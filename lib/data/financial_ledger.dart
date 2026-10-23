import 'dart:convert';

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
    await createControlSchema(db);
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
  /// Creates durable control tables used for audit events and accounting periods.
  static Future<void> createControlSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ledger_audit_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event_key TEXT NOT NULL UNIQUE,
        event_type TEXT NOT NULL,
        actor_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        occurred_at TEXT NOT NULL,
        payload TEXT NOT NULL,
        previous_hash TEXT NOT NULL DEFAULT '',
        event_hash TEXT NOT NULL,
        outcome TEXT NOT NULL CHECK(outcome IN ('accepted','rejected','review')),
        CHECK(length(event_key) > 0),
        CHECK(length(actor_id) > 0),
        CHECK(length(event_hash) > 0)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ledger_period_closures (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        currency TEXT NOT NULL CHECK(currency IN ('LYD','USD','EUR')),
        period_start TEXT NOT NULL,
        period_end TEXT NOT NULL,
        closed_at TEXT NOT NULL,
        closed_by TEXT NOT NULL,
        entry_count INTEGER NOT NULL CHECK(entry_count >= 0),
        debit_total_minor INTEGER NOT NULL CHECK(debit_total_minor >= 0),
        credit_total_minor INTEGER NOT NULL CHECK(credit_total_minor >= 0),
        snapshot_hash TEXT NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('closed','reopened')),
        UNIQUE(currency,period_start,period_end),
        CHECK(period_start <= period_end),
        CHECK(debit_total_minor = credit_total_minor)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS ledger_audit_entity_idx
      ON ledger_audit_events(entity_type,entity_id,id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS ledger_audit_time_idx
      ON ledger_audit_events(occurred_at,id)
    ''');
  }

  /// A consistent audit payload must be deterministic; callers should provide
  /// normalized JSON text rather than locale-dependent numbers or dates.
  static String canonicalAuditPayload(Map<String, Object?> fields) {
    final keys = fields.keys.toList()..sort();
    final buffer = StringBuffer();
    for (final key in keys) {
      final value = fields[key];
      final textValue = value == null ? '' : value.toString();
      buffer
        ..write(key.length)
        ..write(':')
        ..write(key)
        ..write('=')
        ..write(textValue.length)
        ..write(':')
        ..write(textValue)
        ..write(';');
    }
    return buffer.toString();
  }

  /// Appends an audit event with a caller-provided cryptographic hash.
  /// Hash calculation is injected so this data layer does not pretend that a
  /// plain checksum is a cryptographic signature. Use SHA-256/HMAC upstream.
  static Future<int> appendAuditEvent(DatabaseExecutor txn, {
    required String eventKey,
    required String eventType,
    required String actorId,
    required String entityType,
    required String entityId,
    required String occurredAt,
    required String payload,
    required String previousHash,
    required String eventHash,
    required String outcome,
  }) async {
    if ([eventKey,eventType,actorId,entityType,entityId,eventHash].any((v) => v.trim().isEmpty)) {
      throw const FormatException('حقول سجل التدقيق الأساسية مطلوبة');
    }
    if (!{'accepted','rejected','review'}.contains(outcome)) {
      throw const FormatException('نتيجة حدث التدقيق غير صالحة');
    }
    final parsed = DateTime.tryParse(occurredAt);
    if (parsed == null || !parsed.isUtc) {
      throw const FormatException('وقت حدث التدقيق يجب أن يكون UTC');
    }
    final previous = await txn.query(
      'ledger_audit_events',
      columns:['event_hash'],
      orderBy:'id DESC',
      limit:1,
    );
    final expectedPrevious = previous.isEmpty ? '' : previous.first['event_hash'] as String;
    if (expectedPrevious != previousHash) {
      throw StateError('تسلسل سجل التدقيق غير متصل؛ أوقف العملية وراجع السجل');
    }
    return txn.insert('ledger_audit_events', {
      'event_key':eventKey,
      'event_type':eventType,
      'actor_id':actorId,
      'entity_type':entityType,
      'entity_id':entityId,
      'occurred_at':occurredAt,
      'payload':payload,
      'previous_hash':previousHash,
      'event_hash':eventHash,
      'outcome':outcome,
    });
  }

  /// Reads the audit chain in sequence. Cryptographic hash verification must
  /// recompute each event hash with the application's selected hash function.
  static Future<Map<String,Object?>> inspectAuditChain(DatabaseExecutor db) async {
    final rows = await db.query('ledger_audit_events', orderBy:'id ASC');
    var expectedPrevious = '';
    final errors = <Map<String,Object?>>[];
    for (final row in rows) {
      final id = row['id'] as int;
      final previous = row['previous_hash'] as String;
      final current = row['event_hash'] as String;
      if (previous != expectedPrevious) {
        errors.add({'id':id,'reason':'previous_hash_mismatch'});
      }
      if (current.trim().isEmpty) {
        errors.add({'id':id,'reason':'empty_event_hash'});
      }
      expectedPrevious = current;
    }
    return {'ok':errors.isEmpty,'event_count':rows.length,'errors':errors,'last_hash':expectedPrevious};
  }

  /// Returns a detailed account statement with running debit/credit totals.
  /// Running totals are computed in Dart with checked integer arithmetic.
  static Future<Map<String,Object?>> accountStatement(DatabaseExecutor db, {
    required int accountId,
    String? fromDate,
    String? throughDate,
    int limit = 500,
  }) async {
    if (limit < 1 || limit > 5000) throw ArgumentError('حد كشف الحساب غير صالح');
    final accounts = await db.query('journal_accounts',where:'id = ?',whereArgs:[accountId],limit:1);
    if (accounts.isEmpty) throw StateError('الحساب غير موجود');
    final account = accounts.first;
    final clauses = <String>['l.account_id = ?'];
    final args = <Object?>[accountId];
    if (fromDate != null) { clauses.add('e.business_date >= ?'); args.add(fromDate); }
    if (throughDate != null) { clauses.add('e.business_date <= ?'); args.add(throughDate); }
    args.add(limit);
    final rows = await db.rawQuery('''
      SELECT e.id AS entry_id,e.reference,e.business_date,e.created_at,
        e.description,e.source,e.status,l.line_number,l.debit_minor,
        l.credit_minor,l.memo
      FROM journal_lines l JOIN journal_entries e ON e.id=l.entry_id
      WHERE ${clauses.join(' AND ')}
      ORDER BY e.business_date ASC,e.id ASC,l.line_number ASC LIMIT ?
    ''',args);
    var debit = 0;
    var credit = 0;
    final statementLines = <Map<String,Object?>>[];
    for (final row in rows) {
      final d = row['debit_minor'] as int;
      final cr = row['credit_minor'] as int;
      debit = _checkedAdd(debit,d);
      credit = _checkedAdd(credit,cr);
      statementLines.add({...row,'running_debits_minor':debit,'running_credits_minor':credit,'running_net_debit_minor':debit-credit});
    }
    return {'account':account,'lines':statementLines,'total_debits_minor':debit,
      'total_credits_minor':credit,'net_debit_minor':debit-credit,'currency':account['currency']};
  }

  static int _checkedAdd(int left, int right) {
    if (right > 0 && left > maximumMinor-right) throw StateError('تجاوز مجموع القيود الحد العددي');
    if (right < 0 && left < -maximumMinor-right) throw StateError('تجاوز مجموع القيود الحد العددي');
    return left+right;
  }

  /// Produces a trial balance at a date. Debits and credits remain separated
  /// by currency to avoid invalid aggregation across LYD, USD and EUR.
  static Future<List<Map<String,Object?>>> trialBalance(DatabaseExecutor db, {
    required String throughDate,
    String? currency,
  }) async {
    if (DateTime.tryParse(throughDate) == null) throw const FormatException('تاريخ ميزان المراجعة غير صالح');
    if (currency != null) _currency(currency);
    final clauses = <String>['e.business_date <= ?'];
    final args = <Object?>[throughDate];
    if (currency != null) { clauses.add('a.currency = ?'); args.add(currency); }
    return db.rawQuery('''
      SELECT a.id,a.code,a.name,a.currency,a.account_type,
        COALESCE(SUM(l.debit_minor),0) AS debit_minor,
        COALESCE(SUM(l.credit_minor),0) AS credit_minor,
        COALESCE(SUM(l.debit_minor-l.credit_minor),0) AS net_debit_minor
      FROM journal_accounts a
      LEFT JOIN journal_lines l ON l.account_id=a.id
      LEFT JOIN journal_entries e ON e.id=l.entry_id
      WHERE ${clauses.join(' AND ')}
      GROUP BY a.id ORDER BY a.currency,a.code
    ''',args);
  }

  /// Calculates control totals from actual journal lines, grouped per currency.
  static Future<List<Map<String,Object?>>> controlTotals(DatabaseExecutor db, {
    String? fromDate,
    String? throughDate,
  }) async {
    final clauses = <String>[];
    final args = <Object?>[];
    if (fromDate != null) { clauses.add('e.business_date >= ?'); args.add(fromDate); }
    if (throughDate != null) { clauses.add('e.business_date <= ?'); args.add(throughDate); }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return db.rawQuery('''
      SELECT e.currency,COUNT(DISTINCT e.id) AS entries,
        COUNT(l.id) AS lines,SUM(l.debit_minor) AS debits_minor,
        SUM(l.credit_minor) AS credits_minor,
        SUM(l.debit_minor)-SUM(l.credit_minor) AS difference_minor
      FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id
      $where GROUP BY e.currency ORDER BY e.currency
    ''',args);
  }

  /// Validates source-transfer details against its posted journal entry.
  static Future<Map<String,Object?>> verifyTransfer(DatabaseExecutor db, int transferId) async {
    final transfers = await db.query('transfers',where:'id = ?',whereArgs:[transferId],limit:1);
    if (transfers.isEmpty) throw StateError('الحوالة غير موجودة');
    final transfer = transfers.first;
    final entries = await db.query('journal_entries',where:'transfer_id = ?',whereArgs:[transferId],limit:1);
    if (entries.isEmpty) return {'ok':false,'reason':'journal_entry_missing','transfer':transfer};
    final entry = entries.first;
    final lines = await db.rawQuery('''
      SELECT l.*,a.code,a.currency AS account_currency,a.account_type,a.customer_id
      FROM journal_lines l JOIN journal_accounts a ON a.id=l.account_id
      WHERE l.entry_id=? ORDER BY l.line_number
    ''',[entry['id']]);
    final amount = transfer['amount_minor'] as int;
    final kind = transfer['kind'] as String;
    final currency = transfer['currency'] as String;
    var cashCorrect = false;
    var liabilityCorrect = false;
    for (final line in lines) {
      if (line['account_type'] == 'cash' && line['account_currency'] == currency) {
        cashCorrect = kind == 'deposit'
          ? line['debit_minor'] == amount && line['credit_minor'] == 0
          : line['credit_minor'] == amount && line['debit_minor'] == 0;
      }
      if (line['account_type'] == 'customer_liability' &&
          line['customer_id'] == transfer['customer_id'] &&
          line['account_currency'] == currency) {
        liabilityCorrect = kind == 'deposit'
          ? line['credit_minor'] == amount && line['debit_minor'] == 0
          : line['debit_minor'] == amount && line['credit_minor'] == 0;
      }
    }
    final balanced = lines.fold<int>(0,(sum,line) => _checkedAdd(sum,line['debit_minor'] as int)) ==
      lines.fold<int>(0,(sum,line) => _checkedAdd(sum,line['credit_minor'] as int));
    return {'ok':cashCorrect && liabilityCorrect && balanced && lines.length == 2,
      'cash_line_correct':cashCorrect,'customer_line_correct':liabilityCorrect,
      'balanced':balanced,'line_count':lines.length,'transfer':transfer,'entry':entry,'lines':lines};
  }

  /// Detects a likely duplicate transfer using customer, type, amount and a
  /// short time window. This is a warning signal, never an automatic rejection.
  static Future<List<Map<String,Object?>>> findPossibleDuplicateTransfers(DatabaseExecutor db, {
    required int customerId,
    required String kind,
    required int amountMinor,
    required String currency,
    required String createdAt,
    int windowSeconds = 120,
  }) async {
    _currency(currency);
    if (windowSeconds < 1 || windowSeconds > 86400) throw ArgumentError('نافذة التكرار غير صالحة');
    final instant = DateTime.tryParse(createdAt);
    if (instant == null) throw const FormatException('وقت العملية غير صالح');
    final from = instant.toUtc().subtract(Duration(seconds:windowSeconds)).toIso8601String();
    final to = instant.toUtc().add(Duration(seconds:windowSeconds)).toIso8601String();
    return db.query('transfers',where:'customer_id = ? AND kind = ? AND amount_minor = ? AND currency = ? AND created_at BETWEEN ? AND ?',
      whereArgs:[customerId,kind,amountMinor,currency,from,to],orderBy:'created_at DESC',limit:20);
  }

  /// Returns immutable snapshots of the accounts referenced by one entry.
  static Future<List<Map<String,Object?>>> entryAccountSnapshots(DatabaseExecutor db, int entryId) async {
    return db.rawQuery('''
      SELECT l.line_number,l.debit_minor,l.credit_minor,l.memo,
        a.code,a.name,a.currency,a.account_type,a.customer_id
      FROM journal_lines l JOIN journal_accounts a ON a.id=l.account_id
      WHERE l.entry_id=? ORDER BY l.line_number
    ''',[entryId]);
  }

  /// Refuses a date range that is already closed for this currency.
  static Future<void> requireOpenPeriod(DatabaseExecutor db, {
    required String currency,
    required String businessDate,
  }) async {
    _currency(currency);
    if (DateTime.tryParse(businessDate) == null) throw const FormatException('تاريخ العمل غير صالح');
    final rows = await db.query('ledger_period_closures',
      where:'currency = ? AND status = ? AND period_start <= ? AND period_end >= ?',
      whereArgs:[currency,'closed',businessDate,businessDate],limit:1);
    if (rows.isNotEmpty) throw StateError('الفترة المحاسبية مغلقة؛ يلزم إجراء إعادة فتح معتمد');
  }

  /// Closes a currency period after checking balance and capturing a stable
  /// summary. Hashing is injected by the caller and should use canonical data.
  static Future<int> closePeriod(DatabaseExecutor txn, {
    required String currency,
    required String periodStart,
    required String periodEnd,
    required String closedAt,
    required String closedBy,
    required String snapshotHash,
  }) async {
    _currency(currency);
    final start = DateTime.tryParse(periodStart);
    final end = DateTime.tryParse(periodEnd);
    final closed = DateTime.tryParse(closedAt);
    if (start == null || end == null || start.isAfter(end)) throw const FormatException('نطاق الفترة المحاسبية غير صالح');
    if (closed == null || !closed.isUtc || closedBy.trim().isEmpty || snapshotHash.trim().isEmpty) {
      throw const FormatException('بيانات إقفال الفترة غير مكتملة');
    }
    final existing = await txn.query('ledger_period_closures',
      where:'currency = ? AND period_start = ? AND period_end = ? AND status = ?',
      whereArgs:[currency,periodStart,periodEnd,'closed'],limit:1);
    if (existing.isNotEmpty) throw StateError('الفترة مغلقة مسبقًا');
    final totals = await txn.rawQuery('''
      SELECT COUNT(DISTINCT e.id) AS entry_count,
        COALESCE(SUM(l.debit_minor),0) AS debit_total,
        COALESCE(SUM(l.credit_minor),0) AS credit_total
      FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id
      WHERE e.currency=? AND e.business_date BETWEEN ? AND ?
    ''',[currency,periodStart,periodEnd]);
    final row = totals.first;
    final debits = row['debit_total'] as int;
    final credits = row['credit_total'] as int;
    if (debits != credits) throw StateError('لا يمكن إقفال فترة غير متوازنة');
    return txn.insert('ledger_period_closures',{
      'currency':currency,'period_start':periodStart,'period_end':periodEnd,
      'closed_at':closedAt,'closed_by':closedBy,'entry_count':row['entry_count'],
      'debit_total_minor':debits,'credit_total_minor':credits,
      'snapshot_hash':snapshotHash,'status':'closed',
    });
  }

  /// Reopening is explicitly audited by requiring both an actor and a reason.
  /// The caller should append a matching audit event in the same transaction.
  static Future<void> reopenPeriod(DatabaseExecutor txn, {
    required int closureId,
    required String actorId,
    required String reason,
  }) async {
    if (actorId.trim().isEmpty || reason.trim().isEmpty) throw const FormatException('هوية المعيد وسبب إعادة الفتح مطلوبان');
    final rows = await txn.query('ledger_period_closures',where:'id = ? AND status = ?',whereArgs:[closureId,'closed'],limit:1);
    if (rows.isEmpty) throw StateError('الإقفال غير موجود أو أُعيد فتحه مسبقًا');
    final changed = await txn.update('ledger_period_closures',{'status':'reopened'},
      where:'id = ? AND status = ?',whereArgs:[closureId,'closed']);
    if (changed != 1) throw StateError('تغيرت حالة الإقفال؛ أعد المحاولة');
  }

  /// Returns closed periods for audit and operator review.
  static Future<List<Map<String,Object?>>> listPeriods(DatabaseExecutor db, {
    String? currency,
    int limit = 100,
  }) async {
    if (limit < 1 || limit > 1000) throw ArgumentError('عدد الفترات غير صالح');
    if (currency != null) _currency(currency);
    return db.query('ledger_period_closures',
      where:currency == null ? null : 'currency = ?',
      whereArgs:currency == null ? null : [currency],
      orderBy:'period_start DESC,id DESC',limit:limit);
  }

  /// Summarizes account balances without netting assets against liabilities.
  static Future<Map<String,Object?>> balanceSheetControls(DatabaseExecutor db, {
    required String throughDate,
  }) async {
    final rows = await trialBalance(db,throughDate:throughDate);
    final grouped = <String,Map<String,int>>{};
    for (final row in rows) {
      final currency = row['currency'] as String;
      final type = row['account_type'] as String;
      final group = grouped.putIfAbsent(currency,()=>{'debit':0,'credit':0});
      group['debit'] = _checkedAdd(group['debit']!,row['debit_minor'] as int);
      group['credit'] = _checkedAdd(group['credit']!,row['credit_minor'] as int);
      // Account classification is retained so reporting can apply the
      // institution's approved normal-balance rules at the presentation layer.
      if (!{'cash','customer_liability','clearing','fee_income','equity','suspense'}.contains(type)) {
        throw StateError('نوع حساب غير معروف في ميزان المراجعة');
      }
    }
    final result = <Map<String,Object?>>[];
    for (final currency in grouped.keys.toList()..sort()) {
      final values = grouped[currency]!;
      result.add({'currency':currency,'debits_minor':values['debit'],
        'credits_minor':values['credit'],'difference_minor':values['debit']!-values['credit']!});
    }
    return {'through_date':throughDate,'currencies':result};
  }

  /// Searches entries by reference or description, using bound SQL parameters.
  static Future<List<Map<String,Object?>>> searchEntries(DatabaseExecutor db, {
    required String query,
    int limit = 100,
  }) async {
    final needle = query.trim();
    if (needle.isEmpty) throw ArgumentError('أدخل مرجعًا أو وصفًا للبحث');
    if (needle.length > 160) throw ArgumentError('نص البحث أطول من المسموح');
    if (limit < 1 || limit > 500) throw ArgumentError('عدد نتائج البحث غير صالح');
    final pattern = '%${needle.replaceAll('%',r'\%').replaceAll('_',r'\_')}%';
    return db.rawQuery('''
      SELECT e.*,COUNT(l.id) AS line_count FROM journal_entries e
      LEFT JOIN journal_lines l ON l.entry_id=e.id
      WHERE e.reference LIKE ? ESCAPE '\\' OR e.description LIKE ? ESCAPE '\\'
      GROUP BY e.id ORDER BY e.id DESC LIMIT ?
    ''',[pattern,pattern,limit]);
  }

  /// Validates the transfer table's balance snapshots against the signed
  /// sum of historical deposits and withdrawals for each customer.
  static Future<List<Map<String,Object?>>> reconcileCustomerBalances(DatabaseExecutor db) async {
    return db.rawQuery('''
      SELECT c.id AS customer_id,c.name,c.currency,c.balance_minor,
        COALESCE(SUM(CASE WHEN t.kind='deposit' THEN t.amount_minor
                          WHEN t.kind='withdrawal' THEN -t.amount_minor ELSE 0 END),0) AS computed_minor
      FROM customers c LEFT JOIN transfers t ON t.customer_id=c.id
      GROUP BY c.id
      HAVING c.balance_minor != computed_minor
      ORDER BY c.id
    ''');
  }

  /// Compares source-transfer totals with posted journal totals per currency.
  static Future<Map<String,Object?>> reconcileTransferTotals(DatabaseExecutor db) async {
    final transferTotals = await db.rawQuery('''
      SELECT currency,
        SUM(CASE WHEN kind='deposit' THEN amount_minor ELSE 0 END) AS deposits_minor,
        SUM(CASE WHEN kind='withdrawal' THEN amount_minor ELSE 0 END) AS withdrawals_minor,
        COUNT(*) AS transfer_count
      FROM transfers GROUP BY currency ORDER BY currency
    ''');
    final journalTotals = await db.rawQuery('''
      SELECT e.currency,SUM(l.debit_minor) AS debits_minor,
        SUM(l.credit_minor) AS credits_minor,COUNT(DISTINCT e.id) AS entry_count
      FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id
      WHERE e.transfer_id IS NOT NULL GROUP BY e.currency ORDER BY e.currency
    ''');
    final missing = await db.rawQuery('''
      SELECT t.id,t.reference,t.currency,t.amount_minor FROM transfers t
      LEFT JOIN journal_entries e ON e.transfer_id=t.id WHERE e.id IS NULL
    ''');
    return {'ok':missing.isEmpty,'transfer_totals':transferTotals,
      'journal_totals':journalTotals,'missing_entries':missing};
  }

  /// Checks the account catalog for duplicate logical codes, missing customer
  /// links, inactive system accounts, or currency mismatches.
  static Future<List<Map<String,Object?>>> validateAccountCatalog(DatabaseExecutor db) async {
    final invalid = await db.rawQuery('''
      SELECT a.id,a.code,a.currency,a.account_type,a.customer_id,
        c.currency AS customer_currency
      FROM journal_accounts a LEFT JOIN customers c ON c.id=a.customer_id
      WHERE (a.account_type='customer_liability' AND
            (a.customer_id IS NULL OR c.id IS NULL OR c.currency != a.currency))
         OR (a.account_type='cash' AND a.code != 'CASH_' || a.currency)
         OR (a.active NOT IN (0,1))
      ORDER BY a.id
    ''');
    return invalid;
  }

  /// Fetches audit events using pagination and optional entity filtering.
  static Future<List<Map<String,Object?>>> listAuditEvents(DatabaseExecutor db, {
    int limit = 100,
    int offset = 0,
    String? entityType,
    String? entityId,
  }) async {
    if (limit < 1 || limit > 1000 || offset < 0) throw ArgumentError('حدود سجل التدقيق غير صالحة');
    final clauses = <String>[];
    final args = <Object?>[];
    if (entityType != null) { clauses.add('entity_type = ?'); args.add(entityType); }
    if (entityId != null) { clauses.add('entity_id = ?'); args.add(entityId); }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    args.addAll([limit,offset]);
    return db.rawQuery('SELECT * FROM ledger_audit_events $where ORDER BY id DESC LIMIT ? OFFSET ?',args);
  }

  /// Records a rejected or review-needed attempt without creating a financial
  /// posting. Use the same transaction as the business decision where possible.
  static Future<int> recordControlEvent(DatabaseExecutor txn, {
    required String eventKey,
    required String eventType,
    required String actorId,
    required String entityType,
    required String entityId,
    required String occurredAt,
    required String payload,
    required String previousHash,
    required String eventHash,
    required String outcome,
  }) async {
    if (outcome == 'accepted') {
      throw ArgumentError('استخدم سجل الحدث المقبول فقط بعد نجاح الإجراء');
    }
    return appendAuditEvent(txn,eventKey:eventKey,eventType:eventType,actorId:actorId,
      entityType:entityType,entityId:entityId,occurredAt:occurredAt,payload:payload,
      previousHash:previousHash,eventHash:eventHash,outcome:outcome);
  }

  /// Performs a full consistency sweep intended for an operator diagnostics
  /// screen or scheduled maintenance task. It reports findings, never fixes
  /// them silently.
  static Future<Map<String,Object?>> fullDiagnostics(DatabaseExecutor db) async {
    final integrity = await integrityCheck(db);
    final customerBalances = await reconcileCustomerBalances(db);
    final transferTotals = await reconcileTransferTotals(db);
    final catalog = await validateAccountCatalog(db);
    final audit = await inspectAuditChain(db);
    final result = <String,Object?>{
      'sqlite_and_foreign_keys':integrity,
      'customer_balance_mismatches':customerBalances,
      'transfer_journal_reconciliation':transferTotals,
      'invalid_accounts':catalog,
      'audit_chain':audit,
    };
    result['ok'] = integrity['ok'] == true && customerBalances.isEmpty &&
      transferTotals['ok'] == true && catalog.isEmpty && audit['ok'] == true;
    return result;
  }

  /// Returns a safe, currency-specific summary suitable for an operations UI.
  static Future<List<Map<String,Object?>>> dashboardSummary(DatabaseExecutor db) async {
    return db.rawQuery('''
      SELECT e.currency,COUNT(DISTINCT e.id) AS entry_count,
        COUNT(l.id) AS line_count,
        COALESCE(SUM(l.debit_minor),0) AS debits_minor,
        COALESCE(SUM(l.credit_minor),0) AS credits_minor,
        COALESCE(SUM(l.debit_minor)-SUM(l.credit_minor),0) AS difference_minor,
        SUM(CASE WHEN e.status='reversed' THEN 1 ELSE 0 END) AS reversed_entries
      FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id
      GROUP BY e.currency ORDER BY e.currency
    ''');
  }

  /// Validates a journal entry before any external reporting or export.
  static Future<void> requireEntryValid(DatabaseExecutor db, int entryId) async {
    final details = await getEntry(db,entryId);
    if (details == null) throw StateError('القيد غير موجود');
    final entry = details['entry'] as Map<String,Object?>;
    final lines = details['lines'] as List<Map<String,Object?>>;
    if (lines.length < 2) throw StateError('القيد يحتوي على أقل من سطرين');
    var debits = 0;
    var credits = 0;
    for (final line in lines) {
      final d = line['debit_minor'] as int;
      final cr = line['credit_minor'] as int;
      if (d < 0 || cr < 0 || (d == 0) == (cr == 0)) {
        throw StateError('سطر قيد غير صالح');
      }
      if (line['account_currency'] != entry['currency']) {
        throw StateError('عملة الحساب لا تطابق عملة القيد');
      }
      debits = _checkedAdd(debits,d);
      credits = _checkedAdd(credits,cr);
    }
    if (debits != credits || debits != entry['debit_total_minor'] ||
        credits != entry['credit_total_minor']) {
      throw StateError('القيد غير متوازن أو لا يطابق إجمالي رأس القيد');
    }
  }

  /// Rebuilds all totals from immutable line details and flags mismatched
  /// headers. It deliberately does not mutate the source ledger.
  static Future<List<Map<String,Object?>>> findHeaderTotalMismatches(DatabaseExecutor db) async {
    return db.rawQuery('''
      SELECT e.id,e.reference,e.debit_total_minor,e.credit_total_minor,
        COALESCE(SUM(l.debit_minor),0) AS actual_debits,
        COALESCE(SUM(l.credit_minor),0) AS actual_credits
      FROM journal_entries e LEFT JOIN journal_lines l ON l.entry_id=e.id
      GROUP BY e.id
      HAVING e.debit_total_minor != actual_debits OR
        e.credit_total_minor != actual_credits OR actual_debits != actual_credits
      ORDER BY e.id
    ''');
  }

  /// Lists the most recent movements for a customer liability account.
  static Future<List<Map<String,Object?>>> customerLedger(DatabaseExecutor db, {
    required int customerId,
    int limit = 200,
  }) async {
    if (limit < 1 || limit > 2000) throw ArgumentError('عدد حركات العميل غير صالح');
    final accounts = await db.query('journal_accounts',
      where:'customer_id = ? AND account_type = ?',whereArgs:[customerId,'customer_liability']);
    if (accounts.isEmpty) return [];
    final ids = accounts.map((row)=>row['id'] as int).toList();
    final placeholders = List.filled(ids.length,'?').join(',');
    return db.rawQuery('''
      SELECT e.id AS entry_id,e.reference,e.business_date,e.created_at,e.description,
        e.currency,e.status,l.debit_minor,l.credit_minor,l.memo,a.code AS account_code
      FROM journal_lines l JOIN journal_entries e ON e.id=l.entry_id
      JOIN journal_accounts a ON a.id=l.account_id
      WHERE a.id IN ($placeholders) ORDER BY e.id DESC LIMIT ?
    ''',[...ids,limit]);
  }

  /// Exports only journal information as a portable JSON document. Sensitive
  /// customer data is not joined into this file unless explicitly requested.
  static Future<String> exportJournal(DatabaseExecutor db, {int limit = 100000}) async {
    if (limit < 1 || limit > 500000) throw ArgumentError('حد التصدير غير صالح');
    final entries = await db.query('journal_entries',orderBy:'id ASC',limit:limit);
    final lines = await db.query('journal_lines',orderBy:'entry_id ASC,line_number ASC');
    final accountRows = await db.query('journal_accounts',orderBy:'id ASC');
    return const JsonEncoder.withIndent('  ').convert({
      'format':'almasar_hawalat_journal',
      'version':1,
      'exported_at':DateTime.now().toUtc().toIso8601String(),
      'accounts':accountRows,
      'entries':entries,
      'lines':lines,
    });
  }

  /// Validates a journal export without importing it. Import should be a
  /// separately authorized workflow with complete foreign-key remapping.
  static Future<Map<String,Object?>> validateJournalExport(String text) async {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String,dynamic> || decoded['format'] != 'almasar_hawalat_journal' ||
        decoded['version'] != 1 || decoded['accounts'] is! List ||
        decoded['entries'] is! List || decoded['lines'] is! List) {
      throw const FormatException('ملف دفتر القيود غير معروف');
    }
    final accounts = decoded['accounts'] as List;
    final entries = decoded['entries'] as List;
    final lines = decoded['lines'] as List;
    final accountIds = <int>{};
    final codes = <String>{};
    for (final item in accounts) {
      if (item is! Map || item['id'] is! int || item['code'] is! String ||
          item['currency'] is! String || item['account_type'] is! String) {
        throw const FormatException('حساب غير صالح في ملف القيود');
      }
      _currency(item['currency'] as String);
      if (!accountIds.add(item['id'] as int) || !codes.add(item['code'] as String)) {
        throw const FormatException('حسابات مكررة في ملف القيود');
      }
    }
    final entryIds = <int>{};
    final references = <String>{};
    for (final item in entries) {
      if (item is! Map || item['id'] is! int || item['reference'] is! String ||
          item['currency'] is! String || item['debit_total_minor'] is! int ||
          item['credit_total_minor'] is! int ||
          item['debit_total_minor'] != item['credit_total_minor']) {
        throw const FormatException('رأس قيد غير صالح في ملف القيود');
      }
      _currency(item['currency'] as String);
      if (!entryIds.add(item['id'] as int) || !references.add(item['reference'] as String)) {
        throw const FormatException('قيود مكررة في ملف القيود');
      }
    }
    final totals = <int,Map<String,int>>{};
    for (final item in lines) {
      if (item is! Map || item['entry_id'] is! int || item['account_id'] is! int ||
          item['debit_minor'] is! int || item['credit_minor'] is! int) {
        throw const FormatException('سطر قيد غير صالح في ملف القيود');
      }
      if (!entryIds.contains(item['entry_id'] as int) || !accountIds.contains(item['account_id'] as int)) {
        throw const FormatException('سطر يشير إلى قيد أو حساب غير موجود');
      }
      final d = item['debit_minor'] as int;
      final cr = item['credit_minor'] as int;
      if (d < 0 || cr < 0 || (d == 0) == (cr == 0)) {
        throw const FormatException('مبلغ مدين/دائن غير صالح');
      }
      final id = item['entry_id'] as int;
      final bucket = totals.putIfAbsent(id,()=>{'debit':0,'credit':0,'count':0});
      bucket['debit'] = _checkedAdd(bucket['debit']!,d);
      bucket['credit'] = _checkedAdd(bucket['credit']!,cr);
      bucket['count'] = bucket['count']!+1;
    }
    final errors = <Map<String,Object?>>[];
    for (final entry in entries) {
      final id = entry['id'] as int;
      final bucket = totals[id] ?? {'debit':0,'credit':0,'count':0};
      if (bucket['count']! < 2 || bucket['debit'] != entry['debit_total_minor'] ||
          bucket['credit'] != entry['credit_total_minor'] || bucket['debit'] != bucket['credit']) {
        errors.add({'entry_id':id,'reason':'unbalanced_or_incomplete'});
      }
    }
    return {'ok':errors.isEmpty,'accounts':accounts.length,'entries':entries.length,
      'lines':lines.length,'errors':errors};
  }

  /// Ensures a reference is unique before a caller starts an expensive workflow.
  /// The unique database index remains the final race-condition-safe guard.
  static Future<bool> referenceExists(DatabaseExecutor db, String reference) async {
    final clean = reference.trim();
    if (clean.isEmpty) throw ArgumentError('مرجع القيد مطلوب');
    final rows = await db.query('journal_entries',columns:['id'],
      where:'reference = ?',whereArgs:[clean],limit:1);
    return rows.isNotEmpty;
  }

  /// Validates date boundaries in ISO calendar format before applying filters.
  static void validateDateRange(String? fromDate, String? throughDate) {
    DateTime? from;
    DateTime? through;
    if (fromDate != null) {
      from = DateTime.tryParse(fromDate);
      if (from == null || fromDate.length < 10) throw const FormatException('تاريخ البداية غير صالح');
    }
    if (throughDate != null) {
      through = DateTime.tryParse(throughDate);
      if (through == null || throughDate.length < 10) throw const FormatException('تاريخ النهاية غير صالح');
    }
    if (from != null && through != null && from.isAfter(through)) {
      throw const FormatException('تاريخ البداية يأتي بعد تاريخ النهاية');
    }
  }

  /// Provides a compact reconciliation exception without changing the ledger.
  static Map<String,Object?> reconciliationException({
    required String code,
    required String severity,
    required String entityType,
    required String entityId,
    required String message,
    required String detectedAt,
  }) {
    if (code.trim().isEmpty || entityType.trim().isEmpty || entityId.trim().isEmpty ||
        message.trim().isEmpty) throw const FormatException('بيانات استثناء المطابقة ناقصة');
    if (!{'info','warning','critical'}.contains(severity)) throw ArgumentError('درجة الخطورة غير صالحة');
    final date = DateTime.tryParse(detectedAt);
    if (date == null || !date.isUtc) throw const FormatException('وقت اكتشاف الاستثناء يجب أن يكون UTC');
    return {'code':code,'severity':severity,'entity_type':entityType,'entity_id':entityId,
      'message':message,'detected_at':detectedAt,'status':'open'};
  }

  /// Builds a controlled export manifest so a backup can be compared later.
  static Future<Map<String,Object?>> exportManifest(DatabaseExecutor db) async {
    final tables = <String>['journal_accounts','journal_entries','journal_lines','ledger_audit_events','ledger_period_closures'];
    final counts = <String,int>{};
    for (final table in tables) {
      final rows = await db.rawQuery('SELECT COUNT(*) AS count FROM $table');
      counts[table] = rows.first['count'] as int;
    }
    final control = await controlTotals(db);
    return {'format':'almasar_hawalat_ledger_manifest','version':1,
      'created_at':DateTime.now().toUtc().toIso8601String(),'counts':counts,
      'control_totals':control};
  }

  /// Reports accounts with non-zero movement that have been marked inactive.
  static Future<List<Map<String,Object?>>> inactiveAccountsWithActivity(DatabaseExecutor db) async {
    return db.rawQuery('''
      SELECT a.id,a.code,a.name,a.currency,a.account_type,
        COUNT(l.id) AS line_count,
        COALESCE(SUM(l.debit_minor),0) AS debits_minor,
        COALESCE(SUM(l.credit_minor),0) AS credits_minor
      FROM journal_accounts a JOIN journal_lines l ON l.account_id=a.id
      WHERE a.active=0 GROUP BY a.id ORDER BY a.currency,a.code
    ''');
  }

  /// Validates that every posted entry has at least two lines and balanced totals.
  static Future<void> requireWholeLedgerBalanced(DatabaseExecutor db) async {
    final report = await reconcile(db);
    if (report['ok'] != true) throw StateError('فشل فحص دفتر القيود: ${report.toString()}');
    final mismatches = await findHeaderTotalMismatches(db);
    if (mismatches.isNotEmpty) throw StateError('توجد رؤوس قيود لا تطابق سطورها');
  }

  /// Calculates the net movement for a single account in a period.
  static Future<Map<String,Object?>> accountPeriodMovement(DatabaseExecutor db, {
    required int accountId,
    required String fromDate,
    required String throughDate,
  }) async {
    validateDateRange(fromDate,throughDate);
    final accounts = await db.query('journal_accounts',where:'id = ?',whereArgs:[accountId],limit:1);
    if (accounts.isEmpty) throw StateError('الحساب غير موجود');
    final rows = await db.rawQuery('''
      SELECT COUNT(l.id) AS line_count,COALESCE(SUM(l.debit_minor),0) AS debits,
        COALESCE(SUM(l.credit_minor),0) AS credits
      FROM journal_lines l JOIN journal_entries e ON e.id=l.entry_id
      WHERE l.account_id=? AND e.business_date BETWEEN ? AND ?
    ''',[accountId,fromDate,throughDate]);
    final row = rows.first;
    return {'account':accounts.first,'from_date':fromDate,'through_date':throughDate,
      'line_count':row['line_count'],'debits_minor':row['debits'],
      'credits_minor':row['credits'],'net_debit_minor':(row['debits'] as int)-(row['credits'] as int)};
  }

  /// Lists recent activity grouped by source, helpful for operational review.
  static Future<List<Map<String,Object?>>> activityBySource(DatabaseExecutor db, {
    String? currency,
    String? fromDate,
    String? throughDate,
  }) async {
    validateDateRange(fromDate,throughDate);
    final clauses = <String>[];
    final args = <Object?>[];
    if (currency != null) { _currency(currency); clauses.add('e.currency=?'); args.add(currency); }
    if (fromDate != null) { clauses.add('e.business_date>=?'); args.add(fromDate); }
    if (throughDate != null) { clauses.add('e.business_date<=?'); args.add(throughDate); }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return db.rawQuery('''
      SELECT e.currency,e.source,COUNT(DISTINCT e.id) AS entry_count,
        SUM(l.debit_minor) AS debit_minor,SUM(l.credit_minor) AS credit_minor
      FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id
      $where GROUP BY e.currency,e.source ORDER BY e.currency,e.source
    ''',args);
  }

  /// Makes an idempotent external operation key within the journal's namespace.
  static String idempotencyKey(String operation, String stableId) {
    final op = operation.trim().toLowerCase();
    final id = stableId.trim();
    if (op.isEmpty || id.isEmpty || op.contains(':') || id.contains(':')) {
      throw ArgumentError('مفتاح منع التكرار غير صالح');
    }
    return '$op:$id';
  }

  /// Returns the database-level constraints expected by this ledger version.
  /// Diagnostics can show this to support staff without exposing customer data.
  static Map<String,Object?> schemaCapabilities() => {
    'journal_tables':['journal_accounts','journal_entries','journal_lines'],
    'control_tables':['ledger_audit_events','ledger_period_closures'],
    'currencies':['LYD','USD','EUR'],
    'amount_representation':'integer_minor_units',
    'entry_policy':'balanced_single_currency',
    'correction_policy':'reversal_entries',
    'transfer_linkage':'unique_transfer_id',
    'idempotency':'unique_key',
    'foreign_key_check':'required',
  };

  /// Checks that an account belongs to the expected currency before posting.
  static Future<void> requireAccountCurrency(DatabaseExecutor db, {
    required int accountId,
    required String currency,
  }) async {
    _currency(currency);
    final rows = await db.query('journal_accounts',columns:['currency','active'],
      where:'id=?',whereArgs:[accountId],limit:1);
    if (rows.isEmpty) throw StateError('الحساب غير موجود');
    if (rows.first['currency'] != currency) throw StateError('عملة الحساب لا تطابق عملة العملية');
    if (rows.first['active'] != 1) throw StateError('الحساب معطل ولا يقبل قيودًا جديدة');
  }

  /// Builds a deterministic record used by backup comparison and audit hashing.
  static String canonicalEntryFingerprint(Map<String,Object?> entry, List<Map<String,Object?>> lines) {
    final entryKeys = entry.keys.toList()..sort();
    final buffer = StringBuffer('ENTRY|');
    for (final key in entryKeys) {
      final value = entry[key]?.toString() ?? '';
      buffer.write('${key.length}:$key=${value.length}:$value;');
    }
    final sortedLines = [...lines]..sort((a,b) =>
      (a['line_number'] as int).compareTo(b['line_number'] as int));
    for (final line in sortedLines) {
      buffer.write('LINE|');
      for (final key in ['line_number','account_id','debit_minor','credit_minor','memo']) {
        final value = line[key]?.toString() ?? '';
        buffer.write('${key.length}:$key=${value.length}:$value;');
      }
    }
    return buffer.toString();
  }

  /// Compares two entry fingerprints. Hash them with a cryptographic digest
  /// before storing or transmitting them; this method only compares canonical
  /// payloads and is not itself a security primitive.
  static bool entriesEquivalent(Map<String,Object?> leftEntry, List<Map<String,Object?>> leftLines,
      Map<String,Object?> rightEntry, List<Map<String,Object?>> rightLines) {
    return canonicalEntryFingerprint(leftEntry,leftLines) ==
      canonicalEntryFingerprint(rightEntry,rightLines);
  }

  /// Reads the last journal sequence number for health monitoring.
  static Future<int> lastEntryId(DatabaseExecutor db) async {
    final rows = await db.rawQuery('SELECT COALESCE(MAX(id),0) AS last_id FROM journal_entries');
    return rows.first['last_id'] as int;
  }

  /// Returns a safe summary of a currency account without exposing its linked
  /// customer's phone number or other personal information.
  static Future<Map<String,Object?>> accountSummary(DatabaseExecutor db, int accountId) async {
    final rows = await db.rawQuery('''
      SELECT a.id,a.code,a.name,a.currency,a.account_type,a.active,
        COUNT(l.id) AS line_count,COALESCE(SUM(l.debit_minor),0) AS debits_minor,
        COALESCE(SUM(l.credit_minor),0) AS credits_minor
      FROM journal_accounts a LEFT JOIN journal_lines l ON l.account_id=a.id
      WHERE a.id=? GROUP BY a.id
    ''',[accountId]);
    if (rows.isEmpty) throw StateError('الحساب غير موجود');
    return rows.first;
  }

  /// Detects whether the journal contains a gap between its transfer rows and
  /// journal entry sequence; this is diagnostic and does not imply tampering.
  static Future<Map<String,Object?>> sequenceSummary(DatabaseExecutor db) async {
    final entries = await db.rawQuery('SELECT COUNT(*) AS n,MIN(id) AS first_id,MAX(id) AS last_id FROM journal_entries');
    final transfers = await db.rawQuery('SELECT COUNT(*) AS n,MIN(id) AS first_id,MAX(id) AS last_id FROM transfers');
    return {'entries':entries.first,'transfers':transfers.first};
  }

  /// Validates all account references in a set of lines before a bulk report.
  static Future<void> requireAccountsExist(DatabaseExecutor db, Iterable<int> accountIds) async {
    final ids = accountIds.toSet();
    for (final id in ids) {
      final rows = await db.query('journal_accounts',columns:['id'],where:'id=?',whereArgs:[id],limit:1);
      if (rows.isEmpty) throw StateError('حساب مفقود: $id');
    }
  }

  /// Groups ledger totals by business date for cash reconciliation worksheets.
  static Future<List<Map<String,Object?>>> dailyControlTotals(DatabaseExecutor db, {
    required String fromDate,
    required String throughDate,
    String? currency,
  }) async {
    validateDateRange(fromDate,throughDate);
    if (currency != null) _currency(currency);
    final clauses = <String>['e.business_date BETWEEN ? AND ?'];
    final args = <Object?>[fromDate,throughDate];
    if (currency != null) { clauses.add('e.currency=?'); args.add(currency); }
    return db.rawQuery('''
      SELECT e.business_date,e.currency,COUNT(DISTINCT e.id) AS entry_count,
        SUM(l.debit_minor) AS debits_minor,SUM(l.credit_minor) AS credits_minor,
        SUM(l.debit_minor)-SUM(l.credit_minor) AS difference_minor
      FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id
      WHERE ${clauses.join(' AND ')}
      GROUP BY e.business_date,e.currency ORDER BY e.business_date,e.currency
    ''',args);
  }

  /// Verifies that each account's posted lines use the account's own currency.
  static Future<List<Map<String,Object?>>> findCurrencyMismatches(DatabaseExecutor db) async {
    return db.rawQuery('''
      SELECT e.id AS entry_id,e.reference,e.currency AS entry_currency,
        l.id AS line_id,a.code AS account_code,a.currency AS account_currency
      FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id
      JOIN journal_accounts a ON a.id=l.account_id
      WHERE e.currency != a.currency ORDER BY e.id,l.line_number
    ''');
  }

  /// Checks for unbalanced currency totals over a selected date range.
  static Future<List<Map<String,Object?>>> findUnbalancedDailyTotals(DatabaseExecutor db, {
    required String fromDate,
    required String throughDate,
  }) async {
    validateDateRange(fromDate,throughDate);
    return db.rawQuery('''
      SELECT e.business_date,e.currency,SUM(l.debit_minor) AS debits_minor,
        SUM(l.credit_minor) AS credits_minor
      FROM journal_entries e JOIN journal_lines l ON l.entry_id=e.id
      WHERE e.business_date BETWEEN ? AND ?
      GROUP BY e.business_date,e.currency
      HAVING debits_minor != credits_minor
      ORDER BY e.business_date,e.currency
    ''',[fromDate,throughDate]);
  }

  /// Reads the journal entry that represents a source transfer, if present.
  static Future<Map<String,Object?>?> entryForTransfer(DatabaseExecutor db, int transferId) async {
    final rows = await db.query('journal_entries',where:'transfer_id=?',whereArgs:[transferId],limit:1);
    if (rows.isEmpty) return null;
    return getEntry(db,rows.first['id'] as int);
  }

  /// A migration preflight for administrators: reports transfer rows that
  /// cannot be safely represented by the single-currency two-line template.
  static Future<List<Map<String,Object?>>> migrationPreflight(DatabaseExecutor db) async {
    return db.rawQuery('''
      SELECT t.id,t.reference,t.kind,t.amount_minor,t.currency,
        c.currency AS customer_currency,c.id AS matched_customer
      FROM transfers t LEFT JOIN customers c ON c.id=t.customer_id
      WHERE c.id IS NULL OR c.currency != t.currency OR t.amount_minor <= 0
        OR t.kind NOT IN ('deposit','withdrawal')
      ORDER BY t.id
    ''');
  }

  /// Creates a read-only-like summary for a reviewer; it deliberately contains
  /// no controls that could alter a financial record.
  static Future<Map<String,Object?>> reviewerPack(DatabaseExecutor db, {
    required String fromDate,
    required String throughDate,
  }) async {
    validateDateRange(fromDate,throughDate);
    final diagnostics = await fullDiagnostics(db);
    final daily = await dailyControlTotals(db,fromDate:fromDate,throughDate:throughDate);
    final periods = await listPeriods(db,limit:1000);
    final audit = await inspectAuditChain(db);
    return {'range':{'from':fromDate,'through':throughDate},
      'diagnostics':diagnostics,'daily_totals':daily,'periods':periods,
      'audit_chain':audit,'generated_at':DateTime.now().toUtc().toIso8601String()};
  }

  /// Produces a report of posted versus reversed entries by currency.
  static Future<List<Map<String,Object?>>> reversalSummary(DatabaseExecutor db) async {
    return db.rawQuery('''
      SELECT currency,status,COUNT(*) AS entry_count,
        SUM(debit_total_minor) AS debits_minor,
        SUM(credit_total_minor) AS credits_minor
      FROM journal_entries GROUP BY currency,status ORDER BY currency,status
    ''');
  }

  /// Returns reversal relationships, retaining both the original and reversal.
  static Future<List<Map<String,Object?>>> reversalHistory(DatabaseExecutor db, {
    int limit = 200,
  }) async {
    if (limit < 1 || limit > 2000) throw ArgumentError('عدد عمليات العكس غير صالح');
    return db.rawQuery('''
      SELECT original.id AS original_id,original.reference AS original_reference,
        original.status AS original_status,reversal.id AS reversal_id,
        reversal.reference AS reversal_reference,reversal.created_at AS reversed_at,
        reversal.description AS reversal_description
      FROM journal_entries original
      LEFT JOIN journal_entries reversal ON reversal.reversal_of_entry_id=original.id
      WHERE original.reversal_of_entry_id IS NULL
      ORDER BY original.id DESC LIMIT ?
    ''',[limit]);
  }

  /// Checks an entry reference before generating a human-readable receipt.
  static Future<Map<String,Object?>> receiptData(DatabaseExecutor db, int entryId) async {
    final details = await getEntry(db,entryId);
    if (details == null) throw StateError('القيد غير موجود');
    await requireEntryValid(db,entryId);
    final entry = details['entry'] as Map<String,Object?>;
    return {'reference':entry['reference'],'date':entry['business_date'],
      'created_at':entry['created_at'],'currency':entry['currency'],
      'description':entry['description'],'status':entry['status'],
      'lines':details['lines'],'debit_total_minor':entry['debit_total_minor'],
      'credit_total_minor':entry['credit_total_minor']};
  }

  /// Returns the count of entries for an inclusive business-date range.
  static Future<int> countEntries(DatabaseExecutor db, {
    String? fromDate,
    String? throughDate,
    String? currency,
  }) async {
    validateDateRange(fromDate,throughDate);
    final clauses = <String>[];
    final args = <Object?>[];
    if (fromDate != null) { clauses.add('business_date >= ?'); args.add(fromDate); }
    if (throughDate != null) { clauses.add('business_date <= ?'); args.add(throughDate); }
    if (currency != null) { _currency(currency); clauses.add('currency = ?'); args.add(currency); }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM journal_entries $where',args);
    return rows.first['n'] as int;
  }

  /// Returns a list of account codes that should be present for active currencies.
  static Future<List<String>> missingCashAccounts(DatabaseExecutor db) async {
    final currencies = await db.rawQuery('SELECT DISTINCT currency FROM customers');
    final missing = <String>[];
    for (final row in currencies) {
      final currency = row['currency'] as String;
      final account = await db.query('journal_accounts',columns:['id'],
        where:'code=?',whereArgs:['CASH_$currency'],limit:1);
      if (account.isEmpty) missing.add('CASH_$currency');
    }
    return missing;
  }

  /// Reconciles journal-account balances to their detailed posting lines.
  static Future<List<Map<String,Object?>>> accountLineReconciliation(DatabaseExecutor db) async {
    return db.rawQuery('''
      SELECT a.id,a.code,a.currency,COUNT(l.id) AS line_count,
        COALESCE(SUM(l.debit_minor),0) AS debit_minor,
        COALESCE(SUM(l.credit_minor),0) AS credit_minor
      FROM journal_accounts a LEFT JOIN journal_lines l ON l.account_id=a.id
      GROUP BY a.id ORDER BY a.currency,a.code
    ''');
  }

  /// Converts minor units to a fixed-scale decimal string without floating point.
  static String formatMinorUnits(int value, {int decimals = 2}) {
    if (decimals < 0 || decimals > 6) throw ArgumentError('عدد المنازل العشرية غير صالح');
    final negative = value < 0;
    final absolute = value.abs();
    var scale = 1;
    for (var i=0;i<decimals;i++) { scale *= 10; }
    final whole = absolute ~/ scale;
    final fraction = (absolute % scale).toString().padLeft(decimals,'0');
    return '${negative ? '-' : ''}$whole${decimals == 0 ? '' : '.$fraction'}';
  }

  /// Parses a decimal amount into minor units without using binary floating point.
  static int parseMinorUnits(String input, {int decimals = 2}) {
    if (decimals < 0 || decimals > 6) throw ArgumentError('عدد المنازل العشرية غير صالح');
    final clean = input.trim().replaceAll(',','');
    final match = RegExp(r'^([+-]?)([0-9]+)(?:\.([0-9]+))?$').firstMatch(clean);
    if (match == null) throw const FormatException('صيغة المبلغ غير صحيحة');
    final fraction = match.group(3) ?? '';
    if (fraction.length > decimals) throw const FormatException('عدد المنازل العشرية أكبر من المسموح');
    var scale = 1;
    for (var i=0;i<decimals;i++) { scale *= 10; }
    final whole = int.parse(match.group(2)!);
    final paddedFraction = fraction.padRight(decimals,'0');
    final fractional = paddedFraction.isEmpty ? 0 : int.parse(paddedFraction);
    if (whole > (maximumMinor-fractional) ~/ scale) throw const FormatException('المبلغ أكبر من الحد العددي');
    final value = whole*scale+fractional;
    return match.group(1) == '-' ? -value : value;
  }

  /// Creates a normalized, non-sensitive event for audit and monitoring.
  static Map<String,Object?> auditMetadata({
    required String operation,
    required String actorId,
    required String entityType,
    required String entityId,
    required String timestamp,
    Map<String,Object?> extra = const {},
  }) {
    if (operation.trim().isEmpty || actorId.trim().isEmpty ||
        entityType.trim().isEmpty || entityId.trim().isEmpty) {
      throw const FormatException('بيانات التدقيق الأساسية ناقصة');
    }
    final parsed = DateTime.tryParse(timestamp);
    if (parsed == null || !parsed.isUtc) throw const FormatException('وقت التدقيق يجب أن يكون UTC');
    final safeExtra = <String,Object?>{};
    for (final entry in extra.entries) {
      final key = entry.key.toLowerCase();
      if (key.contains('password') || key.contains('secret') || key.contains('token') ||
          key.contains('phone') || key.contains('pin')) continue;
      safeExtra[entry.key] = entry.value;
    }
    return {'operation':operation,'actor_id':actorId,'entity_type':entityType,
      'entity_id':entityId,'timestamp':timestamp,'extra':safeExtra};
  }

  /// Returns a deterministic list of findings for a support case.
  static Future<List<Map<String,Object?>>> findings(DatabaseExecutor db) async {
    final result = <Map<String,Object?>>[];
    final integrity = await integrityCheck(db);
    if (integrity['ok'] != true) result.add({'severity':'critical','code':'SQLITE_OR_LEDGER_INTEGRITY'});
    final customerMismatch = await reconcileCustomerBalances(db);
    for (final item in customerMismatch) {
      result.add({'severity':'critical','code':'CUSTOMER_BALANCE_MISMATCH','entity_id':item['customer_id']});
    }
    final missing = await db.rawQuery('SELECT id FROM transfers t WHERE NOT EXISTS (SELECT 1 FROM journal_entries e WHERE e.transfer_id=t.id)');
    for (final item in missing) {
      result.add({'severity':'critical','code':'TRANSFER_WITHOUT_JOURNAL','entity_id':item['id']});
    }
    final headerMismatches = await findHeaderTotalMismatches(db);
    for (final item in headerMismatches) {
      result.add({'severity':'critical','code':'JOURNAL_HEADER_MISMATCH','entity_id':item['id']});
    }
    final currencies = await findCurrencyMismatches(db);
    for (final item in currencies) {
      result.add({'severity':'critical','code':'CURRENCY_MISMATCH','entity_id':item['entry_id']});
    }
    return result;
  }

  /// Creates a bounded query window for recent records.
  static Future<List<Map<String,Object?>>> recentEntries(DatabaseExecutor db, {
    int days = 7,
    int limit = 100,
  }) async {
    if (days < 1 || days > 3650 || limit < 1 || limit > 1000) throw ArgumentError('نافذة الاستعراض غير صالحة');
    final cutoff = DateTime.now().toUtc().subtract(Duration(days:days)).toIso8601String().substring(0,10);
    return db.query('journal_entries',where:'business_date >= ?',whereArgs:[cutoff],orderBy:'id DESC',limit:limit);
  }

  /// Checks if all journal entries have the expected source classification.
  static Future<List<Map<String,Object?>>> invalidSources(DatabaseExecutor db) async {
    return db.rawQuery('''
      SELECT id,reference,source FROM journal_entries
      WHERE source NOT IN ('transfer','migration','reversal','adjustment')
      ORDER BY id
    ''');
  }

  /// Returns journal counts by source and status for reconciliation reports.
  static Future<List<Map<String,Object?>>> sourceStatusCounts(DatabaseExecutor db) async {
    return db.rawQuery('''
      SELECT source,status,currency,COUNT(*) AS count,
        SUM(debit_total_minor) AS debit_total_minor,
        SUM(credit_total_minor) AS credit_total_minor
      FROM journal_entries GROUP BY source,status,currency
      ORDER BY currency,source,status
    ''');
  }

  /// A pre-posting guard that ensures the customer has a liability account and
  /// the cash account exists, creating neither account as a side effect.
  static Future<void> requirePostingAccounts(DatabaseExecutor db, {
    required int customerId,
    required String currency,
  }) async {
    _currency(currency);
    final cash = await db.query('journal_accounts',columns:['id','active'],
      where:'code=? AND currency=?',whereArgs:['CASH_$currency',currency],limit:1);
    final liability = await db.query('journal_accounts',columns:['id','active'],
      where:'customer_id=? AND currency=? AND account_type=?',
      whereArgs:[customerId,currency,'customer_liability'],limit:1);
    if (cash.isEmpty || liability.isEmpty) throw StateError('حسابات الترحيل المطلوبة غير موجودة');
    if (cash.first['active'] != 1 || liability.first['active'] != 1) throw StateError('أحد حسابات الترحيل معطل');
  }

  /// Returns the earliest and latest posting dates for each currency.
  static Future<List<Map<String,Object?>>> postingDateCoverage(DatabaseExecutor db) async {
    return db.rawQuery('''
      SELECT currency,MIN(business_date) AS first_date,MAX(business_date) AS last_date,
        COUNT(*) AS entries FROM journal_entries GROUP BY currency ORDER BY currency
    ''');
  }

  /// Checks that an adjustment draft obeys the journal's single-currency rule.
  static JournalValidationResult validateAdjustment(List<JournalLineDraft> lines, String currency) {
    _currency(currency);
    if (lines.any((line) => line.currency != currency)) throw const FormatException('لا يسمح بخلط العملات في القيد الواحد');
    return FinancialControls.validateJournal(lines);
  }

  /// Returns a stable schema/version marker for backup compatibility checks.
  static Map<String,Object?> backupCompatibility() => {
    'format':'almasar_hawalat_journal',
    'version':1,
    'database_schema_version':3,
    'required_tables':['journal_accounts','journal_entries','journal_lines'],
    'optional_control_tables':['ledger_audit_events','ledger_period_closures'],
    'integer_minor_units':true,
    'multi_currency_policy':'separate_currency_balances',
  };

  /// Validates a proposed entry reference and description before persistence.
  static void validateEntryMetadata({
    required String reference,
    required String description,
    required String source,
    required String idempotency,
  }) {
    if (reference.trim().isEmpty || reference.length > 160) throw ArgumentError('مرجع القيد غير صالح');
    if (description.length > 4000) throw ArgumentError('وصف القيد أطول من المسموح');
    if (!{'transfer','migration','reversal','adjustment'}.contains(source)) throw ArgumentError('مصدر القيد غير صالح');
    if (idempotency.trim().isEmpty || idempotency.length > 200) throw ArgumentError('مفتاح منع التكرار غير صالح');
  }

  /// Returns totals for a given account type, kept separate for each currency.
  static Future<List<Map<String,Object?>>> totalsByAccountType(DatabaseExecutor db, {
    String? throughDate,
  }) async {
    if (throughDate != null && DateTime.tryParse(throughDate) == null) throw const FormatException('التاريخ غير صالح');
    final where = throughDate == null ? '' : 'WHERE e.business_date <= ?';
    return db.rawQuery('''
      SELECT a.currency,a.account_type,SUM(l.debit_minor) AS debits_minor,
        SUM(l.credit_minor) AS credits_minor,COUNT(l.id) AS line_count
      FROM journal_accounts a JOIN journal_lines l ON l.account_id=a.id
      JOIN journal_entries e ON e.id=l.entry_id
      $where GROUP BY a.currency,a.account_type ORDER BY a.currency,a.account_type
    ''',throughDate == null ? [] : [throughDate]);
  }

  /// Reports journal entries with no corresponding source transfer when their
  /// source claims to be a transfer or migration.
  static Future<List<Map<String,Object?>>> unexpectedTransferLinks(DatabaseExecutor db) async {
    return db.rawQuery('''
      SELECT e.id,e.reference,e.source,e.transfer_id FROM journal_entries e
      LEFT JOIN transfers t ON t.id=e.transfer_id
      WHERE (e.source IN ('transfer','migration') AND e.transfer_id IS NULL)
         OR (e.transfer_id IS NOT NULL AND t.id IS NULL)
      ORDER BY e.id
    ''');
  }

  /// Validates that all period closures are balanced and their ranges are sane.
  static Future<List<Map<String,Object?>>> validateClosures(DatabaseExecutor db) async {
    return db.rawQuery('''
      SELECT id,currency,period_start,period_end,debit_total_minor,credit_total_minor
      FROM ledger_period_closures
      WHERE period_start > period_end OR debit_total_minor != credit_total_minor
      ORDER BY id
    ''');
  }

  /// Returns a read-only overview of reversal chains for review.
  static Future<List<Map<String,Object?>>> possibleReversalAnomalies(DatabaseExecutor db) async {
    return db.rawQuery('''
      SELECT e.id,e.reference,e.status,e.reversal_of_entry_id
      FROM journal_entries e
      WHERE (e.reversal_of_entry_id IS NOT NULL AND e.source != 'reversal')
         OR (e.source='reversal' AND e.reversal_of_entry_id IS NULL)
      ORDER BY e.id
    ''');
  }

  /// Prepares a deterministic export record for a single account and its lines.
  static Future<Map<String,Object?>> accountExportRecord(DatabaseExecutor db, int accountId) async {
    final account = await db.query('journal_accounts',where:'id=?',whereArgs:[accountId],limit:1);
    if (account.isEmpty) throw StateError('الحساب غير موجود');
    final lines = await db.rawQuery('''
      SELECT l.entry_id,l.line_number,l.debit_minor,l.credit_minor,l.memo,
        e.reference,e.business_date,e.currency,e.source
      FROM journal_lines l JOIN journal_entries e ON e.id=l.entry_id
      WHERE l.account_id=? ORDER BY e.business_date,e.id,l.line_number
    ''',[accountId]);
    return {'account':account.first,'lines':lines,'exported_at':DateTime.now().toUtc().toIso8601String()};
  }

  /// Produces counts and key totals to compare before and after a backup restore.
  static Future<Map<String,Object?>> restoreComparison(DatabaseExecutor db) async {
    final manifest = await exportManifest(db);
    final integrity = await integrityCheck(db);
    final balances = await reconcileCustomerBalances(db);
    return {'manifest':manifest,'integrity':integrity,'customer_balance_errors':balances,
      'ok':integrity['ok'] == true && balances.isEmpty};
  }

  /// Validates a journal line's shape without accessing the database.
  static void validateLineDraft({
    required int debitMinor,
    required int creditMinor,
    required String currency,
    required String accountCode,
  }) {
    _currency(currency);
    if (accountCode.trim().isEmpty) throw ArgumentError('رمز الحساب مطلوب');
    if (debitMinor < 0 || creditMinor < 0 || (debitMinor == 0) == (creditMinor == 0)) {
      throw const FormatException('يجب أن يكون السطر مدينًا أو دائنًا فقط وبمبلغ موجب');
    }
    if (debitMinor > maximumMinor || creditMinor > maximumMinor) throw const FormatException('مبلغ السطر يتجاوز الحد العددي');
  }

  /// Reads one date's aggregate without loading its individual entries.
  static Future<Map<String,Object?>> dailySummary(DatabaseExecutor db, {
    required String businessDate,
    required String currency,
  }) async {
    _currency(currency);
    if (DateTime.tryParse(businessDate) == null) throw const FormatException('التاريخ غير صالح');
    final rows = await db.rawQuery('''
      SELECT COUNT(DISTINCT e.id) AS entry_count,COUNT(l.id) AS line_count,
        COALESCE(SUM(l.debit_minor),0) AS debits_minor,
        COALESCE(SUM(l.credit_minor),0) AS credits_minor
      FROM journal_entries e LEFT JOIN journal_lines l ON l.entry_id=e.id
      WHERE e.business_date=? AND e.currency=?
    ''',[businessDate,currency]);
    return {'business_date':businessDate,'currency':currency,...rows.first};
  }

  /// Returns journal rows for a reference, including all its posting lines.
  static Future<Map<String,Object?>?> entryByReference(DatabaseExecutor db, String reference) async {
    final rows = await db.query('journal_entries',where:'reference=?',whereArgs:[reference.trim()],limit:1);
    if (rows.isEmpty) return null;
    return getEntry(db,rows.first['id'] as int);
  }

  /// Provides a consistency report suitable for a scheduled maintenance run.
  static Future<Map<String,Object?>> scheduledAudit(DatabaseExecutor db) async {
    final findingsList = await findings(db);
    final totals = await controlTotals(db);
    final coverage = await postingDateCoverage(db);
    final accountErrors = await validateAccountCatalog(db);
    final closureErrors = await validateClosures(db);
    final reversalErrors = await possibleReversalAnomalies(db);
    return {'ok':findingsList.isEmpty && accountErrors.isEmpty && closureErrors.isEmpty && reversalErrors.isEmpty,
      'findings':findingsList,'control_totals':totals,'posting_coverage':coverage,
      'account_errors':accountErrors,'closure_errors':closureErrors,'reversal_errors':reversalErrors,
      'checked_at':DateTime.now().toUtc().toIso8601String()};
  }

  /// Exposes a stable health status without disclosing ledger line contents.
  static Future<Map<String,Object?>> healthStatus(DatabaseExecutor db) async {
    final integrity = await integrityCheck(db);
    final count = await countEntries(db);
    final lastId = await lastEntryId(db);
    final missingCash = await missingCashAccounts(db);
    return {'ok':integrity['ok'] == true && missingCash.isEmpty,
      'entry_count':count,'last_entry_id':lastId,'missing_cash_accounts':missingCash,
      'integrity':integrity,'checked_at':DateTime.now().toUtc().toIso8601String()};
  }
}
