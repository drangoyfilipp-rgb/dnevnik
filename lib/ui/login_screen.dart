import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/bridge.dart';
import '../core/diagnostics.dart';
import '../core/myschool.dart';
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
                  ? 'Сессия Госуслуг закончилась. Войдите снова — сохранённые данные никуда не делись.'
                  : 'Расписание, задания и оценки из «Госуслуги Моя школа».',
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
              'Вход идёт на официальной странице Госуслуг (gosuslugi.ru/school). Приложение не видит и не сохраняет '
              'пароль — на этом телефоне хранится только сессия.',
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

/// Official www.gosuslugi.ru/school web app in a WebView with the API bridge.
/// [browse] = «Дневник Госуслуг» from «Ещё»: no auto-close, data is captured while browsing.
class LoginWebView extends StatefulWidget {
  const LoginWebView({super.key, this.browse = false});
  final bool browse;
  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView> {
  double _progress = 0;
  String _host = '';
  bool _signedIn = false;
  bool _closing = false;
  int _datamart = 0;
  InAppWebViewController? _c;
  StreamSubscription<WebCapture>? _sub;
  Timer? _hintTimer;
  bool _showHint = false;

  @override
  void initState() {
    super.initState();
    _sub = Bridge.events.listen((cap) {
      if (cap.isDatamart && cap.status >= 200 && cap.status < 300) {
        _datamart++;
        if (mounted) setState(() {});
        if (_signedIn && !widget.browse) {
          // Give the web app a moment to load the rest of its data, then return.
          Timer(const Duration(seconds: 3), _finish);
        }
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _hintTimer?.cancel();
    super.dispose();
  }

  Future<void> _check(InAppWebViewController c, WebUri? url) async {
    Bridge.notePage(url);
    if (url == null) return;
    final u = Uri.parse(url.toString());
    Diagnostics.instance.add('WebView: ${maskPath(u.toString())}');
    if (_signedIn || !Bridge.isSchoolPage(u)) return;
    final cookies = await Bridge.portalCookies();
    if ((cookies['acc_t'] ?? '').isEmpty) return;
    _signedIn = true;
    await Services.I.repo.saveSession(cookies, await Bridge.userAgent(c));
    await CookieKeeper.persist();
    if (!mounted) return;
    setState(() {});
    if (!widget.browse) {
      _hintTimer = Timer(const Duration(seconds: 12), () {
        if (mounted) setState(() => _showHint = true);
      });
    }
  }

  Future<void> _finish() async {
    if (_closing || !mounted) return;
    _closing = true;
    final cookies = await Bridge.portalCookies();
    final c = _c;
    if ((cookies['acc_t'] ?? '').isNotEmpty) {
      await Services.I.repo.saveSession(cookies, c == null ? null : await Bridge.userAgent(c));
      await CookieKeeper.persist();
    }
    if (!mounted) return;
    if (widget.browse) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
    Services.I.repo.refreshAll();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final c = _c;
        if (c != null && await c.canGoBack()) {
          await c.goBack();
        } else if (context.mounted) {
          if (_signedIn) {
            _finish();
          } else {
            Navigator.of(context).pop();
          }
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.browse ? 'Дневник Госуслуг' : (_host.isEmpty ? 'Вход' : _host), style: const TextStyle(fontSize: 16)),
          actions: [
            if (_signedIn || widget.browse) TextButton(onPressed: _finish, child: const Text('Готово')),
          ],
          bottom: _progress < 1
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(3),
                  child: LinearProgressIndicator(value: _progress == 0 ? null : _progress))
              : null,
        ),
        body: Column(children: [
          if (_signedIn && !widget.browse)
            Material(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  _showHint && _datamart == 0
                      ? 'Если Госуслуги просят выбрать регион или дать согласие — пройдите шаги и откройте дневник, затем нажмите «Готово».'
                      : 'Вход выполнен — загружаю дневник…',
                  style: t.bodySmall,
                ),
              ),
            ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(kMsFeedUrl)),
              initialUserScripts: bridgeScripts(),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                thirdPartyCookiesEnabled: true,
                saveFormData: false,
                cacheEnabled: true,
                supportZoom: true,
              ),
              onWebViewCreated: (c) {
                _c = c;
                Bridge.attach(c);
              },
              onProgressChanged: (c, p) => setState(() => _progress = p / 100),
              onLoadStart: (c, url) => setState(() => _host = url?.host ?? ''),
              onLoadStop: _check,
              onUpdateVisitedHistory: (c, url, reload) => _check(c, url),
              onReceivedError: (c, req, err) {
                if (req.isForMainFrame ?? true) {
                  Diagnostics.instance.error('WebView', '${err.type} ${err.description} (${maskPath(req.url.toString())})');
                }
              },
            ),
          ),
        ]),
      ),
    );
  }
}
