/// Conservative parser for WhatsApp exported chat text.
/// It only suggests candidate transactions; the user must review every row
/// before posting anything to the ledger.
class WhatsAppCandidate {
  const WhatsAppCandidate({
    required this.dateText,
    required this.sender,
    required this.message,
    required this.amountText,
    required this.currency,
    required this.direction,
    required this.confidence,
  });

  final String? dateText;
  final String? sender;
  final String message;
  final String amountText;
  final String? currency;
  /// 'paid_to_trader', 'received_from_trader', or 'review'
  final String direction;
  /// 'high' only when both a money phrase and an explicit currency are found.
  final String confidence;
}

class WhatsAppChatParser {
  static final _messageStart = RegExp(
    r'^(\[?\d{1,4}[/-]\d{1,2}[/-]\d{2,4},?\s+\d{1,2}:\d{2}(?::\d{2})?(?:\s?[APap][Mm])?\]?)\s*(?:[-–]\s*|\s+)([^:]+):\s*(.*)
  );
  static final _isoMessageStart = RegExp(
    r'^(\[?\d{4}-\d{1,2}-\d{1,2},?\s+\d{1,2}:\d{2}(?::\d{2})?(?:\s?[APap][Mm])?\]?)\s*(?:[-–]\s*|\s+)([^:]+):\s*(.*)
  );

  static final _amount = RegExp(
    r'(?:(LYD|د\.ل|دينار(?:\s+ليبي)?|USD|\$|دولار|EUR|€|يورو)\s*)?'
    r'(?<![\w/])([0-9٠-٩۰-۹][0-9٠-٩۰-۹,٬]*(?:[.٫][0-9٠-٩۰-۹]{1,3})?)'
    r'\s*(LYD|د\.ل|دينار(?:\s+ليبي)?|USD|\$|دولار|EUR|€|يورو)?',
    caseSensitive: false,
  );

  static final _paid = RegExp(
    r'(حولت\s*لك|حوّلت\s*لك|ارسلت\s*لك|أرسلت\s*لك|بعثت\s*لك|بعت\s*لك|دفعت\s*لك|حولنالك|حوالة\s*لك|تم\s*التحويل\s*لك|sent\s+you|paid\s+you|transferred\s+to\s+you)',
    caseSensitive: false,
  );
  static final _received = RegExp(
    r'(حولت\s*لي|حوّلت\s*لي|ارسلت\s*لي|أرسلت\s*لي|بعثت\s*لي|وصلني\s*منك|استلمت\s*منك|حولت\s*منك|حوالة\s*منك|sent\s+me|paid\s+me|transferred\s+to\s+me|received\s+from\s+you)',
    caseSensitive: false,
  );
  static final _moneyContext = RegExp(
    r'(حوالة|تحويل|حولت|حوّلت|ارسلت|أرسلت|بعثت|دفعت|استلمت|وصلني|عليك|لي\s+عندك|لك\s+عندي|دينار|دولار|يورو|LYD|USD|EUR|\$|€)',
    caseSensitive: false,
  );

