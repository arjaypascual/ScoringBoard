import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' hide Border;
import 'db_helper.dart';
import 'registration_shared.dart';

// ── Data models ───────────────────────────────────────────────────────────────
class _ImportRow {
  final int    rowNum;
  final String teamName;
  final String categoryName;
  final String schoolName;      // NEW — col C
  final String mentorName;      // col D
  final String mentorContact;   // NEW — col E (11-digit)
  final String p1Name;
  final String p1Birthdate;
  final String p2Name;
  final String p2Birthdate;

  // resolved IDs after DB lookup / auto-create
  int? categoryId;
  int? mentorId;
  int? schoolId;

  // status
  String  status  = 'pending';  // pending | ok | error | skipped
  String  message = '';

  _ImportRow({
    required this.rowNum,
    required this.teamName,
    required this.categoryName,
    required this.schoolName,
    required this.mentorName,
    required this.mentorContact,
    required this.p1Name,
    required this.p1Birthdate,
    required this.p2Name,
    required this.p2Birthdate,
  });

  bool get hasError   => status == 'error';
  bool get isOk       => status == 'ok';
  bool get isSkipped  => status == 'skipped';
  bool get isPending  => status == 'pending';

  String? validate() {
    if (teamName.isEmpty)         return 'Team name is required';
    if (categoryName.isEmpty)     return 'Category is required';
    if (schoolName.isEmpty)       return 'School name is required';
    if (mentorName.isEmpty)       return 'Mentor name is required';
    if (mentorContact.isEmpty)    return 'Mentor contact is required';
    if (!RegExp(r'^\d{11}$').hasMatch(mentorContact))
                                  return 'Contact must be exactly 11 digits';
    if (p1Name.isEmpty)           return 'Player 1 name is required';
    if (p1Birthdate.isEmpty)      return 'Player 1 birthdate is required';
    if (p2Name.isEmpty)           return 'Player 2 name is required';
    if (p2Birthdate.isEmpty)      return 'Player 2 birthdate is required';
    if (!_isValidDate(p1Birthdate)) return 'Player 1 birthdate must be YYYY-MM-DD';
    if (!_isValidDate(p2Birthdate)) return 'Player 2 birthdate must be YYYY-MM-DD';
    return null;
  }

  static bool _isValidDate(String v) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(v)) return false;
    try { DateTime.parse(v); return true; } catch (_) { return false; }
  }
}

// ── Main widget ───────────────────────────────────────────────────────────────
class ExcelImportPage extends StatefulWidget {
  final VoidCallback? onDone;

  const ExcelImportPage({super.key, this.onDone});

  @override
  State<ExcelImportPage> createState() => _ExcelImportPageState();
}

class _ExcelImportPageState extends State<ExcelImportPage> {
  static const _accent = Color(0xFF00CFFF);

  List<_ImportRow> _rows        = [];
  bool _isParsing               = false;
  bool _isImporting             = false;
  String? _fileName;
  int _importedCount            = 0;
  int _skippedCount             = 0;
  int _errorCount               = 0;
  int _newMentorCount           = 0;
  bool _importDone              = false;

