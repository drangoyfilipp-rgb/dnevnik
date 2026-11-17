// WebView side of the «Госуслуги Моя школа» integration:
//  * a document-start user script that reports every /api/myschool/ call of the
//    official web app (method, url, body, headers, status, response) to Dart;
//  * copying the portal cookies (incl. httpOnly) + UA from the WebView;
//  * a headless WebView run used for silent re-login and as the data fallback.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'diagnostics.dart';
import 'myschool.dart';

const String kBridgeHandler = 'dnevnikApi';

const String kBridgeJs = r'''
(function () {
  if (window.__dnevnikHooked) return;
  window.__dnevnikHooked = true;
  var Q = [];
  var MAX = 6000000;
  function send(d) {
    try {
      var b = window.flutter_inappwebview;
      if (b && typeof b.callHandler === 'function') { b.callHandler('dnevnikApi', JSON.stringify(d)); }
      else { Q.push(d); }
    } catch (e) {}
  }
  window.addEventListener('flutterInAppWebViewPlatformReady', function () { var q = Q; Q = []; q.forEach(send); });
  function want(u) { try { return String(u).indexOf('/api/myschool/') >= 0; } catch (e) { return false; } }
  function abs(u) { try { return String(new URL(String(u), location.href)); } catch (e) { return String(u); } }
  function hdrs(h) {
    var o = {};
    try {
      if (!h) return o;
      if (typeof Headers !== 'undefined' && h instanceof Headers) { h.forEach(function (v, k) { o[k] = v; }); }
      else if (Array.isArray(h)) { h.forEach(function (p) { o[p[0]] = p[1]; }); }
      else { for (var k in h) { if (Object.prototype.hasOwnProperty.call(h, k)) o[k] = String(h[k]); } }
    } catch (e) {}
    return o;
  }
  var of = window.fetch;
  if (of) {
    window.fetch = function (input, init) {
      var p = of.apply(this, arguments);
      try {
        var url = (typeof input === 'string') ? input : ((input && input.url) || String(input));
        if (!want(url)) return p;
        var method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
        var body = (init && typeof init.body === 'string') ? init.body : null;
        var h = hdrs((init && init.headers) || (input && input.headers));
        var bodyP = Promise.resolve(body);
        if (body === null && input && typeof input.clone === 'function' && method !== 'GET') {
          bodyP = input.clone().text().catch(function () { return null; });
        }
        p.then(function (r) {
          var c = r.clone();
          Promise.all([c.text(), bodyP]).then(function (a) {
            send({k: 'fetch', m: method, u: abs(url), b: a[1], h: h, s: r.status, t: a[0].length > MAX ? null : a[0]});
          }).catch(function () {});
        }).catch(function (e) { send({k: 'fetch', m: method, u: abs(url), b: body, h: h, s: 0, t: null}); });
      } catch (e) {}
      return p;
    };
  }
  var X = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
  if (X) {
    var oOpen = X.open, oSend = X.send, oSet = X.setRequestHeader;
    X.open = function (m, u) { this.__d = {m: String(m || 'GET').toUpperCase(), u: abs(u), h: {}}; return oOpen.apply(this, arguments); };
    X.setRequestHeader = function (k, v) { try { if (this.__d) this.__d.h[k] = String(v); } catch (e) {} return oSet.apply(this, arguments); };
    X.send = function (b) {
      var d = this.__d, x = this;
      try {
        if (d && want(d.u)) {
          d.b = (typeof b === 'string') ? b : null;
          x.addEventListener('loadend', function () {
            var t = null;
            try {
              if (!x.responseType || x.responseType === 'text') t = x.responseText;
              else if (x.responseType === 'json') t = JSON.stringify(x.response);
            } catch (e) {}
            send({k: 'xhr', m: d.m, u: d.u, b: d.b, h: d.h, s: x.status, t: (t && t.length > MAX) ? null : t});
          });
        }
      } catch (e) {}
      return oSend.apply(this, arguments);
    };
  }
})();
''';

UnmodifiableListView<UserScript> bridgeScripts() => UnmodifiableListView([
      UserScript(source: kBridgeJs, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START, forMainFrameOnly: false),
    ]);

/// One API call captured inside the WebView.
class WebCapture {
  WebCapture(this.method, this.url, this.requestBody, this.headers, this.status, this.responseText);
  final String method;
  final String url;
  final String? requestBody;
  final Map<String, String> headers;
  final int status;
  final String? responseText;

  String get path => Uri.tryParse(url)?.path ?? url;
  bool get isDatamart => method == 'POST' && path.endsWith('/v1/datamart');

  dynamic get requestJson {
    try {
      return requestBody == null || requestBody!.isEmpty ? null : jsonDecode(requestBody!);
    } catch (_) {
      return null;
    }
  }

  dynamic get responseJson {
    try {
      return responseText == null || responseText!.isEmpty ? null : jsonDecode(responseText!);
    } catch (_) {
      return null;
    }
  }

  static WebCapture? parse(dynamic arg) {
    try {
      final m = arg is String ? jsonDecode(arg) : arg;
      if (m is! Map) return null;
      final h = <String, String>{};
      final hh = m['h'];
      if (hh is Map) hh.forEach((k, v) => h['$k'] = '$v');
      return WebCapture(
        '${m['m'] ?? 'GET'}'.toUpperCase(),
        '${m['u'] ?? ''}',
        m['b'] is String ? m['b'] as String : null,
        h,
        (m['s'] as num?)?.toInt() ?? 0,
        m['t'] is String ? m['t'] as String : null,
      );
    } catch (_) {
      return null;
    }
  }
}

