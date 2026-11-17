import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'diagnostics.dart';
import 'myschool.dart';

class SessionExpired implements Exception {
  @override
  String toString() => 'Сессия Госуслуг истекла — нужно войти снова';
}

/// The server answered with an HTML page (anti-bot check / login) instead of JSON.
class NotJson implements Exception {
  final int status;
  final String path;
  NotJson(this.status, this.path);
  @override
  String toString() => 'Вместо данных пришла страница ($status, ${maskApiPath(path)})';
}

/// No network / server unreachable.
bool isOfflineError(Object e) =>
    e is SocketException || e is TimeoutException || (e is HttpException && e.message.contains('Connection'));

class HttpFailure implements Exception {
  final int status;
  final String path;
  HttpFailure(this.status, this.path);
  @override
  String toString() => 'Сервер ответил $status (${maskApiPath(path)})';
}

const String kDefaultUa =
    'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

/// Decodes a file name from a Content-Disposition header.
String? filenameFromContentDisposition(String? header) {
  if (header == null || header.isEmpty) return null;
  final star = RegExp(r"filename\*\s*=\s*([^']*)'[^']*'([^;]+)", caseSensitive: false).firstMatch(header);
  if (star != null) {
    final enc = (star.group(1) ?? '').toLowerCase();
    final raw = star.group(2)!.trim().replaceAll('"', '');
    try {
      if (enc.isEmpty || enc == 'utf-8') return Uri.decodeComponent(raw);
      return utf8.decode(Uri.decodeComponent(raw).codeUnits, allowMalformed: true);
    } catch (_) {}
  }
  final plain = RegExp(r'filename\s*=\s*"?([^";]+)"?', caseSensitive: false).firstMatch(header);
  if (plain != null) {
    var name = plain.group(1)!.trim();
    if (name.contains('%')) {
      try {
        name = Uri.decodeComponent(name);
      } catch (_) {}
    }
    // Servers often send UTF-8 bytes as Latin-1 text.
    if (name.codeUnits.every((c) => c < 256) && name.codeUnits.any((c) => c >= 0x80)) {
      try {
        name = utf8.decode(latin1.encode(name));
      } catch (_) {}
    }
    return name;
  }
  return null;
}

String safeFileName(String name) {
  var n = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  if (n.isEmpty) n = 'файл';
  if (n.length > 120) {
    final dot = n.lastIndexOf('.');
    final ext = dot > 0 && n.length - dot <= 8 ? n.substring(dot) : '';
    n = n.substring(0, 120 - ext.length) + ext;
  }
  return n;
}

bool _isPortalHost(String host) => host == 'gosuslugi.ru' || host.endsWith('.gosuslugi.ru');

class MsResponse {
  MsResponse(this.status, this.json, this.length);
  final int status;
  final dynamic json;
  final int length;
}

/// HTTP client for www.gosuslugi.ru/api/myschool with the WebView's cookies and UA.
class MsClient {
  final Map<String, String> cookies = {};

  /// Extra request headers learned from the official web app (e.g. X-*).
  final Map<String, String> headers = {};
  String userAgent = kDefaultUa;

  bool get hasAccessCookie => (cookies['acc_t'] ?? '').isNotEmpty;

  HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 15)
    ..userAgent = userAgent;

  String get cookieHeader => cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void _absorb(HttpClientResponse r) {
    final raw = r.headers[HttpHeaders.setCookieHeader] ?? const <String>[];
    for (final line in raw) {
      final first = line.split(';').first;
      final i = first.indexOf('=');
      if (i <= 0) continue;
      final name = first.substring(0, i).trim();
      final value = first.substring(i + 1).trim();
      final expired = RegExp(r'max-age=0|expires=thu, 01 jan 1970', caseSensitive: false).hasMatch(line);
      if (value.isEmpty || value == 'deleted' || expired) {
        cookies.remove(name);
      } else {
        cookies[name] = value;
      }
    }
  }

  void _setHeaders(HttpClientRequest req, Uri uri, {bool json = true}) {
    req.followRedirects = false;
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'ru-RU,ru;q=0.9');
    if (json) req.headers.set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*');
    if (_isPortalHost(uri.host)) {
      if (cookies.isNotEmpty) req.headers.set(HttpHeaders.cookieHeader, cookieHeader);
      req.headers.set('Origin', kMsOrigin);
      req.headers.set(HttpHeaders.refererHeader, kMsFeedUrl);
      headers.forEach((k, v) {
        try {
          req.headers.set(k, v);
        } catch (_) {}
      });
    }
  }

  /// POST/GET JSON to the portal API. 202 = not ready yet → retried.
  Future<MsResponse> json(String method, String path, {Object? body}) async {
    final uri = Uri.parse(absMsUrl(path));
    final client = _client();
    final sw = Stopwatch()..start();
    try {
      for (var attempt = 0;; attempt++) {
        final req = await client.openUrl(method, uri).timeout(const Duration(seconds: 25));
        _setHeaders(req, uri);
        if (body != null) {
          final bytes = utf8.encode(jsonEncode(body));
          req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
          req.contentLength = bytes.length;
          req.add(bytes);
        }
        final res = await req.close().timeout(const Duration(seconds: 60));
        _absorb(res);
        final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 60));
        Diagnostics.instance.add('$method ${maskApiPath(uri.path)} → ${res.statusCode}, ${text.length} б, ${sw.elapsedMilliseconds} мс');
        if (res.statusCode == 401) throw SessionExpired();
        if (res.statusCode == 202 && attempt < 8) {
          await Future<void>.delayed(Duration(milliseconds: 800 + 700 * attempt));
          continue;
        }
        if (res.isRedirect || (res.statusCode >= 300 && res.statusCode < 400)) {
          final loc = res.headers.value(HttpHeaders.locationHeader) ?? '';
          if (loc.contains('esia') || loc.contains('login')) throw SessionExpired();
          throw HttpFailure(res.statusCode, uri.path);
        }
        dynamic parsed;
        try {
          parsed = text.isEmpty ? null : jsonDecode(text);
        } catch (_) {
          throw NotJson(res.statusCode, uri.path);
        }
        Diagnostics.instance.api(method, uri.path, res.statusCode, body, parsed, via: 'app');
        if (res.statusCode >= 400) throw HttpFailure(res.statusCode, uri.path);
        return MsResponse(res.statusCode, parsed, text.length);
      }
    } finally {
      client.close();
    }
  }

  /// True when the portal answers anything at all (used to notice the network came back).
  Future<bool> probe() async {
    final client = _client()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse('$kMsOrigin${kMsApiPrefix}v1/current_year')).timeout(const Duration(seconds: 10));
      req.followRedirects = false;
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>();
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpClientResponse> _openGet(HttpClient client, Uri uri) async {
    var current = uri;
    for (var i = 0; i < 8; i++) {
      final req = await client.getUrl(current);
      _setHeaders(req, current, json: false);
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      final res = await req.close().timeout(const Duration(seconds: 40));
      if (_isPortalHost(current.host)) _absorb(res);
      if (res.statusCode == 401) {
        await res.drain<void>();
        throw SessionExpired();
      }
      if (res.isRedirect || (res.statusCode >= 300 && res.statusCode < 400)) {
        final loc = res.headers.value(HttpHeaders.locationHeader);
        await res.drain<void>();
        if (loc == null) throw HttpFailure(res.statusCode, current.path);
        final next = current.resolve(loc);
        if (next.host.contains('esia.gosuslugi')) throw SessionExpired();
        current = next;
        continue;
      }
      return res;
    }
    throw HttpFailure(310, uri.path);
  }

  /// Downloads [url] into [dir]. Returns the saved file (original name when the server gives one).
  Future<File> download(String url, Directory dir,
      {required String fallbackName, void Function(int received, int? total)? onProgress}) async {
    final uri = Uri.parse(absMsUrl(url));
    final client = _client();
    try {
      final res = await _openGet(client, uri);
      if (res.statusCode >= 400) {
        await res.drain<void>();
        throw HttpFailure(res.statusCode, uri.path);
      }
      final ctype = res.headers.contentType?.mimeType ?? '';
      var name = filenameFromContentDisposition(res.headers.value('content-disposition')) ?? fallbackName;
      name = safeFileName(name);
      if (!name.contains('.')) {
        final ext = _extForMime(ctype);
        if (ext != null) name = '$name.$ext';
      }
      if (ctype == 'text/html' && !name.toLowerCase().endsWith('.html')) {
        await res.drain<void>();
        throw NotJson(415, uri.path);
      }
      await dir.create(recursive: true);
      final tmp = File('${dir.path}/.$name.part');
      final sink = tmp.openWrite();
      var got = 0;
      final total = res.contentLength > 0 ? res.contentLength : null;
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        onProgress?.call(got, total);
      }
      await sink.close();
      final target = File('${dir.path}/$name');
      if (await target.exists()) await target.delete();
      final saved = await tmp.rename(target.path);
      Diagnostics.instance.add('Файл ${maskApiPath(uri.toString())} → $got б');
      return saved;
    } finally {
      client.close();
    }
  }

  String? _extForMime(String m) => const {
        'application/pdf': 'pdf',
        'image/jpeg': 'jpg',
        'image/png': 'png',
        'application/msword': 'doc',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
        'application/vnd.ms-powerpoint': 'ppt',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'pptx',
        'application/vnd.ms-excel': 'xls',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
        'application/zip': 'zip',
        'text/plain': 'txt',
      }[m];
}
