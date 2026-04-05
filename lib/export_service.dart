// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:excel/excel.dart' as xl;
import 'db_helper.dart';

/// ── ExportService ────────────────────────────────────────────────────────────
/// Static helpers to export standings and attendance data.
///
/// PDF  → uses Printing.layoutPdf() — opens the system print/save dialog,
///         exactly the same way schedule_viewer.dart already does it.
/// Excel → saves a timestamped .xlsx to the user's Downloads folder via
///         dart:io (no path_provider needed).
///
/// Only packages already present in pubspec.yaml are used:
///   pdf, printing, excel, dart:io, flutter/material.
class ExportService {
  // ── PDF colours ────────────────────────────────────────────────────────────
  static const _accentBg = PdfColor.fromInt(0xFF5C2ECC);
  static const _rowEven  = PdfColor.fromInt(0xFFF0EEFF);
  static const _textHead = PdfColors.white;
  static const _textDark = PdfColors.black;

  // ── Timestamp — no intl ────────────────────────────────────────────────────
  static String _ts() {
    final n = DateTime.now();
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${p(n.year, 4)}${p(n.month)}${p(n.day)}_'
        '${p(n.hour)}${p(n.minute)}${p(n.second)}';
  }

  static String _pretty() {
    final n = DateTime.now();
    const months = [
      '', 'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    final h    = n.hour % 12 == 0 ? 12 : n.hour % 12;
    final ampm = n.hour < 12 ? 'AM' : 'PM';
    String p(int v) => v.toString().padLeft(2, '0');
    return '${months[n.month]} ${n.day}, ${n.year} '
        '– ${p(h)}:${p(n.minute)} $ampm';
  }

  // ── Downloads folder — no path_provider ───────────────────────────────────
  static Directory _downloadsDir() {
    final profile = Platform.environment['USERPROFILE']; // Windows
    if (profile != null) {
      final d = Directory('$profile\\Downloads');
      if (d.existsSync()) return d;
    }
    final home = Platform.environment['HOME']; // macOS / Linux
    if (home != null) {
      final d = Directory('$home/Downloads');
      if (d.existsSync()) return d;
    }
    return Directory.current;
  }

  // ────────────────────────────────────────────────────────────────────────────
  //  STANDINGS  →  PDF
  // ────────────────────────────────────────────────────────────────────────────
  static Future<void> exportStandingsToPdf({
    required BuildContext context,
    required List<Map<String, String?>> categories,
    required Map<int, List<Map<String, dynamic>>> standingsByCategory,
    required List<SoccerGroupExport> soccerGroups,
  }) async {
    try {
      _snack(context, '⏳ Opening PDF…', Colors.blueGrey);
      final doc = pw.Document();

      for (final cat in categories) {
        final catId    = int.tryParse(cat['category_id'].toString()) ?? 0;
        final catName  = (cat['category_type'] ?? '').toUpperCase();
        final isSoccer = catName.toLowerCase().contains('soccer');

        if (isSoccer) {
          doc.addPage(_buildSoccerPdfPage(catName, soccerGroups));
        } else {
          final rows      = standingsByCategory[catId] ?? [];
          final isTimer   = _isTimerCategory(catName);
          final maxRounds = rows.isNotEmpty
              ? (rows.first['maxRounds'] as int? ?? 2)
              : 2;
          doc.addPage(
              _buildStandingsPdfPage(catName, rows, isTimer, maxRounds));
        }
      }

      // Reuse the same pattern as schedule_viewer.dart
      await Printing.layoutPdf(
        onLayout: (_) async => doc.save(),
        name: 'standings_${_ts()}.pdf',
      );
    } catch (e) {
      _snack(context, '❌ PDF export failed: $e', Colors.red);
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  //  STANDINGS  →  EXCEL
  // ────────────────────────────────────────────────────────────────────────────
  static Future<void> exportStandingsToExcel({
    required BuildContext context,
    required List<Map<String, String?>> categories,
    required Map<int, List<Map<String, dynamic>>> standingsByCategory,
    required List<SoccerGroupExport> soccerGroups,
  }) async {
    try {
      _snack(context, '⏳ Generating Excel…', Colors.blueGrey);
      final excel    = xl.Excel.createExcel();
      bool firstSheet = true;

      for (final cat in categories) {
        final catId    = int.tryParse(cat['category_id'].toString()) ?? 0;
        final catName  = (cat['category_type'] ?? '').toUpperCase();
        final isSoccer = catName.toLowerCase().contains('soccer');

        xl.Sheet sheet;
        if (firstSheet) {
          final def = excel.getDefaultSheet()!;
          excel.rename(def, catName);
          sheet = excel[catName];
          firstSheet = false;
        } else {
          excel[catName];
          sheet = excel[catName];
        }

        if (isSoccer) {
          _fillSoccerSheet(sheet, catName, soccerGroups);
        } else {
          final rows      = standingsByCategory[catId] ?? [];
          final isTimer   = _isTimerCategory(catName);
          final maxRounds = rows.isNotEmpty
              ? (rows.first['maxRounds'] as int? ?? 2)
              : 2;
          _fillStandingsSheet(sheet, catName, rows, isTimer, maxRounds);
        }
      }

      final bytes    = excel.save()!;
      final filename = 'standings_${_ts()}.xlsx';
      await _saveExcel(context, Uint8List.fromList(bytes), filename);
    } catch (e) {
      _snack(context, '❌ Excel export failed: $e', Colors.red);
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  //  ATTENDANCE  →  PDF
  // ────────────────────────────────────────────────────────────────────────────
  static Future<void> exportAttendanceToPdf(BuildContext context) async {
    try {
      _snack(context, '⏳ Opening attendance PDF…', Colors.blueGrey);
      final data = await _fetchAttendanceData();
      final doc  = pw.Document();
      doc.addPage(_buildAttendancePdfPage(data));

      await Printing.layoutPdf(
        onLayout: (_) async => doc.save(),
        name: 'attendance_${_ts()}.pdf',
      );
    } catch (e) {
      _snack(context, '❌ Attendance PDF failed: $e', Colors.red);
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  //  ATTENDANCE  →  EXCEL
  // ────────────────────────────────────────────────────────────────────────────
  static Future<void> exportAttendanceToExcel(BuildContext context) async {
    try {
      _snack(context, '⏳ Generating attendance Excel…', Colors.blueGrey);
      final data  = await _fetchAttendanceData();
      final excel = xl.Excel.createExcel();
      final def   = excel.getDefaultSheet()!;
      excel.rename(def, 'Attendance');
      _fillAttendanceSheet(excel['Attendance'], data);
      final bytes    = excel.save()!;
      final filename = 'attendance_${_ts()}.xlsx';
      await _saveExcel(context, Uint8List.fromList(bytes), filename);
    } catch (e) {
      _snack(context, '❌ Attendance Excel failed: $e', Colors.red);
    }
  }

  // ── Fetch attendance data ──────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> _fetchAttendanceData() async {
    final conn = await DBHelper.getConnection();
    final res  = await conn.execute('''
      SELECT
        t.team_id,
        t.team_name,
        c.category_type,
        s.school_name,
        COUNT(DISTINCT p.player_id)     AS player_count,
        COUNT(DISTINCT m.mentor_id)     AS mentor_count,
        COUNT(DISTINCT ts.match_id)     AS matches_scheduled,
        COUNT(DISTINCT sc.score_id)     AS matches_scored
      FROM tbl_team t
      LEFT JOIN tbl_category     c  ON c.category_id  = t.category_id
      LEFT JOIN tbl_mentor       m  ON m.mentor_id    = t.mentor_id
      LEFT JOIN tbl_school       s  ON s.school_id    = m.school_id
      LEFT JOIN tbl_player       p  ON p.team_id      = t.team_id
      LEFT JOIN tbl_teamschedule ts ON ts.team_id    = t.team_id
      LEFT JOIN tbl_score        sc ON sc.team_id    = t.team_id
      GROUP BY t.team_id, t.team_name, c.category_type, s.school_name
      ORDER BY c.category_type, t.team_name
    ''');
    return res.rows
        .map((r) => r.assoc() as Map<String, dynamic>)
        .toList();
  }

  // ────────────────────────────────────────────────────────────────────────────
  //  PDF page builders
  // ────────────────────────────────────────────────────────────────────────────

  static pw.Page _buildStandingsPdfPage(
    String catName,
    List<Map<String, dynamic>> rows,
    bool isTimer,
    int maxRounds,
  ) {
    return pw.Page(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          _pdfTitle('RoboVenture – $catName Standings'),
          _pdfSubtitle('Generated: ${_pretty()}'),
          pw.SizedBox(height: 10),
          _buildStandingsTable(rows, isTimer, maxRounds),
        ],
      ),
    );
  }

  static pw.Page _buildSoccerPdfPage(
    String catName,
    List<SoccerGroupExport> groups,
  ) {
    // Build a flat sorted list from all groups
    final all = <Map<String, dynamic>>[];
    for (final g in groups) {
      for (final t in g.teams) {
        all.add({
          'rank': 0,
          'group': g.label,
          'team_name': t.teamName,
          'mp': t.matchesPlayed,
          'w': t.wins,
          'd': t.draws,
          'l': t.losses,
          'gf': t.goalsFor,
          'ga': t.goalsAgainst,
          'gd': t.goalDiff,
          'pts': t.points,
        });
      }
    }
    all.sort((a, b) {
      if (b['pts'] != a['pts'])
        return (b['pts'] as int).compareTo(a['pts'] as int);
      if (b['gd'] != a['gd'])
        return (b['gd'] as int).compareTo(a['gd'] as int);
      return (b['gf'] as int).compareTo(a['gf'] as int);
    });
    for (int i = 0; i < all.length; i++) all[i]['rank'] = i + 1;

    return pw.Page(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          _pdfTitle('RoboVenture – $catName Standings'),
          _pdfSubtitle('Generated: ${_pretty()}'),
          pw.SizedBox(height: 10),
          _buildSoccerTable(all),
        ],
      ),
    );
  }

  static pw.Page _buildAttendancePdfPage(
      List<Map<String, dynamic>> data) {
    return pw.Page(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          _pdfTitle('RoboVenture – Attendance Report'),
          _pdfSubtitle('Generated: ${_pretty()}'),
          pw.SizedBox(height: 10),
          _buildAttendanceTable(data),
        ],
      ),
    );
  }

