/// Reconciles customer balances against the immutable transfer history.
///
/// A customer is created with a zero opening balance, so its current balance
/// must equal deposits minus withdrawals in the stored ledger. This validator
/// is used before restoring backups so inconsistent financial data is rejected
/// before any existing local records are replaced.
void validateCustomerLedger({
  required List<Map<String, Object?>> customerRows,
  required List<Map<String, Object?>> transferRows,
}) {
  final customers = <int, Map<String, Object?>>{};
  final calculated = <int, BigInt>{};
  for (final customer in customerRows) {
    final id = customer['id'];
    if (id is! int || customers.containsKey(id)) {
      throw const FormatException('معرّفات العملاء مكررة أو غير صالحة');
    }
    if (customer['currency'] is! String ||
        customer['balance_minor'] is! int) {
      throw const FormatException('رصيد أو عملة العميل غير صالحة');
    }
    customers[id] = customer;
    calculated[id] = BigInt.zero;
  }

  final references = <String>{};
  for (final transfer in transferRows) {
    final id = transfer['customer_id'];
    final customer = id is int ? customers[id] : null;
    final reference = transfer['reference'];
    final amount = transfer['amount_minor'];
    final kind = transfer['kind'];
    if (customer == null) {
      throw const FormatException('توجد عملية مرتبطة بعميل غير موجود');
    }
    if (reference is! String || reference.isEmpty ||
        !references.add(reference)) {
      throw const FormatException('مراجع العمليات مكررة أو غير صالحة');
    }
    if (amount is! int || amount <= 0 ||
        (kind != 'deposit' && kind != 'withdrawal')) {
      throw const FormatException('نوع أو مبلغ عملية غير صالح');
    }
    if (transfer['currency'] != customer['currency']) {
      throw const FormatException('عملة العملية لا تطابق عملة حساب العميل');
    }
    final signedAmount = BigInt.from(amount);
    calculated[id as int] = calculated[id as int]! +
        (kind == 'deposit' ? signedAmount : -signedAmount);
  }

  for (final entry in customers.entries) {
    final recorded = BigInt.from(entry.value['balance_minor'] as int);
    if (recorded != calculated[entry.key]) {
      throw FormatException(
        'الرصيد لا يطابق سجل العمليات للعميل رقم ${entry.key}',
      );
    }
  }
}
