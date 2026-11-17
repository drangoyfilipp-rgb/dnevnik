import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppTab { feed, schedule, homework, grades }

extension AppTabInfo on AppTab {
  String get title => switch (this) {
        AppTab.feed => 'Лента',
        AppTab.schedule => 'Расписание',
        AppTab.homework => 'Задания',
        AppTab.grades => 'Оценки',
      };
  IconData get icon => switch (this) {
        AppTab.feed => Icons.dynamic_feed_outlined,
        AppTab.schedule => Icons.calendar_today_outlined,
        AppTab.homework => Icons.assignment_outlined,
        AppTab.grades => Icons.grade_outlined,
      };
  IconData get selectedIcon => switch (this) {
        AppTab.feed => Icons.dynamic_feed,
        AppTab.schedule => Icons.calendar_today,
        AppTab.homework => Icons.assignment,
        AppTab.grades => Icons.grade,
      };
}

class AppSettings extends ChangeNotifier {
  late SharedPreferences _p;

  ThemeMode themeMode = ThemeMode.system;
  bool dynamicColor = true;
  bool compact = false;
  List<AppTab> tabOrder = AppTab.values.toList();
  Set<AppTab> hiddenTabs = {};
  AppTab startTab = AppTab.schedule;
  bool lockEnabled = true;
  bool biometric = true;
  bool autoUpdate = true;
  int ignoredBuild = 0;
  DateTime? lastUpdateCheck;
  bool hwOnlySubjectsWithHw = true;
  bool hwByWeek = false;
  bool gradesByDate = false;
  int lockAfterSeconds = 60;

  /// Bell schedule «08:30–09:15» per lesson number (index 0 = 1st lesson). Empty = unknown.
  List<String> bells = [];

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    themeMode = ThemeMode.values[(_p.getInt('themeMode') ?? 0).clamp(0, 2)];
    dynamicColor = _p.getBool('dynamicColor') ?? true;
    compact = _p.getBool('compact') ?? false;
    final order = _p.getStringList('tabOrder');
    if (order != null) {
      final parsed = order.map((n) => AppTab.values.where((t) => t.name == n)).expand((e) => e).toList();
      for (final t in AppTab.values) {
        if (!parsed.contains(t)) parsed.add(t);
      }
      tabOrder = parsed;
    }
    hiddenTabs = (_p.getStringList('hiddenTabs') ?? const [])
        .map((n) => AppTab.values.where((t) => t.name == n))
        .expand((e) => e)
        .toSet();
    startTab = AppTab.values.firstWhere((t) => t.name == _p.getString('startTab'), orElse: () => AppTab.schedule);
    lockEnabled = _p.getBool('lockEnabled') ?? true;
    biometric = _p.getBool('biometric') ?? true;
    autoUpdate = _p.getBool('autoUpdate') ?? true;
    ignoredBuild = _p.getInt('ignoredBuild') ?? 0;
    final luc = _p.getString('lastUpdateCheck');
    lastUpdateCheck = luc == null ? null : DateTime.tryParse(luc);
    hwOnlySubjectsWithHw = _p.getBool('hwOnly') ?? true;
    hwByWeek = _p.getBool('hwByWeek') ?? false;
    gradesByDate = _p.getBool('gradesByDate') ?? false;
    lockAfterSeconds = _p.getInt('lockAfterSeconds') ?? 60;
    bells = _p.getStringList('bells') ?? [];
  }

  List<AppTab> get visibleTabs {
    final v = tabOrder.where((t) => !hiddenTabs.contains(t)).toList();
    return v.isEmpty ? [AppTab.schedule] : v;
  }

  Future<void> update(void Function(AppSettings s) change) async {
    change(this);
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    await _p.setInt('themeMode', themeMode.index);
    await _p.setBool('dynamicColor', dynamicColor);
    await _p.setBool('compact', compact);
    await _p.setStringList('tabOrder', tabOrder.map((e) => e.name).toList());
    await _p.setStringList('hiddenTabs', hiddenTabs.map((e) => e.name).toList());
    await _p.setString('startTab', startTab.name);
    await _p.setBool('lockEnabled', lockEnabled);
    await _p.setBool('biometric', biometric);
    await _p.setBool('autoUpdate', autoUpdate);
    await _p.setInt('ignoredBuild', ignoredBuild);
    if (lastUpdateCheck != null) await _p.setString('lastUpdateCheck', lastUpdateCheck!.toIso8601String());
    await _p.setBool('hwOnly', hwOnlySubjectsWithHw);
    await _p.setBool('hwByWeek', hwByWeek);
    await _p.setBool('gradesByDate', gradesByDate);
    await _p.setInt('lockAfterSeconds', lockAfterSeconds);
    await _p.setStringList('bells', bells);
  }
}

/// Parses the bell schedule text: one lesson per line, «8:30-9:15» / «08:30 – 09:15».
/// Returns normalized «08:30–09:15» lines; null when a line is not a time range.
List<String>? parseBells(String text) {
  final out = <String>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final m = RegExp(r'^(?:\d{1,2}[.)]\s*)?(\d{1,2})[:.](\d{2})\s*[-–—]\s*(\d{1,2})[:.](\d{2})$').firstMatch(line);
    if (m == null) return null;
    String hm(String h, String mi) => '${h.padLeft(2, '0')}:$mi';
    final a = hm(m.group(1)!, m.group(2)!), b = hm(m.group(3)!, m.group(4)!);
    if (int.parse(m.group(1)!) > 23 || int.parse(m.group(3)!) > 23 || a.compareTo(b) >= 0) return null;
    out.add('$a–$b');
  }
  return out;
}
