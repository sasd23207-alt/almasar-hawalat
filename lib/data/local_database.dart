import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class LocalDatabase {
  LocalDatabase._();

  static final LocalDatabase instance = LocalDatabase._();
  static Database? _database;

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
    return db.query(
      'transfers',
      orderBy: 'id DESC',
      limit: limit,
    );
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
    if (!const {'LYD', 'USD', 'EUR'}.contains(currency)) {
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
      final next = kind == 'deposit' ? current + amountMinor : current - amountMinor;
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
        'amount_minor': amountMinor,
        'currency': customer['currency'],
        'note': note.trim(),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
    return reference;
  }
}
