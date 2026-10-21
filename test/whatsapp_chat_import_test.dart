import 'package:flutter_test/flutter_test.dart';
import 'package:almasar_hawalat/whatsapp/chat_import.dart';

void main() {
  group('WhatsAppChatParser', () {
    test('recognizes Arabic transfer phrase, Arabic digits, and LYD', () {
      final rows = WhatsAppChatParser.parse(
        '21/10/2026, 10:30 - Salem: حولت لك ١٥٠ دينار ليبي',
        accountOwnerName: 'Salem', traderSenderName: 'Trader',
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
        accountOwnerName: 'Salem', traderSenderName: 'Trader',
      );
      expect(rows, hasLength(1));
      expect(rows.single.amountText, '250');
      expect(rows.single.currency, 'USD');
      // The trader authored "you sent me", so this is paid to the trader.
      expect(rows.single.direction, 'paid_to_trader');
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
        accountOwnerName: 'Salem', traderSenderName: 'Trader',
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
        accountOwnerName: 'Salem', traderSenderName: 'Trader',
      );
      expect(rows, hasLength(1));
      expect(rows.single.amountText, '75');
      expect(rows.single.currency, 'USD');
    });

    test('prefers currency-linked amount over an earlier transfer reference number', () {
      final rows = WhatsAppChatParser.parse(
        '21/10/2026, 11:40 - Salem: تم التحويل رقم 12345 بمبلغ 200 USD لك',
        accountOwnerName: 'Salem', traderSenderName: 'Trader',
      );
      expect(rows, hasLength(1));
      expect(rows.single.amountText, '200');
      expect(rows.single.currency, 'USD');
    });

    test('flags messages containing multiple explicit money amounts for review', () {
      final rows = WhatsAppChatParser.parse(
        '21/10/2026, 11:45 - Salem: حولت لك 100 USD وتساوي 500 LYD',
      );
      expect(rows, hasLength(1));
      expect(rows.single.direction, 'review');
      expect(rows.single.confidence, 'review');
    });

    test('flags a second fee amount even when only the transfer has a currency', () {
      final rows = WhatsAppChatParser.parse(
        '21/10/2026, 11:46 - Salem: حولت لك 100 USD عمولة 20',
      );
      expect(rows, hasLength(1));
      expect(rows.single.direction, 'review');
      expect(rows.single.confidence, 'review');
    });

    test('does not choose a direction when one message contains both directions', () {
      final rows = WhatsAppChatParser.parse(
        '21/10/2026, 11:47 - Salem: حولت لك 100 USD ثم استلمت منك 50 USD',
      );
      expect(rows, hasLength(1));
      expect(rows.single.direction, 'review');
      expect(rows.single.confidence, 'review');
    });


    test('recognizes iPhone-style bracketed export with seconds and AM/PM', () {
      final rows = WhatsAppChatParser.parse(
        '[10/21/26, 10:30:45 AM] Salem: حولت لك ١٥٠ دينار ليبي',
        accountOwnerName: 'Salem', traderSenderName: 'Trader',
      );
      expect(rows, hasLength(1));
      expect(rows.single.amountText, '150');
      expect(rows.single.currency, 'LYD');
      expect(rows.single.direction, 'paid_to_trader');
      expect(rows.single.dateText, '[10/21/26, 10:30:45 AM]');
    });

    test('recognizes ISO export timestamp with seconds', () {
      final rows = WhatsAppChatParser.parse(
        '2026-10-20, 12:00:30 - Trader: أرسلت لي 250 USD',
        accountOwnerName: 'Salem', traderSenderName: 'Trader',
      );
      expect(rows, hasLength(1));
      expect(rows.single.amountText, '250');
      expect(rows.single.currency, 'USD');
      // The trader authored "you sent me", so this is paid to the trader.
      expect(rows.single.direction, 'paid_to_trader');
    });

    test('does not infer a direction from a generic payment statement', () {
      final rows = WhatsAppChatParser.parse(
        '21/10/2026, 11:48 - Salem: تم تحويل مبلغ 90 USD',
      );
      expect(rows, hasLength(1));
      expect(rows.single.direction, 'review');
      expect(rows.single.confidence, 'review');
    });

    test('reverses direction when the trader authored the message', () {
      final rows = WhatsAppChatParser.parse(
        '21/10/2026, 11:49 - Trader: حولت لك 90 USD',
        accountOwnerName: 'Salem', traderSenderName: 'Trader',
      );
      expect(rows, hasLength(1));
      expect(rows.single.direction, 'received_from_trader');
    });

    test('does not infer direction when sender is neither configured participant', () {
      final rows = WhatsAppChatParser.parse(
        '21/10/2026, 11:50 - Unknown: حولت لك 90 USD',
        accountOwnerName: 'Salem', traderSenderName: 'Trader',
      );
      expect(rows, hasLength(1));
      expect(rows.single.direction, 'review');
      expect(rows.single.confidence, 'review');
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
