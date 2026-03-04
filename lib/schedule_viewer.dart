import 'dart:async';
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
    with TickerProviderStateMixin {
  // Tabs
  TabController? _tabController;
  List<Map<String, dynamic>> _categories = [];

  // Schedule data: category_id → list of match rows
  Map<int, List<Map<String, dynamic>>> _scheduleByCategory = {};

  // Status per match: '$categoryId-$matchIndex' → MatchStatus
  final Map<String, MatchStatus> _statusMap = {};

  bool _isLoading = true;
  DateTime? _lastUpdated;
  Timer? _autoRefreshTimer;

  // Track changes using a hash/signature instead of just count
  String _lastDataSignature = '';

  // ── Lifecycle ────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _loadData(initial: true);
    _autoRefreshTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _silentRefresh(),
    );
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _tabController?.dispose();
    super.dispose();
  }

  // ── Build a signature string to detect any data change ──────────────────
  String _buildSignature(List rows) {
    return rows.map((r) => r.toString()).join('|');
  }

  // ── Silent refresh — only rebuilds UI if data actually changed ───────────
  Future<void> _silentRefresh() async {
    try {
      final conn = await DBHelper.getConnection();
      final result = await conn.execute("""
        SELECT
          c.category_id,
          ts.teamschedule_id,
          ts.match_id,
          t.team_name,
          s.schedule_start,
          s.schedule_end
        FROM tbl_teamschedule ts
        JOIN tbl_team t     ON ts.team_id    = t.team_id
        JOIN tbl_category c ON t.category_id = c.category_id
        JOIN tbl_match m    ON ts.match_id   = m.match_id
        JOIN tbl_schedule s ON m.schedule_id = s.schedule_id
        ORDER BY c.category_id, s.schedule_start, ts.match_id
      """);

      final rows = result.rows.map((r) => r.assoc()).toList();
      final signature = _buildSignature(rows);

      if (signature != _lastDataSignature) {
        _lastDataSignature = signature;
        await _loadData(initial: false); // silent — no loading spinner
      }
    } catch (_) {}
  }

  // ── Load data ────────────────────────────────────────────────────────────
  // initial: true  → show loading spinner (first load only)
  // initial: false → update data silently, no spinner, no blink
  Future<void> _loadData({bool initial = false}) async {
    if (initial) {
      setState(() => _isLoading = true);
    }

    try {
      final categories = await DBHelper.getCategories();
      final conn = await DBHelper.getConnection();

      final result = await conn.execute("""
        SELECT
          c.category_id,
          c.category_type,
          ts.teamschedule_id,
          ts.match_id,
          ts.round_id,
          ts.arena_number,
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
        ORDER BY c.category_id, s.schedule_start, ts.match_id, ts.arena_number
      """);

      final rows = result.rows.map((r) => r.assoc()).toList();

      // Update signature on full load too
      _lastDataSignature = _buildSignature(rows);

      final Map<int, Map<int, Map<String, dynamic>>> grouped = {};
      final Map<int, int> _matchArenaCounter = {};

      for (final row in rows) {
        final catId   = int.tryParse(row['category_id'].toString()) ?? 0;
        final matchId = int.tryParse(row['match_id'].toString())    ?? 0;
        int arenaNum  = int.tryParse(row['arena_number']?.toString() ?? '0') ?? 0;
        if (arenaNum <= 0) {
          _matchArenaCounter[matchId] = (_matchArenaCounter[matchId] ?? 0) + 1;
          arenaNum = _matchArenaCounter[matchId]!;
        }

        grouped.putIfAbsent(catId, () => {});
        if (!grouped[catId]!.containsKey(matchId)) {
          grouped[catId]![matchId] = {
            'match_id':       matchId,
            'schedule':       '${_fmt(row['schedule_start'])} - ${_fmt(row['schedule_end'])}',
            'schedule_start': row['schedule_start'] ?? '',
            'arenas':         <int, Map<String, String>>{},
          };
        }
        (grouped[catId]![matchId]!['arenas']
            as Map<int, Map<String, String>>)[arenaNum] = {
          'team_name':  row['team_name']  ?? '',
          'round_type': row['round_type'] ?? '',
        };
      }

      final Map<int, List<Map<String, dynamic>>> scheduleByCategory = {};
      for (final cat in categories) {
        final catId    = int.tryParse(cat['category_id'].toString()) ?? 0;
        final matchMap = grouped[catId] ?? {};

        final matches = matchMap.values.map((m) {
          final arenasMap = m['arenas'] as Map<int, Map<String, String>>;
          final maxArena  = arenasMap.keys.isEmpty
              ? 0
              : arenasMap.keys.reduce((a, b) => a > b ? a : b);
          final arenaList = List.generate(maxArena, (i) => arenasMap[i + 1]);
          return {
            'match_id':       m['match_id'],
            'schedule':       m['schedule'],
            'schedule_start': m['schedule_start'],
            'arenaCount':     maxArena,
            'arenas':         arenaList,
          };
        }).toList();

        matches.sort((a, b) => (a['schedule_start'] as String)
            .compareTo(b['schedule_start'] as String));

        for (int i = 0; i < matches.length; i++) {
          matches[i]['matchNumber'] = i + 1;
        }

        scheduleByCategory[catId] = matches;
      }

      // Preserve current tab index before rebuilding controller
      final previousTabIndex = _tabController?.index ?? 0;

      _tabController?.dispose();
      _tabController = TabController(
        length: categories.length,
        vsync: this,
        initialIndex: previousTabIndex.clamp(0, (categories.length - 1).clamp(0, 9999)),
      );

      // Single setState — no intermediate _isLoading = true blink
      setState(() {
        _categories         = categories;
        _scheduleByCategory = scheduleByCategory;
        _isLoading          = false;
        _lastUpdated        = DateTime.now();
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
    final key     = _statusKey(catId, matchNumber);
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
    final doc          = pw.Document();
    final categoryName = (category['category_type'] ?? '').toString().toUpperCase();

    int maxArenas = 1;
    for (final m in matches) {
      final count = (m['arenaCount'] as int? ?? 1);
      if (count > maxArenas) maxArenas = count;
    }

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4.landscape,
        build: (pw.Context ctx) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Container(
                color: const PdfColor.fromInt(0xFF3D1A8C),
                padding: const pw.EdgeInsets.symmetric(vertical: 12, horizontal: 16),
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
              pw.Container(
                color: const PdfColor.fromInt(0xFF5C2ECC),
                padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 8),
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
              ...matches.asMap().entries.map((entry) {
                final i      = entry.key;
                final m      = entry.value;
                final arenas = m['arenas'] as List;
                final isEven = i % 2 == 0;
                return pw.Container(
                  color: isEven
                      ? PdfColors.white
                      : const PdfColor.fromInt(0xFFF3EEFF),
                  padding: const pw.EdgeInsets.symmetric(vertical: 10, horizontal: 8),
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
                        final team = ai < arenas.length ? arenas[ai] as Map? : null;
                        if (team != null) {
                          return pw.Expanded(
                            flex: 2,
                            child: pw.Column(
                              crossAxisAlignment: pw.CrossAxisAlignment.center,
                              children: [
                                pw.Text(
                                  team['round_type']?.toString() ?? '',
                                  textAlign: pw.TextAlign.center,
                                  style: pw.TextStyle(
                                      fontSize: 10,
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
                          return pw.Expanded(
                              flex: 2,
                              child: pw.Text('—',
                                  textAlign: pw.TextAlign.center,
                                  style: const pw.TextStyle(
                                      color: PdfColors.grey400)));
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
                      text: (c['category_type'] ?? '').toString().toUpperCase());
                }).toList(),
              ),
            ),
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

  // ── Live indicator widget ────────────────────────────────────────────────
  Widget _buildLiveIndicator() {
    final timeStr = _lastUpdated == null
        ? 'Loading...'
        : '${_lastUpdated!.hour.toString().padLeft(2, '0')}:'
          '${_lastUpdated!.minute.toString().padLeft(2, '0')}:'
          '${_lastUpdated!.second.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PulsingDot(),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('LIVE',
                  style: TextStyle(
                      color: Color(0xFF00FF88),
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
              Text(timeStr,
                  style: const TextStyle(color: Colors.white54, fontSize: 9)),
            ],
          ),
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
    int maxArenas = 1;
    for (final m in matches) {
      final count = (m['arenaCount'] as int? ?? 1);
      if (count > maxArenas) maxArenas = count;
    }

    final categoryName =
        (category['category_type'] ?? '').toString().toUpperCase();

    return Column(
      children: [
        // ── Category title bar ───────────────────────────────────────
        Container(
          width: double.infinity,
          color: const Color(0xFF2D0E7A),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 32),
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
              Row(
                children: [
                  IconButton(
                    tooltip: 'Export PDF',
                    icon: const Icon(Icons.picture_as_pdf,
                        color: Color(0xFF00CFFF)),
                    onPressed: () => _exportPdf(category, matches),
                  ),
                  _buildLiveIndicator(),
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
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 24),
          child: Row(
            children: [
              _headerCell('MATCH',     flex: 1, center: false),
              _headerCell('SCHEDULE:', flex: 2, center: false),
              ...List.generate(
                maxArenas,
                (i) => _headerCell('ARENA ${i + 1}', flex: 3, center: true),
              ),
              _headerCell('STATUS', flex: 2, center: true),
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
                    final match    = matches[index];
                    final matchNum = match['matchNumber'] as int;
                    final schedule = match['schedule'] as String;
                    final arenas   = match['arenas'] as List;
                    final isEven   = index % 2 == 0;
                    final status   = _getStatus(catId, matchNum);

                    return Container(
                      color: isEven
                          ? const Color(0xFF1E0E5A)
                          : const Color(0xFF160A42),
                      padding: const EdgeInsets.symmetric(
                          vertical: 14, horizontal: 24),
                      child: Row(
                        children: [
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
                          Expanded(
                            flex: 2,
                            child: Text(
                              schedule,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13),
                            ),
                          ),
                          ...List.generate(maxArenas, (ai) {
                            final team = ai < arenas.length
                                ? arenas[ai] as Map<String, dynamic>?
                                : null;
                            if (team != null) {
                              return Expanded(
                                flex: 3,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Text(
                                      (team['round_type']
                                                  ?.toString()
                                                  .toUpperCase() ??
                                              ''),
                                      style: const TextStyle(
                                        color: Color(0xFF00CFFF),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Text(
                                      team['team_name']?.toString() ?? '',
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600),
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
                                        color: Colors.white24, fontSize: 13)),
                              );
                            }
                          }),
                          Expanded(
                            flex: 2,
                            child: GestureDetector(
                              onTap: () => _cycleStatus(catId, matchNum),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: status.color.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(20),
                                  border:
                                      Border.all(color: status.color, width: 1.5),
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
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
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
                  style: TextStyle(color: Colors.white54, fontSize: 10)),
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

  Widget _headerCell(String text, {int flex = 1, bool center = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        textAlign: center ? TextAlign.center : TextAlign.left,
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

// ── Pulsing dot animation ─────────────────────────────────────────────────────
class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: Color(0xFF00FF88),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}