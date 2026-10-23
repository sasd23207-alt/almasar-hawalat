import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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
  StreamSubscription<List<SharedMediaFile>>? _shareSubscription;
  StreamSubscription<String?>? _sharedTextSubscription;
  bool _handlingSharedFile = false;

  @override
  void initState() {
    super.initState();
    // Accept both shared files and actual text sent by another app.
    // This enables direct processing when the sender app really provides text;
    // it cannot make WhatsApp expose its entire private chat history.
    _shareSubscription = ReceiveSharingIntent.instance.getMediaStream().listen(
      (files) { if (files.isNotEmpty) _handleSharedFile(files.first.path); },
      onError: (_) { if (mounted) _showMessage('تعذر استقبال المحتوى المشترك. يمكنك فتح الاستيراد من حساب التاجر.'); },
    );
    _sharedTextSubscription = ReceiveSharingIntent.instance.getTextStream().listen(
      (text) { if (text != null && text.trim().isNotEmpty) _handleSharedText(text); },
      onError: (_) {},
    );
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      if (files.isNotEmpty && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _handleSharedFile(files.first.path));
      }
      ReceiveSharingIntent.instance.reset();
    }).catchError((_) {});
    ReceiveSharingIntent.instance.getInitialText().then((text) {
      if (text != null && text.trim().isNotEmpty && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _handleSharedText(text));
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _shareSubscription?.cancel();
    _sharedTextSubscription?.cancel();
    super.dispose();
  }

  Future<void> _handleSharedText(String text) async {
    if (!mounted || _handlingSharedFile || text.trim().isEmpty) return;
    _handlingSharedFile = true;
    try {
      await _importChat(sharedText: text);
    } finally {
      _handlingSharedFile = false;
      ReceiveSharingIntent.instance.reset();
    }
  }

  Future<void> _handleSharedFile(String path) async {
    if (!mounted || _handlingSharedFile || path.isEmpty) return;
    _handlingSharedFile = true;
    try {
      if (!path.toLowerCase().endsWith('.txt')) {
        _showMessage('الملف المشترك ليس TXT. صدّر محادثة واتساب كملف نصي ثم شاركه.');
        return;
      }
      await _importChat(sharedPath: path);
    } finally {
      _handlingSharedFile = false;
      ReceiveSharingIntent.instance.reset();
    }
  }

  Future<void> _importChat({String? sharedPath, String? sharedText}) async {
    PlatformFile? selectedFile;
    String? path = sharedPath;
    if (sharedPath == null && sharedText == null) {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['txt'], withData: true,
      );
      if (picked == null || picked.files.isEmpty || !mounted) return;
      selectedFile = picked.files.single;
      path = selectedFile.path;
    }
    try {
      final bytes = selectedFile?.bytes;
      final text = sharedText ??
          (bytes != null
              ? utf8.decode(bytes, allowMalformed: true)
              : path != null
                  ? await File(path).readAsString()
                  : throw const FormatException('تعذر قراءة النص أو الملف المشترك'));
      final fileName = selectedFile?.name ?? path?.split('/').last ?? 'نص مستلم من تطبيق آخر';
      final nameController = TextEditingController();
      final phoneController = TextEditingController();
      final ownerNameController = TextEditingController();
      final traderSenderController = TextEditingController();
      // Reuse the last participant names for this merchant so repeat imports
      // need fewer taps. The operator can still edit them before proceeding.
      final savedProfile = await LocalDatabase.instance.getMerchantImportProfile(nameController.text);
      if (savedProfile != null) {
        ownerNameController.text = savedProfile['owner_sender_name'] as String;
        traderSenderController.text = savedProfile['trader_sender_name'] as String;
      }
      final details = await showDialog<_ImportDetails>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('بيانات التاجر'),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('الملف: $fileName', maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            TextField(controller: nameController, autofocus: true, decoration: const InputDecoration(labelText: 'اسم التاجر في كشف الحساب *')),
            const SizedBox(height: 12),
            TextField(controller: ownerNameController, decoration: const InputDecoration(labelText: 'اسمك كما يظهر في المحادثة *')),
            const SizedBox(height: 12),
            TextField(controller: traderSenderController, decoration: const InputDecoration(labelText: 'اسم التاجر كما يظهر في المحادثة *')),
            const SizedBox(height: 12),
            TextField(controller: phoneController, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم التاجر (اختياري)')),
            const SizedBox(height: 8),
            const Text('نحتاج اسمَي طرفَي المحادثة حتى لا نعكس اتجاه الحوالة بالخطأ. أي اسم غير معروف سيبقى للمراجعة اليدوية.', style: TextStyle(color: Colors.black54)),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                if (nameController.text.trim().isEmpty ||
                    ownerNameController.text.trim().isEmpty ||
                    traderSenderController.text.trim().isEmpty) return;
                Navigator.pop(context, _ImportDetails(
                  name: nameController.text.trim(),
                  phone: phoneController.text.trim(),
                  text: text,
                  ownerName: ownerNameController.text.trim(),
                  traderSenderName: traderSenderController.text.trim(),
                ));
              },
              child: const Text('تحليل المحادثة'),
            ),
          ],
        ),
      );
      nameController.dispose();
      phoneController.dispose();
      ownerNameController.dispose();
      traderSenderController.dispose();
      if (details == null || !mounted) return;
      // Persist the mapping for the next import from this merchant.
      final profileMerchantId = await LocalDatabase.instance.getOrCreateMerchant(
        name: details.name,
        phone: details.phone,
      );
      await LocalDatabase.instance.saveMerchantImportProfile(
        merchantId: profileMerchantId,
        ownerSenderName: details.ownerName,
        traderSenderName: details.traderSenderName,
      );
      final candidates = WhatsAppChatParser.parse(
        details.text,
        accountOwnerName: details.ownerName,
        traderSenderName: details.traderSenderName,
      );
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
  const _ImportDetails({
    required this.name,
    required this.phone,
    required this.text,
    required this.ownerName,
    required this.traderSenderName,
  });
  final String name;
  final String phone;
  final String text;
  final String ownerName;
  final String traderSenderName;
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
        // Identity is based on the original source message, not editable
        // review fields. Changing an amount/currency/direction during review
        // must not make the same imported message look like a new transaction.
        final keyText = '${widget.details.name.trim().toLowerCase()}|'
            '${row.candidate.dateText ?? ''}|'
            '${(row.candidate.sender ?? '').trim()}|'
            '${row.candidate.message.replaceAll('\r\n', '\n').trim()}';
        payload.add({
          'merchant_id': merchantId,
          'source_key': base64Url.encode(utf8.encode(keyText)),
          'transaction_date': parseWhatsAppDate(row.candidate.dateText),
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
        include = candidate.confidence == 'high' && parseWhatsAppDate(candidate.dateText) != null;
  final WhatsAppCandidate candidate;
  final TextEditingController amount;
  String? currency;
  String? direction;
  bool include;
}

class MerchantStatementScreen extends StatefulWidget {
  const MerchantStatementScreen({super.key, required this.merchant});
  final Map<String, Object?> merchant;
  @override
  State<MerchantStatementScreen> createState() => _MerchantStatementScreenState();
}

class _MerchantStatementScreenState extends State<MerchantStatementScreen> {
  int _revision = 0;
  Future<void> _openWhatsApp() async {
    final phone = (widget.merchant['phone'] as String? ?? '').replaceAll(RegExp(r'[^0-9+]'), '');
    if (phone.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('أضف رقم التاجر مع مفتاح الدولة أولًا.'))); return; }
    try {
      final ok = await launchUrl(Uri.parse('https://wa.me/${phone.replaceAll('+', '')}'), mode: LaunchMode.externalApplication);
      if (!ok && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر فتح واتساب لهذا الرقم. تحقق من الرقم وتثبيت واتساب.')));
    } catch (_) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر فتح واتساب. تحقق من الرقم وتثبيت التطبيق.'))); }
  }
  Future<void> _addManual() async {
    final added = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => _ManualMerchantTransactionScreen(merchant: widget.merchant)));
    if (added == true && mounted) setState(() => _revision++);
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.merchant['name'] as String), actions: [IconButton(tooltip: 'فتح واتساب', onPressed: _openWhatsApp, icon: const Icon(Icons.chat_outlined))]),
    floatingActionButton: FloatingActionButton.extended(onPressed: _addManual, icon: const Icon(Icons.add), label: const Text('إضافة حوالة يدويًا')),
    body: FutureBuilder(
      key: ValueKey(_revision),
      future: Future.wait([
        LocalDatabase.instance.getMerchantTransactions(widget.merchant['id'] as int),
        LocalDatabase.instance.getMerchantTotals(widget.merchant['id'] as int),
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


class _ManualMerchantTransactionScreen extends StatefulWidget {
  const _ManualMerchantTransactionScreen({required this.merchant});
  final Map<String, Object?> merchant;
  @override State<_ManualMerchantTransactionScreen> createState() => _ManualMerchantTransactionScreenState();
}
class _ManualMerchantTransactionScreenState extends State<_ManualMerchantTransactionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  DateTime _date = DateTime.now();
  String _currency = 'LYD';
  String _direction = 'paid_to_trader';
  bool _saving = false;
  String? _error;
  @override void dispose() { _amount.dispose(); _note.dispose(); super.dispose(); }
  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    try {
      final minor = toMinorUnits(_amount.text.trim(), _currency);
      final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
      final key = base64Url.encode(utf8.encode('manual|' + widget.merchant['id'].toString() + '|' + stamp.toString() + '|' + Random.secure().nextInt(1 << 32).toString()));
      final ok = await LocalDatabase.instance.addMerchantTransaction(merchantId: widget.merchant['id'] as int, sourceKey: key, transactionDate: DateTime(_date.year, _date.month, _date.day).toIso8601String().substring(0, 10), sender: 'إضافة يدوية', originalMessage: _note.text.trim().isEmpty ? 'حوالة أضيفت يدويًا' : _note.text.trim(), amountMinor: minor, currency: _currency, direction: _direction, importBatch: 'manual-' + stamp.toString());
      if (!ok) throw StateError('العملية موجودة مسبقًا ولم تُكرر.');
      if (mounted) Navigator.pop(context, true);
    } catch (e) { if (mounted) setState(() { _saving = false; _error = 'لم يتم حفظ الحوالة: $e'; }); }
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('إضافة حوالة يدويًا')),
    body: Form(key: _formKey, child: ListView(padding: const EdgeInsets.all(16), children: [
      Text('التاجر: ' + (widget.merchant['name'] as String), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      TextFormField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'المبلغ *'), validator: (v) { try { if (toMinorUnits((v ?? '').trim(), _currency) <= 0) return 'أدخل مبلغًا أكبر من صفر'; } catch (_) { return 'صيغة المبلغ غير صحيحة'; } return null; }),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(value: _currency, decoration: const InputDecoration(labelText: 'العملة'), items: const [DropdownMenuItem(value: 'LYD', child: Text('دينار ليبي (LYD)')), DropdownMenuItem(value: 'USD', child: Text('دولار أمريكي (USD)')), DropdownMenuItem(value: 'EUR', child: Text('يورو (EUR)'))], onChanged: _saving ? null : (v) => setState(() => _currency = v ?? 'LYD')),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(value: _direction, decoration: const InputDecoration(labelText: 'اتجاه الحوالة'), items: const [DropdownMenuItem(value: 'paid_to_trader', child: Text('أرسلت للتاجر')), DropdownMenuItem(value: 'received_from_trader', child: Text('استلمت من التاجر'))], onChanged: _saving ? null : (v) => setState(() => _direction = v ?? 'paid_to_trader')),
      const SizedBox(height: 12),
      OutlinedButton.icon(onPressed: _saving ? null : () async { final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2000), lastDate: DateTime(2100)); if (d != null && mounted) setState(() => _date = d); }, icon: const Icon(Icons.calendar_month), label: Text('تاريخ الحوالة: ' + _date.toIso8601String().substring(0, 10))),
      const SizedBox(height: 12),
      TextFormField(controller: _note, maxLines: 3, decoration: const InputDecoration(labelText: 'البيان / رقم الحوالة / ملاحظات (اختياري)')),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
      const SizedBox(height: 20),
      FilledButton.icon(onPressed: _saving ? null : _save, icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined), label: Text(_saving ? 'جارٍ الحفظ...' : 'حفظ الحوالة في كشف الحساب')),
      const SizedBox(height: 8),
      const Text('تُحفظ العملية محليًا وتُحدّث إجماليات العملة نفسها فقط؛ لا يتم خلط العملات أو تحويلها تلقائيًا.', style: TextStyle(color: Colors.black54, height: 1.5)),
    ])),
  );
}
