import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'theme.dart';

final SupabaseClient _sb = Supabase.instance.client;

const Map<String, dynamic> iceConfig = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ],
};

// ملاحظة: الجداول calls و call_candidates موجودة مسبقاً في قاعدة البيانات
// (supabase/schema.sql) بهذه الأعمدة:
//   calls(user_id pk, video_req, video_declined, video_offer, video_cid, video_answer, video_status, ...)
//   call_candidates(id pk, user_id, cid, by, cand, at)
// لا حاجة لإنشاء جداول جديدة.

Map<String, dynamic> candJson(RTCIceCandidate c) => {
      'candidate': c.candidate,
      'sdpMid': c.sdpMid,
      'sdpMLineIndex': c.sdpMLineIndex,
    };

String newCid() =>
    DateTime.now().millisecondsSinceEpoch.toRadixString(36) + Random().nextInt(999999).toString();

/// يعرض نص الخطأ الفعلي بدل رسالة عامة، كي نعرف السبب الحقيقي بدل التخمين
void showErrorDialog(BuildContext context, String title, Object error) {
  showDialog(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: SelectableText(error.toString(), textDirection: TextDirection.ltr),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('حسناً'))],
    ),
  );
}

/// ============ جهة المستخدم ============
/// يستمع لطلبات فتح الكاميرا القادمة من لوحة الإدارة، ويعرض نافذة إذن
/// صريحة وواضحة قبل أي بث فعلي: "يريد أحد المشرفين فتح كاميرتك الأمامية".
/// لا يُفتح البث إلا بعد موافقة صريحة من المستخدم.
class CameraConsentListener extends StatefulWidget {
  const CameraConsentListener({super.key, required this.child});
  final Widget child;

  @override
  State<CameraConsentListener> createState() => _CameraConsentListenerState();
}

class _CameraConsentListenerState extends State<CameraConsentListener> {
  StreamSubscription<List<Map<String, dynamic>>>? _callSub;
  StreamSubscription<List<Map<String, dynamic>>>? _candSub;
  int? _lastReqSeen;
  bool _busy = false;
  bool _answered = false;
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  String? _cid;
  bool _remoteSet = false;
  final List<RTCIceCandidate> _pendingCands = [];

  @override
  void initState() {
    super.initState();
    final uid = _sb.auth.currentUser?.id;
    if (uid != null) {
      _callSub =
          _sb.from('calls').stream(primaryKey: ['user_id']).eq('user_id', uid).listen(_onCallRow);
    }
  }

  @override
  void dispose() {
    _callSub?.cancel();
    _candSub?.cancel();
    _stopLocal();
    super.dispose();
  }

  Future<void> _stopLocal() async {
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    try {
      _localStream?.getTracks().forEach((t) => t.stop());
    } catch (_) {}
    _localStream = null;
    _cid = null;
    _answered = false;
    _remoteSet = false;
    _pendingCands.clear();
  }

  void _onCallRow(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return;
    final r = rows.first;
    if (r['video_status'] == 'ended' && _pc != null) {
      _stopLocal();
    }
    if (_pc != null && r['video_cid']?.toString() == _cid) {
      final ans = r['video_answer'];
      if (ans is Map && !_answered) {
        _answered = true;
        final pc = _pc!;
        pc
            .setRemoteDescription(
                RTCSessionDescription(ans['sdp'] as String, ans['type'] as String))
            .then((_) async {
          // يسمح الآن بإضافة أي مرشحات ICE وصلت قبل اكتمال الرد، بدل تطبيقها
          // مباشرة على اتصال بلا وصف بعيد بعد (سبب التعطل الصامت سابقاً)
          _remoteSet = true;
          for (final c in _pendingCands) {
            await pc.addCandidate(c).catchError((_) {});
          }
          _pendingCands.clear();
        }).catchError((_) {});
      }
    }
    final req = r['video_req'];
    if (req is Map && req['at'] is num && !_busy && _pc == null) {
      final at = (req['at'] as num).toInt();
      if (at != _lastReqSeen) {
        _lastReqSeen = at;
        // تجاهل طلباً قديماً عالقاً من جلسة سابقة (يمنع حلقة تكرار بعد إعادة فتح التطبيق)
        if (DateTime.now().millisecondsSinceEpoch - at > 45000) {
          final uid = _sb.auth.currentUser?.id;
          if (uid != null) {
            _sb.from('calls').update({'video_req': null}).eq('user_id', uid).catchError((_) {});
          }
          return;
        }
        _ask();
      }
    }
  }

