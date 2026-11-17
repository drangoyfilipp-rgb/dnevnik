import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services.dart';
import 'ui/home_shell.dart';
import 'ui/lock_screens.dart';
import 'ui/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Services.create();
  runApp(const DnevnikApp());
}

class DnevnikApp extends StatelessWidget {
  const DnevnikApp({super.key});

  ThemeData _theme(ColorScheme scheme, bool compact) => ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
        listTileTheme: ListTileThemeData(dense: compact),
      );

  @override
  Widget build(BuildContext context) {
    final s = Services.I.settings;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => DynamicColorBuilder(builder: (light, dark) {
        const seed = Color(0xFF3F51B5);
        final lightScheme = (s.dynamicColor ? light : null) ?? ColorScheme.fromSeed(seedColor: seed);
        final darkScheme =
            (s.dynamicColor ? dark : null) ?? ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);
        return MaterialApp(
          title: 'Дневник',
          debugShowCheckedModeBanner: false,
          themeMode: s.themeMode,
          theme: _theme(lightScheme, s.compact),
          darkTheme: _theme(darkScheme, s.compact),
          locale: const Locale('ru'),
          home: const RootGate(),
        );
      }),
    );
  }
}

/// PIN lock first, then sign-in, then the app.
class RootGate extends StatefulWidget {
  const RootGate({super.key});
  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> with WidgetsBindingObserver {
  final s = Services.I;
  late bool _locked;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _locked = s.settings.lockEnabled && s.lock.hasPin;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _pausedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final p = _pausedAt;
      _pausedAt = null;
      if (p != null &&
          s.settings.lockEnabled &&
          s.lock.hasPin &&
          !LockScreen.biometricInProgress &&
          DateTime.now().difference(p).inSeconds >= s.settings.lockAfterSeconds) {
        setState(() => _locked = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([s.settings, s.repo]),
      builder: (context, _) {
        if (s.settings.lockEnabled && !s.lock.hasPin) {
          return PinSetupScreen(onDone: () => setState(() => _locked = false), firstRun: true);
        }
        if (_locked && s.settings.lockEnabled) {
          return LockScreen(onUnlocked: () => setState(() => _locked = false));
        }
        if (!s.repo.loggedIn) return const LoginIntro();
        return const HomeShell();
      },
    );
  }
}
