import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'diagnostics.dart';
import 'models.dart';
import 'net.dart';
import 'parser.dart';
import 'settings.dart';

const _secure = FlutterSecureStorage();

class Repo extends ChangeNotifier {
  Repo(this.settings) {
    client.trustSchoolCert = () => settings.trustSchoolCert;
  }

  final AppSettings settings;
  final EljurClient client = EljurClient();
  final Map<String, Week> weeks = {};
  GradesPage? grades;
  FinalsTable? finals;
  String? pupilId;
  int weekSign = -1; // path index = weekSign * delta (delta > 0 = future)
  DateTime? currentMonday;
  bool loggedIn = false;
  bool sessionExpired = false;
  bool busy = false;
  String? lastError;
  DateTime? lastSync;
  Directory? _dir;

  static String key(DateTime monday) =>
      '${monday.year}-${monday.month.toString().padLeft(2, '0')}-${monday.day.toString().padLeft(2, '0')}';

  Future<void> init() async {
    _dir = await getApplicationSupportDirectory();
    final c = await _secure.read(key: 'cookies');
    final ua = await _secure.read(key: 'ua');
    if (ua != null && ua.isNotEmpty) client.userAgent = ua;
    if (c != null && c.isNotEmpty) {
      client.cookies.addAll(Map<String, String>.from(jsonDecode(c) as Map));
      loggedIn = client.cookies.isNotEmpty;
    }
    await _loadCache();
  }

  File get _cacheFile => File('${_dir!.path}/cache.json');

  Future<void> _loadCache() async {
    try {
      if (!await _cacheFile.exists()) return;
      final j = jsonDecode(await _cacheFile.readAsString()) as Map<String, dynamic>;
      for (final w in (j['weeks'] as List? ?? const [])) {
        final week = Week.fromJson(Map<String, dynamic>.from(w as Map));
        weeks[key(week.monday)] = week;
      }
      if (j['grades'] != null) grades = GradesPage.fromJson(Map<String, dynamic>.from(j['grades'] as Map));
      if (j['finals'] != null) finals = FinalsTable.fromJson(Map<String, dynamic>.from(j['finals'] as Map));
      pupilId = j['pupil'] as String?;
      weekSign = (j['weekSign'] as int?) ?? -1;
      lastSync = DateTime.tryParse(j['lastSync'] as String? ?? '');
    } catch (e) {
      Diagnostics.instance.error('кэш', e);
    }
  }

  Future<void> _saveCache() async {
    try {
      // Keep at most 40 weeks.
      final list = weeks.values.toList()..sort((a, b) => b.monday.compareTo(a.monday));
      final j = {
        'weeks': list.take(40).map((e) => e.toJson()).toList(),
        'grades': grades?.toJson(),
        'finals': finals?.toJson(),
        'pupil': pupilId,
        'weekSign': weekSign,
        'lastSync': lastSync?.toIso8601String(),
      };
      await _cacheFile.writeAsString(jsonEncode(j));
    } catch (e) {
      Diagnostics.instance.error('кэш', e);
    }
  }

  Future<void> saveSession(Map<String, String> cookies, String? ua) async {
    client.cookies
      ..clear()
      ..addAll(cookies);
    if (ua != null && ua.isNotEmpty) client.userAgent = ua;
    await _secure.write(key: 'cookies', value: jsonEncode(client.cookies));
    if (ua != null) await _secure.write(key: 'ua', value: ua);
    loggedIn = true;
    sessionExpired = false;
    Diagnostics.instance.add('Вход выполнен, cookies: ${cookies.keys.join(', ')}');
    notifyListeners();
  }

  Future<void> logout() async {
    client.cookies.clear();
    await _secure.delete(key: 'cookies');
    weeks.clear();
    grades = null;
    finals = null;
    pupilId = null;
    loggedIn = false;
    try {
      if (await _cacheFile.exists()) await _cacheFile.delete();
    } catch (_) {}
    notifyListeners();
  }

  void markSessionExpired() {
    sessionExpired = true;
    notifyListeners();
  }

  Future<void> _persistCookies() async {
    await _secure.write(key: 'cookies', value: jsonEncode(client.cookies));
  }

  Week? weekAt(int delta) {
    final m = mondayOf(DateTime.now()).add(Duration(days: 7 * delta));
    return weeks[key(m)];
  }

  Future<T?> _guard<T>(String where, Future<T> Function() f) async {
    try {
      final r = await f();
      lastError = null;
      return r;
    } on SessionExpired catch (e) {
      sessionExpired = true;
      lastError = e.toString();
      Diagnostics.instance.error(where, e);
    } on SocketException catch (e) {
      lastError = 'Нет связи с сервером школы';
      Diagnostics.instance.error(where, e);
    } on HandshakeException catch (e) {
      lastError = 'Ошибка защищённого соединения (сертификат). См. Диагностику';
      Diagnostics.instance.error(where, e);
    } catch (e, st) {
      lastError = '$e';
      Diagnostics.instance.error(where, '$e\n${st.toString().split('\n').take(4).join('\n')}');
    }
    return null;
  }

