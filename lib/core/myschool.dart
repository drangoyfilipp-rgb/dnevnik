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
  'student_classes',
];

/// obj_types asked per week interval (same interval ids as the web app uses).
const List<String> kWeeklyObjTypes = ['student_lessons', 'student_homeworks_materials', 'student_marks'];

/// Final marks; the portal answers 400 without a valid interval_id, so they are only probed.
const List<String> kFinalObjTypes = ['student_pmarks', 'student_ymarks'];

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

  /// v1/current_year answer (academic year), learned from the web app.
  String? currentYear;

  /// Final-mark probes the portal rejected: «obj_type|interval» → when (ISO).
  final Map<String, String> failedProbes = {};

  /// Single-item requests to try for final marks (pmarks/ymarks), which the web app
  /// does not ask on the pages we saw. Candidates: the class/year interval, academ_year,
  /// current_year and the main period ids. Rejected ones are retried after [retryAfter].
  List<Map<String, dynamic>> finalProbes({DateTime? now, Duration retryAfter = const Duration(days: 3), int max = 8}) {
    final sid = requestStudentId;
    if (sid == null) return const [];
    final when = now ?? DateTime.now();
    final cands = <String>[];
    void add(dynamic v) {
      final t = _s(v);
      if (t.isNotEmpty && !cands.contains(t)) cands.add(t);
    }

    for (final e in entriesOf('student_classes')) {
      add(e.intervalId);
      for (final o in e.objects.values) {
        add(o['academ_year']);
      }
    }
    add(currentYear);
    for (final p in mainPeriods(parsePeriods(objectsOf('student_classes')))) {
      add(p.id);
    }
    final out = <Map<String, dynamic>>[];
    for (final t in kFinalObjTypes) {
      if (entriesOf(t).any((e) => e.objects.isNotEmpty)) continue; // already works → replayed
      for (final c in cands) {
        final failed = DateTime.tryParse(failedProbes['$t|$c'] ?? '');
        if (failed != null && when.difference(failed) < retryAfter) continue;
        out.add({'interval_id': c, 'obj_type': t, 'student_id': sid, 'hash': null});
      }
    }
    return out.take(max).toList();
  }

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

  /// Bodies to POST to the datamart now: every stored (obj_type, interval) of a wanted
  /// type with our hash, plus learned requests not stored yet. Never an item without
  /// interval_id for types that need one (the portal answers 400 to the whole batch).
  List<List<Map<String, dynamic>>> buildRequests({List<String> wanted = kWantedObjTypes, int chunk = 12}) {
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    void add(String t, dynamic sid, String iid) {
      final k = keyOf(t, _s(sid), iid);
      if (!seen.add(k)) return;
      items.add({
        if (iid.isNotEmpty) 'interval_id': iid,
        'obj_type': t,
        'student_id': sid is String ? sid : _s(sid),
        'hash': entries[k]?.hash,
      });
    }

    for (final r in requests) {
      for (final i in r) {
        final t = _s(i['obj_type']);
        if (!wanted.contains(t)) continue;
        add(t, i['student_id'], _s(i['interval_id']));
      }
    }
    for (final e in entries.values) {
      if (!wanted.contains(e.objType) || e.status == 'error' || e.studentId.isEmpty) continue;
      if (e.intervalId.isEmpty && kFinalObjTypes.contains(e.objType)) continue;
      add(e.objType, e.studentId, e.intervalId);
    }
    final out = <List<Map<String, dynamic>>>[];
    for (var i = 0; i < items.length; i += chunk) {
      out.add(items.sublist(i, i + chunk > items.length ? items.length : i + chunk));
    }
    return out;
  }

  /// Student id as the web app sends it (a string in all observed requests).
  String? get requestStudentId {
    for (final r in requests) {
      for (final i in r) {
        final v = _s(i['student_id']);
        if (v.isNotEmpty) return v;
      }
    }
    return studentId;
  }

  /// Date range of lessons/homework/marks in each stored interval of [objType].
  List<IntervalSpan> intervalSpans(String objType) {
    final out = <IntervalSpan>[];
    for (final e in entriesOf(objType)) {
      DateTime? lo, hi;
      for (final o in e.objects.values) {
        final d = objectDate(objType, o);
        if (d == null) continue;
        if (lo == null || d.isBefore(lo)) lo = d;
        if (hi == null || d.isAfter(hi)) hi = d;
      }
      if (lo != null) out.add(IntervalSpan(e.intervalId, lo, hi!, e.objects.length));
    }
    return out;
  }

  /// Week interval model learned from what the web app asked (null = unknown shape).
  WeekIntervalModel? get weekModel {
    final spans = [
      ...intervalSpans('student_lessons'),
      ...intervalSpans('student_marks'),
    ];
    return WeekIntervalModel.fit(spans);
  }

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
        'year': currentYear,
        'failed': failedProbes,
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
    s.currentYear = j['year'] as String?;
    final f = j['failed'];
    if (f is Map) f.forEach((k, v) => s.failedProbes['$k'] = '$v');
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
    final wm = weekModel;
    b.writeln('  интервалы недель: ${wm == null ? 'модель не найдена' : wm.describe()}');
    final mon = mondayOf(DateTime.now());
    for (final t in kWeeklyObjTypes) {
      final spans = intervalSpans(t)..sort((x, y) => x.first.compareTo(y.first));
      if (spans.isEmpty) continue;
      b.writeln('  $t по интервалам: ${spans.map((x) => 'id ${x.id.length} цифр/${RegExp(r'^\d+$').hasMatch(x.id) ? 'число' : 'текст'}, '
          '${x.days} дн., неделя ${(mondayOf(x.first).difference(mon).inDays / 7).round()}, ${x.count} об.').join('; ')}');
    }
    b.writeln('  итоговые: неудачных проб ${failedProbes.length}, год ${currentYear == null ? 'нет' : 'есть'}');
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
  'start_datetime', 'time_start', 'start_time', 'begin_time', 'lesson_start', 'time_from', 'start', 'begin', 'start_at', 'begin_at',
  'datetime_from', 'datetime_start', 'start_date_time', 'date_from', 'date_start',
];
const _endKeys = [
  'end_datetime', 'time_end', 'end_time', 'finish_time', 'lesson_end', 'time_to', 'end', 'finish', 'end_at', 'finish_at', 'datetime_to',
  'datetime_end', 'end_date_time', 'date_to', 'date_end',
];
const _numberKeys = ['lesson_number', 'number', 'lesson_num', 'num', 'order', 'position', 'lesson_index', 'period_number', 'index'];
const _topicKeys = ['topic', 'lesson_topic', 'theme', 'topic_name', 'lesson_theme', 'subject_topic', 'topic_title'];
const _hwTextKeys = [
  'description', 'homework_text', 'hometask', 'text', 'content', 'task', 'homework', 'home_work', 'assignment',
  'value', 'title', 'name', 'comment',
];
const _hwDueKeys = [
  'plan_ready_date', 'ready_date', 'date_to', 'deadline', 'due_date', 'dueDate', 'to_date', 'date_end', 'end_date', 'lesson_date', 'date', 'date_from',
  'created_at', 'created',
];
const _lessonLinkKeys = ['ready_lesson_id', 'lesson_id', 'schedule_id', 'schedule_item_id', 'lesson_uuid', 'lessonId'];
const _markValueKeys = [
  'mark_value1', 'mark_value', 'value', 'mark_value', 'mark', 'grade', 'grade_value', 'score', 'result', 'mark_name', 'five_point', 'text',
];
const _markWeightKeys = ['weight', 'mark_weight', 'coefficient', 'coef', 'factor', 'mark_coefficient'];
const _markDateKeys = ['date', 'mark_date', 'lesson_date', 'date_time', 'datetime', 'created_at', 'create_date', 'created'];
const _markCommentKeys = [
  'work_type_description', 'work_type_name', 'control_form', 'control_name', 'control_form_name', 'work_type',
  'type_name', 'form', 'kind',
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
      final sz = m['size'] ?? m['file_size'] ?? m['fileSize'];
      final size = sz is num ? sz.toInt() : int.tryParse('${sz ?? ''}') ?? 0;
      if (seen.add(abs)) out.add(Attachment(name: name, url: abs, size: size));
    }
    for (final e in m.entries) {
      if (e.value is Map || e.value is List) walk(e.value, d + 1);
    }
  }

  walk(v, depth);
  return out;
}

