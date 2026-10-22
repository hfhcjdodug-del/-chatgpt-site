import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'theme.dart';
import 'video_call.dart';

const String adminEmail = 'jadocool0427@gmail.com';

bool isAdminUser(User? u) => (u?.email ?? '').toLowerCase() == adminEmail;

final SupabaseClient _sb = Supabase.instance.client;

/// لوحة الإدارة داخل التطبيق: تظهر فقط لحساب المدير (Gmail)
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: pal.bg,
        appBar: AppBar(
          backgroundColor: pal.bg,
          foregroundColor: pal.fg,
          title: const Text('لوحة الإدارة'),
          bottom: TabBar(
            isScrollable: true,
            labelColor: pal.fg,
            unselectedLabelColor: pal.mut,
            indicatorColor: Pal.blue,
            tabs: const [
              Tab(text: 'المستخدمون'),
              Tab(text: 'الردود'),
              Tab(text: 'العقل'),
              Tab(text: 'الاقتراحات'),
            ],
          ),
        ),
        body: const TabBarView(children: [
          _UsersTab(),
          _RepliesTab(),
          _BrainTab(),
          _SuggestTab(),
        ]),
      ),
    );
  }
}

void _snack(BuildContext c, String m) {
  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));
}

Future<bool> _confirm(BuildContext c, String msg) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(msg),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('إلغاء')),
        TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('تأكيد')),
      ],
    ),
  );
  return r == true;
}

// ================= المستخدمون =================
class _UsersTab extends StatelessWidget {
  const _UsersTab();

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _sb.from('profiles').stream(primaryKey: ['id']).order('last_at', ascending: false),
      builder: (c, snap) {
        if (snap.hasError) return Center(child: Text('خطأ: ${snap.error}', style: TextStyle(color: pal.mut)));
        final rows = snap.data;
        if (rows == null) return const Center(child: CircularProgressIndicator());
        if (rows.isEmpty) return Center(child: Text('لا يوجد مستخدمون بعد', style: TextStyle(color: pal.mut)));
        final now = DateTime.now().millisecondsSinceEpoch;
        return ListView.separated(
          itemCount: rows.length,
          separatorBuilder: (_, __) => Divider(height: 1, color: pal.line),
          itemBuilder: (c, i) {
            final u = rows[i];
            final name = ((u['name'] ?? '') as String).isEmpty ? 'بدون اسم' : u['name'].toString();
            final seen = (u['last_seen'] is num) ? (u['last_seen'] as num).toInt() : 0;
            final online = now - seen < 70000;
            final unread = (u['unread'] is num) ? (u['unread'] as num).toInt() : 0;
            return ListTile(
              leading: Stack(children: [
                CircleAvatar(
                  backgroundColor: pal.bar,
                  child: Text(name.characters.first.toUpperCase(), style: TextStyle(color: pal.fg)),
                ),
                if (online)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Pal.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: pal.bg, width: 2),
                      ),
                    ),
                  ),
              ]),
              title: Text(name, style: TextStyle(color: pal.fg, fontWeight: FontWeight.w600)),
              subtitle: Text(
                (u['last_message'] ?? '').toString().isEmpty
                    ? (u['email'] ?? '').toString()
                    : u['last_message'].toString(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: pal.mut),
              ),
              trailing: unread > 0
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                      decoration: BoxDecoration(color: Pal.blue, borderRadius: BorderRadius.circular(12)),
                      child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 13)),
                    )
                  : null,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => _AdminChat(uid: u['id'].toString(), name: name)),
              ),
            );
          },
        );
      },
    );
  }
}

class _AdminChat extends StatefulWidget {
  const _AdminChat({required this.uid, required this.name});
  final String uid;
  final String name;

  @override
  State<_AdminChat> createState() => _AdminChatState();
}

class _AdminChatState extends State<_AdminChat> {
  final TextEditingController _t = TextEditingController();
  final ScrollController _sc = ScrollController();
  String? _lastConv;

  @override
  void initState() {
    super.initState();
    _sb.from('profiles').update({'unread': 0}).eq('id', widget.uid).then((_) {}, onError: (_) {});
  }

