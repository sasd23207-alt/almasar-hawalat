# حسابات التجار واستيراد محادثات واتساب

## الحالة الحالية

- [WRITTEN-ONLY until CI passes] Import UI accepts WhatsApp-exported `.txt` files, parses candidate money messages, and presents them for human review.
- [WRITTEN-ONLY until CI passes] Merchant accounts and ledger entries are stored in local SQLite tables.
- [WRITTEN-ONLY until CI passes] The import batch is atomic; exact duplicate source keys are ignored.
- [WRITTEN-ONLY until CI passes] Statement totals are grouped by currency and direction.
- [NOT IMPLEMENTED] Automatic exchange-rate conversion. No cross-currency net total is calculated.
- [NOT IMPLEMENTED] Automatic access to private WhatsApp chats. The user must export and choose the text file.
- [NOT VERIFIED] Testing on a physical Android phone and with real merchant exports.

## Import workflow

1. In WhatsApp, export the merchant conversation as a text file (`.txt`). Avoid attaching media if it is not needed.
2. In the app, open **التجار** → **إضافة تاجر من واتساب**.
3. Enter the merchant's name. The optional phone number is metadata only.
4. Review the candidate messages. Check the original text, amount, currency, and direction. Uncheck non-transactions.
5. For any unclear message, choose the correct amount/currency/direction manually, or leave it unchecked. A direction of `review` is never accepted into the ledger.
6. Confirm the import and inspect the merchant statement. The result shows inserted rows and duplicates ignored.

## Accounting rules

- Stored amounts are integer minor units; LYD uses 3 decimal places, USD and EUR use 2.
- Each transaction preserves its original message and sender for audit.
- The ledger defines `paid_to_trader` as money sent by the app user to the merchant and `received_from_trader` as money received by the app user from the merchant.
- Statement net is calculated separately per currency as **received − sent**. A positive number means more was received than sent; it is not by itself a legal debt determination.
- No automatic currency conversion is performed. Exchange profit/loss requires an explicit rate and a documented base-currency convention, which are not yet implemented.
- If multiple currency-tagged amounts appear in one message, direction is ambiguous, or the currency is not explicit, the parser marks the candidate for review rather than choosing a result silently.
- Numeric dates where both day and month could be interpreted either way are not normalized into a date. The original text remains available.
- Re-importing the same source line with the same merchant, amount, currency, direction, sender, and date text is idempotent. Editing the parsed details changes the deduplication key; review carefully to avoid importing an edited line as a separate transaction.

## Local data and backups

Merchant data is stored on the device in the app's SQLite database. Version-2 backup files include merchant accounts and merchant transactions. Restoring a backup replaces current local records; make a fresh backup first. Keep backup files private because they include financial information and original chat text.

## Verification checklist before real accounting use

- [ ] Latest GitHub Actions run passes Flutter analysis, all tests, and debug APK build.
- [ ] Test a real exported chat from each WhatsApp language/date format in use.
- [ ] Compare imported rows against the original conversation line-by-line.
- [ ] Re-import the same file and confirm duplicates are ignored.
- [ ] Export and restore a version-2 backup on a second test device.
- [ ] Have an accountant validate ledger direction conventions and statement totals.
- [ ] Test on the target Android devices; CI build success alone does not verify device behavior.
