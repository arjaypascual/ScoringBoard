import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

// ── Soccer match score model ─────────────────────────────────────────────────
class SoccerScore {
  int? home;
  int? away;
  bool get isFinished => home != null && away != null;
  bool get isHomeWin  => isFinished && home! > away!;
  bool get isAwayWin  => isFinished && away! > home!;
  bool get isDraw     => isFinished && home! == away!;
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
  final String  id;
  BracketTeam   team1;
  BracketTeam   team2;
  BracketTeam?  winner;
  final int     round;
  final int     position;
  String?       scheduleTime;

  BracketMatch({
    required this.id,
    required this.team1,
    required this.team2,
    required this.round,
    required this.position,
    this.winner,
    this.scheduleTime,
  });
}

// ── Main widget ──────────────────────────────────────────────────────────────
class ScheduleViewer extends StatefulWidget {
  final VoidCallback? onRegister;
  final VoidCallback? onStandings;

  const ScheduleViewer({super.key, this.onRegister, this.onStandings});

  @override
  State<ScheduleViewer> createState() => _ScheduleViewerState();
}

class _ScheduleViewerState extends State<ScheduleViewer>
    with TickerProviderStateMixin {
  TabController? _tabController;
  List<Map<String, dynamic>>           _categories         = [];
  Map<int, List<Map<String, dynamic>>> _scheduleByCategory = {};
  final Map<String, MatchStatus>       _statusMap          = {};
  bool      _isLoading = true;
  DateTime? _lastUpdated;
  Timer?    _autoRefreshTimer;
  String    _lastDataSignature = '';

  int? _soccerCategoryId;

  // Soccer group-stage scores  key = match_id.toString()
  final Map<String, SoccerScore> _soccerScores = {};

  // Whether the bracket has been seeded from standings
  bool _bracketSeeded = false;

  List<List<BracketMatch>> _bracketRounds = [];

  // Soccer teams from DB
  List<Map<String, dynamic>> _soccerTeams = [];

  // Last schedule_end from soccer group stage — bracket starts after this
  String? _lastSoccerEndTime;

  @override
  void initState() {
    super.initState();
    _loadData(initial: true);
    _autoRefreshTimer = Timer.periodic(
        const Duration(seconds: 10), (_) => _silentRefresh());
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _tabController?.dispose();
    super.dispose();
  }

  // ── helpers ────────────────────────────────────────────────────────────────
  String _buildSignature(List rows) => rows.map((r) => r.toString()).join('|');

  String _fmt(String? t) {
    if (t == null || t.isEmpty) return '--:--';
    final parts = t.split(':');
    return parts.length < 2 ? t : '${parts[0]}:${parts[1]}';
  }

  String      _statusKey(int catId, int matchNumber) => '$catId-$matchNumber';
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

  // ── NEW: check if every group-stage match for a category is Done ──────────
  bool _allMatchesDone(int catId, List<Map<String, dynamic>> matches) {
    if (matches.isEmpty) return false;
    return matches.every((m) {
      final matchNum = m['matchNumber'] as int? ?? 0;
      return _getStatus(catId, matchNum) == MatchStatus.done;
    });
  }

  // ── silent background refresh ─────────────────────────────────────────────
  Future<void> _silentRefresh() async {
    try {
      final conn   = await DBHelper.getConnection();
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

  // ── main data load ────────────────────────────────────────────────────────
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
        if ((cat['category_type'] ?? '').toString().toLowerCase().contains('soccer')) {
          soccerCatId = int.tryParse(cat['category_id'].toString());
          break;
        }
      }

      for (final row in rows) {
        final catId   = int.tryParse(row['category_id'].toString()) ?? 0;
        final matchId = int.tryParse(row['match_id'].toString())    ?? 0;
        int arenaNum  = int.tryParse(row['arena_number']?.toString() ?? '0') ?? 0;
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
            'teams_list':     <Map<String, String>>[],
          };
        }
        (grouped[catId]![matchId]!['arenas'] as Map<int, Map<String, String>>)[arenaNum] = {
          'team_name':  row['team_name']  ?? '',
          'round_type': row['round_type'] ?? '',
          'team_id':    row['team_id']?.toString() ?? '',
        };
        (grouped[catId]![matchId]!['teams_list'] as List<Map<String, String>>).add({
          'team_name':  row['team_name']  ?? '',
          'round_type': row['round_type'] ?? '',
          'team_id':    row['team_id']?.toString() ?? '',
        });
      }

      final Map<int, List<Map<String, dynamic>>> scheduleByCategory = {};
      for (final cat in categories) {
        final catId    = int.tryParse(cat['category_id'].toString()) ?? 0;
        final matchMap = grouped[catId] ?? {};
        final matches  = matchMap.values.map((m) {
          final am        = m['arenas']    as Map<int, Map<String, String>>;
          final teamsList = m['teams_list'] as List<Map<String, String>>;
          final maxArena  = am.keys.isEmpty ? 0 : am.keys.reduce((a, b) => a > b ? a : b);
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

      // Load soccer teams + last end time
      List<Map<String, dynamic>> soccerTeams = [];
      String? lastSoccerEndTime;
      if (soccerCatId != null) {
        soccerTeams = await DBHelper.getTeamsByCategory(soccerCatId);
        final soccerMatches = scheduleByCategory[soccerCatId] ?? [];
        if (soccerMatches.isNotEmpty) {
          final lastMatch = rows
              .where((r) =>
                  int.tryParse(r['category_id'].toString()) == soccerCatId)
              .toList();
          if (lastMatch.isNotEmpty) {
            lastMatch.sort((a, b) =>
                (a['schedule_end'] ?? '').toString()
                    .compareTo((b['schedule_end'] ?? '').toString()));
            final raw = lastMatch.last['schedule_end']?.toString() ?? '';
            if (raw.isNotEmpty) {
              final parts = raw.split(':');
              lastSoccerEndTime =
                  parts.length >= 2 ? '${parts[0]}:${parts[1]}' : raw;
            }
          }
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
        _soccerTeams        = soccerTeams;
        _lastSoccerEndTime  = lastSoccerEndTime;
        _isLoading          = false;
        _lastUpdated        = DateTime.now();
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Failed to load: $e'), backgroundColor: Colors.red));
    }
  }

  int _bracketSize(int teamCount) {
    if (teamCount >= 16) return 16;
    if (teamCount >= 8)  return 8;
    if (teamCount >= 4)  return 4;
    return teamCount.clamp(2, 4);
  }

  void _assignBracketTimes(List<List<BracketMatch>> rounds, int durationMinutes) {
    if (_lastSoccerEndTime == null) return;
    final parts = _lastSoccerEndTime!.split(':');
    if (parts.length < 2) return;
    int h = int.tryParse(parts[0]) ?? 9;
    int m = int.tryParse(parts[1]) ?? 0;

    String fmt(int hour, int min) =>
        '${hour.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';

    for (final round in rounds) {
      for (final match in round) {
        match.scheduleTime = fmt(h, m);
        m += durationMinutes;
        while (m >= 60) { m -= 60; h++; }
        if (h == 12) { h = 13; m = 0; }
      }
    }
  }

  void _seedBracketFromStandings(List<Map<String, dynamic>> matches) {
    final size  = _bracketSize(_soccerTeams.length);
    final topN  = _soccerTeams.take(size).toList();

    final List<BracketTeam> bracketTeams = [];
    for (int i = 0; i < topN.length ~/ 2; i++) {
      final a = topN[i];
      final b = topN[topN.length - 1 - i];
      bracketTeams.add(BracketTeam(
          teamId: int.parse(a['team_id'].toString()),
          teamName: a['team_name'].toString()));
      bracketTeams.add(BracketTeam(
          teamId: int.parse(b['team_id'].toString()),
          teamName: b['team_name'].toString()));
    }
    int byeN = 0;
    while (bracketTeams.length < size)
      bracketTeams.add(BracketTeam(teamId: -(++byeN), teamName: 'BYE', isBye: true));

    final rounds = _buildBracketFromTeams(bracketTeams);
    _assignBracketTimes(rounds, 10);
    setState(() {
      _bracketRounds = rounds;
      _bracketSeeded = true;
    });
  }

  List<List<BracketMatch>> _buildBracketFromTeams(List<BracketTeam> teams) {
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
            round:    roundNum, position: i ~/ 2));
      }
      rounds.add(current);
      prev = current;
      roundNum++;
    }
    return rounds;
  }

  void _rebuildBracket(List<Map<String, dynamic>> matches) {
    setState(() { _bracketSeeded = false; _bracketRounds = []; });
    _seedBracketFromStandings(matches);
  }

  void _setMatchResult(BracketMatch match, BracketTeam winner) {
    setState(() { match.winner = winner; _propagateWinner(match); });
  }

  void _propagateWinner(BracketMatch match) {
    if (match.winner == null || match.winner!.isBye) return;
    final nextRoundIdx = match.round + 1;
    if (nextRoundIdx >= _bracketRounds.length) return;
    final nextRound    = _bracketRounds[nextRoundIdx];
    final nextMatchIdx = match.position ~/ 2;
    if (nextMatchIdx >= nextRound.length) return;
    final nextMatch = nextRound[nextMatchIdx];
    if (match.position % 2 == 0) nextMatch.team1 = match.winner!;
    else                          nextMatch.team2 = match.winner!;
  }

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
      if (nextMatch.winner != null) { resetDownstream(nextMatch); nextMatch.winner = null; }
    }
    setState(() { resetDownstream(match); match.winner = null; });
  }

  void _showScoreDialog(
      String matchId, String team1Name, String team2Name,
      List<Map<String, dynamic>> allMatches) {
    final existing = _soccerScores[matchId];
    final c1 = TextEditingController(text: existing?.home?.toString() ?? '');
    final c2 = TextEditingController(text: existing?.away?.toString() ?? '');

    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.7),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 360,
          decoration: BoxDecoration(
            color: const Color(0xFF14093A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF3D1E88), width: 1.5),
            boxShadow: [BoxShadow(
                color: const Color(0xFF6B2FD9).withOpacity(0.35),
                blurRadius: 40, spreadRadius: 2)],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                    borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.sports_soccer, color: Color(0xFF9B6FE8), size: 18),
                ),
                const SizedBox(width: 10),
                const Text('ENTER MATCH SCORE',
                    style: TextStyle(color: Colors.white, fontSize: 16,
                        fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(ctx),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(6)),
                    child: Icon(Icons.close, color: Colors.white.withOpacity(0.4), size: 18),
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(children: [
                Expanded(child: Column(children: [
                  Text(team1Name,
                      textAlign: TextAlign.center,
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white,
                          fontSize: 14, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  _scoreField(c1, const Color(0xFF00CFFF)),
                ])),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [Color(0xFF8B3FE8), Color(0xFF5218A8)]),
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [BoxShadow(
                          color: const Color(0xFF7B2FD8).withOpacity(0.5),
                          blurRadius: 12)],
                    ),
                    child: const Text('VS',
                        style: TextStyle(color: Colors.white, fontSize: 15,
                            fontWeight: FontWeight.w900, letterSpacing: 2,
                            fontStyle: FontStyle.italic)),
                  ),
                ),
                Expanded(child: Column(children: [
                  Text(team2Name,
                      textAlign: TextAlign.center,
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white,
                          fontSize: 14, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  _scoreField(c2, const Color(0xFF00FF88)),
                ])),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(children: [
                if (existing?.isFinished == true) ...[
                  Expanded(child: OutlinedButton.icon(
                    onPressed: () {
                      setState(() => _soccerScores.remove(matchId));
                      Navigator.pop(ctx);
                    },
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 16),
                    label: const Text('Clear', style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  )),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: () {
                      final h = int.tryParse(c1.text.trim());
                      final a = int.tryParse(c2.text.trim());
                      if (h == null || a == null) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('Please enter valid scores'),
                            backgroundColor: Colors.orange));
                        return;
                      }
                      setState(() {
                        _soccerScores[matchId] = SoccerScore()..home = h..away = a;
                      });
                      Navigator.pop(ctx);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF5B2CC0),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Save Score',
                        style: TextStyle(color: Colors.white,
                            fontSize: 14, fontWeight: FontWeight.bold)),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _scoreField(TextEditingController ctrl, Color accentColor) {
    return Container(
      height: 58,
      decoration: BoxDecoration(
        color: const Color(0xFF1C0F4A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accentColor.withOpacity(0.5), width: 1.5),
      ),
      child: Center(
        child: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          textAlign: TextAlign.center,
          style: TextStyle(color: accentColor, fontSize: 26, fontWeight: FontWeight.bold),
          decoration: const InputDecoration(
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            hintText: '0',
            hintStyle: TextStyle(color: Colors.white12, fontSize: 26),
          ),
        ),
      ),
    );
  }

  Future<void> _exportPdf(
      Map<String, dynamic> category,
      List<Map<String, dynamic>> matches) async {
    final doc          = pw.Document();
    final categoryName = (category['category_type'] ?? '').toString().toUpperCase();
    int maxArenas = 1;
    for (final m in matches) {
      final count = m['arenaCount'] as int? ?? 1;
      if (count > maxArenas) maxArenas = count;
    }
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4.landscape,
      build: (pw.Context ctx) => pw.Column(
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
                        pw.Text(team['team_id']?.toString() ?? '', textAlign: pw.TextAlign.center,
                            style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                        pw.Text(team['team_name']?.toString() ?? '', textAlign: pw.TextAlign.center,
                            style: const pw.TextStyle(fontSize: 9)),
                      ],
                    ));
                  }
                  return pw.Expanded(flex: 2, child: pw.Text('—',
                      textAlign: pw.TextAlign.center,
                      style: const pw.TextStyle(color: PdfColors.grey400)));
                }),
              ]),
            );
          }).toList(),
        ],
      ),
    ));
    await Printing.layoutPdf(onLayout: (fmt) async => doc.save());
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0730),
      body: Column(children: [
        _buildHeader(),
        if (_isLoading)
          const Expanded(child: Center(
              child: CircularProgressIndicator(color: Color(0xFF00CFFF))))
        else if (_categories.isEmpty)
          const Expanded(child: Center(
              child: Text('No schedule data found.',
                  style: TextStyle(color: Colors.white, fontSize: 18))))
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
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 1),
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
      ]),
    );
  }

  // ── Soccer view: 2 sub-tabs (Schedule | Bracket) ─────────────────────────
  // ── CHANGED: bracket tab is locked until all group-stage matches are Done ─
  Widget _buildSoccerView(
      Map<String, dynamic> category, int catId,
      List<Map<String, dynamic>> matches) {
    final bracketSize  = _bracketSize(_soccerTeams.length);
    final canSeed      = !_bracketSeeded;
    final allDone      = _allMatchesDone(catId, matches);   // ← NEW

    return DefaultTabController(
      length: 2,
      child: Column(children: [
        _buildCategoryTitleBar(category, 'SOCCER', matches),
        Container(
          color: const Color(0xFF130742),
          child: TabBar(
            // ── Disable bracket tab if not all matches are Done ──────────
            onTap: (index) {
              if (index == 1 && !allDone) {
                // Snap back to schedule tab and show warning
                DefaultTabController.of(context).animateTo(0);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: const Color(0xFF2D0E7A),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    content: Row(children: const [
                      Icon(Icons.lock, color: Color(0xFFFFD700), size: 18),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Complete all group-stage matches first.\nSet every match status to "Done" to unlock the bracket.',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ]),
                    duration: const Duration(seconds: 3),
                  ),
                );
              }
            },
            indicatorColor: const Color(0xFF00FF88),
            indicatorWeight: 3,
            labelColor: const Color(0xFF00FF88),
            unselectedLabelColor: Colors.white30,
            labelStyle: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 1.2),
            tabs: [
              // Schedule tab — always accessible
              const Tab(
                icon: Icon(Icons.calendar_today, size: 16),
                text: 'SCHEDULE',
              ),
              // Bracket tab — shows lock icon when not all done
              Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      allDone ? Icons.account_tree : Icons.lock,
                      size: 16,
                      color: allDone
                          ? const Color(0xFF00FF88)
                          : Colors.white24,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'BRACKET',
                      style: TextStyle(
                        color: allDone ? const Color(0xFF00FF88) : Colors.white24,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        letterSpacing: 1.2,
                      ),
                    ),
                    if (!allDone) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: Colors.white12, width: 1),
                        ),
                        child: const Text(
                          'LOCKED',
                          style: TextStyle(
                              color: Colors.white24,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(children: [
            _buildSoccerScheduleTab(catId, matches, bracketSize, canSeed),
            // ── If not all done, show locked screen instead of bracket ──
            allDone
                ? _buildBracketTab(matches)
                : _buildBracketLockedScreen(matches),
          ]),
        ),
      ]),
    );
  }

  // ── NEW: Locked bracket placeholder screen ────────────────────────────────
  Widget _buildBracketLockedScreen(List<Map<String, dynamic>> matches) {
    final total    = matches.length;
    final doneCount = matches.where((m) {
      final matchNum = m['matchNumber'] as int? ?? 0;
      return _getStatus(_soccerCategoryId ?? 0, matchNum) == MatchStatus.done;
    }).length;
    final remaining = total - doneCount;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF1A0A4A),
              border: Border.all(
                  color: const Color(0xFFFFD700).withOpacity(0.3), width: 2),
              boxShadow: [
                BoxShadow(
                    color: const Color(0xFFFFD700).withOpacity(0.1),
                    blurRadius: 30,
                    spreadRadius: 5),
              ],
            ),
            child: const Icon(Icons.lock, color: Color(0xFFFFD700), size: 52),
          ),
          const SizedBox(height: 24),
          const Text(
            'BRACKET LOCKED',
            style: TextStyle(
                color: Color(0xFFFFD700),
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: 3),
          ),
          const SizedBox(height: 10),
          Text(
            'Complete all group-stage matches to unlock.',
            style: TextStyle(
                color: Colors.white.withOpacity(0.45),
                fontSize: 15),
          ),
          const SizedBox(height: 20),
          // Progress indicator
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 48),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF130742),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: const Color(0xFF3D1E88).withOpacity(0.5), width: 1),
            ),
            child: Column(children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Matches Done',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.5), fontSize: 13)),
                  Text('$doneCount / $total',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: total > 0 ? doneCount / total : 0,
                  minHeight: 8,
                  backgroundColor: Colors.white.withOpacity(0.08),
                  valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF00FF88)),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                remaining > 0
                    ? '$remaining match${remaining > 1 ? 'es' : ''} remaining'
                    : 'All matches complete!',
                style: TextStyle(
                    color: remaining > 0
                        ? Colors.white38
                        : const Color(0xFF00FF88),
                    fontSize: 13),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  // ── Soccer Schedule sub-tab ───────────────────────────────────────────────
  Widget _buildSoccerScheduleTab(
      int catId,
      List<Map<String, dynamic>> matches,
      int bracketSize,
      bool canSeed) {

    final List<Map<String, dynamic>> rows = [];
    int i = 0;
    while (i < matches.length) {
      final m      = matches[i];
      final arenas = m['arenas'] as List;
      if (arenas.length >= 2 && arenas[1] != null) {
        rows.add(m); i++;
      } else {
        final t1 = arenas.isNotEmpty ? arenas[0] as Map<String, dynamic>? : null;
        Map<String, dynamic>? t2;
        if (i + 1 < matches.length) {
          final next       = matches[i + 1];
          final nextArenas = next['arenas'] as List;
          t2 = nextArenas.isNotEmpty ? nextArenas[0] as Map<String, dynamic>? : null;
        }
        rows.add({
          'matchNumber':    m['matchNumber'],
          'match_id':       m['match_id'],
          'schedule':       m['schedule'],
          'schedule_start': m['schedule_start'],
          'team1': t1,
          'team2': t2,
        });
        i += t2 != null ? 2 : 1;
      }
    }

    return Column(children: [
      if (canSeed)
        Container(
          margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFF00803A), Color(0xFF005728)]),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [BoxShadow(
                color: const Color(0xFF00FF88).withOpacity(0.2), blurRadius: 16)],
          ),
          child: Row(children: [
            const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Top $bracketSize teams ready to advance to the bracket.',
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 10),
            ElevatedButton.icon(
              onPressed: () => _seedBracketFromStandings(matches),
              icon: const Icon(Icons.account_tree, size: 16),
              label: const Text('Seed Bracket',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00CFFF),
                foregroundColor: const Color(0xFF0E0730),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
            ),
          ]),
        ),

      Container(
        decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF4A22AA), Color(0xFF3A1880)])),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
        child: Row(children: [
          _headerCell('#',      flex: 1),
          _headerCell('TIME',   flex: 2),
          _headerCell('HOME',   flex: 4, center: true),
          _headerCell('SCORE',  flex: 2, center: true),
          _headerCell('AWAY',   flex: 4, center: true),
          _headerCell('STATUS', flex: 2, center: true),
        ]),
      ),

      Expanded(
        child: rows.isEmpty
            ? const Center(child: Text('No matches scheduled.',
                style: TextStyle(color: Colors.white38, fontSize: 16)))
            : ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, idx) {
                  final row = rows[idx];

                  // ── Group-stage row ────────────────────────────────────
                  final matchId  = row['match_id'].toString();
                  final matchNum = row['matchNumber'] as int;
                  final schedule = row['schedule']    as String;
                  final isEven   = idx % 2 == 0;
                  final status   = _getStatus(catId, matchNum);
                  final score    = _soccerScores[matchId];

                  Map<String, dynamic>? t1 = row['team1'] as Map<String, dynamic>?;
                  Map<String, dynamic>? t2 = row['team2'] as Map<String, dynamic>?;
                  if (t1 == null && row.containsKey('arenas')) {
                    final arenas = row['arenas'] as List;
                    t1 = arenas.isNotEmpty ? arenas[0] as Map<String, dynamic>? : null;
                    t2 = arenas.length > 1  ? arenas[1] as Map<String, dynamic>? : null;
                  }

                  final team1Name = t1?['team_name']?.toString() ?? '—';
                  final team2Name = t2?['team_name']?.toString() ?? '—';
                  final _t1raw    = t1?['team_id']?.toString() ?? '';
                  final _t2raw    = t2?['team_id']?.toString() ?? '';
                  final team1Id   = _t1raw.isNotEmpty ? 'C${_t1raw}R' : '';
                  final team2Id   = _t2raw.isNotEmpty ? 'C${_t2raw}R' : '';
                  final bothReal  = team1Name != '—' && team2Name != '—';

                  final bool t1Wins = score?.isHomeWin == true;
                  final bool t2Wins = score?.isAwayWin == true;
                  final bool isDraw = score?.isDraw     == true;

                  return Container(
                    decoration: BoxDecoration(
                      color: isEven ? const Color(0xFF160C40) : const Color(0xFF100830),
                      border: const Border(bottom: BorderSide(color: Color(0xFF1A1050), width: 1)),
                    ),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 1, child: Center(
                            child: Text('$matchNum',
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.4),
                                    fontWeight: FontWeight.bold, fontSize: 16)),
                          )),
                          Expanded(flex: 2, child: Center(
                            child: Text(schedule,
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.55), fontSize: 15)),
                          )),
                          Expanded(flex: 4, child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (team1Id.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF00CFFF).withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(color: const Color(0xFF00CFFF).withOpacity(0.5), width: 1),
                                    ),
                                    child: Text(team1Id,
                                        style: const TextStyle(
                                            color: Color(0xFF00CFFF), fontSize: 11,
                                            fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                                  ),
                                const SizedBox(height: 4),
                                Text(team1Name,
                                    textAlign: TextAlign.right,
                                    maxLines: 2, overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: t1Wins
                                            ? const Color(0xFF00FF88)
                                            : isDraw
                                                ? const Color(0xFFFFD700)
                                                : team1Name == '—'
                                                    ? Colors.white24 : Colors.white,
                                        fontSize: 16,
                                        fontWeight: t1Wins ? FontWeight.bold : FontWeight.w700)),
                              ],
                            ),
                          )),
                          Expanded(flex: 2, child: Center(
                            child: GestureDetector(
                              onTap: bothReal
                                  ? () => _showScoreDialog(matchId, team1Name, team2Name, matches)
                                  : null,
                              child: Container(
                                margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  gradient: score?.isFinished == true
                                      ? const LinearGradient(
                                          colors: [Color(0xFF3D1E88), Color(0xFF1A0850)])
                                      : null,
                                  color: score?.isFinished == true
                                      ? null
                                      : bothReal
                                          ? const Color(0xFF1A0F38)
                                          : const Color(0xFF0D0722),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: score?.isFinished == true
                                        ? const Color(0xFF7B50D8)
                                        : bothReal
                                            ? const Color(0xFF3D1E88)
                                            : Colors.white12,
                                    width: 1.5,
                                  ),
                                  boxShadow: score?.isFinished == true
                                      ? [BoxShadow(
                                          color: const Color(0xFF5B2CC0).withOpacity(0.3),
                                          blurRadius: 8)]
                                      : [],
                                ),
                                child: score?.isFinished == true
                                    ? Text('${score!.home}  –  ${score.away}',
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                            color: Colors.white, fontSize: 16,
                                            fontWeight: FontWeight.bold, letterSpacing: 1))
                                    : Text(bothReal ? 'TAP\nSCORE' : '—',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                            color: bothReal ? Colors.white38 : Colors.white12,
                                            fontSize: 10, fontWeight: FontWeight.bold,
                                            letterSpacing: 0.5)),
                              ),
                            ),
                          )),
                          Expanded(flex: 4, child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (team2Id.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF00CFFF).withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(color: const Color(0xFF00CFFF).withOpacity(0.5), width: 1),
                                    ),
                                    child: Text(team2Id,
                                        style: const TextStyle(
                                            color: Color(0xFF00CFFF), fontSize: 11,
                                            fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                                  ),
                                const SizedBox(height: 4),
                                Text(team2Name,
                                    maxLines: 2, overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: t2Wins
                                            ? const Color(0xFF00FF88)
                                            : isDraw
                                                ? const Color(0xFFFFD700)
                                                : team2Name == '—'
                                                    ? Colors.white24 : Colors.white,
                                        fontSize: 16,
                                        fontWeight: t2Wins ? FontWeight.bold : FontWeight.w700)),
                              ],
                            ),
                          )),
                          Expanded(flex: 2, child: Center(
                            child: GestureDetector(
                              onTap: () => _cycleStatus(catId, matchNum),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                decoration: BoxDecoration(
                                  color: status.color.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: status.color, width: 1.5),
                                ),
                                child: Text(status.label,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: status.color,
                                        fontWeight: FontWeight.bold, fontSize: 12)),
                              ),
                            ),
                          )),
                        ],
                      ),
                    ),
                  );
                }),
      ),
    ]);
  }

  // ── Bracket sub-tab ────────────────────────────────────────────────────────
  Widget _buildBracketTab(List<Map<String, dynamic>> matches) {
    if (!_bracketSeeded || _bracketRounds.isEmpty) {
      final totalTeams  = _soccerTeams.length;
      final bracketSize = _bracketSize(totalTeams);
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.account_tree, size: 64, color: Colors.white.withOpacity(0.08)),
          const SizedBox(height: 16),
          const Text('Bracket not seeded yet.',
              style: TextStyle(color: Colors.white38, fontSize: 18)),
          const SizedBox(height: 6),
          Text(
            totalTeams == 0
                ? 'Register teams first.'
                : 'Enter scores in the Schedule tab,\nthen seed the bracket with the Top $bracketSize teams.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white24, fontSize: 15),
          ),
          if (totalTeams >= 4) ...[
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () => _seedBracketFromStandings(matches),
              icon: const Icon(Icons.account_tree, size: 16),
              label: Text('Seed Top $bracketSize Bracket',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF5B2CC0),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
            ),
          ],
        ]),
      );
    }

    final totalRounds = _bracketRounds.length;
    final champion    = _bracketRounds.last.first.winner;
    final bracketSize = _bracketRounds[0].length * 2;

    return Column(children: [
      Container(
        color: const Color(0xFF0D0628),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(children: [
          const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 18),
          const SizedBox(width: 6),
          Text('Top $bracketSize · $totalRounds Rounds',
              style: const TextStyle(color: Color(0xFF7C6AAA), fontSize: 14)),
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
                const Icon(Icons.star, color: Color(0xFFFFD700), size: 14),
                const SizedBox(width: 4),
                Text('Champion: ${champion.teamName}',
                    style: const TextStyle(color: Color(0xFFFFD700),
                        fontSize: 13, fontWeight: FontWeight.bold)),
              ]),
            ),
          ],
          const Spacer(),
          Text('Tap a card to set winner',
              style: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 13)),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: () => _rebuildBracket(matches),
            icon: const Icon(Icons.refresh, size: 14, color: Color(0xFF00CFFF)),
            label: const Text('Reseed',
                style: TextStyle(color: Color(0xFF00CFFF), fontSize: 13)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              side: const BorderSide(color: Color(0xFF00CFFF), width: 1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
          ),
        ]),
      ),
      Expanded(
        child: LayoutBuilder(builder: (context, constraints) {
          final availW        = constraints.maxWidth  - 40;
          final availH        = constraints.maxHeight - 40;
          final numRounds     = _bracketRounds.length;
          final firstRoundCnt = _bracketRounds[0].length;

          const double kGapWFrac = 0.08;
          const double kGapHFrac = 0.12;

          final double gapW   = availW * kGapWFrac / numRounds;
          final double matchW = (availW - gapW * (numRounds - 1)) / numRounds;
          final double gapH   = availH * kGapHFrac / firstRoundCnt;
          final double matchH = (availH - gapH * (firstRoundCnt - 1)) / firstRoundCnt;

          return Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: availW, height: availH,
              child: _BracketCanvas(
                rounds:     _bracketRounds,
                onMatchTap: _showMatchDialog,
                matchW:     matchW,
                matchH:     matchH,
                gapW:       gapW,
                gapH:       gapH,
              ),
            ),
          );
        }),
      ),
    ]);
  }

  void _showMatchDialog(BracketMatch match) {
    final bool t1Real = !match.team1.isBye && match.team1.teamName != 'TBD';
    final bool t2Real = !match.team2.isBye && match.team2.teamName != 'TBD';
    if (!t1Real && !t2Real) return;
    if (t1Real && !t2Real) { _setMatchResult(match, match.team1); return; }
    if (t2Real && !t1Real) { _setMatchResult(match, match.team2); return; }

    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.7),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            width: 420,
            decoration: BoxDecoration(
              color: const Color(0xFF14093A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF3D1E88), width: 1.5),
              boxShadow: [BoxShadow(
                  color: const Color(0xFF6B2FD9).withOpacity(0.35),
                  blurRadius: 40, spreadRadius: 2)],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                        borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.sports_soccer, color: Color(0xFF9B6FE8), size: 18),
                  ),
                  const SizedBox(width: 10),
                  const Text('SELECT MATCH WINNER',
                      style: TextStyle(color: Colors.white, fontSize: 16,
                          fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(ctx),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(6)),
                      child: Icon(Icons.close, color: Colors.white.withOpacity(0.4), size: 18),
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
                              color: const Color(0xFF7B2FD8).withOpacity(0.6), blurRadius: 14)],
                        ),
                        child: const Text('VS',
                            style: TextStyle(color: Colors.white, fontSize: 17,
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
                    icon: const Icon(Icons.restart_alt, color: Colors.redAccent, size: 16),
                    label: const Text('Clear result',
                        style: TextStyle(color: Colors.redAccent, fontSize: 14)),
                  ),
                ),
              const SizedBox(height: 8),
            ]),
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          gradient: isWinner
              ? const LinearGradient(colors: [Color(0xFF00B86A), Color(0xFF006B3E)])
              : null,
          color: isWinner ? null : const Color(0xFF1C0F4A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isWinner ? const Color(0xFF00FF88) : const Color(0xFF2E1A5E),
            width: isWinner ? 2 : 1),
          boxShadow: isWinner
              ? [BoxShadow(color: const Color(0xFF00FF88).withOpacity(0.28), blurRadius: 16)]
              : [],
        ),
        child: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: isWinner
                  ? LinearGradient(colors: [
                      Colors.white.withOpacity(0.25),
                      Colors.white.withOpacity(0.10)])
                  : const LinearGradient(colors: [Color(0xFF2E1A62), Color(0xFF1C0F42)]),
              border: Border.all(
                color: isWinner ? Colors.white.withOpacity(0.5) : const Color(0xFF3E2878),
                width: 1.5),
            ),
            child: Center(child: Text(initial,
                style: TextStyle(
                    color: isWinner ? Colors.white : Colors.white54,
                    fontWeight: FontWeight.bold, fontSize: 17))),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(team.teamName,
              style: TextStyle(
                  color: isWinner ? Colors.white : Colors.white70,
                  fontWeight: isWinner ? FontWeight.bold : FontWeight.w500,
                  fontSize: 16),
              overflow: TextOverflow.ellipsis)),
          if (isWinner) ...[
            const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 19),
            const SizedBox(width: 4),
            const Icon(Icons.check_circle, color: Colors.white, size: 19),
          ] else
            Icon(Icons.chevron_right, color: Colors.white.withOpacity(0.15), size: 20),
        ]),
      ),
    );
  }

  Widget _buildCategoryView(
      Map<String, dynamic> category, int catId,
      List<Map<String, dynamic>> matches) {
    final categoryName = (category['category_type'] ?? '').toString().toUpperCase();
    return Column(children: [
      _buildCategoryTitleBar(category, categoryName, matches),
      Expanded(child: _buildScheduleTable(category, catId, matches)),
    ]);
  }

  Widget _buildCategoryTitleBar(
      Map<String, dynamic> category, String title,
      List<Map<String, dynamic>> matches) {
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
      child: Row(children: [
        const Text('ROBOVENTURE',
            style: TextStyle(color: Colors.white30, fontSize: 14,
                fontWeight: FontWeight.bold, letterSpacing: 2)),
        const Spacer(),
        Text(title,
            style: const TextStyle(color: Colors.white, fontSize: 26,
                fontWeight: FontWeight.w900, letterSpacing: 3)),
        const Spacer(),
        IconButton(tooltip: 'Export PDF',
            icon: const Icon(Icons.picture_as_pdf, color: Color(0xFF00CFFF), size: 22),
            onPressed: () => _exportPdf(category, matches)),
        _buildLiveIndicator(),
        IconButton(tooltip: 'View Standings',
            icon: const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 22),
            onPressed: widget.onStandings),
        IconButton(tooltip: 'Register',
            icon: const Icon(Icons.app_registration, color: Color(0xFF00CFFF), size: 22),
            onPressed: widget.onRegister),
      ]),
    );
  }

  Widget _buildScheduleTable(
      Map<String, dynamic> category, int catId,
      List<Map<String, dynamic>> matches) {
    int maxArenas = 1;
    for (final m in matches) {
      final count = m['arenaCount'] as int? ?? 1;
      if (count > maxArenas) maxArenas = count;
    }
    return Column(children: [
      Container(
        decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF4A22AA), Color(0xFF3A1880)])),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
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
                style: TextStyle(color: Colors.white38, fontSize: 16)))
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
                    padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 24),
                    child: Row(children: [
                      Expanded(flex: 1, child: Text('$matchNum',
                          style: const TextStyle(color: Colors.white,
                              fontWeight: FontWeight.bold, fontSize: 17))),
                      Expanded(flex: 2, child: Text(schedule,
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.75), fontSize: 16))),
                      if (maxArenas == 1) const Spacer(flex: 2),
                      ...List.generate(maxArenas, (ai) {
                        final team = ai < arenas.length
                            ? arenas[ai] as Map<String, dynamic>? : null;
                        if (team != null) {
                          final rawId     = team['team_id']?.toString() ?? '';
                          final displayId = rawId.isNotEmpty ? 'C${rawId}R' : '';
                          return Expanded(flex: 3, child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (displayId.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF00CFFF).withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: const Color(0xFF00CFFF).withOpacity(0.5), width: 1),
                                  ),
                                  child: Text(displayId,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color: Color(0xFF00CFFF), fontSize: 11,
                                          fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                                ),
                              const SizedBox(height: 4),
                              Text(team['team_name']?.toString() ?? '',
                                  style: const TextStyle(color: Colors.white,
                                      fontSize: 16, fontWeight: FontWeight.w600),
                                  textAlign: TextAlign.center),
                            ],
                          ));
                        }
                        return const Expanded(flex: 3, child: Text('—',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white24, fontSize: 16)));
                      }),
                      if (maxArenas == 1) const Spacer(flex: 2),
                      Expanded(flex: 2, child: GestureDetector(
                        onTap: () => _cycleStatus(catId, matchNum),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(
                            color: status.color.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: status.color, width: 1.5),
                          ),
                          child: Text(status.label,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: status.color,
                                  fontWeight: FontWeight.bold, fontSize: 13)),
                        ),
                      )),
                    ]),
                  );
                }),
      ),
    ]);
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [
          Color(0xFF2D0E7A), Color(0xFF1A0850), Color(0xFF2D0E7A)]),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            RichText(text: const TextSpan(children: [
              TextSpan(text: 'Make', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
              TextSpan(text: 'bl',   style: TextStyle(color: Color(0xFF00CFFF), fontSize: 26, fontWeight: FontWeight.bold)),
              TextSpan(text: 'ock',  style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
            ])),
            const Text('Construct Your Dreams',
                style: TextStyle(color: Colors.white38, fontSize: 13)),
          ]),
          Image.asset('assets/images/CenterLogo.png', height: 72, fit: BoxFit.contain),
          const Text('CREOTEC',
              style: TextStyle(color: Colors.white, fontSize: 20,
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
          const Text('LIVE', style: TextStyle(color: Color(0xFF00FF88), fontSize: 11,
              fontWeight: FontWeight.bold, letterSpacing: 1.2)),
          Text(timeStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ]),
      ]),
    );
  }

  Widget _headerCell(String text, {int flex = 1, bool center = false}) => Expanded(
    flex: flex,
    child: Text(text,
        textAlign: center ? TextAlign.center : TextAlign.left,
        style: const TextStyle(color: Colors.white70,
            fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 0.8)),
  );
}