  @override
  void dispose() {
    _t.dispose();
    _sc.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _t.text.trim();
    if (text.isEmpty) return;
    final cid = _lastConv;
    if (cid == null) {
      _snack(context, 'لا توجد محادثة لهذا المستخدم بعد');
      return;
    }
    _t.clear();
    try {
      await _sb.from('messages').insert({
        'user_id': widget.uid,
        'conv_id': cid,
        'sender': 'admin',
        'text': text,
      });
      // يمنع البوت من الرد لمدة 5 دقائق
      await _sb.from('profiles').update({
        'human_until': DateTime.now().millisecondsSinceEpoch + 300000,
        'unread': 0,
      }).eq('id', widget.uid);
    } catch (e) {
      if (mounted) _snack(context, 'تعذر الإرسال: $e');
    }
  }

  Future<void> _deleteUser() async {
    if (!await _confirm(context, 'حذف هذا المستخدم وكل محادثاته؟')) return;
    try {
      await _sb.from('profiles').delete().eq('id', widget.uid);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _snack(context, 'تعذر الحذف: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(
        backgroundColor: pal.bg,
        foregroundColor: pal.fg,
        title: Text(widget.name),
        actions: [
          IconButton(
            tooltip: 'طلب فتح الكاميرا (بموافقة المستخدم)',
            icon: const Icon(Icons.videocam_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => AdminCameraScreen(uid: widget.uid, name: widget.name)),
            ),
          ),
          IconButton(onPressed: _deleteUser, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _sb
                .from('messages')
                .stream(primaryKey: ['id'])
                .eq('user_id', widget.uid)
                .order('at', ascending: true),
            builder: (c, snap) {
              final rows = snap.data ?? [];
              if (rows.isNotEmpty) _lastConv = rows.last['conv_id']?.toString();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_sc.hasClients) _sc.jumpTo(_sc.position.maxScrollExtent);
              });
              return ListView.builder(
                controller: _sc,
                padding: const EdgeInsets.all(14),
                itemCount: rows.length,
                itemBuilder: (c, i) {
                  final m = rows[i];
                  final s = m['sender'];
                  final user = s == 'user';
                  final admin = s == 'admin';
                  return Align(
                    alignment: user ? Alignment.centerLeft : Alignment.centerRight,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                      decoration: BoxDecoration(
                        color: user ? pal.bub : (admin ? Pal.blue : pal.bar),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: SelectableText(
                        (m['text'] ?? '').toString(),
                        style: TextStyle(color: user || admin ? Colors.white : pal.fg, fontSize: 16),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _t,
                  style: TextStyle(color: pal.fg),
                  decoration: InputDecoration(
                    hintText: 'اكتب ردّاً باسم المشرف',
                    hintStyle: TextStyle(color: pal.mut),
                    filled: true,
                    fillColor: pal.bar,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _send,
                style: IconButton.styleFrom(backgroundColor: Pal.blue),
                icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ================= الردود =================
class _RepliesTab extends StatefulWidget {
  const _RepliesTab();

  @override
  State<_RepliesTab> createState() => _RepliesTabState();
}

class _RepliesTabState extends State<_RepliesTab> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _sb.from('replies').select().order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          _rows = List<Map<String, dynamic>>.from(r);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack(context, 'تعذر التحميل: $e');
      }
    }
  }

  Future<void> _edit([Map<String, dynamic>? row]) async {
    final kw = TextEditingController(text: row?['keywords']?.toString() ?? '');
    final an = TextEditingController(text: row?['answer']?.toString() ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(row == null ? 'ردّ جديد' : 'تعديل الردّ'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: kw,
              decoration: const InputDecoration(labelText: 'الكلمات المفتاحية (افصل بفاصلة)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: an,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'الردّ',
                helperText: 'للتنويع افصل الردود بـ |||',
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('إلغاء')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('حفظ')),
        ],
      ),
    );
    if (ok != true) return;
    final k = kw.text.trim(), a = an.text.trim();
    if (k.isEmpty || a.isEmpty) return;
    try {
      if (row == null) {
        await _sb.from('replies').insert({'keywords': k, 'answer': a});
      } else {
        await _sb.from('replies').update({'keywords': k, 'answer': a}).eq('id', row['id']);
      }
      _load();
    } catch (e) {
      if (mounted) _snack(context, 'تعذر الحفظ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Scaffold(
      backgroundColor: pal.bg,
      floatingActionButton: FloatingActionButton(
        backgroundColor: Pal.blue,
        onPressed: () => _edit(),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rows.isEmpty
              ? Center(child: Text('لا توجد ردود جاهزة بعد', style: TextStyle(color: pal.mut)))
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 90),
                  itemCount: _rows.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: pal.line),
                  itemBuilder: (c, i) {
                    final r = _rows[i];
                    return ListTile(
                      title: Text(r['keywords'].toString(), style: TextStyle(color: pal.fg, fontWeight: FontWeight.w600)),
                      subtitle: Text(r['answer'].toString(),
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.mut)),
                      onTap: () => _edit(r),
                      trailing: IconButton(
                        icon: Icon(Icons.delete_outline, color: pal.mut),
                        onPressed: () async {
                          if (!await _confirm(context, 'حذف هذا الردّ؟')) return;
                          await _sb.from('replies').delete().eq('id', r['id']);
                          _load();
                        },
                      ),
                    );
                  },
                ),
    );
  }
}

// ================= العقل =================
class _BrainTab extends StatefulWidget {
  const _BrainTab();

  @override
  State<_BrainTab> createState() => _BrainTabState();
}

class _BrainTabState extends State<_BrainTab> {
  final _url = TextEditingController();
  final _model = TextEditingController();
  final _temp = TextEditingController();
  final _system = TextEditingController();
  bool _on = true;
  bool _loading = true;
  Map<String, dynamic> _extra = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _sb.from('settings').select('data').eq('id', 'ai').maybeSingle();
      final d = r?['data'];
      if (d is Map) {
        _extra = Map<String, dynamic>.from(d);
        _on = d['on'] != false;
        _url.text = (d['url'] ?? '').toString();
        _model.text = (d['model'] ?? '').toString();
        _temp.text = (d['temp'] ?? '').toString();
        _system.text = (d['system'] ?? '').toString();
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final data = Map<String, dynamic>.from(_extra)
      ..['on'] = _on
      ..['url'] = _url.text.trim()
      ..['model'] = _model.text.trim()
      ..['system'] = _system.text;
    final t = double.tryParse(_temp.text.trim());
    if (t != null) data['temp'] = t;
    try {
      await _sb.from('settings').upsert({'id': 'ai', 'data': data});
      if (mounted) _snack(context, 'تم الحفظ');
    } catch (e) {
      if (mounted) _snack(context, 'تعذر الحفظ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return ListView(padding: const EdgeInsets.all(16), children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('تفعيل العقل الذكي'),
        value: _on,
        onChanged: (v) => setState(() => _on = v),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _url,
        textDirection: TextDirection.ltr,
        decoration: const InputDecoration(labelText: 'رابط الوسيط (Worker)', helperText: 'اتركه فارغاً لاستخدام الافتراضي'),
      ),
      const SizedBox(height: 12),
      TextField(controller: _model, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'النموذج')),
      const SizedBox(height: 12),
      TextField(
        controller: _temp,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'الحرارة (0 إلى 1)'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _system,
        minLines: 4,
        maxLines: 12,
        decoration: const InputDecoration(labelText: 'تعليمات النظام (شخصية الذكاء)'),
      ),
      const SizedBox(height: 18),
      FilledButton(
        onPressed: _save,
        style: FilledButton.styleFrom(backgroundColor: Pal.blue, minimumSize: const Size.fromHeight(50)),
        child: const Text('حفظ'),
      ),
    ]);
  }
}

