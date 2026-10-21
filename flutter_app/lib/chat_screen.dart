import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'config.dart';
import 'icons.dart';
import 'kv_store.dart';
import 'services.dart';
import 'theme.dart';
import 'voice_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final SupabaseClient sb = Supabase.instance.client;
  late final String uid;
  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  String? _convId;
  bool _convIsNew = true;
  Stream<Rows>? _msgStream;
  late final Stream<Rows> _convStream;
  Rows _msgs = [];
  int _waiting = 0;
  Timer? _beat;
  String _name = 'مستخدم';
  String _title = '';
  bool _search = false;
  String _q = '';
  final SpeechToText _dict = SpeechToText();
  bool _dictating = false;
  List<Map<String, String>> _chips = const [];
  bool _hasText = false;
  bool _temp = false;

  @override
  void initState() {
    super.initState();
    uid = sb.auth.currentUser!.id;
    _convStream = sb
        .from('conversations')
        .stream(primaryKey: ['id'])
        .eq('user_id', uid)
        .order('last_at', ascending: false);
    _startNew();
    _input.addListener(() {
      final h = _input.text.trim().isNotEmpty;
      if (h != _hasText) setState(() => _hasText = h);
    });
    _init();
  }

  @override
  void dispose() {
    _beat?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final saved = await KvStore.instance.get('aiName');
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
    final w = await Svc.loadWelcome();
    if (mounted) {
      setState(() {
        _title = w.title;
        _chips = w.items;
      });
    }
  }

  // ---------------- المحادثات ----------------
  Stream<Rows> _watch(String cid) =>
      sb.from('messages').stream(primaryKey: ['id']).eq('conv_id', cid).order('at', ascending: true);

  void _startNew({bool temp = false}) {
    final id = const Uuid().v4();
    setState(() {
      _convId = id;
      _convIsNew = true;
      _temp = temp;
      _msgs = [];
      _msgStream = temp ? null : _watch(id);
      _tempMsgs.clear();
    });
  }

  void _open(String id) {
    setState(() {
      _convId = id;
      _convIsNew = false;
      _temp = false;
      _msgs = [];
      _msgStream = _watch(id);
    });
  }

  // رسائل المحادثة المؤقتة (لا تُحفظ)
  final Rows _tempMsgs = [];

  void _scrollEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  // ---------------- معالجة الرسالة (نص أو صوت) ----------------
  Future<String> _process(String text, {bool voice = false, String? preset}) async {
    final cid = _convId!;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_temp) {
      final hist = List<Map<String, dynamic>>.from(_tempMsgs);
      setState(() {
        _tempMsgs.add({'sender': 'user', 'text': text});
        _waiting++;
      });
      _scrollEnd();
      try {
        final ans = preset ?? await Svc.matchReply(text) ?? await Svc.askAi(hist, text, voice: voice) ?? 'تمام 👍';
        if (mounted) setState(() => _tempMsgs.add({'sender': 'bot', 'text': ans}));
        _scrollEnd();
        return ans;
      } finally {
        if (mounted) setState(() => _waiting--);
      }
    }
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
    final hist = List<Map<String, dynamic>>.from(_msgs);
    await sb.from('messages').insert({'user_id': uid, 'conv_id': cid, 'sender': 'user', 'text': text});
    _bump(text, now);
    if (mounted) setState(() => _waiting++);
    try {
      String? ans = preset ?? await Svc.matchReply(text);
      final aiF = ans == null ? Svc.askAi(hist, text, voice: voice) : null;
      final p = await sb.from('profiles').select('in_call,human_until').eq('id', uid).maybeSingle();
      final hu = (p?['human_until'] is num) ? (p!['human_until'] as num).toInt() : 0;
      final human = p != null && (p['in_call'] == true || hu > DateTime.now().millisecondsSinceEpoch);
      if (human) return '';
      if (aiF != null) ans = await aiF;
      if (ans == null) {
        ans = 'تعذّر الاتصال بالذكاء الاصطناعي${Svc.lastError.isEmpty ? '' : ' (${Svc.lastError})'}';
      }
      await sb.from('messages').insert({'user_id': uid, 'conv_id': cid, 'sender': 'bot', 'text': ans});
      return ans;
    } finally {
      if (mounted) setState(() => _waiting--);
    }
  }

  Future<void> _bump(String text, int now) async {
    try {
      final p = await sb.from('profiles').select('unread').eq('id', uid).maybeSingle();
      final u = (p?['unread'] is num) ? (p!['unread'] as num).toInt() : 0;
      await sb
          .from('profiles')
          .update({'last_message': text, 'last_at': now, 'unread': u + 1}).eq('id', uid);
    } catch (_) {}
  }

  Future<void> _send({String? text, String? preset}) async {
    final t = (text ?? _input.text).trim();
    if (t.isEmpty) return;
    _input.clear();
    try {
      await _process(t, preset: preset == null ? null : Svc.pickVariant(preset));
    } catch (e) {
      _toast('تعذر الإرسال: $e');
    }
  }

  void _openVoice() {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: VoiceScreen(onUser: (t) => _process(t, voice: true)),
      ),
    ));
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 3)));
  }

  Future<void> _logout() async {
    _beat?.cancel();
    try {
      await sb.from('profiles').update({'in_call': false, 'voice_active': false}).eq('id', uid);
    } catch (_) {}
    await sb.auth.signOut();
  }

  // ---------------- الواجهة ----------------
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Scaffold(
      key: _scaffold,
      backgroundColor: pal.bg,
      drawer: _sidebar(pal),
      body: SafeArea(
        child: Column(
          children: [
            _header(pal),
            Expanded(child: _body(pal)),
            _bottom(pal),
          ],
        ),
      ),
    );
  }

  Widget _header(Pal pal) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      child: Row(
        textDirection: TextDirection.ltr,
        children: [
          CircleBtn(
            color: _temp ? pal.fg : pal.circle,
            onTap: () => _startNew(temp: !_temp),
            child: CustomPaint(size: const Size(24, 24), painter: TempChatPainter(_temp ? pal.bg : pal.fg)),
          ),
          const Spacer(),
          if (_temp)
            Text('محادثة مؤقتة', style: TextStyle(color: pal.mut, fontSize: 15))
          else
            GestureDetector(
              onTap: () => _plusModal(pal),
              child: Container(
                height: 46,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(color: pal.pill, borderRadius: BorderRadius.circular(24)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('اشترك في Plus',
                        style: TextStyle(color: pal.pillt, fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 8),
                    Icon(Icons.auto_awesome, color: pal.pillt, size: 20),
                  ],
                ),
              ),
            ),
          const SizedBox(width: 10),
          CircleBtn(
            color: pal.circle,
            onTap: () => _scaffold.currentState?.openDrawer(),
            child: CustomPaint(size: const Size(24, 24), painter: LinesPainter(pal.fg)),
          ),
        ],
      ),
    );
  }

  void _plusModal(Pal pal) {
    showDialog(
      context: context,
      builder: (c) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: pal.sheet,
          title: Text('✨ ChatGPT Plus', style: TextStyle(color: pal.fg)),
          content: Text('ميزات إضافية وأولوية أعلى في الاستجابة.', style: TextStyle(color: pal.mut)),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('حسناً'))],
        ),
      ),
    );
  }

  Future<void> _dictate() async {
    if (_dictating) {
      await _dict.stop();
      setState(() => _dictating = false);
      return;
    }
    final ok = await _dict.initialize(onStatus: (s) {
      if ((s == 'done' || s == 'notListening') && mounted) setState(() => _dictating = false);
    }, onError: (_) {
      if (mounted) setState(() => _dictating = false);
    });
    if (!ok) {
      _toast('التعرف على الصوت غير متاح');
      return;
    }
    String? loc;
    try {
      final ar = (await _dict.locales()).where((l) => l.localeId.toLowerCase().startsWith('ar')).toList();
      if (ar.isNotEmpty) loc = ar.first.localeId;
    } catch (_) {}
    setState(() => _dictating = true);
    final base = _input.text;
    await _dict.listen(
      localeId: loc,
      pauseFor: const Duration(seconds: 3),
      listenOptions: SpeechListenOptions(partialResults: true, listenMode: ListenMode.dictation),
      onResult: (r) {
        final t = r.recognizedWords;
        _input.text = base.isEmpty ? t : '$base $t';
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
      },
    );
  }

  Widget _body(Pal pal) {
    if (_temp) return _list(pal, _tempMsgs);
    return StreamBuilder<Rows>(
      stream: _msgStream,
      builder: (c, snap) {
        if (snap.hasData) {
          _msgs = snap.data!;
          if (_msgs.isNotEmpty) _scrollEnd();
        }
        return _list(pal, _msgs);
      },
    );
  }

  Widget _list(Pal pal, Rows rows) {
    if (rows.isEmpty && _waiting == 0) return _welcomeView(pal);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      itemCount: rows.length + (_waiting > 0 ? 1 : 0),
      itemBuilder: (c, i) {
        if (i >= rows.length) {
          return Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(color: pal.fg, shape: BoxShape.circle),
              ),
            ),
          );
        }
        final m = rows[i];
        final mine = m['sender'] == 'user';
        final text = (m['text'] ?? '').toString();
        return mine ? _userBubble(pal, text) : _botText(pal, text);
      },
    );
  }

  Widget _userBubble(Pal pal, String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _copy(text),
        child: Container(
          margin: const EdgeInsets.only(top: 8, bottom: 8, right: 56),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(color: pal.bub, borderRadius: BorderRadius.circular(22)),
          child: SelectableText(text, textAlign: TextAlign.right, style: TextStyle(color: pal.bubt, fontSize: 17, fontWeight: FontWeight.w500, height: 1.4)),
        ),
      ),
    );
  }

  void _copy(String t) {
    Clipboard.setData(ClipboardData(text: t));
    _toast('تم النسخ');
  }

  Widget _botText(Pal pal, String text) {
    final parts = <Widget>[];
    final re = RegExp(r'```([^\n`]*)\n?([\s\S]*?)```');
    var last = 0;
    void plain(String s) {
      s = s.trim();
      if (s.isEmpty) return;
      parts.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: SelectableText(s, textAlign: TextAlign.right, style: TextStyle(color: pal.fg, fontSize: 17, fontWeight: FontWeight.w500, height: 1.6)),
      ));
    }

    for (final m in re.allMatches(text)) {
      plain(text.substring(last, m.start));
      final lang = (m.group(1) ?? '').trim();
      final body = (m.group(2) ?? '').trimRight();
      final writing = lang == 'writing';
      parts.add(Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(color: pal.code, borderRadius: BorderRadius.circular(14), border: Border.all(color: pal.line)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 0),
              child: Row(
                children: [
                  Text(writing ? 'نص' : (lang.isEmpty ? 'code' : lang), style: TextStyle(color: pal.mut, fontSize: 13)),
                  const Spacer(),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _copy(body),
                    icon: Icon(Icons.copy_rounded, size: 18, color: pal.mut),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: writing
                  ? SelectableText(body, style: TextStyle(color: pal.fg, fontSize: 16, height: 1.6))
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SelectableText(
                        body,
                        textDirection: TextDirection.ltr,
                        style: TextStyle(color: pal.fg, fontSize: 14, fontFamily: 'monospace', height: 1.45),
                      ),
                    ),
            ),
          ],
        ),
      ));
      last = m.end;
    }
    plain(text.substring(last));
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ...parts,
        const SizedBox(height: 8),
        Row(
          textDirection: TextDirection.ltr,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            for (final ic in [Icons.volume_up_outlined, Icons.thumb_up_alt_outlined, Icons.thumb_down_alt_outlined, Icons.ios_share_rounded])
              Padding(
                padding: const EdgeInsets.only(left: 22),
                child: GestureDetector(
                  onTap: () => _copy(text),
                  child: Icon(ic, size: 22, color: pal.mut),
                ),
              ),
            const SizedBox(width: 0),
          ],
        ),
      ]),
    );
  }

  Widget _welcomeView(Pal pal) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_temp)
              Text('المحادثات المؤقتة لا تُحفظ في السجل',
                  textAlign: TextAlign.center, style: TextStyle(color: pal.mut, fontSize: 17))
            else ...[
              if (_title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Text(_title,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: pal.fg, fontSize: 28, fontWeight: FontWeight.w600)),
                ),
              if (_chips.isEmpty) _promo(pal),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final x in _chips)
                    GestureDetector(
                      onTap: () => _send(text: x['text'], preset: x['answer']),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(color: pal.bar, borderRadius: BorderRadius.circular(24)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if ((x['emoji'] ?? '').isNotEmpty)
                              Padding(
                                padding: const EdgeInsetsDirectional.only(end: 8),
                                child: Text(x['emoji']!, style: const TextStyle(fontSize: 20)),
                              ),
                            Text(x['text'] ?? '', style: TextStyle(color: pal.fg, fontSize: 16)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _promo(Pal pal) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 280,
            height: 228,
            child: CustomPaint(painter: BikeCardPainter()),
          ),
        ),
        const SizedBox(height: 26),
        Text('Intelligent UI مع GPT-6',
            textDirection: TextDirection.rtl,
            style: TextStyle(color: pal.fg, fontSize: 24, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Text('احصل على إجابات مرئية وتفاعلية تساعدك على اتخاذ الخطوة التالية',
            textAlign: TextAlign.center,
            style: TextStyle(color: pal.mut, fontSize: 15.5, height: 1.5)),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: () => _plusModal(pal),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(28)),
            child: const Text('جرّب GPT-6',
                style: TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  Widget _bottom(Pal pal) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(color: pal.bar, borderRadius: BorderRadius.circular(30)),
        child: Row(
          textDirection: TextDirection.ltr,
          children: [
            GestureDetector(
              onTap: _hasText ? () => _send() : _openVoice,
              child: Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(color: Pal.blue, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: _hasText
                    ? const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 26)
                    : CustomPaint(size: const Size(26, 26), painter: WavePainter(Colors.white)),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _dictate,
              child: SizedBox(
                width: 46,
                height: 44,
                child: Icon(_dictating ? Icons.mic : Icons.mic_none_rounded,
                    color: _dictating ? Pal.blue : pal.fg, size: 28),
              ),
            ),
            Expanded(
              child: TextField(
                controller: _input,
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.right,
                style: TextStyle(color: pal.fg, fontSize: 17, fontWeight: FontWeight.w600),
                cursorColor: pal.fg,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: 'اسأل ChatGPT',
                  hintStyle: TextStyle(color: pal.mut, fontSize: 17),
                  border: InputBorder.none,
                  isCollapsed: true,
                ),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _plusSheet(pal),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(Icons.add_rounded, color: pal.fg, size: 30),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _plusSheet(Pal pal) {
    showModalBottomSheet(
      context: context,
      backgroundColor: pal.sheet,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final it in const [
                  (Icons.photo_camera_outlined, 'الكاميرا'),
                  (Icons.image_outlined, 'الصور'),
                  (Icons.attach_file_rounded, 'الملفات'),
                ])
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(c);
                      _toast('${it.$2}: قريباً في التحديث القادم');
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(color: pal.sheetIcon, shape: BoxShape.circle),
                          child: Icon(it.$1, color: pal.fg, size: 28),
                        ),
                        const SizedBox(height: 8),
                        Text(it.$2, style: TextStyle(color: pal.fg, fontSize: 14)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- الشريط الجانبي ----------------
  Widget _sidebar(Pal pal) {
    const nav = [
      (Icons.collections_outlined, 'الصور'),
      (Icons.view_week_outlined, 'المكتبة'),
      (Icons.folder_open_rounded, 'المشروعات'),
      (Icons.desktop_windows_outlined, 'التحكم عن بُعد'),
      (Icons.schedule_rounded, 'المهام'),
      (Icons.extension_outlined, 'المكونات الإضافية'),
    ];
    final initials = _name.trim().isEmpty
        ? '?'
        : _name.trim().characters.take(2).toString().toUpperCase();
    return Drawer(
      backgroundColor: pal.side,
      width: MediaQuery.of(context).size.width * 0.8,
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
              child: _search
                  ? Row(children: [
                      Expanded(
                        child: TextField(
                          autofocus: true,
                          style: TextStyle(color: pal.fg, fontSize: 17),
                          onChanged: (v) => setState(() => _q = v),
                          decoration: InputDecoration(
                            hintText: 'بحث في المحادثات',
                            hintStyle: TextStyle(color: pal.mut),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      CircleBtn(
                          color: pal.circle,
                          size: 46,
                          onTap: () => setState(() {
                                _search = false;
                                _q = '';
                              }),
                          child: Icon(Icons.close, color: pal.fg, size: 22)),
                    ])
                  : Row(children: [
                      Text('ChatGPT', style: TextStyle(color: pal.fg, fontSize: 24, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      CircleBtn(
                          color: pal.circle,
                          size: 46,
                          onTap: () => setState(() => _search = true),
                          child: Icon(Icons.search_rounded, color: pal.fg, size: 26)),
                    ]),
            ),
            const SizedBox(height: 6),
            for (final n in nav)
              InkWell(
                onTap: () => _toast('${n.$2}: غير متاح حالياً'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                  child: Row(children: [
                    Icon(n.$1, color: pal.fg, size: 26),
                    const SizedBox(width: 16),
                    Text(n.$2, style: TextStyle(color: pal.fg, fontSize: 17.5, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
              child: Divider(color: pal.line, height: 1),
            ),
            Expanded(
              child: StreamBuilder<Rows>(
                stream: _convStream,
                builder: (c, snap) {
                  final rows = (snap.data ?? [])
                      .where((r) => _q.isEmpty || (r['title'] ?? '').toString().contains(_q))
                      .toList();
                  return ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: rows.length,
                    itemBuilder: (c, i) {
                      final r = rows[i];
                      final id = r['id'].toString();
                      return InkWell(
                        onTap: () {
                          Navigator.pop(context);
                          _open(id);
                        },
                        onLongPress: () async {
                          await sb.from('messages').delete().eq('conv_id', id);
                          await sb.from('conversations').delete().eq('id', id);
                          if (id == _convId) _startNew();
                        },
                        child: Container(
                          color: (id == _convId && !_temp) ? pal.bar : null,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          child: Text((r['title'] ?? 'محادثة').toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: pal.fg, fontSize: 17)),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        _startNew();
                      },
                      child: Container(
                        height: 62,
                        decoration: BoxDecoration(color: Pal.blue, borderRadius: BorderRadius.circular(31)),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.edit_square, color: Colors.white, size: 24),
                            const SizedBox(width: 10),
                            const Text('الدردشة',
                                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () => _settings(pal),
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: pal.circle,
                      ),
                      alignment: Alignment.center,
                      child: CircleAvatar(
                        radius: 24,
                        backgroundColor: Pal.green,
                        child: Text(initials,
                            style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _settings(Pal pal) {
    showDialog(
      context: context,
      builder: (c) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (c, set) => AlertDialog(
            backgroundColor: pal.sheet,
            title: Text('الإعدادات', style: TextStyle(color: pal.fg)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_name, style: TextStyle(color: pal.fg, fontSize: 18)),
                  subtitle: Text(sb.auth.currentUser?.email ?? '', style: TextStyle(color: pal.mut)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('الوضع الداكن', style: TextStyle(color: pal.fg)),
                  value: themeMode.value == ThemeMode.dark,
                  onChanged: (v) {
                    themeMode.value = v ? ThemeMode.dark : ThemeMode.light;
                    KvStore.instance.set('aiTheme', v ? 'dark' : 'light');
                    Navigator.pop(c);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(c);
                  _logout();
                },
                child: const Text('تسجيل الخروج', style: TextStyle(color: Colors.redAccent)),
              ),
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('إغلاق')),
            ],
          ),
        ),
      ),
    );
  }
}
