import 'package:flutter/material.dart';

/// ألوان التصميم (مأخوذة من شكل ChatGPT الداكن السابق)
class Pal {
  const Pal(this.dark);
  final bool dark;

  static Pal of(BuildContext c) => Pal(Theme.of(c).brightness == Brightness.dark);

  static const Color blue = Color(0xFF3566EF);
  static const Color green = Color(0xFF27AA5E);

  Color get bg => dark ? Colors.black : Colors.white;
  Color get fg => dark ? const Color(0xFFF4F4F4) : Colors.black;
  Color get mut => dark ? const Color(0xFF9D9D9D) : const Color(0xFF6B6B70);
  Color get bar => dark ? const Color(0xFF303030) : const Color(0xFFEFEFF0);
  Color get circle => bar;
  Color get side => dark ? const Color(0xFF212121) : const Color(0xFFFAFAFA);
  Color get line => dark ? const Color(0xFF414141) : const Color(0xFFE7E7E9);
  Color get bub => dark ? const Color(0xFF0A1170) : const Color(0xFFE8F3FF);
  Color get bubt => dark ? Colors.white : const Color(0xFF1173D4);
  Color get pill => dark ? const Color(0xFF33414F) : const Color(0xFFE6F2FF);
  Color get pillt => dark ? const Color(0xFF5CA8FF) : const Color(0xFF0A84FF);
  Color get sheet => dark ? const Color(0xFF2A2A2D) : const Color(0xFFF7F7F8);
  Color get sheetIcon => dark ? const Color(0xFF3A3A3D) : const Color(0xFFEDEDEE);
  Color get code => dark ? const Color(0xFF1E1E20) : const Color(0xFFF7F7F8);
}
