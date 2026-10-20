import 'dart:io';

/// تخزين بسيط في ملفات داخل مجلد التطبيق الخاص (بدون مكتبة shared_preferences)
class KvStore {
  KvStore._();
  static final KvStore instance = KvStore._();

  Directory? _dir;

  Future<File?> _file(String key) async {
    try {
      // مجلد cache هو systemTemp في أندرويد، ومجلد files شقيقه داخل مجلد التطبيق
      _dir ??= Directory('${Directory.systemTemp.parent.path}/files');
      if (!await _dir!.exists()) await _dir!.create(recursive: true);
      final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
      return File('${_dir!.path}/kv_$safe.txt');
    } catch (_) {
      return null;
    }
  }

  Future<String?> get(String key) async {
    try {
      final f = await _file(key);
      if (f == null || !await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> set(String key, String value) async {
    try {
      final f = await _file(key);
      if (f != null) await f.writeAsString(value, flush: true);
    } catch (_) {}
  }

  Future<void> remove(String key) async {
    try {
      final f = await _file(key);
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }
}
