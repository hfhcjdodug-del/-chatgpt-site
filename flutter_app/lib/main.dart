import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_screen.dart';
import 'config.dart';
import 'login_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // في نسخة release تظهر أخطاء البناء كمربع رمادي؛ نعرض النص بدلاً منه للتشخيص
  ErrorWidget.builder = (FlutterErrorDetails d) => Container(
        color: Colors.white,
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Text(
            d.exceptionAsString(),
            textDirection: TextDirection.ltr,
            style: const TextStyle(color: Colors.red, fontSize: 12),
          ),
        ),
      );
  runApp(const Boot());
}

/// يشغّل التهيئة ويعرض شاشة انتظار أو رسالة الخطأ بدل الشاشة السوداء
class Boot extends StatefulWidget {
  const Boot({super.key});

  @override
  State<Boot> createState() => _BootState();
}

class _BootState extends State<Boot> {
  late final Future<void> _ready = _init();

  Future<void> _init() async {
    await Supabase.initialize(url: supabaseUrl, anonKey: supabaseKey)
        .timeout(const Duration(seconds: 20));
    final prefs = await SharedPreferences.getInstance();
    themeMode.value =
        prefs.getString('aiTheme') == 'dark' ? ThemeMode.dark : ThemeMode.light;
  }

  Widget _plain(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.white,
          body: SafeArea(child: Center(child: child)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snap) {
        if (snap.hasError) {
          return _plain(SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: SelectableText(
              'تعذر تشغيل التطبيق:\n${snap.error}',
              textDirection: TextDirection.ltr,
              style: const TextStyle(color: Colors.red, fontSize: 14),
            ),
          ));
        }
        if (snap.connectionState != ConnectionState.done) {
          return _plain(const CircularProgressIndicator());
        }
        return const AiApp();
      },
    );
  }
}

class AiApp extends StatelessWidget {
  const AiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeMode,
      builder: (context, mode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'ChatGPT',
          themeMode: mode,
          theme: ThemeData(
            brightness: Brightness.light,
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF1173D4),
            scaffoldBackgroundColor: Colors.white,
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF1173D4),
            scaffoldBackgroundColor: const Color(0xFF212121),
          ),
          builder: (context, child) => Directionality(
            textDirection: TextDirection.rtl,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const AuthGate(),
        );
      },
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session == null) return const LoginScreen();
        return ChatScreen(key: ValueKey(session.user.id));
      },
    );
  }
}