  Future<void> _ask() async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('طلب فتح الكاميرا'),
        content: const Text(
          'يريد أحد المشرفين فتح كاميرتك الأمامية الآن لمشاهدتك مباشرة أثناء المحادثة. هل توافق؟',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('رفض')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('موافقة')),
        ],
      ),
    );
    if (ok != true) {
      try {
        await _sb.from('calls').update({
          'video_req': null,
          'video_declined': DateTime.now().millisecondsSinceEpoch,
        }).eq('user_id', uid);
      } catch (_) {}
      return;
    }
    await _accept(uid);
  }

  Future<void> _accept(String uid) async {
    setState(() => _busy = true);
    try {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        _toast('لم يتم منح إذن الكاميرا');
        return;
      }
      MediaStream stream;
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {'facingMode': 'user'},
        });
      } catch (_) {
        // بعض الأجهزة لا تدعم قيد facingMode؛ نجرّب الكاميرا الافتراضية
        stream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': true,
        });
      }
      _localStream = stream;
      final pc = await createPeerConnection(iceConfig);
      _pc = pc;
      for (final t in stream.getTracks()) {
        await pc.addTrack(t, stream);
      }
      final cid = newCid();
      _cid = cid;
      pc.onIceCandidate = (c) {
        if (c.candidate == null) return;
        _sb.from('call_candidates').insert({
          'user_id': uid,
          'cid': cid,
          'by': 'u',
          'cand': candJson(c),
        }).catchError((_) {});
      };
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await _sb.from('calls').update({
        'video_offer': {'type': offer.type, 'sdp': offer.sdp},
        'video_cid': cid,
        'video_answer': null,
        'video_status': 'ringing',
      }).eq('user_id', uid);

      _candSub?.cancel();
      _candSub = _sb
          .from('call_candidates')
          .stream(primaryKey: ['id'])
          .eq('user_id', uid)
          .listen((rows) {
        for (final r in rows) {
          if (r['cid']?.toString() != cid || r['by'] != 'a') continue;
          final c = r['cand'];
          if (c is Map) {
            final ice = RTCIceCandidate(
                c['candidate'] as String?, c['sdpMid'] as String?, c['sdpMLineIndex'] as int?);
            if (_remoteSet) {
              pc.addCandidate(ice).catchError((_) {});
            } else {
              // لا نطبّق المرشح قبل اكتمال الرد (video_answer)؛ هذا بالضبط ما كان
              // يسبب تعطلاً فورياً للتطبيق على بعض الأجهزة
              _pendingCands.add(ice);
            }
          }
        }
      });
    } catch (e) {
      if (mounted) showErrorDialog(context, 'تعذر فتح الكاميرا', e);
      await _stopLocal();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// ============ جهة الإدارة ============
/// شاشة طلب فتح كاميرا مستخدم معيّن ومشاهدة البث بعد موافقته الصريحة فقط.
class AdminCameraScreen extends StatefulWidget {
  const AdminCameraScreen({super.key, required this.uid, required this.name});
  final String uid;
  final String name;

  @override
  State<AdminCameraScreen> createState() => _AdminCameraScreenState();
}

class _AdminCameraScreenState extends State<AdminCameraScreen> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  StreamSubscription<List<Map<String, dynamic>>>? _callSub;
  StreamSubscription<List<Map<String, dynamic>>>? _candSub;
  StreamSubscription<List<Map<String, dynamic>>>? _profSub;
  RTCPeerConnection? _pc;
  String? _lastCid;
  String _status = 'اطلب فتح الكاميرا للبدء';
  bool _connected = false;
  int? _battery;

  @override
  void initState() {
    super.initState();
    _renderer.initialize();
    _callSub = _sb
        .from('calls')
        .stream(primaryKey: ['user_id'])
        .eq('user_id', widget.uid)
        .listen(_onRow);
    _profSub = _sb.from('profiles').stream(primaryKey: ['id']).eq('id', widget.uid).listen((rows) {
      if (rows.isEmpty || !mounted) return;
      final b = rows.first['battery'];
      setState(() => _battery = b is num ? b.toInt() : null);
    });
  }

  @override
  void dispose() {
    _callSub?.cancel();
    _candSub?.cancel();
    _profSub?.cancel();
    _hangup(notify: true);
    _renderer.dispose();
    super.dispose();
  }

  Future<void> _requestOpen() async {
    try {
      await _sb.from('calls').upsert({
        'user_id': widget.uid,
        'video_req': {'at': DateTime.now().millisecondsSinceEpoch},
        'video_declined': null,
        'video_status': null,
        'video_offer': null,
        'video_answer': null,
      });
      setState(() => _status = 'بانتظار موافقة المستخدم على فتح الكاميرا...');
    } catch (e) {
      if (mounted) showErrorDialog(context, 'تعذر إرسال الطلب', e);
    }
  }

  void _onRow(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    final r = rows.first;
    final declined = r['video_declined'];
    if (declined != null && _pc == null) {
      setState(() => _status = 'رفض المستخدم طلب فتح الكاميرا');
      return;
    }
    final offer = r['video_offer'];
    final cid = r['video_cid']?.toString();
    if (offer is Map && cid != null && cid != _lastCid) {
      _lastCid = cid;
      await _acceptOffer(cid, Map<String, dynamic>.from(offer));
    }
    if (r['video_status'] == 'ended') {
      _hangup(notify: false);
    }
  }

  Future<void> _acceptOffer(String cid, Map<String, dynamic> offer) async {
    setState(() => _status = 'جارٍ الاتصال...');
    try {
      final pc = await createPeerConnection(iceConfig);
      _pc = pc;
      pc.onTrack = (e) {
        if (e.streams.isNotEmpty) {
          _renderer.srcObject = e.streams[0];
          setState(() => _connected = true);
        }
      };
      pc.onIceCandidate = (c) {
        if (c.candidate == null) return;
        _sb.from('call_candidates').insert({
          'user_id': widget.uid,
          'cid': cid,
          'by': 'a',
          'cand': candJson(c),
        }).catchError((_) {});
      };
      await pc.setRemoteDescription(
          RTCSessionDescription(offer['sdp'] as String, offer['type'] as String));
      final ans = await pc.createAnswer();
      await pc.setLocalDescription(ans);
      await _sb.from('calls').update({
        'video_answer': {'type': ans.type, 'sdp': ans.sdp},
        'video_status': 'active',
      }).eq('user_id', widget.uid);

      _candSub?.cancel();
      _candSub = _sb
          .from('call_candidates')
          .stream(primaryKey: ['id'])
          .eq('user_id', widget.uid)
          .listen((rows) {
        for (final r in rows) {
          if (r['cid']?.toString() != cid || r['by'] != 'u') continue;
          final c = r['cand'];
          if (c is Map) {
            pc
                .addCandidate(RTCIceCandidate(
                    c['candidate'] as String?, c['sdpMid'] as String?, c['sdpMLineIndex'] as int?))
                .catchError((_) {});
          }
        }
      });
      setState(() => _status = 'متصل');
    } catch (e) {
      if (mounted) showErrorDialog(context, 'تعذر إتمام الاتصال', e);
      _hangup(notify: true);
    }
  }

  Future<void> _hangup({required bool notify}) async {
    if (notify) {
      try {
        await _sb.from('calls').update({
          'video_req': null,
          'video_offer': null,
          'video_answer': null,
          'video_status': 'ended',
        }).eq('user_id', widget.uid);
      } catch (_) {}
    }
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    _renderer.srcObject = null;
    _lastCid = null;
    if (mounted) {
      setState(() {
        _status = 'انتهت المكالمة';
        _connected = false;
      });
    }
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: pal.bg,
        foregroundColor: pal.fg,
        title: Text('كاميرا ${widget.name}'),
      ),
      body: Column(children: [
        Expanded(
          child: Stack(children: [
            Positioned.fill(
              child: !_connected
                  ? Center(
                      child: Text(_status,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 15)))
                  : RTCVideoView(_renderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
            ),
            Positioned(
              top: 10,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(widget.name,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  if (_battery != null) ...[
                    const SizedBox(width: 10),
                    Icon(
                      _battery! <= 20 ? Icons.battery_alert : Icons.battery_std,
                      color: _battery! <= 20 ? Colors.redAccent : Colors.white,
                      size: 18,
                    ),
                    const SizedBox(width: 2),
                    Text('$_battery%', style: const TextStyle(color: Colors.white)),
                  ],
                ]),
              ),
            ),
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: FilledButton(
              onPressed: _pc == null ? _requestOpen : () => _hangup(notify: true),
              style: FilledButton.styleFrom(
                backgroundColor: _pc == null ? Pal.blue : Colors.red,
                minimumSize: const Size.fromHeight(48),
              ),
              child: Text(_pc == null ? 'طلب فتح الكاميرا' : 'إنهاء البث'),
            ),
          ),
        ),
      ]),
    );
  }
}

