// Tolerant parsers for the server-rendered ЭлЖур pages (school.lpr-reg.ru).
// Every parser returns what it can find and never throws on unknown markup;
// the «Диагностика» export shows the page structure when something is missing.

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'models.dart';

const String kBaseUrl = 'https://school.lpr-reg.ru';

String cleanText(String s) {
  var t = s.replaceAll('\u00a0', ' ').replaceAll('\r', '');
  t = t.split('\n').map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim()).join('\n');
  t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return t.trim();
}

/// Text of an element keeping line breaks from <br>, <p>, <li>, <div>.
String blockText(dom.Element? e) {
  if (e == null) return '';
  final buf = StringBuffer();
  void walk(dom.Node n) {
    if (n is dom.Text) {
      buf.write(n.text);
    } else if (n is dom.Element) {
      final tag = n.localName;
      if (tag == 'script' || tag == 'style') return;
      if (tag == 'br') {
        buf.write('\n');
        return;
      }
      final block = const {'p', 'div', 'li', 'tr', 'ul', 'ol', 'h1', 'h2', 'h3', 'h4'}.contains(tag);
      if (block) buf.write('\n');
      if (tag == 'li') buf.write('• ');
      for (final c in n.nodes) {
        walk(c);
      }
      if (block) buf.write('\n');
    }
  }

  walk(e);
  return cleanText(buf.toString());
}

String absUrl(String href, {String base = kBaseUrl}) {
  final h = href.trim();
  if (h.startsWith('http://') || h.startsWith('https://')) return h;
  if (h.startsWith('//')) return 'https:$h';
  if (h.startsWith('/')) return '$base$h';
  return '$base/$h';
}

/// «Понедельник, 17.11» (+ school year guess) → date.
DateTime? parseDayTitle(String title, {DateTime? now}) {
  final m = RegExp(r'(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4}))?').firstMatch(title);
  if (m == null) return null;
  final d = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  int year;
  if (m.group(3) != null) {
    year = int.parse(m.group(3)!);
    if (year < 100) year += 2000;
  } else {
    final n = now ?? DateTime.now();
    // School year runs September → August.
    final startYear = n.month >= 8 ? n.year : n.year - 1;
    year = mo >= 8 ? startYear : startYear + 1;
  }
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return DateTime(year, mo, d);
}

DateTime? parseAnyDate(String s, {DateTime? now}) {
  final iso = RegExp(r'(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  if (iso != null) {
    return DateTime(int.parse(iso.group(1)!), int.parse(iso.group(2)!), int.parse(iso.group(3)!));
  }
  return parseDayTitle(s, now: now);
}

