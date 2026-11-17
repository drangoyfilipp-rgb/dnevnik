// «Госуслуги Моя школа» data layer (pure Dart, unit-tested with synthetic JSON).
//
// The portal API (https://www.gosuslugi.ru/api/myschool/) is not documented.
// We learn the real datamart requests from the official web app inside a
// WebView, replay them from Dart, keep the raw objects per obj_type (offline
// cache + hash-based deltas) and derive the diary from them with key-name
// heuristics, because field schemas are not known in advance.

import 'dart:convert';

import 'models.dart';
import 'util.dart';

const String kMsOrigin = 'https://www.gosuslugi.ru';
const String kMsApiPrefix = '/api/myschool/';
const String kMsDatamartPath = '/api/myschool/v1/datamart';
const String kMsFeedUrl = 'https://www.gosuslugi.ru/school/feed';

const List<String> kWantedObjTypes = [
  'student_lessons',
  'student_homeworks_materials',
  'student_marks',
  'student_pmarks',
  'student_ymarks',
];

/// Path of a URL with digits/uuids masked — safe for logs and the export.
String maskApiPath(String urlOrPath) {
  final uri = Uri.tryParse(urlOrPath);
  final p = uri == null ? urlOrPath.split('?').first : uri.path;
  return p
      .replaceAll(RegExp(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'), '{uuid}')
      .replaceAll(RegExp(r'\d{3,}'), '#');
}

// ───────────────────────── key structure (no values) ─────────────────────────

const _enumKeys = {'obj_type', 'data_status', 'obj_action', 'role'};

String _strKind(String s) {
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) return 'str:date';
  if (RegExp(r'^\d{4}-\d{2}-\d{2}[T ]\d{1,2}:\d{2}').hasMatch(s)) return 'str:datetime';
  if (RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$').hasMatch(s)) return 'str:time';
  if (RegExp(r'^\d{1,2}\.\d{1,2}\.\d{4}').hasMatch(s)) return 'str:ru-date';
  if (RegExp(r'^-?\d+([.,]\d+)?$').hasMatch(s)) return 'str:num';
  if (s.startsWith('http://') || s.startsWith('https://')) return 'str:url';
  if (s.startsWith('/')) return 'str:path';
  if (s.contains('<') && s.contains('>')) return 'str:html';
  if (s.isEmpty) return 'str:empty';
  return 'str';
}

String _maskKey(String k) => RegExp(r'^\d+$').hasMatch(k) || RegExp(r'\d{4,}').hasMatch(k) ? '#' : k;

/// Type-only shape of a JSON value: keys and value kinds, never values
/// (except a few enum-like keys such as obj_type / data_status).
dynamic jsonShape(dynamic v, {int depth = 0, String? key}) {
  if (depth > 9) return '…';
  if (v == null) return 'null';
  if (v is bool) return 'bool';
  if (v is num) return 'num';
  if (v is String) {
    if (key != null && _enumKeys.contains(key) && v.length <= 60) return '="$v"';
    return _strKind(v);
  }
  if (v is Map) {
    final out = <String, dynamic>{};
    v.forEach((k, val) {
      final mk = _maskKey('$k');
      out[mk] = _mergeShape(out[mk], jsonShape(val, depth: depth + 1, key: '$k'));
    });
    return out;
  }
  if (v is List) {
    if (v.isEmpty) return ['list×0'];
    dynamic merged;
    for (final e in v.take(40)) {
      merged = _mergeShape(merged, jsonShape(e, depth: depth + 1, key: key));
    }
    return ['list×${v.length}', merged];
  }
  return v.runtimeType.toString();
}

dynamic _mergeShape(dynamic a, dynamic b) {
  if (a == null) return b;
  if (b == null) return a;
  if (a is Map && b is Map) {
    final out = Map<String, dynamic>.from(a);
    b.forEach((k, v) => out['$k'] = _mergeShape(out['$k'], v));
    return out;
  }
  if (a is List && b is List && a.length == 2 && b.length == 2) return [a[0], _mergeShape(a[1], b[1])];
  if (a is String && b is String) {
    if (a == b) return a;
    final parts = {...a.split('|'), ...b.split('|')}.toList()..sort();
    return parts.take(6).join('|');
  }
  if (a == 'null') return b;
  if (b == 'null') return a;
  return a;
}

String shapeText(dynamic json) => const JsonEncoder.withIndent(' ').convert(jsonShape(json));

// ───────────────────────── datamart store ─────────────────────────

class DmEntry {
  DmEntry(this.objType, this.studentId, this.intervalId);
  final String objType;
  final String studentId;
  final String intervalId;
  String? hash;
  String status = '';
  DateTime? updated;
  final Map<String, Map<String, dynamic>> objects = {};

  String get key => DatamartStore.keyOf(objType, studentId, intervalId);

  Map<String, dynamic> toJson() => {
        't': objType,
        's': studentId,
        'i': intervalId,
        'h': hash,
        'st': status,
        'u': updated?.toIso8601String(),
        'o': objects,
      };

  factory DmEntry.fromJson(Map<String, dynamic> j) {
    final e = DmEntry(j['t'] as String? ?? '', j['s'] as String? ?? '', j['i'] as String? ?? '')
      ..hash = j['h'] as String?
      ..status = j['st'] as String? ?? ''
      ..updated = DateTime.tryParse(j['u'] as String? ?? '');
    final o = j['o'];
    if (o is Map) {
      o.forEach((k, v) {
        if (v is Map) e.objects['$k'] = Map<String, dynamic>.from(v);
      });
    }
    return e;
  }
}

class ApplyResult {
  int items = 0;
  int objects = 0;
  final List<String> errors = [];
  final Map<String, String> statuses = {}; // objType → status
}

String _s(dynamic v) => v == null ? '' : (v is String ? v : '$v');

class DatamartStore {
  final Map<String, DmEntry> entries = {};

  /// Learned request bodies (each a list of datamart items), as the web app sent them.
  final List<List<Map<String, dynamic>>> requests = [];

  /// Student id learned from requests or from v2/auth/student.
  String? studentId;

  static String keyOf(String t, String s, String i) => '$t|$s|$i';

  bool get isEmpty => entries.values.every((e) => e.objects.isEmpty);
  bool get hasTemplates => requests.isNotEmpty || studentId != null;

  DateTime? get lastUpdated {
    DateTime? best;
    for (final e in entries.values) {
      if (e.updated != null && (best == null || e.updated!.isAfter(best))) best = e.updated;
    }
    return best;
  }

  Iterable<DmEntry> entriesOf(String objType) => entries.values.where((e) => e.objType == objType);

  List<Map<String, dynamic>> objectsOf(String objType) => [
        for (final e in entriesOf(objType)) ...e.objects.values,
      ];

  /// Datamart items found anywhere in a request/response JSON.
  static List<Map<String, dynamic>> itemsIn(dynamic json, {int depth = 0}) {
    if (depth > 3 || json == null) return const [];
    if (json is List) {
      final out = <Map<String, dynamic>>[];
      for (final e in json) {
        if (e is Map && e.containsKey('obj_type')) {
          out.add(Map<String, dynamic>.from(e));
        } else if (e is Map || e is List) {
          out.addAll(itemsIn(e, depth: depth + 1));
        }
      }
      return out;
    }
    if (json is Map) {
      if (json.containsKey('obj_type')) return [Map<String, dynamic>.from(json)];
      final out = <Map<String, dynamic>>[];
      for (final v in json.values) {
        if (v is List || v is Map) out.addAll(itemsIn(v, depth: depth + 1));
      }
      return out;
    }
    return const [];
  }

  /// Remembers a datamart request body sent by the official web app.
  bool learnRequest(dynamic body) {
    final items = itemsIn(body);
    if (items.isEmpty) return false;
    final clean = [
      for (final it in items) {for (final e in it.entries) if (e.key != 'hash') e.key: e.value},
    ];
    for (final it in clean) {
      final sid = _s(it['student_id']);
      if (sid.isNotEmpty) studentId = sid;
    }
    String sig(List<Map<String, dynamic>> r) =>
        (r.map((i) => '${i['obj_type']}|${_s(i['student_id'])}|${_s(i['interval_id'])}').toList()..sort()).join(',');
    final s = sig(clean);
    requests.removeWhere((r) => sig(r) == s);
    requests.add(clean);
    if (requests.length > 40) requests.removeAt(0);
    return true;
  }

  /// Learns the student id from a v2/auth/student-like answer (first pupil).
  void learnStudent(dynamic json) {
    if (studentId != null) return;
    dynamic first = json;
    if (first is Map) {
      for (final k in ['students', 'data', 'items', 'result', 'persons', 'children']) {
        if (first is Map && first[k] is List) {
          first = first[k];
          break;
        }
      }
    }
    if (first is List && first.isNotEmpty) first = first.first;
    if (first is Map) {
      final id = first['student_id'] ?? first['studentId'] ?? first['id'];
      if (id != null && _s(id).isNotEmpty) studentId = _s(id);
    }
  }

  /// Bodies to POST to the datamart now: learned requests with our stored hashes,
  /// or a constructed one when only the student id is known.
  List<List<Map<String, dynamic>>> buildRequests({List<String> wanted = kWantedObjTypes}) {
    final out = <List<Map<String, dynamic>>>[];
    final covered = <String>{};
    for (final r in requests) {
      final items = r.where((i) => wanted.contains(i['obj_type'])).toList();
      if (items.isEmpty) continue;
      out.add([
        for (final i in items)
          {
            ...i,
            'hash': entries[keyOf(_s(i['obj_type']), _s(i['student_id']), _s(i['interval_id']))]?.hash,
          }
      ]);
      covered.addAll(items.map((i) => _s(i['obj_type'])));
    }
    final sid = studentId;
    if (sid != null) {
      final missing = wanted.where((t) => !covered.contains(t)).toList();
      if (missing.isNotEmpty) {
        out.add([
          for (final t in missing) {'obj_type': t, 'student_id': _numOrString(sid), 'hash': entries[keyOf(t, sid, '')]?.hash},
        ]);
      }
    }
    return out;
  }

  static dynamic _numOrString(String s) => int.tryParse(s) ?? s;

  static String objId(Map<String, dynamic> o, int index) {
    for (final k in ['obj_id', 'id', 'uuid', 'obj_hash']) {
      final v = o[k];
      if (v != null && _s(v).isNotEmpty) return _s(v);
    }
    return 'idx$index:${jsonEncode(o).hashCode}';
  }

  /// Applies a datamart answer. [ourRequest] = the answer belongs to a request with
  /// our own hashes (so deltas are relative to our state).
  ApplyResult applyResponse(dynamic json, {bool ourRequest = true, DateTime? now}) {
    final res = ApplyResult();
    final when = now ?? DateTime.now();
    for (final it in itemsIn(json)) {
      final t = _s(it['obj_type']);
      if (t.isEmpty) continue;
      res.items++;
      final sid = _s(it['student_id']);
      if (sid.isNotEmpty) studentId ??= sid;
      final iid = _s(it['interval_id']);
      final key = keyOf(t, sid, iid);
      final e = entries.putIfAbsent(key, () => DmEntry(t, sid, iid));
      var status = _s(it['data_status']).toLowerCase();
      final rawData = it['data'];
      List? data;
      if (rawData is List) {
        data = rawData;
      } else if (rawData is Map) {
        data = rawData.values.whereType<List>().firstOrNull ?? [rawData];
      }
      if (status.isEmpty) status = data != null ? 'snapshot' : 'actual';
      res.statuses[t] = status;
      if (status == 'error') {
        res.errors.add('$t: error');
        e.status = 'error';
        continue;
      }
      final newHash = it['hash'] == null ? null : _s(it['hash']);
      if (status == 'snapshot') {
        e.objects.clear();
      }
      if ((status == 'snapshot' || status == 'delta') && data != null) {
        var i = 0;
        for (final o in data) {
          if (o is! Map) continue;
          final m = Map<String, dynamic>.from(o);
          final id = objId(m, i++);
          if (_s(m['obj_action']).toLowerCase() == 'delete') {
            e.objects.remove(id);
          } else {
            e.objects[id] = m;
          }
          res.objects++;
        }
      }
      if (status == 'delta') {
        final prev = it['prev_hash'] == null ? null : _s(it['prev_hash']);
        final consistent = ourRequest && (prev == null || prev == e.hash);
        e.hash = consistent ? newHash : null; // unknown base → ask for a snapshot next time
      } else if (status == 'snapshot') {
        // A snapshot answered to the web app is still a full state.
        e.hash = newHash;
      } else if (status == 'actual' && newHash != null && ourRequest) {
        e.hash = newHash;
      }
      e.status = status;
      e.updated = when;
    }
    return res;
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'entries': entries.values.map((e) => e.toJson()).toList(),
        'requests': requests,
        'student': studentId,
      };

  static DatamartStore fromJson(Map<String, dynamic> j) {
    final s = DatamartStore();
    for (final e in (j['entries'] as List? ?? const [])) {
      if (e is Map) {
        final d = DmEntry.fromJson(Map<String, dynamic>.from(e));
        s.entries[d.key] = d;
      }
    }
    for (final r in (j['requests'] as List? ?? const [])) {
      if (r is List) {
        s.requests.add([for (final i in r) if (i is Map) Map<String, dynamic>.from(i)]);
      }
    }
    s.studentId = j['student'] as String?;
    return s;
  }

  /// Object counts per obj_type/status (no values) for Диагностика.
  String summary() {
    final b = StringBuffer();
    b.writeln('Шаблонов запросов: ${requests.length}; student_id: ${studentId == null ? 'нет' : 'есть'}');
    for (final r in requests) {
      b.writeln('  запрос: ${r.map((i) => '${i['obj_type']}${_s(i['interval_id']).isEmpty ? '' : '[interval]'}'
          ' {${i.keys.where((k) => k != 'obj_type').join(',')}}').join('; ')}');
    }
    final byType = <String, List<DmEntry>>{};
    for (final e in entries.values) {
      byType.putIfAbsent(e.objType, () => []).add(e);
    }
    for (final t in byType.keys.toList()..sort()) {
      final l = byType[t]!;
      b.writeln('  $t: интервалов ${l.length}, объектов ${l.fold<int>(0, (a, e) => a + e.objects.length)}, '
          'статусы ${l.map((e) => e.status).toSet().join('/')}, hash ${l.where((e) => e.hash != null).length}/${l.length}');
    }
    return b.toString();
  }
}

/// Shifts every ISO date inside an interval id by [days] (for week-shaped ids).
/// Returns null when the id has no dates.
String? shiftIntervalId(String id, int days) {
  final re = RegExp(r'(\d{4})-(\d{2})-(\d{2})');
  if (!re.hasMatch(id)) return null;
  return id.replaceAllMapped(re, (m) {
    final d = DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)).add(Duration(days: days));
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  });
}

