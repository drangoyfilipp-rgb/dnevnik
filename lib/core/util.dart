// Small pure helpers shared by the parsers and the UI.

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

String cleanText(String s) {
  var t = s.replaceAll('\u00a0', ' ').replaceAll('\r', '');
  t = t.split('\n').map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim()).join('\n');
  t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return t.trim();
}

/// Text of an HTML fragment keeping line breaks from <br>, <p>, <li>, <div>.
/// Plain text (no tags) is returned cleaned.
String htmlToText(String source) {
  if (!source.contains('<')) return cleanText(_decodeEntities(source));
  final frag = html_parser.parseFragment(source);
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
    } else if (n is dom.DocumentFragment) {
      for (final c in n.nodes) {
        walk(c);
      }
    }
  }

  walk(frag);
  return cleanText(buf.toString());
}

String _decodeEntities(String s) => s
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

DateTime mondayOf(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Loose date parser for API values: ISO dates/datetimes (with or without zone),
/// «DD.MM.YYYY», epoch seconds/milliseconds. Returns local time.
DateTime? parseLooseDateTime(dynamic v) {
  if (v == null) return null;
  if (v is num) {
    if (v <= 0) return null;
    final ms = v > 100000000000 ? v.toInt() : (v * 1000).toInt();
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
  if (v is! String) return null;
  final s = v.trim();
  if (s.isEmpty) return null;
  if (RegExp(r'^\d{9,13}$').hasMatch(s)) return parseLooseDateTime(int.parse(s));
  final iso = RegExp(r'^\d{4}-\d{2}-\d{2}').firstMatch(s);
  // An explicit offset (+03:00) is the school's own wall clock: keep it literally,
  // so the date/time does not move with the phone's time zone.
  final wall = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{1,2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*[+-]\d{2}:?\d{2}$').firstMatch(s);
  if (wall != null) {
    int g(int i) => int.tryParse(wall.group(i) ?? '') ?? 0;
    return DateTime(g(1), g(2), g(3), g(4), g(5), g(6));
  }
  if (iso != null) {
    final p = DateTime.tryParse(s.replaceFirst(' ', 'T'));
    if (p != null) return p.isUtc ? p.toLocal() : p;
    return DateTime.tryParse(iso.group(0)!);
  }
  final ru = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})(?:[ T](\d{1,2}):(\d{2}))?').firstMatch(s);
  if (ru != null) {
    return DateTime(int.parse(ru.group(3)!), int.parse(ru.group(2)!), int.parse(ru.group(1)!),
        int.tryParse(ru.group(4) ?? '') ?? 0, int.tryParse(ru.group(5) ?? '') ?? 0);
  }
  return null;
}

/// «08:00:00» / «8:00» / datetime → «08:00». Empty when unknown.
String parseLooseTime(dynamic v) {
  if (v == null) return '';
  if (v is String) {
    final t = RegExp(r'^\s*(\d{1,2}):(\d{2})(?::\d{2})?\s*$').firstMatch(v);
    if (t != null) return '${t.group(1)!.padLeft(2, '0')}:${t.group(2)}';
  }
  final d = parseLooseDateTime(v);
  if (d == null) return '';
  if (v is String && !RegExp(r'[T ]\d{1,2}:\d{2}').hasMatch(v)) return '';
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// Whether a string value carries a time of day (so it is a datetime, not a date).
bool hasTimePart(dynamic v) => v is String && RegExp(r'[T ]\d{1,2}:\d{2}').hasMatch(v);

String normSubject(String s) => s.toLowerCase().replaceAll('ё', 'е').replaceAll(RegExp(r'[^a-zа-я0-9]+'), '');

String ddmmhhmm(DateTime t) =>
    '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')} '
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
