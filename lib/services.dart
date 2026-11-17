import 'core/lock.dart';
import 'core/repo.dart';
import 'core/settings.dart';
import 'core/updater.dart';

/// App-wide services, created once in main().
class Services {
  Services._(this.settings, this.repo, this.lock, this.updater);
  final AppSettings settings;
  final Repo repo;
  final LockService lock;
  final Updater updater;

  static late Services I;

  /// Test hook: services without plugins (no storage is touched until used).
  static Services forTest(AppSettings settings, Repo repo, LockService lock, Updater updater) =>
      I = Services._(settings, repo, lock, updater);

  static Future<Services> create() async {
    final settings = AppSettings();
    await settings.load();
    final repo = Repo(settings);
    await repo.init();
    final lock = LockService();
    await lock.load();
    I = Services._(settings, repo, lock, Updater(settings));
    return I;
  }
}