// ───────────────────────── intervals (weeks) ─────────────────────────

class IntervalSpan {
  IntervalSpan(this.id, this.first, this.last, this.count);
  final String id;
  final DateTime first;
  final DateTime last;
  final int count;
  int get days => last.difference(first).inDays + 1;
}

/// Date of a datamart object, used to learn what an interval covers.
DateTime? objectDate(String objType, Map<String, dynamic> o) {
  dynamic v;
  if (objType == 'student_marks') {
    v = pick(o, _markDateKeys, depth: 0) ?? pick(o, _startKeys, depth: 0);
  } else if (objType == 'student_homeworks_materials') {
    v = pick(o, _hwDueKeys, depth: 0);
  } else {
    v = pick(o, _dateKeys, depth: 0) ?? pick(o, _startKeys, depth: 0);
  }
  final d = parseLooseDateTime(v);
  return d == null ? null : dateOnly(d);
}

/// How the web app numbers week intervals: learned from stored intervals
/// (id → Monday of the lessons inside). Supports a linear numbering
/// (id = base + step × weeks, e.g. week counters or epoch seconds) and ids that
/// are dates (YYYYMMDD). Anything else → null (no extra weeks are asked).
class WeekIntervalModel {
  WeekIntervalModel._(this.kind, this.base, this.baseMonday, this.step, this.dayOffset, this.width);
  final String kind; // 'linear' | 'ymd'
  final int base;
  final DateTime baseMonday;
  final int step;
  final int dayOffset; // ymd: id date − Monday, days
  final int width;

