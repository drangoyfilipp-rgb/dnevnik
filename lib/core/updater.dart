import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'diagnostics.dart';
import 'settings.dart';

const String kRepo = 'drangoyfilipp-rgb/dnevnik';
const String kLatestApi = 'https://api.github.com/repos/$kRepo/releases/latest';
const String kReleasesPage = 'https://github.com/$kRepo/releases/latest';

int? buildFromTag(String tag) {
  final m = RegExp(r'build-(\d+)').firstMatch(tag);
  return m == null ? null : int.parse(m.group(1)!);
}

/// Picks the APK for this device: arm64 when the runtime is arm64, else universal.
String? pickAsset(List<Map<String, dynamic>> assets, {required bool arm64}) {
  String? byName(bool Function(String n) f) {
    for (final a in assets) {
      final n = (a['name'] as String? ?? '').toLowerCase();
      if (n.endsWith('.apk') && f(n)) return a['browser_download_url'] as String?;
    }
    return null;
  }

  if (arm64) {
    final a = byName((n) => n.contains('arm64'));
    if (a != null) return a;
  }
  return byName((n) => n.contains('universal')) ?? byName((n) => true);
}

class UpdateInfo {
  final int build;
  final String apkUrl;
  final String pageUrl;
  final String notes;
  UpdateInfo(this.build, this.apkUrl, this.pageUrl, this.notes);
}

class Updater {
  Updater(this.settings);
  final AppSettings settings;

  Future<int> currentBuild() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber) ?? 0;
  }

  bool get dueForAutoCheck {
    final last = settings.lastUpdateCheck;
    return settings.autoUpdate && (last == null || DateTime.now().difference(last).inHours >= 6);
  }

  /// Returns a newer build, or null. Throws on network errors when [manual].
  Future<UpdateInfo?> check({bool manual = false}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      Future<(int, String)> get(String url) async {
        final req = await client.getUrl(Uri.parse(url));
        req.headers.set('Accept', 'application/vnd.github+json');
        req.headers.set('User-Agent', 'dnevnik-app');
        final res = await req.close().timeout(const Duration(seconds: 20));
        return (res.statusCode, await res.transform(utf8.decoder).join());
      }

      var (code, body) = await get(kLatestApi);
      Map<String, dynamic>? j;
      if (code == 200) {
        j = jsonDecode(body) as Map<String, dynamic>;
      } else if (code == 404) {
        // /latest skips releases marked «pre-release»: take the newest build-N from the list.
        (code, body) = await get('https://api.github.com/repos/$kRepo/releases?per_page=20');
        if (code == 200) {
          final list = (jsonDecode(body) as List).map((e) => Map<String, dynamic>.from(e as Map)).where((r) => r['draft'] != true && buildFromTag(r['tag_name'] as String? ?? '') != null).toList()
            ..sort((a, b) => buildFromTag(b['tag_name'] as String)!.compareTo(buildFromTag(a['tag_name'] as String)!));
          if (list.isNotEmpty) j = list.first;
        }
      }
      if (j == null) throw HttpException('GitHub ответил $code');
      await settings.update((s) => s.lastUpdateCheck = DateTime.now());
      final build = buildFromTag(j['tag_name'] as String? ?? '');
      if (build == null) return null;
      final current = await currentBuild();
      Diagnostics.instance.add('Обновления: на GitHub сборка $build, установлена $current');
      if (build <= current) return null;
      if (!manual && settings.ignoredBuild == build) return null;
      final assets = ((j['assets'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final url = pickAsset(assets, arm64: Platform.version.contains('arm64'));
      return UpdateInfo(build, url ?? '', j['html_url'] as String? ?? kReleasesPage, j['body'] as String? ?? '');
    } catch (e) {
      Diagnostics.instance.error('обновления', e);
      if (manual) rethrow;
      return null;
    } finally {
      client.close();
    }
  }

  Future<File> download(UpdateInfo u, void Function(double p) onProgress) async {
    // Must be inside the app's external files dir or data dir (FileProvider, no permissions).
    final dir = await getExternalStorageDirectory() ?? await getApplicationSupportDirectory();
    final out = File('${dir.path}/updates/dnevnik-build-${u.build}.apk');
    await out.parent.create(recursive: true);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(u.apkUrl));
      req.headers.set('User-Agent', 'dnevnik-app');
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('Загрузка: ${res.statusCode}');
      final total = res.contentLength;
      var got = 0;
      final sink = out.openWrite();
      await for (final c in res) {
        sink.add(c);
        got += c.length;
        if (total > 0) onProgress(got / total);
      }
      await sink.close();
      return out;
    } finally {
      client.close();
    }
  }
}
