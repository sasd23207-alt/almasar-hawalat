import 'package:flutter_test/flutter_test.dart';
import 'package:almasar_hawalat/core/ledger_integrity.dart';

void main() {
  Map<String, Object?> customer({int id = 1, int balance = 700, String currency = 'LYD'}) => {
    'id': id,
    'name': 'عميل',
    'currency': currency,
    'balance_minor': balance,
  };

  Map<String, Object?> transfer({
    int id = 1,
    int customerId = 1,
    String reference = 'REF-1',
    String kind = 'deposit',
    int amount = 1000,
    String currency = 'LYD',
  }) => {
    'id': id,
    'customer_id': customerId,
    'reference': reference,
    'kind': kind,
    'amount_minor': amount,
    'currency': currency,
  };

  test('accepts a balance reconciled with deposits and withdrawals', () {
    expect(
      () => validateCustomerLedger(
        customerRows: [customer(balance: 700)],
        transferRows: [
          transfer(amount: 1000),
          transfer(id: 2, reference: 'REF-2', kind: 'withdrawal', amount: 300),
        ],
      ),
      returnsNormally,
    );
  });

  test('rejects a balance that does not equal the ledger', () {
    expect(
      () => validateCustomerLedger(
        customerRows: [customer(balance: 701)],
        transferRows: [transfer(amount: 700)],
      ),
      throwsFormatException,
    );
  });

  test('rejects currency mismatch instead of silently reconciling it', () {
    expect(
      () => validateCustomerLedger(
        customerRows: [customer(balance: 1000)],
        transferRows: [transfer(amount: 1000, currency: 'USD')],
      ),
      throwsFormatException,
    );
  });

  test('rejects duplicate transaction references', () {
    expect(
      () => validateCustomerLedger(
        customerRows: [customer(balance: 2000)],
        transferRows: [
          transfer(amount: 1000),
          transfer(id: 2, amount: 1000),
        ],
      ),
      throwsFormatException,
    );
  });

  test('rejects transfers linked to missing customers', () {
    expect(
      () => validateCustomerLedger(
        customerRows: [customer()],
        transferRows: [transfer(customerId: 2)],
      ),
      throwsFormatException,
    );
  });
}