  static final _digits = RegExp(r'^\d{1,18}$');

  static WeekIntervalModel? fit(List<IntervalSpan> spans) {
    final weekly = <String, DateTime>{};
    for (final s in spans) {
      if (!_digits.hasMatch(s.id) || s.days > 7) continue;
      final m = mondayOf(s.first);
      if (mondayOf(s.last) != m) continue;
      weekly[s.id] = m;
    }
    if (weekly.isEmpty) return null;
    final ids = weekly.keys.toList()..sort();
    final width = ids.first.length;
    if (ids.any((i) => i.length != width)) return null;

    // YYYYMMDD ids.
    if (width == 8) {
      int? off;
      var ok = true;
      for (final id in ids) {
        final d = DateTime.tryParse('${id.substring(0, 4)}-${id.substring(4, 6)}-${id.substring(6, 8)}');
        if (d == null || d.month != int.parse(id.substring(4, 6))) {
          ok = false;
          break;
        }
        final o = dateOnly(d).difference(weekly[id]!).inDays;
        if (o < -1 || o > 7 || (off != null && off != o)) {
          ok = false;
          break;
        }
        off = o;
      }
      if (ok && off != null) return WeekIntervalModel._('ymd', 0, weekly[ids.first]!, 0, off, width);
    }

    final base = int.parse(ids.first);
    final baseMonday = weekly[ids.first]!;
    int? step;
    for (final id in ids.skip(1)) {
      final weeks = weekly[id]!.difference(baseMonday).inDays ~/ 7;
      final dn = int.parse(id) - base;
      if (weeks == 0) {
        if (dn != 0) return null;
        continue;
      }
      if (dn % weeks != 0) return null;
      final st = dn ~/ weeks;
      if (st == 0 || (step != null && step != st)) return null;
      step = st;
    }
    if (step == null) {
      // A single week: epoch seconds / milliseconds of the Monday are recognisable.
      final ms = baseMonday.millisecondsSinceEpoch;
      if ((base - ms ~/ 1000).abs() <= 2 * 86400) return WeekIntervalModel._('linear', base, baseMonday, 604800, 0, width);
      if ((base - ms).abs() <= 2 * 86400000) return WeekIntervalModel._('linear', base, baseMonday, 604800000, 0, width);
      return null;
    }
    return WeekIntervalModel._('linear', base, baseMonday, step, 0, width);
  }

