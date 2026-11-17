// Clean share text: date, subject, task, file names. No ad signatures,
// no duplicated lines, no long tracking URLs.

import 'models.dart';

const _weekdaysShort = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

String shortDate(DateTime d) =>
    '${_weekdaysShort[d.weekday - 1]}, ${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';

final _adPatterns = <RegExp>[
  RegExp(r'^(отправлено|sent) (из|from|с помощью)\b', caseSensitive: false),
  RegExp(r'(госуслуги\s*моя\s*школа|элжур|eljur|скачайте приложение|download the app)', caseSensitive: false),
  RegExp(r'^-{2,}\s*$'),
];

final _urlRe = RegExp(r'https?://[^\s<>()]+', caseSensitive: false);

/// Shortens long URLs to «host/…»; keeps short ones as they are.
String tidyUrls(String text, {int maxLen = 40}) {
  return text.replaceAllMapped(_urlRe, (m) {
    final url = m.group(0)!;
    if (url.length <= maxLen) return url;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return '${uri.host}/…';
  });
}

/// Removes ad lines, duplicates and blank runs from free text.
String cleanShareBody(String text) {
  final out = <String>[];
  final seen = <String>{};
  for (var line in text.replaceAll('\r', '').split('\n')) {
    line = line.trim();
    if (line.isEmpty) {
      if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
      continue;
    }
    if (_adPatterns.any((p) => p.hasMatch(line))) continue;
    line = tidyUrls(line);
    final key = line.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (!seen.add(key)) continue;
    out.add(line);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out.join('\n');
}

String shareLessonText(Lesson l, DateTime date, {bool includeTopic = false}) {
  final b = StringBuffer('${shortDate(date)} · ${l.subject}');
  if (includeTopic && l.topic.isNotEmpty) b.write('\nТема: ${cleanShareBody(l.topic)}');
  final hw = cleanShareBody(l.homework);
  if (hw.isNotEmpty) b.write('\nДЗ: $hw');
  final names = <String>{};
  for (final f in l.files) {
    final n = f.name.trim();
    if (n.isNotEmpty) names.add(n);
  }
  if (names.isNotEmpty) b.write('\nФайлы: ${names.join(', ')}');
  return b.toString();
}

String shareDayText(Day d, {bool onlyHomework = true}) {
  final lessons = d.lessons.where((l) => !onlyHomework || l.hasHomework).toList();
  final b = StringBuffer(shortDate(d.date));
  final seen = <String>{};
  for (final l in lessons) {
    final hw = cleanShareBody(l.homework);
    final names = l.files.map((f) => f.name.trim()).where((n) => n.isNotEmpty).toSet();
    final line = '${l.subject}: ${hw.isEmpty ? '' : hw}${names.isEmpty ? '' : '${hw.isEmpty ? '' : ' '}(файлы: ${names.join(', ')})'}';
    if (!seen.add(line)) continue;
    b.write('\n• $line');
  }
  return b.toString();
}

String _num(double w) => w % 1 == 0 ? w.toInt().toString() : w.toString();

String _avgText(double a) => a.toStringAsFixed(2).replaceAll('.', ',');

/// A whole day: every lesson (number, time, room) with its homework, files and marks.
String shareDayFull(Day d) {
  final b = StringBuffer(shortDate(d.date));
  final lessons = d.lessons.where((l) => l.isLesson).toList();
  final extra = d.lessons.where((l) => !l.isLesson && l.hasHomework).toList();
  if (lessons.isEmpty && extra.isEmpty) {
    b.write('\nУроков нет');
    return b.toString();
  }
  for (final l in lessons) {
    final head = [
      '${l.number.isEmpty ? '•' : '${l.number}.'} ${l.subject}',
      if (l.time.isNotEmpty) l.time,
      if (l.room.isNotEmpty) 'каб. ${l.room}',
    ].join(', ');
    b.write('\n$head');
    final hw = cleanShareBody(l.homework);
    if (hw.isNotEmpty) b.write('\n   ДЗ: ${hw.replaceAll('\n', '\n   ')}');
    final names = l.files.map((f) => f.name.trim()).where((n) => n.isNotEmpty).toSet();
    if (names.isNotEmpty) b.write('\n   Файлы: ${names.join(', ')}');
    if (l.marks.isNotEmpty) b.write('\n   Оценки: ${l.marks.map((m) => m.value).join(', ')}');
  }
  for (final l in extra) {
    final hw = cleanShareBody(l.homework);
    final names = l.files.map((f) => f.name.trim()).where((n) => n.isNotEmpty).toSet();
    b.write('\n• ${l.subject}: ${hw.isEmpty ? '' : hw}${names.isEmpty ? '' : ' (файлы: ${names.join(', ')})'}');
  }
  return b.toString();
}

/// One subject's marks: subject, period, each mark with date and kind, the average.
String shareSubjectMarks(SubjectMarks s, {String period = ''}) {
  final b = StringBuffer(period.isEmpty ? s.subject : '${s.subject} · $period');
  final avg = s.computedAverage;
  if (s.marks.isEmpty) {
    b.write('\nОценок нет');
    return b.toString();
  }
  b.write('\nОценки: ${s.marks.map((m) => m.weight == 1 ? m.value : '${m.value}×${_num(m.weight)}').join(', ')}');
  if (avg != null) b.write('\nСредний балл: ${_avgText(avg)}');
  for (final m in s.marks) {
    final date = m.date == null ? '' : '${m.date!.day.toString().padLeft(2, '0')}.${m.date!.month.toString().padLeft(2, '0')}';
    final info = [if (m.comment.isNotEmpty) cleanShareBody(m.comment), if (m.weight != 1) 'вес ${_num(m.weight)}'].join(', ');
    b.write('\n${date.isEmpty ? '' : '$date — '}${m.value}${info.isEmpty ? '' : ' ($info)'}');
  }
  return b.toString();
}

/// All subjects at once (Оценки → Поделиться).
String shareAllMarks(List<SubjectMarks> subjects, {String period = ''}) {
  final b = StringBuffer(period.isEmpty ? 'Оценки' : 'Оценки · $period');
  for (final s in subjects) {
    if (s.marks.isEmpty) continue;
    final avg = s.computedAverage;
    b.write('\n${s.subject}: ${s.marks.map((m) => m.value).join(' ')}${avg == null ? '' : ' — ${_avgText(avg)}'}');
  }
  return b.toString();
}