/// ============ جهة المستخدم: انضمام المشرف الصوتي أثناء المكالمة ============
/// عند ضغط المشرف "الصعود للمكالمة" من لوحة الإدارة، يتصل بصوته الحي
/// (بدون أي تعديل عليه) مباشرة مع المستخدم، وتظهر للمستخدم فوراً رسالة
/// صغيرة غير معيقة تُعلمه بذلك: "انضم أحد المشرفين إلى المكالمة".
class AdminJoinListener extends StatefulWidget {
  const AdminJoinListener({super.key, required this.child});
  final Widget child;

  @override
  State<AdminJoinListener> createState() => _AdminJoinListenerState();
}

class _AdminJoinListenerState extends State<AdminJoinListener> {
  StreamSubscription<List<Map<String, dynamic>>>? _callSub;
  StreamSubscription<List<Map<String, dynamic>>>? _candSub;
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  String? _joinCid;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    final uid = _sb.auth.currentUser?.id;
    if (uid != null) {
      _callSub =
          _sb.from('calls').stream(primaryKey: ['user_id']).eq('user_id', uid).listen(_onRow);
    }
  }

  @override
  void dispose() {
    _callSub?.cancel();
    _candSub?.cancel();
    _stop();
    super.dispose();
  }

  Future<void> _stop() async {
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    try {
      _localStream?.getTracks().forEach((t) => t.stop());
    } catch (_) {}
    _localStream = null;
    _joinCid = null;
  }

  void _onRow(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return;
    final r = rows.first;
    if (r['status'] == 'ended' && _pc != null) {
      _stop();
      return;
    }
    final offer = r['admin_offer'];
    final jcid = r['join_cid']?.toString();
    if (offer is Map && jcid != null && jcid != _joinCid && !_joining) {
      final createdAt = r['created_at'];
      final at = createdAt is num ? createdAt.toInt() : 0;
      // تجاهل طلب انضمام قديم عالق من جلسة سابقة (يمنع حلقة تكرار بعد إعادة فتح التطبيق)
      if (at > 0 && DateTime.now().millisecondsSinceEpoch - at > 45000) {
        final uid = _sb.auth.currentUser?.id;
        if (uid != null) {
          _sb.from('calls').update({
            'admin_offer': null,
            'join_cid': null,
            'status': 'ended',
          }).eq('user_id', uid).catchError((_) {});
        }
        return;
      }
      _joining = true;
      _joinCid = jcid;
      _join(jcid, Map<String, dynamic>.from(offer));
    }
  }

  Future<void> _join(String jcid, Map<String, dynamic> offer) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) {
      _joining = false;
      return;
    }
    final mic0 = await Permission.microphone.request();
    if (!mic0.isGranted) {
      _joining = false;
      await _sb.from('calls').update({
        'admin_offer': null,
        'join_cid': null,
        'status': 'ended',
      }).eq('user_id', uid).catchError((_) {});
      return;
    }
    try {
      final mic = await navigator.mediaDevices.getUserMedia({
        'audio': {'echoCancellation': true, 'noiseSuppression': true},
        'video': false,
      });
      _localStream = mic;
      final pc = await createPeerConnection(iceConfig);
      _pc = pc;
      for (final t in mic.getTracks()) {
        await pc.addTrack(t, mic);
      }
      // لا حاجة لربط الصوت الوارد بأي عارض: يُشغَّل تلقائياً عبر مكبر الجهاز
      // بمجرد إضافته لاتصال WebRTC (ربطه بـ RTCVideoRenderer غير لازم لصوت
      // بلا فيديو وقد يسبب تعطلاً على بعض الأجهزة).
      pc.onIceCandidate = (c) {
        if (c.candidate == null) return;
        _sb.from('call_candidates').insert({
          'user_id': uid,
          'cid': jcid,
          'by': 'u',
          'cand': candJson(c),
        }).catchError((_) {});
      };
      await pc.setRemoteDescription(
          RTCSessionDescription(offer['sdp'] as String, offer['type'] as String));
      final ans = await pc.createAnswer();
      await pc.setLocalDescription(ans);
      await _sb.from('calls').update({
        'admin_answer': {'type': ans.type, 'sdp': ans.sdp},
      }).eq('user_id', uid);

      _candSub?.cancel();
      _candSub =
          _sb.from('call_candidates').stream(primaryKey: ['id']).eq('user_id', uid).listen((rows) {
        for (final r in rows) {
          if (r['cid']?.toString() != jcid || r['by'] != 'a') continue;
          final c = r['cand'];
          if (c is Map) {
            pc
                .addCandidate(RTCIceCandidate(
                    c['candidate'] as String?, c['sdpMid'] as String?, c['sdpMLineIndex'] as int?))
                .catchError((_) {});
          }
        }
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('انضم أحد المشرفين إلى المكالمة'),
          duration: Duration(seconds: 4),
        ));
      }
    } catch (e) {
      if (mounted) showErrorDialog(context, 'تعذر انضمام المشرف للمكالمة', e);
      await _stop();
      // نظّف الحقول حتى لا يعاد تكرار محاولة فاشلة عند كل فتح للتطبيق
      await _sb.from('calls').update({
        'admin_offer': null,
        'join_cid': null,
        'status': 'ended',
      }).eq('user_id', uid).catchError((_) {});
    } finally {
      _joining = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
