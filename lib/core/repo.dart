import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'bridge.dart';
import 'diagnostics.dart';
import 'models.dart';
import 'myschool.dart';
import 'net.dart';
import 'settings.dart';
import 'util.dart';

const _secure = FlutterSecureStorage();

/// Request headers never copied from the web app (the client sets its own).
const _skipHeaders = {
  'cookie', 'content-type', 'content-length', 'user-agent', 'accept', 'accept-language', 'accept-encoding', 'host',
  'origin', 'referer', 'connection',
};

class Repo extends ChangeNotifier {
  Repo(this.settings) {
    Bridge.onCapture = onWebCapture;
    _bells = List.of(settings.bells);
    settings.addListener(() {
      if (settings.bells.join('|') != _bells.join('|')) {
        _bells = List.of(settings.bells);
        _derive();
        notifyListeners();
      }
    });
  }

  List<String> _bells = const [];

  /// Main attestation periods (четверти) of the current class, sorted.
  List<StudyPeriod> periods = const [];

  /// Lesson times come from the user's bell schedule (the portal has none).
  bool timesFromBells = false;

  final AppSettings settings;
  final MsClient client = MsClient();
  DatamartStore store = DatamartStore();
  Map<String, Week> weeks = {};
  GradesPage? grades;
  FinalsTable? finals;
  bool loggedIn = false;
  bool sessionExpired = false;
  bool busy = false;
  bool offline = false;
  String? lastError;
  DateTime? lastSync;
  Directory? _dir;
  Future<void>? _refreshing;
  Timer? _probe;
  Timer? _saveTimer;

  static String key(DateTime monday) => weekKey(monday);

  Future<void> init() async {
    _dir = await getApplicationSupportDirectory();
    // build-2 (school.lpr-reg.ru) leftovers: that service is gone.
    try {
      await _secure.delete(key: 'cookies');
      await _secure.delete(key: 'ua');
      final old = File('${_dir!.path}/cache.json');
      if (await old.exists()) await old.delete();
    } catch (_) {}
    try {
      final c = await _secure.read(key: 'ms_cookies');
      if (c != null && c.isNotEmpty) client.cookies.addAll(Map<String, String>.from(jsonDecode(c) as Map));
      final h = await _secure.read(key: 'ms_headers');
      if (h != null && h.isNotEmpty) client.headers.addAll(Map<String, String>.from(jsonDecode(h) as Map));
      final ua = await _secure.read(key: 'ms_ua');
      if (ua != null && ua.isNotEmpty) client.userAgent = ua;
    } catch (e) {
      Diagnostics.instance.error('сессия', e);
    }
    await _loadCache();
    _derive();
    loggedIn = client.hasAccessCookie || !store.isEmpty;
  }

  File get _cacheFile => File('${_dir!.path}/ms_store.json');

  Future<void> _loadCache() async {
    try {
      if (!await _cacheFile.exists()) return;
      final j = jsonDecode(await _cacheFile.readAsString()) as Map<String, dynamic>;
      store = DatamartStore.fromJson(Map<String, dynamic>.from(j['store'] as Map? ?? const {}));
      lastSync = DateTime.tryParse(j['lastSync'] as String? ?? '');
    } catch (e) {
      Diagnostics.instance.error('кэш', e);
    }
  }

  Future<void> _saveCache() async {
    _saveTimer?.cancel();
    try {
      final j = {'store': store.toJson(), 'lastSync': lastSync?.toIso8601String()};
      final tmp = File('${_cacheFile.path}.tmp');
      await tmp.writeAsString(jsonEncode(j));
      await tmp.rename(_cacheFile.path);
    } catch (e) {
      Diagnostics.instance.error('кэш', e);
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _saveCache);
  }

  Future<void> _persistSession() async {
    await _secure.write(key: 'ms_cookies', value: jsonEncode(client.cookies));
    await _secure.write(key: 'ms_headers', value: jsonEncode(client.headers));
    await _secure.write(key: 'ms_ua', value: client.userAgent);
  }

  void _derive() {
    try {
      final data = buildDiary(store, bells: settings.bells);
      periods = data.periods;
      timesFromBells = data.timesFromBells;
      weeks = data.weeks(lastSync ?? store.lastUpdated ?? DateTime.now());
      grades = data.subjects.isEmpty
          ? null
          : GradesPage(subjects: data.subjects, fetchedAt: lastSync ?? DateTime.now());
      finals = data.finals;
    } catch (e, st) {
      Diagnostics.instance.error('разбор данных', '$e\n${st.toString().split('\n').take(4).join('\n')}');
    }
  }