// ================= الاقتراحات + الترحيب =================
class _SuggestTab extends StatefulWidget {
  const _SuggestTab();

  @override
  State<_SuggestTab> createState() => _SuggestTabState();
}

class _SuggestTabState extends State<_SuggestTab> {
  List<Map<String, dynamic>> _rows = [];
  final _title = TextEditingController();
  Map<String, dynamic> _welcome = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _sb.from('settings').select('id,data').like('id', 'sg_%');
      final rows = List<Map<String, dynamic>>.from(r);
      rows.sort((a, b) {
        num o(Map<String, dynamic> x) => (x['data'] is Map && x['data']['order'] is num) ? x['data']['order'] : 0;
        return o(a).compareTo(o(b));
      });
      final w = await _sb.from('settings').select('data').eq('id', 'welcome').maybeSingle();
      if (w?['data'] is Map) {
        _welcome = Map<String, dynamic>.from(w!['data']);
        _title.text = (_welcome['title'] ?? '').toString();
      }
      if (mounted) {
        setState(() {
          _rows = rows;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack(context, 'تعذر التحميل: $e');
      }
    }
  }

  Future<void> _saveTitle() async {
    try {
      await _sb.from('settings').upsert({'id': 'welcome', 'data': {..._welcome, 'title': _title.text.trim()}});
      if (mounted) _snack(context, 'تم حفظ عنوان الترحيب');
    } catch (e) {
      if (mounted) _snack(context, 'تعذر الحفظ: $e');
    }
  }

