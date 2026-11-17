import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/diagnostics.dart';
import '../services.dart';
import 'widgets.dart';

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  Future<String> _version() async {
    final i = await PackageInfo.fromPlatform();
    return '${i.version} (сборка ${i.buildNumber})';
  }

  Future<void> _export(BuildContext context) async {
    final repo = Services.I.repo;
    // Make sure the main pages are in memory before exporting their structure.
    if (repo.loggedIn && Diagnostics.instance.pageKinds.length < 3) {
      await repo.loadWeek(0, force: true);
      await repo.loadGrades();
      await repo.loadFinals();
    }
    final text = Diagnostics.instance.structureExport(appVersion: await _version());
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/dnevnik-diagnostika.txt');
    await f.writeAsString(text);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(f.path, mimeType: 'text/plain')],
      text: 'Диагностика Дневника (только структура страниц, без оценок и имён)',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final d = Diagnostics.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Диагностика')),
      body: ListenableBuilder(
        listenable: d,
        builder: (context, _) => FutureBuilder<String>(
          future: _version(),
          builder: (context, snap) {
            final report = d.report(appVersion: snap.data ?? '');
            return ListView(padding: const EdgeInsets.all(16), children: [
              Card(
                child: ListTile(
                  leading: Icon(d.lastError == null ? Icons.check_circle_outline : Icons.error_outline,
                      color: d.lastError == null ? Colors.green : Theme.of(context).colorScheme.error),
                  title: Text(d.lastError == null ? 'Ошибок нет' : 'Последняя ошибка'),
                  subtitle: d.lastError == null
                      ? null
                      : SelectableText('${d.lastError}\n${d.lastErrorAt == null ? '' : timeAgo(d.lastErrorAt!)}'),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => _export(context),
                icon: const Icon(Icons.ios_share),
                label: const Text('Экспорт структуры страниц'),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'В файл попадают только теги, классы и длины текста страниц журнала — без оценок, имён и заданий. '
                  'Отправьте его, если что-то не отображается.',
                ),
              ),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                      onPressed: () => copyText(context, report), icon: const Icon(Icons.copy), label: const Text('Копировать отчёт')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                      onPressed: () {
                        d.log.clear();
                        d.lastError = null;
                        d.lastErrorAt = null;
                        d.add('Журнал очищен');
                      },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Очистить')),
                ),
              ]),
              const SizedBox(height: 12),
              SelectableText(report, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ]);
          },
        ),
      ),
    );
  }
}