// ───────────────────────── tolerant field lookup ─────────────────────────

String _lk(String k) => k.toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');

/// Value of the first key from [keys] (case/underscore-insensitive), looked up on the
/// object itself first, then in nested maps up to [depth].
dynamic pick(Map<String, dynamic> m, List<String> keys, {int depth = 2}) {
  final wanted = keys.map(_lk).toList();
  dynamic find(Map map, int d) {
    final lower = <String, dynamic>{};
    map.forEach((k, v) => lower.putIfAbsent(_lk('$k'), () => v));
    for (final w in wanted) {
      final v = lower[w];
      if (v != null && !(v is String && v.trim().isEmpty)) return v;
    }
    if (d <= 0) return null;
    for (final v in map.values) {
      if (v is Map) {
        final r = find(v, d - 1);
        if (r != null) return r;
      }
    }
    return null;
  }

  return find(m, depth);
}

/// Text of a value: strings as is, numbers formatted, maps by name/title/value.
String textOf(dynamic v) {
  if (v == null) return '';
  if (v is String) return v.trim();
  if (v is num) return v % 1 == 0 ? v.toInt().toString() : v.toString();
  if (v is bool) return '';
  if (v is Map) {
    final m = Map<String, dynamic>.from(v);
    return textOf(pick(m, ['name', 'title', 'short_name', 'full_name', 'value', 'text', 'label', 'description'], depth: 0));
  }
  if (v is List) return v.map(textOf).where((s) => s.isNotEmpty).join('\n');
  return '';
}

