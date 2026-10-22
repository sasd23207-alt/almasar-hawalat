/// Banking-style accounting controls for local financial records.
///
/// Monetary values are always integer minor units. Every posted journal must
/// contain at least two lines, use one currency, and have equal debit/credit
/// totals. This module is a domain guard; it does not by itself make this app a
/// licensed bank or replace operational, regulatory, or independent security review.
class JournalLineDraft {
  const JournalLineDraft({
    required this.accountCode,
    required this.currency,
    required this.debitMinor,
    required this.creditMinor,
  });

  final String accountCode;
  final String currency;
  final int debitMinor;
  final int creditMinor;
}

class JournalValidationResult {
  const JournalValidationResult({
    required this.currency,
    required this.totalDebitsMinor,
    required this.totalCreditsMinor,
    required this.lineCount,
  });

  final String currency;
  final int totalDebitsMinor;
  final int totalCreditsMinor;
  final int lineCount;

  bool get isBalanced => totalDebitsMinor == totalCreditsMinor;
}

class FinancialControls {
  FinancialControls._();

  static const supportedCurrencies = <String>{'LYD', 'USD', 'EUR'};
  static const maximumMinorAmount = 0x7fffffffffffffff;

  /// Validates a complete posting before a caller writes any ledger rows.
  /// Mixed-currency entries are rejected; exchange must be represented as
  /// separate balanced entries with explicit FX-clearing accounts.
  static JournalValidationResult validateJournal(
    List<JournalLineDraft> lines,
  ) {
    if (lines.length < 2) {
      throw const FormatException('القيد المحاسبي يحتاج إلى سطرين على الأقل');
    }

    final currency = lines.first.currency;
    if (!supportedCurrencies.contains(currency)) {
      throw const FormatException('عملة القيد غير مدعومة');
    }

    var debits = 0;
    var credits = 0;
    final accountCodes = <String>{};
    for (final line in lines) {
      final code = line.accountCode.trim();
      if (code.isEmpty) {
        throw const FormatException('رمز الحساب المحاسبي مطلوب');
      }
      if (!supportedCurrencies.contains(line.currency) ||
          line.currency != currency) {
        throw const FormatException(
          'لا يمكن جمع عملات مختلفة في قيد واحد؛ استخدم قيد صرف منفصلًا',
        );
      }
      if (line.debitMinor < 0 || line.creditMinor < 0 ||
          (line.debitMinor == 0 && line.creditMinor == 0) ||
          (line.debitMinor > 0 && line.creditMinor > 0)) {
        throw const FormatException(
          'كل سطر يجب أن يحتوي على مدين أو دائن موجب واحد فقط',
        );
      }
      if (debits > maximumMinorAmount - line.debitMinor ||
          credits > maximumMinorAmount - line.creditMinor) {
        throw const FormatException('إجمالي القيد يتجاوز سعة التخزين');
      }
      debits += line.debitMinor;
      credits += line.creditMinor;
      accountCodes.add(code);
    }
    if (debits != credits) {
      throw FormatException(
        'القيد غير متوازن: المدين $debits لا يساوي الدائن $credits',
      );
    }
    if (accountCodes.length < 2) {
      throw const FormatException('القيد يحتاج إلى حسابين مختلفين على الأقل');
    }
    return JournalValidationResult(
      currency: currency,
      totalDebitsMinor: debits,
      totalCreditsMinor: credits,
      lineCount: lines.length,
    );
  }

  /// Computes a reconciliation difference without converting currencies.
  /// A zero difference is necessary but not sufficient proof of correctness.
  static int reconciliationDifference({
    required int recordedBalanceMinor,
    required int ledgerBalanceMinor,
  }) {
    if (recordedBalanceMinor < 0 || ledgerBalanceMinor < 0) {
      throw const FormatException('الأرصدة السالبة تحتاج إلى معالجة استثنائية');
    }
    return recordedBalanceMinor - ledgerBalanceMinor;
  }

  /// A reversal must mirror every original line and keep the original currency.
  /// The caller must enforce one reversal per original transaction in storage.
  static List<JournalLineDraft> buildReversal(
    List<JournalLineDraft> original,
  ) {
    validateJournal(original);
    final reversal = original
        .map((line) => JournalLineDraft(
              accountCode: line.accountCode,
              currency: line.currency,
              debitMinor: line.creditMinor,
              creditMinor: line.debitMinor,
            ))
        .toList(growable: false);
    validateJournal(reversal);
    return reversal;
  }