  Future<void> _edit([Map<String, dynamic>? row]) async {
    final d = (row?['data'] is Map) ? Map<String, dynamic>.from(row!['data']) : <String, dynamic>{};
    final emoji = TextEditingController(text: (d['emoji'] ?? '').toString());
    final text = TextEditingController(text: (d['text'] ?? '').toString());
    final ans = TextEditingController(text: (d['answer'] ?? '').toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(row == null ? 'اقتراح جديد' : 'تعديل الاقتراح'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: emoji, decoration: const InputDecoration(labelText: 'الرمز (إيموجي)')),
            const SizedBox(height: 10),
            TextField(controller: text, decoration: const InputDecoration(labelText: 'نص الزر')),
            const SizedBox(height: 10),
            TextField(
              controller: ans,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(labelText: 'الردّ', helperText: 'للتنويع افصل الردود بـ |||'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('حفظ')),
        ],
      ),
    );
    if (ok != true || text.text.trim().isEmpty) return;
    final id = row?['id']?.toString() ?? 'sg_${DateTime.now().millisecondsSinceEpoch}';
    final data = {
      ...d,
      'emoji': emoji.text.trim(),
      'text': text.text.trim(),
      'answer': ans.text.trim(),
      'on': d['on'] ?? true,
      'order': d['order'] ?? _rows.length,
    };
    try {
      await _sb.from('settings').upsert({'id': id, 'data': data});
      _load();
    } catch (e) {
      if (mounted) _snack(context, 'تعذر الحفظ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Scaffold(
      backgroundColor: pal.bg,
      floatingActionButton: FloatingActionButton(
        backgroundColor: Pal.blue,
        onPressed: () => _edit(),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 90), children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'عنوان شاشة الترحيب'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saveTitle,
              style: FilledButton.styleFrom(backgroundColor: Pal.blue),
              child: const Text('حفظ'),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            _rows.isEmpty
                ? 'لا توجد اقتراحات. عند إضافة اقتراح تظهر أزرار الاقتراحات بدل بطاقة الدراجة في شاشة الترحيب.'
                : 'أزرار الاقتراحات في شاشة الترحيب',
            style: TextStyle(color: pal.mut, fontSize: 13),
          ),
        ),
        for (final r in _rows) ...[
          Builder(builder: (c) {
            final d = (r['data'] is Map) ? Map<String, dynamic>.from(r['data']) : <String, dynamic>{};
            return ListTile(
              leading: Text((d['emoji'] ?? '').toString(), style: const TextStyle(fontSize: 24)),
              title: Text((d['text'] ?? '').toString(), style: TextStyle(color: pal.fg)),
              subtitle: Text((d['answer'] ?? '').toString(),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.mut)),
              onTap: () => _edit(r),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Switch(
                  value: d['on'] != false,
                  onChanged: (v) async {
                    await _sb.from('settings').upsert({'id': r['id'], 'data': {...d, 'on': v}});
                    _load();
                  },
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, color: pal.mut),
                  onPressed: () async {
                    if (!await _confirm(context, 'حذف هذا الاقتراح؟')) return;
                    await _sb.from('settings').delete().eq('id', r['id']);
                    _load();
                  },
                ),
              ]),
            );
          }),
          Divider(height: 1, color: pal.line),
        ],
      ]),
    );
  }
}
