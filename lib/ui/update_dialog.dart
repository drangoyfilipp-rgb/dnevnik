import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/diagnostics.dart';
import '../core/updater.dart';
import '../services.dart';

Future<void> openReleasePage(String url) async {
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

Future<void> showUpdateDialog(BuildContext context, UpdateInfo u, {bool auto = false}) async {
  final current = await Services.I.updater.currentBuild();
  if (!context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Доступна сборка ${u.build}'),
      content: Text('Сейчас: сборка $current'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Позже')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Скачать')),
      ],
    ),
  );
  if (go != true) {
    if (auto) await Services.I.settings.update((s) => s.ignoredBuild = u.build);
    return;
  }
  if (!context.mounted) return;
  if (u.apkUrl.isEmpty) {
    await openReleasePage(u.pageUrl);
    return;
  }
  final progress = ValueNotifier<double>(0);
  var cancelled = false;
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      title: Text('Загрузка сборки ${u.build}'),
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (ctx, p, child) => Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(value: p == 0 ? null : p),
          const SizedBox(height: 8),
          Text(p == 0 ? '' : '${(p * 100).round()}%'),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(c);
            },
            child: const Text('Скрыть')),
      ],
    ),
  );
  try {
    final f = await Services.I.updater.download(u, (p) => progress.value = p);
    if (context.mounted && !cancelled) Navigator.of(context, rootNavigator: true).pop();
    final r = await OpenFilex.open(f.path, type: 'application/vnd.android.package-archive');
    if (r.type != ResultType.done) throw Exception(r.message);
  } catch (e) {
    Diagnostics.instance.error('обновление', e);
    if (context.mounted && !cancelled) Navigator.of(context, rootNavigator: true).pop();
    if (!context.mounted) return;
    final again = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Не получилось установить'),
        content: Text('$e\n\nМожно скачать APK в браузере.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Закрыть')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Открыть в браузере')),
        ],
      ),
    );
    if (again == true) await openReleasePage(u.pageUrl);
  }
}
