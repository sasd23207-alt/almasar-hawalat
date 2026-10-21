import 'dart:convert';
import 'dart:io';

import 'package:almasar_hawalat/core/money.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cases = jsonDecode(File('test/golden/money_cases.json').readAsStringSync())
      as Map<String, dynamic>;

  group('toMinorUnits (valid)', () {
    for (final item in cases['to_minor_valid'] as List<dynamic>) {
      final amount = item['amount'] as String;
      final currency = item['currency'] as String;
      test('$amount $currency', () {
        expect(toMinorUnits(amount, currency), item['minor'] as int);
      });
    }
  });

  group('toMinorUnits (invalid)', () {
    for (final item in cases['to_minor_invalid'] as List<dynamic>) {
      final amount = item['amount'] as String;
      final currency = item['currency'] as String;
      test('$amount $currency is rejected', () {
        expect(() => toMinorUnits(amount, currency), throwsA(anything));
      });
    }
  });

  group('fromMinorUnits', () {
    for (final item in cases['from_minor'] as List<dynamic>) {
      final minor = item['minor'] as int;
      final currency = item['currency'] as String;
      test('$minor $currency', () {
        expect(fromMinorUnits(minor, currency), item['text'] as String);
      });
    }
  });
}
