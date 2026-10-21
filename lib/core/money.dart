/// Money helpers. Amounts are stored as whole numbers of the smallest unit
/// (never as floating point), exactly like the Python reference implementation.
/// Behaviour is checked against test/golden/money_cases.json.

/// Assumption: decimal places per currency. LYD is subdivided into 1000 dirhams.
const Map<String, int> currencyDecimals = {
  'USD': 2,
  'EUR': 2,
  'LYD': 3,
};

final RegExp _amountPattern = RegExp(r'^(\d+)(?:\.(\d+))?$');

/// '5000.5' + 'LYD' -> 5000500. Throws if the text is not a plain positive
/// number, if the currency is unknown, or if it has more decimals than allowed.
int toMinorUnits(String amountText, String currency) {
  final decimals = currencyDecimals[currency];
  if (decimals == null) {
    throw ArgumentError('Unsupported currency: $currency');
  }

  final match = _amountPattern.firstMatch(amountText.trim());
  if (match == null) {
    throw FormatException('Not a valid amount: $amountText');
  }

  final wholePart = match.group(1)!;
  final fractionPart = match.group(2) ?? '';

  // Extra decimals are accepted only if they are zeros ("10.500" for USD).
  if (fractionPart.length > decimals) {
    final extraDigits = fractionPart.substring(decimals);
    if (extraDigits.replaceAll('0', '').isNotEmpty) {
      throw FormatException('$currency allows at most $decimals decimal places');
    }
  }

  final fractionDigits = fractionPart.length >= decimals
      ? fractionPart.substring(0, decimals)
      : fractionPart.padRight(decimals, '0');

  final amountMinor = int.parse('$wholePart$fractionDigits');
  if (amountMinor <= 0) {
    throw const FormatException('Amount must be greater than zero');
  }
  return amountMinor;
}

/// 5000500 + 'LYD' -> '5000.500'
String fromMinorUnits(int amountMinor, String currency) {
  final decimals = currencyDecimals[currency];
  if (decimals == null) {
    throw ArgumentError('Unsupported currency: $currency');
  }

  final sign = amountMinor < 0 ? '-' : '';
  final digits = amountMinor.abs().toString().padLeft(decimals + 1, '0');
  final wholePart = digits.substring(0, digits.length - decimals);
  final fractionPart = digits.substring(digits.length - decimals);
  return '$sign$wholePart.$fractionPart';
}
