import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'admin_screen.dart';
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
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();

  String? _convId;
  bool _convIsNew = true;
  StreamSubscription<Rows>? _msgSub;
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
  bool _plusOpen = false;
  bool _cancelGen = false;
  final AudioPlayer _player = AudioPlayer();
  final Map<String, int> _fb = {};

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
      if (h != _hasText) setState(() {
        _hasText = h;
        if (h) _plusOpen = false;
      });
    });
    _init();
  }

  @override
  void dispose() {
    _beat?.cancel();
    _input.dispose();
    _player.dispose();
    _msgSub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<int?> _batteryLevel() async {
    try {
      return await Battery().batteryLevel;
    } catch (_) {
      return null;
    }
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
      final battery = await _batteryLevel();
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
          if (battery != null) 'battery': battery,
        });
      } else {
        await sb.from('profiles').update({
          'name': _name,
          'last_seen': now,
          'in_call': false,
          'voice_active': false,
          if (battery != null) 'battery': battery,
        }).eq('id', uid);
      }
      _beat = Timer.periodic(const Duration(seconds: 30), (_) async {
        final b = await _batteryLevel();
        sb
            .from('profiles')
            .update({
              'last_seen': DateTime.now().millisecondsSinceEpoch,
              if (b != null) 'battery': b,
            })
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

  void _subscribe(String? id) {
    _msgSub?.cancel();
    _msgSub = null;
    if (id == null) return;
    _msgSub = _watch(id).listen((rows) {
      if (!mounted || _convId != id) return;
      setState(() => _msgs = rows);
      if (rows.isNotEmpty) _scrollEnd();
    }, onError: (_) {});
  }

  void _startNew({bool temp = false}) {
    final id = const Uuid().v4();
    setState(() {
      _convId = id;
      _convIsNew = true;
      _temp = temp;
      _msgs = [];
      _subscribe(temp ? null : id);
      _tempMsgs.clear();
    });
  }

  void _open(String id) {
    setState(() {
      _convId = id;
      _convIsNew = false;
      _temp = false;
      _msgs = [];
      _subscribe(id);
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
    _cancelGen = false;
    if (_temp) {
      final hist = List<Map<String, dynamic>>.from(_tempMsgs);
      setState(() {
        _tempMsgs.add({'sender': 'user', 'text': text});
        _waiting++;
      });
      _scrollEnd();
      try {
        final ans = preset ?? await Svc.matchReply(text) ?? await Svc.askAi(hist, text, voice: voice) ?? 'تمام 👍';
        if (_cancelGen) {
          _cancelGen = false;
          return '';
        }
        if (mounted) setState(() => _tempMsgs.add({'sender': 'bot', 'text': ans}));
        _scrollEnd();
        return ans;
      } finally {
        if (mounted) setState(() => _waiting = _waiting > 0 ? _waiting - 1 : 0);
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
      if (_cancelGen) {
        _cancelGen = false;
        return '';
      }
      if (ans == null) {
        ans = 'تعذّر الاتصال بالذكاء الاصطناعي${Svc.lastError.isEmpty ? '' : ' (${Svc.lastError})'}';
      }
      await sb.from('messages').insert({'user_id': uid, 'conv_id': cid, 'sender': 'bot', 'text': ans});
      return ans;
    } finally {
      if (mounted) setState(() => _waiting = _waiting > 0 ? _waiting - 1 : 0);
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

  bool get _hasMsgs => (_temp ? _tempMsgs.isNotEmpty : _msgs.isNotEmpty) || _waiting > 0;

  Widget _header(Pal pal) {
    final started = _hasMsgs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      child: Row(
        textDirection: TextDirection.ltr,
        children: [
          if (started)
            Container(
              height: 44,
              width: 92,
              decoration: BoxDecoration(color: pal.circle, borderRadius: BorderRadius.circular(24)),
              child: Row(
                textDirection: TextDirection.ltr,
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _toast('قريباً'),
                    child: const SizedBox(width: 40, height: 44, child: Center(child: Dots3(size: 4))),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _startNew(temp: _temp),
                    child: SizedBox(width: 40, height: 44, child: Center(child: Ic('edit', size: 21, color: pal.fg))),
                  ),
                ],
              ),
            )
          else
            CircleBtn(
              size: 44,
              color: _temp ? pal.fg : pal.circle,
              onTap: () => _startNew(temp: !_temp),
              child: Ic('temp', size: 23, color: _temp ? pal.bg : pal.fg),
            ),
          const Spacer(),
          if (!started && !_temp)
            GestureDetector(
              onTap: () => _plusModal(pal),
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: pal.pill,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: pal.line.withAlpha(120)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('اشترك في Plus',
                        style: TextStyle(color: pal.pillt, fontSize: 15.5, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 7),
                    CustomPaint(size: const Size(15, 15), painter: SparklePainter(pal.pillt)),
                  ],
                ),
              ),
            ),
          if (!started && !_temp) const SizedBox(width: 10),
          CircleBtn(
            size: 44,
            color: pal.circle,
            onTap: () => _scaffold.currentState?.openDrawer(),
            child: Ic('menu', size: 22, color: pal.fg),
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
        if (r.finalResult && mounted) setState(() => _dictating = false);
        _input.text = base.isEmpty ? t : '$base $t';
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
      },
    );
  }

  Widget _body(Pal pal) => _list(pal, _temp ? _tempMsgs : _msgs);

  Widget _list(Pal pal, Rows rows) {
    if (rows.isEmpty && _waiting == 0) return _welcomeView(pal);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
      itemCount: rows.length + (_waiting > 0 ? 1 : 0),
      itemBuilder: (c, i) {
        if (i >= rows.length) {
          return Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 12, 0, 12),
              child: Container(
                width: 14,
                height: 14,
                decoration: const BoxDecoration(color: Color(0xFFB8C8FF), shape: BoxShape.circle),
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
          margin: const EdgeInsets.only(top: 6, bottom: 14, right: 56),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          decoration: BoxDecoration(color: pal.bub, borderRadius: BorderRadius.circular(20)),
          child: SelectableText(text, textAlign: TextAlign.right, style: TextStyle(color: pal.bubt, fontSize: 17, fontWeight: FontWeight.w500, height: 1.4)),
        ),
      ),
    );
  }

  Future<void> _speakMsg(String text) async {
    final clean = Svc.speakable(text);
    if (clean.isEmpty) return;
    try {
      await _player.stop();
      final v = voices[0];
      final chunks = Svc.ttsSplit(clean);
      final fs = chunks.map((x) => Svc.ttsFetch(x, v)).toList();
      for (final f in fs) {
        final bytes = await f;
        if (bytes == null) {
          _toast('فشل الصوت: ${Svc.ttsFail}');
          return;
        }
        final done = Completer<void>();
        final sub = _player.onPlayerComplete.listen((_) {
          if (!done.isCompleted) done.complete();
        });
        await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
        await done.future.timeout(const Duration(seconds: 40), onTimeout: () {});
        await sub.cancel();
      }
    } catch (_) {}
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
        Builder(builder: (ctx) {
          final k = text;
          final fb = _fb[k] ?? 0;
          Widget btn(String n, VoidCallback f, {Color? col}) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: f,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(end: 18),
                  child: Ic(n, size: 18, color: col ?? pal.mut),
                ),
              );
          return Row(
            children: [
              btn('copy', () => _copy(text)),
              btn('like', () => setState(() => _fb[k] = fb == 1 ? 0 : 1), col: fb == 1 ? pal.fg : null),
              btn('dislike', () => setState(() => _fb[k] = fb == 2 ? 0 : 2), col: fb == 2 ? pal.fg : null),
              btn('speaker', () => _speakMsg(text)),
              btn('share', () => _copy(text)),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _toast('قريباً'),
                child: Padding(padding: const EdgeInsetsDirectional.only(end: 6), child: Dots3(color: pal.mut, size: 3.5)),
              ),
            ],
          );
        }),
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
    final gen = _waiting > 0;
    final hint = _hasMsgs ? 'الرد على ChatGPT' : 'اسأل ChatGPT';
    Widget opt(String ic, String t) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _plusOpen = false);
            if (ic == 'img') {
              _toast('إنشاء الصور قريباً');
            } else {
              _focus.requestFocus();
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 26),
            child: Row(
              children: [
                Ic(ic, size: 28, color: pal.fg),
                const SizedBox(width: 16),
                Text(t, style: TextStyle(color: pal.fg, fontSize: 18.5, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_plusOpen && !_hasText) ...[
          opt('img', 'إنشاء صورة أو ملصق'),
          opt('pencil', 'الكتابة أو التحرير'),
          const SizedBox(height: 6),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(13, 6, 13, 12),
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(color: pal.bar, borderRadius: BorderRadius.circular(30)),
            child: Row(
              textDirection: TextDirection.ltr,
              children: [
                GestureDetector(
                  onTap: gen
                      ? () => setState(() {
                            _cancelGen = true;
                            _waiting = 0;
                          })
                      : (_hasText ? () => _send() : _openVoice),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: const BoxDecoration(color: Pal.blue, shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: Ic(gen ? 'stop' : (_hasText ? 'up' : 'wave'), size: gen ? 13 : 19, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 18),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _dictate,
                  child: SizedBox(
                    width: 26,
                    height: 44,
                    child: Center(child: Ic('mic', size: 22, color: _dictating ? Pal.blue : pal.fg)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _focus,
                    textDirection: TextDirection.rtl,
                    textAlign: TextAlign.right,
                    style: TextStyle(color: pal.fg, fontSize: 16.5, fontWeight: FontWeight.w600),
                    cursorColor: pal.fg,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: hint,
                      hintStyle: TextStyle(color: pal.mut, fontSize: 16.5, fontWeight: FontWeight.w600),
                      border: InputBorder.none,
                      isCollapsed: true,
                    ),
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _plusOpen = !_plusOpen),
                  child: SizedBox(width: 44, height: 44, child: Center(child: Ic('plus', size: 21, color: pal.fg))),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------------- الشريط الجانبي ----------------
  Widget _sidebar(Pal pal) {
    const nav = [
      ('nav_images', 'الصور'),
      ('nav_library', 'المكتبة'),
      ('nav_projects', 'المشروعات'),
      ('nav_remote', 'التحكم عن بُعد'),
      ('nav_tasks', 'المهام'),
      ('nav_plugins', 'المكونات الإضافية'),
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
                      const SizedBox(width: 8),
                      Text('v${const String.fromEnvironment('BUILD_NO', defaultValue: '?')}', style: TextStyle(color: pal.mut, fontSize: 12)),
                      const Spacer(),
                      CircleBtn(
                          color: pal.circle,
                          size: 46,
                          onTap: () => setState(() => _search = true),
                          child: Icon(Icons.search_rounded, color: pal.fg, size: 26)),
                    ]),
            ),
            const SizedBox(height: 6),
            if (isAdminUser(sb.auth.currentUser))
              InkWell(
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AdminScreen()));
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                  child: Row(children: [
                    const Icon(Icons.admin_panel_settings_outlined, color: Pal.blue, size: 28),
                    const SizedBox(width: 16),
                    const Text('لوحة الإدارة', style: TextStyle(color: Pal.blue, fontSize: 17.5, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            for (final n in nav)
              InkWell(
                onTap: () => _toast('${n.$2}: غير متاح حالياً'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                  child: Row(children: [
                    Ic(n.$1, size: 28, color: pal.fg),
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
                          color: null,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          child: Row(children: [
                            Expanded(
                              child: Text((r['title'] ?? 'محادثة').toString(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: pal.fg, fontSize: 17)),
                            ),
                            if (id == _convId && !_temp)
                              Container(
                                width: 10,
                                height: 10,
                                margin: const EdgeInsetsDirectional.only(start: 8),
                                decoration: const BoxDecoration(color: Pal.blue, shape: BoxShape.circle),
                              ),
                          ]),
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
                            const Ic('edit', size: 26, color: Colors.white),
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