  /// Interval id of the week starting [monday].
  String idFor(DateTime monday) {
    final m = mondayOf(monday);
    if (kind == 'ymd') {
      final d = m.add(Duration(days: dayOffset));
      return '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
    }
    final weeks = (m.difference(baseMonday).inHours / (24 * 7)).round();
    return '${base + step * weeks}'.padLeft(width, '0');
  }

  /// No values — for Диагностика.
  String describe() => kind == 'ymd' ? 'ГГГГММДД (+$dayOffset дн. от пн)' : 'линейная, шаг $step на неделю, $width цифр';
}

// ───────────────────────── study periods ─────────────────────────

String _periodLabel(Map<String, dynamic> p, int days) {
  final num = textOf(pick(p, const ['period_num', 'num', 'number'], depth: 0));
  final desc = textOf(pick(p, const ['period_type_description', 'period_type_descrioption', 'period_name', 'name'], depth: 0));
  final low = desc.toLowerCase();
  if (days > 200 || (low.contains('год') && !low.contains('полугод'))) return 'Год';
  if (RegExp(r'\d').hasMatch(desc)) return desc;
  String word;
  if (low.contains('четв')) {
    word = 'четверть';
  } else if (low.contains('полуг')) {
    word = 'полугодие';
  } else if (low.contains('трим')) {
    word = 'триместр';
  } else if (low.contains('семест')) {
    word = 'семестр';
  } else if (low.contains('кан')) {
    word = 'каникулы';
  } else {
    word = low.isEmpty ? 'период' : low;
  }
  return num.isEmpty ? word : '$num $word';
}

/// Study periods of the current class (student_classes → periods).
List<StudyPeriod> parsePeriods(List<Map<String, dynamic>> classes) {
  final out = <StudyPeriod>[];
  final seen = <String>{};
  for (final c in classes) {
    final list = c['periods'];
    if (list is! List) continue;
    for (final raw in list) {
      if (raw is! Map) continue;
      final p = Map<String, dynamic>.from(raw);
      final a = parseLooseDateTime(pick(p, const ['period_start_date', 'start_date', 'date_from'], depth: 0));
      final b = parseLooseDateTime(pick(p, const ['period_end_date', 'end_date', 'date_to'], depth: 0));
      if (a == null || b == null) continue;
      final start = dateOnly(a), end = dateOnly(b);
      final id = textOf(p['period_id'] ?? p['id']);
      if (!seen.add('$id|$start|$end')) continue;
      final days = end.difference(start).inDays + 1;
      out.add(StudyPeriod(
        id: id,
        label: _periodLabel(p, days),
        start: start,
        end: end,
        type: textOf(p['period_type_code'] ?? p['period_type_value']),
        study: p['period_is_study'] != false,
      ));
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start) != 0 ? a.start.compareTo(b.start) : b.days.compareTo(a.days));
  return out;
}

/// The attestation periods marks are grouped by (most frequent study type shorter than a year).
List<StudyPeriod> mainPeriods(List<StudyPeriod> all) {
  final byType = <String, List<StudyPeriod>>{};
  for (final p in all) {
    if (!p.study || p.days > 200) continue;
    byType.putIfAbsent(p.type, () => []).add(p);
  }
  if (byType.isEmpty) return const [];
  final best = byType.values.reduce((a, b) => b.length > a.length ? b : a);
  return best..sort((a, b) => a.start.compareTo(b.start));
}

