import 'dart:convert';

import '../core/ledger_integrity.dart';

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
      version: 2,
      onConfigure: (db) async {
        // SQLite disables foreign-key enforcement by default unless enabled per connection.
        await db.execute('PRAGMA foreign_keys = ON');
      },
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
        await _createMerchantTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createMerchantTables(db);
        }
      },
    );
    return _database!;
  }

  Future<void> _createMerchantTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS merchant_accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL COLLATE NOCASE UNIQUE,
        phone TEXT NOT NULL DEFAULT '',
        notes TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS merchant_transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        merchant_id INTEGER NOT NULL,
        source_key TEXT NOT NULL UNIQUE,
        transaction_date TEXT,
        sender TEXT NOT NULL DEFAULT '',
        original_message TEXT NOT NULL,
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        currency TEXT NOT NULL CHECK (currency IN ('LYD', 'USD', 'EUR')),
        direction TEXT NOT NULL CHECK (direction IN ('paid_to_trader', 'received_from_trader')),
        exchange_rate_micros INTEGER,
        import_batch TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (merchant_id) REFERENCES merchant_accounts(id)
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS merchant_tx_merchant_date_idx ON merchant_transactions(merchant_id, transaction_date)');
  }

  Future<int> getOrCreateMerchant({required String name, String phone = ''}) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) throw ArgumentError('اسم التاجر مطلوب');
    final db = await database;
    return db.transaction((txn) async {
      final found = await txn.query('merchant_accounts', where: 'name = ?', whereArgs: [cleanName], limit: 1);
      if (found.isNotEmpty) {
        final id = found.first['id'] as int;
        if (phone.trim().isNotEmpty && (found.first['phone'] as String? ?? '').isEmpty) {
          await txn.update('merchant_accounts', {'phone': phone.trim()}, where: 'id = ?', whereArgs: [id]);
        }
        return id;
      }
      return txn.insert('merchant_accounts', {
        'name': cleanName,
        'phone': phone.trim(),
        'notes': '',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  Future<List<Map<String, Object?>>> getMerchants() async {
    final db = await database;
    return db.rawQuery('''
      SELECT m.*,
        (SELECT COUNT(*) FROM merchant_transactions t WHERE t.merchant_id = m.id) AS transaction_count
      FROM merchant_accounts m
      ORDER BY m.name COLLATE NOCASE
    ''');
  }

  Future<List<Map<String, Object?>>> getMerchantTransactions(int merchantId) async {
    final db = await database;
    return db.query('merchant_transactions', where: 'merchant_id = ?', whereArgs: [merchantId], orderBy: 'COALESCE(transaction_date, created_at) DESC, id DESC');
  }

  Future<Map<String, int>> getMerchantTotals(int merchantId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT currency, direction, SUM(amount_minor) AS total_minor
      FROM merchant_transactions WHERE merchant_id = ?
      GROUP BY currency, direction
    ''', [merchantId]);
    final result = <String, int>{};
    for (final row in rows) {
      final key = '${row['currency']}_${row['direction']}';
      result[key] = (row['total_minor'] as num?)?.toInt() ?? 0;
    }
    return result;
  }

  /// Idempotent insert: a repeated export line cannot create a second ledger entry.
  Future<bool> addMerchantTransaction({
    required int merchantId,
    required String sourceKey,
    required String? transactionDate,
    required String sender,
    required String originalMessage,
    required int amountMinor,
    required String currency,
    required String direction,
    required String importBatch,
  }) async {
    if (amountMinor <= 0) throw ArgumentError('المبلغ يجب أن يكون أكبر من صفر');
    if (!supportedCurrencies.contains(currency)) throw ArgumentError('العملة غير مدعومة');
    if (direction != 'paid_to_trader' && direction != 'received_from_trader') {
      throw ArgumentError('لا يمكن تسجيل عملية غير مؤكدة الاتجاه');
    }
    final db = await database;
    try {
      await db.insert('merchant_transactions', {
        'merchant_id': merchantId,
        'source_key': sourceKey,
        'transaction_date': transactionDate,
        'sender': sender,
        'original_message': originalMessage,
        'amount_minor': amountMinor,
        'currency': currency,
        'direction': direction,
        'import_batch': importBatch,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.abort);
      return true;
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) return false;
      rethrow;
    }
  }

  /// Imports a reviewed batch atomically. Validation errors roll back the entire batch;
  /// duplicate source keys are ignored without duplicating ledger rows.
  Future<Map<String, int>> addMerchantTransactionsBatch(List<Map<String, Object?>> rows) async {
    for (final row in rows) {
      if (row['merchant_id'] is! int ||
          row['source_key'] is! String || (row['source_key'] as String).isEmpty ||
          row['original_message'] is! String ||
          row['amount_minor'] is! int || (row['amount_minor'] as int) <= 0 ||
          !supportedCurrencies.contains(row['currency']) ||
          !{'paid_to_trader', 'received_from_trader'}.contains(row['direction'])) {
        throw ArgumentError('توجد عملية غير صالحة؛ لم يتم حفظ الدفعة');
      }
    }
    final db = await database;
    var inserted = 0;
    var duplicates = 0;
    await db.transaction((txn) async {
      for (final row in rows) {
        final result = await txn.insert(
          'merchant_transactions',
          row,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (result == -1) {
          duplicates++;
        } else {
          inserted++;
        }
      }
    });
    return {'inserted': inserted, 'duplicates': duplicates};
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
    final merchants = await db.query('merchant_accounts', orderBy: 'id ASC');
    final merchantTransactions = await db.query('merchant_transactions', orderBy: 'id ASC');
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'almasar_hawalat_backup',
      'schema_version': 2,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'customers': customers,
      'transfers': transfers,
      'merchants': merchants,
      'merchant_transactions': merchantTransactions,
    });
  }

  /// Replaces all local records only after basic validation. All deletes and
  /// inserts run in one SQLite transaction so a failed restore rolls back.
  Future<void> restoreBackup(String backupText) async {
    final decoded = jsonDecode(backupText);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'almasar_hawalat_backup' ||
        !{1, 2}.contains(decoded['schema_version']) ||
        (decoded['schema_version'] == 2 && (decoded['merchants'] is! List || decoded['merchant_transactions'] is! List)) ||
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

    final customerIdList = customerRows.map((row) => row['id'] as int).toList();
    if (customerIdList.toSet().length != customerIdList.length) {
      throw const FormatException('النسخة تحتوي على أرقام عملاء مكررة');
    }
    final customerIds = customerIdList.toSet();
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

    final transferIds = transferRows.map((row) => row['id'] as int).toList();
    final transferReferences = transferRows.map((row) => row['reference'] as String).toList();
    if (transferIds.toSet().length != transferIds.length ||
        transferReferences.toSet().length != transferReferences.length ||
        transferReferences.any((reference) => reference.trim().isEmpty)) {
      throw const FormatException('النسخة تحتوي على أرقام أو مراجع حوالات مكررة أو فارغة');
    }

    // Refuse a backup whose recorded balances contradict its own ledger.
    // This check runs before the destructive replacement transaction.
    validateCustomerLedger(
      customerRows: customerRows,
      transferRows: transferRows,
    );

    final merchantRows = ((decoded['merchants'] as List?) ?? const []).map((value) {
      if (value is! Map) throw const FormatException('بيانات تاجر غير صالحة');
      final row = Map<String, Object?>.from(value);
      if (row['id'] is! int || row['name'] is! String ||
          (row['name'] as String).trim().isEmpty ||
          row['phone'] is! String || row['notes'] is! String ||
          row['created_at'] is! String) {
        throw const FormatException('بيانات تاجر غير صالحة');
      }
      return row;
    }).toList();
    final merchantIdList = merchantRows.map((row) => row['id'] as int).toList();
    final merchantNames = merchantRows.map((row) => (row['name'] as String).trim().toLowerCase()).toList();
    if (merchantIdList.toSet().length != merchantIdList.length ||
        merchantNames.toSet().length != merchantNames.length) {
      throw const FormatException('النسخة تحتوي على أرقام تجار أو أسماء مكررة');
    }
    final merchantIds = merchantIdList.toSet();
    final merchantTransactionRows = ((decoded['merchant_transactions'] as List?) ?? const []).map((value) {
      if (value is! Map) throw const FormatException('بيانات عملية تاجر غير صالحة');
      final row = Map<String, Object?>.from(value);
      if (row['id'] is! int || row['merchant_id'] is! int ||
          !merchantIds.contains(row['merchant_id']) ||
          row['source_key'] is! String || row['original_message'] is! String ||
          row['sender'] is! String || row['amount_minor'] is! int ||
          (row['amount_minor'] as int) <= 0 ||
          !supportedCurrencies.contains(row['currency']) ||
          !{'paid_to_trader', 'received_from_trader'}.contains(row['direction']) ||
          row['import_batch'] is! String || row['created_at'] is! String ||
          (row['transaction_date'] != null && row['transaction_date'] is! String) ||
          (row['exchange_rate_micros'] != null && row['exchange_rate_micros'] is! int)) {
        throw const FormatException('بيانات عملية تاجر غير صالحة');
      }
      return row;
    }).toList();

    final merchantTransactionIds = merchantTransactionRows.map((row) => row['id'] as int).toList();
    final sourceKeys = merchantTransactionRows.map((row) => row['source_key'] as String).toList();
    if (merchantTransactionIds.toSet().length != merchantTransactionIds.length ||
        sourceKeys.toSet().length != sourceKeys.length ||
        sourceKeys.any((key) => key.trim().isEmpty)) {
      throw const FormatException('النسخة تحتوي على أرقام أو مفاتيح عمليات تجار مكررة أو فارغة');
    }

    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('merchant_transactions');
      await txn.delete('merchant_accounts');
      await txn.delete('transfers');
      await txn.delete('customers');
      for (final row in customerRows) {
        await txn.insert('customers', row);
      }
      for (final row in transferRows) {
        await txn.insert('transfers', row);
      }
      for (final row in merchantRows) {
        await txn.insert('merchant_accounts', row);
      }
      for (final row in merchantTransactionRows) {
        await txn.insert('merchant_transactions', row);
      }
    });
  }
}
