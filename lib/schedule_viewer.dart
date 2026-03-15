import 'dart:async';
import 'dart:math';
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

// ── Group Stage Models ───────────────────────────────────────────────────────
class GroupTeam {
  final int    teamId;
  final String teamName;
  int wins   = 0;
  int losses = 0;
  int points = 0;
  GroupTeam({required this.teamId, required this.teamName});
  int get gamesPlayed => wins + losses;
}

class GroupMatch {
  final String   id;
  final GroupTeam team1;
  final GroupTeam team2;
  GroupTeam? winner;
  int? score1;
  int? score2;
  String? scheduleTime;   // e.g. "08:30"
  int?    matchId;        // DB match_id for linking to tbl_score
  bool get isDone => winner != null;
  GroupMatch({required this.id, required this.team1, required this.team2,
      this.scheduleTime, this.matchId});
}

class TournamentGroup {
  final String           label;
  final List<GroupTeam>  teams;
  final List<GroupMatch> matches;
  TournamentGroup({required this.label, required this.teams, required this.matches});
}

// ── Bracket data models ──────────────────────────────────────────────────────
class BracketTeam {
  final int    teamId;
  final String teamName;
  bool   isBye;
  int?   score;
  int    seed;
  BracketTeam({required this.teamId, required this.teamName,
    this.isBye = false, this.score, this.seed = 0});
}

enum BracketSide { upper, lower }

class BracketMatch {
  final String  id;
  BracketTeam   team1;
  BracketTeam   team2;
  BracketTeam?  winner;
  BracketTeam?  loser;
  final int     round;
  final int     position;
  final BracketSide side;
  String?       scheduleTime;
  int score1 = 0;
  int score2 = 0;
  bool get isBO3 => id.startsWith('gf');
  bool get isDone => winner != null;
  BracketMatch({
    required this.id, required this.team1, required this.team2,
    required this.round, required this.position,
    this.side = BracketSide.upper, this.winner, this.scheduleTime,
  });
}

// ── Helpers ──────────────────────────────────────────────────────────────────
String _fmtTeamId(String rawId) {
  if (rawId.isEmpty) return '';
  final n = int.tryParse(rawId);
  if (n == null) return rawId;
  return 'C${n.toString().padLeft(3, '0')}R';
}

BracketTeam _tbd() => BracketTeam(teamId: -99, teamName: 'TBD');
BracketTeam _bye(int n) =>
    BracketTeam(teamId: -(n + 100), teamName: 'BYE', isBye: true);

