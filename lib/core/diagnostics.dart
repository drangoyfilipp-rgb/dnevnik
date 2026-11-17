import 'package:flutter/foundation.dart';

import 'myschool.dart';

class LogEntry {
  final DateTime time;
  final String text;
  LogEntry(this.text) : time = DateTime.now();
  @override
  String toString() => '${_hms(time)} $text';
}

String _hms(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

/// Masks digits/uuids in paths so ids do not leave the device (host kept, query dropped).
String maskPath(String urlOrPath) {
  final uri = Uri.tryParse(urlOrPath);
  final host = uri == null || uri.host.isEmpty ? '' : uri.host;
  return '$host${maskApiPath(urlOrPath)}';
}

/// One API call seen (by the app or inside the WebView): path + key structure, no values.
class ApiShape {
  ApiShape(this.method, this.path, this.status, this.request, this.response, this.via, this.headerNames);
  final String method;
  final String path;
  final int status;
  final String request;
  final String response;
  final String via;
  final List<String> headerNames;
  final DateTime at = DateTime.now();
}

class Diagnostics extends ChangeNotifier {
  Diagnostics._();
  static final Diagnostics instance = Diagnostics._();

  final List<LogEntry> log = [];
  String? lastError;
  DateTime? lastErrorAt;

  /// Latest shape per «METHOD path [obj_types]» (memory only).
  final Map<String, ApiShape> shapes = {};

  /// Masked /school/* pages visited by the WebView (to know the web app's routes).
  final Set<String> webPages = {};

  void add(String text) {
    log.add(LogEntry(text));
    if (log.length > 300) log.removeRange(0, log.length - 300);
    notifyListeners();
  }

  void error(String where, Object e) {
    lastError = '$where: $e';
    lastErrorAt = DateTime.now();
    add('ОШИБКА $where: $e');
  }

  void api(String method, String url, int status, dynamic request, dynamic response,
      {String via = 'app', Iterable<String> headerNames = const []}) {
    final path = maskApiPath(url);
    final types = DatamartStore.itemsIn(request).map((i) => '${i['obj_type']}').toSet().toList()..sort();
    final key = '$via $method $path ${types.join(',')}';
    shapes[key] = ApiShape(
      method,
      path,
      status,
      request == null ? '' : shapeText(request),
      response == null ? '' : shapeText(response),
      via,
      headerNames.map((h) => h.toLowerCase()).toSet().toList()..sort(),
    );
    if (shapes.length > 60) shapes.remove(shapes.keys.first);
    notifyListeners();
  }

  String report({String appVersion = '', String state = ''}) {
    final b = StringBuffer('Дневник — диагностика\n');
    if (appVersion.isNotEmpty) b.writeln('Версия: $appVersion');
    b.writeln('Время: ${DateTime.now().toIso8601String()}');
    b.writeln('Последняя ошибка: ${lastError ?? 'нет'}${lastErrorAt == null ? '' : ' (${lastErrorAt!.toIso8601String()})'}');
    if (state.isNotEmpty) b.writeln(state);
    b.writeln('\nЖурнал:');
    for (final e in log.reversed.take(120)) {
      b.writeln(e.toString());
    }
    return b.toString();
  }

  /// Report + API paths with JSON key structure (types only, no values).
  String structureExport({String appVersion = '', String state = '', String store = ''}) {
    final b = StringBuffer(report(appVersion: appVersion, state: state));
    b.writeln('\n===== ДАННЫЕ (только счётчики) =====');
    b.writeln(store.isEmpty ? '(нет)' : store);
    b.writeln('\n===== СТРАНИЦЫ WEBVIEW =====');
    b.writeln(webPages.isEmpty ? '(нет)' : webPages.join('\n'));
    b.writeln('\n===== API: пути и структура JSON (без значений) =====');
    if (shapes.isEmpty) b.writeln('(запросов к /api/myschool/ ещё не было)');
    for (final s in shapes.values) {
      b.writeln('\n--- [${s.via}] ${s.method} ${s.path} → ${s.status}');
      if (s.headerNames.isNotEmpty) b.writeln('заголовки запроса: ${s.headerNames.join(', ')}');
      if (s.request.isNotEmpty) b.writeln('ЗАПРОС:\n${s.request}');
      if (s.response.isNotEmpty) b.writeln('ОТВЕТ:\n${_cap(s.response)}');
    }
    return b.toString();
  }

  String _cap(String s) => s.length > 30000 ? '${s.substring(0, 30000)}\n…(обрезано)' : s;
}
