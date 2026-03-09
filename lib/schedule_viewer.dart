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
  final int      round;
  final int      position;

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
  TabController? _tabController;
  List<Map<String, dynamic>> _categories = [];
  Map<int, List<Map<String, dynamic>>> _scheduleByCategory = {};
  final Map<String, MatchStatus> _statusMap = {};
  bool _isLoading = true;
  DateTime? _lastUpdated;
  Timer? _autoRefreshTimer;
  String _lastDataSignature = '';

  int? _soccerCategoryId;
  List<List<BracketMatch>> _bracketRounds = [];
  final Map<String, Map<String, int?>> _bracketScores = {};

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
        SELECT c.category_id, ts.match_id, t.team_name, s.schedule_start
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

  Future<void> _loadData({bool initial = false}) async {
    if (initial) setState(() => _isLoading = true);
    try {
      final categories = await DBHelper.getCategories();
      final conn       = await DBHelper.getConnection();

      final result = await conn.execute("""
        SELECT c.category_id, c.category_type,
               ts.teamschedule_id, ts.match_id, ts.round_id, ts.arena_number,
               t.team_id, t.team_name,
               s.schedule_start, s.schedule_end, r.round_type
        FROM tbl_teamschedule ts
        JOIN tbl_team t     ON ts.team_id    = t.team_id
        JOIN tbl_category c ON t.category_id = c.category_id
        JOIN tbl_match m    ON ts.match_id   = m.match_id
        JOIN tbl_schedule s ON m.schedule_id = s.schedule_id
        JOIN tbl_round r    ON ts.round_id   = r.round_id
        ORDER BY c.category_id, s.schedule_start, ts.match_id, ts.arena_number
      """);

      final rows = result.rows.map((r) => r.assoc()).toList();
      _lastDataSignature = _buildSignature(rows);

      final Map<int, Map<int, Map<String, dynamic>>> grouped      = {};
      final Map<int, int>                            arenaCounter = {};

      int? soccerCatId;
      for (final cat in categories) {
        final name = (cat['category_type'] ?? '').toString().toLowerCase();
        if (name.contains('soccer')) {
          soccerCatId = int.tryParse(cat['category_id'].toString());
          break;
        }
      }

      for (final row in rows) {
        final catId   = int.tryParse(row['category_id'].toString()) ?? 0;
        final matchId = int.tryParse(row['match_id'].toString())    ?? 0;
        int   arenaNum = int.tryParse(row['arena_number']?.toString() ?? '0') ?? 0;
        if (arenaNum <= 0) {
          arenaCounter[matchId] = (arenaCounter[matchId] ?? 0) + 1;
          arenaNum = arenaCounter[matchId]!;
        }
        grouped.putIfAbsent(catId, () => {});
        if (!grouped[catId]!.containsKey(matchId)) {
          grouped[catId]![matchId] = {
            'match_id':       matchId,
            'schedule':       '${_fmt(row['schedule_start'])} - ${_fmt(row['schedule_end'])}',
            'schedule_start': row['schedule_start'] ?? '',
            'arenas':         <int, Map<String, String>>{},
            'teams_list':     <Map<String, String>>[],  // ordered append list
          };
        }
        // Store by arena slot as before
        (grouped[catId]![matchId]!['arenas'] as Map<int, Map<String, String>>)[arenaNum] = {
          'team_name':  row['team_name']  ?? '',
          'round_type': row['round_type'] ?? '',
        };
        // Also append to ordered list (handles duplicates by always adding)
        (grouped[catId]![matchId]!['teams_list'] as List<Map<String, String>>).add({
          'team_name':  row['team_name']  ?? '',
          'round_type': row['round_type'] ?? '',
        });
      }

      final Map<int, List<Map<String, dynamic>>> scheduleByCategory = {};
      for (final cat in categories) {
        final catId    = int.tryParse(cat['category_id'].toString()) ?? 0;
        final matchMap = grouped[catId] ?? {};
        final matches  = matchMap.values.map((m) {
          final am         = m['arenas']     as Map<int, Map<String, String>>;
          final teamsList  = m['teams_list'] as List<Map<String, String>>;
          final maxArena   = am.keys.isEmpty ? 0 : am.keys.reduce((a, b) => a > b ? a : b);

          // If only 1 arena slot but 2+ teams in list, build arenas from the list
          List<Map<String, String>?> arenaList;
          if (maxArena <= 1 && teamsList.length >= 2) {
            arenaList = teamsList.take(2).map((t) => t).toList();
          } else {
            arenaList = List.generate(maxArena, (i) => am[i + 1]);
          }

          return {
            'match_id':       m['match_id'],
            'schedule':       m['schedule'],
            'schedule_start': m['schedule_start'],
            'arenaCount':     arenaList.length,
            'arenas':         arenaList,
          };
        }).toList();
        matches.sort((a, b) =>
            (a['schedule_start'] as String).compareTo(b['schedule_start'] as String));
        for (int i = 0; i < matches.length; i++) matches[i]['matchNumber'] = i + 1;
        scheduleByCategory[catId] = matches;
      }

      // ── Build soccer bracket directly from tbl_team ──────────────────────
      List<List<BracketMatch>> bracketRounds = [];
      if (soccerCatId != null) {
        final teamRows = await DBHelper.getTeamsByCategory(soccerCatId);
        if (teamRows.isNotEmpty) {
          final ids   = teamRows.map((t) => int.parse(t['team_id'].toString())).toList();
          final names = {
            for (final t in teamRows)
              int.parse(t['team_id'].toString()): t['team_name'].toString()
          };
          bracketRounds = _bracketRounds.isEmpty
              ? _buildBracket(ids, names)
              : _bracketRounds.also((_) => _refreshBracketTeamNames(_bracketRounds, names));
        }
      }

      final prevIdx = _tabController?.index ?? 0;
      _tabController?.dispose();
      _tabController = TabController(
        length: categories.length,
        vsync:  this,
        initialIndex: prevIdx.clamp(0, (categories.length - 1).clamp(0, 9999)),
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Failed to load: $e'), backgroundColor: Colors.red));
    }
  }

  List<List<BracketMatch>> _buildBracket(List<int> teamIds, Map<int, String> names) {
    int needed = 2;
    while (needed < teamIds.length) needed *= 2;

    final teams = teamIds
        .map((id) => BracketTeam(teamId: id, teamName: names[id] ?? 'Team $id'))
        .toList();
    int byeN = 0;
    while (teams.length < needed)
      teams.add(BracketTeam(teamId: -(++byeN), teamName: 'BYE', isBye: true));

    List<BracketMatch> firstRound = [];
    for (int i = 0; i < teams.length; i += 2) {
      final m = BracketMatch(
        id: 'r0m${i ~/ 2}', team1: teams[i], team2: teams[i + 1],
        round: 0, position: i ~/ 2);
      if (!teams[i].isBye && teams[i + 1].isBye)  m.winner = teams[i];
      if (teams[i].isBye  && !teams[i + 1].isBye) m.winner = teams[i + 1];
      firstRound.add(m);
    }

    List<List<BracketMatch>> rounds = [firstRound];
    int roundNum = 1;
    List<BracketMatch> prev = firstRound;
    while (prev.length > 1) {
      List<BracketMatch> current = [];
      for (int i = 0; i < prev.length; i += 2) {
        current.add(BracketMatch(
          id: 'r${roundNum}m${i ~/ 2}',
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

  void _refreshBracketTeamNames(List<List<BracketMatch>> rounds, Map<int, String> names) {
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

  void _rebuildBracket() {
    if (_soccerCategoryId == null) return;
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

  void _setMatchResult(BracketMatch match, BracketTeam winner) {
    setState(() {
      match.winner = winner;
      _propagateWinner(match);
    });
  }

  void _propagateWinner(BracketMatch match) {
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

  // ── Clear result + recursively reset all downstream rounds ───────────────
  void _clearMatchResult(BracketMatch match) {
    void resetDownstream(BracketMatch m) {
      final nextRoundIdx = m.round + 1;
      if (nextRoundIdx >= _bracketRounds.length) return;
      final nextRound    = _bracketRounds[nextRoundIdx];
      final nextMatchIdx = m.position ~/ 2;
      if (nextMatchIdx >= nextRound.length) return;
      final nextMatch  = nextRound[nextMatchIdx];
      final feedsTeam1 = m.position % 2 == 0;
      if (feedsTeam1 && nextMatch.team1.teamId == m.winner?.teamId)
        nextMatch.team1 = BracketTeam(teamId: -99, teamName: 'TBD');
      else if (!feedsTeam1 && nextMatch.team2.teamId == m.winner?.teamId)
        nextMatch.team2 = BracketTeam(teamId: -99, teamName: 'TBD');
      if (nextMatch.winner != null) {
        resetDownstream(nextMatch);
        nextMatch.winner = null;
      }
    }
    setState(() {
      resetDownstream(match);
      match.winner = null;
    });
  }

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
    doc.addPage(pw.Page(
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
                  pw.Text('ROBOVENTURE', style: pw.TextStyle(color: PdfColors.white, fontSize: 14, fontWeight: pw.FontWeight.bold)),
                  pw.Text(categoryName, style: pw.TextStyle(color: PdfColors.white, fontSize: 20, fontWeight: pw.FontWeight.bold)),
                  pw.Text('4TH ROBOTICS COMPETITION', style: const pw.TextStyle(color: PdfColors.white, fontSize: 10)),
                ],
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Container(
              color: const PdfColor.fromInt(0xFF5C2ECC),
              padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: pw.Row(children: [
                pw.Expanded(flex: 1, child: pw.Text('MATCH', style: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 11))),
                pw.Expanded(flex: 2, child: pw.Text('SCHEDULE', style: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 11))),
                ...List.generate(maxArenas, (i) => pw.Expanded(
                  flex: 2,
                  child: pw.Text('ARENA ${i + 1}', textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 11)),
                )),
              ]),
            ),
            ...matches.asMap().entries.map((entry) {
              final i = entry.key; final m = entry.value;
              final arenas = m['arenas'] as List;
              return pw.Container(
                color: i % 2 == 0 ? PdfColors.white : const PdfColor.fromInt(0xFFF3EEFF),
                padding: const pw.EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                child: pw.Row(children: [
                  pw.Expanded(flex: 1, child: pw.Text('${m['matchNumber']}', style: const pw.TextStyle(fontSize: 11))),
                  pw.Expanded(flex: 2, child: pw.Text('${m['schedule']}', style: const pw.TextStyle(fontSize: 11))),
                  ...List.generate(maxArenas, (ai) {
                    final team = ai < arenas.length ? arenas[ai] as Map? : null;
                    if (team != null) {
                      return pw.Expanded(flex: 2, child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.center,
                        children: [
                          pw.Text(team['round_type']?.toString() ?? '', textAlign: pw.TextAlign.center,
                              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                          pw.Text(team['team_name']?.toString() ?? '', textAlign: pw.TextAlign.center,
                              style: const pw.TextStyle(fontSize: 9)),
                        ],
                      ));
                    }
                    return pw.Expanded(flex: 2, child: pw.Text('—',
                        textAlign: pw.TextAlign.center, style: const pw.TextStyle(color: PdfColors.grey400)));
                  }),
                ]),
              );
            }).toList(),
          ],
        );
      },
    ));
    await Printing.layoutPdf(onLayout: (fmt) async => doc.save());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0730),
      body: Column(
        children: [
          _buildHeader(),
          if (_isLoading)
            const Expanded(child: Center(
              child: CircularProgressIndicator(color: Color(0xFF00CFFF))))
          else if (_categories.isEmpty)
            const Expanded(child: Center(
              child: Text('No schedule data found.',
                  style: TextStyle(color: Colors.white, fontSize: 16))))
          else ...[
            Container(
              color: const Color(0xFF180850),
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                indicatorColor: const Color(0xFF00CFFF),
                indicatorWeight: 3,
                labelColor: const Color(0xFF00CFFF),
                unselectedLabelColor: Colors.white38,
                labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1),
                tabs: _categories.map((c) =>
                    Tab(text: (c['category_type'] ?? '').toString().toUpperCase())).toList(),
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: _categories.map((cat) {
                  final catId    = int.tryParse(cat['category_id'].toString()) ?? 0;
                  final matches  = _scheduleByCategory[catId] ?? [];
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

  Widget _buildSoccerView(Map<String, dynamic> category, int catId, List<Map<String, dynamic>> matches) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          _buildCategoryTitleBar(category, 'SOCCER', matches),
          Container(
            color: const Color(0xFF130742),
            child: const TabBar(
              indicatorColor: Color(0xFF00FF88),
              indicatorWeight: 3,
              labelColor: Color(0xFF00FF88),
              unselectedLabelColor: Colors.white30,
              labelStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.2),
              tabs: [
                Tab(icon: Icon(Icons.calendar_today, size: 15), text: 'SCHEDULE'),
                Tab(icon: Icon(Icons.account_tree,   size: 15), text: 'BRACKET'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(children: [
              _buildSoccerSchedule(catId, matches),
              _buildBracketTab(),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryTitleBar(Map<String, dynamic> category, String title, List<Map<String, dynamic>> matches) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF2D0E7A), Color(0xFF1A0850)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 28),
      child: Row(
        children: [
          const Text('ROBOVENTURE',
              style: TextStyle(color: Colors.white30, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 2)),
          const Spacer(),
          Text(title,
              style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 3)),
          const Spacer(),
          IconButton(tooltip: 'Export PDF',
              icon: const Icon(Icons.picture_as_pdf, color: Color(0xFF00CFFF), size: 20),
              onPressed: () => _exportPdf(category, matches)),
          _buildLiveIndicator(),
          IconButton(tooltip: 'View Standings',
              icon: const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 20),
              onPressed: widget.onStandings),
          IconButton(tooltip: 'Register',
              icon: const Icon(Icons.app_registration, color: Color(0xFF00CFFF), size: 20),
              onPressed: widget.onRegister),
        ],
      ),
    );
  }

  Widget _buildScheduleTable(Map<String, dynamic> category, int catId, List<Map<String, dynamic>> matches) {
    int maxArenas = 1;
    for (final m in matches) {
      final count = m['arenaCount'] as int? ?? 1;
      if (count > maxArenas) maxArenas = count;
    }
    return Column(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF4A22AA), Color(0xFF3A1880)]),
          ),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 24),
          child: Row(children: [
            _headerCell('MATCH',    flex: 1),
            _headerCell('SCHEDULE', flex: 2),
            if (maxArenas == 1) const Spacer(flex: 2),
            ...List.generate(maxArenas, (i) => _headerCell('ARENA ${i + 1}', flex: 3, center: true)),
            if (maxArenas == 1) const Spacer(flex: 2),
            _headerCell('STATUS', flex: 2, center: true),
          ]),
        ),
        Expanded(
          child: matches.isEmpty
              ? const Center(child: Text('No matches scheduled.',
                  style: TextStyle(color: Colors.white38, fontSize: 14)))
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
                      color: isEven ? const Color(0xFF160C40) : const Color(0xFF100830),
                      padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 24),
                      child: Row(children: [
                        Expanded(flex: 1, child: Text('$matchNum',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14))),
                        Expanded(flex: 2, child: Text(schedule,
                            style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 13))),
                        if (maxArenas == 1) const Spacer(flex: 2),
                        ...List.generate(maxArenas, (ai) {
                          final team = ai < arenas.length ? arenas[ai] as Map<String, dynamic>? : null;
                          if (team != null) {
                            return Expanded(flex: 3, child: Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text((team['round_type']?.toString().toUpperCase() ?? ''),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Color(0xFF00CFFF), fontWeight: FontWeight.bold, fontSize: 11)),
                                Text(team['team_name']?.toString() ?? '',
                                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                                    textAlign: TextAlign.center),
                              ],
                            ));
                          }
                          return Expanded(flex: 3, child: const Text('—',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white24, fontSize: 13)));
                        }),
                        if (maxArenas == 1) const Spacer(flex: 2),
                        Expanded(flex: 2, child: GestureDetector(
                          onTap: () => _cycleStatus(catId, matchNum),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: status.color.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: status.color, width: 1.5),
                            ),
                            child: Text(status.label,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: status.color, fontWeight: FontWeight.bold, fontSize: 11)),
                          ),
                        )),
                      ]),
                    );
                  }),
        ),
      ],
    );
  }

  // ── Soccer schedule: pair consecutive entries into VS matchup rows ──────────
  Widget _buildSoccerSchedule(int catId, List<Map<String, dynamic>> matches) {
    final List<Map<String, dynamic>> rows = [];
    int i = 0;
    while (i < matches.length) {
      final m = matches[i];
      final arenas = m['arenas'] as List;
      if (arenas.length >= 2 && arenas[1] != null) {
        rows.add(m);
        i++;
      } else {
        final t1 = arenas.isNotEmpty ? arenas[0] as Map<String, dynamic>? : null;
        Map<String, dynamic>? t2;
        if (i + 1 < matches.length) {
          final next = matches[i + 1];
          final nextArenas = next['arenas'] as List;
          t2 = nextArenas.isNotEmpty ? nextArenas[0] as Map<String, dynamic>? : null;
        }
        rows.add({
          'matchNumber':    m['matchNumber'],
          'schedule':       m['schedule'],
          'schedule_start': m['schedule_start'],
          'team1':          t1,
          'team2':          t2,
        });
        i += t2 != null ? 2 : 1;
      }
    }

    return Column(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF4A22AA), Color(0xFF3A1880)]),
          ),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 24),
          child: Row(children: [
            _headerCell('#',      flex: 1),
            _headerCell('TIME',   flex: 2),
            _headerCell('HOME',   flex: 4, center: true),
            _headerCell('',       flex: 1, center: true),
            _headerCell('AWAY',   flex: 4, center: true),
            _headerCell('STATUS', flex: 2, center: true),
          ]),
        ),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('No matches scheduled.',
                  style: TextStyle(color: Colors.white38, fontSize: 14)))
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, idx) {
                    final row      = rows[idx];
                    final matchNum = row['matchNumber'] as int;
                    final schedule = row['schedule']    as String;
                    final isEven   = idx % 2 == 0;
                    final status   = _getStatus(catId, matchNum);

                    Map<String, dynamic>? t1 = row['team1'] as Map<String, dynamic>?;
                    Map<String, dynamic>? t2 = row['team2'] as Map<String, dynamic>?;
                    if (t1 == null && row.containsKey('arenas')) {
                      final arenas = row['arenas'] as List;
                      t1 = arenas.isNotEmpty ? arenas[0] as Map<String, dynamic>? : null;
                      t2 = arenas.length > 1  ? arenas[1] as Map<String, dynamic>? : null;
                    }

                    final team1Name = t1?['team_name']?.toString() ?? '—';
                    final team2Name = t2?['team_name']?.toString() ?? '—';
                    final roundType = (t1?['round_type'] ?? t2?['round_type'] ?? '')
                        .toString().toUpperCase();
                    final bothReal  = team1Name != '—' && team2Name != '—';

                    return Container(
                      decoration: BoxDecoration(
                        color: isEven ? const Color(0xFF160C40) : const Color(0xFF100830),
                        border: const Border(
                            bottom: BorderSide(color: Color(0xFF1A1050), width: 1)),
                      ),
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 1, child: Center(
                              child: Text('$matchNum',
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.4),
                                      fontWeight: FontWeight.bold, fontSize: 13)),
                            )),
                            Expanded(flex: 2, child: Center(
                              child: Text(schedule,
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.55), fontSize: 12)),
                            )),
                            Expanded(flex: 4, child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  if (roundType.isNotEmpty)
                                    Text(roundType,
                                        style: const TextStyle(
                                            color: Color(0xFF00CFFF), fontSize: 9,
                                            fontWeight: FontWeight.bold, letterSpacing: 0.8)),
                                  const SizedBox(height: 2),
                                  Text(team1Name,
                                      textAlign: TextAlign.right,
                                      maxLines: 2, overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: team1Name == '—'
                                              ? Colors.white24 : Colors.white,
                                          fontSize: 14, fontWeight: FontWeight.w700)),
                                ],
                              ),
                            )),
                            Expanded(flex: 1, child: Center(
                              child: Container(
                                margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                                decoration: BoxDecoration(
                                  gradient: bothReal
                                      ? const LinearGradient(
                                          colors: [Color(0xFF8B3FE8), Color(0xFF5218A8)],
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight)
                                      : null,
                                  color: bothReal ? null : const Color(0xFF1A0F38),
                                  borderRadius: BorderRadius.circular(6),
                                  boxShadow: bothReal
                                      ? [BoxShadow(
                                          color: const Color(0xFF7B2FD8).withOpacity(0.5),
                                          blurRadius: 10)]
                                      : [],
                                ),
                                child: Text('VS',
                                    style: TextStyle(
                                        color: bothReal ? Colors.white : Colors.white12,
                                        fontSize: 11, fontWeight: FontWeight.w900,
                                        letterSpacing: 2, fontStyle: FontStyle.italic)),
                              ),
                            )),
                            Expanded(flex: 4, child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (roundType.isNotEmpty)
                                    Text(roundType,
                                        style: const TextStyle(
                                            color: Color(0xFF00CFFF), fontSize: 9,
                                            fontWeight: FontWeight.bold, letterSpacing: 0.8)),
                                  const SizedBox(height: 2),
                                  Text(team2Name,
                                      maxLines: 2, overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: team2Name == '—'
                                              ? Colors.white24 : Colors.white,
                                          fontSize: 14, fontWeight: FontWeight.w700)),
                                ],
                              ),
                            )),
                            Expanded(flex: 2, child: Center(
                              child: GestureDetector(
                                onTap: () => _cycleStatus(catId, matchNum),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: status.color.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: status.color, width: 1.5),
                                  ),
                                  child: Text(status.label,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: status.color,
                                          fontWeight: FontWeight.bold, fontSize: 11)),
                                ),
                              ),
                            )),
                          ],
                        ),
                      ),
                    );
                  }),
        ),
      ],
    );
  }

  Widget _buildBracketTab() {
    if (_bracketRounds.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.sports_soccer, size: 64, color: Colors.white.withOpacity(0.1)),
          const SizedBox(height: 16),
          const Text('No soccer teams registered yet.',
              style: TextStyle(color: Colors.white38, fontSize: 16)),
          const SizedBox(height: 6),
          const Text('Register teams first, then the bracket will auto-build.',
              style: TextStyle(color: Colors.white24, fontSize: 13)),
        ]),
      );
    }

    final totalRounds = _bracketRounds.length;
    final champion    = _bracketRounds.last.first.winner;

    return Column(
      children: [
        Container(
          color: const Color(0xFF0D0628),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(children: [
            const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 16),
            const SizedBox(width: 6),
            Text(
              '${_bracketRounds[0].where((m) => !m.team1.isBye && !m.team2.isBye).length * 2 + _bracketRounds[0].where((m) => m.team1.isBye != m.team2.isBye).length} Teams · $totalRounds Rounds',
              style: const TextStyle(color: Color(0xFF7C6AAA), fontSize: 12),
            ),
            if (champion != null) ...[
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFD700).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.6)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.star, color: Color(0xFFFFD700), size: 13),
                  const SizedBox(width: 4),
                  Text('Champion: ${champion.teamName}',
                      style: const TextStyle(color: Color(0xFFFFD700), fontSize: 12, fontWeight: FontWeight.bold)),
                ]),
              ),
            ],
            const Spacer(),
            Text('Tap a card to set winner',
                style: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 11)),
            const SizedBox(width: 12),
            TextButton.icon(
              onPressed: _rebuildBracket,
              icon: const Icon(Icons.refresh, size: 13, color: Color(0xFF00CFFF)),
              label: const Text('Rebuild', style: TextStyle(color: Color(0xFF00CFFF), fontSize: 12)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                side: const BorderSide(color: Color(0xFF00CFFF), width: 1),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ]),
        ),
        Container(
          color: const Color(0xFF0A0420),
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: List.generate(totalRounds, (i) {
              String label;
              if (i == totalRounds - 1)      label = 'FINAL';
              else if (i == totalRounds - 2) label = 'SEMI-FINAL';
              else if (i == totalRounds - 3) label = 'QUARTER-FINAL';
              else                            label = 'ROUND ${i + 1}';
              return Expanded(
                child: Text(label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFF4A3878), fontSize: 9,
                        letterSpacing: 1.8, fontWeight: FontWeight.bold)),
              );
            }),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final availW        = constraints.maxWidth;
              final availH        = constraints.maxHeight;
              final numRounds     = _bracketRounds.length;
              final firstRoundCnt = _bracketRounds[0].length;

              const double kGapWFrac = 0.10;
              final double slotW  = availW / (numRounds + (numRounds - 1) * kGapWFrac);
              final double gapW   = slotW * kGapWFrac;

              const double kGapHFrac = 0.15;
              final double slotH  = availH / (firstRoundCnt + (firstRoundCnt - 1) * kGapHFrac);
              final double matchH = slotH * 0.85;
              final double gapH   = slotH * kGapHFrac;

              final double finalMatchW = slotW.clamp(200.0, 320.0);
              final double finalMatchH = matchH.clamp(60.0, 90.0);
              final double finalGapW   = gapW.clamp(24.0, 72.0);
              final double finalGapH   = gapH.clamp(10.0, 40.0);

              final double totalW = numRounds * (finalMatchW + finalGapW) - finalGapW;
              final double totalH = firstRoundCnt * (finalMatchH + finalGapH) - finalGapH;

              final bool fitsW = totalW <= availW + 1;
              final bool fitsH = totalH <= availH + 1;

              if (fitsW && fitsH) {
                return Padding(
                  padding: const EdgeInsets.all(20),
                  child: SizedBox(
                    width: availW - 40,
                    height: availH - 40,
                    child: _BracketCanvas(
                      rounds:     _bracketRounds,
                      onMatchTap: _showMatchDialog,
                      matchW:     (availW - 40 - (numRounds - 1) * finalGapW) / numRounds,
                      matchH:     ((availH - 40 - (firstRoundCnt - 1) * finalGapH) / firstRoundCnt * 0.85).clamp(60.0, 90.0),
                      gapW:       finalGapW,
                      gapH:       finalGapH,
                    ),
                  ),
                );
              }

              return InteractiveViewer(
                boundaryMargin: const EdgeInsets.all(60),
                minScale: 0.2, maxScale: 3.0,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: _BracketCanvas(
                        rounds: _bracketRounds, onMatchTap: _showMatchDialog,
                        matchW: finalMatchW, matchH: finalMatchH,
                        gapW: finalGapW, gapH: finalGapH,
                      ),
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

  void _showMatchDialog(BracketMatch match) {
    final bool team1Real = !match.team1.isBye && match.team1.teamName != 'TBD';
    final bool team2Real = !match.team2.isBye && match.team2.teamName != 'TBD';
    if (!team1Real && !team2Real) return;
    if (team1Real && !team2Real) { _setMatchResult(match, match.team1); return; }
    if (team2Real && !team1Real) { _setMatchResult(match, match.team2); return; }

    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.7),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            width: 380,
            decoration: BoxDecoration(
              color: const Color(0xFF14093A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF3D1E88), width: 1.5),
              boxShadow: [
                BoxShadow(color: const Color(0xFF6B2FD9).withOpacity(0.35),
                    blurRadius: 40, spreadRadius: 2),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 14, 14, 14),
                  decoration: const BoxDecoration(
                    color: Color(0xFF0F0628),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
                  ),
                  child: Row(children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF3D1E88).withOpacity(0.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.sports_soccer, color: Color(0xFF9B6FE8), size: 16),
                    ),
                    const SizedBox(width: 10),
                    const Text('SELECT MATCH WINNER',
                        style: TextStyle(color: Colors.white, fontSize: 13,
                            fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(Icons.close, color: Colors.white.withOpacity(0.4), size: 16),
                      ),
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
                  child: Column(children: [
                    _dialogTeamButton(ctx, setDlgState, match, match.team1),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(children: [
                        Expanded(child: Container(height: 1,
                            decoration: BoxDecoration(gradient: LinearGradient(
                                colors: [Colors.transparent, Colors.white.withOpacity(0.12)])))),
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 14),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                                colors: [Color(0xFF8B3FE8), Color(0xFF5218A8)]),
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: [BoxShadow(
                                color: const Color(0xFF7B2FD8).withOpacity(0.6),
                                blurRadius: 14)],
                          ),
                          child: const Text('VS',
                              style: TextStyle(color: Colors.white, fontSize: 15,
                                  fontWeight: FontWeight.w900, letterSpacing: 3,
                                  fontStyle: FontStyle.italic)),
                        ),
                        Expanded(child: Container(height: 1,
                            decoration: BoxDecoration(gradient: LinearGradient(
                                colors: [Colors.white.withOpacity(0.12), Colors.transparent])))),
                      ]),
                    ),
                    _dialogTeamButton(ctx, setDlgState, match, match.team2),
                  ]),
                ),
                if (match.winner != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: TextButton.icon(
                      onPressed: () { _clearMatchResult(match); Navigator.pop(ctx); },
                      icon: const Icon(Icons.restart_alt, color: Colors.redAccent, size: 14),
                      label: const Text('Clear result',
                          style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dialogTeamButton(
      BuildContext ctx, StateSetter setDlgState,
      BracketMatch match, BracketTeam team) {
    final isWinner = match.winner?.teamId == team.teamId;
    final initial  = team.teamName.isNotEmpty ? team.teamName[0].toUpperCase() : '?';

    return GestureDetector(
      onTap: () {
        _setMatchResult(match, team);
        setDlgState(() {});
        Navigator.pop(ctx);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          gradient: isWinner
              ? const LinearGradient(colors: [Color(0xFF00B86A), Color(0xFF006B3E)])
              : null,
          color: isWinner ? null : const Color(0xFF1C0F4A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isWinner ? const Color(0xFF00FF88) : const Color(0xFF2E1A5E),
            width: isWinner ? 2 : 1,
          ),
          boxShadow: isWinner
              ? [BoxShadow(color: const Color(0xFF00FF88).withOpacity(0.28), blurRadius: 16)]
              : [],
        ),
        child: Row(children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: isWinner
                  ? LinearGradient(colors: [
                      Colors.white.withOpacity(0.25),
                      Colors.white.withOpacity(0.10)])
                  : const LinearGradient(colors: [Color(0xFF2E1A62), Color(0xFF1C0F42)]),
              border: Border.all(
                color: isWinner
                    ? Colors.white.withOpacity(0.5)
                    : const Color(0xFF3E2878),
                width: 1.5,
              ),
            ),
            child: Center(
              child: Text(initial,
                  style: TextStyle(
                      color: isWinner ? Colors.white : Colors.white54,
                      fontWeight: FontWeight.bold, fontSize: 15)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(team.teamName,
                style: TextStyle(
                    color: isWinner ? Colors.white : Colors.white70,
                    fontWeight: isWinner ? FontWeight.bold : FontWeight.w500,
                    fontSize: 14),
                overflow: TextOverflow.ellipsis),
          ),
          if (isWinner) ...[
            const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 17),
            const SizedBox(width: 4),
            const Icon(Icons.check_circle, color: Colors.white, size: 17),
          ] else
            Icon(Icons.chevron_right, color: Colors.white.withOpacity(0.15), size: 18),
        ]),
      ),
    );
  }

  Widget _buildCategoryView(Map<String, dynamic> category, int catId, List<Map<String, dynamic>> matches) {
    final categoryName = (category['category_type'] ?? '').toString().toUpperCase();
    return Column(children: [
      _buildCategoryTitleBar(category, categoryName, matches),
      Expanded(child: _buildScheduleTable(category, catId, matches)),
    ]);
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF2D0E7A), Color(0xFF1A0850), Color(0xFF2D0E7A)],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            RichText(text: const TextSpan(children: [
              TextSpan(text: 'Make', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
              TextSpan(text: 'bl',   style: TextStyle(color: Color(0xFF00CFFF), fontSize: 22, fontWeight: FontWeight.bold)),
              TextSpan(text: 'ock',  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            ])),
            const Text('Construct Your Dreams',
                style: TextStyle(color: Colors.white38, fontSize: 10)),
          ]),
          Image.asset('assets/images/CenterLogo.png', height: 72, fit: BoxFit.contain),
          const Text('CREOTEC',
              style: TextStyle(color: Colors.white, fontSize: 18,
                  fontWeight: FontWeight.bold, letterSpacing: 3)),
        ],
      ),
    );
  }

  Widget _buildLiveIndicator() {
    final timeStr = _lastUpdated == null
        ? '--:--:--'
        : '${_lastUpdated!.hour.toString().padLeft(2, '0')}:'
          '${_lastUpdated!.minute.toString().padLeft(2, '0')}:'
          '${_lastUpdated!.second.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _PulsingDot(),
        const SizedBox(width: 5),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          const Text('LIVE', style: TextStyle(color: Color(0xFF00FF88), fontSize: 9,
              fontWeight: FontWeight.bold, letterSpacing: 1.2)),
          Text(timeStr, style: const TextStyle(color: Colors.white38, fontSize: 9)),
        ]),
      ]),
    );
  }

  Widget _headerCell(String text, {int flex = 1, bool center = false}) {
    return Expanded(
      flex: flex,
      child: Text(text,
          textAlign: center ? TextAlign.center : TextAlign.left,
          style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold,
              fontSize: 12, letterSpacing: 0.8)),
    );
  }
}