const _subjectKeys = [
  'subject_name', 'subjectName', 'subject', 'discipline_name', 'discipline', 'subject_title', 'lesson_name',
  'education_subject', 'course_name', 'course',
];
const _dateKeys = ['date', 'lesson_date', 'day', 'lesson_day', 'schedule_date', 'event_date', 'date_lesson'];
const _startKeys = [
  'time_start', 'start_time', 'begin_time', 'lesson_start', 'time_from', 'start', 'begin', 'start_at', 'begin_at',
  'datetime_from', 'datetime_start', 'start_date_time', 'date_from', 'date_start',
];
const _endKeys = [
  'time_end', 'end_time', 'finish_time', 'lesson_end', 'time_to', 'end', 'finish', 'end_at', 'finish_at', 'datetime_to',
  'datetime_end', 'end_date_time', 'date_to', 'date_end',
];
const _numberKeys = ['lesson_number', 'number', 'lesson_num', 'num', 'order', 'position', 'lesson_index', 'period_number', 'index'];
const _topicKeys = ['topic', 'lesson_topic', 'theme', 'topic_name', 'lesson_theme', 'subject_topic', 'topic_title'];
const _hwTextKeys = [
  'description', 'homework_text', 'hometask', 'text', 'content', 'task', 'homework', 'home_work', 'assignment',
  'value', 'title', 'name', 'comment',
];
const _hwDueKeys = [
  'date_to', 'deadline', 'due_date', 'dueDate', 'to_date', 'date_end', 'end_date', 'lesson_date', 'date', 'date_from',
  'created_at', 'created',
];
const _lessonLinkKeys = ['lesson_id', 'schedule_id', 'schedule_item_id', 'lesson_uuid', 'lessonId'];
const _markValueKeys = [
  'value', 'mark_value', 'mark', 'grade', 'grade_value', 'score', 'result', 'mark_name', 'five_point', 'text',
];
const _markWeightKeys = ['weight', 'mark_weight', 'coefficient', 'coef', 'factor', 'mark_coefficient'];
const _markDateKeys = ['date', 'mark_date', 'lesson_date', 'date_time', 'datetime', 'created_at', 'create_date', 'created'];
const _markCommentKeys = [
  'control_form', 'control_name', 'control_form_name', 'work_type', 'work_type_name', 'type_name', 'lesson_type',
  'form', 'comment', 'kind', 'type',
];
const _periodKeys = [
  'period_name', 'period', 'interval_name', 'term_name', 'term', 'study_period', 'period_title', 'attestation_period',
  'interval', 'name_period', 'quarter', 'semester',
];

