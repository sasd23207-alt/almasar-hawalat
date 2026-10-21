import 'package:almasar_hawalat/core/money.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('toMinorUnits edge cases', () {
    test('trims surrounding whitespace', () {
      expect(toMinorUnits('  12.34  ', 'USD'), 1234);
    });

    test('accepts extra fractional digits only when they are zero', () {
      expect(toMinorUnits('12.3400', 'USD'), 1234);
      expect(toMinorUnits('12.0000', 'LYD'), 12000);
    });

    test('rejects a non-zero digit beyond currency precision', () {
      expect(() => toMinorUnits('12.341', 'USD'), throwsFormatException);
      expect(() => toMinorUnits('12.0001', 'LYD'), throwsFormatException);
    });

    test('rejects empty, sign-only, and decimal-only input', () {
      for (final amount in ['', ' ', '-', '.', '1.', '.5', '+2']) {
        expect(
          () => toMinorUnits(amount, 'USD'),
          throwsFormatException,
          reason: 'Input "$amount" should be rejected',
        );
      }
    });

    test('rejects zero values even with leading zeros', () {
      expect(() => toMinorUnits('0', 'USD'), throwsFormatException);
      expect(() => toMinorUnits('000.000', 'LYD'), throwsFormatException);
    });

    test('rejects unsupported currencies explicitly', () {
      expect(() => toMinorUnits('10', 'GBP'), throwsArgumentError);
      expect(() => fromMinorUnits(1000, 'GBP'), throwsArgumentError);
    });
  });

  group('fromMinorUnits edge cases', () {
    test('pads small amounts to the correct number of decimal places', () {
      expect(fromMinorUnits(1, 'USD'), '0.01');
      expect(fromMinorUnits(1, 'EUR'), '0.01');
      expect(fromMinorUnits(1, 'LYD'), '0.001');
    });

    test('formats zero consistently', () {
      expect(fromMinorUnits(0, 'USD'), '0.00');
      expect(fromMinorUnits(0, 'LYD'), '0.000');
    });

    test('preserves sign and decimal precision for negative amounts', () {
      expect(fromMinorUnits(-1, 'USD'), '-0.01');
      expect(fromMinorUnits(-1, 'LYD'), '-0.001');
    });
  });

  group('conversion round-trip', () {
    for (final currency in ['USD', 'EUR', 'LYD']) {
      for (final minor in [1, 9, 10, 99, 100, 1234567]) {
        test('$currency $minor minor units round-trip', () {
          final formatted = fromMinorUnits(minor, currency);
          expect(toMinorUnits(formatted, currency), minor);
        });
      }
    }
  });
}
