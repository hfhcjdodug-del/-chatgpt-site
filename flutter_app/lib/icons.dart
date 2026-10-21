import 'dart:math' as math;

import 'package:flutter/material.dart';

/// أيقونة المحادثة المؤقتة (دائرة منقّطة بذيل)
class TempChatPainter extends CustomPainter {
  TempChatPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width * 0.1
      ..strokeCap = StrokeCap.round;
    final c = Offset(s.width * 0.5, s.height * 0.47);
    final r = s.width * 0.36;
    const n = 12;
    for (var i = 0; i < n; i++) {
      final a0 = -math.pi * 0.35 + i * 2 * math.pi / n;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), a0, 2 * math.pi / n * 0.55, false, p);
    }
    canvas.drawLine(
      Offset(s.width * 0.30, s.height * 0.76),
      Offset(s.width * 0.16, s.height * 0.92),
      p,
    );
  }

  @override
  bool shouldRepaint(covariant TempChatPainter old) => old.color != color;
}

/// أيقونة القائمة: سطران، الثاني أقصر
class LinesPainter extends CustomPainter {
  LinesPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width * 0.1
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(s.width * 0.17, s.height * 0.33), Offset(s.width * 0.83, s.height * 0.33), p);
    canvas.drawLine(Offset(s.width * 0.37, s.height * 0.62), Offset(s.width * 0.83, s.height * 0.62), p);
  }

  @override
  bool shouldRepaint(covariant LinesPainter old) => old.color != color;
}

/// أيقونة الموجة الصوتية داخل الزر الأزرق
class WavePainter extends CustomPainter {
  WavePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width * 0.11
      ..strokeCap = StrokeCap.round;
    const xs = [0.17, 0.335, 0.5, 0.665, 0.83];
    const hs = [0.0, 0.17, 0.30, 0.17, 0.0];
    for (var i = 0; i < xs.length; i++) {
      final x = s.width * xs[i];
      final h = s.height * hs[i];
      canvas.drawLine(Offset(x, s.height * 0.5 - h), Offset(x, s.height * 0.5 + h), p);
    }
  }

  @override
  bool shouldRepaint(covariant WavePainter old) => old.color != color;
}

/// زر دائري رمادي داكن (أزرار الشريط العلوي)
class CircleBtn extends StatelessWidget {
  const CircleBtn({super.key, required this.child, required this.onTap, required this.color, this.size = 46});
  final Widget child;
  final VoidCallback onTap;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

/// الكرة الملونة في المحادثة الصوتية
class VoiceBall extends StatelessWidget {
  const VoiceBall({super.key, required this.size, required this.female});
  final double size;
  final bool female;

  @override
  Widget build(BuildContext context) {
    final colors = female
        ? const [Color(0xFFFF7EB6), Color(0xFFFF93C4), Color(0xFFFFEEF6), Color(0xFFFFE0EE)]
        : const [Color(0xFF7B7CFF), Color(0xFF7F90FF), Color(0xFFEEF0FF), Color(0xFFE2E6FF)];
    final glow = female ? const Color(0xFFFFF5FA) : const Color(0xFFF4F5FF);
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: colors,
            stops: const [0.0, 0.42, 0.68, 1.0],
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(0.5, 0.7),
              radius: 0.85,
              colors: [glow, glow, glow.withAlpha(0)],
              stops: const [0.0, 0.38, 0.75],
            ),
          ),
        ),
      ),
    );
  }
}

/// بطاقة الدراجة في شاشة الترحيب (رسم مبسّط)
class BikeCardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    canvas.drawRect(Offset.zero & s, Paint()..color = const Color(0xFFEBD6D1));
    final green = Paint()
      ..color = const Color(0xFF2F4A3E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;
    final gray = Paint()
      ..color = const Color(0xFF7A8A80)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    final thin = Paint()
      ..color = const Color(0xFF7A8A80)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final w = s.width, h = s.height;
    final l = Offset(w * 0.25, h * 0.60), r = Offset(w * 0.80, h * 0.60);
    final rad = w * 0.145;
    for (final c in [l, r]) {
      canvas.drawCircle(c, rad, gray);
      canvas.drawCircle(c, 5, thin);
      for (var k = 0; k < 12; k++) {
        final a = k * math.pi / 6;
        canvas.drawLine(c, c + Offset(math.cos(a), math.sin(a)) * rad, thin);
      }
    }
    final crank = Offset(w * 0.47, h * 0.62);
    final seat = Offset(w * 0.34, h * 0.27);
    final head = Offset(w * 0.68, h * 0.30);
    canvas.drawLine(l, seat, green);
    canvas.drawLine(seat, head, green);
    canvas.drawLine(l, crank, green);
    canvas.drawLine(crank, seat, green);
    canvas.drawLine(crank, head, green);
    canvas.drawLine(head, r, green);
    canvas.drawLine(seat - Offset(w * 0.05, h * 0.03), seat + Offset(w * 0.05, -h * 0.03), green);
    canvas.drawLine(head, head + Offset(w * 0.05, -h * 0.07), green);
    canvas.drawCircle(crank, 9, gray);
    final tag = Paint()..color = const Color(0xFF2F4A3E);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(w * 0.47, h * 0.45), width: 14, height: 14), const Radius.circular(3)), tag);
    // شريط التقدم
    final y = h * 0.90;
    canvas.drawLine(Offset(w * 0.06, y), Offset(w * 0.94, y), Paint()..color = const Color(0xFFE3C2BC)..strokeWidth = 5..strokeCap = StrokeCap.round);
    canvas.drawLine(Offset(w * 0.06, y), Offset(w * 0.46, y), Paint()..color = const Color(0xFF8A8A8A)..strokeWidth = 5..strokeCap = StrokeCap.round);
    canvas.drawCircle(Offset(w * 0.46, y), 6, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant BikeCardPainter old) => false;
}

/// أيقونة PNG بيضاء قابلة للتلوين (مقصوصة من تصميم التطبيق)
class Ic extends StatelessWidget {
  const Ic(this.name, {super.key, required this.size, required this.color});
  final String name;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Image.asset(
        'assets/icons/$name.png',
        width: size,
        height: size,
        color: color,
        filterQuality: FilterQuality.high,
      );
}

/// ثلاث نقاط عمودية ⋮
class Dots3 extends StatelessWidget {
  const Dots3({super.key, this.color = Colors.white, this.size = 5});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var k = 0; k < 3; k++)
            Container(
              width: size,
              height: size,
              margin: EdgeInsets.symmetric(vertical: size * 0.4),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
        ],
      );
}

/// نجمة رباعية (✦) في زر Plus
class SparklePainter extends CustomPainter {
  SparklePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final k = s.width / 24;
    Offset o(double x, double y) => Offset(x * k, y * k);
    final p = Path()
      ..moveTo(12 * k, 1.5 * k)
      ..cubicTo(12.9 * k, 7.6 * k, 16.4 * k, 11.1 * k, 22.5 * k, 12 * k)
      ..cubicTo(16.4 * k, 12.9 * k, 12.9 * k, 16.4 * k, 12 * k, 22.5 * k)
      ..cubicTo(11.1 * k, 16.4 * k, 7.6 * k, 12.9 * k, 1.5 * k, 12 * k)
      ..cubicTo(7.6 * k, 11.1 * k, 11.1 * k, 7.6 * k, 12 * k, 1.5 * k)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
    o(0, 0);
  }

  @override
  bool shouldRepaint(covariant SparklePainter old) => old.color != color;
}