String subjectOf(Map<String, dynamic> m) => textOf(pick(m, _subjectKeys));

DateTime? _dateFrom(Map<String, dynamic> m, List<String> keys) {
  final v = pick(m, keys, depth: 1);
  final d = parseLooseDateTime(v);
  return d == null ? null : dateOnly(d);
}

// ───────────────────────── attachments ─────────────────────────

const _urlKeys = ['download_url', 'downloadUrl', 'file_url', 'fileUrl', 'url', 'link', 'href', 'src', 'uri', 'path'];
const _nameKeys = ['file_name', 'filename', 'fileName', 'original_name', 'originalName', 'display_name', 'name', 'title'];

String absMsUrl(String u) {
  final h = u.trim();
  if (h.startsWith('http://') || h.startsWith('https://')) return h;
  if (h.startsWith('//')) return 'https:$h';
  if (h.startsWith('/')) return '$kMsOrigin$h';
  return '$kMsOrigin/$h';
}

/// Files referenced anywhere inside [v] (maps with a URL-like key).
List<Attachment> attachmentsIn(dynamic v, {int depth = 0, bool includeRoot = false}) {
  final out = <Attachment>[];
  final seen = <String>{};
  void walk(dynamic x, int d) {
    if (d > 6 || x == null) return;
    if (x is List) {
      for (final e in x) {
        walk(e, d + 1);
      }
      return;
    }
    if (x is! Map) return;
    final m = Map<String, dynamic>.from(x);
    String? url;
    for (final k in _urlKeys) {
      final val = m[k];
      if (val is String && (val.startsWith('http') || val.startsWith('/'))) {
        url = val;
        break;
      }
    }
    final rootIsFile = includeRoot &&
        d == 0 &&
        url != null &&
        (const ['file_name', 'filename', 'fileName', 'download_url', 'file_url', 'original_name'].any(m.containsKey) ||
            RegExp(r'\.[a-zA-Z0-9]{2,5}$').hasMatch(Uri.tryParse(url)?.path ?? ''));
    if (url != null && (d > 0 || rootIsFile)) {
      var name = '';
      for (final k in _nameKeys) {
        final val = m[k];
        if (val is String && val.trim().isNotEmpty) {
          name = val.trim();
          break;
        }
      }
      if (name.isEmpty) {
        final seg = Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'файл';
        name = Uri.decodeComponent(seg);
      }
      final abs = absMsUrl(url);
      if (seen.add(abs)) out.add(Attachment(name: name, url: abs));
    }
    for (final e in m.entries) {
      if (e.value is Map || e.value is List) walk(e.value, d + 1);
    }
  }

  walk(v, depth);
  return out;
}

