import 'package:flutter/material.dart';

// مفتاح عام (publishable) آمن داخل التطبيق — الحماية عبر سياسات RLS في Supabase
const supabaseUrl = 'https://deqgwromjujrxunjvmuz.supabase.co';
const supabaseKey = 'sb_publishable_i4FV3xGkbSxcXk9Givr60A_GzKrA8yS';

// وسيط الذكاء الاصطناعي (Cloudflare Worker)
const defaultAiUrl = 'https://small-snow-a143.jadocool0427.workers.dev/';

// وضع الثيم (فاتح / داكن)
final ValueNotifier<ThemeMode> themeMode = ValueNotifier<ThemeMode>(ThemeMode.light);