// ════════════════════════════════════════════════════════════════════════════
// Main widget
// ════════════════════════════════════════════════════════════════════════════
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
  String    _lastGroupSignature = '';

  int? _soccerCategoryId;

  // ── Soccer Group Stage ───────────────────────────────────────────────────
  List<Map<String, dynamic>> _soccerTeams     = [];
  List<TournamentGroup>      _groups          = [];
  bool                       _groupsGenerated = false;
  final Set<String>          _expandedGroups  = {};

  // ── Soccer Schedule — loaded directly from DB, no pairKey dependency ────
  // Each entry: {matchId, groupLabel, time, team1, team2}
  List<Map<String, dynamic>> _soccerScheduleRows = [];
  String _lastScheduleSig = '';

  // ── Soccer Bracket ───────────────────────────────────────────────────────
  List<BracketMatch> _playInMatches = [];
  bool _playInSeeded = false;

  List<BracketMatch> _ubMatches = [];
  List<BracketMatch> _lbMatches = [];
  List<List<BracketMatch>> _ubRounds = [];
  List<List<BracketMatch>> _lbRounds = [];
  BracketMatch?      _grandFinal;
  bool               _bracketSeeded = false;

  // ── Soccer inner tab controller ──────────────────────────────────────────
  TabController? _soccerTabCtrl;

  @override
  void initState() {
    super.initState();
    _loadData(initial: true);
    _autoRefreshTimer = Timer.periodic(
        const Duration(seconds: 2), (_) => _silentRefresh());
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _tabController?.dispose();
    _soccerTabCtrl?.dispose();
    super.dispose();
  }

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

  bool _allGroupMatchesDone() {
    if (_groups.isEmpty) return false;
    return _groups.every((g) => g.matches.every((m) => m.isDone));
  }

  Future<void> _silentRefresh() async {
    try {
      final conn   = await DBHelper.getConnection();

      // Check schedule data changes
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

      // Check group changes from DB (real-time sync for other devices)
      if (_soccerCategoryId != null) {
        try {
          final gResult = await conn.execute(
            "SELECT group_label, team_id, team_name FROM tbl_soccer_groups WHERE category_id = ${_soccerCategoryId} ORDER BY group_label, id",
          );
          final gRows = gResult.rows.map((r) => r.assoc()).toList();
          final gSig  = _buildSignature(gRows);
          if (gSig != _lastGroupSignature) {
            _lastGroupSignature = gSig;
            // Rebuild groups from latest DB data
            final Map<String, List<GroupTeam>> groupMap = {};
            for (final row in gRows) {
              final label    = row['group_label']?.toString() ?? '';
              final teamId   = int.tryParse(row['team_id']?.toString() ?? '0') ?? 0;
              final teamName = row['team_name']?.toString() ?? '';
              groupMap.putIfAbsent(label, () => []);
              groupMap[label]!.add(GroupTeam(teamId: teamId, teamName: teamName));
            }
            final labels = groupMap.keys.toList()..sort();
            final groups = <TournamentGroup>[];
            for (final label in labels) {
              final groupTeams = groupMap[label]!;
              final matches    = <GroupMatch>[];
              int matchIdx     = 0;
              for (int i = 0; i < groupTeams.length; i++) {
                for (int j = i + 1; j < groupTeams.length; j++) {
                  matches.add(GroupMatch(
                      id: 'g${label}_m$matchIdx',
                      team1: groupTeams[i], team2: groupTeams[j]));
                  matchIdx++;
                }
              }
              groups.add(TournamentGroup(label: label, teams: groupTeams, matches: matches));
            }
            if (mounted) {
              setState(() {
                _groups          = groups;
                _groupsGenerated = groups.isNotEmpty;
              });
            }
          }
      // Reload schedule rows directly from DB on every refresh
      if (_soccerCategoryId != null) await _loadSoccerSchedule();
        } catch (_) {}
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

      List<Map<String, dynamic>> soccerTeams = [];
      if (soccerCatId != null) {
        soccerTeams = await DBHelper.getTeamsByCategory(soccerCatId);
      }

      final prevIdx = _tabController?.index ?? 0;
      // Store soccer category id before loading groups
      _soccerCategoryId = soccerCatId;
      _tabController?.dispose();
      _tabController = TabController(
        length: categories.length, vsync: this,
        initialIndex: prevIdx.clamp(0, (categories.length - 1).clamp(0, 9999)),
      );

      final prevSoccerIdx = _soccerTabCtrl?.index ?? 0;
      _soccerTabCtrl?.dispose();
      _soccerTabCtrl = TabController(
          length: 3, vsync: this,
          initialIndex: prevSoccerIdx.clamp(0, 2));

      setState(() {
        _categories         = categories;
        _scheduleByCategory = scheduleByCategory;
        _soccerCategoryId   = soccerCatId;
        _soccerTeams        = soccerTeams;
        _isLoading          = false;
        _lastUpdated        = DateTime.now();
      });

      // Load previously saved groups from DB; auto-generate if none saved yet
      if (!_groupsGenerated) {
        await _loadGroupsFromDB();
        // If still no groups after DB load, auto-generate and save
        if (!_groupsGenerated && soccerTeams.length >= 4) {
          await _generateGroups(teamsOverride: soccerTeams);
        }
      // Always load schedule directly from DB
      await _loadSoccerSchedule();
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Failed to load: $e'), backgroundColor: Colors.red));
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // GROUP STAGE LOGIC
  // ════════════════════════════════════════════════════════════════════════════
  Future<void> _generateGroups({List<Map<String, dynamic>>? teamsOverride}) async {
    final sourceTeams = teamsOverride ?? _soccerTeams;
    if (sourceTeams.isEmpty) return;
    final shuffled = List<Map<String, dynamic>>.from(sourceTeams)..shuffle(Random());
    final n = shuffled.length;
    const int maxGroups     = 8;
    const int teamsPerGroup = 4;
    final int numGroups = (n / teamsPerGroup).ceil().clamp(1, maxGroups);
    final int baseSize  = n ~/ numGroups;
    final int extras    = n % numGroups;
    final counts = List.generate(numGroups, (i) => baseSize + (i < extras ? 1 : 0));
    final labels = List.generate(
        numGroups, (i) => String.fromCharCode('A'.codeUnitAt(0) + i));
    final groups = <TournamentGroup>[];
    int cursor = 0;
    for (int gi = 0; gi < numGroups; gi++) {
      final count      = counts[gi];
      final groupTeams = shuffled.sublist(cursor, cursor + count)
          .map((t) => GroupTeam(
                teamId:   int.parse(t['team_id'].toString()),
                teamName: t['team_name'].toString()))
          .toList();
      cursor += count;
      final matches  = <GroupMatch>[];
      int   matchIdx = 0;
      for (int i = 0; i < groupTeams.length; i++) {
        for (int j = i + 1; j < groupTeams.length; j++) {
          matches.add(GroupMatch(
              id: 'g${labels[gi]}_m$matchIdx',
              team1: groupTeams[i], team2: groupTeams[j]));
          matchIdx++;
        }
      }
      groups.add(TournamentGroup(
          label: labels[gi], teams: groupTeams, matches: matches));
    }
    setState(() {
      _groups          = groups;
      _groupsGenerated = true;
      _playInSeeded    = false;
      _bracketSeeded   = false;
      _playInMatches   = [];
      _ubMatches       = [];
      _lbMatches       = [];
      _ubRounds        = [];
      _lbRounds        = [];
      _grandFinal      = null;
    });
    // Save the newly generated groups to the database
    await _saveGroupsToDB(groups);
  }

  // ── Save generated groups to DB ──────────────────────────────────────────
  Future<void> _saveGroupsToDB(List<TournamentGroup> groups) async {
    if (_soccerCategoryId == null) return;
    try {
      final conn = await DBHelper.getConnection();
      // Ensure table exists
      await conn.execute("""
        CREATE TABLE IF NOT EXISTS tbl_soccer_groups (
          id          INT AUTO_INCREMENT PRIMARY KEY,
          category_id INT         NOT NULL,
          group_label VARCHAR(5)  NOT NULL,
          team_id     INT         NOT NULL,
          team_name   VARCHAR(255) NOT NULL,
          created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
      """);
      // Clear previous groups for this category
      await conn.execute(
        "DELETE FROM tbl_soccer_groups WHERE category_id = ${_soccerCategoryId}",
      );
      // Insert new groups
      for (final g in groups) {
        for (final t in g.teams) {
          final catId   = _soccerCategoryId;
          final label   = g.label.replaceAll("'", "''");
          final teamId  = t.teamId;
          final name    = t.teamName.replaceAll("'", "''");
          await conn.execute(
            "INSERT INTO tbl_soccer_groups (category_id, group_label, team_id, team_name) VALUES ($catId, '$label', $teamId, '$name')",
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('⚠️ Could not save groups to DB: $e'),
              backgroundColor: Colors.orange));
      }
    }
  }

  // ── Load saved groups from DB ────────────────────────────────────────────
  Future<void> _loadGroupsFromDB() async {
    if (_soccerCategoryId == null) return;
    try {
      final conn = await DBHelper.getConnection();
      // Check if the table exists first
      final check = await conn.execute("""
        SELECT COUNT(*) as cnt FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_name = 'tbl_soccer_groups'
      """);
      final tableExists = check.rows.isNotEmpty &&
          (int.tryParse(check.rows.first.assoc()['cnt']?.toString() ?? '0') ?? 0) > 0;
      if (!tableExists) return;

      final result = await conn.execute(
        "SELECT group_label, team_id, team_name FROM tbl_soccer_groups WHERE category_id = ${_soccerCategoryId} ORDER BY group_label, id",
      );
      final rows = result.rows.map((r) => r.assoc()).toList();
      if (rows.isEmpty) return;

      // Reconstruct groups from DB rows
      final Map<String, List<GroupTeam>> groupMap = {};
      for (final row in rows) {
        final label    = row['group_label']?.toString() ?? '';
        final teamId   = int.tryParse(row['team_id']?.toString() ?? '0') ?? 0;
        final teamName = row['team_name']?.toString() ?? '';
        groupMap.putIfAbsent(label, () => []);
        groupMap[label]!.add(GroupTeam(teamId: teamId, teamName: teamName));
      }


      final labels = groupMap.keys.toList()..sort();
      final groups = <TournamentGroup>[];
      for (final label in labels) {
        final groupTeams = groupMap[label]!;
        final matches    = <GroupMatch>[];
        int   matchIdx   = 0;
        for (int i = 0; i < groupTeams.length; i++) {
          for (int j = i + 1; j < groupTeams.length; j++) {
            // scheduleTime and matchId are now populated by _loadSoccerSchedule()
            // via _soccerScheduleRows — no pairKey lookup needed here
            matches.add(GroupMatch(
              id:    'g${label}_m$matchIdx',
              team1: groupTeams[i],
              team2: groupTeams[j],
            ));
            matchIdx++;
          }
        }
        groups.add(TournamentGroup(label: label, teams: groupTeams, matches: matches));
      }

      if (mounted) {
        setState(() {
          _groups          = groups;
          _groupsGenerated = true;
        });
      }
    } catch (_) {
      // Table may not exist yet — silently skip
    }
  }


  // ── Load soccer match schedule DIRECTLY from DB ──────────────────────────
  // Single query joining tbl_teamschedule, tbl_match, tbl_schedule,
  // tbl_soccer_groups. Groups rows by match_id into {matchId, groupLabel,
  // time, team1, team2}. No pairKey logic needed.
  Future<void> _loadSoccerSchedule() async {
    if (_soccerCategoryId == null) return;
    try {
      final conn = await DBHelper.getConnection();
      final result = await conn.execute("""
        SELECT
          m.match_id,
          COALESCE(sg.group_label, '?') AS group_label,
          TIME_FORMAT(s.schedule_start, '%H:%i') AS match_time,
          t.team_id,
          t.team_name,
          ts.teamschedule_id,
          m.bracket_type,
          ts.arena_number
        FROM tbl_match m
        JOIN tbl_schedule     s  ON m.schedule_id  = s.schedule_id
        JOIN tbl_teamschedule ts ON ts.match_id     = m.match_id
        JOIN tbl_team         t  ON ts.team_id      = t.team_id
        LEFT JOIN tbl_soccer_groups sg
               ON sg.team_id     = ts.team_id
              AND sg.category_id = ${_soccerCategoryId}
        WHERE t.category_id = ${_soccerCategoryId}
          AND m.bracket_type IN ('group','round-of-32','round-of-16','quarter-finals','semi-finals','third-place','final')
        ORDER BY s.schedule_start, m.match_id, ts.teamschedule_id
      """);

      final rows = result.rows.map((r) => r.assoc()).toList();
      final sig  = rows.map((r) => r.toString()).join('|');
      if (sig == _lastScheduleSig) return;
      _lastScheduleSig = sig;

      // Pivot: group rows by match_id, collect up to 2 teams per match
      final Map<int, Map<String, dynamic>> byMatch = {};
      for (final row in rows) {
        final matchId = int.tryParse(row['match_id']?.toString() ?? '0') ?? 0;
        final teamId  = int.tryParse(row['team_id']?.toString()  ?? '0') ?? 0;
        if (matchId == 0 || teamId == 0) continue;

        byMatch.putIfAbsent(matchId, () => {
          'matchId':    matchId,
          'groupLabel': row['group_label']?.toString() ?? '?',
          'time':       row['match_time']?.toString()  ?? '',
          'team1':      '',
          'team2':      '',
          'team1Id':    0,
          'team2Id':    0,
          'arena':      0,
          'bracketType': '',
        });

        final entry = byMatch[matchId]!;
        if ((entry['team1'] as String).isEmpty) {
          entry['team1']   = row['team_name']?.toString() ?? '';
          entry['arena']   = int.tryParse(row['arena_number']?.toString() ?? '0') ?? 0;
          entry['bracketType'] = row['bracket_type']?.toString() ?? 'group';
          entry['team1Id'] = teamId;
        } else if ((entry['team2'] as String).isEmpty) {
          entry['team2']   = row['team_name']?.toString() ?? '';
          entry['team2Id'] = teamId;
        }
      }

      final scheduleRows = byMatch.values
          .where((e) =>
              (e['team1'] as String).isNotEmpty &&
              (e['team2'] as String).isNotEmpty)
          .toList()
        ..sort((a, b) {
          final tA = a['time'] as String;
          final tB = b['time'] as String;
          if (tA.isEmpty && tB.isEmpty) return 0;
          if (tA.isEmpty) return 1;
          if (tB.isEmpty) return -1;
          return tA.compareTo(tB);
        });

      if (mounted) {
        setState(() {
          _soccerScheduleRows = scheduleRows;
          if (scheduleRows.isNotEmpty) _groupsGenerated = true;
        });
      }
    } catch (e) {
      debugPrint('⚠️ _loadSoccerSchedule error: $e');
    }
  }


  void _setGroupMatchResult(GroupMatch match, GroupTeam winner, int s1, int s2) {
    final wasLoser1 = !match.isDone
        ? null
        : (match.winner == match.team1 ? match.team2 : match.team1);
    setState(() {
      if (match.isDone && wasLoser1 != null) {
        match.winner!.wins--;
        match.winner!.points--;
        wasLoser1.losses--;
      }
      match.winner = winner;
      match.score1 = s1;
      match.score2 = s2;
      final loser = winner == match.team1 ? match.team2 : match.team1;
      winner.wins++;
      winner.points++;
      loser.losses++;
    });
  }

  List<GroupTeam> _getGroupStandings(TournamentGroup group) {
    final sorted = List<GroupTeam>.from(group.teams);
    sorted.sort((a, b) {
      if (b.points != a.points) return b.points.compareTo(a.points);
      for (final m in group.matches) {
        if (m.isDone) {
          if (m.team1 == a && m.team2 == b) return m.winner == a ? -1 : 1;
          if (m.team1 == b && m.team2 == a) return m.winner == b ? 1 : -1;
        }
      }
      return a.teamName.compareTo(b.teamName);
    });
    return sorted;
  }

  List<GroupTeam> _getAdvancingTeams() {
    final result = <GroupTeam>[];
    for (final g in _groups) {
      final standings = _getGroupStandings(g);
      for (int i = 0; i < standings.length && i < 2; i++) {
        result.add(standings[i]);
      }
    }
    result.sort((a, b) => b.points.compareTo(a.points));
    return result;
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ── BUILD PREVIEW SEEDS from group standings ──────────────────────────────
  // Always returns a list so bracket tab can show a preview at any time.
  // ════════════════════════════════════════════════════════════════════════════
  List<BracketTeam> _buildPreviewSeeds() {
    if (_bracketSeeded) {
      return _playInMatches
          .where((m) => m.winner != null)
          .map((m) => m.winner!)
          .toList();
    }
    if (_playInSeeded) {
      return _playInMatches.map((m) => m.winner ?? m.team1).toList();
    }
    if (_groupsGenerated) {
      return _getAdvancingTeams().asMap().entries.map((e) => BracketTeam(
            teamId:   e.value.teamId,
            teamName: e.value.teamName,
            seed:     e.key + 1,
          )).toList();
    }
    return [];
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ════════════════════════════════════════════════════════════════════════════
  // PLAY-IN — Cross-group pairing (BO1)
  //   Groups are paired: (A,B), (C,D), (E,F), (G,H)
  //   Match 1: Group A  #1  vs  Group B  #2
  //   Match 2: Group A  #2  vs  Group B  #1
  //   Match 3: Group C  #1  vs  Group D  #2  … etc.
  // Winners advance to the Double Elimination bracket.
  // ════════════════════════════════════════════════════════════════════════════
  void _seedPlayIn() {
    if (!_allGroupMatchesDone()) return;

    BracketTeam _bt(GroupTeam t, int seed) =>
        BracketTeam(teamId: t.teamId, teamName: t.teamName, seed: seed);

    final matches  = <BracketMatch>[];
    int   pos      = 0;
    int   seedNum  = 1;

    // Pair consecutive groups: (0,1), (2,3), (4,5), (6,7)
    for (int gi = 0; gi + 1 < _groups.length; gi += 2) {
      final sA = _getGroupStandings(_groups[gi]);
      final sB = _getGroupStandings(_groups[gi + 1]);
      if (sA.length < 2 || sB.length < 2) continue;

      final gLabelA = _groups[gi].label;
      final gLabelB = _groups[gi + 1].label;

      // Match 1: A#1 vs B#2
      matches.add(BracketMatch(
        id: 'pi_${gLabelA}1v${gLabelB}2',
        team1: _bt(sA[0], seedNum),
        team2: _bt(sB[1], seedNum + 1),
        round: 0, position: pos++, side: BracketSide.upper,
      ));
      seedNum += 2;

      // Match 2: A#2 vs B#1
      matches.add(BracketMatch(
        id: 'pi_${gLabelA}2v${gLabelB}1',
        team1: _bt(sA[1], seedNum),
        team2: _bt(sB[0], seedNum + 1),
        round: 0, position: pos++, side: BracketSide.upper,
      ));
      seedNum += 2;
    }

    // Odd group left over — pair its own top1 vs top2
    if (_groups.length % 2 == 1) {
      final last = _groups.last;
      final sL   = _getGroupStandings(last);
      if (sL.length >= 2) {
        matches.add(BracketMatch(
          id: 'pi_${last.label}1v${last.label}2',
          team1: _bt(sL[0], seedNum),
          team2: _bt(sL[1], seedNum + 1),
          round: 0, position: pos++, side: BracketSide.upper,
        ));
      }
    }

    setState(() {
      _playInMatches = matches;
      _playInSeeded  = true;
      _bracketSeeded = false;
      _ubMatches     = [];
      _lbMatches     = [];
      _ubRounds      = [];
      _lbRounds      = [];
      _grandFinal    = null;
    });
  }

  bool get _playInDone =>
      _playInSeeded && _playInMatches.every((m) => m.winner != null);

  void _setPlayInResult(BracketMatch match, BracketTeam winner) {
    setState(() {
      match.winner = winner;
      match.loser  = winner.teamId == match.team1.teamId ? match.team2 : match.team1;
      if (_playInDone && !_bracketSeeded) _seedDoubleElim();
    });
  }

  // ════════════════════════════════════════════════════════════════════════════
  // DOUBLE ELIMINATION — MPL style
  // ════════════════════════════════════════════════════════════════════════════
  void _seedDoubleElim() {
    if (!_playInDone) return;

    final winners = _playInMatches.map((m) => m.winner!).toList();
    final n = winners.length;

    // Next power-of-2
    int slots = 1;
    while (slots < n) slots <<= 1;

    // Pad with BYEs
    final padded = List<BracketTeam>.from(winners);
    for (int i = n; i < slots; i++) {
      padded.add(BracketTeam(teamId: -(200 + i), teamName: 'BYE', isBye: true));
    }

    // ── MPL pairing: 1vN, 2v(N-1) … ────────────────────────────────────────
    final ubR1 = <BracketMatch>[];
    int lo = 0, hi = padded.length - 1, pos = 0;
    while (lo < hi) {
      final t1 = padded[lo];
      final t2 = padded[hi];
      final m  = BracketMatch(
        id: 'ub_r0_m$pos', team1: t1, team2: t2,
        round: 0, position: pos, side: BracketSide.upper,
      );
      if (t2.isBye) { m.winner = t1; m.loser = t2; }
      if (t1.isBye) { m.winner = t2; m.loser = t1; }
      ubR1.add(m);
      lo++; hi--; pos++;
    }
    final ubRounds = <List<BracketMatch>>[ubR1];

    // Auto-advance BYE winners into UB R2
    List<BracketMatch> prevUb = ubR1;
    int rNum = 1;
    while (prevUb.length > 1) {
      final next = <BracketMatch>[];
      for (int i = 0; i < prevUb.length; i += 2) {
        next.add(BracketMatch(
          id: 'ub_r${rNum}_m${i ~/ 2}',
          team1: _tbd(), team2: _tbd(),
          round: rNum, position: i ~/ 2, side: BracketSide.upper,
        ));
      }
      ubRounds.add(next);
      prevUb = next;
      rNum++;
    }

    // Seed UB R2 with auto-advanced BYE winners
    _autoAdvanceUbByes(ubRounds);

    // ── LB rounds ────────────────────────────────────────────────────────────
    final lbRounds = <List<BracketMatch>>[];
    int lbNum = 0;

    // LB R1: UB R1 losers paired
    final lbR1Count = ubR1.length ~/ 2;
    if (lbR1Count > 0) {
      lbRounds.add(List.generate(lbR1Count, (i) => BracketMatch(
        id: 'lb_r0_m$i', team1: _tbd(), team2: _tbd(),
        round: 0, position: i, side: BracketSide.lower,
      )));
      lbNum++;
    }

    List<BracketMatch> prevLb = lbRounds.isNotEmpty ? lbRounds.last : [];
    int ubDropIdx = 1;

    while (prevLb.length > 1 || ubDropIdx < ubRounds.length) {
      if (ubDropIdx < ubRounds.length) {
        // Injection round: LB survivors get UB losers added
        final injCount = max(1, prevLb.length);
        final inj = List.generate(injCount, (i) => BracketMatch(
          id: 'lb_r${lbNum}_m$i', team1: _tbd(), team2: _tbd(),
          round: lbNum, position: i, side: BracketSide.lower,
        ));
        lbRounds.add(inj);
        prevLb = inj;
        lbNum++;
        ubDropIdx++;
      }
      if (prevLb.length <= 1) break;
      // Reduction round: halve match count
      final redCount = max(1, prevLb.length ~/ 2);
      final red = List.generate(redCount, (i) => BracketMatch(
        id: 'lb_r${lbNum}_m$i', team1: _tbd(), team2: _tbd(),
        round: lbNum, position: i, side: BracketSide.lower,
      ));
      lbRounds.add(red);
      prevLb = red;
      lbNum++;
    }

    // LB Final
    final lbFinal = BracketMatch(
      id: 'lb_final', team1: _tbd(), team2: _tbd(),
      round: lbNum, position: 0, side: BracketSide.lower,
    );
    lbRounds.add([lbFinal]);

    final gf = BracketMatch(
      id: 'gf', team1: _tbd(), team2: _tbd(),
      round: 0, position: 0, side: BracketSide.upper,
    );

    setState(() {
      _ubMatches     = ubRounds.expand((r) => r).toList();
      _lbMatches     = lbRounds.expand((r) => r).toList();
      _ubRounds      = ubRounds;
      _lbRounds      = lbRounds;
      _grandFinal    = gf;
      _bracketSeeded = true;
    });
  }

  void _autoAdvanceUbByes(List<List<BracketMatch>> ubRounds) {
    if (ubRounds.length < 2) return;
    final r1 = ubRounds[0];
    final r2 = ubRounds[1];
    for (int i = 0; i < r1.length; i++) {
      final m = r1[i];
      if (m.winner != null && !m.winner!.isBye) {
        final slot = i ~/ 2;
        if (slot < r2.length) {
          if (i % 2 == 0) r2[slot].team1 = m.winner!;
          else              r2[slot].team2 = m.winner!;
        }
      }
    }
  }

  // ── UB result: auto-advance winner, drop loser to correct LB slot ─────────
  void _setUBMatchResult(BracketMatch match, BracketTeam winner) {
    final loser = winner.teamId == match.team1.teamId ? match.team2 : match.team1;
    setState(() {
      match.winner = winner;
      match.loser  = loser;

      final nextUbIdx = match.round + 1;

      // Advance winner to next UB round
      if (nextUbIdx < _ubRounds.length) {
        final nextRound = _ubRounds[nextUbIdx];
        final slot = match.position ~/ 2;
        if (slot < nextRound.length) {
          if (match.position % 2 == 0) nextRound[slot].team1 = winner;
          else                          nextRound[slot].team2 = winner;
        }
      } else {
        // UB Final winner → Grand Final team1
        _grandFinal?.team1 = winner;
      }

      // Drop loser into LB
      if (match.round == 0) {
        // UB R1 losers → LB R1 (paired)
        if (_lbRounds.isNotEmpty) {
          final lbR1 = _lbRounds[0];
          final slot  = match.position ~/ 2;
          if (slot < lbR1.length) {
            if (match.position % 2 == 0) lbR1[slot].team1 = loser;
            else                          lbR1[slot].team2 = loser;
          }
        }
      } else {
        // UB Rn losers → injection round = 2*round - 1
        final lbDropIdx = match.round * 2 - 1;
        if (lbDropIdx < _lbRounds.length) {
          final lbRound = _lbRounds[lbDropIdx];
          bool placed = false;
          for (final m in lbRound) {
            if (m.team1.teamId == -99) { m.team1 = loser; placed = true; break; }
            if (m.team2.teamId == -99) { m.team2 = loser; placed = true; break; }
          }
          if (!placed && lbRound.isNotEmpty) lbRound[0].team2 = loser;
        }
        // UB Final loser → LB Final team2
        if (nextUbIdx >= _ubRounds.length && _lbRounds.isNotEmpty) {
          _lbRounds.last[0].team2 = loser;
        }
      }
    });
  }

  // ── LB result: auto-advance winner ────────────────────────────────────────
  void _setLBMatchResult(BracketMatch match, BracketTeam winner) {
    final loser = winner.teamId == match.team1.teamId ? match.team2 : match.team1;
    setState(() {
      match.winner = winner;
      match.loser  = loser;

      if (match.id == 'lb_final') {
        _grandFinal?.team2 = winner;
        return;
      }

      final myRoundIdx = _lbRounds.indexWhere((r) => r.contains(match));
      final nextIdx    = myRoundIdx + 1;
      if (nextIdx < _lbRounds.length) {
        final nextRound = _lbRounds[nextIdx];
        if (nextRound.length < _lbRounds[myRoundIdx].length) {
          final slot = match.position ~/ 2;
          if (slot < nextRound.length) {
            if (match.position % 2 == 0) nextRound[slot].team1 = winner;
            else                          nextRound[slot].team2 = winner;
          }
        } else {
          final slot = match.position;
          if (slot < nextRound.length) {
            if (nextRound[slot].team1.teamId == -99)      nextRound[slot].team1 = winner;
            else if (nextRound[slot].team2.teamId == -99) nextRound[slot].team2 = winner;
          } else if (nextRound.isNotEmpty) {
            if (nextRound[0].team1.teamId == -99)      nextRound[0].team1 = winner;
            else if (nextRound[0].team2.teamId == -99) nextRound[0].team2 = winner;
          }
        }
      }
    });
  }

  void _setGrandFinalScore(int s1, int s2) {
    setState(() {
      _grandFinal!.score1 = s1;
      _grandFinal!.score2 = s2;
      if (s1 >= 2)      _grandFinal!.winner = _grandFinal!.team1;
      else if (s2 >= 2) _grandFinal!.winner = _grandFinal!.team2;
      else              _grandFinal!.winner = null;
    });
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PDF EXPORT
  // ════════════════════════════════════════════════════════════════════════════
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
                    final rawId     = team['team_id']?.toString() ?? '';
                    final displayId = _fmtTeamId(rawId);
                    return pw.Expanded(flex: 2, child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        pw.Text(displayId, textAlign: pw.TextAlign.center,
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

  // ════════════════════════════════════════════════════════════════════════════
  // BUILD
  // ════════════════════════════════════════════════════════════════════════════
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

  // ════════════════════════════════════════════════════════════════════════════
  // SOCCER VIEW
  // ════════════════════════════════════════════════════════════════════════════
  Widget _buildSoccerView(
      Map<String, dynamic> category, int catId,
      List<Map<String, dynamic>> matches) {
    final groupsDone = _allGroupMatchesDone() && _groupsGenerated;
    final champion   = _grandFinal?.winner;
    return Column(children: [
      _buildCategoryTitleBar(category, 'SOCCER', matches),
      Container(
        color: const Color(0xFF130742),
        child: TabBar(
          controller: _soccerTabCtrl,
          indicatorColor: const Color(0xFF00FF88),
          indicatorWeight: 3,
          labelColor: const Color(0xFF00FF88),
          unselectedLabelColor: Colors.white54,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1),
          tabs: [
            Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.grid_view, size: 15),
              const SizedBox(width: 5),
              const Text('GROUPS'),
              const SizedBox(width: 5),
              if (!_groupsGenerated)
                _phaseBadge('SETUP', const Color(0xFFFFD700))
              else if (!groupsDone)
                _phaseBadge('LIVE', const Color(0xFF00CFFF))
              else
                _phaseBadge('DONE', Colors.green),
            ])),
            Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.calendar_today, size: 15,
                  color: _groupsGenerated ? const Color(0xFF00FF88) : Colors.white38),
              const SizedBox(width: 5),
              Text('MATCH SCHEDULE',
                  style: TextStyle(
                      color: _groupsGenerated ? const Color(0xFF00FF88) : Colors.white38)),
            ])),
            // BRACKET tab — always available as preview
            Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.account_tree, size: 15,
                  color: _groupsGenerated
                      ? const Color(0xFF00FF88) : const Color(0xFF00CFFF).withOpacity(0.5)),
              const SizedBox(width: 5),
              Text('BRACKET',
                  style: TextStyle(
                      color: _groupsGenerated
                          ? const Color(0xFF00FF88)
                          : const Color(0xFF00CFFF).withOpacity(0.5))),
              const SizedBox(width: 5),
              if (!_groupsGenerated)
                _phaseBadge('PREVIEW', Colors.white24)
              else if (!groupsDone)
                _phaseBadge('PREVIEW', const Color(0xFF00CFFF))
              else if (champion != null)
                _phaseBadge('🏆', const Color(0xFFFFD700))
              else
                _phaseBadge('LIVE', const Color(0xFF00FF88)),
            ])),
          ],
        ),
      ),
      Expanded(
        child: TabBarView(
          controller: _soccerTabCtrl,
          children: [
            _buildGroupsTab(),
            _buildSoccerScheduleTab(catId, matches),
            _buildBracketTab(),   // Always rendered — preview or live
          ],
        ),
      ),
    ]);
  }

  Widget _phaseBadge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: color.withOpacity(0.15),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withOpacity(0.5), width: 1),
    ),
    child: Text(text, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold)),
  );

  // ════════════════════════════════════════════════════════════════════════════
  // ████████  BRACKET TAB — FIFA Single Elimination  ████████
  // ════════════════════════════════════════════════════════════════════════════
  // FIFA BRACKET TAB — Single Elimination
  // Reads knockout rows from _soccerScheduleRows (bracket_type != 'group')
  // Rounds: R32 → R16 → QF → SF → 3rd Place → Final
  // ════════════════════════════════════════════════════════════════════════════
  Widget _buildBracketTab() {
    // Get knockout rows from already-loaded schedule data
    final koRows = _soccerScheduleRows
        .where((r) => (r['bracketType'] as String? ?? 'group') != 'group')
        .toList();

    // Group standings for seeding preview
    final advancing = _getAdvancingTeams();

    return Column(children: [
      // ── Phase indicator ─────────────────────────────────────────────────
      Container(
        color: const Color(0xFF0A0620),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: _buildFifaPhaseIndicator(),
      ),

      // ── Status bar ──────────────────────────────────────────────────────
      Container(
        color: const Color(0xFF0D0826),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          Icon(Icons.emoji_events,
              color: const Color(0xFFFFD700).withOpacity(0.7), size: 14),
          const SizedBox(width: 8),
          Text(
            koRows.isEmpty
                ? 'Knockout bracket will appear after schedule is generated.'
                : advancing.isEmpty
                    ? 'Groups in progress — bracket preview below.'
                    : 'Bracket live — top 2 per group advance.',
            style: TextStyle(
                color: koRows.isEmpty
                    ? Colors.white24
                    : Colors.white.withOpacity(0.6),
                fontSize: 12),
          ),
          const Spacer(),
          if (koRows.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF00FF88).withOpacity(0.08),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: const Color(0xFF00FF88).withOpacity(0.3)),
              ),
              child: Text('${koRows.length} MATCHES',
                  style: const TextStyle(
                      color: Color(0xFF00FF88),
                      fontSize: 10,
                      fontWeight: FontWeight.bold)),
            ),
        ]),
      ),

      // ── Bracket content ─────────────────────────────────────────────────
      Expanded(
        child: koRows.isEmpty
            ? _bracketEmptyState()
            : _buildFifaBracketCanvas(koRows, advancing),
      ),
    ]);
  }

  // ── FIFA phase indicator ─────────────────────────────────────────────────
  Widget _buildFifaPhaseIndicator() {
    final koRows = _soccerScheduleRows
        .where((r) => (r['bracketType'] as String? ?? 'group') != 'group')
        .toList();

    final Map<String, int> roundCounts = {};
    for (final r in koRows) {
      final bt = r['bracketType'] as String? ?? '';
      roundCounts[bt] = (roundCounts[bt] ?? 0) + 1;
    }

    const roundOrder = [
      'round-of-32', 'round-of-16', 'quarter-finals',
      'semi-finals', 'third-place', 'final'
    ];
    const roundShort = {
      'round-of-32':    'R32',
      'round-of-16':    'R16',
      'quarter-finals': 'QF',
      'semi-finals':    'SF',
      'third-place':    '3RD',
      'final':          'FINAL',
    };

    // Which rounds exist in our data
    final existingRounds = roundOrder
        .where((r) => roundCounts.containsKey(r))
        .toList();

    // Always show at least GROUP STAGE + the existing rounds
    final phases = <Map<String, dynamic>>[
      {
        'label': 'GROUP\nSTAGE',
        'done': _allGroupMatchesDone() && _groupsGenerated,
        'active': !(_allGroupMatchesDone() && _groupsGenerated),
      },
      ...existingRounds.map((r) => {
        'label': roundShort[r] ?? r.toUpperCase(),
        'done': false,
        'active': false,
      }),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0A2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF3D1E88).withOpacity(0.4)),
      ),
      child: Row(children: phases.asMap().entries.expand((e) {
        final idx    = e.key;
        final phase  = e.value;
        final done   = phase['done'] as bool;
        final active = phase['active'] as bool;
        final label  = phase['label'] as String;

        return [
          Expanded(child: Column(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done
                    ? Colors.green.withOpacity(0.15)
                    : active
                        ? const Color(0xFF00CFFF).withOpacity(0.15)
                        : Colors.white.withOpacity(0.04),
                border: Border.all(
                    color: done
                        ? Colors.green
                        : active
                            ? const Color(0xFF00CFFF)
                            : Colors.white12,
                    width: 1.5),
              ),
              child: Center(child: done
                  ? const Icon(Icons.check, color: Colors.green, size: 16)
                  : active
                      ? Container(width: 8, height: 8,
                          decoration: const BoxDecoration(
                              color: Color(0xFF00CFFF),
                              shape: BoxShape.circle))
                      : Text('${idx + 1}',
                          style: const TextStyle(
                              color: Colors.white24, fontSize: 11))),
            ),
            const SizedBox(height: 4),
            Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: done
                        ? Colors.green
                        : active
                            ? const Color(0xFF00CFFF)
                            : Colors.white24,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    height: 1.2)),
          ])),
          if (idx < phases.length - 1)
            Container(
                width: 24, height: 1.5,
                margin: const EdgeInsets.only(bottom: 20),
                color: done
                    ? Colors.green.withOpacity(0.4)
                    : Colors.white12),
        ];
      }).toList()),
    );
  }

  // ── FIFA Bracket Canvas ───────────────────────────────────────────────────
  Widget _buildFifaBracketCanvas(
      List<Map<String, dynamic>> koRows,
      List<GroupTeam> advancing) {

    const roundOrder = [
      'round-of-32', 'round-of-16', 'quarter-finals',
      'semi-finals', 'third-place', 'final',
    ];
    const roundLabels = {
      'round-of-32':    'ROUND OF 32',
      'round-of-16':    'ROUND OF 16',
      'quarter-finals': 'QUARTER FINALS',
      'semi-finals':    'SEMI FINALS',
      'third-place':    '3RD PLACE',
      'final':          'FINAL',
    };
    const roundColors = {
      'round-of-32':    Color(0xFF7B6AFF),
      'round-of-16':    Color(0xFF00CFFF),
      'quarter-finals': Color(0xFF00FF88),
      'semi-finals':    Color(0xFFFF9F43),
      'third-place':    Color(0xFFCD7F32),
      'final':          Color(0xFFFFD700),
    };

    // Group by bracket_type
    final Map<String, List<Map<String, dynamic>>> byRound = {};
    for (final row in koRows) {
      final bt = row['bracketType'] as String? ?? 'quarter-finals';
      byRound.putIfAbsent(bt, () => []);
      byRound[bt]!.add(row);
    }

    final rounds = roundOrder.where((r) => byRound.containsKey(r)).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rounds.asMap().entries.map((re) {
          final ri         = re.key;
          final roundKey   = re.value;
          final matches    = byRound[roundKey]!;
          final label      = roundLabels[roundKey] ?? roundKey.toUpperCase();
          final color      = roundColors[roundKey] ?? const Color(0xFF00CFFF);
          final isFinal    = roundKey == 'final';
          final is3rd      = roundKey == 'third-place';

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Round header ────────────────────────────────────────────
              if (ri > 0) const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    color.withOpacity(0.2),
                    color.withOpacity(0.05),
                  ]),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: color.withOpacity(0.5)),
                ),
                child: Row(children: [
                  Icon(
                    isFinal
                        ? Icons.emoji_events
                        : is3rd
                            ? Icons.military_tech
                            : Icons.sports_soccer,
                    color: color, size: 18),
                  const SizedBox(width: 10),
                  Text(label,
                      style: TextStyle(
                          color: color,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.5)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                        '${matches.length} match${matches.length != 1 ? "es" : ""}',
                        style: TextStyle(
                            color: color.withOpacity(0.9),
                            fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  ),
                ]),
              ),
              const SizedBox(height: 10),

              // ── Match cards ─────────────────────────────────────────────
              ...matches.asMap().entries.map((me) {
                final mi    = me.key;
                final row   = me.value;
                final time  = row['time']  as String? ?? '';
                final team1 = row['team1'] as String? ?? '';
                final team2 = row['team2'] as String? ?? '';
                final arena = (row['arena'] as int?) ?? 0;
                final isEven = mi % 2 == 0;

                final hasTeams = team1.isNotEmpty && team2.isNotEmpty;

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: isFinal
                        ? const Color(0xFF1A1200)
                        : isEven
                            ? const Color(0xFF0F0A2A)
                            : const Color(0xFF120C35),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: color.withOpacity(isFinal ? 0.5 : 0.25),
                        width: isFinal ? 2 : 1.5),
                    boxShadow: isFinal
                        ? [BoxShadow(
                            color: color.withOpacity(0.15),
                            blurRadius: 20, spreadRadius: 2)]
                        : [],
                  ),
                  child: Column(children: [
                    // Match header: number + time + arena
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.07),
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(10)),
                      ),
                      child: Row(children: [
                        Container(
                          width: 22, height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color.withOpacity(0.15),
                            border: Border.all(
                                color: color.withOpacity(0.4)),
                          ),
                          child: Center(child: Text('${mi + 1}',
                              style: TextStyle(
                                  color: color,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold))),
                        ),
                        const SizedBox(width: 10),
                        if (time.isNotEmpty) ...[
                          Icon(Icons.access_time,
                              color: Colors.white38, size: 12),
                          const SizedBox(width: 4),
                          Text(time,
                              style: const TextStyle(
                                  color: Color(0xFF00CFFF),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(width: 12),
                        ],
                        if (arena > 0) ...[
                          Icon(Icons.place_rounded,
                              color: const Color(0xFFFFD700).withOpacity(0.6),
                              size: 12),
                          const SizedBox(width: 3),
                          Text('Arena $arena',
                              style: TextStyle(
                                  color: const Color(0xFFFFD700)
                                      .withOpacity(0.8),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold)),
                        ],
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: hasTeams
                                ? Colors.green.withOpacity(0.1)
                                : Colors.white.withOpacity(0.04),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: hasTeams
                                    ? Colors.green.withOpacity(0.3)
                                    : Colors.white12),
                          ),
                          child: Text(
                            hasTeams ? 'READY' : 'TBD',
                            style: TextStyle(
                                color: hasTeams
                                    ? Colors.green
                                    : Colors.white24,
                                fontSize: 9,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ]),
                    ),

                    // Teams row
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      child: Row(children: [
                        // Team 1
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              team1.isEmpty ? 'TBD' : team1,
                              textAlign: TextAlign.right,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: team1.isEmpty
                                    ? Colors.white24
                                    : Colors.white,
                                fontSize: isFinal ? 16 : 14,
                                fontWeight: FontWeight.w700),
                            ),
                          ],
                        )),

                        // VS badge
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 16),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: color.withOpacity(0.4), width: 1.5),
                          ),
                          child: Text('VS',
                              style: TextStyle(
                                  color: color,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1)),
                        ),

                        // Team 2
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              team2.isEmpty ? 'TBD' : team2,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: team2.isEmpty
                                    ? Colors.white24
                                    : Colors.white,
                                fontSize: isFinal ? 16 : 14,
                                fontWeight: FontWeight.w700),
                            ),
                          ],
                        )),
                      ]),
                    ),

                    // Final trophy footer
                    if (isFinal)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFD700).withOpacity(0.08),
                          borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(10)),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.emoji_events,
                                color: Color(0xFFFFD700), size: 16),
                            SizedBox(width: 8),
                            Text('CHAMPION',
                                style: TextStyle(
                                    color: Color(0xFFFFD700),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 2)),
                            SizedBox(width: 8),
                            Icon(Icons.emoji_events,
                                color: Color(0xFFFFD700), size: 16),
                          ],
                        ),
                      ),
                  ]),
                );
              }),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _legendDot(Color color, String label) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 9, height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: color.withOpacity(0.5), blurRadius: 5)])),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color.withOpacity(0.8),
            fontSize: 11, fontWeight: FontWeight.bold)),
      ]);

  Widget _destChip(IconData icon, Color color, String label) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color.withOpacity(0.7), size: 9),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(color: color.withOpacity(0.65),
            fontSize: 9, fontWeight: FontWeight.bold)),
      ]);

  Widget _previewChip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withOpacity(0.08),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withOpacity(0.3)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.visibility, color: color, size: 12),
      const SizedBox(width: 5),
      Text(text, style: TextStyle(color: color, fontSize: 10,
          fontWeight: FontWeight.bold, letterSpacing: 0.8)),
    ]),
  );

  /// Shows advancing teams with seed numbers
  // ── Banner shown above the bracket canvas ─────────────────────────────
  // Phase A (groups in progress):   preview expected Top1 vs Top2 matchups
  // Phase B (play-in seeded, live):  show real matchups + tap-to-set result
  // Phase C (bracket seeded):        show bracket seed list
  Widget _buildSeedBanner(List<BracketTeam> seeds) {
    // Phase C — bracket is live, show seeds
    if (_bracketSeeded) {
      return Container(
        color: const Color(0xFF0A0520),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.account_tree, color: Color(0xFF00FF88), size: 13),
            SizedBox(width: 6),
            Text('BRACKET SEEDS  ·  Double Elimination  ·  All rounds BO1  ·  Grand Final BO3',
                style: TextStyle(color: Color(0xFF00FF88), fontSize: 10,
                    fontWeight: FontWeight.bold, letterSpacing: 0.8)),
          ]),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6, runSpacing: 4,
            children: seeds.asMap().entries.map((e) {
              final seed  = e.key + 1;
              final team  = e.value;
              final color = _seedColor(seed);
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: color.withOpacity(0.35)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 16, height: 16,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.2), shape: BoxShape.circle,
                      border: Border.all(color: color, width: 1)),
                    child: Center(child: Text('$seed',
                        style: TextStyle(color: color, fontSize: 8,
                            fontWeight: FontWeight.bold))),
                  ),
                  const SizedBox(width: 5),
                  Text(team.teamName,
                      style: const TextStyle(color: Colors.white70,
                          fontSize: 11, fontWeight: FontWeight.w500)),
                ]),
              );
            }).toList(),
          ),
        ]),
      );
    }

    // Phase B — play-in seeded: compact single-line rows, tappable to set result
    if (_playInSeeded && _playInMatches.isNotEmpty) {
      final doneMatches = _playInMatches.where((m) => m.winner != null).length;
      return Container(
        color: const Color(0xFF0A0520),
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.sports_soccer, color: Color(0xFF00CFFF), size: 12),
            const SizedBox(width: 5),
            const Text('PLAY-IN  ·  BO1  ·  Tap a match to set result',
                style: TextStyle(color: Color(0xFF00CFFF), fontSize: 9,
                    fontWeight: FontWeight.bold, letterSpacing: 0.6)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: doneMatches == _playInMatches.length
                    ? Colors.green.withOpacity(0.12) : Colors.white.withOpacity(0.03),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: doneMatches == _playInMatches.length
                      ? Colors.green.withOpacity(0.4) : Colors.white12),
              ),
              child: Text('$doneMatches / ${_playInMatches.length} done',
                  style: TextStyle(
                    color: doneMatches == _playInMatches.length
                        ? Colors.green : Colors.white38,
                    fontSize: 8, fontWeight: FontWeight.bold)),
            ),
          ]),
          const SizedBox(height: 6),
          ..._playInMatches.asMap().entries.map((e) {
            final gi    = e.key;
            final match = e.value;
            final done  = match.winner != null;
            final gc    = gi < _groups.length
                ? _groupColor(_groups[gi].label) : Colors.white38;
            final gLabel = gi < _groups.length ? _groups[gi].label : '?';
            final w1 = done && match.winner?.teamId == match.team1.teamId;
            final w2 = done && match.winner?.teamId == match.team2.teamId;
            return GestureDetector(
              onTap: done ? null : () => _showBracketMatchDialog(
                  match, onResult: (w) => _setPlayInResult(match, w)),
              child: Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: done ? const Color(0xFF0A1A0A) : const Color(0xFF0E0828),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: done ? Colors.green.withOpacity(0.4) : gc.withOpacity(0.5),
                    width: 1),
                ),
                child: Row(children: [
                  // Group badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: gc.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: gc.withOpacity(0.45))),
                    child: Text('G$gLabel',
                        style: TextStyle(color: gc, fontSize: 8,
                            fontWeight: FontWeight.w900)),
                  ),
                  const SizedBox(width: 6),
                  // BO1 chip
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00CFFF).withOpacity(0.07),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: const Color(0xFF00CFFF).withOpacity(0.25))),
                    child: const Text('BO1',
                        style: TextStyle(color: Color(0xFF00CFFF),
                            fontSize: 7, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 8),
                  // Team 1
                  if (w1) const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 11),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(match.team1.teamName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: w1 ? const Color(0xFF00FF88)
                              : w2 ? Colors.white38 : Colors.white,
                          fontSize: 12,
                          fontWeight: w1 ? FontWeight.bold : FontWeight.w500)),
                  ),
                  // VS
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('VS',
                        style: TextStyle(color: Colors.white.withOpacity(0.18),
                            fontSize: 9, fontWeight: FontWeight.w900)),
                  ),
                  // Team 2
                  Expanded(
                    child: Text(match.team2.teamName,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: w2 ? const Color(0xFF00FF88)
                              : w1 ? Colors.white38 : Colors.white,
                          fontSize: 12,
                          fontWeight: w2 ? FontWeight.bold : FontWeight.w500)),
                  ),
                  const SizedBox(width: 2),
                  if (w2) const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 11),
                  const SizedBox(width: 8),
                  // Status
                  if (done)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.green.withOpacity(0.35))),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.check, color: Colors.green, size: 9),
                        const SizedBox(width: 3),
                        Text(match.winner!.teamName,
                            style: const TextStyle(color: Colors.green,
                                fontSize: 8, fontWeight: FontWeight.bold)),
                        const Text(' advances',
                            style: TextStyle(color: Colors.green, fontSize: 8)),
                      ]),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00CFFF).withOpacity(0.07),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xFF00CFFF).withOpacity(0.3))),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.touch_app, color: Color(0xFF00CFFF), size: 9),
                        SizedBox(width: 3),
                        Text('TAP TO SET',
                            style: TextStyle(color: Color(0xFF00CFFF),
                                fontSize: 8, fontWeight: FontWeight.bold)),
                      ]),
                    ),
                ]),
              ),
            );
          }).toList(),
        ]),
      );
    }

    // Phase A — groups in progress
    // Show CROSS-GROUP expected matchups: A1vsB2, A2vsB1, C1vsD2, C2vsD1 …
    // Groups that finished show as DONE. Pending groups show expected matchup.
    final crossPairs = <_PlayInPreviewPair>[];
    for (int gi = 0; gi + 1 < _groups.length; gi += 2) {
      final gA     = _groups[gi];
      final gB     = _groups[gi + 1];
      final sA     = _getGroupStandings(gA);
      final sB     = _getGroupStandings(gB);
      final doneA  = gA.matches.every((m) => m.isDone) && gA.matches.isNotEmpty;
      final doneB  = gB.matches.every((m) => m.isDone) && gB.matches.isNotEmpty;
      final bothDone = doneA && doneB;
      if (sA.length >= 2 && sB.length >= 2) {
        // Match 1: A#1 vs B#2
        crossPairs.add(_PlayInPreviewPair(
          label: '${gA.label}1  vs  ${gB.label}2',
          t1: sA[0].teamName, t1group: gA.label, t1rank: 1,
          t2: sB[1].teamName, t2group: gB.label, t2rank: 2,
          done: bothDone,
          gcA: _groupColor(gA.label), gcB: _groupColor(gB.label),
        ));
        // Match 2: A#2 vs B#1
        crossPairs.add(_PlayInPreviewPair(
          label: '${gA.label}2  vs  ${gB.label}1',
          t1: sA[1].teamName, t1group: gA.label, t1rank: 2,
          t2: sB[0].teamName, t2group: gB.label, t2rank: 1,
          done: bothDone,
          gcA: _groupColor(gA.label), gcB: _groupColor(gB.label),
        ));
      }
    }
    // Odd group leftover
    if (_groups.length % 2 == 1) {
      final gL   = _groups.last;
      final sL   = _getGroupStandings(gL);
      final doneL = gL.matches.every((m) => m.isDone) && gL.matches.isNotEmpty;
      if (sL.length >= 2) {
        crossPairs.add(_PlayInPreviewPair(
          label: '${gL.label}1  vs  ${gL.label}2',
          t1: sL[0].teamName, t1group: gL.label, t1rank: 1,
          t2: sL[1].teamName, t2group: gL.label, t2rank: 2,
          done: doneL,
          gcA: _groupColor(gL.label), gcB: _groupColor(gL.label),
        ));
      }
    }

    final doneCount = crossPairs.where((p) => p.done).length;
    final totalCount = crossPairs.length;

    // ── Phase A: compact single-line chip per matchup ─────────────────────
    return Container(
      color: const Color(0xFF0A0520),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Title row
        Row(children: [
          const Icon(Icons.visibility, color: Color(0xFFFFD700), size: 12),
          const SizedBox(width: 5),
          const Text('PLAY-IN PREVIEW  ·  auto-updates as groups finish',
              style: TextStyle(color: Color(0xFFFFD700), fontSize: 9,
                  fontWeight: FontWeight.bold, letterSpacing: 0.6)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: doneCount == totalCount && totalCount > 0
                  ? Colors.green.withOpacity(0.12) : Colors.white.withOpacity(0.03),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: doneCount == totalCount && totalCount > 0
                    ? Colors.green.withOpacity(0.4) : Colors.white12),
            ),
            child: Text('$doneCount / $totalCount ready',
                style: TextStyle(
                    color: doneCount == totalCount && totalCount > 0
                        ? Colors.green : Colors.white38,
                    fontSize: 8, fontWeight: FontWeight.bold)),
          ),
        ]),
        const SizedBox(height: 6),
        // ── One compact row per matchup ──────────────────────────────────
        ...crossPairs.map((pair) {
          final borderCol = pair.done
              ? Colors.green.withOpacity(0.4)
              : const Color(0xFF2A1A50);
          final bgCol = pair.done
              ? const Color(0xFF0A1A0A) : const Color(0xFF0E0828);
          return Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: bgCol,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: borderCol, width: 1),
            ),
            child: Row(children: [
              // Status dot
              Container(
                width: 7, height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: pair.done ? Colors.green : const Color(0xFFFFD700),
                  boxShadow: [BoxShadow(
                    color: (pair.done ? Colors.green : const Color(0xFFFFD700))
                        .withOpacity(0.5), blurRadius: 4)],
                ),
              ),
              const SizedBox(width: 7),
              // Team 1 badge + name
              _inlineGroupBadge(pair.t1group, pair.t1rank, pair.gcA),
              const SizedBox(width: 5),
              Expanded(
                child: Text(pair.t1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: pair.done ? Colors.white70 : Colors.white,
                        fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              // VS divider
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('VS',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.2),
                        fontSize: 9, fontWeight: FontWeight.w900,
                        letterSpacing: 1)),
              ),
              // Team 2 badge + name
              Expanded(
                child: Text(pair.t2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        color: pair.done ? Colors.white70 : Colors.white,
                        fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 5),
              _inlineGroupBadge(pair.t2group, pair.t2rank, pair.gcB),
              // Ready / Preview chip
              const SizedBox(width: 8),
              if (pair.done)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.green.withOpacity(0.4)),
                  ),
                  child: const Text('READY',
                      style: TextStyle(color: Colors.green,
                          fontSize: 8, fontWeight: FontWeight.bold)),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFD700).withOpacity(0.06),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.25)),
                  ),
                  child: const Text('PREVIEW',
                      style: TextStyle(color: Color(0xFFFFD700),
                          fontSize: 8, fontWeight: FontWeight.bold)),
                ),
            ]),
          );
        }).toList(),
      ]),
    );
  }

  Widget _inlineGroupBadge(String groupLabel, int rank, Color gc) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: gc.withOpacity(0.15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: gc.withOpacity(0.45), width: 1),
        ),
        child: Text('G$groupLabel #$rank',
            style: TextStyle(color: gc, fontSize: 8, fontWeight: FontWeight.w900)),
      );

  Widget _playInTeamRow(String name, String groupLabel, int rank,
      Color gc, bool isWinner, String? winnerLabel) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: gc.withOpacity(0.15),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: gc.withOpacity(0.4)),
        ),
        child: Text('G$groupLabel #$rank',
            style: TextStyle(color: gc, fontSize: 7, fontWeight: FontWeight.bold)),
      ),
      const SizedBox(width: 6),
      Text(name,
          style: TextStyle(
              color: isWinner ? const Color(0xFF00FF88) : Colors.white,
              fontSize: 11,
              fontWeight: isWinner ? FontWeight.bold : FontWeight.w600)),
      if (isWinner) ...[
        const SizedBox(width: 4),
        const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 10),
      ],
    ]);
  }

  Widget _playInLiveTeamRow(String name, bool isWinner, bool isLoser) {
    return Row(children: [
      // colored left bar: green = winner, red = loser, white = pending
      Container(
        width: 3, height: 22,
        margin: const EdgeInsets.only(right: 6),
        decoration: BoxDecoration(
          color: isWinner ? Colors.green
              : isLoser ? Colors.red.withOpacity(0.4) : Colors.white12,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      Expanded(child: Text(name,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isWinner ? const Color(0xFF00FF88)
                : isLoser ? Colors.white38 : Colors.white,
            fontSize: 12,
            fontWeight: isWinner ? FontWeight.bold : FontWeight.w500,
            decoration: isLoser ? TextDecoration.lineThrough : null,
            decorationColor: Colors.white24,
          ))),
      if (isWinner)
        const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 11),
    ]);
  }

  Color _seedColor(int seed) {
    switch (seed) {
      case 1:  return const Color(0xFFFFD700);
      case 2:  return const Color(0xFFC0C0C0);
      case 3:  return const Color(0xFFCD7F32);
      case 4:  return const Color(0xFF00CFFF);
      default: return const Color(0xFF7B6AFF);
    }
  }

  Widget _bracketEmptyState() => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF130742),
          border: Border.all(color: const Color(0xFF00CFFF).withOpacity(0.25), width: 2),
        ),
        child: const Icon(Icons.account_tree, color: Color(0xFF00CFFF), size: 48),
      ),
      const SizedBox(height: 20),
      const Text('Bracket Preview',
          style: TextStyle(color: Colors.white54, fontSize: 20,
              fontWeight: FontWeight.w900)),
      const SizedBox(height: 8),
      const Text(
        'Generate groups to see the expected bracket.\nAdvancing teams will populate the bracket automatically.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white24, fontSize: 13, height: 1.6),
      ),
    ]),
  );

  void _showGrandFinalScoreDialog() {
    if (_grandFinal == null) return;
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.75),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 320,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF14093A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.4), width: 1.5),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('🏆 GRAND FINAL  ·  BEST OF 3',
                style: TextStyle(color: Color(0xFFFFD700), fontSize: 15,
                    fontWeight: FontWeight.w900, letterSpacing: 1)),
            const SizedBox(height: 16),
            const Text('First to 2 wins',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8,
                children: [[2, 0], [2, 1], [0, 2], [1, 2]].map((combo) =>
                    GestureDetector(
                      onTap: () {
                        _setGrandFinalScore(combo[0], combo[1]);
                        Navigator.pop(ctx);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A0F38),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.3)),
                        ),
                        child: Text('${combo[0]} – ${combo[1]}',
                            style: const TextStyle(color: Color(0xFFFFD700),
                                fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    )).toList()),
          ]),
        ),
      ),
    );
  }

  void _showBracketMatchDialog(BracketMatch match,
      {required void Function(BracketTeam) onResult}) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.75),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 380,
          decoration: BoxDecoration(
            color: const Color(0xFF14093A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF3D1E88), width: 1.5),
            boxShadow: [BoxShadow(color: const Color(0xFF6B2FD9).withOpacity(0.35),
                blurRadius: 40, spreadRadius: 2)],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 14, 14),
              decoration: const BoxDecoration(color: Color(0xFF0F0628),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
              child: Row(children: [
                const Icon(Icons.sports_soccer, color: Color(0xFF9B6FE8), size: 18),
                const SizedBox(width: 10),
                const Text('SELECT WINNER',
                    style: TextStyle(color: Colors.white, fontSize: 16,
                        fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                const Spacer(),
                GestureDetector(onTap: () => Navigator.pop(ctx),
                    child: Icon(Icons.close, color: Colors.white.withOpacity(0.4), size: 18)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                _winnerButton(ctx, match.team1, onResult),
                const Padding(padding: EdgeInsets.symmetric(vertical: 10),
                    child: Text('VS', style: TextStyle(color: Colors.white24,
                        fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 3))),
                _winnerButton(ctx, match.team2, onResult),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _winnerButton(BuildContext ctx, BracketTeam team,
      void Function(BracketTeam) onResult) {
    return GestureDetector(
      onTap: () { onResult(team); Navigator.pop(ctx); },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF1C0F4A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF2E1A5E), width: 1),
        ),
        child: Row(children: [
          Container(width: 36, height: 36,
            decoration: BoxDecoration(shape: BoxShape.circle,
              gradient: const LinearGradient(
                  colors: [Color(0xFF2E1A62), Color(0xFF1C0F42)]),
              border: Border.all(color: const Color(0xFF3E2878), width: 1.5)),
            child: Center(child: Text(
              team.teamName.isNotEmpty ? team.teamName[0].toUpperCase() : '?',
              style: const TextStyle(color: Colors.white54,
                  fontWeight: FontWeight.bold, fontSize: 16),
            )),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(team.teamName,
              style: const TextStyle(color: Colors.white70, fontSize: 15,
                  fontWeight: FontWeight.w500))),
          Icon(Icons.chevron_right, color: Colors.white.withOpacity(0.15), size: 20),
        ]),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // SOCCER SCHEDULE TAB
  // ════════════════════════════════════════════════════════════════════════════
  Widget _buildSoccerScheduleTab(int catId, List<Map<String, dynamic>> matches) {
    return Column(children: [
      if (!_groupsGenerated)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white12, width: 1),
          ),
          child: Row(children: [
            const Icon(Icons.visibility, color: Colors.white24, size: 16),
            const SizedBox(width: 10),
            Expanded(child: RichText(text: const TextSpan(
              style: TextStyle(color: Colors.white38, fontSize: 13),
              children: [
                TextSpan(text: 'View only. ',
                    style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold)),
                TextSpan(text: 'Go to the '),
                TextSpan(text: 'GROUPS', style: TextStyle(
                    color: Color(0xFF00CFFF), fontWeight: FontWeight.bold)),
                TextSpan(text: ' tab to generate groups.'),
              ],
            ))),
          ]),
        ),
      if (_groupsGenerated) ...[
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF00CFFF).withOpacity(0.07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF00CFFF).withOpacity(0.25), width: 1),
          ),
          child: const Row(children: [
            Icon(Icons.edit_note, color: Color(0xFF00CFFF), size: 18),
            SizedBox(width: 8),
            Expanded(child: Text(
              'Tap the ✏️ SCORE button on any match to enter results.',
              style: TextStyle(color: Color(0xFF00CFFF), fontSize: 12),
            )),
          ]),
        ),
        Expanded(child: _buildFifaScheduleList()),
      ] else ...[
        _soccerScheduleHeader(),
        Expanded(
          child: matches.isEmpty
              ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.calendar_today, size: 48, color: Colors.white.withOpacity(0.06)),
                  const SizedBox(height: 14),
                  const Text('No schedule yet.',
                      style: TextStyle(color: Colors.white24, fontSize: 16)),
                ]))
              : AbsorbPointer(
                  absorbing: true,
                  child: Opacity(
                    opacity: 0.45,
                    child: ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (_, idx) => _soccerScheduleRow(catId, matches[idx], idx),
                    ),
                  ),
                ),
        ),
      ],
    ]);
  }

  Widget _buildFifaScheduleList() {
    final allRows    = _soccerScheduleRows;
    final groupRows  = allRows.where((r) =>
        (r['bracketType'] as String? ?? 'group') == 'group').toList();
    final koRows     = allRows.where((r) =>
        (r['bracketType'] as String? ?? 'group') != 'group').toList();

    if (allRows.isEmpty) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.calendar_today, size: 48, color: Colors.white.withOpacity(0.06)),
        const SizedBox(height: 14),
        const Text('No schedule yet. Tap Generate Schedule to create one.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white24, fontSize: 15)),
      ]));
    }

    // Detect arenas from group rows only
    final arenaSet   = groupRows.map((r) => (r['arena'] as int?) ?? 1).toSet();
    final arenaCount = arenaSet.isEmpty ? 1 : arenaSet.reduce((a, b) => a > b ? a : b);

    // If only 1 arena — use simple single-column layout
    if (arenaCount <= 1) {
      return _buildFifaFullView(groupRows, koRows, useSingleColumn: true);
    }

    // Multi-arena: delegate to full FIFA view
    return _buildFifaFullView(groupRows, koRows, useSingleColumn: false);
  }

  // ── Single arena fallback (original list layout) ─────────────────────────
  // ── FIFA Full View: Group Stage (parallel arenas) + Knockout Bracket ───────
  Widget _buildFifaFullView(
    List<Map<String, dynamic>> groupRows,
    List<Map<String, dynamic>> koRows, {
    required bool useSingleColumn,
  }) {
    // Detect arenas
    final arenaSet   = groupRows.map((r) => (r['arena'] as int?) ?? 1).toSet();
    final arenaCount = arenaSet.isEmpty ? 1 : arenaSet.reduce((a, b) => a > b ? a : b);

    return DefaultTabController(
      length: koRows.isEmpty ? 1 : 2,
      child: Column(children: [
        // Tab bar: Group Stage | Knockout
        if (koRows.isNotEmpty)
          Container(
            color: const Color(0xFF0F0A2A),
            child: TabBar(
              indicatorColor: const Color(0xFF00FF88),
              indicatorWeight: 3,
              labelColor: const Color(0xFF00FF88),
              unselectedLabelColor: Colors.white38,
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              tabs: const [
                Tab(text: '⚽  GROUP STAGE'),
                Tab(text: '🏆  KNOCKOUT'),
              ],
            ),
          ),
        Expanded(child: TabBarView(
          children: [
            // ── GROUP STAGE TAB ───────────────────────────────────────────
            _buildGroupScheduleView(groupRows, arenaCount, useSingleColumn),
            // ── KNOCKOUT TAB ──────────────────────────────────────────────
            if (koRows.isNotEmpty)
              _buildKnockoutView(koRows),
          ],
        )),
      ]),
    );
  }

  // ── Group schedule: side-by-side arenas ────────────────────────────────────
  Widget _buildGroupScheduleView(
      List<Map<String, dynamic>> rows, int arenaCount, bool singleColumn) {

    if (rows.isEmpty) {
      return Center(child: Text('No group matches yet.',
          style: TextStyle(color: Colors.white.withOpacity(0.3))));
    }

    if (singleColumn || arenaCount <= 1) {
      return _buildSingleArenaList(rows);
    }

    // Side-by-side arena view
    final arenas = List.generate(arenaCount, (i) => i + 1);

    // Group rows by time slot
    final Map<String, Map<int, Map<String, dynamic>>> byTime = {};
    for (final row in rows) {
      final time  = (row['time'] as String).isNotEmpty ? row['time'] as String : '__notime__';
      final arena = (row['arena'] as int?) ?? 1;
      byTime.putIfAbsent(time, () => {});
      byTime[time]![arena] = row;
    }
    final slots = byTime.keys.toList()
      ..sort((a, b) {
        if (a == '__notime__') return 1;
        if (b == '__notime__') return -1;
        return a.compareTo(b);
      });

    return Column(children: [
      // Arena header
      Container(
        decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF4A22AA), Color(0xFF3A1880)])),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(children: [
          const SizedBox(width: 28),
          const SizedBox(width: 54, child: Text('TIME',
              style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold,
                  fontSize: 12, letterSpacing: 0.8))),
          ...arenas.map((a) => Expanded(child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFFFFD700).withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.4)),
            ),
            child: Center(child: Text('ARENA $a',
                style: const TextStyle(color: Color(0xFFFFD700),
                    fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1))),
          ))),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: slots.length,
          itemBuilder: (_, idx) {
            final timeKey     = slots[idx];
            final displayTime = timeKey == '__notime__' ? '—' : timeKey;
            final slotMatches = byTime[timeKey]!;
            final isEven      = idx % 2 == 0;

            return Container(
              decoration: BoxDecoration(
                color: isEven ? const Color(0xFF160C40) : const Color(0xFF100830),
                border: const Border(bottom: BorderSide(color: Color(0xFF1A1050), width: 1)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              child: IntrinsicHeight(child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(width: 28, child: Center(child: Text('${idx + 1}',
                      style: TextStyle(color: Colors.white.withOpacity(0.3),
                          fontSize: 13, fontWeight: FontWeight.bold)))),
                  SizedBox(width: 54, child: Text(displayTime,
                      style: TextStyle(
                          color: displayTime == '—'
                              ? Colors.white.withOpacity(0.2)
                              : const Color(0xFF00CFFF),
                          fontSize: 13, fontWeight: FontWeight.w600))),
                  ...arenas.map((a) {
                    final row = slotMatches[a];
                    if (row == null) {
                      return Expanded(child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.02),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white.withOpacity(0.06)),
                        ),
                        child: Center(child: Text('—', style: TextStyle(
                            color: Colors.white.withOpacity(0.15), fontSize: 12))),
                      ));
                    }
                    final matchId    = row['matchId']    as int;
                    final groupLabel = row['groupLabel'] as String;
                    final team1      = row['team1']      as String;
                    final team2      = row['team2']      as String;
                    final gc         = _groupColor(groupLabel);
                    GroupMatch? gm;
                    for (final g in _groups) {
                      for (final m in g.matches) {
                        if (m.matchId == matchId) { gm = m; break; }
                      }
                      if (gm != null) break;
                    }
                    final isDone = gm?.isDone ?? false;
                    final t1Wins = isDone && gm?.winner == gm?.team1;
                    final t2Wins = isDone && gm?.winner == gm?.team2;

                    return Expanded(child: GestureDetector(
                      onTap: gm != null ? () => _showGroupMatchDialog(gm!) : null,
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        decoration: BoxDecoration(
                          color: isDone ? const Color(0xFF0A1A0E) : gc.withOpacity(0.07),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: isDone ? Colors.green.withOpacity(0.4) : gc.withOpacity(0.35),
                              width: 1.5),
                        ),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: gc.withOpacity(0.18),
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                            ),
                            child: Center(child: Text('G$groupLabel',
                                style: TextStyle(color: gc, fontSize: 11,
                                    fontWeight: FontWeight.w900))),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                            child: Row(children: [
                              Expanded(child: Text(team1.isNotEmpty ? team1 : '—',
                                  textAlign: TextAlign.right, maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: t1Wins ? const Color(0xFF00FF88) : Colors.white,
                                      fontSize: 12,
                                      fontWeight: t1Wins ? FontWeight.bold : FontWeight.w600))),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                child: isDone
                                    ? Text('${gm!.score1}–${gm.score2}',
                                        style: const TextStyle(color: Colors.white,
                                            fontSize: 11, fontWeight: FontWeight.bold))
                                    : Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF00CFFF).withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(4),
                                          border: Border.all(color: const Color(0xFF00CFFF).withOpacity(0.3)),
                                        ),
                                        child: const Text('vs', style: TextStyle(
                                            color: Color(0xFF00CFFF), fontSize: 10,
                                            fontWeight: FontWeight.bold))),
                              ),
                              Expanded(child: Text(team2.isNotEmpty ? team2 : '—',
                                  maxLines: 2, overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: t2Wins ? const Color(0xFF00FF88) : Colors.white,
                                      fontSize: 12,
                                      fontWeight: t2Wins ? FontWeight.bold : FontWeight.w600))),
                            ]),
                          ),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            decoration: BoxDecoration(
                              color: isDone ? Colors.green.withOpacity(0.12) : Colors.white.withOpacity(0.03),
                              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
                            ),
                            child: Center(child: isDone
                                ? const Row(mainAxisSize: MainAxisSize.min, children: [
                                    Icon(Icons.check_circle, color: Colors.green, size: 10),
                                    SizedBox(width: 4),
                                    Text('Done', style: TextStyle(color: Colors.green,
                                        fontSize: 9, fontWeight: FontWeight.bold)),
                                  ])
                                : Text('Pending', style: TextStyle(
                                    color: Colors.white.withOpacity(0.2),
                                    fontSize: 9, fontWeight: FontWeight.bold))),
                          ),
                        ]),
                      ),
                    ));
                  }),
                ],
              )),
            );
          },
        ),
      ),
    ]);
  }

  // ── FIFA Knockout Bracket View ───────────────────────────────────────────────
  Widget _buildKnockoutView(List<Map<String, dynamic>> koRows) {
    // Group by bracket_type
    const roundOrder = [
      'round-of-32', 'round-of-16', 'quarter-finals',
      'semi-finals', 'third-place', 'final'
    ];
    const roundLabels = {
      'round-of-32':   'ROUND OF 32',
      'round-of-16':   'ROUND OF 16',
      'quarter-finals':'QUARTER FINALS',
      'semi-finals':   'SEMI FINALS',
      'third-place':   '3RD PLACE',
      'final':         'FINAL',
    };

    final Map<String, List<Map<String, dynamic>>> byRound = {};
    for (final row in koRows) {
      final bt = row['bracketType'] as String? ?? 'quarter-finals';
      byRound.putIfAbsent(bt, () => []);
      byRound[bt]!.add(row);
    }

    final rounds = roundOrder.where((r) => byRound.containsKey(r)).toList();

    if (rounds.isEmpty) {
      return Center(child: Text('Knockout matches will appear here after group stage.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 14)));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: rounds.length,
      itemBuilder: (_, ri) {
        final roundKey    = rounds[ri];
        final roundLabel  = roundLabels[roundKey] ?? roundKey.toUpperCase();
        final matches     = byRound[roundKey]!;
        final isFinal     = roundKey == 'final';
        final is3rd       = roundKey == 'third-place';
        final accentColor = isFinal
            ? const Color(0xFFFFD700)
            : is3rd
            ? const Color(0xFFCD7F32)
            : const Color(0xFF00CFFF);

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Round header
          Container(
            margin: EdgeInsets.only(bottom: 10, top: ri == 0 ? 0 : 20),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: accentColor.withOpacity(0.4)),
            ),
            child: Row(children: [
              Icon(isFinal ? Icons.emoji_events : Icons.sports_soccer,
                  color: accentColor, size: 16),
              const SizedBox(width: 10),
              Text(roundLabel, style: TextStyle(
                  color: accentColor, fontSize: 13,
                  fontWeight: FontWeight.w900, letterSpacing: 1.5)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('${matches.length} match${matches.length != 1 ? "es" : ""}',
                    style: TextStyle(color: accentColor.withOpacity(0.8),
                        fontSize: 10, fontWeight: FontWeight.bold)),
              ),
            ]),
          ),

          // Match cards
          ...matches.asMap().entries.map((e) {
            final idx   = e.key;
            final row   = e.value;
            final time  = row['time'] as String? ?? '';
            final team1 = row['team1'] as String? ?? 'TBD';
            final team2 = row['team2'] as String? ?? 'TBD';
            final arena = (row['arena'] as int?) ?? 0;

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isFinal
                    ? const Color(0xFF1A1200)
                    : const Color(0xFF0F0A2A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: accentColor.withOpacity(0.3), width: 1.5),
              ),
              child: Row(children: [
                // Match number
                Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accentColor.withOpacity(0.12),
                    border: Border.all(color: accentColor.withOpacity(0.4)),
                  ),
                  child: Center(child: Text('${idx + 1}',
                      style: TextStyle(color: accentColor, fontSize: 11,
                          fontWeight: FontWeight.bold))),
                ),
                const SizedBox(width: 12),
                // Time
                if (time.isNotEmpty) ...[
                  Text(time, style: const TextStyle(
                      color: Color(0xFF00CFFF), fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
                ],
                // Team 1
                Expanded(child: Text(
                  team1.isEmpty ? 'TBD' : team1,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      color: team1.isEmpty ? Colors.white24 : Colors.white,
                      fontSize: 14, fontWeight: FontWeight.w700),
                )),
                // VS
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: accentColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: accentColor.withOpacity(0.3)),
                    ),
                    child: Text('vs', style: TextStyle(
                        color: accentColor, fontSize: 11,
                        fontWeight: FontWeight.bold)),
                  ),
                ),
                // Team 2
                Expanded(child: Text(
                  team2.isEmpty ? 'TBD' : team2,
                  style: TextStyle(
                      color: team2.isEmpty ? Colors.white24 : Colors.white,
                      fontSize: 14, fontWeight: FontWeight.w700),
                )),
                // Arena badge
                if (arena > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFD700).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.3)),
                    ),
                    child: Text('A$arena', style: const TextStyle(
                        color: Color(0xFFFFD700), fontSize: 10,
                        fontWeight: FontWeight.bold)),
                  ),
                ],
              ]),
            );
          }),
        ]);
      },
    );
  }

  Widget _buildSingleArenaList(List<Map<String, dynamic>> rows) {
    return Column(children: [
      Container(
        decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF4A22AA), Color(0xFF3A1880)])),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
        child: Row(children: [
          _headerCell('#',      flex: 1),
          _headerCell('TIME',   flex: 2),
          _headerCell('GROUP',  flex: 2, center: true),
          _headerCell('HOME',   flex: 4, center: true),
          _headerCell('VS',     flex: 1, center: true),
          _headerCell('AWAY',   flex: 4, center: true),
          _headerCell('STATUS', flex: 2, center: true),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: rows.length,
          itemBuilder: (_, idx) {
            final row        = rows[idx];
            final matchId    = row['matchId']    as int;
            final groupLabel = row['groupLabel'] as String;
            final time       = row['time']       as String;
            final team1      = row['team1']      as String;
            final team2      = row['team2']      as String;
            final isEven     = idx % 2 == 0;
            final gc         = _groupColor(groupLabel);
            GroupMatch? gm;
            for (final g in _groups) {
              for (final m in g.matches) {
                if (m.matchId == matchId) { gm = m; break; }
              }
              if (gm != null) break;
            }
            final isDone = gm?.isDone ?? false;
            final t1Wins = isDone && gm?.winner == gm?.team1;
            final t2Wins = isDone && gm?.winner == gm?.team2;
            return GestureDetector(
              onTap: gm != null ? () => _showGroupMatchDialog(gm!) : null,
              child: Container(
                decoration: BoxDecoration(
                  color: isDone ? const Color(0xFF0D1A10)
                      : isEven ? const Color(0xFF160C40) : const Color(0xFF100830),
                  border: Border(
                    bottom: const BorderSide(color: Color(0xFF1A1050), width: 1),
                    left: BorderSide(
                        color: isDone ? Colors.green.withOpacity(0.5)
                            : gc.withOpacity(0.4),
                        width: 3),
                  ),
                ),
                child: IntrinsicHeight(child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  Expanded(flex: 1, child: Center(child: Text('${idx + 1}',
                      style: TextStyle(color: Colors.white.withOpacity(0.35),
                          fontWeight: FontWeight.bold, fontSize: 15)))),
                  Expanded(flex: 2, child: Center(child: time.isNotEmpty
                      ? Text(time, style: const TextStyle(
                          color: Color(0xFF00CFFF), fontSize: 13,
                          fontWeight: FontWeight.w600))
                      : Text('—', style: TextStyle(
                          color: Colors.white.withOpacity(0.2),
                          fontSize: 13)))),
                  Expanded(flex: 2, child: Center(child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: gc.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: gc.withOpacity(0.5), width: 1.5),
                    ),
                    child: Text('G$groupLabel',
                        style: TextStyle(color: gc, fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  ))),
                  Expanded(flex: 4, child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end, children: [
                      if (t1Wins) const Icon(Icons.emoji_events,
                          color: Color(0xFFFFD700), size: 12),
                      Text(team1.isNotEmpty ? team1 : '—',
                          textAlign: TextAlign.right, maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: t1Wins ? const Color(0xFF00FF88) : Colors.white,
                              fontSize: 14,
                              fontWeight: t1Wins ? FontWeight.bold : FontWeight.w600)),
                    ]),
                  )),
                  Expanded(flex: 1, child: Center(child: GestureDetector(
                    onTap: gm != null ? () => _showGroupMatchDialog(gm!) : null,
                    child: isDone
                        ? Text('${gm!.score1}–${gm.score2}',
                            style: const TextStyle(color: Colors.white,
                                fontSize: 12, fontWeight: FontWeight.bold))
                        : Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 5),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00CFFF).withOpacity(0.08),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color: const Color(0xFF00CFFF).withOpacity(0.35)),
                            ),
                            child: const Text('vs',
                                style: TextStyle(color: Color(0xFF00CFFF),
                                    fontSize: 11, fontWeight: FontWeight.bold))),
                  ))),
                  Expanded(flex: 4, child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (t2Wins) const Icon(Icons.emoji_events,
                          color: Color(0xFFFFD700), size: 12),
                      Text(team2.isNotEmpty ? team2 : '—',
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: t2Wins ? const Color(0xFF00FF88) : Colors.white,
                              fontSize: 14,
                              fontWeight: t2Wins ? FontWeight.bold : FontWeight.w600)),
                    ]),
                  )),
                  Expanded(flex: 2, child: Center(child: isDone
                      ? GestureDetector(
                          onTap: () {
                            if (gm == null) return;
                            setState(() {
                              gm!.winner = null; gm!.score1 = null;
                              gm!.score2 = null;
                              gm!.team1.wins   = (gm!.team1.wins   - 1).clamp(0, 99);
                              gm!.team1.points = (gm!.team1.points - 1).clamp(0, 999);
                              gm!.team2.losses = (gm!.team2.losses - 1).clamp(0, 99);
                            });
                          },
                          child: Column(mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                            const Icon(Icons.check_circle,
                                color: Colors.green, size: 16),
                            const SizedBox(height: 2),
                            const Text('Done',
                                style: TextStyle(color: Colors.green,
                                    fontSize: 10, fontWeight: FontWeight.bold)),
                            Text('reset', style: TextStyle(
                                color: Colors.white.withOpacity(0.2),
                                fontSize: 9)),
                          ]))
                      : Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.04),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: const Text('Pending',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white24,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold))))),
                ])),
              ),
            );
          },
        ),
      ),
    ]);
  }

  Color _groupColor(String label) {
    switch (label) {
      case 'A': return const Color(0xFF00CFFF);
      case 'B': return const Color(0xFFFF9F43);
      case 'C': return const Color(0xFF7B6AFF);
      case 'D': return const Color(0xFF00FF88);
      case 'E': return const Color(0xFFFF6B6B);
      case 'F': return const Color(0xFFFFD700);
      case 'G': return const Color(0xFFFF4FD8);
      case 'H': return const Color(0xFF43E8D8);
      default:  return Colors.white38;
    }
  }

  Widget _actionBanner({
    required IconData icon, required Color color,
    required String message, required String buttonLabel,
    required VoidCallback? onTap, bool disabled = false, String? disabledMsg,
  }) => Container(
    margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      gradient: LinearGradient(colors: disabled
          ? [const Color(0xFF2A2A2A), const Color(0xFF1A1A1A)]
          : [color.withOpacity(0.25), color.withOpacity(0.1)]),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: disabled ? Colors.white12 : color.withOpacity(0.4), width: 1),
    ),
    child: Row(children: [
      Icon(disabled ? Icons.lock : icon,
          color: disabled ? Colors.white24 : color, size: 20),
      const SizedBox(width: 10),
      Expanded(child: Text(disabled ? (disabledMsg ?? message) : message,
          style: TextStyle(color: disabled ? Colors.white24 : Colors.white,
              fontSize: 13, fontWeight: FontWeight.w600))),
      if (!disabled) ...[
        const SizedBox(width: 10),
        ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            foregroundColor: const Color(0xFF0E0730),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          ),
          child: Text(buttonLabel,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        ),
      ],
    ]),
  );

  Widget _soccerScheduleHeader() => Container(
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
  );

  Widget _soccerScheduleRow(int catId, Map<String, dynamic> row, int idx) {
    final matchNum = row['matchNumber'] as int;
    final schedule = row['schedule'] as String;
    final isEven   = idx % 2 == 0;
    final status   = _getStatus(catId, matchNum);
    final arenas   = row['arenas'] as List;
    Map<String, dynamic>? t1 = arenas.isNotEmpty ? arenas[0] as Map<String, dynamic>? : null;
    Map<String, dynamic>? t2 = arenas.length > 1  ? arenas[1] as Map<String, dynamic>? : null;
    final team1Name = t1?['team_name']?.toString() ?? '—';
    final team2Name = t2?['team_name']?.toString() ?? '—';
    final team1Id   = _fmtTeamId(t1?['team_id']?.toString() ?? '');
    final team2Id   = _fmtTeamId(t2?['team_id']?.toString() ?? '');
    return Container(
      decoration: BoxDecoration(
        color: isEven ? const Color(0xFF160C40) : const Color(0xFF100830),
        border: const Border(bottom: BorderSide(color: Color(0xFF1A1050), width: 1)),
      ),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(flex: 1, child: Center(child: Text('$matchNum',
              style: TextStyle(color: Colors.white.withOpacity(0.4),
                  fontWeight: FontWeight.bold, fontSize: 16)))),
          Expanded(flex: 2, child: Center(child: Text(schedule,
              style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 15)))),
          Expanded(flex: 4, child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
            child: Column(mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (team1Id.isNotEmpty) _teamIdBadge(team1Id),
              const SizedBox(height: 4),
              Text(team1Name, textAlign: TextAlign.right, maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
          )),
          Expanded(flex: 2, child: Center(child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1A0F38),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF3D1E88), width: 1.5),
            ),
            child: const Text('—', textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 14)),
          ))),
          Expanded(flex: 4, child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
            child: Column(mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (team2Id.isNotEmpty) _teamIdBadge(team2Id),
              const SizedBox(height: 4),
              Text(team2Name, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
          )),
          Expanded(flex: 2, child: Center(child: GestureDetector(
            onTap: () => _cycleStatus(catId, matchNum),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: status.color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: status.color, width: 1.5),
              ),
              child: Text(status.label, textAlign: TextAlign.center,
                  style: TextStyle(color: status.color,
                      fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ))),
        ]),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // GROUPS TAB
  // ════════════════════════════════════════════════════════════════════════════
  Widget _buildGroupsTab() {
    final teamCount    = _soccerTeams.length;
    final canGenerate  = teamCount >= 4;
    final allDone      = _allGroupMatchesDone() && _groupsGenerated;
    // Disable refresh if any group match has already started (has a score/winner)
    final matchStarted = _groups.any((g) => g.matches.any((m) => m.isDone));
    final canRefresh   = canGenerate && !matchStarted;
    return Column(children: [
      Container(
        color: const Color(0xFF0F0A2A),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: canGenerate
                  ? const Color(0xFF00CFFF).withOpacity(0.12)
                  : Colors.redAccent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: canGenerate
                    ? const Color(0xFF00CFFF).withOpacity(0.7)
                    : Colors.redAccent.withOpacity(0.7),
                width: 1.5,
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center, children: [
              Icon(Icons.groups,
                  color: canGenerate ? const Color(0xFF00CFFF) : Colors.redAccent, size: 15),
              const SizedBox(width: 6),
              Text('$teamCount', style: TextStyle(
                color: canGenerate ? const Color(0xFF00CFFF) : Colors.redAccent,
                fontSize: 13, fontWeight: FontWeight.w900,
              )),
              const SizedBox(width: 4),
              Text('Teams Registered', style: TextStyle(
                color: (canGenerate ? const Color(0xFF00CFFF) : Colors.redAccent).withOpacity(0.7),
                fontSize: 11, fontWeight: FontWeight.bold,
              )),
            ]),
          ),
          const SizedBox(width: 10),
          if (canGenerate)
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white12, width: 1),
              ),
              child: Center(child: Text(_groupSplitLabel(teamCount),
                  style: const TextStyle(color: Colors.white54, fontSize: 11,
                      fontWeight: FontWeight.w600))),
            ),
          const Spacer(),
          if (!canGenerate)
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white12, width: 1),
              ),
              child: const Center(child: Text('Need ≥4 teams',
                  style: TextStyle(color: Colors.white24, fontSize: 11))),
            )
          else if (matchStarted)
            // Show locked button with tooltip when match has started
            Tooltip(
              message: 'Cannot reshuffle after matches have started',
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white12, width: 1),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: const [
                  Icon(Icons.lock, color: Colors.white24, size: 14),
                  SizedBox(width: 8),
                  Text('Refresh Groups',
                      style: TextStyle(color: Colors.white24, fontSize: 13,
                          fontWeight: FontWeight.bold)),
                ]),
              ),
            )
          else
            SizedBox(
              height: 36,
              child: ElevatedButton.icon(
                onPressed: canRefresh ? _generateGroups : null,
                icon: const Icon(Icons.refresh, size: 15),
                label: Text(_groupsGenerated ? 'Refresh Groups' : 'Generate Groups',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _groupsGenerated
                      ? const Color(0xFF7B2FFF) : const Color(0xFF00CFFF),
                  foregroundColor: _groupsGenerated ? Colors.white : const Color(0xFF0E0730),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  elevation: 3,
                ),
              ),
            ),
        ]),
      ),
      if (!_groupsGenerated)
        Expanded(child: _buildGroupsEmptyState(teamCount, canGenerate))
      else
        Expanded(child: Column(children: [
          if (allDone && !_playInSeeded)
            _actionBanner(
              icon: Icons.emoji_events, color: const Color(0xFF00FF88),
              message: 'Groups done!  Play-In: #1 vs #2 each group (BO1). Winners enter Double Elim.',
              buttonLabel: 'Start Play-In', onTap: _seedPlayIn,
            ),
          if (_playInSeeded)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.07),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.green.withOpacity(0.3), width: 1),
              ),
              child: const Row(children: [
                Icon(Icons.check_circle, color: Colors.green, size: 15),
                SizedBox(width: 8),
                Text('Play-In seeded: #1 vs #2 per group (BO1). Enter results in the BRACKET tab.',
                    style: TextStyle(color: Colors.green, fontSize: 13)),
              ]),
            ),
          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: _buildFifaDrawGrid(),
          )),
        ])),
    ]);
  }

  Widget _buildFifaDrawGrid() {
    const int cols = 4;
    final rows = <List<TournamentGroup>>[];
    for (int i = 0; i < _groups.length; i += cols) {
      rows.add(_groups.sublist(i, (i + cols).clamp(0, _groups.length)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF2D0E7A), Color(0xFF1A0850)]),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: const [
          Icon(Icons.sports_soccer, color: Color(0xFF00CFFF), size: 18),
          SizedBox(width: 10),
          Text('DRAW RESULTS', style: TextStyle(color: Colors.white, fontSize: 18,
              fontWeight: FontWeight.w900, letterSpacing: 3)),
          SizedBox(width: 10),
          Icon(Icons.sports_soccer, color: Color(0xFF00CFFF), size: 18),
        ]),
      ),
      ...rows.map((rowGroups) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start,
            children: rowGroups.map((g) => Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: _buildFifaGroupCard(g),
              ),
            )).toList()),
      )),
    ]);
  }

  Widget _buildFifaGroupCard(TournamentGroup group) {
    final doneCount = group.matches.where((m) => m.isDone).length;
    final total     = group.matches.length;
    final allDone   = doneCount == total && total > 0;
    final groupCol  = _groupColor(group.label);
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F0A2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: groupCol.withOpacity(0.4), width: 1.5),
        boxShadow: [BoxShadow(color: groupCol.withOpacity(0.08), blurRadius: 12)],
      ),
      child: Column(children: [
        // ── Group header ──────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            gradient: LinearGradient(
                colors: [groupCol.withOpacity(0.3), groupCol.withOpacity(0.1)]),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
          ),
          child: Row(children: [
            Container(
              width: 30, height: 30,
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: groupCol.withOpacity(0.2),
                  border: Border.all(color: groupCol, width: 1.5)),
              child: Center(child: Text(group.label,
                  style: TextStyle(color: groupCol, fontWeight: FontWeight.w900,
                      fontSize: 14, letterSpacing: 0.5))),
            ),
            const SizedBox(width: 8),
            Text('GROUP ${group.label}',
                style: const TextStyle(color: Colors.white, fontSize: 13,
                    fontWeight: FontWeight.w900, letterSpacing: 1.5)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: allDone
                    ? Colors.green.withOpacity(0.15) : groupCol.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: allDone
                        ? Colors.green.withOpacity(0.5) : groupCol.withOpacity(0.35),
                    width: 1),
              ),
              child: Text('$doneCount/$total',
                  style: TextStyle(
                      color: allDone ? Colors.green : groupCol,
                      fontSize: 10, fontWeight: FontWeight.bold)),
            ),
          ]),
        ),
        // ── Team list (draw only, no standings here) ──────────────────────────
        ...group.teams.asMap().entries.map((e) {
          final idx  = e.key + 1;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(
                  color: Colors.white.withOpacity(0.04), width: 1)),
            ),
            child: Row(children: [
              Container(
                width: 20, height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: groupCol.withOpacity(0.1),
                  border: Border.all(color: groupCol.withOpacity(0.4), width: 1),
                ),
                child: Center(child: Text('$idx',
                    style: TextStyle(color: groupCol.withOpacity(0.8),
                        fontSize: 9, fontWeight: FontWeight.bold))),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(e.value.teamName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70,
                      fontSize: 12, fontWeight: FontWeight.w500))),
            ]),
          );
        }),
        // ── Footer ────────────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.02),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(11)),
            border: Border(top: BorderSide(color: groupCol.withOpacity(0.12), width: 1)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.leaderboard,
                color: const Color(0xFF00FF88).withOpacity(0.5), size: 10),
            const SizedBox(width: 4),
            Text('See Standings for W/L/PTS',
                style: TextStyle(
                    color: const Color(0xFF00FF88).withOpacity(0.5),
                    fontSize: 9, fontWeight: FontWeight.bold)),
          ]),
        ),
      ]),
    );
  }

  String _groupSplitLabel(int n) {
    const int maxGroups     = 8;
    const int teamsPerGroup = 4;
    final int numGroups = (n / teamsPerGroup).ceil().clamp(1, maxGroups);
    final int baseSize  = n ~/ numGroups;
    final int extras    = n % numGroups;
    final labels = List.generate(
        numGroups, (i) => String.fromCharCode('A'.codeUnitAt(0) + i));
    final counts = List.generate(numGroups, (i) => baseSize + (i < extras ? 1 : 0));
    return List.generate(numGroups, (i) => '${labels[i]}:${counts[i]}').join('  ');
  }

  Widget _buildGroupsEmptyState(int teamCount, bool canGenerate) {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            shape: BoxShape.circle, color: const Color(0xFF130742),
            border: Border.all(
              color: canGenerate
                  ? const Color(0xFF00CFFF).withOpacity(0.3)
                  : Colors.redAccent.withOpacity(0.3),
              width: 2,
            ),
          ),
          child: Icon(canGenerate ? Icons.shuffle : Icons.group_add, size: 52,
              color: canGenerate
                  ? const Color(0xFF00CFFF).withOpacity(0.6)
                  : Colors.redAccent.withOpacity(0.5)),
        ),
        const SizedBox(height: 24),
        Text(canGenerate ? 'Ready to Generate Groups!' : 'Not Enough Teams',
            style: TextStyle(
                color: canGenerate ? const Color(0xFF00CFFF) : Colors.redAccent,
                fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
        const SizedBox(height: 10),
        Text(
          canGenerate
              ? '$teamCount teams · ${_groupSplitLabel(teamCount)}\nTap "Generate Groups" above.'
              : 'Need at least 4 teams. Currently $teamCount registered.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 14, height: 1.6),
        ),
      ]),
    );
  }

  void _showGroupMatchDialog(GroupMatch match) {
    final c1 = TextEditingController(text: match.score1?.toString() ?? '');
    final c2 = TextEditingController(text: match.score2?.toString() ?? '');
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.75),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 360,
          decoration: BoxDecoration(
            color: const Color(0xFF14093A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF3D1E88), width: 1.5),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 14, 14),
              decoration: const BoxDecoration(color: Color(0xFF0F0628),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
              child: Row(children: [
                const Icon(Icons.sports_soccer, color: Color(0xFF9B6FE8), size: 18),
                const SizedBox(width: 10),
                const Text('GROUP MATCH RESULT',
                    style: TextStyle(color: Colors.white, fontSize: 15,
                        fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                const Spacer(),
                GestureDetector(onTap: () => Navigator.pop(ctx),
                    child: Icon(Icons.close, color: Colors.white.withOpacity(0.4), size: 18)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(children: [
                Expanded(child: Column(children: [
                  Text(match.team1.teamName, textAlign: TextAlign.center,
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14,
                          fontWeight: FontWeight.bold)),
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
                    ),
                    child: const Text('VS', style: TextStyle(color: Colors.white,
                        fontSize: 15, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                  ),
                ),
                Expanded(child: Column(children: [
                  Text(match.team2.teamName, textAlign: TextAlign.center,
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  _scoreField(c2, const Color(0xFF00FF88)),
                ])),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: ElevatedButton(
                onPressed: () {
                  final s1 = int.tryParse(c1.text.trim());
                  final s2 = int.tryParse(c2.text.trim());
                  if (s1 == null || s2 == null || s1 == s2) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Enter valid scores. Draws are not allowed.'),
                        backgroundColor: Colors.orange));
                    return;
                  }
                  final winner = s1 > s2 ? match.team1 : match.team2;
                  _setGroupMatchResult(match, winner, s1, s2);
                  Navigator.pop(ctx);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF5B2CC0),
                  minimumSize: const Size(double.infinity, 46),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Save Result',
                    style: TextStyle(color: Colors.white, fontSize: 14,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // NON-SOCCER CATEGORY VIEW
  // ════════════════════════════════════════════════════════════════════════════
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
        gradient: LinearGradient(colors: [Color(0xFF2D0E7A), Color(0xFF1A0850)],
            begin: Alignment.centerLeft, end: Alignment.centerRight),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 28),
      child: Row(children: [
        const Text('ROBOVENTURE',
            style: TextStyle(color: Colors.white30, fontSize: 14,
                fontWeight: FontWeight.bold, letterSpacing: 2)),
        const Spacer(),
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 26,
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
          _headerCell('MATCH', flex: 1),
          _headerCell('SCHEDULE', flex: 2),
          if (maxArenas == 1) const Spacer(flex: 2),
          ...List.generate(maxArenas, (i) =>
              _headerCell('ARENA ${i + 1}', flex: 3, center: true)),
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
                    color: isEven
                        ? const Color(0xFF160C40) : const Color(0xFF100830),
                    padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 24),
                    child: Row(children: [
                      Expanded(flex: 1, child: Text('$matchNum',
                          style: const TextStyle(color: Colors.white,
                              fontWeight: FontWeight.bold, fontSize: 17))),
                      Expanded(flex: 2, child: Text(schedule,
                          style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 16))),
                      if (maxArenas == 1) const Spacer(flex: 2),
                      ...List.generate(maxArenas, (ai) {
                        final team = ai < arenas.length
                            ? arenas[ai] as Map<String, dynamic>? : null;
                        if (team != null) {
                          final displayId = _fmtTeamId(team['team_id']?.toString() ?? '');
                          return Expanded(flex: 3, child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (displayId.isNotEmpty) _teamIdBadge(displayId),
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
                          child: Text(status.label, textAlign: TextAlign.center,
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

  // ════════════════════════════════════════════════════════════════════════════
  // SHARED WIDGETS
  // ════════════════════════════════════════════════════════════════════════════
  Widget _teamIdBadge(String id) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: const Color(0xFF00CFFF).withOpacity(0.15),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: const Color(0xFF00CFFF).withOpacity(0.5), width: 1),
    ),
    child: Text(id, style: const TextStyle(color: Color(0xFF00CFFF),
        fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
  );

  Widget _scoreField(TextEditingController ctrl, Color accentColor) => Container(
    height: 58,
    decoration: BoxDecoration(
      color: const Color(0xFF1C0F4A),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: accentColor.withOpacity(0.5), width: 1.5),
    ),
    child: Center(child: TextField(
      controller: ctrl,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textAlign: TextAlign.center,
      style: TextStyle(color: accentColor, fontSize: 26, fontWeight: FontWeight.bold),
      decoration: const InputDecoration(border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: '0', hintStyle: TextStyle(color: Colors.white12, fontSize: 26)),
    )),
  );

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFF1A0550), Color(0xFF2D0E7A), Color(0xFF1A0A4A)],
        ),
        border: const Border(bottom: BorderSide(color: Color(0xFF00CFFF), width: 1.5)),
        boxShadow: [BoxShadow(color: const Color(0xFF00CFFF).withOpacity(0.12),
            blurRadius: 16, offset: const Offset(0, 4))],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(height: 44, width: 160,
              child: Image.asset('assets/images/MakeblockLogo.png',
                  fit: BoxFit.contain, alignment: Alignment.centerLeft)),
          Container(
            decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [
              BoxShadow(color: const Color(0xFF7B2FFF).withOpacity(0.35),
                  blurRadius: 24, spreadRadius: 4),
            ]),
            child: Image.asset('assets/images/CenterLogo.png',
                height: 70, fit: BoxFit.contain),
          ),
          SizedBox(height: 44, width: 160,
              child: Image.asset('assets/images/CreotecLogo.png',
                  fit: BoxFit.contain, alignment: Alignment.centerRight)),
        ],
      ),
    );
  }

  Widget _buildLiveIndicator() {
    final timeStr = _lastUpdated == null ? '--:--:--'
        : '${_lastUpdated!.hour.toString().padLeft(2, "0")}:'
          '${_lastUpdated!.minute.toString().padLeft(2, "0")}:'
          '${_lastUpdated!.second.toString().padLeft(2, "0")}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _PulsingDot(),
        const SizedBox(width: 5),
        Column(crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, children: [
          const Text('LIVE', style: TextStyle(color: Color(0xFF00FF88), fontSize: 11,
              fontWeight: FontWeight.bold, letterSpacing: 1.2)),
          Text(timeStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ]),
      ]),
    );
  }

  Widget _buildPhaseIndicator() {
    final phases = [
      ('GROUP\nSTAGE',  _groupsGenerated && _allGroupMatchesDone()),
      ('PLAY-IN',       _playInDone),
      ('DOUBLE\nELIM',  _bracketSeeded && _grandFinal?.team1.teamId != -99),
      ('GRAND\nFINAL',  _grandFinal?.winner != null),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0A2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF3D1E88).withOpacity(0.4)),
      ),
      child: Row(children: phases.asMap().entries.expand((e) {
        final idx   = e.key;
        final label = e.value.$1;
        final done  = e.value.$2;
        final isCurrent = idx == phases.indexWhere((p) => !p.$2);
        return [
          Expanded(child: Column(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done
                    ? Colors.green.withOpacity(0.15)
                    : isCurrent
                    ? const Color(0xFF00CFFF).withOpacity(0.15)
                    : Colors.white.withOpacity(0.04),
                border: Border.all(
                    color: done ? Colors.green
                        : isCurrent ? const Color(0xFF00CFFF) : Colors.white12,
                    width: 1.5),
              ),
              child: Center(child: done
                  ? const Icon(Icons.check, color: Colors.green, size: 16)
                  : isCurrent
                  ? Container(width: 8, height: 8,
                  decoration: const BoxDecoration(
                      color: Color(0xFF00CFFF), shape: BoxShape.circle))
                  : Text('${idx + 1}',
                  style: const TextStyle(color: Colors.white24, fontSize: 11))),
            ),
            const SizedBox(height: 4),
            Text(label, textAlign: TextAlign.center,
                style: TextStyle(
                    color: done ? Colors.green
                        : isCurrent ? const Color(0xFF00CFFF) : Colors.white24,
                    fontSize: 9, fontWeight: FontWeight.bold, height: 1.2)),
          ])),
          if (idx < phases.length - 1)
            Container(width: 24, height: 1.5, margin: const EdgeInsets.only(bottom: 20),
                color: done ? Colors.green.withOpacity(0.4) : Colors.white12),
        ];
      }).toList()),
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