  /// Compares a retried request's canonical business fields with the stored
  /// request fingerprint. Reusing a key for different content must be rejected.
  static void requireSameIdempotentRequest({
    required String storedFingerprint,
    required String incomingFingerprint,
  }) {
    if (storedFingerprint.isEmpty || incomingFingerprint.isEmpty) {
      throw const FormatException('بصمة الطلب مطلوبة لمنع تكرار العملية');
    }
    if (storedFingerprint != incomingFingerprint) {
      throw const FormatException(
        'مفتاح العملية مستخدم مسبقًا لطلب مختلف؛ أوقف الحفظ وراجع السجل',
      );
    }
  }

  /// Produces a stable representation for audit/hash inputs. The caller should
  /// hash this canonical text with a cryptographic hash and store the previous
  /// event hash as well as the new hash to form a tamper-evident chain.
  static String canonicalAuditRecord({
    required String eventId,
    required String eventType,
    required String actorId,
    required String entityType,
    required String entityId,
    required String occurredAtUtc,
    required String payloadDigest,
    String previousEventHash = '',
  }) {
    final fields = <String>[
      eventId,
      eventType,
      actorId,
      entityType,
      entityId,
      occurredAtUtc,
      payloadDigest,
      previousEventHash,
    ];
    if (fields.take(7).any((field) => field.trim().isEmpty) ||
        !occurredAtUtc.endsWith('Z')) {
      throw const FormatException(
        'بيانات سجل التدقيق ناقصة أو أن الوقت ليس بصيغة UTC',
      );
    }
    return fields.map(_escapeField).join('|');
  }

  /// Enforces configurable per-operation limits without floating-point arithmetic.
  static void validateTransferLimit({
    required int amountMinor,
    required int minimumMinor,
    required int maximumMinor,
  }) {
    if (minimumMinor < 1 || maximumMinor < minimumMinor ||
        amountMinor < minimumMinor || amountMinor > maximumMinor) {
      throw const FormatException('المبلغ خارج حدود العملية المسموح بها');
    }
  }

  /// Requires a second, distinct operator for sensitive actions.
  static void requireDualControl({
    required String makerId,
    required String? checkerId,
    required bool requiredForAction,
  }) {
    if (requiredForAction &&
        (checkerId == null || checkerId.trim().isEmpty ||
         makerId.trim().isEmpty || makerId.trim() == checkerId.trim())) {
      throw const FormatException('هذه العملية تتطلب اعتماد شخص آخر غير مُدخلها');
    }
  }

  /// Blocks posting into a business day that has already been closed.
  static void requireBusinessDayOpen({
    required DateTime valueDate,
    required DateTime? closedThroughDate,
  }) {
    if (closedThroughDate == null) return;
    final valueDay = DateTime.utc(valueDate.year, valueDate.month, valueDate.day);
    final closedDay = DateTime.utc(
      closedThroughDate.year, closedThroughDate.month, closedThroughDate.day,
    );
    if (!valueDay.isAfter(closedDay)) {
      throw const FormatException('تاريخ القيد ضمن فترة مقفلة؛ استخدم قيد تصحيح معتمد');
    }
  }

  /// Fee in minor units, rounded half-up using integer math.
  static int calculateFeeMinor({
    required int amountMinor,
    required int basisPoints,
    int minimumFeeMinor = 0,
    int maximumFeeMinor = maximumMinorAmount,
  }) {
    if (amountMinor <= 0 || basisPoints < 0 ||
        minimumFeeMinor < 0 || maximumFeeMinor < minimumFeeMinor) {
      throw const FormatException('إعدادات العمولة غير صالحة');
    }
    final numerator = BigInt.from(amountMinor) * BigInt.from(basisPoints);
    final rounded = ((numerator + BigInt.from(5000)) ~/ BigInt.from(10000));
    if (rounded > BigInt.from(maximumMinorAmount)) {
      throw const FormatException('قيمة العمولة تتجاوز سعة التخزين');
    }
    final fee = rounded.toInt();
    if (fee < minimumFeeMinor) return minimumFeeMinor;
    if (fee > maximumFeeMinor) return maximumFeeMinor;
    return fee;
  }