  /// Re-derives the diary from [store] (tests, settings changes).
  void reloadFromStore() {
    _derive();
    notifyListeners();
  }

  /// Saves the portal session copied from the login WebView.
  Future<void> saveSession(Map<String, String> cookies, String? ua) async {
    client.cookies
      ..clear()
      ..addAll(cookies);
    if (ua != null && ua.isNotEmpty) client.userAgent = ua;
    await _persistSession();
    loggedIn = true;
    sessionExpired = false;
    Diagnostics.instance.add('Вход выполнен, cookies: ${cookies.keys.join(', ')}');
    notifyListeners();
  }

  /// Every /api/myschool/ call of the official web app (login screen, hidden WebView, embedded diary).
  void onWebCapture(WebCapture c) {
    var changed = false;
    c.headers.forEach((k, v) {
      final lk = k.toLowerCase();
      if (_skipHeaders.contains(lk) || lk.startsWith('sec-')) return;
      if (client.headers[lk] != v) {
        client.headers[lk] = v;
        changed = true;
      }
    });
    if (changed) unawaited(_persistSession());
    if (c.path.contains('/auth/student') && c.status == 200) store.learnStudent(c.responseJson);
    if (c.path.contains('/current_year') && c.status == 200) {
      final y = c.responseJson;
      if (y is Map && y['current_year'] != null) store.currentYear = '${y['current_year']}';
    }
    if (c.isDatamart) {
      store.learnRequest(c.requestJson);
      final j = c.responseJson;
      if (c.status >= 200 && c.status < 300 && j != null) {
        final r = store.applyResponse(j, ourRequest: false);
        if (r.items > 0) {
          lastSync = DateTime.now();
          offline = false;
          sessionExpired = false;
          lastError = null;
          _derive();
          notifyListeners();
        }
      }
      _scheduleSave();
    }
  }

  Future<void> logout() async {
    client.cookies.clear();
    client.headers.clear();
    await _secure.delete(key: 'ms_cookies');
    await _secure.delete(key: 'ms_headers');
    store = DatamartStore();
    weeks = {};
    grades = null;
    finals = null;
    lastSync = null;
    loggedIn = false;
    sessionExpired = false;
    offline = false;
    _stopProbe();
    try {
      if (await _cacheFile.exists()) await _cacheFile.delete();
    } catch (_) {}
    notifyListeners();
  }

  void markSessionExpired() {
    sessionExpired = true;
    notifyListeners();
  }

  Week? weekAt(int delta) {
    final m = mondayOf(DateTime.now()).add(Duration(days: 7 * delta));
    return weeks[key(m)];
  }

  bool get _stale => lastSync == null || DateTime.now().difference(lastSync!).inMinutes >= 15;

  // ───────────────────────── sync ─────────────────────────

  Future<void> refreshAll() {
    if (!loggedIn) return Future.value();
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    busy = true;
    notifyListeners();
    try {
      await _syncOnce();
      offline = false;
      lastError = null;
      _stopProbe();
    } catch (e, st) {
      if (isOfflineError(e)) {
        if (!offline) Diagnostics.instance.add('Нет сети: показываю сохранённые данные');
        offline = true;
        lastError = null;
        _startProbe();
      } else {
        lastError = e is SessionExpired ? null : '$e';
        Diagnostics.instance.error('обновление', '$e\n${st.toString().split('\n').take(3).join('\n')}');
      }
    } finally {
      busy = false;
      _derive();
      await _saveCache();
      notifyListeners();
    }
  }