// ── Play-In preview pair data holder ────────────────────────────────────────
class _PlayInPreviewPair {
  final String label;
  final String t1, t2;
  final String t1group, t2group;
  final int    t1rank,  t2rank;
  final bool   done;
  final Color  gcA, gcB;
  const _PlayInPreviewPair({
    required this.label,
    required this.t1, required this.t2,
    required this.t1group, required this.t2group,
    required this.t1rank,  required this.t2rank,
    required this.done,
    required this.gcA, required this.gcB,
  });
}

// ════════════════════════════════════════════════════════════════════════════
// _MplBracketCanvas  — MPL-style UB/LB double elim visual bracket
// ════════════════════════════════════════════════════════════════════════════
class _MplBracketCanvas extends StatelessWidget {
  final List<BracketTeam>        seeds;
  final List<List<BracketMatch>> ubRounds;
  final List<List<BracketMatch>> lbRounds;
  final BracketMatch?            grandFinal;
  final bool                     isPreview;
  final void Function(BracketMatch, BracketTeam) onUBResult;
  final void Function(BracketMatch, BracketTeam) onLBResult;
  final VoidCallback             onGFTap;
  final void Function(BracketMatch, {required void Function(BracketTeam) onResult}) onShowDialog;

  const _MplBracketCanvas({
    required this.seeds,
    required this.ubRounds,
    required this.lbRounds,
    required this.grandFinal,
    required this.isPreview,
    required this.onUBResult,
    required this.onLBResult,
    required this.onGFTap,
    required this.onShowDialog,
  });