  /// Converts using a positive rate expressed in millionths; no binary floats.
  static int convertMinorUnits({
    required int sourceAmountMinor,
    required int rateMicros,
  }) {
    if (sourceAmountMinor <= 0 || rateMicros <= 0) {
      throw const FormatException('بيانات سعر الصرف غير صالحة');
    }
    final numerator = BigInt.from(sourceAmountMinor) * BigInt.from(rateMicros);
    final divisor = BigInt.from(1000000);
    final rounded = (numerator + divisor ~/ BigInt.from(2)) ~/ divisor;
    if (rounded > BigInt.from(maximumMinorAmount)) {
      throw const FormatException('ناتج الصرف يتجاوز سعة التخزين');
    }
    return rounded.toInt();
  }

  /// Ensures a reversal points to a real original and is not itself a reversal.
  static void validateReversalTarget({
    required String originalReference,
    required bool originalAlreadyReversed,
    required bool targetIsReversal,
    required String reason,
  }) {
    if (originalReference.trim().isEmpty || reason.trim().isEmpty ||
        originalAlreadyReversed || targetIsReversal) {
      throw const FormatException('قيد العكس غير صالح أو تم عكس العملية سابقًا');
    }
  }

  /// Rejects illegal payment lifecycle transitions; no silent state jumps.
  static void validatePaymentTransition({
    required String from,
    required String to,
  }) {
    const allowed = <String, Set<String>>{
      'draft': {'pending_approval', 'cancelled'},
      'pending_approval': {'approved', 'rejected', 'cancelled'},
      'approved': {'submitted', 'cancelled'},
      'submitted': {'settled', 'failed', 'unknown_outcome'},
      'unknown_outcome': {'settled', 'failed', 'submitted'},
      'failed': {'reversed'},
      'settled': {'reversed'},
      'rejected': {},
      'cancelled': {},
      'reversed': {},
    };
    if (!(allowed[from]?.contains(to) ?? false)) {
      throw FormatException('انتقال حالة العملية غير مسموح: $from -> $to');
    }
  }

  /// A retry after a network timeout must be reconciled, not blindly resubmitted.
  static String resolveUnknownOutcome({
    required bool providerConfirmsSettled,
    required bool providerConfirmsFailed,
    required bool providerHasNoRecord,
  }) {
    final confirmations = [
      providerConfirmsSettled, providerConfirmsFailed, providerHasNoRecord,
    ].where((value) => value).length;
    if (confirmations != 1) {
      throw const FormatException('نتيجة مزود الدفع غير حاسمة؛ يلزم تحقق يدوي');
    }
    if (providerConfirmsSettled) return 'settled';
    if (providerConfirmsFailed) return 'failed';
    return 'safe_to_retry_after_reconciliation';
  }

  /// Calculates a control total for one currency and rejects invalid rows.
  static int calculateControlTotal(Iterable<int> amountsMinor) {
    var total = 0;
    for (final amount in amountsMinor) {
      if (amount <= 0 || total > maximumMinorAmount - amount) {
        throw const FormatException('عنصر غير صالح أو تجاوز في إجمالي المطابقة');
      }
      total += amount;
    }
    return total;
  }

  /// Produces discrepancy details suitable for an exception queue.
  static Map<String, Object> buildReconciliationException({
    required String source,
    required String currency,
    required int expectedMinor,
    required int actualMinor,
    required String businessDate,
  }) {
    if (source.trim().isEmpty || businessDate.trim().isEmpty ||
        !supportedCurrencies.contains(currency) ||
        expectedMinor < 0 || actualMinor < 0) {
      throw const FormatException('بيانات استثناء المطابقة غير صالحة');
    }
    return <String, Object>{
      'source': source,
      'currency': currency,
      'business_date': businessDate,
      'expected_minor': expectedMinor,
      'actual_minor': actualMinor,
      'difference_minor': actualMinor - expectedMinor,
      'status': actualMinor == expectedMinor ? 'matched' : 'requires_review',
    };
  }