// ── Bracket canvas ────────────────────────────────────────────────────────────
class _BracketCanvas extends StatelessWidget {
  final List<List<BracketMatch>> rounds;
  final void Function(BracketMatch) onMatchTap;
  final double matchW, matchH, gapW, gapH;

  const _BracketCanvas({
    required this.rounds, required this.onMatchTap,
    this.matchW = 220, this.matchH = 70, this.gapW = 48, this.gapH = 14,
  });

  @override
  Widget build(BuildContext context) {
    final totalH = rounds[0].length * (matchH + gapH) - gapH;
    final totalW = rounds.length   * (matchW + gapW)  - gapW;
    return SizedBox(
      width: totalW, height: totalH,
      child: Stack(children: [
        CustomPaint(
          size: Size(totalW, totalH),
          painter: _BracketLinePainter(rounds: rounds,
              matchW: matchW, matchH: matchH, gapH: gapH, gapW: gapW),
        ),
        for (int r = 0; r < rounds.length; r++)
          for (int m = 0; m < rounds[r].length; m++)
            _positionedCard(r, m, totalH),
      ]),
    );
  }

  Offset _offset(int round, int matchIdx, double totalH) {
    final slotH = totalH / rounds[round].length;
    return Offset(round * (matchW + gapW), (matchIdx + 0.5) * slotH - matchH / 2);
  }