// ── Bracket canvas ─────────────────────────────────────────────────────────
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
          painter: _BracketLinePainter(
              rounds: rounds, matchW: matchW, matchH: matchH, gapH: gapH, gapW: gapW),
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

  String _roundLabel(int roundIdx) {
    final totalRounds = rounds.length;
    if (roundIdx == totalRounds - 1) return 'FINAL';
    if (roundIdx == totalRounds - 2) return 'SEMI-FINAL';
    if (roundIdx == totalRounds - 3) return 'QUARTER-FINAL';
    return 'ROUND ${roundIdx + 1}';
  }

  Color _roundColor(int roundIdx) {
    final totalRounds = rounds.length;
    if (roundIdx == totalRounds - 1) return const Color(0xFFFFD700);
    if (roundIdx == totalRounds - 2) return const Color(0xFF00FF88);
    if (roundIdx == totalRounds - 3) return const Color(0xFF00CFFF);
    return const Color(0xFF7B6AAA);
  }

  Widget _positionedCard(int r, int m, double totalH) {
    final off   = _offset(r, m, totalH);
    final match = rounds[r][m];
    final label = _roundLabel(r);
    final color = _roundColor(r);
    const double footerH = 22;

    return Positioned(
      left: off.dx, top: off.dy, width: matchW,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MatchCard(match: match, onTap: () => onMatchTap(match), cardH: matchH),
          const SizedBox(height: 4),
          Container(
            height: footerH,
            width: matchW,
            decoration: BoxDecoration(
              color: color.withOpacity(0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withOpacity(0.3), width: 1),
            ),
            alignment: Alignment.center,
            child: Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.4)),
          ),
        ],
      ),
    );
  }
}