class Bridge {
  /// Set by the repository: receives every captured API call.
  static void Function(WebCapture c)? onCapture;

  static final StreamController<WebCapture> _events = StreamController.broadcast();
  static Stream<WebCapture> get events => _events.stream;

  static void attach(InAppWebViewController c) {
    c.addJavaScriptHandler(
      handlerName: kBridgeHandler,
      callback: (args) {
        if (args.isEmpty) return null;
        final cap = WebCapture.parse(args.first);
        if (cap == null || !cap.url.contains(kMsApiPrefix)) return null;
        Diagnostics.instance.add('WebView ${cap.method} ${maskApiPath(cap.url)} → ${cap.status}');
        Diagnostics.instance.api(cap.method, cap.url, cap.status, cap.requestJson, cap.responseJson,
            via: 'webview', headerNames: cap.headers.keys);
        try {
          onCapture?.call(cap);
        } catch (e) {
          Diagnostics.instance.error('перехват', e);
        }
        _events.add(cap);
        return null;
      },
    );
  }

  static void notePage(WebUri? url) {
    if (url == null) return;
    final u = Uri.tryParse(url.toString());
    if (u == null) return;
    if (u.host.endsWith('gosuslugi.ru')) Diagnostics.instance.webPages.add(maskPath(u.toString()));
  }

  static bool isSchoolPage(Uri u) => u.host == 'www.gosuslugi.ru' && u.path.startsWith('/school');
  static bool isEsiaPage(Uri u) => u.host.startsWith('esia.') || u.path.startsWith('/login') || u.path.contains('/esia');

  /// All portal cookies the WebView holds (httpOnly included).
  static Future<Map<String, String>> portalCookies() async {
    final map = <String, String>{};
    for (final url in const [
      'https://www.gosuslugi.ru/',
      'https://www.gosuslugi.ru/school/feed',
      'https://www.gosuslugi.ru/api/myschool/v1/datamart',
    ]) {
      try {
        final list = await CookieManager.instance().getCookies(url: WebUri(url));
        for (final c in list) {
          final v = '${c.value ?? ''}';
          if (c.name.isNotEmpty && v.isNotEmpty) map[c.name] = v;
        }
      } catch (e) {
        Diagnostics.instance.error('cookies', e);
      }
    }
    return map;
  }

  static Future<String?> userAgent(InAppWebViewController c) async {
    try {
      final ua = await c.evaluateJavascript(source: 'navigator.userAgent');
      return ua is String && ua.isNotEmpty ? ua : null;
    } catch (_) {
      return null;
    }
  }
}

class HarvestResult {
  bool signedIn = false;
  bool loginWall = false;
  int datamart = 0;
  Map<String, String> cookies = {};
  String? userAgent;
  @override
  String toString() => 'вход=${signedIn ? 'да' : 'нет'}, стена входа=${loginWall ? 'да' : 'нет'}, ответов datamart=$datamart';
}

/// Opens www.gosuslugi.ru/school/feed in a hidden WebView (same cookie store as the
/// login screen): refreshes acc_t through ESIA SSO when possible and lets the web app
/// load its data, which the bridge captures.
Future<HarvestResult> runHeadlessHarvest({Duration timeout = const Duration(seconds: 30)}) async {
  final r = HarvestResult();
  DateTime? lastData;
  DateTime? esiaSince;
  Uri? current;
  final sub = Bridge.events.listen((c) {
    if (c.isDatamart && c.status >= 200 && c.status < 300) {
      r.datamart++;
      lastData = DateTime.now();
    }
  });
  InAppWebViewController? ctl;
  final hw = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(kMsFeedUrl)),
    initialUserScripts: bridgeScripts(),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      thirdPartyCookiesEnabled: true,
      saveFormData: false,
      cacheEnabled: true,
    ),
    onWebViewCreated: (c) {
      ctl = c;
      Bridge.attach(c);
    },
    onUpdateVisitedHistory: (c, url, _) {
      Bridge.notePage(url);
      if (url != null) current = Uri.tryParse(url.toString());
    },
    onLoadStop: (c, url) {
      Bridge.notePage(url);
      if (url != null) current = Uri.tryParse(url.toString());
    },
  );
  final sw = Stopwatch()..start();
  try {
    await hw.run();
    while (sw.elapsed < timeout) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final u = current;
      if (u != null && Bridge.isEsiaPage(u)) {
        esiaSince ??= DateTime.now();
        if (DateTime.now().difference(esiaSince).inSeconds >= 8) {
          r.loginWall = true;
          break;
        }
      } else {
        esiaSince = null;
      }
      if (u != null && Bridge.isSchoolPage(u) && lastData != null && DateTime.now().difference(lastData!).inSeconds >= 3) {
        break;
      }
    }
    final u = current;
    r.cookies = await Bridge.portalCookies();
    r.signedIn = u != null && Bridge.isSchoolPage(u) && (r.cookies['acc_t'] ?? '').isNotEmpty && !r.loginWall;
    final c = ctl;
    if (c != null) r.userAgent = await Bridge.userAgent(c);
  } catch (e) {
    Diagnostics.instance.error('скрытый WebView', e);
  } finally {
    await sub.cancel();
    try {
      await hw.dispose();
    } catch (_) {}
  }
  Diagnostics.instance.add('Скрытый WebView (${sw.elapsed.inSeconds} с): $r');
  return r;
}