  // ── PDF table builders ────────────────────────────────────────────────────

  static pw.Widget _buildStandingsTable(
    List<Map<String, dynamic>> rows,
    bool isTimer,
    int maxRounds,
  ) {
    final roundHeaders = List.generate(
        maxRounds, (i) => isTimer ? 'Run ${i + 1} Time' : 'Run ${i + 1}');
    final lastHeader = isTimer ? 'Best Time' : 'Total Pts';
    final headers    = ['#', 'ID', 'Team', ...roundHeaders, lastHeader];
    final colWidths  = [
      30.0, 50.0, 150.0,
      ...List.filled(maxRounds, 70.0),
      70.0,
    ];

    return _pdfTable(
      headers: headers,
      colWidths: colWidths,
      rows: rows.asMap().entries.map((e) {
        final i      = e.key;
        final row    = e.value;
        final rank   = (row['rank'] as int? ?? i + 1);
        final teamId = row['team_id'] as int;
        final rounds =
            (row['rounds'] as Map<int, Map<String, dynamic>>?) ?? {};
        final cells = <String>[
          '$rank',
          'C${teamId.toString().padLeft(3, '0')}R',
          (row['team_name'] as String).toUpperCase(),
        ];
        for (int r = 1; r <= maxRounds; r++) {
          final d = rounds[r];
          cells.add(isTimer
              ? _fmtDuration(d?['duration'] as String?)
              : (d?['score'] != null ? '${d!['score']}' : '—'));
        }
        cells.add(isTimer
            ? (row['bestTimeStr'] as String? ?? '—')
            : '${row['totalScore'] as int? ?? 0}');
        return cells;
      }).toList(),
    );
  }