  // ── Tighter layout constants ────────────────────────────────────────────
  static const double kW  = 160.0;   // card width
  static const double kH  = 74.0;   // card height (includes dest footer)
  static const double kGH = 32.0;   // horizontal gap between rounds
  static const double kGV =  8.0;   // vertical gap between cards

  @override
  Widget build(BuildContext context) {
    if (seeds.isEmpty && ubRounds.isEmpty) {
      return const SizedBox(
        width: 600, height: 300,
        child: Center(child: Text('Generate groups to preview the bracket',
            style: TextStyle(color: Colors.white24, fontSize: 14))),
      );
    }

    final slotH = kH + kGV;

    // ── Derive counts from actual data when live, else from seeds ─────────
    final int ubRoundCount;
    final int lbRoundCount;
    final int ubRows;

    if (ubRounds.isNotEmpty) {
      ubRoundCount = ubRounds.length;
      ubRows       = ubRounds[0].length * 2;   // R1 matchCount * 2 = total slots
      lbRoundCount = lbRounds.length;
    } else {
      final slots  = _nextPow2(max(2, seeds.length));
      ubRoundCount = _log2(slots);
      lbRoundCount = max(1, (ubRoundCount - 1) * 2);
      ubRows       = slots;
    }

    final lbRows   = max(1, ubRows ~/ 2);
    final ubHeight = 28.0 + ubRows * slotH;
    final lbHeight = 28.0 + lbRows * slotH;
    final totalH   = ubHeight + 36 + lbHeight + 20;
    final totalW   = (ubRoundCount + 1) * (kW + kGH) + kW + 16;

    final previewPairs = _buildPreviewPairs(ubRows);

    return SizedBox(
      width: totalW, height: totalH,
      child: Stack(children: [

        // ── Connector lines ──────────────────────────────────────────────
        CustomPaint(
          size: Size(totalW, totalH),
          painter: _MplLinePainter(
            ubRoundCount: ubRoundCount,
            lbRoundCount: lbRoundCount,
            ubRows: ubRows, lbRows: lbRows,
            ubTopOffset: 28,
            lbTopOffset: ubHeight + 36,
            cardW: kW, cardH: kH, gapH: kGH, gapV: kGV,
            isPreview: isPreview,
          ),
        ),

        // ── Section labels ───────────────────────────────────────────────
        Positioned(left: 0, top: 0, width: 180,
            child: _sectionLabel('UPPER BRACKET', const Color(0xFF00CFFF))),
        Positioned(left: 0, top: ubHeight + 10, width: 180,
            child: _sectionLabel('LOWER BRACKET', const Color(0xFFFF6B6B))),

        // ── UB cards ─────────────────────────────────────────────────────
        ..._buildUBCards(ubRoundCount, ubRows, 28.0, previewPairs),

        // ── Grand Final ──────────────────────────────────────────────────
        _buildGFCard(ubRoundCount, ubRows, 28.0),

        // ── LB cards ─────────────────────────────────────────────────────
        ..._buildLBCards(lbRows, ubHeight + 36),
      ]),
    );
  }

