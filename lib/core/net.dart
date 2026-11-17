import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'diagnostics.dart';
import 'parser.dart';

class SessionExpired implements Exception {
  @override
  String toString() => 'Сессия истекла — нужно войти снова';
}

class HttpFailure implements Exception {
  final int status;
  final String path;
  HttpFailure(this.status, this.path);
  @override
  String toString() => 'Сервер ответил $status (${maskPath(path)})';
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

class EljurClient {
  final Map<String, String> cookies = {};
  String userAgent = kDefaultUa;
  bool Function() trustSchoolCert = () => true;

  HttpClient _client() {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 15)
      ..userAgent = userAgent;
    c.badCertificateCallback = (cert, host, port) {
      final ok = trustSchoolCert() && (host == 'lpr-reg.ru' || host.endsWith('.lpr-reg.ru'));
      Diagnostics.instance.certWarning =
          'недействительный сертификат у $host (до ${cert.endValidity.toIso8601String().substring(0, 10)}), ${ok ? 'разрешено настройкой' : 'отклонено'}';
      return ok;
    };
    return c;
  }

  String get cookieHeader => cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void setCookiesFromHeader(String raw) {
    for (final part in raw.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      cookies[part.substring(0, i).trim()] = part.substring(i + 1).trim();
    }
  }

  void _absorb(HttpClientResponse r) {
    for (final c in r.cookies) {
      if (c.value.isEmpty || c.value == 'deleted') {
        cookies.remove(c.name);
      } else {
        cookies[c.name] = c.value;
      }
    }
  }

  Future<HttpClientResponse> _open(HttpClient client, Uri uri, {String? referer}) async {
    var current = uri;
    for (var i = 0; i < 8; i++) {
      final req = await client.getUrl(current);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.acceptLanguageHeader, 'ru-RU,ru;q=0.9');
      req.headers.set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml,application/json,*/*;q=0.8');
      if (cookies.isNotEmpty && current.host.endsWith('lpr-reg.ru')) {
        req.headers.set(HttpHeaders.cookieHeader, cookieHeader);
      }
      if (referer != null) req.headers.set(HttpHeaders.refererHeader, referer);
      final res = await req.close().timeout(const Duration(seconds: 40));
      _absorb(res);
      if (res.isRedirect || (res.statusCode >= 300 && res.statusCode < 400)) {
        final loc = res.headers.value(HttpHeaders.locationHeader);
        await res.drain<void>();
        if (loc == null) throw HttpFailure(res.statusCode, current.path);
        final next = current.resolve(loc);
        if (next.path.startsWith('/authorize') || next.host.contains('esia.gosuslugi')) {
          throw SessionExpired();
        }
        current = next;
        continue;
      }
      return res;
    }
    throw HttpFailure(310, uri.path);
  }

  Future<String> getPage(String pathOrUrl, {String kind = 'page'}) async {
    final uri = Uri.parse(absUrl(pathOrUrl));
    final sw = Stopwatch()..start();
    final client = _client();
    try {
      final res = await _open(client, uri, referer: '$kBaseUrl/journal-app');
      final body = await res.transform(utf8.decoder).join();
      Diagnostics.instance.add('GET ${maskPath(uri.path)} → ${res.statusCode}, ${body.length} б, ${sw.elapsedMilliseconds} мс');
      if (res.statusCode >= 400) throw HttpFailure(res.statusCode, uri.path);
      Diagnostics.instance.page(kind, body);
      if (looksLikeLoginPage(body)) throw SessionExpired();
      return body;
    } finally {
      client.close();
    }
  }

  /// Downloads [url] into [dir]. Returns the saved file (original name when the server gives one).
  Future<File> download(String url, Directory dir,
      {required String fallbackName, void Function(int received, int? total)? onProgress}) async {
    final uri = Uri.parse(absUrl(url));
    final client = _client();
    try {
      final res = await _open(client, uri, referer: '$kBaseUrl/journal-app');
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
        // The school answered with a page instead of the file: likely a login wall.
        final body = await res.transform(utf8.decoder).join();
        if (looksLikeLoginPage(body)) throw SessionExpired();
        Diagnostics.instance.page('file-html', body);
        throw HttpFailure(415, uri.path);
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
      Diagnostics.instance.add('Файл ${maskPath(uri.path)} → $got б');
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
