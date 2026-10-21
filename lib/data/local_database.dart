import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class LocalDatabase {
  LocalDatabase._();

  static final LocalDatabase instance = LocalDatabase._();
  static Database? _database;
  static const supportedCurrencies = {'LYD', 'USD', 'EUR'};

  Future<Database> get database async {
    if (_database != null) return _database!;
    final root = await getDatabasesPath();
    _database = await openDatabase(
      p.join(root, 'almasar_hawalat.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE customers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            phone TEXT NOT NULL DEFAULT '',
            currency TEXT NOT NULL,
            balance_minor INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE transfers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            reference TEXT NOT NULL UNIQUE,
            customer_id INTEGER NOT NULL,
            customer_name TEXT NOT NULL,
            phone TEXT NOT NULL DEFAULT '',
            kind TEXT NOT NULL CHECK (kind IN ('deposit', 'withdrawal')),
            amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
            currency TEXT NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            FOREIGN KEY (customer_id) REFERENCES customers(id)
          )
        ''');
        await db.execute(
          'CREATE INDEX transfers_created_at_idx ON transfers(created_at)',
        );
        await db.execute(
          'CREATE INDEX transfers_customer_idx ON transfers(customer_id)',
        );
      },
    );
    return _database!;
  }

  Future<List<Map<String, Object?>>> getCustomers() async {
    final db = await database;
    return db.query('customers', orderBy: 'name COLLATE NOCASE ASC');
  }

  Future<List<Map<String, Object?>>> getTransfers({int limit = 200}) async {
    final db = await database;
    return db.query('transfers', orderBy: 'id DESC', limit: limit);
  }

  Future<Map<String, int>> getSummary() async {
    final db = await database;
    final customers = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM customers'),
        ) ??
        0;
    final transfers = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM transfers'),
        ) ??
        0;
    return {'customers': customers, 'transfers': transfers};
  }

  Future<int> addCustomer({
    required String name,
    required String phone,
    required String currency,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) throw ArgumentError('اسم العميل مطلوب');
    if (!supportedCurrencies.contains(currency)) {
      throw ArgumentError('العملة غير مدعومة');
    }
    final db = await database;
    return db.insert('customers', {
      'name': cleanName,
      'phone': phone.trim(),
      'currency': currency,
      'balance_minor': 0,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<String> addTransfer({
    required int customerId,
    required String kind,
    required int amountMinor,
    required String note,
  }) async {
    if (amountMinor <= 0) throw ArgumentError('المبلغ يجب أن يكون أكبر من صفر');
    if (kind != 'deposit' && kind != 'withdrawal') {
      throw ArgumentError('نوع العملية غير صحيح');
    }

    final db = await database;
    final reference =
        'MSR-${DateTime.now().toUtc().microsecondsSinceEpoch}';

    await db.transaction((txn) async {
      final rows = await txn.query(
        'customers',
        where: 'id = ?',
        whereArgs: [customerId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('العميل غير موجود');
      final customer = rows.first;
      final current = customer['balance_minor'] as int;
      final amount = amountMinor;
      if (kind == 'deposit' && current > 0x7fffffffffffffff - amount) {
        throw StateError('المبلغ أكبر من الحد الذي يمكن تخزينه');
      }
      final next = kind == 'deposit' ? current + amount : current - amount;
      if (kind == 'withdrawal' && next < 0) {
        throw StateError('الرصيد غير كافٍ لإتمام العملية');
      }

      final updated = await txn.update(
        'customers',
        {'balance_minor': next},
        where: 'id = ? AND balance_minor = ?',
        whereArgs: [customerId, current],
      );
      if (updated != 1) throw StateError('تغير الرصيد؛ أعد المحاولة');

      await txn.insert('transfers', {
        'reference': reference,
        'customer_id': customerId,
        'customer_name': customer['name'],
        'phone': customer['phone'],
        'kind': kind,
        'amount_minor': amount,
        'currency': customer['currency'],
        'note': note.trim(),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
    return reference;
  }

  /// Produces a versioned portable backup. The caller is responsible for
  /// sharing/storing the returned text securely.
  Future<String> exportBackup() async {
    final db = await database;
    final customers = await db.query('customers', orderBy: 'id ASC');
    final transfers = await db.query('transfers', orderBy: 'id ASC');
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'almasar_hawalat_backup',
      'schema_version': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'customers': customers,
      'transfers': transfers,
    });
  }

  /// Replaces all local records only after basic validation. All deletes and
  /// inserts run in one SQLite transaction so a failed restore rolls back.
  Future<void> restoreBackup(String backupText) async {
    final decoded = jsonDecode(backupText);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'almasar_hawalat_backup' ||
        decoded['schema_version'] != 1 ||
        decoded['customers'] is! List ||
        decoded['transfers'] is! List) {
      throw const FormatException('ملف النسخة الاحتياطية غير معروف أو غير مدعوم');
    }

    final customerRows = (decoded['customers'] as List).map((value) {
      if (value is! Map) throw const FormatException('بيانات عميل غير صالحة');
      final row = Map<String, Object?>.from(value);
      if (row['id'] is! int ||
          row['name'] is! String ||
          (row['name'] as String).trim().isEmpty ||
          row['phone'] is! String ||
          !supportedCurrencies.contains(row['currency']) ||
          row['balance_minor'] is! int ||
          row['created_at'] is! String) {
        throw const FormatException('بيانات عميل غير صالحة');
      }
      return row;
    }).toList();

    final customerIds = customerRows.map((row) => row['id'] as int).toSet();
    final transferRows = (decoded['transfers'] as List).map((value) {
      if (value is! Map) throw const FormatException('بيانات عملية غير صالحة');
      final row = Map<String, Object?>.from(value);
      if (row['id'] is! int ||
          row['reference'] is! String ||
          row['customer_id'] is! int ||
          !customerIds.contains(row['customer_id']) ||
          row['customer_name'] is! String ||
          row['phone'] is! String ||
          !{'deposit', 'withdrawal'}.contains(row['kind']) ||
          row['amount_minor'] is! int ||
          (row['amount_minor'] as int) <= 0 ||
          !supportedCurrencies.contains(row['currency']) ||
          row['note'] is! String ||
          row['created_at'] is! String) {
        throw const FormatException('بيانات عملية غير صالحة');
      }
      return row;
    }).toList();

    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('transfers');
      await txn.delete('customers');
      for (final row in customerRows) {
        await txn.insert('customers', row);
      }
      for (final row in transferRows) {
        await txn.insert('transfers', row);
      }
    });
  }
}