  // ── UB cards ─────────────────────────────────────────────────────────────
  List<Widget> _buildUBCards(int rounds, int ubRows, double topY,
      List<List<BracketTeam?>> previewPairs) {
    final widgets = <Widget>[];
    final slotH   = kH + kGV;

    for (int r = 0; r < rounds; r++) {
      final x          = r * (kW + kGH);
      final matchCount = max(1, ubRows ~/ pow(2, r + 1).toInt());

      widgets.add(Positioned(
        left: x, top: topY - 18, width: kW,
        child: Center(child: _roundChip(_ubLabel(r, rounds), const Color(0xFF00CFFF))),
      ));

      for (int i = 0; i < matchCount; i++) {
        final span = pow(2, r + 1).toInt();
        final y    = topY + i * span * slotH + (span * slotH - kH) / 2;

        BracketMatch? real;
        if (r < ubRounds.length && i < ubRounds[r].length) real = ubRounds[r][i];

        // Preview fallback for R1
        String t1n = 'TBD', t2n = 'TBD';
        int    t1s = 0,     t2s = 0;
        if (r == 0 && i < previewPairs.length) {
          t1n = previewPairs[i][0]?.teamName ?? 'TBD';
          t2n = previewPairs[i][1]?.teamName ?? 'TBD';
          t1s = previewPairs[i][0]?.seed     ?? 0;
          t2s = previewPairs[i][1]?.seed     ?? 0;
        }

        final t1     = (real != null && real.team1.teamId != -99) ? real.team1.teamName : t1n;
        final t2     = (real != null && real.team2.teamId != -99) ? real.team2.teamName : t2n;
        final canTap = !isPreview && real != null &&
            real.team1.teamId != -99 && real.team2.teamId != -99 && real.winner == null;

        widgets.add(Positioned(
          left: x, top: y, width: kW, height: kH,
          child: _BracketCard(
            t1: t1, t2: t2,
            t1Seed: real?.team1.seed ?? t1s,
            t2Seed: real?.team2.seed ?? t2s,
            winner: real?.winner?.teamName,
            accent: const Color(0xFF00CFFF),
            dim: isPreview && real == null,
            canTap: canTap,
            bracketLabel: 'UB',
            winnerDest: r == rounds - 1 ? 'Winner → GF' : 'Winner → ${_ubLabel(r+1, rounds)}',
            loserDest:  r == 0 ? 'Loser → LB R1' : 'Loser → LB',
            onTap: canTap ? () {
              final m = real!;
              onShowDialog(m, onResult: (w) => onUBResult(m, w));
            } : null,
          ),
        ));
      }
    }
    return widgets;
  }