// ───────────────────────── objects → diary ─────────────────────────

class _LessonRec {
  _LessonRec(this.id, this.date, this.lesson, this.sortKey);
  final String id;
  final DateTime date;
  Lesson lesson;
  final String sortKey;
}

Lesson _copyLesson(Lesson l, {String? homework, List<Attachment>? files, List<Mark>? marks}) => Lesson(
      number: l.number,
      time: l.time,
      subject: l.subject,
      topic: l.topic,
      homework: homework ?? l.homework,
      files: files ?? l.files,
      marks: marks ?? l.marks,
    );

String _homeworkText(dynamic v) {
  if (v == null) return '';
  if (v is String) return htmlToText(v);
  if (v is Map) {
    final m = Map<String, dynamic>.from(v);
    return htmlToText(textOf(pick(m, _hwTextKeys, depth: 1)));
  }
  if (v is List) return v.map(_homeworkText).where((s) => s.isNotEmpty).toSet().join('\n');
  return '';
}

Mark? parseMark(Map<String, dynamic> m, {String subject = ''}) {
  var raw = pick(m, _markValueKeys, depth: 1);
  final value = textOf(raw);
  if (value.isEmpty) return null;
  final w = pick(m, _markWeightKeys, depth: 1);
  final weight = w is num ? w.toDouble() : double.tryParse(textOf(w).replaceAll(',', '.')) ?? 1;
  final d = parseLooseDateTime(pick(m, _markDateKeys, depth: 1));
  final comment = textOf(pick(m, _markCommentKeys, depth: 1));
  final subj = subjectOf(m);
  return Mark(
    value: value,
    weight: weight <= 0 ? 1 : weight,
    comment: comment == value ? '' : comment,
    subject: subj.isEmpty ? subject : subj,
    date: d == null ? null : dateOnly(d),
    kind: '',
  );
}