  Widget _positionedCard(int r, int m, double totalH) {
    final off   = _offset(r, m, totalH);
    final match = rounds[r][m];
    return Positioned(
      left: off.dx, top: off.dy, width: matchW, height: matchH,
      child: _MatchCard(match: match, onTap: () => onMatchTap(match), cardH: matchH),
    );
  }
}

// ── Line painter ──────────────────────────────────────────────────────────────
class _BracketLinePainter extends CustomPainter {
  final List<List<BracketMatch>> rounds;
  final double matchW, matchH, gapH, gapW;

  const _BracketLinePainter({
    required this.rounds, required this.matchW,
    required this.matchH, required this.gapH, required this.gapW,
  });

  Offset _rightMid(int r, int m, double h) {
    final slotH = h / rounds[r].length;
    return Offset(r * (matchW + gapW) + matchW, (m + 0.5) * slotH);
  }
  Offset _leftMid(int r, int m, double h) {
    final slotH = h / rounds[r].length;
    return Offset(r * (matchW + gapW), (m + 0.5) * slotH);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paintLine = Paint()
      ..color = const Color(0xFF2E1860)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final paintWin = Paint()
      ..color = const Color(0xFF00FF88).withOpacity(0.35)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    for (int r = 0; r < rounds.length - 1; r++) {
      for (int m = 0; m < rounds[r].length; m += 2) {
        if (m + 1 >= rounds[r].length) continue;
        final top   = _rightMid(r, m,     size.height);
        final bot   = _rightMid(r, m + 1, size.height);
        final midX  = top.dx + gapW / 2;
        final midY  = (top.dy + bot.dy) / 2;
        final nextM = m ~/ 2;
        if (nextM >= rounds[r + 1].length) continue;
        final nextIn = _leftMid(r + 1, nextM, size.height);

        final hasWinner1 = rounds[r][m].winner != null && !rounds[r][m].winner!.isBye;
        final hasWinner2 = rounds[r][m + 1].winner != null && !rounds[r][m + 1].winner!.isBye;

        final p = paintLine;
        final path = Path()
          ..moveTo(top.dx, top.dy)
          ..lineTo(midX,   top.dy)
          ..lineTo(midX,   bot.dy)
          ..lineTo(bot.dx, bot.dy);
        canvas.drawPath(path, p);
        canvas.drawLine(Offset(midX, midY), Offset(nextIn.dx, midY),
            (hasWinner1 || hasWinner2) ? paintWin : p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

// ── Match card — mirrors the soccer schedule VS row layout ───────────────────
class _MatchCard extends StatelessWidget {
  final BracketMatch match;
  final VoidCallback onTap;
  final double cardH;

  const _MatchCard({required this.match, required this.onTap, this.cardH = 78.0});

  @override
  Widget build(BuildContext context) {
    final bool t1Real    = !match.team1.isBye && match.team1.teamName != 'TBD';
    final bool t2Real    = !match.team2.isBye && match.team2.teamName != 'TBD';
    final bool bothReal  = t1Real && t2Real;
    final bool canPlay   = match.winner == null && (t1Real || t2Real);
    final bool hasWinner = match.winner != null;
    final bool t1Wins    = hasWinner && match.winner!.teamId == match.team1.teamId;
    final bool t2Wins    = hasWinner && match.winner!.teamId == match.team2.teamId;

    Color  borderCol;
    Color  glowCol;
    double glowBlur;
    if (hasWinner) {
      borderCol = const Color(0xFF00FF88).withOpacity(0.5);
      glowCol   = const Color(0xFF00FF88).withOpacity(0.15);
      glowBlur  = 12;
    } else if (canPlay) {
      borderCol = const Color(0xFF5B2CC0);
      glowCol   = const Color(0xFF5B2CC0).withOpacity(0.2);
      glowBlur  = 8;
    } else {
      borderCol = const Color(0xFF1C1045);
      glowCol   = Colors.transparent;
      glowBlur  = 0;
    }

    const double kBorder = 1.5;
    final double inner   = cardH - kBorder * 2;
    const double kVsW    = 36.0;
    final double fs      = (cardH * 0.14).clamp(9.0, 13.0);

    return GestureDetector(
      onTap: canPlay || hasWinner ? onTap : null,
      child: Container(
        height: cardH,
        decoration: BoxDecoration(
          color: hasWinner ? const Color(0xFF091910) : const Color(0xFF120A32),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderCol, width: kBorder),
          boxShadow: [
            BoxShadow(color: glowCol,   blurRadius: glowBlur),
            BoxShadow(color: Colors.black.withOpacity(0.45), blurRadius: 5,
                offset: const Offset(0, 2)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(
            height: inner,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _teamCell(
                    name:     match.team1.teamName,
                    isBye:    match.team1.isBye,
                    isWinner: t1Wins,
                    isDim:    hasWinner && !t1Wins,
                    align:    CrossAxisAlignment.end,
                    fontSize: fs,
                  ),
                ),
                SizedBox(
                  width: kVsW,
                  child: _vsCell(bothReal, hasWinner, fs),
                ),
                Expanded(
                  child: _teamCell(
                    name:     match.team2.teamName,
                    isBye:    match.team2.isBye,
                    isWinner: t2Wins,
                    isDim:    hasWinner && !t2Wins,
                    align:    CrossAxisAlignment.start,
                    fontSize: fs,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _teamCell({
    required String            name,
    required bool              isBye,
    required bool              isWinner,
    required bool              isDim,
    required CrossAxisAlignment align,
    required double            fontSize,
  }) {
    final bool isPlaceholder = name == 'TBD' || isBye;

    Color bg;
    Color textCol;
    if (isWinner) {
      bg      = const Color(0xFF00FF88).withOpacity(0.09);
      textCol = const Color(0xFF00FF88);
    } else if (isDim) {
      bg      = Colors.transparent;
      textCol = const Color(0xFF2A1C4A);
    } else if (isPlaceholder) {
      bg      = Colors.transparent;
      textCol = const Color(0xFF22163A);
    } else {
      bg      = Colors.transparent;
      textCol = Colors.white.withOpacity(0.9);
    }

    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: align,
        children: [
          if (isWinner)
            Icon(Icons.emoji_events, color: const Color(0xFFFFD700),
                size: (fontSize * 0.9).clamp(8.0, 12.0)),
          Text(
            name,
            textAlign: align == CrossAxisAlignment.end
                ? TextAlign.right : TextAlign.left,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color:      textCol,
              fontSize:   fontSize,
              fontWeight: isWinner ? FontWeight.bold : FontWeight.w600,
              height:     1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _vsCell(bool bothReal, bool hasWinner, double fs) {
    final bool glowing = bothReal && !hasWinner;
    return Container(
      color: const Color(0xFF0A0520),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 1, height: 6,
            color: Colors.white.withOpacity(0.06),
          ),
          const SizedBox(height: 3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              gradient: glowing
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF9B55F0), Color(0xFF5318B0)])
                  : null,
              color: glowing ? null : const Color(0xFF0E0628),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: glowing
                    ? const Color(0xFFBB88FF).withOpacity(0.45)
                    : Colors.white.withOpacity(0.05),
              ),
              boxShadow: glowing
                  ? [BoxShadow(
                      color: const Color(0xFF8844EE).withOpacity(0.55),
                      blurRadius: 12, spreadRadius: 1)]
                  : [],
            ),
            child: Text(
              'VS',
              style: TextStyle(
                color: glowing ? Colors.white : Colors.white.withOpacity(0.08),
                fontSize: (fs * 0.85).clamp(8.0, 12.0),
                fontWeight: FontWeight.w900,
                letterSpacing: 1.8,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          const SizedBox(height: 3),
          Container(
            width: 1, height: 6,
            color: Colors.white.withOpacity(0.06),
          ),
        ],
      ),
    );
  }
}

// ── Pulsing dot ───────────────────────────────────────────────────────────────
class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _anim = Tween(begin: 0.25, end: 1.0)
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
        decoration: const BoxDecoration(color: Color(0xFF00FF88), shape: BoxShape.circle),
      ),
    );
  }
}

// ── Extension helper ──────────────────────────────────────────────────────────
extension _Also<T> on T {
  T also(void Function(T it) block) { block(this); return this; }
}