  Future<void> _syncOnce() async {
    if (store.buildRequests().isEmpty) {
      // Nothing learned yet: let the official web app load its data in a hidden WebView.
      Diagnostics.instance.add('Шаблонов запросов ещё нет — загружаю через WebView');
      final h = await _harvest();
      if (h.datamart == 0 && h.loginWall) _expired();
      if (h.datamart == 0 && !h.loginWall) throw StateError('Госуслуги не отдали данные дневника (см. Диагностику)');
      return;
    }
    try {
      await _replay();
    } on SessionExpired {
      Diagnostics.instance.add('401 — тихий повторный вход через WebView');
      final h = await _harvest();
      if (h.signedIn) {
        try {
          await _replay();
          return;
        } on SessionExpired {
          if (h.datamart > 0) return;
        }
      } else if (h.datamart > 0) {
        return;
      }
      _expired();
    } catch (e) {
      if (isOfflineError(e)) rethrow;
      // Replay blocked (anti-bot page, 403, 5xx, schema): read what the web app itself loads.
      Diagnostics.instance.error('прямой запрос', e);
      final h = await _harvest();
      if (h.datamart > 0) return;
      if (h.loginWall) {
        _expired();
        return;
      }
      rethrow;
    }
  }

  void _expired() {
    sessionExpired = true;
    Diagnostics.instance.add('Нужен вход: сессия Госуслуг закончилась');
  }

  Future<void> _replay() async {
    final bodies = store.buildRequests();
    var items = 0;
    for (final body in bodies) {
      final r = await client.json('POST', kMsDatamartPath, body: body);
      final a = store.applyResponse(r.json, ourRequest: true);
      items += a.items;
      if (a.errors.isNotEmpty) Diagnostics.instance.add('datamart: ${a.errors.join(', ')}');
    }
    if (items == 0) throw StateError('datamart ответил без данных');
    lastSync = DateTime.now();
    sessionExpired = false;
    await _persistSession();
    await _extras();
  }

  /// Best effort after a successful replay: weeks of the current period that the web app
  /// never asked (for marks of the whole четверть, next week's schedule) and final marks.
  Future<void> _extras() async {
    try {
      final now = DateTime.now();
      final p = periodAt(periods, now);
      final mondays = <DateTime>[];
      var m = mondayOf(p != null && p.contains(now) ? p.start : now.subtract(const Duration(days: 42)));
      final last = mondayOf(now).add(const Duration(days: 7));
      while (!m.isAfter(last)) {
        mondays.add(m);
        m = m.add(const Duration(days: 7));
      }
      await _fetchWeeks(mondays, max: 12);
    } catch (e) {
      if (isOfflineError(e)) rethrow;
      Diagnostics.instance.add('доп. недели: $e');
    }
    for (final item in store.finalProbes()) {
      final k = '${item['obj_type']}|${item['interval_id']}';
      try {
        final r = await client.json('POST', kMsDatamartPath, body: [item]);
        final a = store.applyResponse(r.json, ourRequest: true);
        if (a.items == 0 || a.errors.isNotEmpty) {
          store.failedProbes[k] = DateTime.now().toIso8601String();
        } else {
          Diagnostics.instance.add('Итоговые: ${item['obj_type']} отвечает (${a.objects} об.)');
        }
      } on HttpFailure catch (e) {
        store.failedProbes[k] = DateTime.now().toIso8601String();
        Diagnostics.instance.add('Итоговые: ${item['obj_type']} → ${e.status}');
      } on NotJson {
        store.failedProbes[k] = DateTime.now().toIso8601String();
      } catch (e) {
        if (isOfflineError(e)) rethrow;
        Diagnostics.instance.add('Итоговые: $e');
        break;
      }
    }
  }

  /// Asks lessons/homework/marks for the weeks starting [mondays] that are not stored yet,
  /// using the web app's week numbering (learned). Returns true when something was asked.
  Future<bool> _fetchWeeks(List<DateTime> mondays, {int max = 6}) async {
    final model = store.weekModel;
    final sid = store.requestStudentId;
    if (model == null || sid == null) return false;
    final items = <Map<String, dynamic>>[];
    for (final mon in mondays) {
      final iid = model.idFor(mon);
      for (final t in kWeeklyObjTypes) {
        if (store.entries.containsKey(DatamartStore.keyOf(t, sid, iid))) continue;
        if (store.failedProbes.containsKey('$t|$iid')) continue;
        items.add({'interval_id': iid, 'obj_type': t, 'student_id': sid, 'hash': null});
      }
      if (items.length >= max * kWeeklyObjTypes.length) break;
    }
    if (items.isEmpty) return false;
    for (var i = 0; i < items.length; i += 9) {
      final chunk = items.sublist(i, i + 9 > items.length ? items.length : i + 9);
      try {
        final r = await client.json('POST', kMsDatamartPath, body: chunk);
        store.applyResponse(r.json, ourRequest: true);
      } on HttpFailure catch (e) {
        final when = DateTime.now().toIso8601String();
        for (final it in chunk) {
          store.failedProbes['${it['obj_type']}|${it['interval_id']}'] = when;
        }
        Diagnostics.instance.add('Недели по модели (${model.describe()}) → ${e.status}');
        break;
      }
    }
    _scheduleSave();
    return true;
  }

