import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Portable authenticated encryption for exported backups.
/// The passphrase is never stored by the app; keep it separately from the file.
class BackupEncryption {
  static const format = 'almasar_hawalat_encrypted_backup_v1';
  static const _iterations = 120000;

  static final _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _iterations,
    bits: 256,
  );
  static final _cipher = AesGcm.with256bits();

  static bool isEncrypted(String text) {
    try {
      final value = jsonDecode(text);
      return value is Map && value['format'] == format;
    } catch (_) {
      return false;
    }
  }

  static Future<String> encrypt(String plaintext, String passphrase) async {
    if (passphrase.length < 10) {
      throw ArgumentError('كلمة مرور النسخة الاحتياطية يجب أن تكون 10 أحرف على الأقل.');
    }
    final salt = _kdf.newNonce();
    final key = await _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
    final nonce = _cipher.newNonce();
    final box = await _cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
    );
    return const JsonEncoder.withIndent('  ').convert({
      'format': format,
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': _iterations,
      'cipher': 'AES-256-GCM',
      'salt': base64.encode(salt),
      'nonce': base64.encode(nonce),
      'mac': base64.encode(box.mac.bytes),
      'ciphertext': base64.encode(box.cipherText),
    });
  }

  static Future<String> decrypt(String encryptedText, String passphrase) async {
    final decoded = jsonDecode(encryptedText);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != format ||
        decoded['kdf'] != 'PBKDF2-HMAC-SHA256' ||
        decoded['cipher'] != 'AES-256-GCM' ||
        decoded['iterations'] != _iterations ||
        decoded['salt'] is! String ||
        decoded['nonce'] is! String ||
        decoded['mac'] is! String ||
        decoded['ciphertext'] is! String) {
      throw const FormatException('ملف النسخة المشفرة غير معروف أو غير صالح.');
    }
    final salt = base64.decode(decoded['salt'] as String);
    final nonce = base64.decode(decoded['nonce'] as String);
    final mac = base64.decode(decoded['mac'] as String);
    final ciphertext = base64.decode(decoded['ciphertext'] as String);
    final key = await _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
    try {
      final clear = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
      );
      return utf8.decode(clear);
    } on SecretBoxAuthenticationError {
      throw const FormatException('كلمة المرور غير صحيحة أو ملف النسخة تم تغييره.');
    }
  }
}
