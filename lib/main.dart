import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core/money.dart';
import 'data/local_database.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AlmasarApp());
}

class AlmasarApp extends StatelessWidget {
  const AlmasarApp({super.key});

  @override
  Widget build(BuildContext context) {
    const navy = Color(0xFF142B4A);
    return MaterialApp(
      title: 'المسار للحوالات',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: navy),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        appBarTheme: const AppBarTheme(
          backgroundColor: navy,
          foregroundColor: Colors.white,
          centerTitle: false,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
          fillColor: Colors.white,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  int _refreshKey = 0;

  void _refresh() {
    if (mounted) setState(() => _refreshKey++);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardScreen(key: ValueKey('dashboard-$_refreshKey')),
      CustomersScreen(key: ValueKey('customers-$_refreshKey'), onChanged: _refresh),
      TransfersScreen(key: ValueKey('transfers-$_refreshKey'), onChanged: _refresh),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('المسار للحوالات', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: 'تحديث البيانات',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (value) => setState(() => _tab = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.space_dashboard_outlined), selectedIcon: Icon(Icons.space_dashboard), label: 'الرئيسية'),
          NavigationDestination(icon: Icon(Icons.people_alt_outlined), selectedIcon: Icon(Icons.people_alt), label: 'العملاء'),
          NavigationDestination(icon: Icon(Icons.swap_horiz), selectedIcon: Icon(Icons.swap_horiz), label: 'الحوالات'),
        ],
      ),
    );
  }
}

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: Future.wait([
        LocalDatabase.instance.getSummary(),
        LocalDatabase.instance.getTransfers(limit: 8),
      ]),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return ErrorPanel(message: 'تعذر فتح قاعدة البيانات المحلية: ${snapshot.error}');
        }
        final summary = snapshot.data![0] as Map<String, int>;
        final transfers = snapshot.data![1] as List<Map<String, Object?>>;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF142B4A), Color(0xFF294D75)],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.account_balance_wallet_outlined, color: Colors.white, size: 34),
                  SizedBox(height: 14),
                  Text('إدارة الحوالات والعملاء', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                  SizedBox(height: 6),
                  Text('تُحفظ البيانات على هذا الجهاز داخل قاعدة بيانات محلية.', style: TextStyle(color: Colors.white70, height: 1.5)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: StatCard(title: 'العملاء', value: '${summary['customers']}', icon: Icons.people_alt_outlined)),
                const SizedBox(width: 12),
                Expanded(child: StatCard(title: 'العمليات', value: '${summary['transfers']}', icon: Icons.receipt_long_outlined)),
              ],
            ),
            const SizedBox(height: 24),
            const Text('أحدث العمليات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (transfers.isEmpty)
              const EmptyPanel(message: 'لا توجد عمليات بعد. أضف عميلًا ثم سجّل أول عملية.')
            else
              ...transfers.map((item) => TransferTile(item: item)),
            const SizedBox(height: 12),
            const Text('تنبيه: هذه النسخة تحفظ البيانات على هذا الجهاز فقط. لم تتم إضافة المزامنة بين الأجهزة أو النسخ الاحتياطي بعد.', style: TextStyle(color: Colors.black54, height: 1.5)),
          ],
        );
      },
    );
  }
}

class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.title, required this.value, required this.icon});
  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            Text(title, style: const TextStyle(color: Colors.black54)),
          ],
        ),
      ),
    );
  }
}

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key, required this.onChanged});
  final VoidCallback onChanged;

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  String _search = '';

  Future<void> _addCustomer() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => const AddCustomerDialog(),
    );
    if (result == true && mounted) {
      setState(() {});
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCustomer,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('إضافة عميل'),
      ),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: LocalDatabase.instance.getCustomers(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return ErrorPanel(message: 'تعذر تحميل العملاء: ${snapshot.error}');
          final customers = snapshot.data!.where((customer) {
            final name = (customer['name'] as String).toLowerCase();
            final phone = (customer['phone'] as String).toLowerCase();
            final query = _search.toLowerCase();
            return name.contains(query) || phone.contains(query);
          }).toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            children: [
              TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'ابحث بالاسم أو رقم الهاتف'),
                onChanged: (value) => setState(() => _search = value.trim()),
              ),
              const SizedBox(height: 12),
              if (customers.isEmpty)
                const EmptyPanel(message: 'لا يوجد عملاء مطابقون. يمكنك إضافة عميل جديد.')
              else
                ...customers.map((customer) => Card(
                  elevation: 0,
                  child: ListTile(
                    leading: CircleAvatar(child: Text((customer['name'] as String).isNotEmpty ? (customer['name'] as String).characters.first : '؟')),
                    title: Text(customer['name'] as String, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text((customer['phone'] as String).isEmpty ? 'لا يوجد رقم هاتف' : customer['phone'] as String),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(formatMinor(customer['balance_minor'] as int, customer['currency'] as String), style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text(customer['currency'] as String, style: const TextStyle(fontSize: 11, color: Colors.black54)),
                      ],
                    ),
                  ),
                )),
            ],
          );
        },
      ),
    );
  }
}

