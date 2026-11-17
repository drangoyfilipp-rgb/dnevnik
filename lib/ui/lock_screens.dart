import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/lock.dart';
import '../services.dart';

class PinPad extends StatelessWidget {
  const PinPad({super.key, required this.onDigit, required this.onBackspace, this.extra});
  final void Function(String d) onDigit;
  final VoidCallback onBackspace;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    Widget key(String d) => SizedBox(
          width: 76,
          height: 64,
          child: TextButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              onDigit(d);
            },
            child: Text(d, style: Theme.of(context).textTheme.headlineSmall),
          ),
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final row in const [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9'],
      ])
        Row(mainAxisAlignment: MainAxisAlignment.center, children: row.map(key).toList()),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        SizedBox(width: 76, height: 64, child: extra ?? const SizedBox()),
        key('0'),
        SizedBox(
          width: 76,
          height: 64,
          child: IconButton(onPressed: onBackspace, icon: const Icon(Icons.backspace_outlined), tooltip: 'Стереть'),
        ),
      ]),
    ]);
  }
}

class PinDots extends StatelessWidget {
  const PinDots({super.key, required this.length, this.max = 6, this.error = false});
  final int length;
  final int max;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final count = length < 4 ? 4 : (length > max ? max : length);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(
        count,
        (i) => Container(
          margin: const EdgeInsets.all(7),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: i < length ? (error ? c.error : c.primary) : Colors.transparent,
            border: Border.all(color: error ? c.error : c.outline, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.onUnlocked});
  final VoidCallback onUnlocked;
  static bool biometricInProgress = false;
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final s = Services.I;
  String _pin = '';
  bool _error = false;
  bool _bioAvailable = false;
  int _fails = 0;

  @override
  void initState() {
    super.initState();
    _initBio();
  }

  Future<void> _initBio() async {
    if (!s.settings.biometric) return;
    final ok = await s.lock.biometricAvailable();
    if (!mounted) return;
    setState(() => _bioAvailable = ok);
    if (ok) _bio();
  }

  Future<void> _bio() async {
    LockScreen.biometricInProgress = true;
    final ok = await s.lock.biometric();
    // The system prompt pauses the activity; ignore that pause.
    Future.delayed(const Duration(seconds: 1), () => LockScreen.biometricInProgress = false);
    if (ok && mounted) widget.onUnlocked();
  }

  void _digit(String d) {
    if (_pin.length >= 6) return;
    setState(() {
      _pin += d;
      _error = false;
    });
    if (_pin.length >= 4 && s.lock.check(_pin)) {
      widget.onUnlocked();
    } else if (_pin.length == 6) {
      _fails++;
      setState(() {
        _error = true;
        _pin = '';
      });
      HapticFeedback.heavyImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_outline, size: 40, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              Text('Введите код', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              PinDots(length: _pin.length, error: _error),
              SizedBox(
                height: 24,
                child: _error
                    ? Text(_fails >= 3 ? 'Неверный код. Забыли — переустановите приложение' : 'Неверный код',
                        style: TextStyle(color: Theme.of(context).colorScheme.error))
                    : null,
              ),
              const SizedBox(height: 8),
              PinPad(
                onDigit: _digit,
                onBackspace: () => setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1)),
                extra: _bioAvailable
                    ? IconButton(onPressed: _bio, icon: const Icon(Icons.fingerprint), tooltip: 'Отпечаток')
                    : null,
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key, required this.onDone, this.firstRun = false});
  final VoidCallback onDone;
  final bool firstRun;
  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  final s = Services.I;
  String _pin = '';
  String? _first;
  bool _error = false;

  void _digit(String d) {
    if (_pin.length >= 6) return;
    setState(() {
      _pin += d;
      _error = false;
    });
  }

  Future<void> _next() async {
    if (!validPin(_pin)) return;
    if (_first == null) {
      setState(() {
        _first = _pin;
        _pin = '';
      });
      return;
    }
    if (_first != _pin) {
      setState(() {
        _first = null;
        _pin = '';
        _error = true;
      });
      return;
    }
    await s.lock.setPin(_pin);
    final bio = await s.lock.biometricAvailable();
    if (bio && mounted) {
      final use = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Вход по отпечатку'),
          content: const Text('Открывать дневник отпечатком пальца или лицом? Код останется запасным способом.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Нет')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Да')),
          ],
        ),
      );
      await s.settings.update((x) => x.biometric = use ?? false);
    }
    await s.settings.update((x) => x.lockEnabled = true);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: widget.firstRun ? null : AppBar(title: const Text('Код для входа')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (widget.firstRun) ...[
                Text('Дневник', style: t.headlineMedium),
                const SizedBox(height: 8),
                const Text('Придумайте код из 4–6 цифр — он защитит оценки и сообщения, если телефон возьмёт кто-то другой.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
              ],
              Text(_first == null ? 'Новый код' : 'Повторите код', style: t.titleLarge),
              PinDots(length: _pin.length, error: _error),
              SizedBox(
                height: 22,
                child: _error ? Text('Коды не совпали', style: TextStyle(color: Theme.of(context).colorScheme.error)) : null,
              ),
              PinPad(
                onDigit: _digit,
                onBackspace: () => setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1)),
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: validPin(_pin) ? _next : null, child: const Text('Далее')),
              if (widget.firstRun)
                TextButton(
                  onPressed: () async {
                    await s.settings.update((x) => x.lockEnabled = false);
                    widget.onDone();
                  },
                  child: const Text('Не использовать код (можно включить в Настройках)'),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
