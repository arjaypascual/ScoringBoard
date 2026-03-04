import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'db_helper.dart';

// ── Match status enum ────────────────────────────────────────────────────────
enum MatchStatus { pending, inProgress, done }

extension MatchStatusExt on MatchStatus {
  String get label {
    switch (this) {
      case MatchStatus.pending:    return 'Pending';
      case MatchStatus.inProgress: return 'In Progress';
      case MatchStatus.done:       return 'Done';
    }
  }

  Color get color {
    switch (this) {
      case MatchStatus.pending:    return const Color(0xFFAAAAAA);
      case MatchStatus.inProgress: return const Color(0xFF00CFFF);
      case MatchStatus.done:       return Colors.green;
    }
  }
}

// ── Main widget ──────────────────────────────────────────────────────────────
class ScheduleViewer extends StatefulWidget {
  final VoidCallback? onRegister;
  final VoidCallback? onStandings;

  const ScheduleViewer({
    super.key,
    this.onRegister,
    this.onStandings,
  });

  @override
  State<ScheduleViewer> createState() => _ScheduleViewerState();
}

class _ScheduleViewerState extends State<ScheduleViewer>
    with SingleTickerProviderStateMixin {
  // Tabs
  TabController? _tabController;
  List<Map<String, dynamic>> _categories = [];

  // Schedule data: category_id → list of match rows
  // Each match row: { matchNumber, schedule, teams: [ {teamCode, teamName} ] }
  Map<int, List<Map<String, dynamic>>> _scheduleByCategory = {};

  // Status per match: '$categoryId-$matchIndex' → MatchStatus
  final Map<String, MatchStatus> _statusMap = {};

  bool _isLoading = true;

  // ── Lifecycle ────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  // ── Load data ────────────────────────────────────────────────────────────
  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final categories = await DBHelper.getCategories();
      final conn = await DBHelper.getConnection();

      // Load full schedule with team info grouped by category
      final result = await conn.execute("""
        SELECT
          c.category_id,
          c.category_type,
          ts.teamschedule_id,
          ts.match_id,
          ts.round_id,
          t.team_name,
          s.schedule_start,
          s.schedule_end,
          r.round_type
        FROM tbl_teamschedule ts
        JOIN tbl_team t        ON ts.team_id    = t.team_id
        JOIN tbl_category c    ON t.category_id = c.category_id
        JOIN tbl_match m       ON ts.match_id   = m.match_id
        JOIN tbl_schedule s    ON m.schedule_id = s.schedule_id
        JOIN tbl_round r       ON ts.round_id   = r.round_id
        ORDER BY c.category_id, s.schedule_start, ts.match_id
      """);

      final rows = result.rows.map((r) => r.assoc()).toList();

      // Group rows by category → match_id
      final Map<int, Map<int, Map<String, dynamic>>> grouped = {};
      for (final row in rows) {
        final catId  = int.tryParse(row['category_id'].toString()) ?? 0;
        final matchId = int.tryParse(row['match_id'].toString()) ?? 0;

        grouped.putIfAbsent(catId, () => {});
        if (!grouped[catId]!.containsKey(matchId)) {
          grouped[catId]![matchId] = {
            'match_id': matchId,
            'schedule': '${_fmt(row['schedule_start'])} - ${_fmt(row['schedule_end'])}',
            'teams': <Map<String, String>>[],
          };
        }
        (grouped[catId]![matchId]!['teams'] as List).add({
          'team_name': row['team_name'] ?? '',
          'round_type': row['round_type'] ?? '',
        });
      }

      // Convert to sorted list per category
      final Map<int, List<Map<String, dynamic>>> scheduleByCategory = {};
      for (final cat in categories) {
        final catId = int.tryParse(cat['category_id'].toString()) ?? 0;
        final matches = grouped[catId]?.values.toList() ?? [];
        // Sort by schedule string
        matches.sort((a, b) =>
            (a['schedule'] as String).compareTo(b['schedule'] as String));
        // Assign match number
        for (int i = 0; i < matches.length; i++) {
          matches[i]['matchNumber'] = i + 1;
        }
        scheduleByCategory[catId] = matches;
      }

      // Init tab controller
      _tabController?.dispose();
      _tabController = TabController(
        length: categories.length,
        vsync: this,
      );

      setState(() {
        _categories = categories;
        _scheduleByCategory = scheduleByCategory;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Failed to load schedule: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ── Format time HH:MM:SS → HH:MM ────────────────────────────────────────
  String _fmt(String? t) {
    if (t == null || t.isEmpty) return '--:--';
    final parts = t.split(':');
    if (parts.length < 2) return t;
    return '${parts[0]}:${parts[1]}';
  }

  // ── Status key ───────────────────────────────────────────────────────────
  String _statusKey(int catId, int matchNumber) => '$catId-$matchNumber';

  MatchStatus _getStatus(int catId, int matchNumber) =>
      _statusMap[_statusKey(catId, matchNumber)] ?? MatchStatus.pending;

  void _cycleStatus(int catId, int matchNumber) {
    final key = _statusKey(catId, matchNumber);
    final current = _statusMap[key] ?? MatchStatus.pending;
    setState(() {
      switch (current) {
        case MatchStatus.pending:
          _statusMap[key] = MatchStatus.inProgress;
          break;
        case MatchStatus.inProgress:
          _statusMap[key] = MatchStatus.done;
          break;
        case MatchStatus.done:
          _statusMap[key] = MatchStatus.pending;
          break;
      }
    });
  }

  // ── PDF Export ───────────────────────────────────────────────────────────
  Future<void> _exportPdf(
      Map<String, dynamic> category,
      List<Map<String, dynamic>> matches) async {
    final doc = pw.Document();
    final categoryName =
        (category['category_type'] ?? '').toString().toUpperCase();

    // Determine max arenas dynamically
    int maxArenas = 1;
    for (final m in matches) {
      final teams = (m['teams'] as List).length;
      if (teams > maxArenas) maxArenas = teams;
    }

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4.landscape,
        build: (pw.Context ctx) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              // Header
              pw.Container(
                color: const PdfColor.fromInt(0xFF3D1A8C),
                padding: const pw.EdgeInsets.symmetric(
                    vertical: 12, horizontal: 16),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('ROBOVENTURE',
                        style: pw.TextStyle(
                            color: PdfColors.white,
                            fontSize: 14,
                            fontWeight: pw.FontWeight.bold)),
                    pw.Text(categoryName,
                        style: pw.TextStyle(
                            color: PdfColors.white,
                            fontSize: 20,
                            fontWeight: pw.FontWeight.bold)),
                    pw.Text('4TH ROBOTICS COMPETITION',
                        style: const pw.TextStyle(
                            color: PdfColors.white, fontSize: 10)),
                  ],
                ),
              ),
              pw.SizedBox(height: 8),

              // Table header
              pw.Container(
                color: const PdfColor.fromInt(0xFF5C2ECC),
                padding: const pw.EdgeInsets.symmetric(
                    vertical: 8, horizontal: 8),
                child: pw.Row(
                  children: [
                    pw.Expanded(
                        flex: 1,
                        child: pw.Text('MATCH',
                            style: pw.TextStyle(
                                color: PdfColors.white,
                                fontWeight: pw.FontWeight.bold,
                                fontSize: 11))),
                    pw.Expanded(
                        flex: 2,
                        child: pw.Text('SCHEDULE',
                            style: pw.TextStyle(
                                color: PdfColors.white,
                                fontWeight: pw.FontWeight.bold,
                                fontSize: 11))),
                    ...List.generate(
                      maxArenas,
                      (i) => pw.Expanded(
                        flex: 2,
                        child: pw.Text('ARENA ${i + 1}',
                            textAlign: pw.TextAlign.center,
                            style: pw.TextStyle(
                                color: PdfColors.white,
                                fontWeight: pw.FontWeight.bold,
                                fontSize: 11)),
                      ),
                    ),
                  ],
                ),
              ),

              // Table rows
              ...matches.asMap().entries.map((entry) {
                final i = entry.key;
                final m = entry.value;
                final teams = m['teams'] as List;
                final isEven = i % 2 == 0;
                return pw.Container(
                  color: isEven
                      ? PdfColors.white
                      : const PdfColor.fromInt(0xFFF3EEFF),
                  padding: const pw.EdgeInsets.symmetric(
                      vertical: 10, horizontal: 8),
                  child: pw.Row(
                    children: [
                      pw.Expanded(
                          flex: 1,
                          child: pw.Text('${m['matchNumber']}',
                              style: const pw.TextStyle(fontSize: 11))),
                      pw.Expanded(
                          flex: 2,
                          child: pw.Text('${m['schedule']}',
                              style: const pw.TextStyle(fontSize: 11))),
                      ...List.generate(maxArenas, (ai) {
                        if (ai < teams.length) {
                          final team = teams[ai] as Map;
                          return pw.Expanded(
                            flex: 2,
                            child: pw.Column(
                              children: [
                                pw.Text(
                                  team['round_type']?.toString() ?? '',
                                  textAlign: pw.TextAlign.center,
                                  style: pw.TextStyle(
                                      fontSize: 12,
                                      fontWeight: pw.FontWeight.bold),
                                ),
                                pw.Text(
                                  team['team_name']?.toString() ?? '',
                                  textAlign: pw.TextAlign.center,
                                  style: const pw.TextStyle(fontSize: 9),
                                ),
                              ],
                            ),
                          );
                        } else {
                          return pw.Expanded(flex: 2, child: pw.Text(''));
                        }
                      }),
                    ],
                  ),
                );
              }).toList(),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A0A4A),
      body: Column(
        children: [
          _buildHeader(),
          if (_isLoading)
            const Expanded(
              child: Center(
                child: CircularProgressIndicator(color: Color(0xFF00CFFF)),
              ),
            )
          else if (_categories.isEmpty)
            const Expanded(
              child: Center(
                child: Text('No schedule data found.',
                    style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            )
          else ...[
            // ── Category tabs ──────────────────────────────────────────
            Container(
              color: const Color(0xFF2D0E7A),
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                indicatorColor: const Color(0xFF00CFFF),
                indicatorWeight: 3,
                labelColor: const Color(0xFF00CFFF),
                unselectedLabelColor: Colors.white54,
                labelStyle: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 1),
                tabs: _categories.map((c) {
                  return Tab(
                      text: (c['category_type'] ?? '')
                          .toString()
                          .toUpperCase());
                }).toList(),
              ),
            ),

            // ── Tab views ──────────────────────────────────────────────
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: _categories.map((cat) {
                  final catId =
                      int.tryParse(cat['category_id'].toString()) ?? 0;
                  final matches = _scheduleByCategory[catId] ?? [];
                  return _buildCategoryView(cat, catId, matches);
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Category view ────────────────────────────────────────────────────────
  Widget _buildCategoryView(
    Map<String, dynamic> category,
    int catId,
    List<Map<String, dynamic>> matches,
  ) {
    // Determine dynamic arena count
    int maxArenas = 1;
    for (final m in matches) {
      final teams = (m['teams'] as List).length;
      if (teams > maxArenas) maxArenas = teams;
    }

    final categoryName =
        (category['category_type'] ?? '').toString().toUpperCase();

    return Column(
      children: [
        // ── Category title bar ───────────────────────────────────────
        Container(
          width: double.infinity,
          color: const Color(0xFF2D0E7A),
          padding:
              const EdgeInsets.symmetric(vertical: 14, horizontal: 32),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('ROBOVENTURE',
                  style: TextStyle(
                      color: Colors.white54,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2)),
              Text(
                categoryName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              // Print + Refresh buttons
              Row(
                children: [
                  IconButton(
                    tooltip: 'Export PDF',
                    icon: const Icon(Icons.picture_as_pdf,
                        color: Color(0xFF00CFFF)),
                    onPressed: () => _exportPdf(category, matches),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh, color: Color(0xFF00CFFF)),
                    onPressed: _loadData,
                  ),
                  IconButton(
                    tooltip: 'View Standings',
                    icon: const Icon(Icons.emoji_events,
                        color: Color(0xFFFFD700)),
                    onPressed: widget.onStandings,
                  ),
                  IconButton(
                    tooltip: 'Register New Team',
                    icon: const Icon(Icons.app_registration,
                        color: Color(0xFF00CFFF)),
                    onPressed: widget.onRegister,
                  ),
                ],
              ),
            ],
          ),
        ),

        // ── Table header ─────────────────────────────────────────────
        Container(
          color: const Color(0xFF5C2ECC),
          padding:
              const EdgeInsets.symmetric(vertical: 10, horizontal: 24),
          child: Row(
            children: [
              _headerCell('MATCH', flex: 1),
              _headerCell('SCHEDULE:', flex: 2),
              ...List.generate(
                maxArenas,
                (i) => _headerCell('ARENA ${i + 1}', flex: 3),
              ),
              _headerCell('STATUS', flex: 2),
            ],
          ),
        ),

        // ── Match rows ───────────────────────────────────────────────
        Expanded(
          child: matches.isEmpty
              ? const Center(
                  child: Text('No matches scheduled.',
                      style: TextStyle(color: Colors.white54, fontSize: 14)),
                )
              : ListView.builder(
                  itemCount: matches.length,
                  itemBuilder: (context, index) {
                    final match = matches[index];
                    final matchNum = match['matchNumber'] as int;
                    final schedule = match['schedule'] as String;
                    final teams = match['teams'] as List;
                    final isEven = index % 2 == 0;
                    final status = _getStatus(catId, matchNum);

                    return Container(
                      color: isEven
                          ? const Color(0xFF1E0E5A)
                          : const Color(0xFF160A42),
                      padding: const EdgeInsets.symmetric(
                          vertical: 14, horizontal: 24),
                      child: Row(
                        children: [
                          // Match number
                          Expanded(
                            flex: 1,
                            child: Text(
                              '$matchNum',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15),
                            ),
                          ),

                          // Schedule time
                          Expanded(
                            flex: 2,
                            child: Text(
                              schedule,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13),
                            ),
                          ),

                          // Dynamic arena columns
                          ...List.generate(maxArenas, (ai) {
                            if (ai < teams.length) {
                              final team =
                                  teams[ai] as Map<String, dynamic>;
                              return Expanded(
                                flex: 3,
                                child: Column(
                                  children: [
                                    Text(
                                      team['round_type']
                                              ?.toString()
                                              .toUpperCase() ??
                                          '',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                    ),
                                    Text(
                                      team['team_name']?.toString() ?? '',
                                      style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              );
                            } else {
                              return Expanded(
                                flex: 3,
                                child: const Text('—',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: Colors.white38)),
                              );
                            }
                          }),

                          // Status badge (tap to cycle)
                          Expanded(
                            flex: 2,
                            child: GestureDetector(
                              onTap: () =>
                                  _cycleStatus(catId, matchNum),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color:
                                      status.color.withOpacity(0.2),
                                  borderRadius:
                                      BorderRadius.circular(20),
                                  border: Border.all(
                                      color: status.color, width: 1.5),
                                ),
                                child: Text(
                                  status.label,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: status.color,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ── Header ───────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF2D0E7A),
      padding:
          const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: const TextSpan(
                  children: [
                    TextSpan(
                        text: 'Make',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold)),
                    TextSpan(
                        text: 'bl',
                        style: TextStyle(
                            color: Color(0xFF00CFFF),
                            fontSize: 22,
                            fontWeight: FontWeight.bold)),
                    TextSpan(
                        text: 'ock',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const Text('Construct Your Dreams',
                  style:
                      TextStyle(color: Colors.white54, fontSize: 10)),
            ],
          ),
          Image.asset('assets/images/CenterLogo.png',
              height: 80, fit: BoxFit.contain),
          const Text('CREOTEC',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 3)),
        ],
      ),
    );
  }

  // ── Helper: header cell ──────────────────────────────────────────────────
  Widget _headerCell(String text, {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 13,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}