import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

String hashPin(String pin, String salt) => sha256.convert(utf8.encode('$salt:$pin')).toString();

bool validPin(String pin) => RegExp(r'^\d{4,6}$').hasMatch(pin);

class LockService {
  static const _s = FlutterSecureStorage();
  final LocalAuthentication _auth = LocalAuthentication();
  String? _hash;
  String? _salt;

  Future<void> load() async {
    _hash = await _s.read(key: 'pin_hash');
    _salt = await _s.read(key: 'pin_salt');
  }

  bool get hasPin => _hash != null && _salt != null;

  Future<void> setPin(String pin) async {
    final r = Random.secure();
    _salt = base64Url.encode(List<int>.generate(16, (_) => r.nextInt(256)));
    _hash = hashPin(pin, _salt!);
    await _s.write(key: 'pin_salt', value: _salt);
    await _s.write(key: 'pin_hash', value: _hash);
  }

  Future<void> clearPin() async {
    _hash = null;
    _salt = null;
    await _s.delete(key: 'pin_salt');
    await _s.delete(key: 'pin_hash');
  }

  bool check(String pin) => hasPin && hashPin(pin, _salt!) == _hash;

  Future<bool> biometricAvailable() async {
    try {
      return await _auth.canCheckBiometrics && (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> biometric() async {
    try {
      return await _auth.authenticate(localizedReason: 'Вход в Дневник', biometricOnly: true);
    } catch (_) {
      return false;
    }
  }
}
