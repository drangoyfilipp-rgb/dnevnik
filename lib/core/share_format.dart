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