  static pw.Widget _buildSoccerTable(List<Map<String, dynamic>> rows) {
    return _pdfTable(
      headers: [
        '#', 'Grp', 'Team', 'MP', 'W', 'D', 'L', 'GF', 'GA', 'GD', 'Pts'
      ],
      colWidths: [30, 30, 160, 35, 35, 35, 35, 35, 35, 40, 40],
      rows: rows.map((r) {
        final gd = r['gd'] as int;
        return [
          '${r['rank']}',
          r['group'] as String,
          (r['team_name'] as String).toUpperCase(),
          '${r['mp']}',
          '${r['w']}',
          '${r['d']}',
          '${r['l']}',
          '${r['gf']}',
          '${r['ga']}',
          gd > 0 ? '+$gd' : '$gd',
          '${r['pts']}',
        ];
      }).toList(),
    );
  }

  static pw.Widget _buildAttendanceTable(
      List<Map<String, dynamic>> data) {
    return _pdfTable(
      headers: [
        '#', 'Team', 'Category', 'School',
        'Players', 'Mentors', 'Scheduled', 'Scored',
      ],
      colWidths: [30, 150, 90, 120, 50, 50, 60, 50],
      rows: data.asMap().entries.map((e) => [
        '${e.key + 1}',
        (e.value['team_name']     as String? ?? '').toUpperCase(),
        (e.value['category_type'] as String? ?? '').toUpperCase(),
        e.value['school_name']            as String? ?? '—',
        '${e.value['player_count']        ?? 0}',
        '${e.value['mentor_count']        ?? 0}',
        '${e.value['matches_scheduled']   ?? 0}',
        '${e.value['matches_scored']      ?? 0}',
      ]).toList(),
    );
  }

