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
  }

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
      final data = buildDiary(store);
      weeks = data.weeks(lastSync ?? store.lastUpdated ?? DateTime.now());
      grades = data.subjects.isEmpty
          ? null
          : GradesPage(subjects: data.subjects, fetchedAt: lastSync ?? DateTime.now());
      finals = data.finals;
    } catch (e, st) {
      Diagnostics.instance.error('разбор данных', '$e\n${st.toString().split('\n').take(4).join('\n')}');
    }
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

  /// When the web app asks lessons per week (interval id with dates), ask for another week too.
  Future<void> _fetchShiftedWeek(int delta) async {
    final target = mondayOf(DateTime.now()).add(Duration(days: 7 * delta));
    final items = <Map<String, dynamic>>[];
    for (final r in store.requests) {
      for (final i in r) {
        final t = '${i['obj_type']}';
        if (t != 'student_lessons' && t != 'student_homeworks_materials') continue;
        final iid = '${i['interval_id'] ?? ''}';
        final m = RegExp(r'(\d{4})-(\d{2})-(\d{2})').firstMatch(iid);
        if (m == null) continue;
        final first = DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
        final shift = target.difference(mondayOf(first)).inDays;
        final shifted = shiftIntervalId(iid, shift);
        if (shifted == null || items.any((x) => x['obj_type'] == t && x['interval_id'] == shifted)) continue;
        final sid = '${i['student_id'] ?? ''}';
        items.add({...i, 'interval_id': shifted, 'hash': store.entries[DatamartStore.keyOf(t, sid, shifted)]?.hash});
      }
    }
    if (items.isEmpty) return;
    busy = true;
    notifyListeners();
    try {
      final r = await client.json('POST', kMsDatamartPath, body: items);
      store.applyResponse(r.json, ourRequest: true);
      _derive();
      _scheduleSave();
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
      'предметов с оценками=${grades?.subjects.length ?? 0}, итоговых строк=${finals?.rows.length ?? 0}';
}
