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