  // ── Generic PDF table ─────────────────────────────────────────────────────
  static pw.Widget _pdfTable({
    required List<String> headers,
    required List<double> colWidths,
    required List<List<String>> rows,
  }) {
    return pw.Table(
      columnWidths: {
        for (int i = 0; i < colWidths.length; i++)
          i: pw.FixedColumnWidth(colWidths[i]),
      },
      border: pw.TableBorder.all(
          color: const PdfColor.fromInt(0xFFCCCCCC), width: 0.5),
      children: [
        // Header
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _accentBg),
          children: headers
              .map((h) => pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 6, vertical: 5),
                    child: pw.Text(h,
                        style: pw.TextStyle(
                            color: _textHead,
                            fontWeight: pw.FontWeight.bold,
                            fontSize: 9)),
                  ))
              .toList(),
        ),
        // Data rows
        ...rows.asMap().entries.map((e) {
          final rank = int.tryParse(e.value.first) ?? (e.key + 1);
          final bg = rank == 1
              ? const PdfColor.fromInt(0xFFFFF8DC)
              : rank == 2
                  ? const PdfColor.fromInt(0xFFF5F5F5)
                  : rank == 3
                      ? const PdfColor.fromInt(0xFFFFF3E0)
                      : e.key % 2 == 0
                          ? _rowEven
                          : PdfColors.white;
          return pw.TableRow(
            decoration: pw.BoxDecoration(color: bg),
            children: e.value
                .map((cell) => pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: pw.Text(cell,
                          style: pw.TextStyle(
                              fontSize: 8, color: _textDark)),
                    ))
                .toList(),
          );
        }),
      ],
    );
  }

  static pw.Widget _pdfTitle(String text) => pw.Text(text,
      style: pw.TextStyle(
          fontSize: 16,
          fontWeight: pw.FontWeight.bold,
          color: const PdfColor.fromInt(0xFF2D0E7A)));

  static pw.Widget _pdfSubtitle(String text) => pw.Text(text,
      style: pw.TextStyle(
          fontSize: 9,
          color: const PdfColor.fromInt(0xFF888888)));

  // ────────────────────────────────────────────────────────────────────────────
  //  Excel sheet fillers
  // ────────────────────────────────────────────────────────────────────────────

  static void _fillStandingsSheet(
    xl.Sheet sheet,
    String catName,
    List<Map<String, dynamic>> rows,
    bool isTimer,
    int maxRounds,
  ) {
    final roundHeaders = List.generate(
        maxRounds, (i) => isTimer ? 'Run ${i + 1} Time' : 'Run ${i + 1}');
    final headers = [
      'Rank', 'ID', 'Team Name',
      ...roundHeaders,
      isTimer ? 'Best Time' : 'Total Score',
    ];

    sheet.cell(xl.CellIndex.indexByString('A1')).value =
        xl.TextCellValue('RoboVenture – $catName Standings');
    sheet.cell(xl.CellIndex.indexByString('A2')).value =
        xl.TextCellValue('Generated: ${_pretty()}');

    // Header row (row index 3 = row 4 in Excel)
    for (int c = 0; c < headers.length; c++) {
      final cell = sheet.cell(
          xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 3));
      cell.value = xl.TextCellValue(headers[c]);
      cell.cellStyle = xl.CellStyle(bold: true);
    }

    // Data rows
    for (int i = 0; i < rows.length; i++) {
      final row    = rows[i];
      final rank   = (row['rank'] as int? ?? i + 1);
      final teamId = row['team_id'] as int;
      final rounds =
          (row['rounds'] as Map<int, Map<String, dynamic>>?) ?? {};
      int col = 0;

      void write(dynamic v) {
        sheet.cell(xl.CellIndex.indexByColumnRow(
            columnIndex: col++, rowIndex: 4 + i))
          ..value = v is int
              ? xl.IntCellValue(v)
              : xl.TextCellValue(v.toString());
      }

      write(rank);
      write('C${teamId.toString().padLeft(3, '0')}R');
      write((row['team_name'] as String).toUpperCase());
      for (int r = 1; r <= maxRounds; r++) {
        final d = rounds[r];
        if (isTimer) {
          write(_fmtDuration(d?['duration'] as String?));
        } else {
          final sc = d?['score'] as int?;
          write(sc ?? '—');
        }
      }
      write(isTimer
          ? (row['bestTimeStr'] as String? ?? '—')
          : (row['totalScore'] as int? ?? 0));
    }
  }

  static void _fillSoccerSheet(
    xl.Sheet sheet,
    String catName,
    List<SoccerGroupExport> groups,
  ) {
    final all = <List<dynamic>>[];
    for (final g in groups) {
      for (final t in g.teams) {
        all.add([
          g.label,
          t.teamName.toUpperCase(),
          t.matchesPlayed,
          t.wins,
          t.draws,
          t.losses,
          t.goalsFor,
          t.goalsAgainst,
          t.goalDiff,
          t.points,
        ]);
      }
    }
    all.sort((a, b) {
      if (b[9] != a[9]) return (b[9] as int).compareTo(a[9] as int);
      if (b[8] != a[8]) return (b[8] as int).compareTo(a[8] as int);
      return (b[6] as int).compareTo(a[6] as int);
    });

    sheet.cell(xl.CellIndex.indexByString('A1')).value =
        xl.TextCellValue('RoboVenture – $catName Standings');
    sheet.cell(xl.CellIndex.indexByString('A2')).value =
        xl.TextCellValue('Generated: ${_pretty()}');

    final headers = [
      '#', 'Group', 'Team', 'MP', 'W', 'D', 'L',
      'GF', 'GA', 'GD', 'Pts',
    ];
    for (int c = 0; c < headers.length; c++) {
      final cell = sheet.cell(
          xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 3));
      cell.value = xl.TextCellValue(headers[c]);
      cell.cellStyle = xl.CellStyle(bold: true);
    }

    for (int i = 0; i < all.length; i++) {
      final r      = all[i];
      final values = <dynamic>[i + 1, ...r];
      for (int c = 0; c < values.length; c++) {
        final v = values[c];
        sheet.cell(xl.CellIndex.indexByColumnRow(
            columnIndex: c, rowIndex: 4 + i))
          ..value = v is int
              ? xl.IntCellValue(v)
              : xl.TextCellValue(v.toString());
      }
    }
  }

  static void _fillAttendanceSheet(
    xl.Sheet sheet,
    List<Map<String, dynamic>> data,
  ) {
    sheet.cell(xl.CellIndex.indexByString('A1')).value =
        xl.TextCellValue('RoboVenture – Attendance Report');
    sheet.cell(xl.CellIndex.indexByString('A2')).value =
        xl.TextCellValue('Generated: ${_pretty()}');

    final headers = [
      '#', 'Team Name', 'Category', 'School',
      'Players', 'Mentors', 'Matches Scheduled', 'Matches Scored',
    ];
    for (int c = 0; c < headers.length; c++) {
      final cell = sheet.cell(
          xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 3));
      cell.value = xl.TextCellValue(headers[c]);
      cell.cellStyle = xl.CellStyle(bold: true);
    }

    for (int i = 0; i < data.length; i++) {
      final row    = data[i];
      final values = <dynamic>[
        i + 1,
        (row['team_name']     as String? ?? '').toUpperCase(),
        (row['category_type'] as String? ?? '').toUpperCase(),
        row['school_name']               as String? ?? '—',
        int.tryParse(row['player_count']?.toString()      ?? '0') ?? 0,
        int.tryParse(row['mentor_count']?.toString()      ?? '0') ?? 0,
        int.tryParse(row['matches_scheduled']?.toString() ?? '0') ?? 0,
        int.tryParse(row['matches_scored']?.toString()    ?? '0') ?? 0,
      ];
      for (int c = 0; c < values.length; c++) {
        final v = values[c];
        sheet.cell(xl.CellIndex.indexByColumnRow(
            columnIndex: c, rowIndex: 4 + i))
          ..value = v is int
              ? xl.IntCellValue(v)
              : xl.TextCellValue(v.toString());
      }
    }
  }

  // ── Save Excel to Downloads ────────────────────────────────────────────────
  static Future<void> _saveExcel(
    BuildContext context,
    Uint8List bytes,
    String filename,
  ) async {
    try {
      final dir  = _downloadsDir();
      final sep  = Platform.pathSeparator;
      final path = '${dir.path}$sep$filename';
      await File(path).writeAsBytes(bytes);
      _snack(context, '✅ Saved: $filename → Downloads', Colors.green);
      print('✅ Excel saved to $path');
    } catch (e) {
      _snack(context, '❌ Could not save Excel: $e', Colors.red);
    }
  }

  // ── Misc helpers ─────────────────────────────────────────────────────────
  static bool _isTimerCategory(String name) {
    final l = name.toLowerCase();
    return l.contains('maze')     ||
        l.contains('line')        ||
        l.contains('sprint')      ||
        l.contains('drag')        ||
        l.contains('sumo')        ||
        l.contains('race')        ||
        l.contains('obstacle')    ||
        l.contains('speed')       ||
        l.contains('light');
  }

  static String _fmtDuration(String? raw) {
    if (raw == null || raw.isEmpty || raw == '00:00' || raw == '0:00')
      return '—';
    final parts = raw.split(':');
    if (parts.length < 2) return '—';
    final m = parts[0].padLeft(2, '0');
    final s = parts[1].split('.').first.padLeft(2, '0');
    return '$m:$s';
  }

  static void _snack(BuildContext ctx, String msg, Color color,
      {int seconds = 3}) {
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

// ── Data transfer objects ──────────────────────────────────────────────────────
class SoccerTeamExport {
  final String teamName;
  final int wins, losses, draws, points, goalsFor, goalsAgainst, fouls,
      matchesPlayed;
  int get goalDiff => goalsFor - goalsAgainst;

  const SoccerTeamExport({
    required this.teamName,
    required this.wins,
    required this.losses,
    required this.draws,
    required this.points,
    required this.goalsFor,
    required this.goalsAgainst,
    required this.fouls,
    required this.matchesPlayed,
  });
}

class SoccerGroupExport {
  final String label;
  final List<SoccerTeamExport> teams;
  const SoccerGroupExport({required this.label, required this.teams});
}