class AddCustomerDialog extends StatefulWidget {
  const AddCustomerDialog({super.key});

  @override
  State<AddCustomerDialog> createState() => _AddCustomerDialogState();
}

class _AddCustomerDialogState extends State<AddCustomerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  String _currency = 'LYD';
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await LocalDatabase.instance.addCustomer(name: _name.text, phone: _phone.text, currency: _currency);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('لم يتم حفظ العميل: $error')));
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إضافة عميل جديد'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'اسم العميل'), validator: (value) => value == null || value.trim().isEmpty ? 'اكتب اسم العميل' : null),
              const SizedBox(height: 12),
              TextFormField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم واتساب الدولي', hintText: 'مثال: 2189xxxxxxx')),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _currency,
                decoration: const InputDecoration(labelText: 'عملة الحساب'),
                items: const [
                  DropdownMenuItem(value: 'LYD', child: Text('دينار ليبي (LYD)')),
                  DropdownMenuItem(value: 'USD', child: Text('دولار أمريكي (USD)')),
                  DropdownMenuItem(value: 'EUR', child: Text('يورو (EUR)')),
                ],
                onChanged: (value) => setState(() => _currency = value ?? 'LYD'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('إلغاء')),
        FilledButton(onPressed: _saving ? null : _save, child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('حفظ العميل')),
      ],
    );
  }
}

class TransfersScreen extends StatefulWidget {
  const TransfersScreen({super.key, required this.onChanged});
  final VoidCallback onChanged;

  @override
  State<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends State<TransfersScreen> {
  Future<void> _addTransfer() async {
    final result = await showDialog<bool>(context: context, builder: (context) => const AddTransferDialog());
    if (result == true && mounted) widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addTransfer,
        icon: const Icon(Icons.add_card),
        label: const Text('تسجيل عملية'),
      ),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: LocalDatabase.instance.getTransfers(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return ErrorPanel(message: 'تعذر تحميل العمليات: ${snapshot.error}');
          final transfers = snapshot.data!;
          if (transfers.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: EmptyPanel(message: 'لا توجد حوالات أو عمليات مسجلة حتى الآن.'));
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            itemCount: transfers.length,
            itemBuilder: (context, index) => TransferTile(item: transfers[index], onChanged: widget.onChanged),
          );
        },
      ),
    );
  }
}

class AddTransferDialog extends StatefulWidget {
  const AddTransferDialog({super.key});

  @override
  State<AddTransferDialog> createState() => _AddTransferDialogState();
}

class _AddTransferDialogState extends State<AddTransferDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  List<Map<String, Object?>> _customers = [];
  int? _customerId;
  String _kind = 'deposit';
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCustomers();
  }

  Future<void> _loadCustomers() async {
    try {
      final customers = await LocalDatabase.instance.getCustomers();
      if (!mounted) return;
      setState(() {
        _customers = customers;
        _customerId = customers.isNotEmpty ? customers.first['id'] as int : null;
        _loading = false;
      });
    } catch (error) {
      if (mounted) setState(() { _loading = false; _error = error.toString(); });
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _customerId == null) return;
    final customer = _customers.firstWhere((item) => item['id'] == _customerId);
    int minor;
    try {
      minor = toMinorUnits(_amount.text, customer['currency'] as String);
    } catch (error) {
      setState(() => _error = error.toString());
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final reference = await LocalDatabase.instance.addTransfer(
        customerId: _customerId!,
        kind: _kind,
        amountMinor: minor,
        note: _note.text,
      );
      if (mounted) Navigator.pop(context, true);
      // The reference is stored with the operation and can be found in the history.
      debugPrint('Saved local transfer $reference');
    } catch (error) {
      if (mounted) setState(() { _saving = false; _error = error.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('تسجيل عملية مالية'),
      content: SizedBox(
        width: 420,
        child: _loading
            ? const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            : _customers.isEmpty
                ? const Text('أضف عميلًا أولًا حتى تتمكن من تسجيل عملية.')
                : Form(
                    key: _formKey,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DropdownButtonFormField<int>(
                            value: _customerId,
                            decoration: const InputDecoration(labelText: 'العميل'),
                            items: _customers.map((customer) => DropdownMenuItem<int>(
                              value: customer['id'] as int,
                              child: Text('${customer['name']} — ${customer['currency']}'),
                            )).toList(),
                            onChanged: (value) => setState(() => _customerId = value),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            value: _kind,
                            decoration: const InputDecoration(labelText: 'نوع العملية'),
                            items: const [
                              DropdownMenuItem(value: 'deposit', child: Text('إيداع / استلام')),
                              DropdownMenuItem(value: 'withdrawal', child: Text('صرف / إرسال')),
                            ],
                            onChanged: (value) => setState(() => _kind = value ?? 'deposit'),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'المبلغ', hintText: '0.000'), validator: (value) => value == null || value.trim().isEmpty ? 'اكتب المبلغ' : null),
                          const SizedBox(height: 12),
                          TextFormField(controller: _note, decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)')),
                          if (_error != null) ...[
                            const SizedBox(height: 10),
                            Text(_error!, style: const TextStyle(color: Colors.red)),
                          ],
                        ],
                      ),
                    ),
                  ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('إلغاء')),
        if (!_loading && _customers.isNotEmpty)
          FilledButton(onPressed: _saving ? null : _save, child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('حفظ العملية')),
      ],
    );
  }
}

