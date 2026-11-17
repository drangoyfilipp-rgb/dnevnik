import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/settings.dart';
import '../core/updater.dart';
import '../services.dart';
import 'diagnostics_screen.dart';
import 'file_actions.dart';
import 'lock_screens.dart';
import 'login_screen.dart';
import 'update_dialog.dart';
import 'widgets.dart';

class MoreTab extends StatelessWidget {
  const MoreTab({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = Services.I.repo;
    return ListView(children: [
      ListTile(
        leading: const Icon(Icons.settings_outlined),
        title: const Text('Настройки'),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
      ),
      ListTile(
        leading: const Icon(Icons.bug_report_outlined),
        title: const Text('Диагностика'),
        subtitle: const Text('Если что-то не отображается'),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DiagnosticsScreen())),
      ),
      ListTile(
        leading: const Icon(Icons.public),
        title: const Text('Дневник Госуслуг'),
        subtitle: const Text('Официальная веб-версия; данные с открытых страниц тоже сохраняются'),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginWebView(browse: true))),
      ),
      ListTile(
        leading: const Icon(Icons.folder_outlined),
        title: const Text('Скачанные файлы'),
        subtitle: const Text('Открываются и без интернета'),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DownloadedFilesScreen())),
      ),
      ListTile(
        leading: const Icon(Icons.info_outline),
        title: const Text('О приложении и обновления'),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutScreen())),
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.login),
        title: const Text('Войти заново'),
        subtitle: const Text('Если сессия Госуслуг истекла'),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginWebView())),
      ),
      ListTile(
        leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
        title: const Text('Выйти'),
        onTap: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('Выйти?'),
              content: const Text('Сессия и сохранённые данные будут удалены с телефона.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Выйти')),
              ],
            ),
          );
          if (ok == true) {
            await CookieManager.instance().deleteAllCookies();
            await repo.logout();
          }
        },
      ),
    ]);
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.I.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          final t = Theme.of(context).textTheme;
          Widget header(String x) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                child: Text(x, style: t.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
              );
          return ListView(children: [
            header('Оформление'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('Системная')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Светлая')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Тёмная')),
                ],
                selected: {s.themeMode},
                onSelectionChanged: (v) => s.update((x) => x.themeMode = v.first),
              ),
            ),
            SwitchListTile(
              title: const Text('Цвета обоев (Material You)'),
              value: s.dynamicColor,
              onChanged: (v) => s.update((x) => x.dynamicColor = v),
            ),
            SwitchListTile(
              title: const Text('Компактный вид'),
              subtitle: const Text('Больше уроков на экране'),
              value: s.compact,
              onChanged: (v) => s.update((x) => x.compact = v),
            ),
            header('Вкладки'),
            ListTile(
              title: const Text('Открывать при запуске'),
              trailing: DropdownButton<AppTab>(
                value: s.visibleTabs.contains(s.startTab) ? s.startTab : s.visibleTabs.first,
                items: [for (final tab in s.visibleTabs) DropdownMenuItem(value: tab, child: Text(tab.title))],
                onChanged: (v) => v == null ? null : s.update((x) => x.startTab = v),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('Галочка — показывать вкладку, перетаскивайте за ≡, чтобы поменять порядок.'),
            ),
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorder: (a, b) => s.update((x) {
                final list = x.tabOrder.toList();
                if (b > a) b--;
                list.insert(b, list.removeAt(a));
                x.tabOrder = list;
              }),
              children: [
                for (var i = 0; i < s.tabOrder.length; i++)
                  CheckboxListTile(
                    key: ValueKey(s.tabOrder[i]),
                    controlAffinity: ListTileControlAffinity.leading,
                    value: !s.hiddenTabs.contains(s.tabOrder[i]),
                    title: Text(s.tabOrder[i].title),
                    secondary: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                    onChanged: (v) => s.update((x) {
                      final tab = x.tabOrder[i];
                      if (v == true) {
                        x.hiddenTabs = {...x.hiddenTabs}..remove(tab);
                      } else if (x.visibleTabs.length > 1) {
                        x.hiddenTabs = {...x.hiddenTabs, tab};
                      }
                    }),
                  ),
              ],
            ),
            header('Расписание'),
            ListTile(
              leading: const Icon(Icons.notifications_none),
              title: const Text('Расписание звонков'),
              subtitle: Text(s.bells.isEmpty
                  ? 'Не задано — показываются только номера уроков (школа не заполнила время на портале)'
                  : '${s.bells.length} ур.: ${s.bells.first} … ${s.bells.last}'),
              onTap: () => editBells(context),
            ),
            header('Задания и оценки'),
            SwitchListTile(
              title: const Text('Задания: группировать по предметам'),
              subtitle: const Text('Выкл — по датам'),
              value: s.hwByWeek,
              onChanged: (v) => s.update((x) => x.hwByWeek = v),
            ),
            SwitchListTile(
              title: const Text('Оценки: списком по дате'),
              subtitle: const Text('Выкл — по предметам'),
              value: s.gradesByDate,
              onChanged: (v) => s.update((x) => x.gradesByDate = v),
            ),
            header('Безопасность'),
            SwitchListTile(
              title: const Text('Пароль на вход'),
              subtitle: const Text('Код из 4–6 цифр при открытии'),
              value: s.lockEnabled,
              onChanged: (v) async {
                if (v && !Services.I.lock.hasPin) {
                  await Navigator.push(
                      context, MaterialPageRoute(builder: (c) => PinSetupScreen(onDone: () => Navigator.pop(c))));
                  return;
                }
                if (!v) await Services.I.lock.clearPin();
                await s.update((x) => x.lockEnabled = v);
              },
            ),
            if (s.lockEnabled) ...[
              ListTile(
                title: const Text('Сменить код'),
                leading: const Icon(Icons.pin_outlined),
                onTap: () => Navigator.push(
                    context, MaterialPageRoute(builder: (c) => PinSetupScreen(onDone: () => Navigator.pop(c)))),
              ),
              SwitchListTile(
                title: const Text('Вход по отпечатку / лицу'),
                value: s.biometric,
                onChanged: (v) => s.update((x) => x.biometric = v),
              ),
              ListTile(
                title: const Text('Блокировать после сворачивания'),
                trailing: DropdownButton<int>(
                  value: const [0, 60, 300, 900].contains(s.lockAfterSeconds) ? s.lockAfterSeconds : 60,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('сразу')),
                    DropdownMenuItem(value: 60, child: Text('1 мин')),
                    DropdownMenuItem(value: 300, child: Text('5 мин')),
                    DropdownMenuItem(value: 900, child: Text('15 мин')),
                  ],
                  onChanged: (v) => v == null ? null : s.update((x) => x.lockAfterSeconds = v),
                ),
              ),
            ],
            header('Обновления'),
            SwitchListTile(
              title: const Text('Проверять обновления'),
              subtitle: const Text('Не чаще раза в 6 часов, с GitHub'),
              value: s.autoUpdate,
              onChanged: (v) => s.update((x) => x.autoUpdate = v),
            ),
            const SizedBox(height: 32),
          ]);
        },
      ),
    );
  }
}

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});
  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  bool _checking = false;
  String? _status;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _status = null;
    });
    try {
      final u = await Services.I.updater.check(manual: true);
      if (!mounted) return;
      if (u == null) {
        setState(() => _status = 'У вас последняя сборка');
      } else {
        await showUpdateDialog(context, u);
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Не удалось проверить: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Services.I.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('О приложении')),
      body: FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snap) => ListView(padding: const EdgeInsets.all(16), children: [
          Text('Дневник', style: Theme.of(context).textTheme.headlineSmall),
          Text(snap.hasData ? 'Сборка ${snap.data!.buildNumber} (${snap.data!.version})' : ''),
          const SizedBox(height: 12),
          const Text('Личное приложение для дневника «Госуслуги Моя школа». Без рекламы и аналитики; '
              'данные хранятся только на этом телефоне и доступны без интернета. Пароль от Госуслуг не сохраняется.'),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _checking ? null : _check,
            icon: _checking
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.system_update),
            label: const Text('Проверить обновления'),
          ),
          if (_status != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_status!)),
          if (s.lastUpdateCheck != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Последняя проверка: ${timeAgo(s.lastUpdateCheck!)}', style: Theme.of(context).textTheme.bodySmall),
            ),
          TextButton(onPressed: () => openReleasePage(kReleasesPage), child: const Text('Страница релизов')),
        ]),
      ),
    );
  }
}

Future<void> editBells(BuildContext context) async {
  final s = Services.I.settings;
  final ctrl = TextEditingController(text: s.bells.join('\n'));
  String? error;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Расписание звонков'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('По строке на урок, как в школе, например:\n08:00-08:45\n08:55-09:40\nПустое поле — без времени.'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLines: 10,
              minLines: 4,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(border: const OutlineInputBorder(), errorText: error),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              final parsed = parseBells(ctrl.text);
              if (parsed == null) {
                setState(() => error = 'Формат строки: 08:00-08:45');
                return;
              }
              s.update((x) => x.bells = parsed);
              Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    ),
  );
}