DateTime mondayOf(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

bool _hasClassPart(dom.Element e, String part) => e.classes.any((c) => c.contains(part));

dom.Element? _first(dom.Element root, List<String> selectors) {
  for (final s in selectors) {
    try {
      final r = root.querySelector(s);
      if (r != null) return r;
    } catch (_) {}
  }
  return null;
}

List<dom.Element> _all(dom.Element root, List<String> selectors) {
  for (final s in selectors) {
    try {
      final r = root.querySelectorAll(s);
      if (r.isNotEmpty) return r;
    } catch (_) {}
  }
  return const [];
}

/// Teacher files from `window.diaryData` (teacherFiles[taskId] = [{url, filename}]).
Map<String, List<Attachment>> parseDiaryDataFiles(String htmlSource) {
  final out = <String, List<Attachment>>{};
  final m = RegExp(r'window\.diaryData\s*=\s*(\{.*?\});\s*(?:window\.|</script>|\n)', dotAll: true)
      .firstMatch(htmlSource);
  if (m == null) return out;
  try {
    final data = jsonDecode(m.group(1)!);
    if (data is Map && data['teacherFiles'] is Map) {
      (data['teacherFiles'] as Map).forEach((k, v) {
        if (v is List) {
          out['$k'] = v
              .whereType<Map>()
              .where((f) => f['url'] != null)
              .map((f) => Attachment(name: '${f['filename'] ?? f['name'] ?? 'файл'}', url: absUrl('${f['url']}')))
              .toList();
        }
      });
    }
  } catch (_) {}
  return out;
}

bool _isFileHref(String href) {
  final h = href.trim().toLowerCase();
  if (h.isEmpty || h == '#' || h.startsWith('javascript') || h.startsWith('mailto')) return false;
  if (h.contains('/journal-app') && !h.contains('file')) return false;
  return true;
}

List<Attachment> _filesIn(dom.Element lesson) {
  final out = <Attachment>[];
  final seen = <String>{};
  for (final a in lesson.querySelectorAll('a[href]')) {
    final href = a.attributes['href'] ?? '';
    if (!_isFileHref(href)) continue;
    final url = absUrl(href);
    if (!seen.add(url)) continue;
    var name = cleanText(a.text);
    if (name.isEmpty) name = a.attributes['title'] ?? a.attributes['download'] ?? '';
    if (name.isEmpty) {
      final seg = Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const [];
      name = seg.isEmpty ? 'файл' : Uri.decodeComponent(seg.last);
    }
    out.add(Attachment(name: name, url: url));
  }
  return out;
}

List<Mark> _marksIn(dom.Element lesson, String subject, DateTime? date) {
  final out = <Mark>[];
  for (final m in lesson.querySelectorAll('.dnevnik-mark')) {
    final valueEl = m.querySelector('.dnevnik-mark__value');
    var value = cleanText(valueEl?.text ?? m.text);
    final weightEl = m.querySelector('.dnevnik-mark__weight');
    final weightText = cleanText(weightEl?.text ?? '');
    if (weightEl != null && valueEl == null) {
      value = cleanText(value.replaceFirst(weightText, ''));
    }
    if (value.isEmpty) continue;
    final weight = double.tryParse(weightText.replaceAll(RegExp(r'[^0-9.,]'), '').replaceAll(',', '.')) ?? 1;
    var kind = 'lesson';
    if (valueEl != null && _hasClassPart(valueEl, '--hometask')) kind = 'hometask';
    if (valueEl != null && _hasClassPart(valueEl, '--comment')) kind = 'comment';
    final comment = cleanText(m.attributes['title'] ??
        m.attributes['data-comment'] ??
        valueEl?.attributes['title'] ??
        valueEl?.attributes['data-comment'] ??
        '');
    out.add(Mark(value: value, weight: weight, comment: comment, subject: subject, date: date, kind: kind));
  }
  return out;
}

class WeekParseResult {
  final List<Day> days;
  final bool loginPage;
  const WeekParseResult(this.days, {this.loginPage = false});
}

bool looksLikeLoginPage(String source) {
  return source.contains('ajaxauthorize') && !source.contains('dnevnik-day') ||
      source.contains('id="loginform"') ||
      RegExp(r'esiaUrl\s*=').hasMatch(source) && !source.contains('dnevnik');
}

WeekParseResult parseWeek(String source, {DateTime? now}) {
  if (looksLikeLoginPage(source)) return const WeekParseResult([], loginPage: true);
  final doc = html_parser.parse(source);
  final teacherFiles = parseDiaryDataFiles(source);
  final days = <Day>[];
  final dayEls = doc.querySelectorAll('.dnevnik-day');
  for (final d in dayEls) {
    final titleEl = _first(d, ['.dnevnik-day__title', '.dnevnik-day__header']);
    final title = cleanText(titleEl?.text ?? '');
    final date = parseDayTitle(title, now: now);
    if (date == null) continue;
    final holiday = _hasClassPart(d, '--holiday');
    final holidayText = cleanText(d.querySelector('.dnevnik-day__holiday')?.text ?? '');
    final lessons = <Lesson>[];
    for (final l in d.querySelectorAll('.dnevnik-lesson')) {
      final subjectEl = _first(l, ['.js-rt_licey-dnevnik-subject', '.dnevnik-lesson__subject span', '.dnevnik-lesson__subject']);
      final subject = cleanText(subjectEl?.text ?? '');
      if (subject.isEmpty) continue;
      final number = cleanText(l.querySelector('.dnevnik-lesson__number')?.text ?? '').replaceAll('.', '');
      final time = cleanText(l.querySelector('.dnevnik-lesson__time')?.text ?? '').replaceAll(' ', '');
      final topic = cleanText(l.querySelector('.dnevnik-lesson__topic')?.text ?? '');
      final tasks = _all(l, ['.dnevnik-lesson__task']);
      String hw;
      if (tasks.isNotEmpty) {
        hw = tasks.map(blockText).where((t) => t.isNotEmpty).join('\n');
      } else {
        hw = blockText(l.querySelector('.dnevnik-lesson__hometask'));
      }
      final files = _filesIn(l);
      for (final el in l.querySelectorAll('[data-task_id]')) {
        final id = el.attributes['data-task_id'];
        final extra = teacherFiles[id];
        if (extra != null) {
          for (final f in extra) {
            if (!files.any((x) => x.url == f.url)) files.add(f);
          }
        }
      }
      // File names often repeat inside the task text; strip those lines.
      if (files.isNotEmpty) {
        final names = files.map((f) => f.name.trim()).toSet();
        hw = hw.split('\n').where((line) => !names.contains(line.replaceFirst('• ', '').trim())).join('\n').trim();
      }
      lessons.add(Lesson(
        number: number,
        time: time,
        subject: subject,
        topic: topic,
        homework: hw,
        files: files,
        marks: _marksIn(l, subject, date),
      ));
    }
    days.add(Day(date: date, title: title, holiday: holiday, holidayText: holidayText, lessons: lessons));
  }
  return WeekParseResult(days);
}

/// Pupil id («u.12345») from links on any journal page.
String? findPupilId(String source) {
  final patterns = [
    RegExp(r'journal-student-grades-action/(u\.\d+)'),
    RegExp(r'journal-app/(u\.\d+)/'),
    RegExp(r'journal-student-resultmarks-action/(u\.\d+)'),
  ];
  for (final p in patterns) {
    final m = p.firstMatch(source);
    if (m != null) return m.group(1);
  }
  final m = RegExp(r'"user"\s*:\s*"?(\d{2,})"?').firstMatch(source);
  if (m != null) return 'u.${m.group(1)}';
  return null;
}

/// A dev key, when a page exposes one (used only for the diagnostics hint).
bool pageMentionsDevkey(String source) => RegExp(r'devkey', caseSensitive: false).hasMatch(source);

final _markToken = RegExp(r'^(?:[1-5][+\-]?(?:/[1-5][+\-]?)*|Н|Б|П|ОП|УП|н|б|зач|незач|осв|неосв|✕|x)$');

GradesPage parseGrades(String source, {DateTime? now}) {
  final doc = html_parser.parse(source);
  final bySubject = <String, List<Mark>>{};
  final averages = <String, String>{};
  // Variant 1: <div mark_date="…" name="Subject">5</div>
  for (final e in doc.querySelectorAll('[mark_date]')) {
    final subject = cleanText(e.attributes['name'] ?? '');
    final value = cleanText(e.text);
    if (subject.isEmpty || value.isEmpty) continue;
    final date = parseAnyDate(e.attributes['mark_date'] ?? '', now: now);
    final w = double.tryParse((e.attributes['weight'] ?? e.attributes['data-weight'] ?? '').replaceAll(',', '.')) ?? 1;
    bySubject.putIfAbsent(subject, () => []).add(Mark(
        value: value,
        subject: subject,
        date: date,
        weight: w,
        comment: cleanText(e.attributes['title'] ?? e.attributes['comment'] ?? '')));
  }
  // Variant 2: a table, subject in the first cell, marks in the others.
  if (bySubject.isEmpty) {
    for (final tr in doc.querySelectorAll('tr')) {
      final cells = tr.querySelectorAll('td');
      if (cells.length < 2) continue;
      final subject = cleanText(cells.first.text);
      if (subject.isEmpty || subject.length > 80 || RegExp(r'^\d+$').hasMatch(subject)) continue;
      final marks = <Mark>[];
      String avg = '';
      for (final c in cells.skip(1)) {
        final text = cleanText(c.text);
        if (text.isEmpty) continue;
        if (_hasClassPart(c, 'avg') || _hasClassPart(c, 'average') || RegExp(r'^\d[.,]\d{1,2}$').hasMatch(text)) {
          avg = text;
          continue;
        }
        for (final tok in text.split(RegExp(r'[\s,;]+'))) {
          if (_markToken.hasMatch(tok)) marks.add(Mark(value: tok, subject: subject));
        }
      }
      if (marks.isNotEmpty || avg.isNotEmpty) {
        bySubject.putIfAbsent(subject, () => []).addAll(marks);
        if (avg.isNotEmpty) averages[subject] = avg;
      }
    }
  }
  final periods = <PeriodLink>[];
  final seen = <String>{};
  for (final a in doc.querySelectorAll('a[href*="sp."]')) {
    final href = a.attributes['href'] ?? '';
    if (!href.contains('grades')) continue;
    final label = cleanText(a.text);
    if (label.isEmpty || !seen.add(href)) continue;
    final selected = a.classes.any((c) => c.contains('active') || c.contains('selected') || c.contains('current'));
    periods.add(PeriodLink(label: label, path: href, selected: selected));
  }
  final title = cleanText(_first(doc.documentElement!, ['.page-title', 'h1', 'h2'])?.text ?? '');
  return GradesPage(
    subjects: bySubject.entries
        .map((e) => SubjectMarks(subject: e.key, marks: e.value, average: averages[e.key] ?? ''))
        .toList(),
    periods: periods,
    periodTitle: title,
    fetchedAt: DateTime.now(),
  );
}

FinalsTable parseFinals(String source) {
  final doc = html_parser.parse(source);
  dom.Element? best;
  int bestRows = 0;
  for (final t in doc.querySelectorAll('table')) {
    final n = t.querySelectorAll('tr').length;
    if (n > bestRows) {
      bestRows = n;
      best = t;
    }
  }
  if (best == null) return FinalsTable(headers: const [], rows: const [], fetchedAt: DateTime.now());
  final trs = best.querySelectorAll('tr');
  var headers = <String>[];
  final rows = <FinalsRow>[];
  for (final tr in trs) {
    final ths = tr.querySelectorAll('th');
    final tds = tr.querySelectorAll('td');
    if (ths.length > 1 && tds.isEmpty && headers.isEmpty) {
      headers = ths.skip(1).map((e) => cleanText(e.text)).toList();
      continue;
    }
    final cells = [...ths, ...tds];
    if (cells.length < 2) continue;
    final subject = cleanText(cells.first.text);
    if (subject.isEmpty) continue;
    final values = cells.skip(1).map((e) => cleanText(e.text)).toList();
    if (headers.isEmpty && rows.isEmpty && values.every((v) => !RegExp(r'\d|Н|зач').hasMatch(v))) {
      headers = values; // first row was the header
      continue;
    }
    rows.add(FinalsRow(subject, values));
  }
  return FinalsTable(headers: headers, rows: rows, fetchedAt: DateTime.now());
}

/// Page structure without personal text: tags, classes, ids (digits masked),
/// attribute names and text lengths only. For «Диагностика» export.
String sanitizedStructure(String source, {int maxLines = 4000}) {
  final doc = html_parser.parse(source);
  final lines = <String>[];
  String mask(String s) => s.replaceAll(RegExp(r'\d'), '#');
  void walk(dom.Element e, int depth) {
    if (lines.length >= maxLines) return;
    final tag = e.localName ?? '?';
    final b = StringBuffer('${'  ' * depth}$tag');
    final id = e.attributes['id'];
    if (id != null && id.isNotEmpty) b.write('#${mask(id)}');
    for (final c in e.classes) {
      b.write('.${mask(c)}');
    }
    final attrs = e.attributes.keys
        .map((k) => '$k')
        .where((k) => k != 'class' && k != 'id' && k != 'style')
        .toList();
    if (attrs.isNotEmpty) b.write(' [${attrs.join(',')}]');
    if (tag == 'a') {
      final href = e.attributes['href'] ?? '';
      final path = Uri.tryParse(href)?.path ?? '';
      if (path.isNotEmpty) b.write(' href=${mask(path)}');
    }
    final ownText = e.nodes.whereType<dom.Text>().map((t) => t.text.trim()).join();
    if (ownText.isNotEmpty) b.write(' {text:${ownText.length}}');
    if (tag == 'script') {
      final names = RegExp(r'window\.([A-Za-z_]\w*)\s*=').allMatches(e.text).map((m) => m.group(1)).toSet();
      if (names.isNotEmpty) b.write(' vars=${names.join(',')}');
      lines.add(b.toString());
      return;
    }
    if (tag == 'style' || tag == 'svg') {
      lines.add(b.toString());
      return;
    }
    lines.add(b.toString());
    for (final c in e.children) {
      walk(c, depth + 1);
    }
  }

  final root = doc.documentElement;
  if (root != null) walk(root, 0);
  if (lines.length >= maxLines) lines.add('… (обрезано)');
  return lines.join('\n');
}