class TransferTile extends StatelessWidget {
  const TransferTile({super.key, required this.item, this.onChanged});
  final Map<String, Object?> item;
  final VoidCallback? onChanged;

  Future<void> _openWhatsApp(BuildContext context) async {
    final phone = (item['phone'] as String? ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('لا يوجد رقم هاتف محفوظ لهذا العميل.')));
      return;
    }
    final isDeposit = item['kind'] == 'deposit';
    final message = 'المسار للحوالات\n'
        'إشعار بعملية مالية مسجلة\n'
        'العميل: ${item['customer_name']}\n'
        'العملية: ${isDeposit ? 'إيداع / استلام' : 'صرف / إرسال'}\n'
        'المبلغ: ${formatMinor(item['amount_minor'] as int, item['currency'] as String)} ${item['currency']}\n'
        'رقم المرجع: ${item['reference']}\n'
        'التاريخ: ${item['created_at']}\n'
        '${(item['note'] as String).isEmpty ? '' : 'ملاحظة: ${item['note']}\n'}';
    final uri = Uri.https('wa.me', '/$phone', {'text': message});
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر فتح واتساب على هذا الجهاز.')));
      }
    } catch (error) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر فتح واتساب: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDeposit = item['kind'] == 'deposit';
    final date = DateTime.tryParse(item['created_at'] as String);
    final dateText = date == null ? '' : date.toLocal().toString().substring(0, 16);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: isDeposit ? Colors.green.shade50 : Colors.orange.shade50,
            child: Icon(isDeposit ? Icons.south_west : Icons.north_east, color: isDeposit ? Colors.green.shade800 : Colors.orange.shade800),
          ),
          title: Text(item['customer_name'] as String, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('${item['reference']}\n$dateText${(item['note'] as String).isEmpty ? '' : '\n${item['note']}'}'),
          isThreeLine: (item['note'] as String).isNotEmpty,
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${isDeposit ? '+' : '−'}${formatMinor(item['amount_minor'] as int, item['currency'] as String)}', style: TextStyle(fontWeight: FontWeight.bold, color: isDeposit ? Colors.green.shade800 : Colors.deepOrange.shade800)),
              Text(item['currency'] as String, style: const TextStyle(fontSize: 11, color: Colors.black54)),
              if (onChanged != null)
                InkWell(onTap: () => _openWhatsApp(context), child: const Padding(padding: EdgeInsets.only(top: 4), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.chat, size: 15, color: Color(0xFF168A52)), SizedBox(width: 3), Text('واتساب', style: TextStyle(fontSize: 11, color: Color(0xFF168A52)))]))),
            ],
          ),
        ),
      ),
    );
  }
}

String formatMinor(int minor, String currency) {
  try {
    return fromMinorUnits(minor, currency);
  } catch (_) {
    return minor.toString();
  }
}

class EmptyPanel extends StatelessWidget {
  const EmptyPanel({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Icon(Icons.inbox_outlined, size: 36, color: Colors.black38),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54, height: 1.5)),
          ],
        ),
      ),
    );
  }
}

class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red))));
  }
}
