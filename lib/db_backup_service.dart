// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

/// ── DbBackupService ──────────────────────────────────────────────────────────
/// Backup  → runs mysqldump, saves a timestamped .sql to the user's Downloads.
/// Restore → lets the user pick a .sql file, then pipes it into mysql.
class DbBackupService {
  static const _host = 'localhost';
  static const _port = '3306';
  static const _user = 'root';
  static const _pass = 'root';
  static const _db   = 'roboventuredb';

  // ── Auto-detect mysqldump / mysql path ─────────────────────────────────────
  /// Searches common MySQL install locations on Windows.
  /// Returns the full path if found, or just 'mysqldump'/'mysql' as fallback.
  static String _findMysqlBin(String executable) {
    if (!Platform.isWindows) return executable; // Linux/macOS rely on PATH

    final candidates = [
      // XAMPP (most common on Windows dev machines)
      r'C:\xampp\mysql\bin',
      r'D:\xampp\mysql\bin',
      // MySQL Community Installer — check versions 8.x and 5.x
      for (final ver in ['8.4', '8.3', '8.2', '8.1', '8.0', '5.7', '5.6'])
        'C:\\Program Files\\MySQL\\MySQL Server $ver\\bin',
      // WAMP
      r'C:\wamp64\bin\mysql\mysql8.0.31\bin',
      r'C:\wamp\bin\mysql\mysql5.7.36\bin',
      // MariaDB
      r'C:\Program Files\MariaDB 10.11\bin',
      r'C:\Program Files\MariaDB 10.6\bin',
    ];

    for (final dir in candidates) {
      final file = File('$dir\\$executable.exe');
      if (file.existsSync()) {
        print('✅ Found $executable at: ${file.path}');
        return file.path;
      }
    }

    // Dynamic scan: look inside Program Files\MySQL for any version folder
    final mysqlRoot = Directory(r'C:\Program Files\MySQL');
    if (mysqlRoot.existsSync()) {
      try {
        for (final entity in mysqlRoot.listSync()) {
          if (entity is Directory) {
            final file = File('${entity.path}\\bin\\$executable.exe');
            if (file.existsSync()) {
              print('✅ Found $executable at: ${file.path}');
              return file.path;
            }
          }
        }
      } catch (_) {}
    }

    print('⚠️  $executable not found in known paths, falling back to PATH');
    return executable; // fallback — works if PATH is set
  }

  // ── Timestamp ──────────────────────────────────────────────────────────────
  static String _ts() {
    final n = DateTime.now();
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${p(n.year, 4)}${p(n.month)}${p(n.day)}_'
        '${p(n.hour)}${p(n.minute)}${p(n.second)}';
  }

  // ── Downloads folder ───────────────────────────────────────────────────────
  static Directory _downloadsDir() {
    final profile = Platform.environment['USERPROFILE'];
    if (profile != null) {
      final d = Directory('$profile\\Downloads');
      if (d.existsSync()) return d;
    }
    final home = Platform.environment['HOME'];
    if (home != null) {
      final d = Directory('$home/Downloads');
      if (d.existsSync()) return d;
    }
    return Directory.current;
  }

  // ── Backup ─────────────────────────────────────────────────────────────────
  static Future<String?> backupDatabase(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _BackupConfirmDialog(),
    );
    if (confirmed != true) return null;

    _snack(context, '⏳ Creating backup…', Colors.blueGrey, seconds: 10);

