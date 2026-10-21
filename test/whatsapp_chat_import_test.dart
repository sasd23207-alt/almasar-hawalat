import 'package:flutter_test/flutter_test.dart';
import 'package:almasar_hawalat/whatsapp/chat_import.dart';

void main() {
  group('WhatsAppChatParser', () {
    test('recognizes Arabic transfer phrase, Arabic digits, and LYD', () {
      final rows = WhatsAppChatParser.parse(
        '21/10/2026, 10:30 - Salem: حولت لك ١٥٠ دينار ليبي',
      );
      expect(rows, hasLength(1));
      expect(rows.single.amountText, '150');
      expect(rows.single.currency, 'LYD');
      expect(rows.single.direction, 'paid_to_trader');
      expect(rows.single.confidence, 'high');
    });

    test('recognizes sent-to-me phrase and USD', () {
      final rows = WhatsAppChatParser.parse(
        '2026-10-20, 12:00 - Trader: أرسلت لي 250 USD',
      );
      expect(rows, hasLength(1));
      expect(rows.single.amountText, '250');
      expect(rows.single.currency, 'USD');
      expect(rows.single.direction, 'received_from_trader');
    });

    test('keeps ambiguous transfer wording for manual review', () {
      final rows = WhatsAppChatParser.parse(
        '21/10/2026, 10:30 - Salem: حوالة 70',
      );
      expect(rows, hasLength(1));
      expect(rows.single.direction, 'review');
      expect(rows.single.confidence, 'review');
      expect(rows.single.currency, isNull);
    });

    test('recognizes common Libyan phrase بعثت لك and keeps currency explicit', () {
      final rows = WhatsAppChatParser.parse(
        '21/10/2026, 11:15 - Salem: بعثت لك 1,250.500 د.ل',
      );
      expect(rows, hasLength(1));
      expect(rows.single.amountText, '1250.500');
      expect(rows.single.currency, 'LYD');
      expect(rows.single.direction, 'paid_to_trader');
    });

    test('does not guess direction from عليك even when amount and currency exist', () {
      final rows = WhatsAppChatParser.parse(
        '21/10/2026, 11:20 - Trader: عليك 75 USD',
      );
      expect(rows, hasLength(1));
      expect(rows.single.direction, 'review');
      expect(rows.single.confidence, 'review');
    });

    test('normalizes Persian digits and preserves the explicit currency', () {
      final rows = WhatsAppChatParser.parse(
        '21/10/2026, 11:25 - Salem: أرسلت لك ۷۵ USD',
      );
      expect(rows, hasLength(1));
      expect(rows.single.amountText, '75');
      expect(rows.single.currency, 'USD');
    });

    test('ignores ordinary messages with no money context', () {
      expect(
        WhatsAppChatParser.parse('21/10/2026, 10:30 - Salem: تمام شكرا'),
        isEmpty,
      );
    });

    test('joins wrapped message lines', () {
      final rows = WhatsAppChatParser.parse(
        '21/10/2026, 10:30 - Salem: حولت لك\nالمبلغ 40 USD',
      );
      expect(rows, hasLength(1));
      expect(rows.single.message, contains('المبلغ 40 USD'));
    });
  });
}