StudyPeriod? periodAt(List<StudyPeriod> periods, DateTime day) {
  final d = dateOnly(day);
  for (final p in periods) {
    if (p.contains(d)) return p;
  }
  StudyPeriod? prev;
  for (final p in periods) {
    if (!p.start.isAfter(d)) prev = p;
  }
  return prev ?? (periods.isEmpty ? null : periods.first);
}

// ───────────────────────── objects → diary ─────────────────────────

class _LessonRec {
  _LessonRec(this.id, this.date, this.lesson, this.start, this.end, this.order);
  final String id;
  final DateTime date;
  Lesson lesson;
  final String start; // «08:30» or ''
  final String end;
  final int order; // arrival order (the portal sends lessons in day order)
}

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

String _markValue(Map<String, dynamic> m) {
  final v1 = textOf(pick(m, _markValueKeys, depth: 1));
  final v2 = textOf(m['mark_value2']);
  if (v1.isEmpty) return v2;
  return v2.isEmpty || v2 == v1 ? v1 : '$v1/$v2';
}

Mark? parseMark(Map<String, dynamic> m, {String subject = ''}) {
  final value = _markValue(m);
  if (value.isEmpty) return null;
  final w = pick(m, _markWeightKeys, depth: 1);
  final weight = w is num ? w.toDouble() : double.tryParse(textOf(w).replaceAll(',', '.')) ?? 1;
  final d = parseLooseDateTime(pick(m, _markDateKeys, depth: 1));
  final kind = textOf(pick(m, _markCommentKeys, depth: 1));
  final note = textOf(m['comment']);
  final comment = [kind, if (note.isNotEmpty && note != kind) note].where((x) => x.isNotEmpty && x != value).join(' · ');
  final subj = subjectOf(m);
  return Mark(
    value: value,
    weight: weight <= 0 ? 1 : weight,
    comment: comment,
    subject: subj.isEmpty ? subject : subj,
    date: d == null ? null : dateOnly(d),
    kind: '',
    periodId: textOf(m['period_id']),
  );
}

String _teacherOf(Map<String, dynamic> o) {
  final last = textOf(o['lastname'] ?? o['last_name'] ?? o['teacher_last_name']);
  final first = textOf(o['firstname'] ?? o['first_name'] ?? o['teacher_first_name']);
  final middle = textOf(o['patronymic'] ?? o['middle_name'] ?? o['teacher_middle_name']);
  if (last.isEmpty) return textOf(o['teacher_name'] ?? o['teacher_fio'] ?? o['teacher']);
  final ini = [first, middle].where((x) => x.isNotEmpty).map((x) => '${x.substring(0, 1)}.').join(' ');
  return ini.isEmpty ? last : '$last $ini';
}

String _absenceOf(Map<String, dynamic> o) {
  if (o['skipping_id'] == null && o['skip_date'] == null) return '';
  final t = textOf(o['skipping_description'] ?? o['type_description'] ?? o['type_value']);
  return t.isEmpty ? 'Пропуск' : t;
}

/// Stable identity of a datamart object (the same lesson comes in several intervals).
String _identity(Map<String, dynamic> o, List<String> keys) {
  for (final k in keys) {
    final v = o[k];
    if (v != null && textOf(v).isNotEmpty) return '$k:${textOf(v)}';
  }
  final copy = Map<String, dynamic>.from(o)..remove('obj_hash');
  return 'json:${jsonEncode(copy)}';
}

