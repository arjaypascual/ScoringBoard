import 'dart:async';
import 'dart:math';
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

// ── Bracket data models ──────────────────────────────────────────────────────
class BracketTeam {
  final int    teamId;
  final String teamName;
  bool   isBye;
  int?   score;

  BracketTeam({
    required this.teamId,
    required this.teamName,
    this.isBye  = false,
    this.score,
  });
}

class BracketMatch {
  final String   id;
  BracketTeam    team1;
  BracketTeam    team2;
  BracketTeam?   winner;
  final int      round;      // 0-indexed
  final int      position;   // index within round

  BracketMatch({
    required this.id,
    required this.team1,
    required this.team2,
    required this.round,
    required this.position,
    this.winner,
  });
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

  String _lastDataSignature = '';

  // ── Soccer bracket state ─────────────────────────────────────────────────
  // categoryId of Soccer (detected by name)
  int? _soccerCategoryId;
  // bracket rounds: list of rounds, each round is a list of BracketMatch
  List<List<BracketMatch>> _bracketRounds = [];
  // scores entered per bracket match: matchId → {team1Score, team2Score}
  final Map<String, Map<String, int?>> _bracketScores = {};

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

  String _buildSignature(List rows) =>
      rows.map((r) => r.toString()).join('|');

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

      final rows      = result.rows.map((r) => r.assoc()).toList();
      final signature = _buildSignature(rows);

