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
