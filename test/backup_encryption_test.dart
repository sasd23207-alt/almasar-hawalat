import 'package:flutter_test/flutter_test.dart';
import 'package:almasar_hawalat/security/backup_encryption.dart';

void main() {
  test('encrypted backup can be decrypted with its passphrase', () async {
    const source = '{"format":"almasar_hawalat_backup","customers":[{"name":"Test merchant"}]}';
    final encrypted = await BackupEncryption.encrypt(source, 'correct horse battery staple');
    expect(BackupEncryption.isEncrypted(encrypted), isTrue);
    expect(encrypted, isNot(contains('Test merchant')));
    expect(await BackupEncryption.decrypt(encrypted, 'correct horse battery staple'), source);
  });

  test('wrong passphrase fails authentication', () async {
    final encrypted = await BackupEncryption.encrypt('sensitive ledger data', 'correct horse battery staple');
    await expectLater(
      BackupEncryption.decrypt(encrypted, 'wrong passphrase here'),
      throwsFormatException,
    );
  });

  test('short passphrases are rejected', () async {
    await expectLater(
      BackupEncryption.encrypt('data', 'short'),
      throwsArgumentError,
    );
  });
}