  Future<HarvestResult> _harvest() async {
    if (!await client.probe()) throw const SocketException('нет сети');
    final r = await runHeadlessHarvest();
    if ((r.cookies['acc_t'] ?? '').isNotEmpty) {
      client.cookies.addAll(r.cookies);
      if (r.userAgent != null) client.userAgent = r.userAgent!;
      await _persistSession();
    }
    if (r.datamart > 0) {
      lastSync = DateTime.now();
      sessionExpired = false;
    }
    return r;
  }

  /// Silent re-login (hidden WebView, ESIA SSO). True when the session is fresh again.
  Future<bool> reloginSilently() async {
    try {
      final r = await _harvest();
      if (r.signedIn) {
        sessionExpired = false;
        notifyListeners();
      }
      return r.signedIn;
    } catch (e) {
      if (isOfflineError(e)) offline = true;
      return false;
    }
  }

  void _startProbe() {
    _probe ??= Timer.periodic(const Duration(seconds: 20), (_) async {
      if (busy) return;
      if (await client.probe()) {
        Diagnostics.instance.add('Сеть появилась — обновляю');
        _stopProbe();
        offline = false;
        notifyListeners();
        await refreshAll();
      }
    });
  }

  void _stopProbe() {
    _probe?.cancel();
    _probe = null;
  }

  /// App came back to the foreground.
  void onResume() {
    if (loggedIn && (offline || _stale)) refreshAll();
  }

  /// Loads the week [delta] weeks from now (0 = this week) — from the cache, refreshing when stale.
  Future<Week?> loadWeek(int delta, {bool force = false}) async {
    if (!loggedIn || (offline && !force)) return weekAt(delta);
    if (force || _stale) {
      await refreshAll();
    } else if (weekAt(delta) == null && delta != 0) {
      await _fetchShiftedWeek(delta);
    }
    return weekAt(delta);
  }

  /// A week the web app never asked: ask it with the learned week numbering.
  Future<void> _fetchShiftedWeek(int delta) async {
    final target = mondayOf(DateTime.now()).add(Duration(days: 7 * delta));
    busy = true;
    notifyListeners();
    try {
      if (await _fetchWeeks([target])) _derive();
    } catch (e) {
      if (isOfflineError(e)) {
        offline = true;
        _startProbe();
      } else {
        Diagnostics.instance.error('неделя $delta', e);
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> loadGrades({String? periodPath}) => loadWeek(0);

  Future<void> loadFinals() => loadWeek(0);

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
      out.addAll(s.marks.where((m) => m.date != null && m.date!.isAfter(since)));
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

  /// One line for Диагностика (no personal data).
  String stateLine() => 'Состояние: вход=${loggedIn ? 'да' : 'нет'}, acc_t=${client.hasAccessCookie ? 'есть' : 'нет'}, '
      'cookies=${client.cookies.length}, доп. заголовки=${client.headers.keys.join('/')}, '
      'офлайн=${offline ? 'да' : 'нет'}, сессия истекла=${sessionExpired ? 'да' : 'нет'}, '
      'обновлено=${lastSync == null ? 'никогда' : ddmmhhmm(lastSync!)}, недель=${weeks.length}, '
      'предметов с оценками=${grades?.subjects.length ?? 0}, оценок=${grades?.subjects.fold<int>(0, (a, s) => a + s.marks.length) ?? 0}, '
      'итоговых строк=${finals?.rows.length ?? 0}${finals?.forecast == true ? ' (прогноз)' : ''}, четвертей=${periods.length}, '
      'уроков=${allDays().fold<int>(0, (a, d) => a + d.lessons.where((l) => l.isLesson).length)}, '
      'с ДЗ=${allDays().fold<int>(0, (a, d) => a + d.lessons.where((l) => l.hasHomework).length)}, '
      'время уроков=${timesFromBells ? 'из звонков' : 'с портала/нет'}';
}
