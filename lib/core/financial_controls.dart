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
    if (fields.any((field) => field.trim().isEmpty) ||
        !occurredAtUtc.endsWith('Z')) {
      throw const FormatException(
        'بيانات سجل التدقيق ناقصة أو أن الوقت ليس بصيغة UTC',
      );
    }
    return fields.map(_escapeField).join('|');
  }

  static String _escapeField(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('|', r'\|').replaceAll('\n', r'\n');
}
