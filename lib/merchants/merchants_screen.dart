import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/money.dart';
import '../data/local_database.dart';
import '../whatsapp/chat_import.dart';

class MerchantsScreen extends StatefulWidget {
  const MerchantsScreen({super.key, required this.onChanged});
  final VoidCallback onChanged;

  @override
  State<MerchantsScreen> createState() => _MerchantsScreenState();
}

class _MerchantsScreenState extends State<MerchantsScreen> {
  int _refresh = 0;

  Future<void> _importChat() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty || !mounted) return;
    try {
      final file = picked.files.single;
      final bytes = file.bytes;
      final path = file.path;
      final text = bytes != null
          ? utf8.decode(bytes, allowMalformed: true)
          : path != null
              ? await File(path).readAsString()
              : throw const FormatException('تعذرت قراءة ملف المحادثة');
      final nameController = TextEditingController();
      final phoneController = TextEditingController();
      final details = await showDialog<_ImportDetails>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('بيانات التاجر'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('الملف: ${file.name}', maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            TextField(controller: nameController, autofocus: true, decoration: const InputDecoration(labelText: 'اسم التاجر *')),
            const SizedBox(height: 12),
            TextField(controller: phoneController, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم التاجر (اختياري)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                if (nameController.text.trim().isEmpty) return;
                Navigator.pop(context, _ImportDetails(nameController.text.trim(), phoneController.text.trim(), text));
              },
              child: const Text('تحليل المحادثة'),
            ),
          ],
        ),
      );
      nameController.dispose();
      phoneController.dispose();
      if (details == null || !mounted) return;
      final candidates = WhatsAppChatParser.parse(details.text);
      if (candidates.isEmpty) {
        _showMessage('لم أعثر على رسائل مالية واضحة. لم يتم تسجيل أي عملية.');
        return;
      }
      final accepted = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => _ReviewImportScreen(details: details, candidates: candidates)),
      );
      if (accepted == true && mounted) {
        setState(() => _refresh++);
        widget.onChanged();
        _showMessage('اكتملت مراجعة الاستيراد. راجع ملخص التاجر للتأكد من الأرقام.');
      }
    } catch (error) {
      if (mounted) _showMessage('تعذر استيراد المحادثة؛ لم يتم تسجيل أي شيء: $error');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _importChat,
      icon: const Icon(Icons.file_upload_outlined),
      label: const Text('إضافة تاجر من واتساب'),
    ),
    body: FutureBuilder<List<Map<String, Object?>>>(
      key: ValueKey(_refresh),
      future: LocalDatabase.instance.getMerchants(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text('تعذر تحميل حسابات التجار: ${snapshot.error}')));
        final merchants = snapshot.data ?? [];
        if (merchants.isEmpty) {
          return ListView(padding: const EdgeInsets.all(20), children: const [
            SizedBox(height: 28),
            Icon(Icons.account_balance_outlined, size: 58, color: Color(0xFF294D75)),
            SizedBox(height: 14),
            Text('حسابات التجار وكشوف الحساب', textAlign: TextAlign.center, style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
            SizedBox(height: 10),
            Text('صدّر المحادثة من واتساب كملف TXT، ثم استوردها هنا. ستظهر العمليات المقترحة للمراجعة قبل اعتمادها. الرسائل الغامضة لا تُسجّل تلقائيًا.', textAlign: TextAlign.center, style: TextStyle(height: 1.6, color: Colors.black54)),
          ]);
        }
        return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
          const Padding(padding: EdgeInsets.all(8), child: Text('حسابات التجار', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
          ...merchants.map((merchant) => Card(
            elevation: 0,
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.storefront_outlined)),
              title: Text(merchant['name'] as String, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${merchant['transaction_count']} عملية مسجلة${(merchant['phone'] as String).isEmpty ? '' : ' • ${merchant['phone']}'}'),
              trailing: const Icon(Icons.chevron_left),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MerchantStatementScreen(merchant: merchant))),
            ),
          )),
        ]);
      },
    ),
  );
}

class _ImportDetails {
  const _ImportDetails(this.name, this.phone, this.text);
  final String name;
  final String phone;
  final String text;
}

class _ReviewImportScreen extends StatefulWidget {
  const _ReviewImportScreen({required this.details, required this.candidates});
  final _ImportDetails details;
  final List<WhatsAppCandidate> candidates;

  @override
  State<_ReviewImportScreen> createState() => _ReviewImportScreenState();
}