class DiaryData {
  DiaryData(this.days, this.subjects, this.finals);
  final List<Day> days;
  final List<SubjectMarks> subjects;
  final FinalsTable? finals;

  Map<String, Week> weeks(DateTime fetchedAt) {
    final out = <String, Week>{};
    final by = <DateTime, List<Day>>{};
    for (final d in days) {
      by.putIfAbsent(mondayOf(d.date), () => []).add(d);
    }
    by.forEach((m, list) {
      list.sort((a, b) => a.date.compareTo(b.date));
      out[weekKey(m)] = Week(monday: m, days: list, fetchedAt: fetchedAt);
    });
    return out;
  }
}

String weekKey(DateTime monday) =>
    '${monday.year}-${monday.month.toString().padLeft(2, '0')}-${monday.day.toString().padLeft(2, '0')}';

const _weekdaysFull = ['Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье'];

/// Builds the diary from raw objects of the store.
DiaryData buildDiary(DatamartStore store) {
  return buildDiaryFrom(
    lessons: store.objectsOf('student_lessons'),
    homeworks: store.objectsOf('student_homeworks_materials'),
    marks: store.objectsOf('student_marks'),
    pmarks: [
      for (final e in store.entriesOf('student_pmarks'))
        for (final o in e.objects.values) {...o, '#interval': e.intervalId},
    ],
    ymarks: store.objectsOf('student_ymarks'),
  );
}

