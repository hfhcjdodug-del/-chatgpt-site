import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'config.dart';

typedef Rows = List<Map<String, dynamic>>;

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final SupabaseClient sb = Supabase.instance.client;
  late final String uid;
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final Random _rand = Random();

  String? _convId;
  bool _convIsNew = true;
  Stream<Rows>? _msgStream;
  late final Stream<Rows> _convStream;
  Rows _msgs = [];
  int _waiting = 0;
  Timer? _beat;
  String _welcome = 'أنا جاهز متى شئت.';
  String _name = 'مستخدم';

  static const List<String> _fallbacks = [
    'تمام 👍',
    'فهمتك، كمّل 🌷',
    'فكرة حلوة، شنو رايك أكثر؟',
    'أوكي، خبرني أكثر عن هذا الموضوع',
    'ممم، مثير للاهتمام 🤔',
  ];

  @override
  void initState() {
    super.initState();
    uid = sb.auth.currentUser!.id;
    _convStream = sb
        .from('conversations')
        .stream(primaryKey: ['id'])
        .eq('user_id', uid)
        .order('last_at', ascending: false);
    _convId = const Uuid().v4();
    _convIsNew = true;
    _msgStream = _watch(_convId!);
    _init();
  }

  @override
  void dispose() {
    _beat?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---------------- التهيئة ----------------
  Future<void> _init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('aiName');
      final meta = sb.auth.currentUser?.userMetadata;
      final metaName = meta == null ? null : (meta['full_name'] ?? meta['name']);
      _name = (metaName is String && metaName.isNotEmpty)
          ? metaName
          : (saved != null && saved.isNotEmpty ? saved : 'مستخدم');
      if (mounted) setState(() {});
      final now = DateTime.now().millisecondsSinceEpoch;
      final ex = await sb.from('profiles').select('id').eq('id', uid).maybeSingle();
      if (ex == null) {
        await sb.from('profiles').insert({
          'id': uid,
          'name': _name,
          'email': sb.auth.currentUser?.email ?? '',
          'photo': '',
          'created_at': now,
          'last_at': now,
          'last_seen': now,
          'unread': 0,
          'last_message': '',
        });
      } else {
        await sb.from('profiles').update({
          'name': _name,
          'last_seen': now,
          'in_call': false,
          'voice_active': false,
        }).eq('id', uid);
      }
      _beat = Timer.periodic(const Duration(seconds: 30), (_) {
        sb
            .from('profiles')
            .update({'last_seen': DateTime.now().millisecondsSinceEpoch})
            .eq('id', uid)
            .then((_) {}, onError: (_) {});
      });
    } catch (_) {}
    try {
      final w = await sb.from('settings').select('data').eq('id', 'welcome').maybeSingle();
      final d = w?['data'];
      if (d is Map && d['title'] is String && (d['title'] as String).trim().isNotEmpty) {
        if (mounted) setState(() => _welcome = (d['title'] as String).trim());
      }
    } catch (_) {}
  }

  // ---------------- المحادثات ----------------
  Stream<Rows> _watch(String cid) => sb
      .from('messages')
      .stream(primaryKey: ['id'])
      .eq('conv_id', cid)
      .order('at', ascending: true);

  void _startNew() {
    final id = const Uuid().v4();
    setState(() {
      _convId = id;
      _convIsNew = true;
      _msgs = [];
      _msgStream = _watch(id);
    });
  }

  void _open(String id) {
    setState(() {
      _convId = id;
      _convIsNew = false;
      _msgs = [];
      _msgStream = _watch(id);
    });
  }

  // ---------------- الإرسال ----------------
  String _norm(String s) {
    var t = s.toLowerCase();
    t = t.replaceAll(RegExp(r'[ً-ٟ]'), '');
    t = t.replaceAll(RegExp(r'[أإآ]'), 'ا').replaceAll('ة', 'ه').replaceAll('ى', 'ي');
    return t;
  }

  Future<String?> _matchReply(String text) async {
    try {
      final rows = await sb.from('replies').select('keywords,answer');
      final t = _norm(text);
      String? best;
      var len = 0;
      for (final r in rows) {
        final kw = r['keywords'];
        final an = r['answer'];
        if (kw is! String || an is! String) continue;
        final keys = kw
            .split(RegExp(r'[,،\n]'))
            .map((x) => _norm(x.trim()))
            .where((x) => x.isNotEmpty);
        for (final k in keys) {
          if (t.contains(k) && k.length > len) {
            best = an;
            len = k.length;
          }
        }
      }
      if (best != null && best.contains('|||')) {
        final v = best.split('|||').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
        if (v.isNotEmpty) best = v[_rand.nextInt(v.length)];
      }
      return best;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _askAi(String text) async {
    try {
      final cfgRow = await sb.from('settings').select('data').eq('id', 'ai').maybeSingle();
      final raw = cfgRow?['data'];
      final cfg = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      if (cfg['on'] == false) return null;
      final cu = cfg['url'];
      final url = (cu is String && cu.startsWith('https://')) ? cu : defaultAiUrl;

      final msgs = <Map<String, String>>[];
      final recent = _msgs.length > 24 ? _msgs.sublist(_msgs.length - 24) : _msgs;
      for (final m in recent) {
        final role = m['sender'] == 'user' ? 'user' : 'model';
        final t = (m['text'] ?? '').toString();
        if (t.isEmpty) continue;
        if (msgs.isNotEmpty && msgs.last['role'] == role) {
          msgs.last['text'] = '${msgs.last['text']}\n$t';
        } else {
          msgs.add({'role': role, 'text': t});
        }
      }
      if (msgs.isNotEmpty && msgs.last['role'] == 'user') {
        if (!(msgs.last['text'] ?? '').endsWith(text)) {
          msgs.last['text'] = '${msgs.last['text']}\n$text';
        }
      } else {
        msgs.add({'role': 'user', 'text': text});
      }
      while (msgs.isNotEmpty && msgs.first['role'] != 'user') {
        msgs.removeAt(0);
      }

      final token = sb.auth.currentSession?.accessToken;
      final body = jsonEncode({
        'idToken': token,
        'messages': msgs,
        'system': (cfg['system'] ?? '').toString(),
        'temperature': cfg['temp'] is num ? cfg['temp'] : 0.8,
        'model': (cfg['model'] ?? '').toString(),
      });
      final r = await http
          .post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 25));
      final d = jsonDecode(utf8.decode(r.bodyBytes));
      if (r.statusCode == 200 && d is Map && d['text'] is String && (d['text'] as String).isNotEmpty) {
        return d['text'] as String;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _bumpProfile(String text, int now) async {
    try {
      final p = await sb.from('profiles').select('unread').eq('id', uid).maybeSingle();
      final u = (p?['unread'] is num) ? (p!['unread'] as num).toInt() : 0;
      await sb.from('profiles').update({
        'last_message': text,
        'last_at': now,
        'unread': u + 1,
      }).eq('id', uid);
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final cid = _convId;
    if (cid == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      if (_convIsNew) {
        _convIsNew = false;
        await sb.from('conversations').upsert({
          'id': cid,
          'user_id': uid,
          'title': text.length > 40 ? text.substring(0, 40) : text,
          'created_at': now,
          'last_at': now,
        });
      } else {
        await sb.from('conversations').update({'last_at': now}).eq('id', cid);
      }
      await sb.from('messages').insert({
        'user_id': uid,
        'conv_id': cid,
        'sender': 'user',
        'text': text,
      });
      _bumpProfile(text, now);

      if (mounted) setState(() => _waiting++);
      try {
        String? ans = await _matchReply(text);
        final Future<String?>? aiF = ans == null ? _askAi(text) : null;

        // إذا المشرف يرد بنفسه أو المستخدم داخل مكالمة فلا يرد البوت
        final p = await sb
            .from('profiles')
            .select('in_call,human_until')
            .eq('id', uid)
            .maybeSingle();
        final hu = (p?['human_until'] is num) ? (p!['human_until'] as num).toInt() : 0;
        final human = p != null &&
            (p['in_call'] == true || hu > DateTime.now().millisecondsSinceEpoch);
        if (human) return;

        if (aiF != null) {
          ans = await aiF;
        } else {
          await Future.delayed(const Duration(milliseconds: 150));
        }
        await sb.from('messages').insert({
          'user_id': uid,
          'conv_id': cid,
          'sender': 'bot',
          'text': ans ?? _fallbacks[_rand.nextInt(_fallbacks.length)],
        });
      } finally {
        if (mounted) setState(() => _waiting--);
      }
    } catch (e) {
      _toast('تعذر الإرسال: $e');
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 3)));
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('تسجيل الخروج؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('خروج')),
        ],
      ),
    );
    if (ok == true) {
      _beat?.cancel();
      await sb.auth.signOut();
    }
  }

  Future<void> _toggleTheme(bool dark) async {
    themeMode.value = dark ? ThemeMode.dark : ThemeMode.light;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('aiTheme', dark ? 'dark' : 'light');
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---------------- الواجهة ----------------
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = dark ? const Color(0xFFF4F4F4) : Colors.black;
    final bar = dark ? const Color(0xFF303030) : const Color(0xFFEFEFF0);

    return Scaffold(
      drawer: _drawer(dark, fg),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Text('ChatGPT',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 19, color: fg)),
        actions: [
          IconButton(
            tooltip: 'محادثة جديدة',
            icon: Icon(Icons.edit_outlined, color: fg),
            onPressed: _startNew,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: StreamBuilder<Rows>(
                stream: _msgStream,
                builder: (context, snap) {
                  final data = snap.data;
                  if (data != null) _msgs = data;
                  if (_msgs.isEmpty && _waiting == 0) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_welcome,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: fg)),
                      ),
                    );
                  }
                  _scrollDown();
                  final extra = _waiting > 0 ? 1 : 0;
                  return ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                    itemCount: _msgs.length + extra,
                    itemBuilder: (context, i) {
                      if (i >= _msgs.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Text('●●●',
                                style: TextStyle(color: fg.withAlpha(120), fontSize: 14)),
                          ),
                        );
                      }
                      return _bubble(_msgs[i], dark, fg);
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Container(
                decoration: BoxDecoration(color: bar, borderRadius: BorderRadius.circular(28)),
                padding: const EdgeInsetsDirectional.only(start: 18, end: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(
                          hintText: 'اسأل ChatGPT',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                        ),
                      ),
                    ),
                    IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: dark ? Colors.white : Colors.black,
                        foregroundColor: dark ? Colors.black : Colors.white,
                      ),
                      icon: const Icon(Icons.arrow_upward),
                      onPressed: _send,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(Map<String, dynamic> m, bool dark, Color fg) {
    final sender = (m['sender'] ?? '').toString();
    final text = (m['text'] ?? '').toString();
    final att = m['att'];
    final widgets = <Widget>[];

    if (att is Map && att['type'] == 'image' && att['data'] is String) {
      try {
        final s = att['data'] as String;
        final bytes = base64Decode(s.contains(',') ? s.split(',').last : s);
        widgets.add(ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.memory(bytes, width: 220, fit: BoxFit.cover),
        ));
        widgets.add(const SizedBox(height: 6));
      } catch (_) {}
    }

    if (sender == 'user') {
      if (text.isNotEmpty) widgets.add(SelectableText(text,
          style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w500,
              height: 1.4,
              color: dark ? const Color(0xFF8EC5FF) : const Color(0xFF1173D4))));
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF1B3A5F) : const Color(0xFFE8F3FF),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: widgets),
          ),
        ),
      );
    }

    if (sender == 'admin') {
      widgets.insert(
          0,
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('المشرف',
                style: TextStyle(fontSize: 12, color: fg.withAlpha(130), fontWeight: FontWeight.w600)),
          ));
    }
    if (text.isNotEmpty) widgets.add(SelectableText(text,
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500, height: 1.55, color: fg)));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: widgets),
    );
  }

  Widget _drawer(bool dark, Color fg) {
    return Drawer(
      backgroundColor: dark ? const Color(0xFF171717) : const Color(0xFFFAFAFA),
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(_name, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('محادثة جديدة'),
              onTap: () {
                Navigator.pop(context);
                _startNew();
              },
            ),
            const Divider(height: 1),
            Expanded(
              child: StreamBuilder<Rows>(
                stream: _convStream,
                builder: (context, snap) {
                  final list = snap.data ?? <Map<String, dynamic>>[];
                  if (list.isEmpty) {
                    return Center(
                      child: Text('لا توجد محادثات بعد',
                          style: TextStyle(color: fg.withAlpha(130))),
                    );
                  }
                  return ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final c = list[i];
                      final id = (c['id'] ?? '').toString();
                      final title = (c['title'] ?? 'محادثة جديدة').toString();
                      return ListTile(
                        selected: id == _convId,
                        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () {
                          Navigator.pop(context);
                          _open(id);
                        },
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(height: 1),
            SwitchListTile(
              secondary: const Icon(Icons.dark_mode_outlined),
              title: const Text('الوضع الداكن'),
              value: dark,
              onChanged: _toggleTheme,
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('تسجيل الخروج'),
              onTap: _logout,
            ),
          ],
        ),
      ),
    );
  }
}