class _ReviewImportScreenState extends State<_ReviewImportScreen> {
  late final List<_EditableCandidate> _rows;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _rows = widget.candidates.map(_EditableCandidate.new).toList();
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.amount.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final selected = _rows.where((row) => row.include).toList();
    if (selected.isEmpty) {
      setState(() => _error = 'اختر عملية واحدة على الأقل بعد مراجعتها.');
      return;
    }
    final prepared = <MapEntry<_EditableCandidate, int>>[];
    try {
      for (final row in selected) {
        if (row.direction == null || row.direction == 'review' || row.currency == null) {
          throw const FormatException('حدد اتجاهًا مؤكدًا وعملة لكل عملية مختارة.');
        }
        final amountMinor = toMinorUnits(row.amount.text.trim(), row.currency!);
        prepared.add(MapEntry(row, amountMinor));
      }
    } catch (error) {
      setState(() => _error = 'لم يُحفظ شيء. راجع البيانات: $error');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final merchantId = await LocalDatabase.instance.getOrCreateMerchant(name: widget.details.name, phone: widget.details.phone);
      final batch = DateTime.now().toUtc().toIso8601String();
      final payload = <Map<String, Object?>>[];
      for (final entry in prepared) {
        final row = entry.key;
        final amountMinor = entry.value;
        final currency = row.currency!;
        final keyText = '${widget.details.name.toLowerCase()}|'
            '${row.candidate.dateText ?? ''}|'
            '${row.candidate.sender ?? ''}|'
            '${row.candidate.message.trim()}|'
            '${amountMinor}|$currency|${row.direction}';
        payload.add({
          'merchant_id': merchantId,
          'source_key': base64Url.encode(utf8.encode(keyText)),
          'transaction_date': _parseDate(row.candidate.dateText),
          'sender': row.candidate.sender ?? '',
          'original_message': row.candidate.message,
          'amount_minor': amountMinor,
          'currency': currency,
          'direction': row.direction!,
          'import_batch': batch,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
      final result = await LocalDatabase.instance.addMerchantTransactionsBatch(payload);
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('ملخص الاستيراد'),
            content: Text('عمليات جديدة: ${result['inserted']}\nعمليات مكررة تم تجاهلها: ${result['duplicates']}\n\nراجع كشف الحساب، خصوصًا العمليات التي عدّلتها يدويًا.'),
            actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('تم'))],
          ),
        );
        if (mounted) Navigator.pop(context, true);
      }
    } catch (error) {
      if (mounted) setState(() { _saving = false; _error = 'لم يكتمل الاستيراد: $error'; });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('مراجعة رسائل التاجر')),
    body: Column(children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        color: const Color(0xFFFFF3CD),
        child: Text('التاجر: ${widget.details.name}\nراجع كل سطر قبل اعتماده. لا تعتمد أي رسالة إلا إذا كان المبلغ والعملة والاتجاه صحيحين. الرسائل الأصلية تُحفظ للمراجعة.', style: const TextStyle(height: 1.5)),
      ),
      Expanded(child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _rows.length,
        itemBuilder: (context, index) {
          final row = _rows[index];
          return Card(
            elevation: 0,
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: row.include,
                  onChanged: (value) => setState(() => row.include = value ?? false),
                  title: Text('رسالة ${index + 1} • ${row.candidate.dateText ?? 'تاريخ غير محدد'}'),
                  subtitle: Text(row.candidate.message, maxLines: 5, overflow: TextOverflow.ellipsis),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                if (row.candidate.direction == 'review' || row.candidate.currency == null)
                  const Text('⚠️ تحتاج هذه الرسالة إلى تحقق يدوي قبل تسجيلها.', style: TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.bold)),
                Row(children: [
                  Expanded(child: TextField(controller: row.amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'المبلغ'))),
                  const SizedBox(width: 8),
                  Expanded(child: DropdownButtonFormField<String>(
                    initialValue: row.currency,
                    decoration: const InputDecoration(labelText: 'العملة'),
                    items: const [
                      DropdownMenuItem(value: 'LYD', child: Text('LYD')),
                      DropdownMenuItem(value: 'USD', child: Text('USD')),
                      DropdownMenuItem(value: 'EUR', child: Text('EUR')),
                    ],
                    onChanged: (value) => setState(() => row.currency = value),
                  )),
                ]),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: row.direction,
                  decoration: const InputDecoration(labelText: 'اتجاه العملية'),
                  items: const [
                    DropdownMenuItem(value: 'paid_to_trader', child: Text('أرسلت للتاجر')),
                    DropdownMenuItem(value: 'received_from_trader', child: Text('استلمت من التاجر')),
                    DropdownMenuItem(value: 'review', child: Text('غير محسوم — لا يُحفظ')),
                  ],
                  onChanged: (value) => setState(() => row.direction = value),
                ),
                if (row.candidate.sender != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('مرسل الرسالة: ${row.candidate.sender}', style: const TextStyle(color: Colors.black54))),
              ]),
            ),
          );
        },
      )),
      if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
      SafeArea(child: Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(width: double.infinity, child: FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.verified_outlined),
          label: Text(_saving ? 'جارٍ الحفظ...' : 'اعتماد العمليات المختارة'),
        )),
      )),
    ]),
  );
}