  // ── Existing categories loaded from DB ────────────────────────────────────
  // key = lowercase trimmed name, value = id
  Map<String, int> _existingCategories = {};
  bool _categoriesLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadExistingCategories();
  }

  /// Loads all categories from DB once on init so we can validate Excel rows
  Future<void> _loadExistingCategories() async {
    try {
      final conn = await DBHelper.getConnection();
      final catRows = await conn.execute(
          "SELECT category_id, category_type FROM tbl_category");
      final map = <String, int>{};
      for (final r in catRows.rows) {
        final name = r.assoc()['category_type']?.toString().trim() ?? '';
        final id   = int.tryParse(r.assoc()['category_id']?.toString() ?? '0') ?? 0;
        if (name.isNotEmpty && id > 0) {
          map[name.toLowerCase()] = id;
        }
      }
      if (mounted) {
        setState(() {
          _existingCategories = map;
          _categoriesLoaded   = true;
        });
      }
    } catch (e) {
      debugPrint('Could not load categories: $e');
      if (mounted) setState(() => _categoriesLoaded = true);
    }
  }

  /// Finds a matching category ID using fuzzy/partial matching.
  ///
  /// Matching priority:
  ///   1. Exact match
  ///   2. DB name contains Excel name  — "Aspiring Makers (mbot 1)" contains "Aspiring Makers"
  ///   3. Excel name contains DB name  — "Aspiring Makers Mbot1" contains "Aspiring Makers"
  ///   4. Word-stem overlap            — "Emerging Innovation" ≈ "Emerging Innovators (mbot 2)"
  ///      (each meaningful word in Excel must have a DB word starting with the same 5+ chars)
  ///
  /// Returns the matched category ID, or null if no match found.
  int? _fuzzyMatchCategory(String excelCategoryName) {
    final query = excelCategoryName.toLowerCase().trim();
    if (query.isEmpty) return null;

    // 1. Exact match
    if (_existingCategories.containsKey(query)) {
      return _existingCategories[query];
    }

    // 2. DB name contains Excel value
    for (final entry in _existingCategories.entries) {
      if (entry.key.contains(query)) return entry.value;
    }

    // 3. Excel value contains DB name
    for (final entry in _existingCategories.entries) {
      if (query.contains(entry.key)) return entry.value;
    }

    // 4. Word-stem matching — handles "Innovation" vs "Innovators", "Maker" vs "Makers"
    //    Strip stop words, then check if every meaningful Excel word has a
    //    corresponding DB word that starts with the same first N characters.
    const stopWords = {'a', 'an', 'the', 'of', 'and', 'or', 'in', 'for'};
    const stemLen   = 5; // minimum shared prefix length

    final queryWords = query
        .split(RegExp(r'[\s\(\)]+'))
        .where((w) => w.length >= 3 && !stopWords.contains(w))
        .toList();

    if (queryWords.isEmpty) return null;

    MapEntry<String, int>? bestMatch;
    int bestScore = 0;

    for (final entry in _existingCategories.entries) {
      final dbWords = entry.key
          .split(RegExp(r'[\s\(\)]+'))
          .where((w) => w.length >= 3 && !stopWords.contains(w))
          .toList();

      int matched = 0;
      for (final qw in queryWords) {
        final prefix = qw.substring(0, qw.length < stemLen ? qw.length : stemLen);
        if (dbWords.any((dw) => dw.startsWith(prefix) || qw.startsWith(
            dw.substring(0, dw.length < stemLen ? dw.length : stemLen)))) {
          matched++;
        }
      }

      // All query words must match and score beats previous best
      if (matched == queryWords.length && matched > bestScore) {
        bestScore = matched;
        bestMatch = entry;
      }
    }

    return bestMatch?.value;
  }

  /// Returns the display name of the matched DB category for a given Excel value.
  String _matchedCategoryDisplayName(String excelCategoryName) {
    final query = excelCategoryName.toLowerCase().trim();
    const stopWords = {'a', 'an', 'the', 'of', 'and', 'or', 'in', 'for'};
    const stemLen   = 5;

    final queryWords = query
        .split(RegExp(r'[\s\(\)]+'))
        .where((w) => w.length >= 3 && !stopWords.contains(w))
        .toList();

    for (final entry in _existingCategories.entries) {
      if (entry.key == query || entry.key.contains(query) || query.contains(entry.key)) {
        return entry.key
            .split(' ')
            .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
            .join(' ');
      }
      // Word-stem fallback
      if (queryWords.isNotEmpty) {
        final dbWords = entry.key
            .split(RegExp(r'[\s\(\)]+'))
            .where((w) => w.length >= 3 && !stopWords.contains(w))
            .toList();
        int matched = 0;
        for (final qw in queryWords) {
          final prefix = qw.substring(0, qw.length < stemLen ? qw.length : stemLen);
          if (dbWords.any((dw) => dw.startsWith(prefix) || qw.startsWith(
              dw.substring(0, dw.length < stemLen ? dw.length : stemLen)))) {
            matched++;
          }
        }
        if (matched == queryWords.length) {
          return entry.key
              .split(' ')
              .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
              .join(' ');
        }
      }
    }
    return excelCategoryName;
  }

  // ── Pick & parse Excel ────────────────────────────────────────────────────
  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'xls'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;

    setState(() {
      _isParsing  = true;
      _fileName   = file.name;
      _rows       = [];
      _importDone = false;
    });

    try {
      final Uint8List? bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) throw Exception('Could not read file bytes');

      Excel? excel;

      // Try 1: direct decode
      try { excel = Excel.decodeBytes(bytes); } catch (_) {}

      // Try 2: fix inlineStr then decode
      if (excel == null) {
        try { excel = Excel.decodeBytes(_fixInlineStr(bytes)); } catch (_) {}
      }

      // Try 3: fix inlineStr with all-sheet rewrite
      if (excel == null) {
        try { excel = Excel.decodeBytes(_fixInlineStrAllSheets(bytes)); } catch (_) {}
      }

      // If all 3 attempts failed, throw
      final excelFile = excel ?? (throw Exception(
          'Could not decode Excel file. Please open in Excel or Google Sheets, '
          're-save as .xlsx, and try again.'));

      if (excelFile.tables.isEmpty) throw Exception('No sheets found in file');

      final sheetName = excelFile.tables.keys.firstWhere(
        (k) => excelFile.tables[k] != null && (excelFile.tables[k]!.maxRows) > 0,
        orElse: () => excelFile.tables.keys.first,
      );

      final sheet = excelFile.tables[sheetName];
      if (sheet == null) throw Exception('Sheet could not be read');
      if (sheet.maxRows < 2) throw Exception('Spreadsheet has no data rows');

              String extractCell(List<Data?> row, int col) {
        try {
          if (col >= row.length) return '';
          final data = row[col];
          if (data == null) return '';
          // Try typed value first
          try {
            final v = data.value;
            if (v != null) {
              final result = switch (v) {
                TextCellValue()     => v.value.toString().trim(),
                IntCellValue()      => v.value.toString().trim(),
                DoubleCellValue()   => v.value.toString().trim(),
                BoolCellValue()     => v.value.toString().trim(),
                DateCellValue()     => () {
                    final raw   = v.toString();
                    final match = RegExp(r'(\d{4}-\d{2}-\d{2})').firstMatch(raw);
                    return match?.group(1) ?? raw.trim();
                  }(),
                DateTimeCellValue() => () {
                    final raw   = v.toString();
                    final match = RegExp(r'(\d{4}-\d{2}-\d{2})').firstMatch(raw);
                    return match?.group(1) ?? raw.trim();
                  }(),
                _                   => v.toString().trim(),
              };
              if (result.isNotEmpty) return result;
            }
          } catch (_) {}
          // Fallback to raw toString
          try {
            final raw = data.toString().trim();
            if (raw.isNotEmpty && raw != 'null') return raw;
          } catch (_) {}
          return '';
        } catch (e) {
          debugPrint('extractCell error col $col: $e');
          return '';
        }
      }

      final parsed = <_ImportRow>[];
      for (int r = 4; r < sheet.maxRows; r++) {
        try {
          final rowData = sheet.rows[r];
          bool isEmpty = true;
          for (int c = 0; c < 9; c++) {
            if (extractCell(rowData, c).isNotEmpty) { isEmpty = false; break; }
          }
          if (isEmpty) continue;

          parsed.add(_ImportRow(
            rowNum:        r + 1,
            teamName:      extractCell(rowData, 0),
            categoryName:  extractCell(rowData, 1),
            schoolName:    extractCell(rowData, 2),
            mentorName:    extractCell(rowData, 3),
            mentorContact: extractCell(rowData, 4),
            p1Name:        extractCell(rowData, 5),
            p1Birthdate:   extractCell(rowData, 6),
            p2Name:        extractCell(rowData, 7),
            p2Birthdate:   extractCell(rowData, 8),
          ));
        } catch (e) {
          debugPrint('Row ${r+1} error: $e');
          continue;
        }
      }

      // Validate each row — including category existence check
      for (final row in parsed) {
        final err = row.validate();
        if (err != null) {
          row.status  = 'error';
          row.message = err;
          continue;
        }

        // ── KEY CHANGE: check category exists in DB using fuzzy match, do NOT auto-create ──
        final catId = _fuzzyMatchCategory(row.categoryName);
        if (catId == null) {
          row.status  = 'error';
          row.message = 'Category "${row.categoryName}" not found in DB. '
              'Available: ${_existingCategories.keys.join(", ")}';
        } else {
          row.categoryId = catId;
        }
      }

      setState(() {
        _rows      = parsed;
        _isParsing = false;
      });
    } catch (e) {
      setState(() => _isParsing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('❌ Failed to read file: $e'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  // ── Run bulk import ───────────────────────────────────────────────────────
  Future<void> _runImport() async {
    final validRows = _rows.where((r) => !r.hasError).toList();
    if (validRows.isEmpty) return;

    setState(() {
      _isImporting   = true;
      _importedCount = 0;
      _skippedCount  = 0;
      _errorCount    = 0;
      _newMentorCount = 0;
      _importDone    = false;
    });

    try {
      final conn = await DBHelper.getConnection();

      // Prefetch mentors
      final menRows = await conn.execute(
          "SELECT mentor_id, mentor_name FROM tbl_mentor");
      final Map<String, int> menMap = {
        for (final r in menRows.rows)
          r.assoc()['mentor_name']!.toString().toLowerCase().trim():
              int.parse(r.assoc()['mentor_id'].toString())
      };

      // Re-fetch categories fresh at import time (not from cached parse-time map)
      final freshCatRows = await conn.execute(
          "SELECT category_id, category_type FROM tbl_category");
      final Map<String, int> freshCatMap = {
        for (final r in freshCatRows.rows)
          r.assoc()['category_type']!.toString().toLowerCase().trim():
              int.parse(r.assoc()['category_id'].toString())
      };
      debugPrint('=== IMPORT START: ${validRows.length} rows, '
          'categories: $freshCatMap, mentors: $menMap ===');

      for (final row in validRows) {
        if (!mounted) return;

        // Re-resolve category fresh from DB at import time
        int? catId = row.categoryId;
        if (catId == null) {
          // Try fresh map with fuzzy logic inline
          final query = row.categoryName.toLowerCase().trim();
          catId = freshCatMap[query];
          if (catId == null) {
            for (final e in freshCatMap.entries) {
              if (e.key.contains(query) || query.contains(e.key)) {
                catId = e.value; break;
              }
            }
          }
        }

        if (catId == null) {
          debugPrint('ROW ${row.rowNum}: category "${row.categoryName}" not found. '
              'Available: $freshCatMap');
          setState(() {
            row.status  = 'error';
            row.message = 'Category "${row.categoryName}" not found in DB';
            _errorCount++;
          });
          continue;
        }

        // ── Resolve / auto-create school ─────────────────────────────────
        int? schoolId;
        try {
          final schoolRes = await conn.execute(
            "SELECT school_id FROM tbl_school WHERE LOWER(school_name) = LOWER(:name) LIMIT 1",
            {"name": row.schoolName.trim()},
          );
          if (schoolRes.rows.isNotEmpty) {
            schoolId = int.tryParse(
                schoolRes.rows.first.assoc()['school_id']?.toString() ?? '0');
            debugPrint('ROW ${row.rowNum}: found school_id=$schoolId');
          } else {
            // Auto-create school with a default region
            debugPrint('ROW ${row.rowNum}: school "${row.schoolName}" not found, auto-creating...');
            await conn.execute(
              "INSERT INTO tbl_school (school_name, school_region) VALUES (:name, :region)",
              {"name": row.schoolName.trim(), "region": "NCR - National Capital Region"},
            );
            final sIdRes = await conn.execute(
              "SELECT school_id FROM tbl_school WHERE LOWER(school_name) = LOWER(:name) "
              "ORDER BY school_id DESC LIMIT 1",
              {"name": row.schoolName.trim()},
            );
            schoolId = int.tryParse(
                sIdRes.rows.first.assoc()['school_id']?.toString() ?? '0');
            debugPrint('ROW ${row.rowNum}: auto-created school_id=$schoolId');
          }
        } catch (e) {
          debugPrint('ROW ${row.rowNum}: school error: $e');
          if (!mounted) return;
          setState(() {
            row.status  = 'error';
            row.message = 'Could not resolve school "${row.schoolName}": $e';
            _errorCount++;
          });
          continue;
        }

        if (schoolId == null || schoolId == 0) {
          setState(() {
            row.status  = 'error';
            row.message = 'School "${row.schoolName}" could not be resolved';
            _errorCount++;
          });
          continue;
        }
        row.schoolId = schoolId;

        // ── Resolve / auto-create mentor ──────────────────────────────────
        int? menId = menMap[row.mentorName.toLowerCase().trim()];
        if (menId == null) {
          try {
            debugPrint('ROW ${row.rowNum}: mentor "${row.mentorName}" not found, auto-creating...');
            await conn.execute(
              "INSERT INTO tbl_mentor (mentor_name, mentor_number, school_id) "
              "VALUES (:name, :number, :schoolId)",
              {
                "name":     row.mentorName.trim(),
                "number":   row.mentorContact.trim(),
                "schoolId": schoolId,
              },
            );
            final mIdRes = await conn.execute(
              "SELECT mentor_id FROM tbl_mentor WHERE LOWER(mentor_name) = LOWER(:name) "
              "ORDER BY mentor_id DESC LIMIT 1",
              {"name": row.mentorName.trim()},
            );
            if (mIdRes.rows.isEmpty) throw Exception('Could not retrieve mentor_id');
            menId = int.tryParse(
                mIdRes.rows.first.assoc()['mentor_id']?.toString() ?? '0') ?? 0;
            if (menId == 0) throw Exception('mentor_id is 0');
            menMap[row.mentorName.toLowerCase().trim()] = menId;
            _newMentorCount++;
            debugPrint('ROW ${row.rowNum}: auto-created mentor_id=$menId');
          } catch (e) {
            debugPrint('ROW ${row.rowNum}: could not create mentor: $e');
            if (!mounted) return;
            setState(() {
              row.status  = 'error';
              row.message = 'Could not create mentor "${row.mentorName}": $e';
              _errorCount++;
            });
            continue;
          }
        }

        row.mentorId   = menId;
        row.categoryId = catId;

        debugPrint('ROW ${row.rowNum}: team="${row.teamName}" '
            'catId=$catId menId=$menId');

        // Check duplicate team
        final dupCheck = await conn.execute(
          "SELECT COUNT(*) as cnt FROM tbl_team WHERE LOWER(team_name) = LOWER(:name)",
          {"name": row.teamName},
        );
        final dup = int.tryParse(
                dupCheck.rows.first.assoc()['cnt']?.toString() ?? '0') ?? 0;

        if (dup > 0) {
          if (!mounted) return;
          debugPrint('ROW ${row.rowNum}: SKIPPED — team already exists');
          setState(() {
            row.status  = 'skipped';
            row.message = 'Team already exists — skipped';
            _skippedCount++;
          });
          continue;
        }

        try {
          debugPrint('ROW ${row.rowNum}: inserting team...');
          await conn.execute(
            """INSERT INTO tbl_team (team_name, team_ispresent, mentor_id, category_id)
               VALUES (:name, 1, :mentorId, :categoryId)""",
            {
              "name":       row.teamName,
              "mentorId":   menId,
              "categoryId": catId,
            },
          );
          debugPrint('ROW ${row.rowNum}: team INSERT done, fetching ID...');

          // Fetch inserted team_id by name (more reliable than LAST_INSERT_ID across connections)
          final idResult = await conn.execute(
            "SELECT team_id FROM tbl_team WHERE LOWER(team_name) = LOWER(:name) "
            "ORDER BY team_id DESC LIMIT 1",
            {"name": row.teamName},
          );

          if (idResult.rows.isEmpty) {
            throw Exception('Team inserted but could not retrieve team_id for "${row.teamName}"');
          }

          final teamId = int.tryParse(
              idResult.rows.first.assoc()['team_id']?.toString() ?? '0') ?? 0;

          if (teamId == 0) throw Exception('team_id came back as 0 for "${row.teamName}"');

          debugPrint('ROW ${row.rowNum}: team_id=$teamId, inserting players...');

          await conn.execute(
            """INSERT INTO tbl_player
                 (player_name, player_birthdate, player_ispresent, team_id)
               VALUES (:name, :birth, 1, :teamId)""",
            {"name": row.p1Name, "birth": row.p1Birthdate, "teamId": teamId},
          );

          await conn.execute(
            """INSERT INTO tbl_player
                 (player_name, player_birthdate, player_ispresent, team_id)
               VALUES (:name, :birth, 1, :teamId)""",
            {"name": row.p2Name, "birth": row.p2Birthdate, "teamId": teamId},
          );

          debugPrint('ROW ${row.rowNum}: ✅ SUCCESS team_id=$teamId');
          if (!mounted) return;
          setState(() {
            row.status  = 'ok';
            row.message = 'Imported successfully (team_id=$teamId, cat=$catId)';
            _importedCount++;
          });
        } catch (e) {
          debugPrint('ROW ${row.rowNum}: ❌ DB error: $e');
          if (!mounted) return;
          setState(() {
            row.status  = 'error';
            row.message = 'DB error: $e';
            _errorCount++;
          });
        }
      }
      debugPrint('=== IMPORT DONE: imported=$_importedCount '
          'skipped=$_skippedCount errors=$_errorCount ===');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('❌ Import failed: $e'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
          _importDone  = true;
        });
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0630),
      body: Column(
        children: [
          const RegistrationHeader(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildLeftPanel(),
                Expanded(child: _buildPreviewPanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftPanel() {
    final hasRows    = _rows.isNotEmpty;
    final readyCount = _rows.where((r) => r.isPending).length;
    final hasErrors  = _rows.any((r) => r.hasError);
    final canImport  = hasRows && readyCount > 0 && !_isImporting && !_importDone;

    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: const Color(0xFF130840),
        border: const Border(right: BorderSide(color: Color(0xFF1E1060), width: 1)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Title ──────────────────────────────────────────────────────
            Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [Color(0xFF00CFFF), Color(0xFF0088CC)]),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [BoxShadow(
                      color: _accent.withOpacity(0.35), blurRadius: 14)],
                ),
                child: const Icon(Icons.upload_file_rounded,
                    color: Colors.white, size: 22),
              ),
              const SizedBox(width: 14),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('BULK IMPORT',
                      style: TextStyle(color: Colors.white,
                          fontSize: 16, fontWeight: FontWeight.w900,
                          letterSpacing: 2)),
                  Text('Excel Registration',
                      style: TextStyle(color: Color(0xFF00CFFF),
                          fontSize: 11, letterSpacing: 1)),
                ],
              ),
            ]),
            const SizedBox(height: 28),

            // ── Template hint ──────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _accent.withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _accent.withOpacity(0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.table_chart_rounded,
                        color: _accent.withOpacity(0.8), size: 15),
                    const SizedBox(width: 8),
                    const Text('EXCEL FORMAT',
                        style: TextStyle(color: Color(0xFF00CFFF),
                            fontSize: 11, fontWeight: FontWeight.bold,
                            letterSpacing: 1)),
                  ]),
                  const SizedBox(height: 10),
                  const Text('Required columns (row 1 = header):',
                      style: TextStyle(color: Colors.white54, fontSize: 11)),
                  const SizedBox(height: 8),
                  ..._colGuide.map((c) => Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Row(children: [
                      Container(
                        width: 22, height: 18,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: c.$3.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: c.$3.withOpacity(0.4)),
                        ),
                        child: Center(
                          child: Text(c.$1,
                              style: TextStyle(color: c.$3,
                                  fontSize: 8, fontWeight: FontWeight.bold)),
                        ),
                      ),
                      Expanded(
                        child: Text(c.$2,
                            style: const TextStyle(
                                color: Colors.white60, fontSize: 11)),
                      ),
                    ]),
                  )),
                  const SizedBox(height: 6),
                  Text('• Birthdate format: YYYY-MM-DD',
                      style: TextStyle(color: Colors.white.withOpacity(0.35),
                          fontSize: 10)),
                  Text('• Duplicate teams will be skipped',
                      style: TextStyle(color: Colors.white.withOpacity(0.35),
                          fontSize: 10)),
                  Text('• Category must match an existing DB category',
                      style: TextStyle(color: Colors.orange.withOpacity(0.7),
                          fontSize: 10)),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Existing categories from DB ────────────────────────────────
            _buildCategoryList(),
            const SizedBox(height: 20),

            // ── Pick file button ───────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: _buildActionBtn(
                icon: Icons.folder_open_rounded,
                label: _fileName != null
                    ? _fileName!.length > 24
                        ? '${_fileName!.substring(0, 22)}…'
                        : _fileName!
                    : 'CHOOSE EXCEL FILE',
                color: _accent,
                onTap: _isParsing || _isImporting ? null : _pickFile,
                outlined: _fileName == null,
              ),
            ),
            const SizedBox(height: 12),

            if (hasRows) ...[
              _summaryRow(),
              const SizedBox(height: 20),
            ],

            if (hasRows && !_importDone) ...[
              SizedBox(
                width: double.infinity,
                child: _buildActionBtn(
                  icon: _isImporting
                      ? Icons.hourglass_top_rounded
                      : Icons.rocket_launch_rounded,
                  label: _isImporting
                      ? 'IMPORTING…'
                      : 'IMPORT $readyCount TEAM${readyCount != 1 ? "S" : ""}',
                  color: canImport
                      ? const Color(0xFF00E5A0)
                      : Colors.white24,
                  onTap: canImport ? _runImport : null,
                ),
              ),
              if (hasErrors) ...[
                const SizedBox(height: 8),
                Text('⚠ ${_rows.where((r) => r.hasError).length} rows have errors and will be skipped.',
                    style: const TextStyle(color: Colors.orange, fontSize: 11)),
              ],
            ],

            if (_importDone) ...[
              _buildDoneBanner(),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: _buildActionBtn(
                  icon: Icons.refresh_rounded,
                  label: 'IMPORT ANOTHER FILE',
                  color: _accent,
                  onTap: () => setState(() {
                    _rows       = [];
                    _fileName   = null;
                    _importDone = false;
                  }),
                  outlined: true,
                ),
              ),
              if (widget.onDone != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: _buildActionBtn(
                    icon: Icons.check_circle_rounded,
                    label: 'DONE',
                    color: const Color(0xFF00E5A0),
                    onTap: widget.onDone,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// Shows the list of existing categories from DB so users know valid values
  Widget _buildCategoryList() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.category_rounded,
                color: Colors.orange.withOpacity(0.8), size: 14),
            const SizedBox(width: 8),
            const Text('VALID CATEGORIES (DB)',
                style: TextStyle(color: Colors.orange,
                    fontSize: 10, fontWeight: FontWeight.bold,
                    letterSpacing: 1)),
          ]),
          const SizedBox(height: 8),
          if (!_categoriesLoaded)
            const SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.orange),
            )
          else if (_existingCategories.isEmpty)
            Text('No categories found in DB.',
                style: TextStyle(
                    color: Colors.orange.withOpacity(0.6), fontSize: 11))
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _existingCategories.entries.map((e) {
                // Display the original-cased name from the map key
                final displayName = e.key
                    .split(' ')
                    .map((w) => w.isEmpty
                        ? w
                        : w[0].toUpperCase() + w.substring(1))
                    .join(' ');
                return Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: Colors.orange.withOpacity(0.35)),
                  ),
                  child: Text(displayName,
                      style: const TextStyle(
                          color: Colors.orange,
                          fontSize: 10,
                          fontWeight: FontWeight.w600)),
                );
              }).toList(),
            ),
          const SizedBox(height: 6),
          Text('Category column in Excel must match one of these exactly.',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.25), fontSize: 9)),
        ],
      ),
    );
  }

  Widget _summaryRow() {
    final total  = _rows.length;
    final ready  = _rows.where((r) => r.isPending).length;
    final errors = _rows.where((r) => r.hasError).length;
    return Row(children: [
      _chip('$total ROWS',  Colors.white54),
      const SizedBox(width: 6),
      _chip('$ready READY', const Color(0xFF00CFFF)),
      if (errors > 0) ...[
        const SizedBox(width: 6),
        _chip('$errors ERR', Colors.redAccent),
      ],
    ]);
  }

  Widget _chip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(0.4)),
    ),
    child: Text(label,
        style: TextStyle(color: color, fontSize: 10,
            fontWeight: FontWeight.bold, letterSpacing: 0.8)),
  );

  Widget _buildDoneBanner() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF00E5A0).withOpacity(0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: const Color(0xFF00E5A0).withOpacity(0.3), width: 1.5),
      ),
      child: Column(children: [
        const Icon(Icons.check_circle_rounded,
            color: Color(0xFF00E5A0), size: 32),
        const SizedBox(height: 8),
        const Text('IMPORT COMPLETE',
            style: TextStyle(color: Color(0xFF00E5A0),
                fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
        const SizedBox(height: 12),
        _doneRow(Icons.group_add_rounded,
            '$_importedCount teams registered', const Color(0xFF00E5A0)),
        if (_newMentorCount > 0)
          _doneRow(Icons.person_add_rounded,
              '$_newMentorCount new mentors added', const Color(0xFF00CFFF)),
        if (_skippedCount > 0)
          _doneRow(Icons.skip_next_rounded,
              '$_skippedCount skipped (duplicates)', Colors.orange),
        if (_errorCount > 0)
          _doneRow(Icons.error_outline_rounded,
              '$_errorCount errors', Colors.redAccent),
      ]),
    );
  }

  Widget _doneRow(IconData icon, String label, Color color) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(children: [
      Icon(icon, color: color, size: 14),
      const SizedBox(width: 8),
      Text(label, style: TextStyle(color: color, fontSize: 12)),
    ]),
  );

  Widget _buildActionBtn({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onTap,
    bool outlined = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: onTap == null ? 0.45 : 1.0,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            gradient: !outlined && onTap != null
                ? LinearGradient(
                    colors: [color, color.withOpacity(0.7)],
                    begin: Alignment.topLeft, end: Alignment.bottomRight)
                : null,
            color: outlined || onTap == null ? Colors.transparent : null,
            borderRadius: BorderRadius.circular(12),
            border: outlined
                ? Border.all(color: color.withOpacity(0.6), width: 1.5)
                : null,
            boxShadow: !outlined && onTap != null
                ? [BoxShadow(color: color.withOpacity(0.3), blurRadius: 14)]
                : [],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: outlined ? color : Colors.white, size: 16),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(
                      color: outlined ? color : Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2)),
            ],
          ),
        ),
      ),
    );
  }

  // ── Preview table ─────────────────────────────────────────────────────────
  Widget _buildPreviewPanel() {
    if (_isParsing) {
      return const Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          CircularProgressIndicator(color: Color(0xFF00CFFF)),
          SizedBox(height: 16),
          Text('Reading Excel file…',
              style: TextStyle(color: Colors.white54, fontSize: 14)),
        ]),
      );
    }

    if (_rows.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.table_rows_rounded,
              size: 72, color: Colors.white.withOpacity(0.06)),
          const SizedBox(height: 16),
          Text('No file loaded yet',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.25), fontSize: 16)),
          const SizedBox(height: 6),
          Text('Choose an Excel file to preview data before importing.',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.15), fontSize: 12)),
        ]),
      );
    }

    return Column(
      children: [
        Container(
          color: const Color(0xFF1A0C50),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          child: Row(children: [
            _th('#',         flex: 1),
            _th('TEAM',      flex: 3),
            _th('CATEGORY',  flex: 3),
            _th('SCHOOL',    flex: 3),
            _th('MENTOR',    flex: 3),
            _th('PLAYER 1',  flex: 3),
            _th('PLAYER 2',  flex: 3),
            _th('STATUS',    flex: 2),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _rows.length,
            itemBuilder: (_, i) => _buildRow(_rows[i], i),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(_ImportRow row, int index) {
    Color rowBg;
    if (row.isOk)           rowBg = const Color(0xFF00FF88).withOpacity(0.04);
    else if (row.hasError)  rowBg = Colors.red.withOpacity(0.05);
    else if (row.isSkipped) rowBg = Colors.orange.withOpacity(0.05);
    else                    rowBg = index % 2 == 0
        ? const Color(0xFF130840) : const Color(0xFF0F0630);

    // Check if category is valid for visual highlight
    final catId    = _fuzzyMatchCategory(row.categoryName);
    final catValid = catId != null;
    final matchedName = catValid
        ? _matchedCategoryDisplayName(row.categoryName)
        : row.categoryName;
    // Show a "→ DB Name" hint if the Excel name differs from the matched DB name
    final showMatchHint = catValid &&
        matchedName.toLowerCase() != row.categoryName.toLowerCase().trim();

    return Container(
      color: rowBg,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 1,
              child: Text('${row.rowNum}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12))),
          _td(row.teamName, flex: 3, bold: true),
          // Category cell — highlight red if not in DB, show matched name if fuzzy
          Expanded(flex: 3, child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(
                    row.categoryName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: catValid ? Colors.white70 : Colors.redAccent,
                      fontSize: 12,
                      fontWeight: catValid ? FontWeight.normal : FontWeight.bold,
                    ),
                  ),
                ),
                if (!catValid && row.categoryName.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  const Tooltip(
                    message: 'Category not found in DB',
                    child: Icon(Icons.warning_amber_rounded,
                        color: Colors.redAccent, size: 13),
                  ),
                ],
              ]),
              if (showMatchHint)
                Row(children: [
                  const Icon(Icons.arrow_forward_rounded,
                      color: Color(0xFF00CFFF), size: 10),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      matchedName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Color(0xFF00CFFF), fontSize: 10),
                    ),
                  ),
                ]),
            ],
          )),
          // School cell
          Expanded(flex: 3, child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(row.schoolName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              Text(row.mentorContact,
                  style: const TextStyle(color: Colors.white38, fontSize: 10)),
            ],
          )),
          _td(row.mentorName, flex: 3),
          Expanded(flex: 3, child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(row.p1Name,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  overflow: TextOverflow.ellipsis),
              Text(row.p1Birthdate,
                  style: const TextStyle(color: Colors.white38, fontSize: 10)),
            ],
          )),
          Expanded(flex: 3, child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(row.p2Name,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  overflow: TextOverflow.ellipsis),
              Text(row.p2Birthdate,
                  style: const TextStyle(color: Colors.white38, fontSize: 10)),
            ],
          )),
          Expanded(flex: 2, child: _statusBadge(row)),
        ],
      ),
    );
  }

  Widget _statusBadge(_ImportRow row) {
    IconData icon;
    Color    color;
    String   label;

    if (row.isOk) {
      icon  = Icons.check_circle_rounded;
      color = const Color(0xFF00FF88);
      label = 'OK';
    } else if (row.hasError) {
      icon  = Icons.error_rounded;
      color = Colors.redAccent;
      label = 'ERROR';
    } else if (row.isSkipped) {
      icon  = Icons.skip_next_rounded;
      color = Colors.orange;
      label = 'SKIP';
    } else {
      icon  = Icons.radio_button_unchecked;
      color = Colors.white30;
      label = 'READY';
    }

    return Tooltip(
      message: row.message.isNotEmpty ? row.message : label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 12),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(color: color,
                  fontSize: 9, fontWeight: FontWeight.bold,
                  letterSpacing: 0.8)),
        ]),
      ),
    );
  }

  Widget _th(String label, {required int flex}) => Expanded(
    flex: flex,
    child: Text(label,
        style: const TextStyle(
            color: Color(0xFF00CFFF), fontSize: 10,
            fontWeight: FontWeight.bold, letterSpacing: 1.2)),
  );

  Widget _td(String text, {required int flex, bool bold = false}) => Expanded(
    flex: flex,
    child: Text(text,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: bold ? Colors.white : Colors.white70,
            fontSize: 12,
            fontWeight: bold ? FontWeight.w600 : FontWeight.normal)),
  );

  static const _colGuide = [
    ('A', 'Team Name',           Color(0xFFFFD700)),
    ('B', 'Category',            Color(0xFF00CFFF)),
    ('C', 'School Name',         Color(0xFFFF8A65)),
    ('D', 'Mentor Name',         Color(0xFF967BB6)),
    ('E', 'Mentor Contact (11)', Color(0xFF967BB6)),
    ('F', 'Player 1 Name',       Color(0xFF00E5A0)),
    ('G', 'Player 1 Birthdate',  Color(0xFF00E5A0)),
    ('H', 'Player 2 Name',       Color(0xFFFF8A65)),
    ('I', 'Player 2 Birthdate',  Color(0xFFFF8A65)),
  ];

  static Uint8List _fixInlineStr(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final newArchive = Archive();
      for (final file in archive.files) {
        if (file.isFile && file.name == 'xl/worksheets/sheet1.xml') {
          try {
            var xml = utf8.decode(file.content as List<int>, allowMalformed: true);
            xml = xml.replaceAllMapped(
              RegExp(r'<is><t(?:[^>]*)>(.*?)</t></is>', dotAll: true),
              (m) => '<v>${m.group(1)}</v>',
            );
            final fixed = utf8.encode(xml);
            newArchive.addFile(ArchiveFile(file.name, fixed.length, fixed));
          } catch (_) {
            newArchive.addFile(file);
          }
        } else {
          newArchive.addFile(file);
        }
      }
      return Uint8List.fromList(ZipEncoder().encode(newArchive)!);
    } catch (_) {
      return bytes;
    }
  }

  /// Fixes inlineStr in ALL worksheet files (not just sheet1.xml)
  static Uint8List _fixInlineStrAllSheets(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final newArchive = Archive();
      for (final file in archive.files) {
        if (file.isFile && file.name.startsWith('xl/worksheets/') && file.name.endsWith('.xml')) {
          try {
            var xml = utf8.decode(file.content as List<int>, allowMalformed: true);
            // Fix inlineStr
            xml = xml.replaceAllMapped(
              RegExp(r'<is><t(?:[^>]*)>(.*?)</t></is>', dotAll: true),
              (m) => '<v>${m.group(1)}</v>',
            );
            // Remove null value attributes that crash the parser
            xml = xml.replaceAll(' t="n"', '');
            final fixed = utf8.encode(xml);
            newArchive.addFile(ArchiveFile(file.name, fixed.length, fixed));
          } catch (_) {
            newArchive.addFile(file);
          }
        } else {
          newArchive.addFile(file);
        }
      }
      return Uint8List.fromList(ZipEncoder().encode(newArchive)!);
    } catch (_) {
      return bytes;
    }
  }
}