  // ── LB cards — driven entirely by real lbRounds data ─────────────────────
  List<Widget> _buildLBCards(int lbRows, double topY) {
    final widgets = <Widget>[];
    final slotH   = kH + kGV;

    if (lbRounds.isEmpty) {
      // Preview: just show dimmed TBD placeholders in a single column
      final count = max(1, lbRows ~/ 2);
      widgets.add(Positioned(
        left: 0, top: topY - 18, width: kW,
        child: Center(child: _roundChip('LB R1', const Color(0xFFFF6B6B))),
      ));
      for (int i = 0; i < count; i++) {
        final span = lbRows ~/ count;
        final y    = topY + i * span * slotH + (span * slotH - kH) / 2;
        widgets.add(Positioned(
          left: 0, top: y, width: kW, height: kH,
          child: _BracketCard(
            t1: 'TBD', t2: 'TBD', t1Seed: 0, t2Seed: 0,
            winner: null, accent: const Color(0xFFFF6B6B),
            dim: true, canTap: false, onTap: null,
            bracketLabel: 'LB',
          ),
        ));
      }
      return widgets;
    }

    final totalRounds = lbRounds.length;

    for (int r = 0; r < totalRounds; r++) {
      final roundMatches = lbRounds[r];
      final x = r * (kW + kGH);
      final matchCount = roundMatches.length;

      widgets.add(Positioned(
        left: x, top: topY - 18, width: kW,
        child: Center(child: _roundChip(_lbLabel(r, totalRounds), const Color(0xFFFF6B6B))),
      ));

      // Distribute cards evenly within lbRows
      final totalSlots = lbRows;
      final span       = max(1, totalSlots ~/ matchCount);

      for (int i = 0; i < matchCount; i++) {
        final rm = roundMatches[i];
        final y  = topY + i * span * slotH + (span * slotH - kH) / 2;

        final t1     = rm.team1.teamId != -99 ? rm.team1.teamName : 'TBD';
        final t2     = rm.team2.teamId != -99 ? rm.team2.teamName : 'TBD';
        final canTap = !isPreview && rm.team1.teamId != -99 &&
            rm.team2.teamId != -99 && rm.winner == null;

        widgets.add(Positioned(
          left: x, top: y, width: kW, height: kH,
          child: _BracketCard(
            t1: t1, t2: t2,
            t1Seed: rm.team1.seed,
            t2Seed: rm.team2.seed,
            winner: rm.winner?.teamName,
            accent: const Color(0xFFFF6B6B),
            dim: false,
            canTap: canTap,
            bracketLabel: 'LB',
            winnerDest: r == totalRounds - 1 ? 'Winner → GF' : 'Winner → ${_lbLabel(r+1, totalRounds)}',
            loserDest: 'Eliminated',
            onTap: canTap ? () {
              final m = rm;
              onShowDialog(m, onResult: (w) => onLBResult(m, w));
            } : null,
          ),
        ));
      }
    }
    return widgets;
  }

