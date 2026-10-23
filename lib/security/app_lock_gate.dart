import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  static const _storage = FlutterSecureStorage();
  static const _saltKey = 'almasar_pin_salt_v1';
  static const _hashKey = 'almasar_pin_hash_v1';

  bool _loading = true;
  bool _configured = false;
  bool _locked = true;
  String? _salt;
  String? _hash;
  String? _error;
  final _pin = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    try {
      _salt = await _storage.read(key: _saltKey);
      _hash = await _storage.read(key: _hashKey);
      _configured = _salt != null && _hash != null;
    } catch (_) {
      _error = 'تعذر فتح التخزين الآمن. لا تمسح بيانات التطبيق؛ أعد المحاولة.';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (_configured && mounted) {
        setState(() {
          _locked = true;
          _pin.clear();
          _error = null;
        });
      }
    }
  }

  String _digest(String salt, String pin) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  Future<void> _submit() async {
    final value = _pin.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(value)) {
      setState(() => _error = 'أدخل رقمًا سريًا من 6 أرقام.');
      return;
    }
    if (!_configured) {
      if (_confirm.text.trim() != value) {
        setState(() => _error = 'الرقمان غير متطابقين.');
        return;
      }
      final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
      final salt = base64Url.encode(bytes);
      final hash = _digest(salt, value);
      try {
        await _storage.write(key: _saltKey, value: salt);
        await _storage.write(key: _hashKey, value: hash);
        if (!mounted) return;
        setState(() {
          _salt = salt;
          _hash = hash;
          _configured = true;
          _locked = false;
          _pin.clear();
          _confirm.clear();
          _error = null;
        });
      } catch (_) {
        setState(() => _error = 'تعذر حفظ الرقم السري في التخزين الآمن.');
      }
      return;
    }
    if (_salt != null && _hash != null && _digest(_salt!, value) == _hash) {
      setState(() {
        _locked = false;
        _pin.clear();
        _error = null;
      });
    } else {
      _pin.clear();
      setState(() => _error = 'الرقم السري غير صحيح.');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Material(child: Center(child: CircularProgressIndicator()));
    }
    return Stack(
      children: [
        Offstage(offstage: _locked || !_configured, child: widget.child),
        if (_locked || !_configured)
          Positioned.fill(
            child: Scaffold(
              body: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock_outline, size: 64),
                          const SizedBox(height: 16),
                          Text(
                            _configured ? 'فتح المسار للحوالات' : 'إنشاء رقم سري للتطبيق',
                            style: Theme.of(context).textTheme.headlineSmall,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'يُقفل التطبيق عند مغادرته. احفظ الرقم السري في مكان آمن؛ لا يمكن استعادته من داخل التطبيق.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 20),
                          TextField(
                            controller: _pin,
                            autofocus: true,
                            obscureText: true,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                            decoration: const InputDecoration(labelText: 'الرقم السري (6 أرقام)'),
                            onSubmitted: (_) => _configured ? _submit() : null,
                          ),
                          if (!_configured) ...[
                            const SizedBox(height: 12),
                            TextField(
                              controller: _confirm,
                              obscureText: true,
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                              decoration: const InputDecoration(labelText: 'تأكيد الرقم السري'),
                              onSubmitted: (_) => _submit(),
                            ),
                          ],
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                          ],
                          const SizedBox(height: 18),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: _submit,
                              child: Text(_configured ? 'فتح التطبيق' : 'حفظ الرقم السري'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