// ── Line painter ──────────────────────────────────────────────────────────
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
        final top    = _rightMid(r, m,     size.height);
        final bot    = _rightMid(r, m + 1, size.height);
        final midX   = top.dx + gapW / 2;
        final midY   = (top.dy + bot.dy) / 2;
        final nextM  = m ~/ 2;
        if (nextM >= rounds[r + 1].length) continue;
        final nextIn = _leftMid(r + 1, nextM, size.height);

        final hasWinner1 = rounds[r][m].winner != null && !rounds[r][m].winner!.isBye;
        final hasWinner2 = rounds[r][m + 1].winner != null && !rounds[r][m + 1].winner!.isBye;

        final path = Path()
          ..moveTo(top.dx, top.dy)
          ..lineTo(midX, top.dy)
          ..lineTo(midX, bot.dy)
          ..lineTo(bot.dx, bot.dy);
        canvas.drawPath(path, paintLine);
        canvas.drawLine(Offset(midX, midY), Offset(nextIn.dx, midY),
            (hasWinner1 || hasWinner2) ? paintWin : paintLine);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

// ── Match card ────────────────────────────────────────────────────────────
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
    if (hasWinner)      { borderCol = const Color(0xFF00FF88).withOpacity(0.5); glowCol = const Color(0xFF00FF88).withOpacity(0.15); glowBlur = 12; }
    else if (canPlay)   { borderCol = const Color(0xFF5B2CC0); glowCol = const Color(0xFF5B2CC0).withOpacity(0.2); glowBlur = 8; }
    else                { borderCol = const Color(0xFF1C1045); glowCol = Colors.transparent; glowBlur = 0; }

    const double kBorder = 1.5;
    final double inner   = cardH - kBorder * 2;
    const double kVsW    = 36.0;
    final double fs      = (cardH * 0.18).clamp(10.0, 22.0);

    return GestureDetector(
      onTap: canPlay || hasWinner ? onTap : null,
      child: Container(
        height: cardH,
        decoration: BoxDecoration(
          color: hasWinner ? const Color(0xFF091910) : const Color(0xFF120A32),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderCol, width: kBorder),
          boxShadow: [
            BoxShadow(color: glowCol, blurRadius: glowBlur),
            BoxShadow(color: Colors.black.withOpacity(0.45),
                blurRadius: 5, offset: const Offset(0, 2)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(
            height: inner,
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: _teamCell(
                  name: match.team1.teamName, isBye: match.team1.isBye,
                  isWinner: t1Wins, isDim: hasWinner && !t1Wins,
                  align: CrossAxisAlignment.end, fontSize: fs)),
              SizedBox(width: kVsW, child: _vsCell(bothReal, hasWinner, fs)),
              Expanded(child: _teamCell(
                  name: match.team2.teamName, isBye: match.team2.isBye,
                  isWinner: t2Wins, isDim: hasWinner && !t2Wins,
                  align: CrossAxisAlignment.start, fontSize: fs)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _teamCell({
    required String name, required bool isBye,
    required bool isWinner, required bool isDim,
    required CrossAxisAlignment align, required double fontSize,
  }) {
    final bool isPlaceholder = name == 'TBD' || isBye;
    Color bg, textCol;
    if (isWinner)          { bg = const Color(0xFF00FF88).withOpacity(0.09); textCol = const Color(0xFF00FF88); }
    else if (isDim)        { bg = Colors.transparent; textCol = const Color(0xFF2A1C4A); }
    else if (isPlaceholder){ bg = Colors.transparent; textCol = const Color(0xFF22163A); }
    else                   { bg = Colors.transparent; textCol = Colors.white.withOpacity(0.9); }

    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: align,
        children: [
          if (isWinner)
            Icon(Icons.emoji_events, color: const Color(0xFFFFD700),
                size: (fontSize * 0.9).clamp(10.0, 14.0)),
          Text(name,
              textAlign: align == CrossAxisAlignment.end ? TextAlign.right : TextAlign.left,
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: textCol, fontSize: fontSize,
                  fontWeight: isWinner ? FontWeight.bold : FontWeight.w600, height: 1.2)),
        ],
      ),
    );
  }

  Widget _vsCell(bool bothReal, bool hasWinner, double fs) {
    final bool glowing = bothReal && !hasWinner;
    return Container(
      color: const Color(0xFF0A0520),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(width: 1, height: 6, color: Colors.white.withOpacity(0.06)),
        const SizedBox(height: 3),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            gradient: glowing
                ? const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                    colors: [Color(0xFF9B55F0), Color(0xFF5318B0)])
                : null,
            color: glowing ? null : const Color(0xFF0E0628),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
                color: glowing
                    ? const Color(0xFFBB88FF).withOpacity(0.45)
                    : Colors.white.withOpacity(0.05)),
            boxShadow: glowing
                ? [BoxShadow(color: const Color(0xFF8844EE).withOpacity(0.55),
                    blurRadius: 12, spreadRadius: 1)]
                : [],
          ),
          child: Text('VS',
              style: TextStyle(
                  color: glowing ? Colors.white : Colors.white.withOpacity(0.08),
                  fontSize: (fs * 0.85).clamp(10.0, 14.0),
                  fontWeight: FontWeight.w900, letterSpacing: 1.8,
                  fontStyle: FontStyle.italic)),
        ),
        const SizedBox(height: 3),
        Container(width: 1, height: 6, color: Colors.white.withOpacity(0.06)),
      ]),
    );
  }
}

// ── Pulsing dot ───────────────────────────────────────────────────────────
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
  Widget build(BuildContext context) => FadeTransition(
    opacity: _anim,
    child: Container(width: 8, height: 8,
        decoration: const BoxDecoration(color: Color(0xFF00FF88), shape: BoxShape.circle)),
  );
}