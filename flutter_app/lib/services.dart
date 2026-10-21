import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';

typedef Rows = List<Map<String, dynamic>>;

class VoiceInfo {
  const VoiceInfo(this.id, this.name, this.sub, this.female);
  final String id;
  final String name;
  final String sub;
  final bool female;
}

const List<VoiceInfo> voices = [
  VoiceInfo('ar-IQ-RanaNeural', 'Rana', 'صوت أنثوي', true),
  VoiceInfo('ar-IQ-BasselNeural', 'Bassel', 'صوت ذكوري', false),
];

const String _extraSystem =
    '\n\nاستثناء مهم: عند كتابة أي كود برمجي ضعه دائماً داخل كتلة بهذا الشكل ```اسم_اللغة ثم الكود ثم ```، واشرح خارج الكتلة بنص عادي. وعندما يطلب المستخدم كتابة نص إبداعي أو طويل (قصة، مقال، رسالة، خطاب، قصيدة، منشور، فقرة) فاكتب جملة تمهيد قصيرة ثم ضع النص نفسه داخل كتلة ```writing ثم النص ثم ```. وإذا أرسل المستخدم صورة فانظر إليها بدقة وأجب عن سؤاله أو صفها.';
const String _voiceSystem =
    '\n\nهذا رد صوتي: أجب بجملة أو جملتين قصيرتين فقط، بدون قوائم أو رموز أو كود.';

class Svc {
  Svc._();
  static final SupabaseClient sb = Supabase.instance.client;
  static final Random _rand = Random();
  static String lastError = '';
  static bool cloudTtsOk = true;

  static Future<Map<String, dynamic>> _aiCfg() async {
    try {
      final row = await sb.from('settings').select('data').eq('id', 'ai').maybeSingle();
      final raw = row?['data'];
      return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static String _url(Map<String, dynamic> cfg) {
    final cu = cfg['url'];
    return (cu is String && cu.startsWith('https://')) ? cu : defaultAiUrl;
  }

  // ---------- اقتراحات الترحيب ----------
  static Future<({String title, List<Map<String, String>> items})> loadWelcome() async {
    var title = '';
    var items = <Map<String, String>>[];
    try {
      final w = await sb.from('settings').select('data').eq('id', 'welcome').maybeSingle();
      final d = w?['data'];
      if (d is Map && d['title'] is String) title = (d['title'] as String).trim();
    } catch (_) {}
    try {
      final s = await sb.from('settings').select('data').eq('id', 'sg').maybeSingle();
      final d = s?['data'];
      final list = d is Map ? d['list'] : null;
      if (list is List && list.isNotEmpty) {
        final out = <Map<String, String>>[];
        final sorted = list.whereType<Map>().toList()
          ..sort((a, b) => ((a['order'] ?? 0) as num).compareTo((b['order'] ?? 0) as num));
        for (final x in sorted) {
          if (x['on'] == false) continue;
          final t = (x['text'] ?? '').toString();
          if (t.isEmpty) continue;
          out.add({
            'emoji': (x['emoji'] ?? '').toString(),
            'text': t,
            'answer': (x['answer'] ?? '').toString(),
          });
        }
        if (out.isNotEmpty) items = out;
      }
    } catch (_) {}
    return (title: title, items: items);
  }

  // ---------- الردود الجاهزة ----------
  static String _norm(String s) {
    var t = s.toLowerCase();
    t = t.replaceAll(RegExp('[ً-ٟ]'), '');
    t = t.replaceAll(RegExp('[أإآ]'), 'ا').replaceAll('ة', 'ه').replaceAll('ى', 'ي');
    return t;
  }

  static String pickVariant(String a) {
    if (!a.contains('|||')) return a;
    final v = a.split('|||').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
    return v.isEmpty ? a : v[_rand.nextInt(v.length)];
  }

  static Future<String?> matchReply(String text) async {
    try {
      final rows = await sb.from('replies').select('keywords,answer');
      final t = _norm(text);
      String? best;
      var len = 0;
      for (final r in rows) {
        final kw = r['keywords'];
        final an = r['answer'];
        if (kw is! String || an is! String) continue;
        for (final k in kw
            .split(RegExp(r'[,،\n]'))
            .map((x) => _norm(x.trim()))
            .where((x) => x.isNotEmpty)) {
          if (t.contains(k) && k.length > len) {
            best = an;
            len = k.length;
          }
        }
      }
      return best == null ? null : pickVariant(best);
    } catch (_) {
      return null;
    }
  }

  // ---------- الذكاء الاصطناعي ----------
  static String _clean(String t) {
    final re = RegExp(r'```[\s\S]*?```');
    final sb2 = StringBuffer();
    var last = 0;
    String fix(String s) => s
        .replaceAll('**', '')
        .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*[*-]\s+', multiLine: true), '• ');
    for (final m in re.allMatches(t)) {
      sb2.write(fix(t.substring(last, m.start)));
      sb2.write(m.group(0));
      last = m.end;
    }
    sb2.write(fix(t.substring(last)));
    return sb2.toString().trim();
  }

  static Future<String?> askAi(Rows history, String text,
      {bool voice = false, List<Map<String, String>>? images}) async {
    final cfg = await _aiCfg();
    if (cfg['on'] == false) {
      lastError = 'العقل الذكي مطفأ من لوحة التحكم';
      return null;
    }
    final url = _url(cfg);
    final msgs = <Map<String, String>>[];
    final recent = history.length > 24 ? history.sublist(history.length - 24) : history;
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
    var model = (cfg['model'] ?? '').toString();
    if (model.isEmpty || model == 'gemini-2.5-flash' || model == 'gemini-3-flash-preview') {
      model = 'gemini-3.8-flash';
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (attempt > 0) {
          try {
            await sb.auth.refreshSession();
          } catch (_) {}
        }
        final token = sb.auth.currentSession?.accessToken;
        final body = jsonEncode({
          'idToken': token,
          'messages': msgs,
          'system': '${cfg['system'] ?? ''}${voice ? _voiceSystem : ''}$_extraSystem',
          if (images != null && images.isNotEmpty) 'images': images,
          'model': model,
          'temperature': cfg['temp'] is num ? cfg['temp'] : 0.8,
          'voice': voice,
        });
        final r = await http
            .post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: body)
            .timeout(const Duration(seconds: 25));
        dynamic d;
        try {
          d = jsonDecode(utf8.decode(r.bodyBytes));
        } catch (_) {}
        if (r.statusCode == 200 && d is Map && d['text'] is String) {
          final t = _clean(d['text'] as String);
          if (t.isNotEmpty) {
            lastError = '';
            return t;
          }
          lastError = 'رد فارغ من الوسيط';
        } else {
          lastError = 'HTTP ${r.statusCode}';
        }
      } catch (e) {
        lastError = e.toString();
      }
    }
    return null;
  }