      if (signature != _lastDataSignature) {
        _lastDataSignature = signature;
        await _loadData(initial: false);
      }
    } catch (_) {}
  }

  // ── Load data ────────────────────────────────────────────────────────────
  Future<void> _loadData({bool initial = false}) async {
    if (initial) setState(() => _isLoading = true);

    try {
      final categories = await DBHelper.getCategories();
      final conn       = await DBHelper.getConnection();

      final result = await conn.execute("""
        SELECT
          c.category_id,
          c.category_type,
          ts.teamschedule_id,
          ts.match_id,
          ts.round_id,
          ts.arena_number,
          t.team_id,
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
      _lastDataSignature = _buildSignature(rows);

      final Map<int, Map<int, Map<String, dynamic>>> grouped    = {};
      final Map<int, int>                            _arenaCounter = {};

      // Detect soccer category id
      int? soccerCatId;
      for (final cat in categories) {
        final name = (cat['category_type'] ?? '').toString().toLowerCase();
        if (name.contains('soccer')) {
          soccerCatId = int.tryParse(cat['category_id'].toString());
          break;
        }
      }

      // Collect soccer team ids for bracket building
      final Set<int>                 soccerTeamIdsSeen = {};
      final Map<int, String>         soccerTeamNames   = {};

      for (final row in rows) {
        final catId   = int.tryParse(row['category_id'].toString()) ?? 0;
        final matchId = int.tryParse(row['match_id'].toString())    ?? 0;
        final teamId  = int.tryParse(row['team_id']?.toString()  ?? '0') ?? 0;
        int arenaNum  = int.tryParse(row['arena_number']?.toString() ?? '0') ?? 0;
        if (arenaNum <= 0) {
          _arenaCounter[matchId] = (_arenaCounter[matchId] ?? 0) + 1;
          arenaNum = _arenaCounter[matchId]!;
        }

        // Collect soccer teams
        if (catId == soccerCatId && teamId > 0) {
          soccerTeamIdsSeen.add(teamId);
          soccerTeamNames[teamId] = row['team_name']?.toString() ?? 'Team $teamId';
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

      // ── Build soccer bracket from registered teams ──────────────────────
      List<List<BracketMatch>> bracketRounds = [];
      if (soccerCatId != null && soccerTeamIdsSeen.isNotEmpty) {
        // If bracket was previously built, keep it; else build fresh
        if (_bracketRounds.isEmpty) {
          bracketRounds = _buildBracket(
            soccerTeamIdsSeen.toList(),
            soccerTeamNames,
          );
        } else {
          bracketRounds = _bracketRounds;
          // Update team names in case they changed
          _refreshBracketTeamNames(bracketRounds, soccerTeamNames);
        }
      }

      final previousTabIndex = _tabController?.index ?? 0;
      _tabController?.dispose();
      _tabController = TabController(
        length: categories.length,
        vsync: this,
        initialIndex:
            previousTabIndex.clamp(0, (categories.length - 1).clamp(0, 9999)),
      );

      setState(() {
        _categories         = categories;
        _scheduleByCategory = scheduleByCategory;
        _soccerCategoryId   = soccerCatId;
        _bracketRounds      = bracketRounds;
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

  // ── Build bracket rounds from team list ──────────────────────────────────
  List<List<BracketMatch>> _buildBracket(
    List<int> teamIds,
    Map<int, String> teamNames,
  ) {
    // Pad to next power of 2 with BYEs
    int needed = 2;
    while (needed < teamIds.length) needed *= 2;

    final teams = teamIds
        .map((id) => BracketTeam(teamId: id, teamName: teamNames[id] ?? 'Team $id'))
        .toList();
    // Add BYEs
    int byeCounter = 0;
    while (teams.length < needed) {
      teams.add(BracketTeam(teamId: -(++byeCounter), teamName: 'BYE', isBye: true));
    }

    // Build first round
    List<BracketMatch> firstRound = [];
    for (int i = 0; i < teams.length; i += 2) {
      final m = BracketMatch(
        id:       'r0m${i ~/ 2}',
        team1:    teams[i],
        team2:    teams[i + 1],
        round:    0,
        position: i ~/ 2,
      );
      // Only auto-advance if exactly ONE side is BYE (not BYE vs BYE)
      if (!teams[i].isBye && teams[i + 1].isBye)  m.winner = teams[i];
      if (teams[i].isBye  && !teams[i + 1].isBye) m.winner = teams[i + 1];
      // BYE vs BYE → no winner, slot stays hidden
      firstRound.add(m);
    }

    List<List<BracketMatch>> rounds = [firstRound];
    int roundNum = 1;
    List<BracketMatch> prev = firstRound;

    while (prev.length > 1) {
      List<BracketMatch> current = [];
      for (int i = 0; i < prev.length; i += 2) {
        current.add(BracketMatch(
          id:       'r${roundNum}m${i ~/ 2}',
          team1:    prev[i].winner   ?? BracketTeam(teamId: -99, teamName: 'TBD'),
          team2:    prev[i+1].winner ?? BracketTeam(teamId: -99, teamName: 'TBD'),
          round:    roundNum,
          position: i ~/ 2,
        ));
      }
      rounds.add(current);
      prev = current;
      roundNum++;
    }

    return rounds;
  }

  void _refreshBracketTeamNames(
      List<List<BracketMatch>> rounds, Map<int, String> names) {
    for (final round in rounds) {
      for (final match in round) {
        if (names.containsKey(match.team1.teamId))
          match.team1 = BracketTeam(
              teamId: match.team1.teamId,
              teamName: names[match.team1.teamId]!,
              isBye: match.team1.isBye);
        if (names.containsKey(match.team2.teamId))
          match.team2 = BracketTeam(
              teamId: match.team2.teamId,
              teamName: names[match.team2.teamId]!,
              isBye: match.team2.isBye);
      }
    }
  }

  // ── Rebuild bracket (reset scores) ──────────────────────────────────────
  void _rebuildBracket() {
    if (_soccerCategoryId == null) return;
    final matches = _scheduleByCategory[_soccerCategoryId] ?? [];
    final Map<int, String> teamNames = {};
    for (final m in matches) {
      for (final arena in (m['arenas'] as List)) {
        if (arena != null) {
          // We don't have teamId here, so refetch from DB
        }
      }
    }
    // Re-fetch teams from DB and rebuild
    DBHelper.getTeamsByCategory(_soccerCategoryId!).then((teams) {
      final ids   = teams.map((t) => int.parse(t['team_id'].toString())).toList();
      final names = {
        for (final t in teams)
          int.parse(t['team_id'].toString()): t['team_name'].toString()
      };
      setState(() {
        _bracketScores.clear();
        _bracketRounds = _buildBracket(ids, names);
      });
    });
  }

  // ── Set match result manually ────────────────────────────────────────────
  void _setMatchResult(BracketMatch match, BracketTeam winner) {
    setState(() {
      match.winner = winner;
      _propagateWinner(match);
    });
  }

  void _propagateWinner(BracketMatch match) {
    // Never propagate a BYE into the next round
    if (match.winner == null || match.winner!.isBye) return;
    final nextRoundIdx = match.round + 1;
    if (nextRoundIdx >= _bracketRounds.length) return;
    final nextRound    = _bracketRounds[nextRoundIdx];
    final nextMatchIdx = match.position ~/ 2;
    if (nextMatchIdx >= nextRound.length) return;
    final nextMatch = nextRound[nextMatchIdx];
    if (match.position % 2 == 0) {
      nextMatch.team1 = match.winner!;
    } else {
      nextMatch.team2 = match.winner!;
    }
  }

  // ── Format time ─────────────────────────────────────────────────────────
  String _fmt(String? t) {
    if (t == null || t.isEmpty) return '--:--';
    final parts = t.split(':');
    if (parts.length < 2) return t;
    return '${parts[0]}:${parts[1]}';
  }

  String _statusKey(int catId, int matchNumber) => '$catId-$matchNumber';
  MatchStatus _getStatus(int catId, int matchNumber) =>
      _statusMap[_statusKey(catId, matchNumber)] ?? MatchStatus.pending;

  void _cycleStatus(int catId, int matchNumber) {
    final key     = _statusKey(catId, matchNumber);
    final current = _statusMap[key] ?? MatchStatus.pending;
    setState(() {
      switch (current) {
        case MatchStatus.pending:    _statusMap[key] = MatchStatus.inProgress; break;
        case MatchStatus.inProgress: _statusMap[key] = MatchStatus.done;       break;
        case MatchStatus.done:       _statusMap[key] = MatchStatus.pending;    break;
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
                                pw.Text(team['round_type']?.toString() ?? '',
                                    textAlign: pw.TextAlign.center,
                                    style: pw.TextStyle(
                                        fontSize: 10,
                                        fontWeight: pw.FontWeight.bold)),
                                pw.Text(team['team_name']?.toString() ?? '',
                                    textAlign: pw.TextAlign.center,
                                    style: const pw.TextStyle(fontSize: 9)),
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
                  final isSoccer = catId == _soccerCategoryId;
                  return isSoccer
                      ? _buildSoccerView(cat, catId, matches)
                      : _buildCategoryView(cat, catId, matches);
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Soccer view: schedule + bracket tabs ─────────────────────────────────
  Widget _buildSoccerView(
    Map<String, dynamic> category,
    int catId,
    List<Map<String, dynamic>> matches,
  ) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          // Title bar
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
                const Text('SOCCER',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2)),
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Export PDF',
                      icon: const Icon(Icons.picture_as_pdf, color: Color(0xFF00CFFF)),
                      onPressed: () => _exportPdf(category, matches),
                    ),
                    _buildLiveIndicator(),
                    IconButton(
                      tooltip: 'View Standings',
                      icon: const Icon(Icons.emoji_events, color: Color(0xFFFFD700)),
                      onPressed: widget.onStandings,
                    ),
                    IconButton(
                      tooltip: 'Register New Team',
                      icon: const Icon(Icons.app_registration, color: Color(0xFF00CFFF)),
                      onPressed: widget.onRegister,
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Sub-tabs: Schedule | Bracket
          Container(
            color: const Color(0xFF1E0A60),
            child: const TabBar(
              indicatorColor: Color(0xFF00FF88),
              indicatorWeight: 3,
              labelColor: Color(0xFF00FF88),
              unselectedLabelColor: Colors.white38,
              labelStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1),
              tabs: [
                Tab(icon: Icon(Icons.calendar_today, size: 16), text: 'SCHEDULE'),
                Tab(icon: Icon(Icons.account_tree,   size: 16), text: 'BRACKET'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                // ── Schedule tab (same as other categories) ────────────────
                _buildScheduleTable(category, catId, matches),
                // ── Bracket tab ────────────────────────────────────────────
                _buildBracketTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Schedule table (extracted so soccer can reuse it) ────────────────────
  Widget _buildScheduleTable(
    Map<String, dynamic> category,
    int catId,
    List<Map<String, dynamic>> matches,
  ) {
    int maxArenas = 1;
    for (final m in matches) {
      final count = m['arenaCount'] as int? ?? 1;
      if (count > maxArenas) maxArenas = count;
    }

    return Column(
      children: [
        // Table header
        Container(
          color: const Color(0xFF5C2ECC),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 24),
          child: Row(
            children: [
              _headerCell('MATCH',     flex: 1, center: false),
              _headerCell('SCHEDULE:', flex: 2, center: false),
              if (maxArenas == 1) const Spacer(flex: 2),
              ...List.generate(
                maxArenas,
                (i) => _headerCell('ARENA ${i + 1}', flex: 3, center: true),
              ),
              if (maxArenas == 1) const Spacer(flex: 2),
              _headerCell('STATUS', flex: 2, center: true),
            ],
          ),
        ),
        // Match rows
        Expanded(
          child: matches.isEmpty
              ? const Center(
                  child: Text('No matches scheduled.',
                      style: TextStyle(color: Colors.white54, fontSize: 14)))
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
                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 1,
                            child: Text('$matchNum',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15)),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(schedule,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 13)),
                          ),
                          if (maxArenas == 1) const Spacer(flex: 2),
                          ...List.generate(maxArenas, (ai) {
                            final team = ai < arenas.length
                                ? arenas[ai] as Map<String, dynamic>?
                                : null;
                            if (team != null) {
                              return Expanded(
                                flex: 3,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      (team['round_type']?.toString().toUpperCase() ?? ''),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color: Color(0xFF00CFFF),
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12),
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
                          if (maxArenas == 1) const Spacer(flex: 2),
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
                                  border: Border.all(
                                      color: status.color, width: 1.5),
                                ),
                                child: Text(
                                  status.label,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: status.color,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11),
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

  // ── Bracket tab ──────────────────────────────────────────────────────────
  Widget _buildBracketTab() {
    if (_bracketRounds.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.sports_soccer,
                size: 64, color: Colors.white.withOpacity(0.15)),
            const SizedBox(height: 16),
            const Text('No soccer teams registered yet.',
                style: TextStyle(color: Colors.white54, fontSize: 16)),
            const SizedBox(height: 8),
            const Text('Register teams first, then the bracket will auto-build.',
                style: TextStyle(color: Colors.white24, fontSize: 13)),
          ],
        ),
      );
    }

    final totalRounds = _bracketRounds.length;
    final champion    = _bracketRounds.last.first.winner;

    return Column(
      children: [
        // Bracket toolbar
        Container(
          color: const Color(0xFF160A42),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 18),
              const SizedBox(width: 8),
              Text(
                '${_bracketRounds[0].length * 2 - (_bracketRounds[0].where((m) => m.team2.isBye || m.team1.isBye).length)} Teams · $totalRounds Rounds',
                style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
              ),
              if (champion != null) ...[
                const SizedBox(width: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFD700).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFFD700), width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star, color: Color(0xFFFFD700), size: 14),
                      const SizedBox(width: 4),
                      Text('Champion: ${champion.teamName}',
                          style: const TextStyle(
                              color: Color(0xFFFFD700),
                              fontSize: 12,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
              const Spacer(),
              const Text('Tap a match card to set winner',
                  style: TextStyle(color: Color(0xFF4B5563), fontSize: 11)),
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: _rebuildBracket,
                icon: const Icon(Icons.refresh, size: 14, color: Color(0xFF00CFFF)),
                label: const Text('Rebuild',
                    style: TextStyle(color: Color(0xFF00CFFF), fontSize: 12)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  side: const BorderSide(color: Color(0xFF00CFFF), width: 1),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                ),
              ),
            ],
          ),
        ),
        // Round labels
        Container(
          color: const Color(0xFF120840),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: List.generate(totalRounds, (i) {
              String label;
              if (i == totalRounds - 1)       label = 'FINAL';
              else if (i == totalRounds - 2)  label = 'SEMI-FINAL';
              else if (i == totalRounds - 3)  label = 'QUARTER-FINAL';
              else                             label = 'ROUND ${i + 1}';
              return Expanded(
                child: Text(label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 10,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.bold)),
              );
            }),
          ),
        ),
        // Bracket canvas — fills all remaining space
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final availW = constraints.maxWidth;
              final availH = constraints.maxHeight;
              final numRounds     = _bracketRounds.length;
              final firstRoundCnt = _bracketRounds[0].length;

              // Compute card dimensions to fill the screen
              // Horizontal: divide width equally across rounds + gaps
              const double kGapWFrac  = 0.08; // gap = 8% of slot width
              final double slotW      = availW / (numRounds + (numRounds - 1) * kGapWFrac);
              final double matchW     = slotW;
              final double gapW       = slotW * kGapWFrac;

              // Vertical: divide height equally across first-round matches + gaps
              const double kGapHFrac  = 0.12;
              final double slotH      = availH / (firstRoundCnt + (firstRoundCnt - 1) * kGapHFrac);
              final double matchH     = slotH * 0.88;
              final double gapH       = slotH * kGapHFrac;

              // If teams are few, cap card size so it doesn't look oversized
              final double finalMatchW = matchW.clamp(160.0, 280.0);
              final double finalMatchH = matchH.clamp(52.0, 100.0);
              final double finalGapW   = gapW.clamp(28.0, 80.0);
              final double finalGapH   = gapH.clamp(8.0,  40.0);

              // If computed total fits the screen, use FittedBox; else scroll
              final double totalW = numRounds * (finalMatchW + finalGapW) - finalGapW;
              final double totalH = firstRoundCnt * (finalMatchH + finalGapH) - finalGapH;

              final bool fitsW = totalW <= availW + 1;
              final bool fitsH = totalH <= availH + 1;

              Widget canvas = _BracketCanvas(
                rounds:    _bracketRounds,
                onMatchTap: _showMatchDialog,
                matchW:    finalMatchW,
                matchH:    finalMatchH,
                gapW:      finalGapW,
                gapH:      finalGapH,
              );

              // If it fits perfectly, expand to fill
              if (fitsW && fitsH) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: availW - 32,
                    height: availH - 32,
                    child: _BracketCanvas(
                      rounds:     _bracketRounds,
                      onMatchTap: _showMatchDialog,
                      matchW:     (availW - 32 - (numRounds - 1) * finalGapW) / numRounds,
                      matchH:     (availH - 32 - (firstRoundCnt - 1) * finalGapH) / firstRoundCnt * 0.88,
                      gapW:       finalGapW,
                      gapH:       finalGapH,
                    ),
                  ),
                );
              }

              // Otherwise wrap in interactive viewer + scroll
              return InteractiveViewer(
                boundaryMargin: const EdgeInsets.all(60),
                minScale: 0.2,
                maxScale: 3.0,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: canvas,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ── Match result dialog ──────────────────────────────────────────────────
  void _showMatchDialog(BracketMatch match) {
    final bool team1Real = !match.team1.isBye && match.team1.teamName != 'TBD';
    final bool team2Real = !match.team2.isBye && match.team2.teamName != 'TBD';

    // Both sides are BYE or TBD — nothing to do, don't advance anything
    if (!team1Real && !team2Real) return;

    // Exactly one real team — auto-advance that team silently (no dialog)
    if (team1Real && !team2Real) {
      _setMatchResult(match, match.team1);
      return;
    }
    if (team2Real && !team1Real) {
      _setMatchResult(match, match.team2);
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1040),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Set Match Winner',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Who won this match?',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 16),
            _winnerButton(ctx, match, match.team1),
            const SizedBox(height: 8),
            _winnerButton(ctx, match, match.team2),
            if (match.winner != null) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  setState(() { match.winner = null; });
                  Navigator.pop(ctx);
                },
                child: const Text('Clear result',
                    style: TextStyle(color: Colors.red)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _winnerButton(BuildContext ctx, BracketMatch match, BracketTeam team) {
    final isWinner = match.winner?.teamId == team.teamId;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: () {
          _setMatchResult(match, team);
          Navigator.pop(ctx);
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: isWinner
              ? const Color(0xFF00FF88).withOpacity(0.2)
              : const Color(0xFF2D1060),
          foregroundColor: isWinner ? const Color(0xFF00FF88) : Colors.white,
          side: BorderSide(
              color: isWinner ? const Color(0xFF00FF88) : const Color(0xFF3D2080),
              width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isWinner) const Icon(Icons.check_circle, size: 16),
            if (isWinner) const SizedBox(width: 6),
            Text(team.teamName,
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  // ── Category view (non-soccer) ───────────────────────────────────────────
  Widget _buildCategoryView(
    Map<String, dynamic> category,
    int catId,
    List<Map<String, dynamic>> matches,
  ) {
    final categoryName =
        (category['category_type'] ?? '').toString().toUpperCase();

    return Column(
      children: [
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
              Text(categoryName,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2)),
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
        Expanded(child: _buildScheduleTable(category, catId, matches)),
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

// ── Bracket canvas widget ────────────────────────────────────────────────────
class _BracketCanvas extends StatelessWidget {
  final List<List<BracketMatch>> rounds;
  final void Function(BracketMatch) onMatchTap;
  final double matchW;
  final double matchH;
  final double gapW;
  final double gapH;

  const _BracketCanvas({
    required this.rounds,
    required this.onMatchTap,
    this.matchW = 220.0,
    this.matchH = 70.0,
    this.gapW   = 48.0,
    this.gapH   = 14.0,
  });

  @override
  Widget build(BuildContext context) {
    final numRounds     = rounds.length;
    final firstRoundCnt = rounds[0].length;
    final totalH = firstRoundCnt * (matchH + gapH) - gapH;
    final totalW = numRounds    * (matchW + gapW)  - gapW;

    return SizedBox(
      width: totalW,
      height: totalH,
      child: Stack(
        children: [
          CustomPaint(
            size: Size(totalW, totalH),
            painter: _BracketLinePainter(
                rounds: rounds,
                matchW: matchW,
                matchH: matchH,
                gapH:   gapH,
                gapW:   gapW),
          ),
          for (int r = 0; r < rounds.length; r++)
            for (int m = 0; m < rounds[r].length; m++)
              _positionedCard(r, m, totalH),
        ],
      ),
    );
  }

  Offset _offset(int round, int matchIdx, double totalH) {
    final matchesInRound = rounds[round].length;
    final slotH = totalH / matchesInRound;
    final x = round * (matchW + gapW);
    final y = (matchIdx + 0.5) * slotH - matchH / 2;
    return Offset(x, y);
  }

  Widget _positionedCard(int r, int m, double totalH) {
    final off   = _offset(r, m, totalH);
    final match = rounds[r][m];
    return Positioned(
      left: off.dx, top: off.dy,
      width: matchW, height: matchH,
      child: _MatchCard(match: match, onTap: () => onMatchTap(match), cardH: matchH),
    );
  }
}

// ── Line painter ─────────────────────────────────────────────────────────────
class _BracketLinePainter extends CustomPainter {
  final List<List<BracketMatch>> rounds;
  final double matchW, matchH, gapH, gapW;

  const _BracketLinePainter({
    required this.rounds,
    required this.matchW,
    required this.matchH,
    required this.gapH,
    required this.gapW,
  });

  Offset _rightCenter(int round, int matchIdx, double totalH) {
    final matchesInRound = rounds[round].length;
    final slotH = totalH / matchesInRound;
    return Offset(
      round * (matchW + gapW) + matchW,
      (matchIdx + 0.5) * slotH,
    );
  }

  Offset _leftCenter(int round, int matchIdx, double totalH) {
    final matchesInRound = rounds[round].length;
    final slotH = totalH / matchesInRound;
    return Offset(
      round * (matchW + gapW),
      (matchIdx + 0.5) * slotH,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF3D2080)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    for (int r = 0; r < rounds.length - 1; r++) {
      for (int m = 0; m < rounds[r].length; m += 2) {
        final top    = _rightCenter(r, m,     size.height);
        final bot    = _rightCenter(r, m + 1, size.height);
        final midX   = top.dx + gapW / 2;
        final midY   = (top.dy + bot.dy) / 2;
        final nextM  = m ~/ 2;
        if (nextM >= rounds[r + 1].length) continue;
        final nextIn = _leftCenter(r + 1, nextM, size.height);

        // Draw bracket shape
        final path = Path()
          ..moveTo(top.dx, top.dy)
          ..lineTo(midX, top.dy)
          ..lineTo(midX, bot.dy)
          ..lineTo(bot.dx, bot.dy);
        canvas.drawPath(path, paint);

        // Horizontal to next match
        canvas.drawLine(Offset(midX, midY), Offset(nextIn.dx, midY), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

// ── Match card widget ─────────────────────────────────────────────────────────
class _MatchCard extends StatelessWidget {
  final BracketMatch match;
  final VoidCallback onTap;
  final double cardH;

  const _MatchCard({required this.match, required this.onTap, this.cardH = 62.0});

  @override
  Widget build(BuildContext context) {
    final bool team1Real = !match.team1.isBye && match.team1.teamName != 'TBD';
    final bool team2Real = !match.team2.isBye && match.team2.teamName != 'TBD';

    // Tappable only if at least one real team exists (BYE vs BYE = not tappable)
    final canPlay = match.winner == null && (team1Real || team2Real);

    // Scale font and padding based on card height
    final double fontSize = (cardH * 0.16).clamp(10.0, 15.0);
    final double hPad     = (cardH * 0.12).clamp(6.0, 14.0);

    return GestureDetector(
      onTap: canPlay || match.winner != null ? onTap : null,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A0D4A),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: canPlay
                ? const Color(0xFF4D2DA0)
                : match.winner != null
                    ? const Color(0xFF00FF88).withOpacity(0.4)
                    : const Color(0xFF2A1560),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          children: [
            _teamRow(match.team1, match.winner == match.team1, fontSize, hPad),
            Container(height: 1, color: const Color(0xFF2A1560)),
            _teamRow(match.team2, match.winner == match.team2, fontSize, hPad),
          ],
        ),
      ),
    );
  }

  Widget _teamRow(BracketTeam team, bool isWinner, double fontSize, double hPad) {
    Color textColor = Colors.white;
    Color bg        = Colors.transparent;

    if (team.teamName == 'TBD' || team.isBye) {
      textColor = const Color(0xFF4B5070);
    } else if (isWinner) {
      bg        = const Color(0xFF00FF88).withOpacity(0.10);
      textColor = const Color(0xFF00FF88);
    } else if (match.winner != null) {
      textColor = const Color(0xFF6B6090);
    }

    return Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: hPad),
        decoration: BoxDecoration(color: bg),
        child: Row(
          children: [
            if (isWinner)
              Container(
                width: 6, height: 6,
                margin: const EdgeInsets.only(right: 6),
                decoration: const BoxDecoration(
                    color: Color(0xFF00FF88), shape: BoxShape.circle),
              ),
            Expanded(
              child: Text(
                team.teamName,
                style: TextStyle(
                    color: textColor,
                    fontSize: fontSize,
                    fontWeight: isWinner ? FontWeight.bold : FontWeight.normal),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Pulsing dot ──────────────────────────────────────────────────────────────
class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 8, height: 8,
        decoration: const BoxDecoration(
            color: Color(0xFF00FF88), shape: BoxShape.circle),
      ),
    );
  }
}