  // ── Grand Final card ─────────────────────────────────────────────────────
  Widget _buildGFCard(int ubRoundCount, int ubRows, double ubTopY) {
    final slotH  = kH + kGV;
    final x      = ubRoundCount * (kW + kGH);
    final midY   = ubTopY + (ubRows * slotH) / 2 - (kH + 48) / 2;
    final gf     = grandFinal;
    final t1     = (gf != null && gf.team1.teamId != -99) ? gf.team1.teamName : 'UB FINALIST';
    final t2     = (gf != null && gf.team2.teamId != -99) ? gf.team2.teamName : 'LB FINALIST';
    final isDone = gf?.winner != null;
    final canTap = !isPreview && gf != null &&
        gf.team1.teamId != -99 && gf.team2.teamId != -99 && !isDone;

    return Positioned(
      left: x, top: midY, width: kW + 16,
      child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFFFFD700), Color(0xFFFF8C00)]),
            borderRadius: BorderRadius.circular(7),
            boxShadow: [BoxShadow(color: const Color(0xFFFFD700).withOpacity(0.3), blurRadius: 8)],
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Text('🏆', style: TextStyle(fontSize: 10)),
            SizedBox(width: 5),
            Text('GRAND FINAL', style: TextStyle(color: Color(0xFF1A0800),
                fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
            SizedBox(width: 5),
            Text('🏆', style: TextStyle(fontSize: 10)),
          ]),
        ),
        GestureDetector(
          onTap: canTap ? onGFTap : null,
          child: Container(
            height: kH + 24,
            decoration: BoxDecoration(
              color: isDone ? const Color(0xFF1A2A00)
                  : canTap ? const Color(0xFF1A1000) : const Color(0xFF110A2A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isDone
                    ? const Color(0xFFFFD700).withOpacity(0.8)
                    : canTap ? const Color(0xFFFFD700).withOpacity(0.5)
                    : const Color(0xFFFFD700).withOpacity(isPreview ? 0.12 : 0.25),
                width: 1.5,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Column(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _gfRow(t1, gf?.score1 ?? 0,
                    isDone && gf?.winner?.teamId == gf?.team1.teamId,
                    gf?.team1.teamId == -99, const Color(0xFF00CFFF), 'UB'),
                Container(height: 1, color: const Color(0xFFFFD700).withOpacity(0.1)),
                _gfRow(t2, gf?.score2 ?? 0,
                    isDone && gf?.winner?.teamId == gf?.team2.teamId,
                    gf?.team2.teamId == -99, const Color(0xFFFF6B6B), 'LB'),
                if (canTap)
                  const Center(child: Text('TAP TO SET SCORE',
                      style: TextStyle(color: Color(0xFFFFD700), fontSize: 7,
                          fontWeight: FontWeight.bold))),
                if (isDone)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [Color(0xFFFFD700), Color(0xFFFF8C00)]),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('🏆 ${gf!.winner!.teamName}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xFF1A0800),
                            fontSize: 7, fontWeight: FontWeight.w900)),
                  ),
              ]),
            ),
          ),
        ),
        Container(
          margin: const EdgeInsets.only(top: 3),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFFFFD700).withOpacity(0.07),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.2)),
          ),
          child: const Text('BO3  ·  First to 2 wins',
              style: TextStyle(color: Color(0xFFFFD700), fontSize: 8,
                  fontWeight: FontWeight.bold)),
        ),
      ]),
    );
  }

  Widget _gfRow(String name, int score, bool isWinner, bool isDim,
      Color badge, String badgeLabel) =>
      Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          decoration: BoxDecoration(
            color: badge.withOpacity(0.1),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: badge.withOpacity(0.3)),
          ),
          child: Text(badgeLabel, style: TextStyle(color: badge, fontSize: 6,
              fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 4),
        Expanded(child: Text(name, overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: isWinner ? const Color(0xFF00FF88)
                    : isDim ? Colors.white24 : Colors.white,
                fontSize: 10,
                fontWeight: isWinner ? FontWeight.bold : FontWeight.w500))),
        if (isWinner)
          const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 10),
        Container(width: 18, height: 18,
          decoration: BoxDecoration(
            color: isWinner
                ? const Color(0xFFFFD700).withOpacity(0.1)
                : Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Center(child: Text('$score',
              style: TextStyle(
                  color: isWinner ? const Color(0xFFFFD700) : Colors.white38,
                  fontSize: 9, fontWeight: FontWeight.bold))),
        ),
      ]);

  // ── Helpers ──────────────────────────────────────────────────────────────
  List<List<BracketTeam?>> _buildPreviewPairs(int ubRows) {
    final slots = ubRows;
    if (seeds.isEmpty) return List.generate(slots ~/ 2, (_) => [null, null]);
    final padded = List<BracketTeam?>.from(seeds);
    while (padded.length < slots) padded.add(null);
    final pairs = <List<BracketTeam?>>[];
    int lo = 0, hi = padded.length - 1;
    while (lo < hi) { pairs.add([padded[lo], padded[hi]]); lo++; hi--; }
    return pairs;
  }

  String _ubLabel(int r, int total) {
    if (r == total - 1) return 'UB FINAL';
    if (r == total - 2) return 'UB SF';
    if (r == total - 3) return 'UB QF';
    return 'UB R${r + 1}';
  }

  String _lbLabel(int r, int total) {
    if (r == total - 1) return 'LB FINAL';
    if (r == total - 2) return 'LB SF';
    return 'LB R${r + 1}';
  }

  Widget _sectionLabel(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(5),
      border: Border.all(color: color.withOpacity(0.3)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 7, height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: color.withOpacity(0.5), blurRadius: 4)])),
      const SizedBox(width: 5),
      Text(text, style: TextStyle(color: color, fontSize: 10,
          fontWeight: FontWeight.bold, letterSpacing: 1.2)),
    ]),
  );

  Widget _roundChip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withOpacity(0.2)),
    ),
    child: Text(text, style: TextStyle(color: color.withOpacity(0.7),
        fontSize: 8, fontWeight: FontWeight.bold, letterSpacing: 0.6)),
  );

  static int _nextPow2(int n) { int p = 1; while (p < n) p <<= 1; return p; }
  static int _log2(int n)     { int r = 0; while (n > 1) { n >>= 1; r++; } return r; }
}

