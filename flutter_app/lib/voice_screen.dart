import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'icons.dart';
import 'kv_store.dart';
import 'services.dart';

/// شاشة الدردشة الصوتية: استماع (ar) → ردّ الذكاء → نطق بالصوت البشري عبر الوسيط
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key, required this.onUser});
  final Future<String> Function(String text) onUser;

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> with SingleTickerProviderStateMixin {
  final SpeechToText _stt = SpeechToText();
  final AudioPlayer _player = AudioPlayer();
  late final AnimationController _pulse;
  final PageController _pager = PageController();

  bool _active = true;
  bool _busy = false; // نعالج رد أو ننطق
  bool _speaking = false;
  bool _muted = false;
  bool _ready = false;
  String _status = 'جارٍ التجهيز…';
  String _heard = '';
  String? _locale;
  int _vIdx = 0;
  int _gen = 0;

  VoiceInfo get _voice => voices[_vIdx];

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat(reverse: true);
    _setVoiceActive(true);
    _boot();
  }

  void _setVoiceActive(bool v) {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    Supabase.instance.client
        .from('profiles')
        .update({'voice_active': v})
        .eq('id', uid)
        .then((_) {}, onError: (_) {});
  }

  Future<void> _boot() async {
    final sv = await KvStore.instance.get('vvoice');
    final k = voices.indexWhere((v) => v.id == sv);
    if (k >= 0 && mounted) {
      setState(() => _vIdx = k);
      _pager.jumpToPage(k);
    }
    try {
      _ready = await _stt.initialize(
        onStatus: _onStatus,
        onError: (e) {
          if (!mounted) return;
          if (e.errorMsg == 'error_permission') {
            setState(() => _status = 'اسمح للتطبيق باستخدام الميكروفون');
          }
        },
      );
      if (_ready) {
        final ls = await _stt.locales();
        final ar = ls.where((l) => l.localeId.toLowerCase().startsWith('ar')).toList();
        if (ar.isNotEmpty) {
          final sa = ar.where((l) => l.localeId.toLowerCase().replaceAll('_', '-') == 'ar-sa');
          _locale = (sa.isNotEmpty ? sa.first : ar.first).localeId;
        }
      }
    } catch (_) {
      _ready = false;
    }
    if (!mounted) return;
    if (!_ready) {
      setState(() => _status = 'التعرف على الصوت غير متاح (ثبّت تطبيق Google أو اسمح بالميكروفون)');
      return;
    }
    setState(() => _status = 'أستمع إليك…');
    _listen();
  }

  void _onStatus(String s) {
    if ((s == 'done' || s == 'notListening') && _active && !_busy && !_muted) {
      Future.delayed(const Duration(milliseconds: 350), () {
        if (_active && !_busy && !_muted && !_stt.isListening) _listen();
      });
    }
  }

  Future<void> _listen() async {
    if (!_active || !_ready || _busy || _muted || _stt.isListening) return;
    try {
      await _stt.listen(
        localeId: _locale,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 3),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.dictation,
        ),
        onResult: (r) {
          if (!mounted) return;
          setState(() => _heard = r.recognizedWords);
          if (r.finalResult && r.recognizedWords.trim().isNotEmpty) {
            _handle(r.recognizedWords.trim());
          }
        },
      );
    } catch (_) {}
  }

  Future<void> _handle(String text) async {
    if (_busy || !_active) return;
    _busy = true;
    final my = ++_gen;
    try {
      await _stt.stop();
    } catch (_) {}
    if (mounted) setState(() => _status = 'أفكّر…');
    String ans;
    try {
      ans = await widget.onUser(text);
    } catch (_) {
      ans = 'تعذّر الرد';
    }
    if (!_active || my != _gen) return;
    await _speak(ans, my);
    _busy = false;
    if (!mounted || !_active) return;
    setState(() {
      _heard = '';
      _status = 'أستمع إليك…';
    });
    _listen();
  }

  Future<void> _speak(String text, int my) async {
    final clean = Svc.speakable(text);
    if (clean.isEmpty || !Svc.cloudTtsOk) {
      if (!Svc.cloudTtsOk && mounted) setState(() => _status = Svc.ttsFail);
      return;
    }
    final chunks = Svc.ttsSplit(clean);
    final fetches = chunks.map((c) => Svc.ttsFetch(c, _voice)).toList();
    if (mounted) setState(() => _speaking = true);
    for (var i = 0; i < fetches.length; i++) {
      final bytes = await fetches[i];
      if (!_active || my != _gen) break;
      if (bytes == null) {
        if (mounted) setState(() => _status = 'فشل الصوت: ${Svc.ttsFail}');
        await Future.delayed(const Duration(seconds: 2));
        break;
      }
      if (mounted) setState(() => _status = '');
      final done = Completer<void>();
      final sub = _player.onPlayerComplete.listen((_) {
        if (!done.isCompleted) done.complete();
      });
      try {
        await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
        await done.future.timeout(const Duration(seconds: 40), onTimeout: () {});
      } catch (_) {}
      await sub.cancel();
    }
    if (mounted) setState(() => _speaking = false);
  }

  void _toggleMute() {
    setState(() {
      _muted = !_muted;
      _status = _muted ? 'الميكروفون مكتوم' : 'أستمع إليك…';
    });
    if (_muted) {
      _stt.stop();
    } else {
      _listen();
    }
  }

  Future<void> _end() async {
    _active = false;
    _gen++;
    try {
      await _stt.cancel();
    } catch (_) {}
    try {
      await _player.stop();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _active = false;
    _gen++;
    _setVoiceActive(false);
    _pulse.dispose();
    _pager.dispose();
    try {
      _stt.cancel();
    } catch (_) {}
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _end();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 8),
              Expanded(
                child: PageView.builder(
                  controller: _pager,
                  itemCount: voices.length,
                  onPageChanged: (i) {
                    setState(() => _vIdx = i);
                    KvStore.instance.set('vvoice', voices[i].id);
                  },
                  itemBuilder: (c, i) => Center(
                    child: AnimatedBuilder(
                      animation: _pulse,
                      builder: (c, _) {
                        final amp = _speaking ? 0.10 : (_busy ? 0.04 : 0.025);
                        final s = 1 + amp * _pulse.value;
                        return Transform.scale(
                          scale: s,
                          child: VoiceBall(size: 230, female: voices[i].female),
                        );
                      },
                    ),
                  ),
                ),
              ),
              Text(_voice.name,
                  style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(_voice.sub, style: const TextStyle(color: Color(0xFF9D9D9D), fontSize: 15)),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < voices.length; i++)
                    Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _vIdx ? Colors.white : const Color(0xFF555555),
                      ),
                    ),
                ],
              ),
              SizedBox(
                height: 64,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Center(
                    child: Text(
                      _heard.isNotEmpty && !_busy ? _heard : _status,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFFBDBDBD), fontSize: 16),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircleBtn(
                      size: 64,
                      color: const Color(0xFF303030),
                      onTap: _toggleMute,
                      child: Icon(_muted ? Icons.mic_off : Icons.mic, color: Colors.white, size: 28),
                    ),
                    const SizedBox(width: 28),
                    CircleBtn(
                      size: 64,
                      color: const Color(0xFFE5484D),
                      onTap: _end,
                      child: const Icon(Icons.close, color: Colors.white, size: 30),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
