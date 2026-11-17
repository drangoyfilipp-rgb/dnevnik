import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/diagnostics.dart';
import '../core/parser.dart';
import '../services.dart';
import 'diagnostics_screen.dart';

class LoginIntro extends StatelessWidget {
  const LoginIntro({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final repo = Services.I.repo;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Spacer(),
            Icon(Icons.menu_book_rounded, size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text('Дневник', style: t.headlineMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              repo.sessionExpired
                  ? 'Сессия школы закончилась. Войдите снова — сохранённые данные никуда не делись.'
                  : 'Расписание, задания и оценки из электронного журнала школы (school.lpr-reg.ru).',
              textAlign: TextAlign.center,
            ),
            const Spacer(),
            FilledButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('Войти через Госуслуги'),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginWebView())),
            ),
            const SizedBox(height: 12),
            Text(
              'Логин и пароль вводятся на официальной странице Госуслуг. Приложение их не видит и не сохраняет — '
              'хранится только сессия школы на этом телефоне.',
              style: t.bodySmall,
              textAlign: TextAlign.center,
            ),
            TextButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DiagnosticsScreen())),
              child: const Text('Диагностика'),
            ),
          ]),
        ),
      ),
    );
  }
}

class LoginWebView extends StatefulWidget {
  const LoginWebView({super.key});
  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView> {
  double _progress = 0;
  String _host = '';
  bool _finishing = false;

  static bool isFinalSchoolPage(Uri u) {
    if (!u.host.endsWith('lpr-reg.ru')) return false;
    final p = u.path;
    if (p.startsWith('/authorize') || p.startsWith('/journal-esia') || p.startsWith('/esia-redirect')) return false;
    return p == '/' || p.isEmpty || p.startsWith('/journal-');
  }

  Future<void> _maybeFinish(InAppWebViewController c, WebUri? url) async {
    if (url == null || _finishing) return;
    final u = Uri.parse(url.toString());
    Diagnostics.instance.add('Вход: ${maskPath(u.toString())}');
    if (!isFinalSchoolPage(u)) return;
    _finishing = true;
    try {
      final cookies = await CookieManager.instance().getCookies(url: WebUri(kBaseUrl));
      final map = <String, String>{for (final ck in cookies) ck.name: '${ck.value}'};
      final ua = await c.evaluateJavascript(source: 'navigator.userAgent');
      if (map.isEmpty) {
        Diagnostics.instance.error('вход', 'после входа нет cookies школы');
        _finishing = false;
        return;
      }
      await Services.I.repo.saveSession(map, ua is String ? ua : null);
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      Services.I.repo.refreshAll();
    } catch (e) {
      Diagnostics.instance.error('вход', e);
      _finishing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_host.isEmpty ? 'Вход' : _host, style: const TextStyle(fontSize: 16)),
        bottom: _progress < 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3), child: LinearProgressIndicator(value: _progress == 0 ? null : _progress))
            : null,
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri('$kBaseUrl/journal-esia-action/')),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          thirdPartyCookiesEnabled: true,
          saveFormData: false,
          clearCache: false,
          supportZoom: true,
        ),
        onProgressChanged: (c, p) => setState(() => _progress = p / 100),
        onLoadStart: (c, url) => setState(() => _host = url?.host ?? ''),
        onLoadStop: _maybeFinish,
        onUpdateVisitedHistory: (c, url, reload) => _maybeFinish(c, url),
        onReceivedServerTrustAuthRequest: (c, challenge) async {
          final host = challenge.protectionSpace.host;
          final ok = Services.I.settings.trustSchoolCert && (host == 'lpr-reg.ru' || host.endsWith('.lpr-reg.ru'));
          Diagnostics.instance.certWarning = 'WebView: ошибка сертификата у $host, ${ok ? 'разрешено' : 'отклонено'}';
          return ServerTrustAuthResponse(
              action: ok ? ServerTrustAuthResponseAction.PROCEED : ServerTrustAuthResponseAction.CANCEL);
        },
        onReceivedError: (c, req, err) {
          if (req.isForMainFrame ?? true) {
            Diagnostics.instance.error('вход WebView', '${err.type} ${err.description} (${maskPath(req.url.toString())})');
          }
        },
      ),
    );
  }
}