class DiaryData {
  DiaryData(this.days, this.subjects, this.finals, {this.periods = const [], this.timesFromBells = false});
  final List<Day> days;
  final List<SubjectMarks> subjects;
  final FinalsTable? finals;
  final List<StudyPeriod> periods; // main attestation periods (четверти)
  final bool timesFromBells;

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
DiaryData buildDiary(DatamartStore store, {List<String> bells = const [], DateTime? now}) {
  return buildDiaryFrom(
    lessons: store.objectsOf('student_lessons'),
    homeworks: store.objectsOf('student_homeworks_materials'),
    marks: store.objectsOf('student_marks'),
    pmarks: [
      for (final e in store.entriesOf('student_pmarks'))
        for (final o in e.objects.values) {...o, '#interval': e.intervalId},
    ],
    ymarks: store.objectsOf('student_ymarks'),
    classes: store.objectsOf('student_classes'),
    bells: bells,
    now: now,
  );
}

/// «08:30–09:15» lines from the bell schedule setting (index = lesson number − 1).
String bellFor(List<String> bells, String number) {
  final n = int.tryParse(number);
  if (n == null || n < 1 || n > bells.length) return '';
  return bells[n - 1].trim();
}

DiaryData buildDiaryFrom({
  List<Map<String, dynamic>> lessons = const [],
  List<Map<String, dynamic>> homeworks = const [],
  List<Map<String, dynamic>> marks = const [],
  List<Map<String, dynamic>> pmarks = const [],
  List<Map<String, dynamic>> ymarks = const [],
  List<Map<String, dynamic>> classes = const [],
  List<String> bells = const [],
  DateTime? now,
}) {
  final recs = <_LessonRec>[];
  final byId = <String, _LessonRec>{};
  final seenLessons = <String>{};
  var order = 0;

  // Lessons (schedule). The same lesson arrives in several overlapping intervals → dedupe.
  for (final o in lessons) {
    if (!seenLessons.add(_identity(o, const ['id', 'obj_id', 'lesson_id', 'uuid']))) continue;
    final startRaw = pick(o, _startKeys, depth: 1);
    final endRaw = pick(o, _endKeys, depth: 1);
    var date = _dateFrom(o, _dateKeys);
    if (date == null && hasTimePart(startRaw)) {
      final d = parseLooseDateTime(startRaw);
      if (d != null) date = dateOnly(d);
    }
    if (date == null) continue;
    final s = parseLooseTime(startRaw), e = parseLooseTime(endRaw);
    final number = textOf(pick(o, _numberKeys, depth: 0));
    final subject = subjectOf(o);
    final inlineHw = pick(o, const ['homework', 'home_work', 'hometask', 'homeworks', 'home_task'], depth: 0);
    final lesson = Lesson(
      number: RegExp(r'^\d{1,2}$').hasMatch(number) ? number : '',
      subject: subject.isEmpty ? 'Урок' : subject,
      topic: htmlToText(textOf(pick(o, _topicKeys, depth: 1))),
      homework: _homeworkText(inlineHw),
      files: attachmentsIn(inlineHw),
      room: textOf(pick(o, const ['room', 'room_name', 'classroom', 'cabinet', 'auditorium'], depth: 0)),
      teacher: _teacherOf(o),
      absence: _absenceOf(o),
    );
    final r = _LessonRec(textOf(o['id'] ?? o['obj_id']), date, lesson, s, e, order++);
    recs.add(r);
    for (final k in [o['obj_id'], o['id'], o['lesson_id'], o['uuid'], o['schedule_id']]) {
      if (k != null && textOf(k).isNotEmpty) byId.putIfAbsent(textOf(k), () => r);
    }
  }

  // Times: the portal sends a placeholder (the same start for every lesson of a day)
  // when the school did not fill its bell schedule → show lesson numbers only.
  final byDay = <DateTime, List<_LessonRec>>{};
  for (final r in recs) {
    byDay.putIfAbsent(r.date, () => []).add(r);
  }
  final allStarts = recs.map((r) => r.start).where((x) => x.isNotEmpty).toSet();
  final globalFake = recs.length >= 3 && allStarts.length == 1;
  var usedBells = false;
  for (final list in byDay.values) {
    final starts = list.map((r) => r.start).toSet();
    final fake = globalFake || (list.length >= 2 && starts.length == 1);
    final hasNumbers = list.every((r) => r.lesson.number.isNotEmpty);
    list.sort((a, b) {
      if (hasNumbers) {
        final c = int.parse(a.lesson.number).compareTo(int.parse(b.lesson.number));
        if (c != 0) return c;
      } else if (!fake) {
        final c = (a.start.isEmpty ? '99:99' : a.start).compareTo(b.start.isEmpty ? '99:99' : b.start);
        if (c != 0) return c;
      }
      return a.order.compareTo(b.order);
    });
    for (var i = 0; i < list.length; i++) {
      final r = list[i];
      final number = r.lesson.number.isNotEmpty ? r.lesson.number : '${i + 1}';
      var time = '';
      if (!fake && r.start.isNotEmpty) time = r.end.isEmpty ? r.start : '${r.start}–${r.end}';
      if (time.isEmpty) {
        time = bellFor(bells, number);
        if (time.isNotEmpty) usedBells = true;
      }
      r.lesson = r.lesson.copyWith(number: number, time: time);
    }
  }

  // Homework (+ materials). Shown on the lesson it is due (ready_lesson_id / plan_ready_date).
  final seenHw = <String>{};
  for (final o in homeworks) {
    if (!seenHw.add(_identity(o, const ['id', 'obj_id', 'homework_id']))) continue;
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
    final link = pick(o, _lessonLinkKeys, depth: 0);
    if (link != null) target = byId[textOf(link)];
    final date = _dateFrom(o, _hwDueKeys) ?? target?.date;
    if (target != null && date != null && target.date != date) target = null;
    if (target == null && date != null) {
      final same = recs.where((r) => r.date == date && normSubject(r.lesson.subject) == normSubject(subject)).toList();
      if (same.isNotEmpty) target = same.firstWhere((r) => !r.lesson.hasHomework, orElse: () => same.first);
    }
    if (target != null) {
      final l = target.lesson;
      final hw = l.homework.isEmpty ? text : (text.isEmpty || l.homework.contains(text) ? l.homework : '${l.homework}\n$text');
      final allFiles = [...l.files, ...files.where((f) => !l.files.any((x) => x.url == f.url))];
      target.lesson = l.copyWith(homework: hw, files: allFiles);
    } else if (date != null) {
      recs.add(_LessonRec('', date,
          Lesson(subject: subject.isEmpty ? 'Задание' : subject, homework: text, files: files, isLesson: false), '', '', order++));
    }
  }

  // Marks: on the lesson (lesson_id, else same day + subject) and grouped by subject.
  final bySubject = <String, List<Mark>>{};
  final subjectNames = <String, String>{};
  final seenMarks = <String>{};
  for (final o in marks) {
    if (!seenMarks.add(_identity(o, const ['id', 'obj_id', 'marks_id']))) continue;
    final m = parseMark(o);
    if (m == null) continue;
    final key = normSubject(m.subject);
    subjectNames.putIfAbsent(key, () => m.subject.isEmpty ? 'Без предмета' : m.subject);
    bySubject.putIfAbsent(key, () => []).add(m);
    _LessonRec? target;
    final link = o['lesson_id'] ?? pick(o, _lessonLinkKeys, depth: 0);
    if (link != null) target = byId[textOf(link)];
    if (target == null && m.date != null) {
      target = recs.where((r) => r.date == m.date && normSubject(r.lesson.subject) == key && r.lesson.isLesson).firstOrNull;
    }
    if (target != null) target.lesson = target.lesson.copyWith(marks: [...target.lesson.marks, m]);
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
    final list = e.value
      ..sort((a, b) {
        if (a.lesson.isLesson != b.lesson.isLesson) return a.lesson.isLesson ? -1 : 1;
        final na = int.tryParse(a.lesson.number) ?? 99, nb = int.tryParse(b.lesson.number) ?? 99;
        return na != nb ? na.compareTo(nb) : a.order.compareTo(b.order);
      });
    final d = e.key;
    return Day(
      date: d,
      title: '${_weekdaysFull[d.weekday - 1]}, ${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}',
      lessons: list.map((r) => r.lesson).toList(),
    );
  }).toList()
    ..sort((a, b) => a.date.compareTo(b.date));