class _EditableCandidate {
  _EditableCandidate(this.candidate)
      : amount = TextEditingController(text: candidate.amountText),
        currency = candidate.currency,
        direction = candidate.direction == 'review' ? null : candidate.direction,
        include = candidate.confidence == 'high' && candidate.dateText != null;
  final WhatsAppCandidate candidate;
  final TextEditingController amount;
  String? currency;
  String? direction;
  bool include;
}

String? _parseDate(String? raw) {
  if (raw == null) return null;
  final match = RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(raw) ??
      RegExp(r'(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})').firstMatch(raw);
  if (match == null) return null;
  try {
    int year;
    int month;
    int day;
    if (match.group(1)!.length == 4) {
      year = int.parse(match.group(1)!);
      month = int.parse(match.group(2)!);
      day = int.parse(match.group(3)!);
    } else {
      day = int.parse(match.group(1)!);
      month = int.parse(match.group(2)!);
      year = int.parse(match.group(3)!);
      if (year < 100) year += year >= 70 ? 1900 : 2000;
    }
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) return null;
    return date.toIso8601String();
  } catch (_) {
    return null;
  }
}

class MerchantStatementScreen extends StatelessWidget {
  const MerchantStatementScreen({super.key, required this.merchant});
  final Map<String, Object?> merchant;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(merchant['name'] as String)),
    body: FutureBuilder(
      future: Future.wait([
        LocalDatabase.instance.getMerchantTransactions(merchant['id'] as int),
        LocalDatabase.instance.getMerchantTotals(merchant['id'] as int),
      ]),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) return Center(child: Text('تعذر إعداد كشف الحساب: ${snapshot.error}'));
        final transactions = snapshot.data![0] as List<Map<String, Object?>>;
        final totals = snapshot.data![1] as Map<String, int>;
        Widget totalCard(String currency) {
          final sent = totals['${currency}_paid_to_trader'] ?? 0;
          final received = totals['${currency}_received_from_trader'] ?? 0;
          return Card(elevation: 0, child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(currency, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
              const SizedBox(height: 8),
              Text('أرسلت للتاجر: ${_format(sent, currency)}'),
              Text('استلمت من التاجر: ${_format(received, currency)}'),
              const Divider(),
              Text('الصافي (استلام − إرسال): ${_format(received - sent, currency)}', style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
          ));
        }
        return ListView(padding: const EdgeInsets.all(12), children: [
          const Text('ملخص حسب العملة — لا يتم دمج العملات أو تحويلها تلقائيًا.', style: TextStyle(color: Colors.black54)),
          const SizedBox(height: 8),
          totalCard('LYD'), totalCard('USD'), totalCard('EUR'),
          const SizedBox(height: 14),
          const Text('سجل العمليات', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
          if (transactions.isEmpty) const Padding(padding: EdgeInsets.all(18), child: Text('لا توجد عمليات مسجلة.')),
          ...transactions.map((tx) {
            final sent = tx['direction'] == 'paid_to_trader';
            final date = tx['transaction_date'] as String?;
            return Card(elevation: 0, child: ListTile(
              leading: Icon(sent ? Icons.north_east : Icons.south_west, color: sent ? Colors.deepOrange : Colors.green),
              title: Text('${sent ? 'أرسلت للتاجر' : 'استلمت من التاجر'} • ${_format(tx['amount_minor'] as int, tx['currency'] as String)} ${tx['currency']}'),
              subtitle: Text('${date ?? 'تاريخ غير مؤكد'}\n${tx['original_message']}', maxLines: 4, overflow: TextOverflow.ellipsis),
              isThreeLine: true,
            ));
          }),
        ]);
      },
    ),
  );
}

String _format(int minor, String currency) {
  try { return fromMinorUnits(minor, currency); } catch (_) { return minor.toString(); }
}