  /// Prevents two approval steps from being attributed to the same person.
  static void validateApprovalChain(List<String> approverIds) {
    if (approverIds.isEmpty ||
        approverIds.any((id) => id.trim().isEmpty) ||
        approverIds.toSet().length != approverIds.length) {
      throw const FormatException('سلسلة الاعتماد فارغة أو تحتوي على اعتماد مكرر');
    }
  }

  /// Validates an external statement line before reconciliation.
  static void validateStatementLine({
    required String externalReference,
    required String currency,
    required int amountMinor,
    required DateTime bookedAt,
  }) {
    if (externalReference.trim().isEmpty ||
        !supportedCurrencies.contains(currency) ||
        amountMinor <= 0 ||
        bookedAt.isUtc == false) {
      throw const FormatException('سطر كشف المصدر الخارجي غير صالح');
    }
  }

  /// Prevents reports from adding balances in unlike currencies.
  static Map<String, int> totalsByCurrency(
    Iterable<({String currency, int amountMinor})> values,
  ) {
    final totals = <String, int>{};
    for (final value in values) {
      if (!supportedCurrencies.contains(value.currency) ||
          value.amountMinor < 0) {
        throw const FormatException('عملة أو مبلغ غير صالح في التقرير');
      }
      final current = totals[value.currency] ?? 0;
      if (current > maximumMinorAmount - value.amountMinor) {
        throw const FormatException('إجمالي العملة يتجاوز سعة التخزين');
      }
      totals[value.currency] = current + value.amountMinor;
    }
    return totals;
  }

  /// Risk triage is a flag for human review, not an automatic fraud verdict.
  static Set<String> assessReviewFlags({
    required int amountMinor,
    required int configuredReviewThresholdMinor,
    required bool recipientIsNew,
    required bool duplicateReference,
    required bool unusualHour,
    required bool currencyMismatch,
  }) {
    final flags = <String>{};
    if (amountMinor <= 0) flags.add('invalid_amount');
    if (configuredReviewThresholdMinor > 0 &&
        amountMinor >= configuredReviewThresholdMinor) {
      flags.add('large_amount');
    }
    if (recipientIsNew) flags.add('new_recipient');
    if (duplicateReference) flags.add('duplicate_reference');
    if (unusualHour) flags.add('unusual_time');
    if (currencyMismatch) flags.add('currency_mismatch');
    return flags;
  }

  /// Validates a dated posting and its recorded UTC timestamp separately.
  static void validatePostingDates({
    required DateTime valueDate,
    required DateTime createdAt,
  }) {
    if (!createdAt.isUtc ||
        valueDate.year < 2000 || valueDate.year > 2200) {
      throw const FormatException('تاريخ القيمة أو وقت التسجيل غير صالح');
    }
  }

  /// Validates a bounded import batch before it is queued for review.
  static void validateImportBatch({
    required String batchId,
    required int rowCount,
    required int maximumRows,
  }) {
    if (batchId.trim().isEmpty || rowCount < 1 ||
        maximumRows < 1 || rowCount > maximumRows) {
      throw const FormatException('دفعة الاستيراد فارغة أو تتجاوز الحد المسموح');
    }
  }

  /// Detects a possible duplicate without merging records automatically.
  static bool looksLikeDuplicate({
    required String existingReference,
    required String incomingReference,
    required int existingAmountMinor,
    required int incomingAmountMinor,
    required String existingCurrency,
    required String incomingCurrency,
  }) {
    return existingReference.trim().isNotEmpty &&
        existingReference.trim() == incomingReference.trim() &&
        existingAmountMinor == incomingAmountMinor &&
        existingCurrency == incomingCurrency;
  }

  /// Limits free-form financial references to a safe, predictable shape.
  static String normalizeReference(String raw) {
    final value = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (value.isEmpty || value.length > 120 ||
        value.contains(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'))) {
      throw const FormatException('مرجع العملية فارغ أو غير صالح');
    }
    return value;
  }

  /// Checks that a snapshot was taken after the last successful posting.
  static void validateSnapshotWatermark({
    required int snapshotSequence,
    required int latestLedgerSequence,
  }) {
    if (snapshotSequence < 0 || latestLedgerSequence < 0 ||
        snapshotSequence > latestLedgerSequence) {
      throw const FormatException('مؤشر ملخص الأرصدة غير صالح');
    }
  }

  static String _escapeField(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('|', r'\|').replaceAll('\n', r'\n');
}