    try {
      final dir         = _downloadsDir();
      final sep         = Platform.pathSeparator;
      final path        = '${dir.path}${sep}roboventure_backup_${_ts()}.sql';
      final mysqldump   = _findMysqlBin('mysqldump');

      final result = await Process.run(
        mysqldump,
        [
          '-h', _host,
          '-P', _port,
          '-u', _user,
          '-p$_pass',
          '--single-transaction',
          '--routines',
          '--triggers',
          _db,
        ],
        runInShell: true,
      );

      if (result.exitCode != 0) {
        final err = (result.stderr as String).trim();
        _snack(context, '❌ Backup failed: $err', Colors.red);
        return null;
      }

      await File(path).writeAsString(result.stdout as String);
      _snack(context, '✅ Backup saved → ${dir.path}', Colors.green);
      print('✅ Backup written to $path');
      return path;
    } catch (e) {
      _snack(context, '❌ Backup error: $e', Colors.red);
      return null;
    }
  }

  // ── Restore ────────────────────────────────────────────────────────────────
  static Future<bool> restoreDatabase(BuildContext context) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['sql'],
      dialogTitle: 'Select backup file (.sql)',
    );
    if (picked == null || picked.files.single.path == null) return false;
    final path = picked.files.single.path!;

    if (!context.mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RestoreConfirmDialog(
        filename: path.split(Platform.pathSeparator).last,
      ),
    );
    if (confirmed != true) return false;

    _snack(context, '⏳ Restoring database…', Colors.orange, seconds: 15);

    try {
      final sqlContent  = await File(path).readAsString();
      final mysql       = _findMysqlBin('mysql');

      final proc = await Process.start(
        mysql,
        ['-h', _host, '-P', _port, '-u', _user, '-p$_pass', _db],
        runInShell: true,
      );

      proc.stdin.write(sqlContent);
      await proc.stdin.close();

      final exitCode = await proc.exitCode;
      if (exitCode != 0) {
        final err = await proc.stderr
            .transform(const SystemEncoding().decoder)
            .join();
        _snack(context, '❌ Restore failed: $err', Colors.red);
        return false;
      }

      _snack(context, '✅ Database restored successfully!', Colors.green);
      print('✅ Restore from $path complete.');
      return true;
    } catch (e) {
      _snack(context, '❌ Restore error: $e', Colors.red);
      return false;
    }
  }

  // ── SnackBar helper ────────────────────────────────────────────────────────
  static void _snack(
    BuildContext ctx,
    String msg,
    Color color, {
    int seconds = 3,
  }) {
    if (!ctx.mounted) return;
    ScaffoldMessenger.of(ctx)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: color,
        duration: Duration(seconds: seconds),
      ));
  }
}

// ── Backup confirmation dialog ────────────────────────────────────────────────
class _BackupConfirmDialog extends StatelessWidget {
  const _BackupConfirmDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A0A4A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF00CFFF), width: 1.5),
      ),
      title: const Row(children: [
        Icon(Icons.cloud_upload_rounded, color: Color(0xFF00CFFF), size: 22),
        SizedBox(width: 10),
        Text('Backup Database',
            style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 18)),
      ]),
      content: const Text(
        'This will create a full SQL dump of roboventuredb '
        'and save it to your Downloads folder.\n\nProceed?',
        style: TextStyle(color: Colors.white70, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.save_alt_rounded, size: 16),
          label: const Text('Create Backup'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00CFFF),
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}

// ── Restore confirmation dialog ───────────────────────────────────────────────
class _RestoreConfirmDialog extends StatelessWidget {
  final String filename;
  const _RestoreConfirmDialog({required this.filename});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A0A4A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFFF6B6B), width: 1.5),
      ),
      title: const Row(children: [
        Icon(Icons.warning_amber_rounded, color: Color(0xFFFF6B6B), size: 22),
        SizedBox(width: 10),
        Text('Restore Database',
            style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 18)),
      ]),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '⚠️  This will OVERWRITE all current data in '
            'roboventuredb with the contents of:',
            style: TextStyle(color: Colors.white70, height: 1.5),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFF6B6B).withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFF6B6B).withOpacity(0.4)),
            ),
            child: Text(filename,
                style: const TextStyle(
                    color: Color(0xFFFF6B6B),
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
          ),
          const SizedBox(height: 10),
          const Text('This action cannot be undone.',
              style: TextStyle(
                  color: Color(0xFFFF9F43), fontWeight: FontWeight.bold)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.restore_rounded, size: 16),
          label: const Text('Restore'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFF6B6B),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}