DiaryData buildDiaryFrom({
  List<Map<String, dynamic>> lessons = const [],
  List<Map<String, dynamic>> homeworks = const [],
  List<Map<String, dynamic>> marks = const [],
  List<Map<String, dynamic>> pmarks = const [],
  List<Map<String, dynamic>> ymarks = const [],
}) {
  final recs = <_LessonRec>[];
  final byId = <String, _LessonRec>{};

  // Lessons (schedule).
  for (final o in lessons) {
    final startRaw = pick(o, _startKeys, depth: 1);
    final endRaw = pick(o, _endKeys, depth: 1);
    var date = _dateFrom(o, _dateKeys);
    if (date == null && hasTimePart(startRaw)) {
      final d = parseLooseDateTime(startRaw);
      if (d != null) date = dateOnly(d);
    }
    if (date == null) continue;
    final s = parseLooseTime(startRaw), e = parseLooseTime(endRaw);
    final time = s.isEmpty ? '' : (e.isEmpty ? s : '$s–$e');
    final number = textOf(pick(o, _numberKeys, depth: 0));
    final subject = subjectOf(o);
    final inlineHw = pick(o, const ['homework', 'home_work', 'hometask', 'homeworks', 'home_task'], depth: 0);
    final lesson = Lesson(
      number: RegExp(r'^\d{1,2}$').hasMatch(number) ? number : '',
      time: time,
      subject: subject.isEmpty ? 'Урок' : subject,
      topic: htmlToText(textOf(pick(o, _topicKeys, depth: 1))),
      homework: _homeworkText(inlineHw),
      files: attachmentsIn(inlineHw),
    );
    final id = textOf(o['obj_id'] ?? o['id'] ?? o['lesson_id'] ?? o['uuid']);
    final sortKey = '${lesson.number.padLeft(2, '0')}|${s.isEmpty ? '99:99' : s}';
    final r = _LessonRec(id, date, lesson, sortKey);
    recs.add(r);
    for (final k in [o['obj_id'], o['id'], o['lesson_id'], o['uuid'], o['schedule_id']]) {
      if (k != null && textOf(k).isNotEmpty) byId[textOf(k)] = r;
    }
  }

  // Homework (+ materials/files).
  for (final o in homeworks) {
    final subject = subjectOf(o);
    var text = '';
    for (final k in _hwTextKeys) {
      final v = pick(o, [k], depth: 1);
      final t = v is List ? _homeworkText(v) : htmlToText(textOf(v));
      if (t.isNotEmpty && t != subject) {
        text = t;
        break;
      }
    }
    final files = attachmentsIn(o, includeRoot: true);
    if (files.any((f) => f.name == text)) text = '';
    if (text.isEmpty && files.isEmpty) continue;
    _LessonRec? target;
    final link = pick(o, _lessonLinkKeys, depth: 1);
    if (link != null) target = byId[textOf(link)];
    final date = _dateFrom(o, _hwDueKeys) ?? target?.date;
    if (target == null && date != null) {
      final same = recs.where((r) => r.date == date && normSubject(r.lesson.subject) == normSubject(subject)).toList();
      if (same.isNotEmpty) target = same.firstWhere((r) => !r.lesson.hasHomework, orElse: () => same.first);
    }
    if (target != null) {
      final l = target.lesson;
      final hw = l.homework.isEmpty ? text : (l.homework.contains(text) ? l.homework : '${l.homework}\n$text');
      final allFiles = [...l.files, ...files.where((f) => !l.files.any((x) => x.url == f.url))];
      target.lesson = _copyLesson(l, homework: hw, files: allFiles);
    } else if (date != null) {
      final r = _LessonRec('', date, Lesson(subject: subject.isEmpty ? 'Задание' : subject, homework: text, files: files), '99|99:99');
      recs.add(r);
    }
  }

  // Marks: attached to the lesson of the same day/subject, and grouped by subject.
  final bySubject = <String, List<Mark>>{};
  final subjectNames = <String, String>{};
  for (final o in marks) {
    final m = parseMark(o);
    if (m == null) continue;
    final key = normSubject(m.subject);
    subjectNames.putIfAbsent(key, () => m.subject.isEmpty ? 'Без предмета' : m.subject);
    bySubject.putIfAbsent(key, () => []).add(m);
    _LessonRec? target;
    final link = pick(o, _lessonLinkKeys, depth: 1);
    if (link != null) target = byId[textOf(link)];
    if (target == null && m.date != null) {
      target = recs.where((r) => r.date == m.date && normSubject(r.lesson.subject) == key).firstOrNull;
    }
    if (target != null) target.lesson = _copyLesson(target.lesson, marks: [...target.lesson.marks, m]);
  }
  final subjects = bySubject.entries.map((e) {
    final list = e.value..sort((a, b) => (a.date ?? DateTime(0)).compareTo(b.date ?? DateTime(0)));
    return SubjectMarks(subject: subjectNames[e.key]!, marks: list);
  }).toList()
    ..sort((a, b) => a.subject.compareTo(b.subject));

  // Days.
  final byDate = <DateTime, List<_LessonRec>>{};
  for (final r in recs) {
    byDate.putIfAbsent(r.date, () => []).add(r);
  }
  final days = byDate.entries.map((e) {
    final list = e.value..sort((a, b) => a.sortKey.compareTo(b.sortKey));
    final d = e.key;
    return Day(
      date: d,
      title: '${_weekdaysFull[d.weekday - 1]}, ${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}',
      lessons: list.map((r) => r.lesson).toList(),
    );
  }).toList()
    ..sort((a, b) => a.date.compareTo(b.date));

  return DiaryData(days, subjects, buildFinals(pmarks: pmarks, ymarks: ymarks));
}