  String _weekPath(int delta) => '/journal-app/week.${weekSign * delta}';

  Future<Week?> _fetchWeek(int delta) async {
    final src = await client.getPage(_weekPath(delta), kind: 'diary-week');
    pupilId ??= findPupilId(src);
    final res = parseWeek(src);
    if (res.loginPage) throw SessionExpired();
    if (res.days.isEmpty) {
      Diagnostics.instance.error('дневник', 'на странице недели не найдено дней (разметка изменилась?)');
      return null;
    }
    final monday = mondayOf(res.days.first.date);
    return Week(monday: monday, days: res.days, fetchedAt: DateTime.now());
  }

  /// Loads the week [delta] weeks from now (0 = this week).
  Future<Week?> loadWeek(int delta, {bool force = false}) async {
    final cached = weekAt(delta);
    if (!force && cached != null && DateTime.now().difference(cached.fetchedAt).inMinutes < 15) return cached;
    if (!loggedIn) return cached;
    busy = true;
    notifyListeners();
    final w = await _guard('неделя $delta', () async {
      var week = await _fetchWeek(delta);
      if (week == null) return null;
      final expected = mondayOf(DateTime.now()).add(Duration(days: 7 * delta));
      if (delta != 0 && week.monday != expected) {
        final opposite = mondayOf(DateTime.now()).add(Duration(days: -7 * delta));
        if (week.monday == opposite) {
          weekSign = -weekSign;
          Diagnostics.instance.add('Направление недель перевёрнуто (sign=$weekSign)');
          week = await _fetchWeek(delta);
        }
      }
      return week;
    });
    if (w != null) {
      weeks[key(w.monday)] = w;
      lastSync = DateTime.now();
      sessionExpired = false;
      await _persistCookies();
      await _saveCache();
    }
    busy = false;
    notifyListeners();
    return w ?? cached;
  }

  Future<void> loadGrades({String? periodPath}) async {
    if (!loggedIn) return;
    busy = true;
    notifyListeners();
    final g = await _guard('оценки', () async {
      final path = periodPath ?? '/journal-student-grades-action/${pupilId ?? ''}';
      final src = await client.getPage(path, kind: 'grades');
      pupilId ??= findPupilId(src);
      final page = parseGrades(src);
      if (page.subjects.isEmpty) {
        Diagnostics.instance.error('оценки', 'на странице оценок ничего не распознано');
      }
      return page;
    });
    if (g != null) {
      grades = g;
      await _saveCache();
    }
    busy = false;
    notifyListeners();
  }

  Future<void> loadFinals() async {
    if (!loggedIn) return;
    busy = true;
    notifyListeners();
    final f = await _guard('итоговые', () async {
      if (pupilId == null) await _fetchWeek(0);
      final src = await client.getPage('/journal-student-resultmarks-action/${pupilId ?? ''}', kind: 'finals');
      final t = parseFinals(src);
      if (t.rows.isEmpty) Diagnostics.instance.error('итоговые', 'таблица итоговых оценок не найдена');
      return t;
    });
    if (f != null) {
      finals = f;
      await _saveCache();
    }
    busy = false;
    notifyListeners();
  }

  Future<void> refreshAll() async {
    await loadWeek(0, force: true);
    if (sessionExpired) return;
    await loadWeek(1, force: true);
    await loadGrades();
    await loadFinals();
  }

  /// Marks collected from the diary weeks in the cache (fallback for «Оценки»).
  List<SubjectMarks> marksFromDiary() {
    final by = <String, List<Mark>>{};
    for (final w in weeks.values) {
      for (final d in w.days) {
        for (final l in d.lessons) {
          for (final m in l.marks) {
            by.putIfAbsent(l.subject, () => []).add(m);
          }
        }
      }
    }
    final list = by.entries.map((e) {
      final marks = e.value..sort((a, b) => (a.date ?? DateTime(0)).compareTo(b.date ?? DateTime(0)));
      return SubjectMarks(subject: e.key, marks: marks);
    }).toList()
      ..sort((a, b) => a.subject.compareTo(b.subject));
    return list;
  }

  List<Mark> recentMarks({int days = 14}) {
    final since = DateTime.now().subtract(Duration(days: days));
    final out = <Mark>[];
    for (final s in grades?.subjects ?? marksFromDiary()) {
      out.addAll(s.marks.where((m) => m.date == null || m.date!.isAfter(since)));
    }
    if (out.isEmpty) {
      for (final s in marksFromDiary()) {
        out.addAll(s.marks.where((m) => m.date != null && m.date!.isAfter(since)));
      }
    }
    out.sort((a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)));
    return out;
  }

  /// All days from the cache, sorted.
  List<Day> allDays() {
    final list = <Day>[];
    for (final w in weeks.values) {
      list.addAll(w.days);
    }
    list.sort((a, b) => a.date.compareTo(b.date));
    return list;
  }

  Future<Directory> filesDir() async {
    final ext = await getExternalStorageDirectory();
    final base = ext ?? await getApplicationDocumentsDirectory();
    return Directory('${base.path}/Файлы');
  }
}