  // ---------- الصوت البشري ----------
  static List<String> ttsSplit(String t) {
    final ss = RegExp(r'[^.!?؟]+[.!?؟]*\s*')
        .allMatches(t)
        .map((m) => m.group(0)!.trim())
        .where((x) => x.isNotEmpty)
        .toList();
    if (ss.isEmpty) return [t];
    var first = ss.removeAt(0);
    if (first.length > 150) {
      final k = first.lastIndexOf(' ', 140);
      if (k > 40) {
        ss.insert(0, first.substring(k + 1));
        first = first.substring(0, k);
      }
    }
    final out = <String>[first];
    var cur = '';
    for (final x in ss) {
      cur = cur.isEmpty ? x : '$cur $x';
      if (cur.length > 200 && out.length < 3) {
        out.add(cur);
        cur = '';
      }
    }
    if (cur.isNotEmpty) {
      if (out.length < 3) {
        out.add(cur);
      } else {
        out[out.length - 1] = '${out.last} $cur';
      }
    }
    return out;
  }

  static String speakable(String text) {
    var t = text.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    t = t.replaceAll(RegExp('[\u{1F000}-\u{1FFFF}☀-➿️]', unicode: true), '');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 500 ? t.substring(0, 500) : t;
  }

  static final Map<String, Uint8List> _ttsCache = {};
  static String ttsFail = '';

  static Future<Uint8List?> ttsFetch(String text, VoiceInfo v) async {
    final key = '${v.id}|$text';
    final c = _ttsCache[key];
    if (c != null) return c;
    final cfg = await _aiCfg();
    final url = _url(cfg);
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (attempt > 0) {
          try {
            await sb.auth.refreshSession();
          } catch (_) {}
        }
        final r = await http
            .post(Uri.parse(url),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'idToken': sb.auth.currentSession?.accessToken,
                  'tts': true,
                  'text': text,
                  'voice': v.id,
                }))
            .timeout(const Duration(seconds: 15));
        dynamic j;
        try {
          j = jsonDecode(utf8.decode(r.bodyBytes));
        } catch (_) {}
        if (r.statusCode == 200 && j is Map && j['audio'] is String) {
          final bytes = base64Decode(j['audio'] as String);
          if (_ttsCache.length > 40) _ttsCache.remove(_ttsCache.keys.first);
          _ttsCache[key] = bytes;
          return bytes;
        }
        if (r.statusCode == 501) {
          cloudTtsOk = false;
          ttsFail = 'الصوت البشري غير مفعّل في Cloudflare';
          return null;
        }
        if (r.statusCode == 429) {
          cloudTtsOk = false;
          ttsFail = 'انتهت حصة الصوت اليومية';
          return null;
        }
        ttsFail = 'HTTP ${r.statusCode}';
      } catch (e) {
        ttsFail = e is TimeoutException ? 'انتهت مهلة الصوت' : e.toString();
        if (kDebugMode) debugPrint('tts error $e');
      }
    }
    return null;
  }
}