  final allPeriods = parsePeriods(classes);
  final periods = mainPeriods(allPeriods);
  final official = buildFinals(pmarks: pmarks, ymarks: ymarks, periods: allPeriods);
  final finals = official ?? buildForecast(subjects, periods, now: now);
  return DiaryData(days, subjects, finals, periods: periods, timesFromBells: usedBells);
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

FinalsTable? buildFinals({
  List<Map<String, dynamic>> pmarks = const [],
  List<Map<String, dynamic>> ymarks = const [],
  List<StudyPeriod> periods = const [],
}) {
  final rows = <String, Map<String, String>>{};
  final names = <String, String>{};
  final headers = <String>[];
  void put(String subject, String period, String value) {
    final k = normSubject(subject);
    names.putIfAbsent(k, () => subject.isEmpty ? 'Без предмета' : subject);
    rows.putIfAbsent(k, () => {})[period] = value;
    if (!headers.contains(period)) headers.add(period);
  }

  final byId = {for (final p in periods) if (p.id.isNotEmpty) p.id: p.label};
  final intervalLabels = <String, String>{};
  for (final o in pmarks) {
    final m = parseMark(o);
    if (m == null) continue;
    var period = byId[m.periodId] ?? textOf(pick(o, _periodKeys, depth: 1));
    if (period.isEmpty || RegExp(r'^\d{4,}$').hasMatch(period) || byId.containsKey(period)) {
      period = byId[period] ?? '';
    }
    if (period.isEmpty) {
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

/// Weighted average of marks (null when none is numeric).
double? weightedAverage(Iterable<Mark> marks) {
  double sum = 0, w = 0;
  for (final m in marks) {
    final n = m.numeric;
    if (n == null) continue;
    sum += n * m.weight;
    w += m.weight;
  }
  return w == 0 ? null : sum / w;
}

/// Mark a weighted average rounds to (x.5 rounds up).
String roundedMark(double avg) => (avg + 0.5 + 1e-9).floor().clamp(1, 5).toString();

/// Marks of [period]: by period id when the marks carry one, else by date.
List<Mark> marksInPeriod(List<Mark> marks, StudyPeriod period) => marks
    .where((m) => m.periodId.isNotEmpty && period.id.isNotEmpty
        ? m.periodId == period.id
        : (m.date != null && period.contains(m.date!)))
    .toList();

/// «Прогноз» like the official app when the portal has no final marks yet:
/// rounded weighted average per started period and for the year.
FinalsTable? buildForecast(List<SubjectMarks> subjects, List<StudyPeriod> periods, {DateTime? now}) {
  if (subjects.isEmpty) return null;
  final today = dateOnly(now ?? DateTime.now());
  final started = periods.where((p) => !p.start.isAfter(today)).toList();
  final headers = [for (final p in started) p.label, 'Год'];
  final rows = <FinalsRow>[];
  for (final s in subjects) {
    final values = <String>[], notes = <String>[];
    for (final p in started) {
      final a = weightedAverage(marksInPeriod(s.marks, p));
      values.add(a == null ? '' : roundedMark(a));
      notes.add(a == null ? '' : a.toStringAsFixed(2));
    }
    final y = weightedAverage(s.marks);
    values.add(y == null ? '' : roundedMark(y));
    notes.add(y == null ? '' : y.toStringAsFixed(2));
    if (values.every((v) => v.isEmpty)) continue;
    rows.add(FinalsRow(s.subject, values, notes));
  }
  if (rows.isEmpty) return null;
  return FinalsTable(headers: headers, rows: rows, fetchedAt: DateTime.now(), forecast: true);
}