  static List<WhatsAppCandidate> parse(String text) {
    final messages = <Map<String, String?>>[];
    for (final rawLine in text.replaceAll('\r\n', '\n').split('\n')) {
      final line = rawLine.trimRight();
      final match = _messageStart.firstMatch(line) ?? _isoMessageStart.firstMatch(line);
      if (match != null) {
        messages.add({'date': match.group(1), 'sender': match.group(2)?.trim(), 'body': match.group(3) ?? ''});
      } else if (messages.isNotEmpty && line.isNotEmpty) {
        final previous = messages.last;
        previous['body'] = '${previous['body']}\n$line';
      }
    }

    final results = <WhatsAppCandidate>[];
    for (final item in messages) {
      final body = item['body'] ?? '';
      if (!_moneyContext.hasMatch(body)) continue;
      final amountMatches = _amount.allMatches(body).toList();
      if (amountMatches.isEmpty) continue;
      // Prefer a number explicitly tied to a currency; do not accidentally treat
      // a transfer/reference number earlier in the message as the money amount.
      final currencyMatches = amountMatches.where((match) =>
        _currency(match.group(1)) != null || _currency(match.group(3)) != null
      ).toList();
      final selectedMatches = currencyMatches.isNotEmpty ? currencyMatches : amountMatches;
      final amountMatch = selectedMatches.first;
      final amountText = _normalizeDigits(amountMatch.group(2) ?? '');
      if (amountText.isEmpty || double.tryParse(amountText.replaceAll(',', '').replaceAll('٬', '').replaceAll('٫', '.')) == null) continue;
      final currency = _currency(amountMatch.group(1)) ?? _currency(amountMatch.group(3));
      // A second amount may be a fee, balance, or currency conversion even
      // when only one amount has an explicit currency. Never choose silently.
      final secondaryAmountCue = RegExp(
        r'(مبلغ|بمبلغ|قيمة|عمولة|رسوم|خصم|تساوي|يساوي|المتبقي|الرصيد|amount|fee|commission|equals|balance)',
        caseSensitive: false,
      );
      final hasUnlabelledSecondaryMoney = amountMatches.any((match) {
        final isCurrencyTagged =
            _currency(match.group(1)) != null || _currency(match.group(3)) != null;
        if (isCurrencyTagged || match.start == amountMatch.start) return false;
        final start = match.start - 24 < 0 ? 0 : match.start - 24;
        final end = match.end + 12 > body.length ? body.length : match.end + 12;
        return secondaryAmountCue.hasMatch(body.substring(start, end));
      });
      final multipleExplicitAmounts =
          currencyMatches.length > 1 || hasUnlabelledSecondaryMoney;
      final hasPaidPhrase = _paid.hasMatch(body);
      final hasReceivedPhrase = _received.hasMatch(body);
      final detectedDirection = hasPaidPhrase == hasReceivedPhrase
          ? 'review'
          : hasPaidPhrase
              ? 'paid_to_trader'
              : 'received_from_trader';
      final direction = multipleExplicitAmounts ? 'review' : detectedDirection;
      results.add(WhatsAppCandidate(
        dateText: item['date'],
        sender: item['sender'],
        message: body,
        amountText: amountText.replaceAll(',', '').replaceAll('٬', '').replaceAll('٫', '.'),
        currency: currency,
        direction: direction,
        confidence: currency != null && direction != 'review' ? 'high' : 'review',
      ));
    }
    return results;
  }

  static String _normalizeDigits(String value) {
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    var output = value;
    for (var i = 0; i < 10; i++) {
      output = output.replaceAll(arabic[i], '$i').replaceAll(persian[i], '$i');
    }
    return output;
  }

