import 'package:flutter/foundation.dart';

import 'parser.dart';

class LogEntry {
  final DateTime time;
  final String text;
  LogEntry(this.text) : time = DateTime.now();
  @override
  String toString() => '${_hms(time)} $text';
}

String _hms(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

/// Masks digits in paths so ids do not leave the device.
String maskPath(String urlOrPath) {
  final uri = Uri.tryParse(urlOrPath);
  final p = uri == null ? urlOrPath : (uri.host.isEmpty ? uri.path : '${uri.host}${uri.path}');
  return p.replaceAll(RegExp(r'\d{3,}'), '#');
}

class Diagnostics extends ChangeNotifier {
  Diagnostics._();
  static final Diagnostics instance = Diagnostics._();

  final List<LogEntry> log = [];
  String? lastError;
  DateTime? lastErrorAt;
  String? certWarning;
  bool devkeySeen = false;

  /// Last raw page per kind (memory only, never written to disk).
  final Map<String, String> _pages = {};

  void add(String text) {
    log.add(LogEntry(text));
    if (log.length > 200) log.removeRange(0, log.length - 200);
    notifyListeners();
  }

  void error(String where, Object e) {
    lastError = '$where: $e';
    lastErrorAt = DateTime.now();
    add('ОШИБКА $where: $e');
  }

  void page(String kind, String source) {
    _pages[kind] = source;
    if (pageMentionsDevkey(source)) devkeySeen = true;
  }

  List<String> get pageKinds => _pages.keys.toList();

  String report({String appVersion = ''}) {
    final b = StringBuffer('Дневник — диагностика\n');
    if (appVersion.isNotEmpty) b.writeln('Версия: $appVersion');
    b.writeln('Время: ${DateTime.now().toIso8601String()}');
    b.writeln('Последняя ошибка: ${lastError ?? 'нет'}${lastErrorAt == null ? '' : ' (${lastErrorAt!.toIso8601String()})'}');
    if (certWarning != null) b.writeln('Сертификат: $certWarning');
    b.writeln('devkey на страницах: ${devkeySeen ? 'встречается' : 'нет'}');
    b.writeln('\nЖурнал:');
    for (final e in log.reversed.take(80)) {
      b.writeln(e.toString());
    }
    return b.toString();
  }

  /// Structure of the last fetched pages without personal text.
  String structureExport({String appVersion = ''}) {
    final b = StringBuffer(report(appVersion: appVersion));
    if (_pages.isEmpty) {
      b.writeln('\n(страницы ещё не загружались)');
    }
    _pages.forEach((kind, src) {
      b.writeln('\n===== СТРАНИЦА: $kind (${src.length} байт) =====');
      b.writeln(sanitizedStructure(src));
    });
    return b.toString();
  }
}
