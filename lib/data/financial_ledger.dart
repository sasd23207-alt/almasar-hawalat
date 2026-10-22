import 'package:sqflite/sqflite.dart';
import '../core/financial_controls.dart';

/// Persistent double-entry journal. Call postTransfer inside the same SQLite
/// transaction as the customer balance and transfer-row mutations.
class FinancialLedger {
  FinancialLedger._();
  static const maximumMinor = 0x7fffffffffffffff;

  static Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS journal_accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        currency TEXT NOT NULL CHECK(currency IN ('LYD','USD','EUR')),
        account_type TEXT NOT NULL CHECK(account_type IN
          ('cash','customer_liability','clearing','fee_income','equity','suspense')),
        customer_id INTEGER,
        active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1)),
        created_at TEXT NOT NULL,
        FOREIGN KEY(customer_id) REFERENCES customers(id)
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS journal_customer_account_unique
      ON journal_accounts(customer_id,currency) WHERE customer_id IS NOT NULL
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS journal_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        reference TEXT NOT NULL UNIQUE,
        transfer_id INTEGER UNIQUE,
        currency TEXT NOT NULL CHECK(currency IN ('LYD','USD','EUR')),
        business_date TEXT NOT NULL,
        created_at TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL CHECK(source IN ('transfer','migration','reversal','adjustment')),
        idempotency_key TEXT NOT NULL UNIQUE,
        reversal_of_entry_id INTEGER UNIQUE,
        debit_total_minor INTEGER NOT NULL CHECK(debit_total_minor > 0),
        credit_total_minor INTEGER NOT NULL CHECK(credit_total_minor > 0),
        status TEXT NOT NULL DEFAULT 'posted' CHECK(status IN ('posted','reversed')),
        CHECK(debit_total_minor = credit_total_minor),
        FOREIGN KEY(transfer_id) REFERENCES transfers(id),
        FOREIGN KEY(reversal_of_entry_id) REFERENCES journal_entries(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS journal_lines (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entry_id INTEGER NOT NULL,
        account_id INTEGER NOT NULL,
        line_number INTEGER NOT NULL CHECK(line_number > 0),
        debit_minor INTEGER NOT NULL DEFAULT 0 CHECK(debit_minor >= 0),
        credit_minor INTEGER NOT NULL DEFAULT 0 CHECK(credit_minor >= 0),
        memo TEXT NOT NULL DEFAULT '',
        UNIQUE(entry_id,line_number),
        CHECK((debit_minor > 0 AND credit_minor = 0) OR
              (credit_minor > 0 AND debit_minor = 0)),
        FOREIGN KEY(entry_id) REFERENCES journal_entries(id) ON DELETE RESTRICT,
        FOREIGN KEY(account_id) REFERENCES journal_accounts(id) ON DELETE RESTRICT
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS journal_entry_date_idx ON journal_entries(business_date,id)');
    await db.execute('CREATE INDEX IF NOT EXISTS journal_line_account_idx ON journal_lines(account_id,entry_id)');
  }

  static void _currency(String currency) {
    if (!FinancialControls.supportedCurrencies.contains(currency)) {
      throw FormatException('عملة دفتر القيود غير مدعومة: $currency');
    }
  }

  static String _date(String timestamp) {
    final parsed = DateTime.tryParse(timestamp);
    if (parsed == null) throw const FormatException('وقت القيد غير صالح');
    return '${parsed.year.toString().padLeft(4,'0')}-${parsed.month.toString().padLeft(2,'0')}-${parsed.day.toString().padLeft(2,'0')}';
  }

  static Future<int> _cash(DatabaseExecutor db, String currency, String now) async {
    await db.insert('journal_accounts', {
      'code':'CASH_$currency','name':'الصندوق - $currency','currency':currency,
      'account_type':'cash','customer_id':null,'active':1,'created_at':now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    final rows = await db.query('journal_accounts', columns:['id'], where:'code = ?', whereArgs:['CASH_$currency'], limit:1);
    if (rows.isEmpty) throw StateError('تعذر إنشاء حساب الصندوق');
    return rows.first['id'] as int;
  }

  static Future<int> _liability(DatabaseExecutor db, int customerId, String name, String currency, String now) async {
    final code = 'CUSTOMER_LIABILITY_${customerId}_$currency';
    await db.insert('journal_accounts', {
      'code':code,'name':'أمانات العميل: $name - $currency','currency':currency,
      'account_type':'customer_liability','customer_id':customerId,'active':1,'created_at':now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    final rows = await db.query('journal_accounts', columns:['id'], where:'customer_id = ? AND currency = ?', whereArgs:[customerId,currency], limit:1);
    if (rows.isEmpty) throw StateError('تعذر إنشاء حساب أمانات العميل');
    return rows.first['id'] as int;
  }

  /// Stores a balanced entry and two immutable-in-practice posting lines.
  /// Database constraints protect balance equality, positive amounts and FKs.
  static Future<int> postTransfer(DatabaseExecutor txn, {
    required int transferId, required String reference, required int customerId,
    required String customerName, required String currency, required String kind,
    required int amountMinor, required String createdAt, required String description,
    String source = 'transfer',
  }) async {
    _currency(currency);
    if (amountMinor <= 0 || amountMinor > maximumMinor) throw const FormatException('مبلغ القيد غير صالح');
    if (kind != 'deposit' && kind != 'withdrawal') throw const FormatException('نوع العملية غير صالح');
    final drafts = [
      JournalLineDraft(accountCode:'CASH_$currency',currency:currency,
        debitMinor:kind == 'deposit' ? amountMinor : 0,
        creditMinor:kind == 'withdrawal' ? amountMinor : 0),
      JournalLineDraft(accountCode:'CUSTOMER_LIABILITY_${customerId}_$currency',currency:currency,
        debitMinor:kind == 'withdrawal' ? amountMinor : 0,
        creditMinor:kind == 'deposit' ? amountMinor : 0),
    ];
    final totals = FinancialControls.validateJournal(drafts);
    final existing = await txn.query('journal_entries', columns:['id'],
      where:'transfer_id = ? OR idempotency_key = ?', whereArgs:[transferId,'transfer:$transferId'], limit:1);
    if (existing.isNotEmpty) throw StateError('القيد موجود مسبقًا لهذه العملية');
    final cashId = await _cash(txn,currency,createdAt);
    final customerAccountId = await _liability(txn,customerId,customerName,currency,createdAt);
    final entryId = await txn.insert('journal_entries', {
      'reference':'JRN-$reference','transfer_id':transferId,'currency':currency,
      'business_date':_date(createdAt),'created_at':createdAt,'description':description,
      'source':source,'idempotency_key':'transfer:$transferId','reversal_of_entry_id':null,
      'debit_total_minor':totals.totalDebitsMinor,'credit_total_minor':totals.totalCreditsMinor,'status':'posted',
    });
    await txn.insert('journal_lines', {
      'entry_id':entryId,'account_id':cashId,'line_number':1,
      'debit_minor':kind == 'deposit' ? amountMinor : 0,
      'credit_minor':kind == 'withdrawal' ? amountMinor : 0,
      'memo':kind == 'deposit' ? 'استلام نقدي' : 'صرف نقدي',
    });
    await txn.insert('journal_lines', {
      'entry_id':entryId,'account_id':customerAccountId,'line_number':2,
      'debit_minor':kind == 'withdrawal' ? amountMinor : 0,
      'credit_minor':kind == 'deposit' ? amountMinor : 0,
      'memo':kind == 'deposit' ? 'زيادة أمانات العميل' : 'تخفيض أمانات العميل',
    });
    return entryId;
  }

  /// Backfills existing transfer rows without changing balances or transfer IDs.
  static Future<int> backfillTransfers(DatabaseExecutor db) async {
    await createSchema(db);
    final transfers = await db.query('transfers', orderBy:'id ASC');
    var inserted = 0;
    for (final t in transfers) {
      final id = t['id'] as int;
      final found = await db.query('journal_entries', columns:['id'], where:'transfer_id = ?', whereArgs:[id], limit:1);
      if (found.isNotEmpty) continue;
      final customer = await db.query('customers', columns:['name','currency'], where:'id = ?', whereArgs:[t['customer_id']], limit:1);
      if (customer.isEmpty) throw StateError('العميل غير موجود أثناء ترحيل الحوالة $id');
      if (customer.first['currency'] != t['currency']) throw StateError('اختلاف عملة الحوالة والعميل رقم $id');
      await postTransfer(db, transferId:id, reference:'MIGRATION-${t['reference']}',
        customerId:t['customer_id'] as int, customerName:t['customer_name'] as String,
        currency:t['currency'] as String, kind:t['kind'] as String,
        amountMinor:t['amount_minor'] as int, createdAt:t['created_at'] as String,
        description:(t['note'] as String?) ?? '', source:'migration');
      inserted++;
    }
    return inserted;
  }

  static Future<List<Map<String,Object?>>> getEntries(DatabaseExecutor db, {
    int limit = 100, int offset = 0, String? currency, String? fromDate, String? throughDate,
  }) async {
    if (limit < 1 || limit > 1000 || offset < 0) throw ArgumentError('حدود استعراض القيود غير صالحة');
    final clauses = <String>[];
    final args = <Object?>[];
    if (currency != null) { _currency(currency); clauses.add('e.currency = ?'); args.add(currency); }
    if (fromDate != null) { clauses.add('e.business_date >= ?'); args.add(fromDate); }
    if (throughDate != null) { clauses.add('e.business_date <= ?'); args.add(throughDate); }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    args.addAll([limit,offset]);
    return db.rawQuery('''SELECT e.*,COUNT(l.id) AS line_count FROM journal_entries e
      LEFT JOIN journal_lines l ON l.entry_id=e.id $where
      GROUP BY e.id ORDER BY e.id DESC LIMIT ? OFFSET ?''',args);
  }

  static Future<Map<String,Object?>?> getEntry(DatabaseExecutor db, int id) async {
    final entries = await db.query('journal_entries',where:'id = ?',whereArgs:[id],limit:1);
    if (entries.isEmpty) return null;
    final lines = await db.rawQuery('''SELECT l.*,a.code AS account_code,a.name AS account_name,
      a.currency AS account_currency,a.account_type FROM journal_lines l
      JOIN journal_accounts a ON a.id=l.account_id WHERE l.entry_id=? ORDER BY l.line_number''',[id]);
    return {'entry':entries.first,'lines':lines};
  }

  /// Reports discrepancies; does not auto-correct financial records.
  static Future<Map<String,Object?>> reconcile(DatabaseExecutor db) async {
    final broken = await db.rawQuery('''SELECT e.id,e.reference,e.debit_total_minor,e.credit_total_minor,
      COALESCE(SUM(l.debit_minor),0) AS line_debits,COALESCE(SUM(l.credit_minor),0) AS line_credits,
      COUNT(l.id) AS line_count,
      SUM(CASE WHEN a.currency != e.currency THEN 1 ELSE 0 END) AS currency_mismatches
      FROM journal_entries e LEFT JOIN journal_lines l ON l.entry_id=e.id
      LEFT JOIN journal_accounts a ON a.id=l.account_id GROUP BY e.id
      HAVING line_count < 2 OR line_debits != e.debit_total_minor OR
      line_credits != e.credit_total_minor OR line_debits != line_credits OR currency_mismatches > 0''');
    final missing = await db.rawQuery('''SELECT t.id,t.reference FROM transfers t
      LEFT JOIN journal_entries e ON e.transfer_id=t.id WHERE e.id IS NULL ORDER BY t.id''');
    final orphaned = await db.rawQuery('''SELECT e.id,e.reference FROM journal_entries e
      LEFT JOIN transfers t ON t.id=e.transfer_id WHERE e.transfer_id IS NOT NULL AND t.id IS NULL''');
    final totals = await db.rawQuery('''SELECT e.currency,SUM(l.debit_minor) AS debits_minor,
      SUM(l.credit_minor) AS credits_minor,COUNT(DISTINCT e.id) AS entry_count
      FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id
      GROUP BY e.currency ORDER BY e.currency''');
    return {'ok':broken.isEmpty && missing.isEmpty && orphaned.isEmpty,
      'broken_entries':broken,'transfers_without_entries':missing,
      'entries_without_transfers':orphaned,'totals_by_currency':totals};
  }

  static Future<Map<String,Object?>> integrityCheck(DatabaseExecutor db) async {
    final quick = await db.rawQuery('PRAGMA quick_check');
    final foreignKeys = await db.rawQuery('PRAGMA foreign_key_check');
    final journal = await reconcile(db);
    return {'ok':quick.length == 1 && quick.first.values.first == 'ok' &&
        foreignKeys.isEmpty && journal['ok'] == true,
      'quick_check':quick,'foreign_key_errors':foreignKeys,'journal':journal};
  }

  /// Returns account balances grouped by currency; no cross-currency sums.
  static Future<List<Map<String,Object?>>> accountBalances(DatabaseExecutor db, {String? currency}) async {
    if (currency != null) _currency(currency);
    final where = currency == null ? '' : 'WHERE a.currency = ?';
    return db.rawQuery('''SELECT a.id,a.code,a.name,a.currency,a.account_type,
      COALESCE(SUM(l.debit_minor),0) AS debits_minor,
      COALESCE(SUM(l.credit_minor),0) AS credits_minor,
      COALESCE(SUM(l.debit_minor-l.credit_minor),0) AS debit_net_minor
      FROM journal_accounts a LEFT JOIN journal_lines l ON l.account_id=a.id
      $where GROUP BY a.id ORDER BY a.currency,a.code''',currency == null ? [] : [currency]);
  }
}