  static String? _currency(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = raw.toLowerCase().replaceAll(' ', '');
    if (value == 'lyd' || value == 'د.ل' || value.contains('دينار')) return 'LYD';
    if (value == 'usd' || value == r'$' || value.contains('دولار')) return 'USD';
    if (value == 'eur' || value == '€' || value.contains('يورو')) return 'EUR';
    return null;
  }
}
,
  );
  static final _isoMessageStart = RegExp(
    r'^(\[?\d{4}-\d{1,2}-\d{1,2},?\s+\d{1,2}:\d{2}(?:\s?[APap][Mm])?\]?)\s*[-–]\s*([^:]+):\s*(.*)$',
  );

  static final _amount = RegExp(
    r'(?:(LYD|د\.ل|دينار(?:\s+ليبي)?|USD|\$|دولار|EUR|€|يورو)\s*)?'
    r'(?<![\w/])([0-9٠-٩۰-۹][0-9٠-٩۰-۹,٬]*(?:[.٫][0-9٠-٩۰-۹]{1,3})?)'
    r'\s*(LYD|د\.ل|دينار(?:\s+ليبي)?|USD|\$|دولار|EUR|€|يورو)?',
    caseSensitive: false,
  );

  static final _paid = RegExp(
    r'(حولت\s*لك|حوّلت\s*لك|ارسلت\s*لك|أرسلت\s*لك|بعثت\s*لك|بعت\s*لك|دفعت\s*لك|حولنالك|حوالة\s*لك|تم\s*التحويل\s*لك|sent\s+you|paid\s+you|transferred\s+to\s+you)',
    caseSensitive: false,
  );
  static final _received = RegExp(
    r'(حولت\s*لي|حوّلت\s*لي|ارسلت\s*لي|أرسلت\s*لي|بعثت\s*لي|وصلني\s*منك|استلمت\s*منك|حولت\s*منك|حوالة\s*منك|sent\s+me|paid\s+me|transferred\s+to\s+me|received\s+from\s+you)',
    caseSensitive: false,
  );
  static final _moneyContext = RegExp(
    r'(حوالة|تحويل|حولت|حوّلت|ارسلت|أرسلت|بعثت|دفعت|استلمت|وصلني|عليك|لي\s+عندك|لك\s+عندي|دينار|دولار|يورو|LYD|USD|EUR|\$|€)',
    caseSensitive: false,
  );

  static List<WhatsAppCandidate> parse(String text) {
    final messages = <Map<String, String?>>[];
    for (final rawLine in text.replaceAll('\r\n', '\n').split('\n')) {
      final line = rawLine.trimRight();
      final match = _messageStart.firstMatch(line) ?? _isoMessageStart.firstMatch(line);
      if (match != null) {
        messages.add({'date': match.group(1), 'sender': match.group(2)?.trim(), 'body': match.group(3) ?? ''});
      } else if (messages.isNotEmpty && line.isNotEmpty) {
        final previous = messages.last;
        previous['body'] = '${previous['body']}\n$line';
      }
    }

    final results = <WhatsAppCandidate>[];
    for (final item in messages) {
      final body = item['body'] ?? '';
      if (!_moneyContext.hasMatch(body)) continue;
      final amountMatches = _amount.allMatches(body).toList();
      if (amountMatches.isEmpty) continue;
      // Prefer a number explicitly tied to a currency; do not accidentally treat
      // a transfer/reference number earlier in the message as the money amount.
      final currencyMatches = amountMatches.where((match) =>
        _currency(match.group(1)) != null || _currency(match.group(3)) != null
      ).toList();
      final selectedMatches = currencyMatches.isNotEmpty ? currencyMatches : amountMatches;
      final amountMatch = selectedMatches.first;
      final amountText = _normalizeDigits(amountMatch.group(2) ?? '');
      if (amountText.isEmpty || double.tryParse(amountText.replaceAll(',', '').replaceAll('٬', '').replaceAll('٫', '.')) == null) continue;
      final currency = _currency(amountMatch.group(1)) ?? _currency(amountMatch.group(3));
      // A second amount may be a fee, balance, or currency conversion even
      // when only one amount has an explicit currency. Never choose silently.
      final secondaryAmountCue = RegExp(
        r'(مبلغ|بمبلغ|قيمة|عمولة|رسوم|خصم|تساوي|يساوي|المتبقي|الرصيد|amount|fee|commission|equals|balance)',
        caseSensitive: false,
      );
      final hasUnlabelledSecondaryMoney = amountMatches.any((match) {
        final isCurrencyTagged =
            _currency(match.group(1)) != null || _currency(match.group(3)) != null;
        if (isCurrencyTagged || match.start == amountMatch.start) return false;
        final start = match.start - 24 < 0 ? 0 : match.start - 24;
        final end = match.end + 12 > body.length ? body.length : match.end + 12;
        return secondaryAmountCue.hasMatch(body.substring(start, end));
      });
      final multipleExplicitAmounts =
          currencyMatches.length > 1 || hasUnlabelledSecondaryMoney;
      final hasPaidPhrase = _paid.hasMatch(body);
      final hasReceivedPhrase = _received.hasMatch(body);
      final detectedDirection = hasPaidPhrase == hasReceivedPhrase
          ? 'review'
          : hasPaidPhrase
              ? 'paid_to_trader'
              : 'received_from_trader';
      final direction = multipleExplicitAmounts ? 'review' : detectedDirection;
      results.add(WhatsAppCandidate(
        dateText: item['date'],
        sender: item['sender'],
        message: body,
        amountText: amountText.replaceAll(',', '').replaceAll('٬', '').replaceAll('٫', '.'),
        currency: currency,
        direction: direction,
        confidence: currency != null && direction != 'review' ? 'high' : 'review',
      ));
    }
    return results;
  }

  static String _normalizeDigits(String value) {
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    var output = value;
    for (var i = 0; i < 10; i++) {
      output = output.replaceAll(arabic[i], '$i').replaceAll(persian[i], '$i');
    }
    return output;
  }

  static String? _currency(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = raw.toLowerCase().replaceAll(' ', '');
    if (value == 'lyd' || value == 'د.ل' || value.contains('دينار')) return 'LYD';
    if (value == 'usd' || value == r'$' || value.contains('دولار')) return 'USD';
    if (value == 'eur' || value == '€' || value.contains('يورو')) return 'EUR';
    return null;
  }
}
,
  );

  static final _amount = RegExp(
    r'(?:(LYD|د\.ل|دينار(?:\s+ليبي)?|USD|\$|دولار|EUR|€|يورو)\s*)?'
    r'(?<![\w/])([0-9٠-٩۰-۹][0-9٠-٩۰-۹,٬]*(?:[.٫][0-9٠-٩۰-۹]{1,3})?)'
    r'\s*(LYD|د\.ل|دينار(?:\s+ليبي)?|USD|\$|دولار|EUR|€|يورو)?',
    caseSensitive: false,
  );

  static final _paid = RegExp(
    r'(حولت\s*لك|حوّلت\s*لك|ارسلت\s*لك|أرسلت\s*لك|بعثت\s*لك|بعت\s*لك|دفعت\s*لك|حولنالك|حوالة\s*لك|تم\s*التحويل\s*لك|sent\s+you|paid\s+you|transferred\s+to\s+you)',
    caseSensitive: false,
  );
  static final _received = RegExp(
    r'(حولت\s*لي|حوّلت\s*لي|ارسلت\s*لي|أرسلت\s*لي|بعثت\s*لي|وصلني\s*منك|استلمت\s*منك|حولت\s*منك|حوالة\s*منك|sent\s+me|paid\s+me|transferred\s+to\s+me|received\s+from\s+you)',
    caseSensitive: false,
  );
  static final _moneyContext = RegExp(
    r'(حوالة|تحويل|حولت|حوّلت|ارسلت|أرسلت|بعثت|دفعت|استلمت|وصلني|عليك|لي\s+عندك|لك\s+عندي|دينار|دولار|يورو|LYD|USD|EUR|\$|€)',
    caseSensitive: false,
  );

  static List<WhatsAppCandidate> parse(String text) {
    final messages = <Map<String, String?>>[];
    for (final rawLine in text.replaceAll('\r\n', '\n').split('\n')) {
      final line = rawLine.trimRight();
      final match = _messageStart.firstMatch(line) ?? _isoMessageStart.firstMatch(line);
      if (match != null) {
        messages.add({'date': match.group(1), 'sender': match.group(2)?.trim(), 'body': match.group(3) ?? ''});
      } else if (messages.isNotEmpty && line.isNotEmpty) {
        final previous = messages.last;
        previous['body'] = '${previous['body']}\n$line';
      }
    }

    final results = <WhatsAppCandidate>[];
    for (final item in messages) {
      final body = item['body'] ?? '';
      if (!_moneyContext.hasMatch(body)) continue;
      final amountMatches = _amount.allMatches(body).toList();
      if (amountMatches.isEmpty) continue;
      // Prefer a number explicitly tied to a currency; do not accidentally treat
      // a transfer/reference number earlier in the message as the money amount.
      final currencyMatches = amountMatches.where((match) =>
        _currency(match.group(1)) != null || _currency(match.group(3)) != null
      ).toList();
      final selectedMatches = currencyMatches.isNotEmpty ? currencyMatches : amountMatches;
      final amountMatch = selectedMatches.first;
      final amountText = _normalizeDigits(amountMatch.group(2) ?? '');
      if (amountText.isEmpty || double.tryParse(amountText.replaceAll(',', '').replaceAll('٬', '').replaceAll('٫', '.')) == null) continue;
      final currency = _currency(amountMatch.group(1)) ?? _currency(amountMatch.group(3));
      // A second amount may be a fee, balance, or currency conversion even
      // when only one amount has an explicit currency. Never choose silently.
      final secondaryAmountCue = RegExp(
        r'(مبلغ|بمبلغ|قيمة|عمولة|رسوم|خصم|تساوي|يساوي|المتبقي|الرصيد|amount|fee|commission|equals|balance)',
        caseSensitive: false,
      );
      final hasUnlabelledSecondaryMoney = amountMatches.any((match) {
        final isCurrencyTagged =
            _currency(match.group(1)) != null || _currency(match.group(3)) != null;
        if (isCurrencyTagged || match.start == amountMatch.start) return false;
        final start = match.start - 24 < 0 ? 0 : match.start - 24;
        final end = match.end + 12 > body.length ? body.length : match.end + 12;
        return secondaryAmountCue.hasMatch(body.substring(start, end));
      });
      final multipleExplicitAmounts =
          currencyMatches.length > 1 || hasUnlabelledSecondaryMoney;
      final hasPaidPhrase = _paid.hasMatch(body);
      final hasReceivedPhrase = _received.hasMatch(body);
      final detectedDirection = hasPaidPhrase == hasReceivedPhrase
          ? 'review'
          : hasPaidPhrase
              ? 'paid_to_trader'
              : 'received_from_trader';
      final direction = multipleExplicitAmounts ? 'review' : detectedDirection;
      results.add(WhatsAppCandidate(
        dateText: item['date'],
        sender: item['sender'],
        message: body,
        amountText: amountText.replaceAll(',', '').replaceAll('٬', '').replaceAll('٫', '.'),
        currency: currency,
        direction: direction,
        confidence: currency != null && direction != 'review' ? 'high' : 'review',
      ));
    }
    return results;
  }

  static String _normalizeDigits(String value) {
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    var output = value;
    for (var i = 0; i < 10; i++) {
      output = output.replaceAll(arabic[i], '$i').replaceAll(persian[i], '$i');
    }
    return output;
  }

  static String? _currency(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = raw.toLowerCase().replaceAll(' ', '');
    if (value == 'lyd' || value == 'د.ل' || value.contains('دينار')) return 'LYD';
    if (value == 'usd' || value == r'$' || value.contains('دولار')) return 'USD';
    if (value == 'eur' || value == '€' || value.contains('يورو')) return 'EUR';
    return null;
  }
}
,
  );
  static final _isoMessageStart = RegExp(
    r'^(\[?\d{4}-\d{1,2}-\d{1,2},?\s+\d{1,2}:\d{2}(?:\s?[APap][Mm])?\]?)\s*[-–]\s*([^:]+):\s*(.*)$',
  );

  static final _amount = RegExp(
    r'(?:(LYD|د\.ل|دينار(?:\s+ليبي)?|USD|\$|دولار|EUR|€|يورو)\s*)?'
    r'(?<![\w/])([0-9٠-٩۰-۹][0-9٠-٩۰-۹,٬]*(?:[.٫][0-9٠-٩۰-۹]{1,3})?)'
    r'\s*(LYD|د\.ل|دينار(?:\s+ليبي)?|USD|\$|دولار|EUR|€|يورو)?',
    caseSensitive: false,
  );

  static final _paid = RegExp(
    r'(حولت\s*لك|حوّلت\s*لك|ارسلت\s*لك|أرسلت\s*لك|بعثت\s*لك|بعت\s*لك|دفعت\s*لك|حولنالك|حوالة\s*لك|تم\s*التحويل\s*لك|sent\s+you|paid\s+you|transferred\s+to\s+you)',
    caseSensitive: false,
  );
  static final _received = RegExp(
    r'(حولت\s*لي|حوّلت\s*لي|ارسلت\s*لي|أرسلت\s*لي|بعثت\s*لي|وصلني\s*منك|استلمت\s*منك|حولت\s*منك|حوالة\s*منك|sent\s+me|paid\s+me|transferred\s+to\s+me|received\s+from\s+you)',
    caseSensitive: false,
  );
  static final _moneyContext = RegExp(
    r'(حوالة|تحويل|حولت|حوّلت|ارسلت|أرسلت|بعثت|دفعت|استلمت|وصلني|عليك|لي\s+عندك|لك\s+عندي|دينار|دولار|يورو|LYD|USD|EUR|\$|€)',
    caseSensitive: false,
  );

  static List<WhatsAppCandidate> parse(String text) {
    final messages = <Map<String, String?>>[];
    for (final rawLine in text.replaceAll('\r\n', '\n').split('\n')) {
      final line = rawLine.trimRight();
      final match = _messageStart.firstMatch(line) ?? _isoMessageStart.firstMatch(line);
      if (match != null) {
        messages.add({'date': match.group(1), 'sender': match.group(2)?.trim(), 'body': match.group(3) ?? ''});
      } else if (messages.isNotEmpty && line.isNotEmpty) {
        final previous = messages.last;
        previous['body'] = '${previous['body']}\n$line';
      }
    }

    final results = <WhatsAppCandidate>[];
    for (final item in messages) {
      final body = item['body'] ?? '';
      if (!_moneyContext.hasMatch(body)) continue;
      final amountMatches = _amount.allMatches(body).toList();
      if (amountMatches.isEmpty) continue;
      // Prefer a number explicitly tied to a currency; do not accidentally treat
      // a transfer/reference number earlier in the message as the money amount.
      final currencyMatches = amountMatches.where((match) =>
        _currency(match.group(1)) != null || _currency(match.group(3)) != null
      ).toList();
      final selectedMatches = currencyMatches.isNotEmpty ? currencyMatches : amountMatches;
      final amountMatch = selectedMatches.first;
      final amountText = _normalizeDigits(amountMatch.group(2) ?? '');
      if (amountText.isEmpty || double.tryParse(amountText.replaceAll(',', '').replaceAll('٬', '').replaceAll('٫', '.')) == null) continue;
      final currency = _currency(amountMatch.group(1)) ?? _currency(amountMatch.group(3));
      // A second amount may be a fee, balance, or currency conversion even
      // when only one amount has an explicit currency. Never choose silently.
      final secondaryAmountCue = RegExp(
        r'(مبلغ|بمبلغ|قيمة|عمولة|رسوم|خصم|تساوي|يساوي|المتبقي|الرصيد|amount|fee|commission|equals|balance)',
        caseSensitive: false,
      );
      final hasUnlabelledSecondaryMoney = amountMatches.any((match) {
        final isCurrencyTagged =
            _currency(match.group(1)) != null || _currency(match.group(3)) != null;
        if (isCurrencyTagged || match.start == amountMatch.start) return false;
        final start = match.start - 24 < 0 ? 0 : match.start - 24;
        final end = match.end + 12 > body.length ? body.length : match.end + 12;
        return secondaryAmountCue.hasMatch(body.substring(start, end));
      });
      final multipleExplicitAmounts =
          currencyMatches.length > 1 || hasUnlabelledSecondaryMoney;
      final hasPaidPhrase = _paid.hasMatch(body);
      final hasReceivedPhrase = _received.hasMatch(body);
      final detectedDirection = hasPaidPhrase == hasReceivedPhrase
          ? 'review'
          : hasPaidPhrase
              ? 'paid_to_trader'
              : 'received_from_trader';
      final direction = multipleExplicitAmounts ? 'review' : detectedDirection;
      results.add(WhatsAppCandidate(
        dateText: item['date'],
        sender: item['sender'],
        message: body,
        amountText: amountText.replaceAll(',', '').replaceAll('٬', '').replaceAll('٫', '.'),
        currency: currency,
        direction: direction,
        confidence: currency != null && direction != 'review' ? 'high' : 'review',
      ));
    }
    return results;
  }

  static String _normalizeDigits(String value) {
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    var output = value;
    for (var i = 0; i < 10; i++) {
      output = output.replaceAll(arabic[i], '$i').replaceAll(persian[i], '$i');
    }
    return output;
  }

  static String? _currency(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = raw.toLowerCase().replaceAll(' ', '');
    if (value == 'lyd' || value == 'د.ل' || value.contains('دينار')) return 'LYD';
    if (value == 'usd' || value == r'$' || value.contains('دولار')) return 'USD';
    if (value == 'eur' || value == '€' || value.contains('يورو')) return 'EUR';
    return null;
  }
}