// ── Individual bracket card ──────────────────────────────────────────────────
class _BracketCard extends StatelessWidget {
  final String  t1, t2;
  final int     t1Seed, t2Seed;
  final String? winner;
  final Color   accent;
  final bool    dim, canTap;
  final VoidCallback? onTap;
  final String? bracketLabel;   // 'UB' or 'LB'
  final String? winnerDest;     // e.g. 'Winner → UB SF'
  final String? loserDest;      // e.g. 'Loser → LB' or 'Eliminated'

  const _BracketCard({
    required this.t1, required this.t2,
    required this.t1Seed, required this.t2Seed,
    required this.accent, required this.dim, required this.canTap,
    this.winner, this.onTap, this.bracketLabel,
    this.winnerDest, this.loserDest,
  });

  @override
  Widget build(BuildContext context) {
    final isDone = winner != null;
    final t1Win  = isDone && winner == t1;
    final t2Win  = isDone && winner == t2;

    return Opacity(
      opacity: (dim && !isDone) ? 0.35 : 1.0,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: isDone ? const Color(0xFF091A10)
                : canTap ? const Color(0xFF120A32) : const Color(0xFF0B0722),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isDone ? Colors.green.withOpacity(0.5)
                  : canTap ? accent.withOpacity(0.65) : Colors.white12,
              width: 1.5,
            ),
            boxShadow: canTap
                ? [BoxShadow(color: accent.withOpacity(0.15), blurRadius: 8)]
                : [],
          ),
          child: Column(children: [
            // ── Header bar with UB/LB indicator ─────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: accent.withOpacity(0.07),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
                border: Border(bottom: BorderSide(color: accent.withOpacity(0.12))),
              ),
              child: Row(children: [
                // UB / LB pill indicator
                if (bracketLabel != null)
                  Container(
                    margin: const EdgeInsets.only(right: 5),
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: accent.withOpacity(0.45), width: 1),
                    ),
                    child: Text(bracketLabel!,
                        style: TextStyle(color: accent, fontSize: 7,
                            fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                  ),
                Expanded(child: Text(
                  isDone ? 'DONE' : dim ? 'PREVIEW' : 'PENDING',
                  style: TextStyle(color: accent.withOpacity(0.4),
                      fontSize: 8, fontWeight: FontWeight.bold),
                )),
                if (isDone)
                  const Icon(Icons.check_circle, color: Colors.green, size: 9)
                else if (canTap)
                  Text('TAP', style: TextStyle(color: accent.withOpacity(0.55),
                      fontSize: 8, fontWeight: FontWeight.bold)),
              ]),
            ),
            // Team 1
            Expanded(child: _teamRow(t1, t1Seed, t1Win, isDone && !t1Win)),
            Container(height: 1, color: Colors.white.withOpacity(0.05)),
            // Team 2
            Expanded(child: _teamRow(t2, t2Seed, t2Win, isDone && !t2Win)),
            // ── Dest footer ─────────────────────────────────────────────
            if (!isDone && !dim && (winnerDest != null || loserDest != null))
              Container(
                padding: const EdgeInsets.fromLTRB(6, 2, 6, 3),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.2),
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(7)),
                  border: Border(top: BorderSide(color: accent.withOpacity(0.08))),
                ),
                child: Row(children: [
                  if (winnerDest != null)
                    Expanded(child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.arrow_upward, color: const Color(0xFF00FF88).withOpacity(0.6), size: 7),
                      const SizedBox(width: 2),
                      Flexible(child: Text(winnerDest!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: const Color(0xFF00FF88).withOpacity(0.6),
                              fontSize: 7, fontWeight: FontWeight.bold))),
                    ])),
                  if (loserDest != null)
                    Expanded(child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.arrow_downward,
                          color: (loserDest == 'Eliminated'
                              ? Colors.redAccent : const Color(0xFFFF6B6B)).withOpacity(0.6),
                          size: 7),
                      const SizedBox(width: 2),
                      Flexible(child: Text(loserDest!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: (loserDest == 'Eliminated'
                                  ? Colors.redAccent : const Color(0xFFFF6B6B)).withOpacity(0.6),
                              fontSize: 7, fontWeight: FontWeight.bold))),
                    ])),
                ]),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _teamRow(String name, int seed, bool isWinner, bool isDim) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(children: [
          if (seed > 0)
            Container(
              width: 15, height: 15, margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: accent.withOpacity(0.07),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: accent.withOpacity(0.18)),
              ),
              child: Center(child: Text('$seed',
                  style: TextStyle(color: accent.withOpacity(0.55),
                      fontSize: 7, fontWeight: FontWeight.bold))),
            )
          else
            const SizedBox(width: 3),
          Expanded(child: Text(name, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: isWinner ? const Color(0xFF00FF88)
                      : isDim ? Colors.white24
                      : name == 'TBD' ? Colors.white24 : Colors.white,
                  fontSize: 11,
                  fontWeight: isWinner ? FontWeight.bold : FontWeight.w500))),
          if (isWinner)
            const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 10),
        ]),
      );
}

// ── Line painter ─────────────────────────────────────────────────────────────
class _MplLinePainter extends CustomPainter {
  final int    ubRoundCount, lbRoundCount, ubRows, lbRows;
  final double ubTopOffset, lbTopOffset;
  final double cardW, cardH, gapH, gapV;
  final bool   isPreview;

  _MplLinePainter({
    required this.ubRoundCount, required this.lbRoundCount,
    required this.ubRows, required this.lbRows,
    required this.ubTopOffset, required this.lbTopOffset,
    required this.cardW, required this.cardH,
    required this.gapH, required this.gapV,
    required this.isPreview,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final ubPaint = Paint()
      ..color = const Color(0xFF00CFFF).withOpacity(isPreview ? 0.1 : 0.22)
      ..strokeWidth = 1.5 ..style = PaintingStyle.stroke;
    final lbPaint = Paint()
      ..color = const Color(0xFFFF6B6B).withOpacity(isPreview ? 0.1 : 0.22)
      ..strokeWidth = 1.5 ..style = PaintingStyle.stroke;
    final gfPaint = Paint()
      ..color = const Color(0xFFFFD700).withOpacity(isPreview ? 0.08 : 0.18)
      ..strokeWidth = 1.5 ..style = PaintingStyle.stroke;

    final slotH = cardH + gapV;

    // ── UB connectors ──────────────────────────────────────────────────────
    for (int r = 0; r < ubRoundCount - 1; r++) {
      final curCount  = ubRows ~/ pow(2, r + 1).toInt();
      final nextCount = ubRows ~/ pow(2, r + 2).toInt();
      final x1 = r       * (cardW + gapH) + cardW;
      final x2 = (r + 1) * (cardW + gapH);
      final mx = x1 + gapH / 2;

      for (int ni = 0; ni < nextCount; ni++) {
        final spanCur  = ubRows ~/ curCount;
        final spanNext = ubRows ~/ nextCount;
        final ia = ni * 2, ib = ni * 2 + 1;
        final y1a = ubTopOffset + ia * spanCur  * slotH + (spanCur  * slotH) / 2;
        final y1b = ubTopOffset + ib * spanCur  * slotH + (spanCur  * slotH) / 2;
        final y2  = ubTopOffset + ni * spanNext * slotH + (spanNext * slotH) / 2;
        _merge(canvas, ubPaint, x1, y1a, x1, y1b, mx, y2, x2, y2);
      }
    }

    // UB Final → GF
    if (ubRoundCount > 0) {
      final lastX = (ubRoundCount - 1) * (cardW + gapH) + cardW;
      final gfX   = ubRoundCount * (cardW + gapH);
      final midY  = ubTopOffset + ubRows * slotH / 2;
      _line(canvas, gfPaint, lastX, midY, gfX, midY);
    }

    // ── LB connectors ──────────────────────────────────────────────────────
    for (int r = 0; r < lbRoundCount - 1; r++) {
      final curCount  = max(1, lbRows ~/ pow(2, r ~/ 2).toInt());
      final nextCount = max(1, lbRows ~/ pow(2, (r + 1) ~/ 2).toInt());
      final x1 = r       * (cardW + gapH) + cardW;
      final x2 = (r + 1) * (cardW + gapH);
      final mx = x1 + gapH / 2;

      if (nextCount < curCount) {
        // Merge
        for (int ni = 0; ni < nextCount; ni++) {
          final ia = ni * 2, ib = ni * 2 + 1;
          final spanC = lbRows ~/ curCount;
          final spanN = lbRows ~/ nextCount;
          final y1a = lbTopOffset + ia * spanC * slotH + (spanC * slotH) / 2;
          final y1b = lbTopOffset + ib * spanC * slotH + (spanC * slotH) / 2;
          final y2  = lbTopOffset + ni * spanN * slotH + (spanN * slotH) / 2;
          _merge(canvas, lbPaint, x1, y1a, x1, y1b, mx, y2, x2, y2);
        }
      } else {
        // 1-to-1
        for (int ni = 0; ni < min(curCount, nextCount); ni++) {
          final spanC = lbRows ~/ curCount;
          final spanN = lbRows ~/ nextCount;
          final y1 = lbTopOffset + ni * spanC * slotH + (spanC * slotH) / 2;
          final y2 = lbTopOffset + ni * spanN * slotH + (spanN * slotH) / 2;
          _line(canvas, lbPaint, x1, y1, mx, y1);
          _line(canvas, lbPaint, mx, y1, mx, y2);
          _line(canvas, lbPaint, mx, y2, x2, y2);
        }
      }
    }

    // LB Final → GF (bottom slot)
    if (lbRoundCount > 0) {
      final lastLbX = (lbRoundCount - 1) * (cardW + gapH) + cardW;
      final gfX     = ubRoundCount * (cardW + gapH) + (cardW + 20) / 2;
      final lbMidY  = lbTopOffset + lbRows * slotH / 2;
      final gfMidY  = ubTopOffset + ubRows * slotH / 2 + cardH / 2 + 14;
      final path = Path()
        ..moveTo(lastLbX, lbMidY)
        ..lineTo(gfX, lbMidY)
        ..lineTo(gfX, gfMidY);
      canvas.drawPath(path, gfPaint);
    }
  }

  void _merge(Canvas c, Paint p,
      double x1a, double y1a, double x1b, double y1b,
      double mx,  double my,  double x2,  double y2) {
    final path = Path()
      ..moveTo(x1a, y1a)..lineTo(mx, y1a)..lineTo(mx, my)
      ..moveTo(x1b, y1b)..lineTo(mx, y1b)..lineTo(mx, my)
      ..lineTo(x2, y2);
    c.drawPath(path, p);
  }

  void _line(Canvas c, Paint p, double x1, double y1, double x2, double y2) {
    c.drawLine(Offset(x1, y1), Offset(x2, y2), p);
  }

  @override
  bool shouldRepaint(_MplLinePainter o) => true;
}

// ════════════════════════════════════════════════════════════════════════════
// PULSING DOT
// ════════════════════════════════════════════════════════════════════════════
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