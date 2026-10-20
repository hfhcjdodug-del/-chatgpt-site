import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'kv_store.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _name = TextEditingController();
  String _err = '';
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final n = _name.text.trim();
    if (n.isEmpty) {
      setState(() => _err = 'اكتب اسمك');
      return;
    }
    setState(() {
      _busy = true;
      _err = '';
    });
    try {
      await KvStore.instance.set('aiName', n);
      await Supabase.instance.client.auth.signInAnonymously();
    } catch (e) {
      final msg = e.toString();
      if (mounted) {
        setState(() {
          _err = msg.toLowerCase().contains('anonymous')
              ? 'الدخول المجهول غير مفعّل في Supabase'
              : msg.toLowerCase().contains('socket') || msg.toLowerCase().contains('network')
                  ? 'لا يوجد اتصال بالإنترنت'
                  : 'تعذر الدخول: $msg';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = dark ? const Color(0xFFF4F4F4) : Colors.black;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: fg, width: 5),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text('تسجيل الدخول',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: fg)),
                  const SizedBox(height: 8),
                  Text('سجّل دخولك للبدء بالمحادثة',
                      style: TextStyle(fontSize: 15, color: fg.withAlpha(150))),
                  const SizedBox(height: 26),
                  TextField(
                    controller: _name,
                    maxLength: 40,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _login(),
                    decoration: InputDecoration(
                      hintText: 'اكتب اسمك',
                      counterText: '',
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: _busy ? null : _login,
                      style: FilledButton.styleFrom(
                        backgroundColor: dark ? Colors.white : Colors.black,
                        foregroundColor: dark ? Colors.black : Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('تسجيل الدخول أو التسجيل',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  if (_err.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(_err,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xFFD70015), fontSize: 14)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
