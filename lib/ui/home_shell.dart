import 'package:flutter/material.dart';

import '../core/settings.dart';
import '../services.dart';
import 'more_screens.dart';
import 'tabs.dart';
import 'update_dialog.dart';
import 'widgets.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final s = Services.I;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    final tabs = s.settings.visibleTabs;
    final start = tabs.indexOf(s.settings.startTab);
    _index = start < 0 ? 0 : start;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (s.repo.lastSync == null || DateTime.now().difference(s.repo.lastSync!).inMinutes > 15) {
        s.repo.refreshAll();
      }
      if (s.updater.dueForAutoCheck) {
        final u = await s.updater.check();
        if (u != null && mounted) showUpdateDialog(context, u, auto: true);
      }
    });
  }

  Widget _tab(AppTab t) => switch (t) {
        AppTab.feed => const FeedTab(),
        AppTab.schedule => const ScheduleTab(),
        AppTab.homework => const HomeworkTab(),
        AppTab.grades => const GradesTab(),
      };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s.settings,
      builder: (context, _) {
        final tabs = s.settings.visibleTabs;
        final count = tabs.length + 1;
        if (_index >= count) _index = 0;
        final isMore = _index == tabs.length;
        return Scaffold(
          appBar: AppBar(
            title: Text(isMore ? 'Ещё' : tabs[_index].title),
            actions: [
              if (!isMore)
                ListenableBuilder(
                  listenable: s.repo,
                  builder: (context, _) => s.repo.busy
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                      : IconButton(onPressed: s.repo.refreshAll, icon: const Icon(Icons.refresh), tooltip: 'Обновить'),
                ),
            ],
          ),
          body: Column(children: [
            const StatusBanner(),
            Expanded(
              child: IndexedStack(index: _index, children: [
                for (final t in tabs) _tab(t),
                const MoreTab(),
              ]),
            ),
          ]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            labelBehavior: s.settings.compact
                ? NavigationDestinationLabelBehavior.onlyShowSelected
                : NavigationDestinationLabelBehavior.alwaysShow,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: [
              for (final t in tabs) NavigationDestination(icon: Icon(t.icon), selectedIcon: Icon(t.selectedIcon), label: t.title),
              const NavigationDestination(icon: Icon(Icons.more_horiz), label: 'Ещё'),
            ],
          ),
        );
      },
    );
  }
}