int _periodOrder(String label) {
  if (label.startsWith('Период ')) return 100 + (int.tryParse(label.substring(7)) ?? 0);
  final m = RegExp(r'(\d+)').firstMatch(label);
  if (m != null) return int.parse(m.group(1)!);
  const roman = {'I': 1, 'II': 2, 'III': 3, 'IV': 4};
  final r = RegExp(r'\b(IV|III|II|I)\b').firstMatch(label);
  if (r != null) return roman[r.group(1)]!;
  return 50;
}

FinalsTable? buildFinals({List<Map<String, dynamic>> pmarks = const [], List<Map<String, dynamic>> ymarks = const []}) {
  final rows = <String, Map<String, String>>{};
  final names = <String, String>{};
  final headers = <String>[];
  void put(String subject, String period, String value) {
    final k = normSubject(subject);
    names.putIfAbsent(k, () => subject.isEmpty ? 'Без предмета' : subject);
    rows.putIfAbsent(k, () => {})[period] = value;
    if (!headers.contains(period)) headers.add(period);
  }

  final intervalLabels = <String, String>{};
  for (final o in pmarks) {
    final m = parseMark(o);
    if (m == null) continue;
    var period = textOf(pick(o, _periodKeys, depth: 1));
    if (period.isEmpty || RegExp(r'^\d{4,}$').hasMatch(period)) {
      final iid = textOf(o['#interval']);
      period = intervalLabels.putIfAbsent(iid, () => 'Период ${intervalLabels.length + 1}');
    }
    put(m.subject, period, m.value);
  }
  for (final o in ymarks) {
    final m = parseMark(o);
    if (m == null) continue;
    put(m.subject, 'Год', m.value);
  }
  if (rows.isEmpty) return null;
  final periodHeaders = headers.where((h) => h != 'Год').toList()
    ..sort((a, b) => _periodOrder(a).compareTo(_periodOrder(b)));
  final allHeaders = [...periodHeaders, if (headers.contains('Год')) 'Год'];
  final keys = rows.keys.toList()..sort((a, b) => names[a]!.compareTo(names[b]!));
  return FinalsTable(
    headers: allHeaders,
    rows: [for (final k in keys) FinalsRow(names[k]!, [for (final h in allHeaders) rows[k]![h] ?? ''])],
    fetchedAt: DateTime.now(),
  );
}
