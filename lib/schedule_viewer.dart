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
  int draws  = 0;
  int points = 0;
  GroupTeam({required this.teamId, required this.teamName});
  int get gamesPlayed => wins + losses + draws;
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
  final VoidCallback? onBack;
  final VoidCallback? onRegister;
  final VoidCallback? onStandings;
  const ScheduleViewer({super.key, this.onBack, this.onRegister, this.onStandings});
  @override
  State<ScheduleViewer> createState() => _ScheduleViewerState();
}

class _ScheduleViewerState extends State<ScheduleViewer>
    with TickerProviderStateMixin {
  TabController? _tabController;
  List<Map<String, String?>>           _categories         = [];
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

  // ── Knockout scores from DB: matchId -> { teamId -> goals } ─────────────
  Map<int, Map<int, int>> _koScores = {};

  // ── Soccer Bracket ───────────────────────────────────────────────────────


  // ── Soccer inner tab controller ──────────────────────────────────────────
  TabController? _soccerTabCtrl;

  @override
  void initState() {
    super.initState();
    _runMigrationsAndLoad();
    _autoRefreshTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _silentRefresh());
  }

  Future<void> _runMigrationsAndLoad() async {
    try {
      await DBHelper.runMigrations();
    } catch (e) {
      debugPrint('Migration warning: $e');
    }
    await _loadData(initial: true);
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
    if (_isSilentRefreshing) return; // already running — skip this tick
    _isSilentRefreshing = true;
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
        WHERE t.team_ispresent = 1
        ORDER BY c.category_id, s.schedule_start, ts.match_id
      """);
      final rows      = result.rows.map((r) => r.assoc()).toList();
      final signature = _buildSignature(rows);
      if (signature != _lastDataSignature) {
        _lastDataSignature = signature;
        await _loadData(initial: false);
      }

      // Check group changes + score changes from DB
      if (_soccerCategoryId != null) {
        try {
          // Check for score changes in group matches
          // FIX 1: use score_independentscore (goals) not score_totalscore
          final scoreResult = await conn.execute(
            "SELECT sc.score_id, sc.match_id, sc.team_id, sc.score_independentscore "
            "FROM tbl_score sc "
            "JOIN tbl_teamschedule ts ON ts.match_id = sc.match_id AND ts.team_id = sc.team_id "
            "JOIN tbl_match m ON m.match_id = sc.match_id "
            "JOIN tbl_team t ON t.team_id = sc.team_id "
            "WHERE t.category_id = ${_soccerCategoryId} AND m.bracket_type = 'group' "
            "ORDER BY sc.score_id",
          );
          final sRows = scoreResult.rows.map((r) => r.assoc()).toList();
          final sSig  = _buildSignature(sRows);

          final gResult = await conn.execute(
            "SELECT group_label, team_id FROM tbl_soccer_groups WHERE category_id = ${_soccerCategoryId} ORDER BY group_label, id",
          );
          final gRows = gResult.rows.map((r) => r.assoc()).toList();
          final gSig  = _buildSignature(gRows);

          final combined = '$gSig|$sSig';
          if (combined != _lastGroupSignature) {
            _lastGroupSignature = combined;
            // Reload groups WITH scores from DB
            await _loadGroupsFromDB();
          }
        } catch (_) {}
      }
      // Reload schedule rows directly from DB on every refresh
      if (_soccerCategoryId != null) {
        await _loadSoccerSchedule();
        await _loadKoScores();
        // Auto-advance to knockout when group stage completes
        _checkAndAutoAdvance();
        // BUG FIX 2: also check KO advancement on every refresh tick
        // so existing winners are re-advanced after a reload/restart
        await _checkAndAutoAdvanceKnockout();
      }
    } catch (_) {}
    finally {
      _isSilentRefreshing = false;
    }
  }

  Future<void> _loadData({bool initial = false}) async {
    if (initial) setState(() => _isLoading = true);
    try {
      final categories = await DBHelper.getActiveCategories();
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
        WHERE c.status = 'active'
          AND t.team_ispresent = 1
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
        soccerTeams = await DBHelper.getTeamsByCategory(soccerCatId, presentOnly: true);
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

      // Load schedule first so _groupsGenerated check works correctly
      await _loadSoccerSchedule();
      await _loadKoScores();

      // Load previously saved groups from DB
      if (!_groupsGenerated) {
        await _loadGroupsFromDB();
        // If still no groups after DB load AND schedule exists, auto-generate
        if (!_groupsGenerated && soccerTeams.length >= 4 &&
            _soccerScheduleRows.any((r) =>
                (r['bracketType'] as String? ?? '') == 'group')) {
          await _generateGroups(teamsOverride: soccerTeams);
        }
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
    // ── Fixed group count: always 3 groups ──────────────────────────────────
    const int numGroups = 3;
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
      _groupsGenerated = groups.isNotEmpty && _soccerScheduleRows.any((r) => (r['bracketType'] as String? ?? '') == 'group');
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
      // Reset flags so regenerating groups always re-triggers auto-advance
      _hasAutoAdvanced   = false;
      _lastAdvancedRound = '';
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
      final check = await conn.execute("""
        SELECT COUNT(*) as cnt FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_name = 'tbl_soccer_groups'
      """);
      final tableExists = check.rows.isNotEmpty &&
          (int.tryParse(check.rows.first.assoc()['cnt']?.toString() ?? '0') ?? 0) > 0;
      if (!tableExists) return;

      // Only load teams that are currently marked present
      final result = await conn.execute("""
        SELECT sg.group_label, sg.team_id, sg.team_name
        FROM tbl_soccer_groups sg
        JOIN tbl_team t ON t.team_id = sg.team_id
        WHERE sg.category_id = ${_soccerCategoryId}
          AND t.team_ispresent = 1
        ORDER BY sg.group_label, sg.id
      """);
      final rows = result.rows.map((r) => r.assoc()).toList();
      if (rows.isEmpty) return;

      // ── Load scores from DB for all group matches ─────────────────────────
      // FIX 2: use score_independentscore (goals) not score_totalscore
      final scoreResult = await conn.execute("""
        SELECT ts.match_id, ts.team_id,
               sc.score_independentscore AS goals
        FROM tbl_teamschedule ts
        JOIN tbl_match m  ON m.match_id  = ts.match_id
        JOIN tbl_team  t  ON t.team_id   = ts.team_id
        LEFT JOIN tbl_score sc ON sc.team_id = ts.team_id
                               AND sc.match_id = ts.match_id
        WHERE t.category_id = ${_soccerCategoryId}
          AND m.bracket_type = 'group'
        ORDER BY ts.match_id, ts.teamschedule_id
      """);
      // Build: matchId → { teamId → goals }
      final Map<int, Map<int, int>> matchScores = {};
      for (final r in scoreResult.rows) {
        final mid   = int.tryParse(r.assoc()['match_id']?.toString() ?? '0') ?? 0;
        final tid   = int.tryParse(r.assoc()['team_id']?.toString()  ?? '0') ?? 0;
        final goals = int.tryParse(r.assoc()['goals']?.toString()    ?? '-1') ?? -1;
        if (mid == 0 || tid == 0) continue;
        matchScores.putIfAbsent(mid, () => {});
        matchScores[mid]![tid] = goals;
      }

      // ── Load match_id per team pair from tbl_teamschedule ─────────────────
      final matchIdResult = await conn.execute("""
        SELECT ts.match_id, GROUP_CONCAT(ts.team_id ORDER BY ts.teamschedule_id) AS team_ids
        FROM tbl_teamschedule ts
        JOIN tbl_match m ON m.match_id = ts.match_id
        JOIN tbl_team  t ON t.team_id  = ts.team_id
        WHERE t.category_id = ${_soccerCategoryId}
          AND m.bracket_type = 'group'
        GROUP BY ts.match_id
      """);
      // Build: "teamId1_teamId2" → matchId (both orderings)
      final Map<String, int> pairToMatch = {};
      for (final r in matchIdResult.rows) {
        final mid   = int.tryParse(r.assoc()['match_id']?.toString() ?? '0') ?? 0;
        final ids   = (r.assoc()['team_ids']?.toString() ?? '').split(',');
        if (ids.length == 2) {
          pairToMatch['${ids[0]}_${ids[1]}'] = mid;
          pairToMatch['${ids[1]}_${ids[0]}'] = mid;
        }
      }

      // ── Reconstruct groups ────────────────────────────────────────────────
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
            final t1 = groupTeams[i];
            final t2 = groupTeams[j];
            final gm = GroupMatch(
              id:    'g${label}_m$matchIdx',
              team1: t1,
              team2: t2,
            );

            // Look up match_id for this pair
            final key     = '${t1.teamId}_${t2.teamId}';
            final matchId = pairToMatch[key];
            if (matchId != null) {
              gm.matchId = matchId;
              final scores = matchScores[matchId];
              if (scores != null) {
                final g1 = scores[t1.teamId] ?? -1;
                final g2 = scores[t2.teamId] ?? -1;
                // Only mark done if BOTH teams have scores
                if (g1 >= 0 && g2 >= 0) {
                  gm.score1  = g1;
                  gm.score2  = g2;
                  gm.winner  = g1 >= g2 ? t1 : t2;
                  // Update team stats — 3 pts for win, 1 pt each for draw, 0 for loss
                  if (g1 > g2) {
                    t1.wins++;   t1.points += 3;  // FIX: was +1
                    t2.losses++;
                  } else if (g2 > g1) {
                    t2.wins++;   t2.points += 3;  // FIX: was +1
                    t1.losses++;
                  } else {
                    t1.draws++; t1.points += 1;   // FIX: draws now give 1 pt each
                    t2.draws++; t2.points += 1;
                  }
                }
              }
            }

            matches.add(gm);
            matchIdx++;
          }
        }
        groups.add(TournamentGroup(label: label, teams: groupTeams, matches: matches));
      }

      if (mounted) {
        if (mounted) {
        setState(() {
          _groups          = groups;
          _groupsGenerated = groups.isNotEmpty &&
              _soccerScheduleRows.any((r) =>
                  (r['bracketType'] as String? ?? '') == 'group');
          // Reset auto-advance so it can fire again if schedule is regenerated
          if (!_groupsGenerated) _hasAutoAdvanced = false;
        });
      }
      }
    } catch (e) {
      print('_loadGroupsFromDB error: $e');
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
      // Query 1: matches WITH teams assigned (group stage + seeded KO matches)
      final result = await conn.execute("""
        SELECT
          m.match_id,
          m.bracket_type,
          TIME_FORMAT(s.schedule_start, '%H:%i') AS match_time,
          ts.arena_number,
          t.team_id,
          t.team_name,
          ts.teamschedule_id,
          COALESCE(sg.group_label, '?') AS group_label,
          (SELECT COUNT(*) FROM tbl_score sc2 WHERE sc2.match_id = m.match_id) AS score_count
        FROM tbl_match m
        JOIN tbl_schedule     s  ON s.schedule_id  = m.schedule_id
        JOIN tbl_teamschedule ts ON ts.match_id    = m.match_id
        JOIN tbl_team         t  ON t.team_id      = ts.team_id
        LEFT JOIN tbl_soccer_groups sg
               ON sg.team_id     = ts.team_id
              AND sg.category_id = ${_soccerCategoryId}
        WHERE t.category_id = ${_soccerCategoryId}
          AND m.bracket_type IN (
            'group','elimination','round-of-32','round-of-16','round-of-8',
            'quarter-finals','semi-finals','third-place','final'
          )
        ORDER BY s.schedule_start, m.match_id, ts.teamschedule_id
      """);

      // Query 2: knockout match slots with NO teams yet (so bracket renders even before seeding)
      final emptyKoResult = await conn.execute("""
        SELECT m.match_id, m.bracket_type,
               TIME_FORMAT(s.schedule_start, '%H:%i') AS match_time
        FROM tbl_match m
        JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
        WHERE m.bracket_type IN (
          'elimination','round-of-32','round-of-16','round-of-8',
          'quarter-finals','semi-finals','third-place','final'
        )
        AND m.match_id NOT IN (
          SELECT DISTINCT ts2.match_id FROM tbl_teamschedule ts2
          JOIN tbl_team t2 ON t2.team_id = ts2.team_id
          WHERE t2.category_id = ${_soccerCategoryId}
        )
        ORDER BY s.schedule_start, m.match_id
      """);

      final rows        = result.rows.map((r) => r.assoc()).toList();
      final emptyKoRows = emptyKoResult.rows.map((r) => r.assoc()).toList();
      // FIX: include empty KO slots in the signature so the bracket renders
      // the ELIM/QF/SF columns immediately after schedule generation — before
      // any teams are seeded — instead of waiting until teams appear (which
      // could be never if the early-return fires every tick).
      final sig = (rows + emptyKoRows)
          .map((r) => '${r['match_id']}_${r['score_count'] ?? 0}')
          .join('|');
      if (sig == _lastScheduleSig) return;
      _lastScheduleSig = sig;

      // Pivot: 2 rows per match_id → one entry with team1 + team2
      final Map<int, Map<String, dynamic>> byMatch = {};
      for (final row in rows) {
        final matchId = int.tryParse(row['match_id']?.toString() ?? '0') ?? 0;
        final teamId  = int.tryParse(row['team_id']?.toString()  ?? '0') ?? 0;
        if (matchId == 0 || teamId == 0) continue;

        final groupLabel = row['group_label']?.toString() ?? '?';
        final teamName   = row['team_name']?.toString() ?? '';
        final arenaNum   = int.tryParse(row['arena_number']?.toString() ?? '0') ?? 0;
        final rawBt = row['bracket_type']?.toString() ?? 'group';
        final bracketType = rawBt == 'group' ? 'group'
            : _ScheduleViewerState._normalizeBracketType(rawBt, 0);
        final matchTime  = row['match_time']?.toString() ?? '';

        byMatch.putIfAbsent(matchId, () => {
          'matchId':     matchId,
          'groupLabel':  groupLabel,
          'time':        matchTime,
          'team1':       '',
          'team2':       '',
          'team1Id':     0,
          'team2Id':     0,
          'arena':       arenaNum,
          'bracketType': bracketType,
          '_labels':     <String>[],  // collect both teams' labels
          'scoreCount':  int.tryParse(row['score_count']?.toString() ?? '0') ?? 0,
        });

        final entry  = byMatch[matchId]!;
        final labels = entry['_labels'] as List<String>;
        if (groupLabel != '?') labels.add(groupLabel);

        // Pick the most common label as the match's group
        if (labels.isNotEmpty) {
          final freq = <String, int>{};
          for (final l in labels) freq[l] = (freq[l] ?? 0) + 1;
          entry['groupLabel'] = freq.entries
              .reduce((a, b) => a.value >= b.value ? a : b)
              .key;
        }

        if ((entry['team1'] as String).isEmpty) {
          entry['team1']   = teamName;
          entry['team1Id'] = teamId;
          entry['arena']   = arenaNum;
          entry['bracketType'] = bracketType;
          entry['time']    = matchTime;
        } else if ((entry['team2'] as String).isEmpty) {
          entry['team2']   = teamName;
          entry['team2Id'] = teamId;
        }
      }

      // Add empty knockout slots so bracket tree renders before seeding
      // Track position within each time slot to assign correct arena number
      final Map<String, int> timeSlotCounter = {};
      for (final row in emptyKoRows) {
        final matchId = int.tryParse(row['match_id']?.toString() ?? '0') ?? 0;
        final rawBt   = row['bracket_type']?.toString() ?? '';
        final bt      = _ScheduleViewerState._normalizeBracketType(rawBt, 0);
        final time    = row['match_time']?.toString() ?? '';
        if (matchId == 0 || byMatch.containsKey(matchId)) continue;
        // Assign sequential arena number within same time slot
        final slotKey = '${bt}_${time}';
        timeSlotCounter[slotKey] = (timeSlotCounter[slotKey] ?? 0) + 1;
        final arenaNum = timeSlotCounter[slotKey]!;
        byMatch[matchId] = {
          'matchId':     matchId,
          'groupLabel':  '',
          'time':        time,
          'team1':       '',
          'team2':       '',
          'team1Id':     0,
          'team2Id':     0,
          'arena':       arenaNum,
          'bracketType': bt,
          '_labels':     <String>[],
        };
      }

      final scheduleRows = byMatch.values.toList()
        ..sort((a, b) {
          // Group rows first, then KO rows by time
          final btA = a['bracketType'] as String? ?? '';
          final btB = b['bracketType'] as String? ?? '';
          if (btA == 'group' && btB != 'group') return -1;
          if (btA != 'group' && btB == 'group') return 1;
          final tA = a['time'] as String? ?? '';
          final tB = b['time'] as String? ?? '';
          if (tA.isEmpty && tB.isEmpty) return 0;
          if (tA.isEmpty) return 1;
          if (tB.isEmpty) return -1;
          return tA.compareTo(tB);
        });

      if (mounted) {
        setState(() {
          _soccerScheduleRows = scheduleRows;
          // Mark groups generated if any group-stage rows exist
          if (scheduleRows.any((r) =>
              (r['bracketType'] as String? ?? '') == 'group')) {
            _groupsGenerated = true;
          }
        });
      }
    } catch (e) {
      debugPrint('⚠️ _loadSoccerSchedule error: $e');
    }
  }


  // ── Load knockout scores from DB ─────────────────────────────────────────
  Future<void> _loadKoScores() async {
    if (_soccerCategoryId == null) return;
    try {
      final scores = await DBHelper.getKnockoutScores(_soccerCategoryId!);
      if (mounted) setState(() => _koScores = scores);
    } catch (e) {
      debugPrint('_loadKoScores error: $e');
    }
  }

  void _setGroupMatchResult(GroupMatch match, GroupTeam winner, int s1, int s2) {
    final wasLoser1 = !match.isDone
        ? null
        : (match.winner == match.team1 ? match.team2 : match.team1);
    setState(() {
      if (match.isDone && wasLoser1 != null) {
        // Undo previous result — remove 3 pts from winner, not 1
        match.winner!.wins--;
        match.winner!.points -= 3;  // FIX: was -1, must be -3 to match 3-pt system
        wasLoser1.losses--;
      }
      match.winner = winner;
      match.score1 = s1;
      match.score2 = s2;
      final loser = winner == match.team1 ? match.team2 : match.team1;
      winner.wins++;
      winner.points += 3;  // FIX: was +1, must be +3 to match db_helper 3-pt system
      loser.losses++;
    });
  }

  List<GroupTeam> _getGroupStandings(TournamentGroup group) {
    final sorted = List<GroupTeam>.from(group.teams);
    sorted.sort((a, b) {
      // Primary: points (3 per win, 1 per draw)
      if (b.points != a.points) return b.points.compareTo(a.points);
      // Tiebreaker 1: head-to-head result
      for (final m in group.matches) {
        if (m.isDone) {
          if (m.team1 == a && m.team2 == b) return m.winner == a ? -1 : 1;
          if (m.team1 == b && m.team2 == a) return m.winner == b ? 1 : -1;
        }
      }
      // Tiebreaker 2: goal difference across all group matches
      final gdA = _calcGoalDiffInGroup(a, group);
      final gdB = _calcGoalDiffInGroup(b, group);
      if (gdB != gdA) return gdB.compareTo(gdA);
      // Tiebreaker 3: goals for across all group matches
      final gfA = _calcGoalsForInGroup(a, group);
      final gfB = _calcGoalsForInGroup(b, group);
      if (gfB != gfA) return gfB.compareTo(gfA);
      return a.teamName.compareTo(b.teamName);
    });
    return sorted;
  }

  int _calcGoalDiffInGroup(GroupTeam team, TournamentGroup group) {
    int gf = 0, ga = 0;
    for (final m in group.matches) {
      if (!m.isDone || m.score1 == null || m.score2 == null) continue;
      if (m.team1 == team) { gf += m.score1!; ga += m.score2!; }
      if (m.team2 == team) { gf += m.score2!; ga += m.score1!; }
    }
    return gf - ga;
  }

  int _calcGoalsForInGroup(GroupTeam team, TournamentGroup group) {
    int gf = 0;
    for (final m in group.matches) {
      if (!m.isDone || m.score1 == null || m.score2 == null) continue;
      if (m.team1 == team) gf += m.score1!;
      if (m.team2 == team) gf += m.score2!;
    }
    return gf;
  }

  List<GroupTeam> _getAdvancingTeams() {
    final result = <GroupTeam>[];
    for (final g in _groups) {
      final standings = _getGroupStandings(g);
      for (int i = 0; i < standings.length && i < 2; i++) {
        result.add(standings[i]);
      }
    }
    // Sort by overall standings: points → goal difference → goals for.
    // This must match the DB-side ranking in DBHelper.advanceToKnockout
    // so that the bracket preview always shows the correct BYE recipients.
    result.sort((a, b) {
      if (b.points != a.points) return b.points.compareTo(a.points);
      // Tiebreaker 1: goal difference (goals_for - goals_against)
      final gdA = _calcGoalDiff(a);
      final gdB = _calcGoalDiff(b);
      if (gdB != gdA) return gdB.compareTo(gdA);
      // Tiebreaker 2: goals for
      final gfA = _calcGoalsFor(a);
      final gfB = _calcGoalsFor(b);
      if (gfB != gfA) return gfB.compareTo(gfA);
      // Final fallback: alphabetical
      return a.teamName.compareTo(b.teamName);
    });
    return result;
  }

  /// Computes total goal difference for a team across all their group matches.
  int _calcGoalDiff(GroupTeam team) {
    int gf = 0, ga = 0;
    for (final g in _groups) {
      for (final m in g.matches) {
        if (!m.isDone || m.score1 == null || m.score2 == null) continue;
        if (m.team1 == team) { gf += m.score1!; ga += m.score2!; }
        if (m.team2 == team) { gf += m.score2!; ga += m.score1!; }
      }
    }
    return gf - ga;
  }

  /// Computes total goals for a team across all their group matches.
  int _calcGoalsFor(GroupTeam team) {
    int gf = 0;
    for (final g in _groups) {
      for (final m in g.matches) {
        if (!m.isDone || m.score1 == null || m.score2 == null) continue;
        if (m.team1 == team) gf += m.score1!;
        if (m.team2 == team) gf += m.score2!;
      }
    }
    return gf;
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ── BUILD PREVIEW SEEDS from group standings ──────────────────────────────
  // Always returns a list so bracket tab can show a preview at any time.
  // ════════════════════════════════════════════════════════════════════════════
  // ── Normalize bracket_type to canonical FIFA label ────────────────────────
  // Maps 'round-of-8' → 'quarter-finals', etc. based on match count
  // Also auto-detects what rounds should exist from group count
  static String _normalizeBracketType(String raw, int totalKoMatches) {
    // Always trust these exact labels
    const canonical = {
      'elimination', 'round-of-16', 'quarter-finals',
      'semi-finals', 'third-place', 'final',
    };
    if (canonical.contains(raw)) return raw;

    // round-of-16 from DB stays as round-of-16
    if (raw == 'round-of-32') return 'elimination';

    // Normalize legacy labels by team count implied by name
    if (raw == 'round-of-8') return 'quarter-finals';
    if (raw == 'round-of-4') return 'semi-finals';

    // Fallback: try to parse number from 'round-of-N'
    final m = RegExp(r'round-of-(\d+)').firstMatch(raw);
    if (m != null) {
      final n = int.tryParse(m.group(1) ?? '') ?? 0;
      if (n >= 32) return 'elimination';
      if (n == 16) return 'round-of-16';
      if (n == 8)  return 'quarter-finals';
      if (n == 4)  return 'semi-finals';
    }
    return raw;
  }

  // ── Bracket flow rules ───────────────────────────────────────────────────
  //
  //   BYE rule: ALWAYS only top 2 seeds (rank 1 & 2 overall) get a BYE
  //             when an ELIM round exists. Never more than 2 BYEs.
  //
  //   2 grp →  4 teams → SF(2)                    → 3RD → FINAL
  //   3 grp →  6 teams → ELIM(2, 2BYE) → SF(2)   → 3RD → FINAL  ★ no QF
  //   4 grp →  8 teams → QF(4)          → SF(2)   → 3RD → FINAL
  //   5 grp → 10 teams → ELIM(2, 2BYE) → QF(4) → SF(2) → 3RD → FINAL
  //   6 grp → 12 teams → ELIM(4, 2BYE) → QF(4) → SF(2) → 3RD → FINAL
  //   7 grp → 14 teams → ELIM(6, 2BYE) → QF(4) → SF(2) → 3RD → FINAL
  //   8 grp → 16 teams → QF(4)          → SF(2)   → 3RD → FINAL
  //
  //   Key for 3 groups: 6 teams, top 2 BYE to SF, bottom 4 play 2 ELIM
  //   matches → 2 ELIM winners join 2 BYE teams = 4 SF slots. QF skipped.
  //
  static List<String> _fifaRoundOrder(int numGroups, {int totalRegisteredTeams = 0}) {
    final rounds    = <String>[];
    final advancing = numGroups * 2; // top 2 per group advance

    if (advancing <= 4) {
      // 2 groups → 4 teams → SF directly
    } else if (advancing == 6) {
      // 3 groups → 6 teams → ELIM(2) → SF directly (NO QF)
      // Top 2 seeds BYE to SF; bottom 4 play 2 ELIM → 2 winners to SF
      rounds.add('elimination');
      // quarter-finals intentionally skipped
    } else if (advancing == 8) {
      // 4 groups → 8 teams → QF directly
      rounds.add('quarter-finals');
    } else if (advancing == 16) {
      // 8 groups → 16 teams → R16 → QF
      rounds.add('round-of-16'); 
      rounds.add('quarter-finals');   
    } else {
      // 5,6,7 groups → ELIM(top 2 BYE) → QF(4)
      rounds.add('elimination');
      rounds.add('quarter-finals');
    }

    rounds.add('semi-finals');
    rounds.add('third-place');
    rounds.add('final');
    return rounds;
  }

  // Real ELIM match count (matches actually played, excluding BYEs).
  //   3 grp: 6 advancing, 2 BYEs → 4 play ELIM → 2 matches → 2 winners to SF
  //   5 grp: 10 advancing, 2 BYEs → 8 play ELIM → need 4 for QF → 2 ELIM matches
  //   6 grp: 12 advancing, 2 BYEs → 10 play ELIM → need 4 for QF → 4 ELIM matches
  //   7 grp: 14 advancing, 2 BYEs → 12 play ELIM → need 4 for QF → 6 ELIM matches
  static int realElimMatches(int numGroups) {
    final advancing = numGroups * 2;
    if (advancing <= 4)  return 0; // SF direct
    if (advancing == 6)  return 2; // 3 grp: 4 teams play → 2 matches → 2 to SF
    if (advancing == 8)  return 0; // QF direct
    if (advancing == 16) return 0; // QF direct
    // 5,6,7 groups: top 2 BYE to QF; rest play ELIM to fill remaining QF slots
    // QF has 4 slots; 2 taken by BYEs; 2 winners needed from ELIM
    // ELIM matches = (advancing - 2) / 2 ... but we need exactly 2 QF spots
    // So ELIM real = (advancing - 2) - 2 = advancing - 4
    // i.e. the non-bye teams (advancing-2) play each other; winners (half) go to QF
    return (advancing - 2) ~/ 2; // winners = half of non-bye teams
  }

  // BYE count = always 2 (top 2 seeds) whenever an ELIM round exists.
  static int byeCount(int numGroups) {
    final advancing = numGroups * 2;
    if (advancing <= 4)  return 0; // SF direct, no ELIM
    if (advancing == 8)  return 0; // QF direct, no ELIM
    if (advancing == 16) return 0; // QF direct, no ELIM
    return 2; // top 2 seeds always BYE past ELIM
  }

  // Total ELIM slot count (real + bye) — kept for legacy callers.
  static int eliminationMatchCount(int advancing) {
    final ng = advancing ~/ 2;
    if (advancing <= 4)  return 0;
    if (advancing == 8)  return 0;
    if (advancing == 16) return 0;
    return realElimMatches(ng) + byeCount(ng);
  }

  static int _nextPow2(int n) {
    int p = 1;
    while (p < n) p <<= 1;
    return p;
  }

  List<BracketTeam> _buildPreviewSeeds() {
    if (_groupsGenerated) {
      return _getAdvancingTeams().asMap().entries.map((e) => BracketTeam(
            teamId:   e.value.teamId,
            teamName: e.value.teamName,
            seed:     e.key + 1,
          )).toList();
    }
    return [];
  }



  void _setPlayInResult(BracketMatch match, BracketTeam winner) {
    setState(() {
      match.winner = winner;
      match.loser  = winner.teamId == match.team1.teamId ? match.team2 : match.team1;
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
  // ── Advance to knockout state ────────────────────────────────────────────
  bool _isAdvancing        = false;
  bool _hasAutoAdvanced    = false; // prevents repeat group→KO advance
  bool _isSilentRefreshing = false; // prevents overlapping refresh calls
  bool _isKoChecking       = false; // prevents overlapping KO advance calls
  String _lastAdvancedRound = '';   // prevents repeated snackbar for same round
  bool _showBracketFlowInfo = false; // toggles "how does this work" panel
  bool _isLoadingData = false;

  // ── Auto-advance: fires once when groups finish and KO slots are ready ────
  void _checkAndAutoAdvance() {
    if (_hasAutoAdvanced) return;
    if (_soccerCategoryId == null) return;
    if (!_allGroupMatchesDone() || !_groupsGenerated) return;

    // Knockout slots exist (even empty ones) but no teams seeded yet → advance
    final koRows = _soccerScheduleRows
        .where((r) => (r['bracketType'] as String? ?? 'group') != 'group')
        .toList();
    final koHasTeams = koRows.any((r) =>
        (r['team1'] as String? ?? '').isNotEmpty ||
        (r['team2'] as String? ?? '').isNotEmpty);

    if (koRows.isNotEmpty && !koHasTeams) {
      _hasAutoAdvanced = true;
      _advanceToKnockout().catchError((_) {
        _hasAutoAdvanced = false; // retry on next refresh if it failed
      });
    } else if (koRows.isEmpty) {
      // KO slots not loaded yet — try again on next refresh
      // (slots appear once the schedule has been generated)
    }
  }
  
  // ── Reset knockout seeding and re-run with correct rankings ─────────────
  Future<void> _resetAndReseedKnockout() async {
    if (_soccerCategoryId == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF130742),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Reset Bracket Seeding',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text(
          'This will clear all knockout match assignments and re-seed the bracket '
          'using the correct overall standings (top 2 seeds get BYEs).\n\n'
          'Knockout scores will also be cleared. Continue?',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset & Re-seed',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _isAdvancing = true);
    try {
      await DBHelper.resetKnockoutSeeding(_soccerCategoryId!);
      _hasAutoAdvanced = false;
      _lastAdvancedRound = '';
      await _loadSoccerSchedule();
      await _loadKoScores();
      // Re-seed immediately
      await DBHelper.advanceToKnockout(_soccerCategoryId!);
      await _loadSoccerSchedule();
      await _loadKoScores();
      if (mounted) setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Bracket re-seeded! Top 2 seeds now have BYEs.',
              style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          backgroundColor: Color(0xFF00FF88),
          duration: Duration(seconds: 4),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e', style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.redAccent,
        ));
      }
    } finally {
      if (mounted) setState(() => _isAdvancing = false);
    }
  }

  Future<void> _advanceToKnockout() async {
    if (_soccerCategoryId == null) return;
    setState(() => _isAdvancing = true);
    try {
      // Delegate ALL group counts (including 3 groups) to DBHelper.
      await DBHelper.advanceToKnockout(_soccerCategoryId!);

      // Direct reload — bypass _isSilentRefreshing guard
      await _loadSoccerSchedule();
      await _loadKoScores();
      if (mounted) setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Teams advanced to knockout!',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          backgroundColor: Color(0xFF00FF88),
          duration: Duration(seconds: 3),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e',
              style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.redAccent,
        ));
      }
    } finally {
      if (mounted) setState(() => _isAdvancing = false);
    }
  }

  // ── Auto-advance through every knockout round until the Final ──────────────
  // Fires after each KO result. Once a full round is complete it seeds the
  // next round automatically.
  // For 3 groups: ELIM → SF directly (QF skipped).
  // For other group counts: follows the standard round order.
  Future<void> _checkAndAutoAdvanceKnockout() async {
    if (_isKoChecking) return;  // already running — skip
    if (_isAdvancing) return;   // manual advance in progress — skip
    if (_soccerCategoryId == null) return;
    _isKoChecking = true;
    // Dynamic round order: use _fifaRoundOrder so 3-group correctly skips QF
    final roundOrder = _fifaRoundOrder(_groups.isNotEmpty ? _groups.length : 3);
    try {
      final conn = await DBHelper.getConnection();
      for (final round in roundOrder) {
        // BUG FIX 3: removed backslash escaping so variables interpolate correctly
        final matchResult = await conn.execute("""
          SELECT m.match_id
          FROM tbl_match m
          JOIN tbl_teamschedule ts ON ts.match_id = m.match_id
          JOIN tbl_team t ON t.team_id = ts.team_id
          WHERE t.category_id = ${_soccerCategoryId}
            AND m.bracket_type = '$round'
          GROUP BY m.match_id HAVING COUNT(DISTINCT ts.team_id) = 2
        """);
        if (matchResult.rows.isEmpty) continue;
        final matchIds = matchResult.rows
            .map((r) => int.tryParse(r.assoc()['match_id']?.toString() ?? '0') ?? 0)
            .where((id) => id > 0).toList();
        final scoredResult = await conn.execute("""
          SELECT m.match_id, COUNT(DISTINCT sc.team_id) AS scored
          FROM tbl_match m JOIN tbl_score sc ON sc.match_id = m.match_id
          JOIN tbl_team t ON t.team_id = sc.team_id
          WHERE t.category_id = ${_soccerCategoryId} AND m.bracket_type = '$round'
          GROUP BY m.match_id
        """);
        final scoredIds = scoredResult.rows
            .where((r) => (int.tryParse(r.assoc()['scored']?.toString() ?? '0') ?? 0) >= 2)
            .map((r) => int.tryParse(r.assoc()['match_id']?.toString() ?? '0') ?? 0)
            .toSet();
        // Round not fully scored yet — stop here, don't check later rounds
        if (!matchIds.every((id) => scoredIds.contains(id))) break;
        final nextIdx = roundOrder.indexOf(round) + 1;
        if (nextIdx >= roundOrder.length) break;
        final nextRound = roundOrder[nextIdx];
        // Only skip if ALL matches in the next round are already FULL (2 teams each).
        // A simple count > 0 would wrongly block advancement when BYE teams are
        // pre-seeded (1 team per SF match) — ELIM winners would never fill TBD slots.
        final seededCheck = await conn.execute("""
          SELECT m.match_id, COUNT(ts.teamschedule_id) AS team_count
          FROM tbl_match m
          LEFT JOIN tbl_teamschedule ts ON ts.match_id = m.match_id
          LEFT JOIN tbl_team t ON t.team_id = ts.team_id
            AND t.category_id = ${_soccerCategoryId}
          WHERE m.bracket_type = '$nextRound'
          GROUP BY m.match_id
        """);
        final nextMatchCounts = seededCheck.rows
            .map((r) => int.tryParse(r.assoc()['team_count']?.toString() ?? '0') ?? 0)
            .toList();
        // FIX 3: Don't skip if next round has 2 teams but NO scores yet —
        // that means teams were seeded by championship_sched.dart (mobile app)
        // but scores haven't been entered yet. We should NOT block advancement.
        // Only skip if next round matches are ALREADY SCORED (have winners).
        final nextRoundScoredCheck = await conn.execute("""
          SELECT m.match_id, COUNT(DISTINCT sc.team_id) AS scored_teams
          FROM tbl_match m
          LEFT JOIN tbl_score sc ON sc.match_id = m.match_id
          LEFT JOIN tbl_team t ON t.team_id = sc.team_id
            AND t.category_id = ${_soccerCategoryId}
          WHERE m.bracket_type = '$nextRound'
          GROUP BY m.match_id
        """);
        final nextRoundScoredCounts = nextRoundScoredCheck.rows
            .map((r) => int.tryParse(r.assoc()['scored_teams']?.toString() ?? '0') ?? 0)
            .toList();
        // Only skip if ALL matches in next round are already fully scored (2 teams scored)
        final alreadyScored = nextRoundScoredCounts.isNotEmpty &&
            nextRoundScoredCounts.every((c) => c >= 2);
        if (alreadyScored) break;
        // Also skip if teams are already seeded AND this session already announced it
        final alreadySeeded = nextMatchCounts.isNotEmpty &&
            nextMatchCounts.every((c) => c >= 2);
        if (alreadySeeded) break;
        // Skip if we already announced this exact round advancement this session
        final advanceKey = '$round→$nextRound';
        if (_lastAdvancedRound == advanceKey) break;
        if (mounted) setState(() => _isAdvancing = true);
        for (final matchId in matchIds) {
          // FIX 4: use score_independentscore (goals scored) not score_totalscore
          // score_totalscore may be 0 for all teams in soccer — goals are in score_independentscore
          final scoreRows = await conn.execute("""
            SELECT sc.team_id, sc.score_independentscore AS goals
            FROM tbl_score sc JOIN tbl_team t ON t.team_id = sc.team_id
            WHERE sc.match_id = $matchId AND t.category_id = ${_soccerCategoryId}
            ORDER BY sc.score_independentscore DESC LIMIT 2
          """);
          if (scoreRows.rows.length < 2) continue;
          final rs = scoreRows.rows.map((r) => r.assoc()).toList();
          final g0 = int.tryParse(rs[0]['goals']?.toString() ?? '0') ?? 0;
          final g1 = int.tryParse(rs[1]['goals']?.toString() ?? '0') ?? 0;
          // Skip tied scores — knockout draw is invalid, admin must correct score
          if (g0 == g1) {
            debugPrint('⚠️ Tied KO score for match $matchId ($g0-$g1) — skipping');
            continue;
          }
          final winnerId = g0 > g1
              ? int.tryParse(rs[0]['team_id']?.toString() ?? '0') ?? 0
              : int.tryParse(rs[1]['team_id']?.toString() ?? '0') ?? 0;
          final loserId = g0 > g1
              ? int.tryParse(rs[1]['team_id']?.toString() ?? '0') ?? 0
              : int.tryParse(rs[0]['team_id']?.toString() ?? '0') ?? 0;
          if (winnerId == 0) continue;
          try {
            await DBHelper.advanceKnockoutWinner(
              matchId: matchId, winnerTeamId: winnerId,
              loserTeamId: loserId, categoryId: _soccerCategoryId!,
            );
          } catch (_) {}
        }
        await _loadSoccerSchedule();
        await _loadKoScores();
        if (mounted) setState(() {});
        _lastAdvancedRound = '$round→$nextRound';
        if (mounted) {
          final roundLabel = {
            'elimination': 'Play-in', 'quarter-finals': 'Quarter Finals',
            'semi-finals': 'Semi Finals', 'third-place': '3rd Place', 'final': 'Final',
          }[round] ?? round.toUpperCase();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
              '✅ $roundLabel complete — advancing to ${nextRound.toUpperCase()}!',
              style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
            ),
            backgroundColor: const Color(0xFF00FF88),
            duration: const Duration(seconds: 3),
          ));
        }
        break;
      }
    } catch (e) {
      debugPrint('_checkAndAutoAdvanceKnockout error: $e');
    } finally {
      _isKoChecking = false;
      if (mounted) setState(() => _isAdvancing = false);
    }
  }

  // ── Knockout match result dialog ─────────────────────────────────────────
  Future<void> _showKoMatchDialog(Map<String, dynamic> row) async {
    final matchId  = row['matchId']  as int? ?? 0;
    final team1    = row['team1']    as String? ?? '';
    final team2    = row['team2']    as String? ?? '';
    final team1Id  = row['team1Id']  as int? ?? 0;
    final team2Id  = row['team2Id']  as int? ?? 0;
    if (matchId == 0 || team1Id == 0 || team2Id == 0) return;

    final existing = _koScores[matchId] ?? {};
    int g1 = existing[team1Id] ?? 0;
    int g2 = existing[team2Id] ?? 0;

    final s1Ctrl = TextEditingController(text: '$g1');
    final s2Ctrl = TextEditingController(text: '$g2');

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF130742),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Set Match Result',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: Column(children: [
              Text(team1, textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 8),
              TextField(
                controller: s1Ctrl,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 22,
                    fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF1E0E50),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                          color: const Color(0xFF00FF88).withOpacity(0.4))),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                          color: const Color(0xFF00FF88).withOpacity(0.3))),
                ),
              ),
            ])),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('–', style: TextStyle(color: Colors.white38,
                  fontSize: 24, fontWeight: FontWeight.bold)),
            ),
            Expanded(child: Column(children: [
              Text(team2, textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 8),
              TextField(
                controller: s2Ctrl,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 22,
                    fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF1E0E50),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                          color: const Color(0xFF00FF88).withOpacity(0.4))),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                          color: const Color(0xFF00FF88).withOpacity(0.3))),
                ),
              ),
            ])),
          ]),
          const SizedBox(height: 12),
          const Text(
            'Winner advances to the next round automatically.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00FF88),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('CONFIRM', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (result != true) return;

    final goals1 = int.tryParse(s1Ctrl.text.trim()) ?? 0;
    final goals2 = int.tryParse(s2Ctrl.text.trim()) ?? 0;
    if (goals1 == goals2) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('⚠️ Draw not allowed in knockout — enter a decisive score.'),
        backgroundColor: Colors.orange,
      ));
      return;
    }

    final winnerTeamId = goals1 > goals2 ? team1Id : team2Id;
    final loserTeamId  = goals1 > goals2 ? team2Id : team1Id;

    // Get default referee id
    int refId = 1;
    try {
      final refResult = await DBHelper.getConnection().then(
          (c) => c.execute("SELECT referee_id FROM tbl_referee ORDER BY referee_id LIMIT 1"));
      if (refResult.rows.isNotEmpty) {
        refId = int.tryParse(
                refResult.rows.first.assoc()['referee_id']?.toString() ?? '1') ??
            1;
      }
    } catch (_) {}

    try {
      // Save scores
      await DBHelper.saveKnockoutScore(
          matchId: matchId, teamId: team1Id, goals: goals1, refereeId: refId);
      await DBHelper.saveKnockoutScore(
          matchId: matchId, teamId: team2Id, goals: goals2, refereeId: refId);

      // Advance winner (and loser to 3rd place if semi-final)
      await DBHelper.advanceKnockoutWinner(
        matchId:       matchId,
        winnerTeamId:  winnerTeamId,
        loserTeamId:   loserTeamId,
        categoryId:    _soccerCategoryId!,
      );

      await _silentRefresh();
      // Auto-advance if this round is now fully complete
      await _checkAndAutoAdvanceKnockout();

      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✅ Result saved! Winner advances to next round.',
            style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF00FF88),
        duration: const Duration(seconds: 3),
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error saving result: $e',
            style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.redAccent,
      ));
    }
  }

  Widget _buildBracketTab() {
    final koRows = _soccerScheduleRows
        .where((r) => (r['bracketType'] as String? ?? 'group') != 'group')
        .toList();
    final koHasTeams = koRows.any((r) =>
        (r['team1'] as String? ?? '').isNotEmpty ||
        (r['team2'] as String? ?? '').isNotEmpty);
    final advancing  = _getAdvancingTeams();
    final groupsDone = _allGroupMatchesDone() && _groupsGenerated;

    return Column(children: [
      // ── Bracket flow preview panel ───────────────────────────────────────
      Container(
        color: const Color(0xFF080518),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: _buildBracketFlowPreview(),
      ),

      // ── Status bar ──────────────────────────────────────────────────────
      Container(
        color: const Color(0xFF0D0826),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          if (_isAdvancing) ...[
            const SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2,
                    color: Color(0xFF00FF88))),
            const SizedBox(width: 10),
            const Text('Seeding knockout bracket…',
                style: TextStyle(color: Color(0xFF00FF88),
                    fontSize: 12, fontWeight: FontWeight.bold)),
          ] else ...[
            Icon(Icons.emoji_events,
                color: const Color(0xFFFFD700).withOpacity(0.7), size: 14),
            const SizedBox(width: 8),
            Expanded(child: Text(
              !groupsDone
                  ? 'Complete all group matches to unlock the bracket.'
                  : koHasTeams
                      ? 'Bracket live — top 2 per group advanced. Tap a match to enter scores.'
                      : koRows.isEmpty
                          ? 'Generating schedule… bracket will appear shortly.'
                          : 'Seeding teams into bracket…',
              style: TextStyle(
                  color: koHasTeams
                      ? const Color(0xFF00FF88)
                      : Colors.white.withOpacity(0.5),
                  fontSize: 12,
                  fontWeight: koHasTeams ? FontWeight.bold : FontWeight.normal),
            )),
            if (koHasTeams)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF00FF88).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF00FF88).withOpacity(0.3)),
                ),
                child: Text('${koRows.length} MATCHES',
                    style: const TextStyle(color: Color(0xFF00FF88),
                        fontSize: 10, fontWeight: FontWeight.bold)),
              ),
            // ── Reset & Re-seed button (always shown when groups are done) ──
            if (groupsDone) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _resetAndReseedKnockout,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.orange.withOpacity(0.5)),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.refresh, size: 11, color: Colors.orange),
                    SizedBox(width: 4),
                    Text('RESET BRACKET', style: TextStyle(
                        color: Colors.orange, fontSize: 10,
                        fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
            ],
          ],
        ]),
      ),

      // ── Bracket content ─────────────────────────────────────────────────
      Expanded(
        child: !groupsDone && advancing.isEmpty
            ? _bracketEmptyState()
            : !koHasTeams
                // Groups done but KO not seeded yet — show advancing teams preview
                ? _buildAdvancingPreview(advancing)
                : _buildFifaBracketCanvas(koRows, advancing),
      ),
    ]);
  }

  // ── Advancing teams preview — shown while KO is being seeded ─────────────
  Widget _buildAdvancingPreview(List<GroupTeam> advancing) {
    final grouped = <String, List<GroupTeam>>{};
    for (final g in _groups) {
      final standings = _getGroupStandings(g);
      grouped[g.label] = standings.take(2).toList();
    }
    final labels = grouped.keys.toList()..sort();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [Color(0xFF00FF88), Color(0xFF00CFAA)]),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.emoji_events, color: Colors.black, size: 18),
              SizedBox(width: 10),
              Text('TEAMS ADVANCING TO KNOCKOUT',
                  style: TextStyle(color: Colors.black, fontSize: 14,
                      fontWeight: FontWeight.w900, letterSpacing: 1.2)),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Group grid — top 2 per group
        ...labels.map((label) {
          final teams = grouped[label] ?? [];
          final gc    = _groupColor(label);
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF0F0A2A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: gc.withOpacity(0.35)),
            ),
            child: Column(children: [
              // Group header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: gc.withOpacity(0.12),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
                ),
                child: Row(children: [
                  Container(
                    width: 26, height: 26,
                    decoration: BoxDecoration(
                        color: gc.withOpacity(0.2),
                        shape: BoxShape.circle,
                        border: Border.all(color: gc, width: 1.5)),
                    child: Center(child: Text(label,
                        style: TextStyle(color: gc, fontSize: 12,
                            fontWeight: FontWeight.w900))),
                  ),
                  const SizedBox(width: 10),
                  Text('GROUP $label',
                      style: TextStyle(color: gc, fontSize: 13,
                          fontWeight: FontWeight.w800, letterSpacing: 0.8)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00FF88).withOpacity(0.08),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: const Color(0xFF00FF88).withOpacity(0.3)),
                    ),
                    child: const Text('TOP 2 ADVANCE',
                        style: TextStyle(color: Color(0xFF00FF88),
                            fontSize: 9, fontWeight: FontWeight.bold)),
                  ),
                ]),
              ),
              // Top 2 teams
              ...teams.asMap().entries.map((e) {
                final rank = e.key + 1;
                final t    = e.value;
                final isFirst = rank == 1;
                return Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: gc.withOpacity(0.15)),
                    ),
                  ),
                  child: Row(children: [
                    // Rank badge
                    Container(
                      width: 24, height: 24,
                      decoration: BoxDecoration(
                        color: isFirst
                            ? const Color(0xFFFFD700).withOpacity(0.15)
                            : Colors.white.withOpacity(0.06),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isFirst
                              ? const Color(0xFFFFD700).withOpacity(0.6)
                              : Colors.white24,
                        ),
                      ),
                      child: Center(child: Text('$rank',
                          style: TextStyle(
                            color: isFirst
                                ? const Color(0xFFFFD700)
                                : Colors.white54,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ))),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(t.teamName,
                        style: TextStyle(
                          color: isFirst ? Colors.white : Colors.white70,
                          fontSize: 14,
                          fontWeight: isFirst
                              ? FontWeight.w700 : FontWeight.w500,
                        ))),
                    // Stats chips
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      _statChip('PTS', '${t.points}',
                          const Color(0xFF00FF88)),
                      const SizedBox(width: 6),
                      _statChip('W', '${t.wins}', const Color(0xFF00CFFF)),
                      const SizedBox(width: 6),
                      _statChip('D', '${t.draws}', Colors.orange),
                      const SizedBox(width: 6),
                      _statChip('L', '${t.losses}', Colors.redAccent),
                    ]),
                    if (isFirst)
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Icon(Icons.arrow_forward_rounded,
                            color: Color(0xFF00FF88), size: 16),
                      ),
                  ]),
                );
              }),
            ]),
          );
        }),
      ]),
    );
  }

  Widget _statChip(String label, String value, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: color.withOpacity(0.08),
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: color.withOpacity(0.3)),
    ),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: TextStyle(color: color.withOpacity(0.7),
          fontSize: 8, fontWeight: FontWeight.bold)),
      Text(value, style: TextStyle(color: color,
          fontSize: 11, fontWeight: FontWeight.bold)),
    ]),
  );

  // ── Bracket flow preview — button only, toggles info panel ──────────────
  Widget _buildBracketFlowPreview() {
    final ng = _groups.isNotEmpty ? _groups.length : 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── HOW DOES THIS WORK? button ─────────────────────────────────
        Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onTap: () => setState(
                () => _showBracketFlowInfo = !_showBracketFlowInfo),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _showBracketFlowInfo
                    ? const Color(0xFF00CFFF).withOpacity(0.12)
                    : const Color(0xFF7B6AFF).withOpacity(0.10),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                    color: _showBracketFlowInfo
                        ? const Color(0xFF00CFFF).withOpacity(0.45)
                        : const Color(0xFF7B6AFF).withOpacity(0.4)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(
                  _showBracketFlowInfo
                      ? Icons.close
                      : Icons.help_outline_rounded,
                  size: 12,
                  color: _showBracketFlowInfo
                      ? const Color(0xFF00CFFF)
                      : const Color(0xFF7B6AFF),
                ),
                const SizedBox(width: 5),
                Text(
                  _showBracketFlowInfo
                      ? 'CLOSE'
                      : 'HOW DOES THIS WORK?',
                  style: TextStyle(
                    color: _showBracketFlowInfo
                        ? const Color(0xFF00CFFF)
                        : const Color(0xFF7B6AFF),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ]),
            ),
          ),
        ),

        // ── Info panel — shown when button is tapped ───────────────────
        if (_showBracketFlowInfo) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: _buildBracketInfoPanel(ng),
            ),
          ),
        ],
      ],
    );
  }

  // ── Dynamic bracket info panel — content based on current group count ────
  Widget _buildBracketInfoPanel(int ng) {
    // ── Per-group explanation data ──────────────────────────────────────────
    // Returns {flow, why, byeWho, diagram} specific to ng groups
    String _flow() {
      switch (ng) {
        case 2:  return 'GROUP STAGE  →  SF (2)  →  3RD  →  FINAL';
        case 3:  return 'GROUP STAGE  →  ELIM (2)  →  SF (2)  →  3RD  →  FINAL';
        case 4:  return 'GROUP STAGE  →  QF (4)  →  SF (2)  →  3RD  →  FINAL';
        case 5:  return 'GROUP STAGE  →  ELIM (2)  →  QF (4)  →  SF (2)  →  3RD  →  FINAL';
        case 6:  return 'GROUP STAGE  →  ELIM (4)  →  QF (4)  →  SF (2)  →  3RD  →  FINAL';
        case 7:  return 'GROUP STAGE  →  ELIM (6)  →  QF (4)  →  SF (2)  →  3RD  →  FINAL';
        case 8:  return 'GROUP STAGE  →  QF (4)  →  SF (2)  →  3RD  →  FINAL';
        case 9:  return 'GROUP STAGE  →  ELIM (2)  →  R16 (8)  →  QF (4)  →  SF (2)  →  3RD  →  FINAL';
        default: return 'GROUP STAGE  →  ELIM  →  ...  →  FINAL';
      }
    }

    String _why() {
      final adv = ng * 2;
      switch (ng) {
        case 2:
          return '$adv teams advance (top 2 per group). $adv fills SF directly — no elimination round needed.';
        case 3:
          return '$adv teams advance but the bracket needs 8 slots. Only 4 can fit QF, so 2 teams play ELIM first and 2 get BYEs straight to SF.';
        case 4:
          return '$adv teams advance and fills QF perfectly — 8 teams, 4 matches. No elimination round needed.';
        case 5:
          return '$adv teams advance but 10 doesn\'t fit QF (needs 8). Top 2 seeds BYE to QF; remaining 8 play 2 ELIM matches → 2 winners join the BYEs in QF.';
        case 6:
          return '$adv teams advance. 12 teams → 4 ELIM matches needed to reduce to 8 for QF. Top 2 seeds BYE to QF; remaining 10 play 4 ELIM matches → 4 winners join BYEs.';
        case 7:
          return '$adv teams advance. 14 teams → 6 ELIM matches to reduce to 8 for QF. Top 2 seeds BYE to QF; remaining 12 play 6 ELIM matches.';
        case 8:
          return '$adv teams advance and fills QF perfectly — 16 teams, 4 matches. No elimination round needed.';
        case 9:
          return '$adv teams advance. 18 teams → ELIM first to reduce, then R16 (8 matches), then QF → SF → FINAL.';
        default:
          return '$adv teams advance (top 2 per group). Bracket adjusts automatically.';
      }
    }

    String _byeWho() {
      final byes = byeCount(ng);
      if (byes == 0) return '';
      switch (ng) {
        case 3:
          return 'The top 2 teams by OVERALL standings (best points → goal difference → goals for across all groups) get BYEs directly into SF. The remaining 4 teams play 2 ELIM matches.';
        case 5:
          return 'Overall 1st and 2nd seeds (best records across all groups) get BYEs into QF. The remaining 8 teams play ELIM.';
        case 6:
          return 'Overall top 2 seeds get BYEs into QF. Remaining 10 teams play 4 ELIM matches.';
        case 7:
          return 'Overall top 2 seeds get BYEs into QF. Remaining 12 teams play 6 ELIM matches.';
        case 9:
          return 'Overall top 2 seeds get BYEs into R16. Remaining 16 teams play 2 ELIM matches.';
        default:
          return 'Top $byes seed${byes > 1 ? 's' : ''} (overall standings) advance directly, skipping the first knockout round.';
      }
    }

    // ── ASCII-style diagram per group count ─────────────────────────────────
    String _diagram() {
      switch (ng) {
        case 2:
          return
            'Group A (1st) ──┐\n'
            '                ├── SF Match 1 ──┐\n'
            'Group B (2nd) ──┘                ├── FINAL\n'
            'Group B (1st) ──┐                |\n'
            '                ├── SF Match 2 ──┘\n'
            'Group A (2nd) ──┘\n'
            '\nSF Losers → 3RD PLACE MATCH';
        case 3:
          return
            'Seed 3 (overall) ──┐\n'
            '                   ├── ELIM 1 ──┐\n'
            'Seed 4 (overall) ──┘            ├── SF Match 1 ──┐\n'
            'Seed 1 (overall) ── BYE ────────┘                ├── FINAL\n'
            'Seed 5 (overall) ──┐                             |\n'
            '                   ├── ELIM 2 ──┐                |\n'
            'Seed 6 (overall) ──┘            ├── SF Match 2 ──┘\n'
            'Seed 2 (overall) ── BYE ────────┘\n'
            '\nSF Losers → 3RD PLACE MATCH\n'
            '\n★ BYEs = top 2 by PTS → Goal Diff → Goals For';
        case 4:
          return
            'Group A (1st) ──┐\n'
            '                ├── QF 1 ──┐\n'
            'Group B (2nd) ──┘          ├── SF 1 ──┐\n'
            'Group C (1st) ──┐          |          ├── FINAL\n'
            '                ├── QF 2 ──┘          |\n'
            'Group D (2nd) ──┘          ┌── SF 2 ──┘\n'
            'Group B (1st) ──┐          |\n'
            '                ├── QF 3 ──┘\n'
            'Group A (2nd) ──┘\n'
            'Group D (1st) ──┐\n'
            '                ├── QF 4\n'
            'Group C (2nd) ──┘\n'
            '\nSF Losers → 3RD PLACE MATCH';
        case 5:
          return
            '── BYE ──────────────────────────────── QF slot 1\n'
            '(Overall 1st seed skips ELIM)\n'
            '── BYE ──────────────────────────────── QF slot 2\n'
            '(Overall 2nd seed skips ELIM)\n\n'
            'Remaining 8 teams play 2 ELIM matches:\n'
            'Team 3 ──┐\n'
            '         ├── ELIM 1 ──── QF slot 3\n'
            'Team 4 ──┘\n'
            'Team 5 ──┐\n'
            '         ├── ELIM 2 ──── QF slot 4\n'
            'Team 6 ──┘\n'
            '\nQF → SF → 3RD / FINAL';
        case 6:
          return
            '── BYE ──────────────────────────────── QF slot 1\n'
            '── BYE ──────────────────────────────── QF slot 2\n\n'
            'Remaining 10 teams play 4 ELIM matches:\n'
            'Team 3 ──┐\n'
            '         ├── ELIM 1 ──── QF slot 3\n'
            'Team 4 ──┘\n'
            'Team 5 ──┐\n'
            '         ├── ELIM 2 ──── QF slot 4\n'
            'Team 6 ──┘\n'
            'Team 7 ──┐\n'
            '         ├── ELIM 3 (extra, feeds QF)\n'
            'Team 8 ──┘\n'
            'Team 9 ──┐\n'
            '         ├── ELIM 4 (extra, feeds QF)\n'
            'Team 10 ─┘\n'
            '\nQF → SF → 3RD / FINAL';
        case 7:
          return
            '── BYE ──────────────────────────────── QF slot 1\n'
            '── BYE ──────────────────────────────── QF slot 2\n\n'
            'Remaining 12 teams play 6 ELIM matches → 6 winners\n'
            '(6 winners + 2 BYEs = 8 → fills QF)\n'
            '\nQF → SF → 3RD / FINAL';
        case 8:
          return
            'Group A (1st) ──┐\n'
            '                ├── QF 1 ──┐\n'
            'Group B (2nd) ──┘          ├── SF 1 ──┐\n'
            'Group C (1st) ──┐          |          ├── FINAL\n'
            '                ├── QF 2 ──┘          |\n'
            'Group D (2nd) ──┘          ┌── SF 2 ──┘\n'
            '... (8 QF matches total)   |\n'
            '\nSF Losers → 3RD PLACE MATCH';
        case 9:
          return
            '── BYE ──────────────────── R16 slot 1\n'
            '── BYE ──────────────────── R16 slot 2\n\n'
            'Remaining 16 teams play 2 ELIM matches:\n'
            'Team 3 ──┐\n'
            '         ├── ELIM 1 ──── R16 slot 3\n'
            'Team 4 ──┘\n'
            'Team 5 ──┐\n'
            '         ├── ELIM 2 ──── R16 slot 4\n'
            'Team 6 ──┘\n'
            '... (fills remaining R16 slots)\n'
            '\nR16 → QF → SF → 3RD / FINAL';
        default:
          return 'Top 2 per group advance. Bracket auto-adjusts.';
      }
    }

    final hasBye = byeCount(ng) > 0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF080418),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF3D1E88).withOpacity(0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── Title ──────────────────────────────────────────────────────
        Row(children: [
          const Icon(Icons.account_tree,
              color: Color(0xFF7B6AFF), size: 13),
          const SizedBox(width: 6),
          Text(
            'Bracket for $ng Group${ng == 1 ? '' : 's'}',
            style: const TextStyle(
                color: Color(0xFF7B6AFF),
                fontSize: 12, fontWeight: FontWeight.w900,
                letterSpacing: 0.5),
          ),
        ]),
        const SizedBox(height: 10),

        // ── Flow line ──────────────────────────────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF0F0A2A),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
                color: const Color(0xFF7B6AFF).withOpacity(0.2)),
          ),
          child: Text(_flow(),
              style: const TextStyle(
                  color: Color(0xFF9B85FF),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  height: 1.4)),
        ),
        const SizedBox(height: 10),

        // ── Why section ────────────────────────────────────────────────
        _infoSection(
          icon: Icons.lightbulb_outline,
          color: const Color(0xFFFF9F43),
          title: 'Why this flow?',
          body: _why(),
        ),

        // ── BYE section (only if applicable) ──────────────────────────
        if (hasBye) ...[
          const SizedBox(height: 8),
          _infoSection(
            icon: Icons.directions_run,
            color: const Color(0xFFFFD700),
            title: 'Who gets the BYE?',
            body: _byeWho(),
          ),
        ],
        const SizedBox(height: 10),

        // ── Diagram ────────────────────────────────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF04020F),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
                color: Colors.white.withOpacity(0.07)),
          ),
          child: Text(_diagram(),
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontFamily: 'monospace',
                  height: 1.6)),
        ),
      ]),
    );
  }

  Widget _infoSection({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
  }) =>
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.05),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Icon(icon, color: color, size: 13),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(title,
                  style: TextStyle(
                      color: color,
                      fontSize: 10,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(body,
                  style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                      height: 1.5)),
            ]),
          ),
        ]),
      );

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

    // Dynamic round order based on actual group count
    final numGroupsNow   = _groups.isNotEmpty ? _groups.length : 8;
    final advancingNow   = numGroupsNow * 2;
    final roundOrder     = _fifaRoundOrder(numGroupsNow, totalRegisteredTeams: _soccerTeams.length);
    final byes           = byeCount(numGroupsNow);
    final realMatches    = realElimMatches(numGroupsNow);
    final elimLabel      = (realMatches > 0)
        ? 'ELIM\n($realMatches matches\n$byes BYE)'
        : 'ELIM';
    final roundShort = {
      'elimination':    elimLabel,
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0A2A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF3D1E88).withOpacity(0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: phases.asMap().entries.expand((e) {
          final idx    = e.key;
          final phase  = e.value;
          final done   = phase['done'] as bool;
          final active = phase['active'] as bool;
          final label  = phase['label'] as String;

          final circleColor = done
              ? Colors.green
              : active
                  ? const Color(0xFF00CFFF)
                  : Colors.white24;

          final bgColor = done
              ? Colors.green.withOpacity(0.12)
              : active
                  ? const Color(0xFF00CFFF).withOpacity(0.12)
                  : Colors.white.withOpacity(0.03);

          return [
            Expanded(child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: bgColor,
                    border: Border.all(color: circleColor, width: 1.5),
                  ),
                  child: Center(child: done
                      ? Icon(Icons.check, color: Colors.green, size: 14)
                      : active
                          ? Container(width: 7, height: 7,
                              decoration: const BoxDecoration(
                                  color: Color(0xFF00CFFF),
                                  shape: BoxShape.circle))
                          : Text('${idx + 1}',
                              style: TextStyle(
                                  color: circleColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold))),
                ),
                const SizedBox(height: 4),
                Text(label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: circleColor,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        height: 1.2)),
              ],
            )),
            if (idx < phases.length - 1)
              Container(
                width: 20, height: 1.5,
                margin: const EdgeInsets.only(bottom: 18),
                color: done
                    ? Colors.green.withOpacity(0.4)
                    : Colors.white.withOpacity(0.1),
              ),
          ];
        }).toList(),
      ),
    );
  }

  // ── FIFA Bracket Canvas ───────────────────────────────────────────────────
  // ════════════════════════════════════════════════════════════════════════════
  // FIFA KNOCKOUT BRACKET — horizontal tree with connecting lines
  // Rounds flow left→right: R32 → R16 → QF → SF → FINAL
  // 3rd-place match shown below the semi-finals
  // ════════════════════════════════════════════════════════════════════════════
  // ════════════════════════════════════════════════════════════════════════════
  // FIFA KNOCKOUT BRACKET — proper horizontal tree with group labels
  // ════════════════════════════════════════════════════════════════════════════
  // ════════════════════════════════════════════════════════════════════════════
  // FIFA KNOCKOUT BRACKET — horizontal tree, all slots always rendered
  // ════════════════════════════════════════════════════════════════════════════
  Widget _buildFifaBracketCanvas(
      List<Map<String, dynamic>> koRows,
      List<GroupTeam> advancing) {

    // ── Round config ──────────────────────────────────────────────────────────
    // Derive round order dynamically from number of groups
    final numGroups = _groups.length > 0 ? _groups.length : 8;
    final roundOrder = _fifaRoundOrder(numGroups, totalRegisteredTeams: _soccerTeams.length)
        .where((r) => r != 'third-place').toList(); // 3rd shown separately

    final canvasNumGroups    = _groups.isNotEmpty ? _groups.length : 8;
    final canvasByes         = byeCount(canvasNumGroups);
    final canvasReal         = realElimMatches(canvasNumGroups);
    final elimCanvasLabel    = (canvasReal > 0)
        ? 'PLAY-IN\n($canvasReal matches\n$canvasByes BYE)'
        : 'ELIM';
    final roundLabels = {
      'elimination':    elimCanvasLabel,
      'quarter-finals': 'QF',
      'semi-finals':    'SF',
      'final':          'FINAL',
    };
    const roundColors = {
      'elimination':    Color(0xFF00CFFF),
      'quarter-finals': Color(0xFF00FF88),
      'semi-finals':    Color(0xFFFF9F43),
      'final':          Color(0xFFFFD700),
    };

    // ── Build teamGroup map from group stage ──────────────────────────────────
    final Map<int, String> teamGroup = {};
    for (final r in _soccerScheduleRows) {
      if ((r['bracketType'] as String? ?? '') == 'group') {
        final t1Id = r['team1Id'] as int? ?? 0;
        final t2Id = r['team2Id'] as int? ?? 0;
        final lbl  = r['groupLabel'] as String? ?? '';
        if (t1Id > 0 && lbl.isNotEmpty && lbl != '?') teamGroup[t1Id] = lbl;
        if (t2Id > 0 && lbl.isNotEmpty && lbl != '?') teamGroup[t2Id] = lbl;
      }
    }

    // ── Separate 3rd-place ────────────────────────────────────────────────────
    final thirdRows = koRows
        .where((r) => r['bracketType'] == 'third-place').toList();
    final mainRows  = koRows
        .where((r) => r['bracketType'] != 'third-place').toList();

    // ── Group rows by round ───────────────────────────────────────────────────
    final Map<String, List<Map<String, dynamic>>> byRound = {};
    for (final row in mainRows) {
      final bt = row['bracketType'] as String? ?? '';
      byRound.putIfAbsent(bt, () => []);
      byRound[bt]!.add(row);
    }

    // Determine active rounds (that exist in DB)
    final activeRounds = roundOrder
        .where((r) => byRound.containsKey(r))
        .toList();
    if (activeRounds.isEmpty) return _bracketEmptyState();

    // ── Figure out expected match counts per round ────────────────────────────
    // Use ACTUAL DB row counts per round — the halving formula breaks when BYEs
    // inflate later rounds beyond what simple halving predicts (e.g. 3 groups:
    // PLAY-IN=2 matches but SF=2 matches because 2 BYE teams also enter SF).
    final Map<String, int> expectedCount = {};
    for (final rk in activeRounds) {
      expectedCount[rk] = byRound[rk]!.length;
    }
    // Canvas height is driven by the round with the MOST matches (usually first)
    final int firstRoundMatches =
        activeRounds.map((r) => expectedCount[r]!).reduce((a, b) => a > b ? a : b);

    // ── Card dimensions ───────────────────────────────────────────────────────
    const double cardW  = 196.0;
    const double cardH  = 68.0;   // card only (no footer)
    const double footH  = 22.0;   // advancing footer
    const double slotH  = cardH + footH + 6.0; // total slot height per match
    const double gapH   = 52.0;

    // Total canvas height = round with most slots
    final double totalH  = firstRoundMatches * slotH;
    final double canvasW = activeRounds.length * (cardW + gapH);

    // ── Build positioned cards list ───────────────────────────────────────────
    List<Widget> cards = [];

    for (int ri = 0; ri < activeRounds.length; ri++) {
      final rk       = activeRounds[ri];
      final color    = roundColors[rk] ?? const Color(0xFF00CFFF);
      final isFinal  = rk == 'final';
      final matches  = byRound[rk]!;
      final expected = expectedCount[rk]!;
      final mySlotH  = totalH / expected;
      final leftPos  = ri.toDouble() * (cardW + gapH);

      for (int mi = 0; mi < expected; mi++) {
        // Get the actual row data (may be null/empty if not yet seeded)
        final row     = mi < matches.length ? matches[mi] : <String,dynamic>{};
        final team1   = row['team1']   as String? ?? '';
        final team2   = row['team2']   as String? ?? '';
        final team1Id = row['team1Id'] as int?    ?? 0;
        final team2Id = row['team2Id'] as int?    ?? 0;
        final matchId = row['matchId'] as int?    ?? 0;

        final scores   = matchId > 0 ? (_koScores[matchId] ?? {}) : {};
        final g1       = team1Id > 0 ? scores[team1Id] : null;
        final g2       = team2Id > 0 ? scores[team2Id] : null;
        final hasScore = g1 != null && g2 != null;
        final win1     = hasScore && g1! > g2!;
        final win2     = hasScore && g2! > g1!;
        final grp1     = team1Id > 0 ? (teamGroup[team1Id] ?? '') : '';
        final grp2     = team2Id > 0 ? (teamGroup[team2Id] ?? '') : '';

        final topPos   = mi * mySlotH + (mySlotH - slotH) / 2;

        cards.add(Positioned(
          left:   leftPos,
          top:    topPos,
          width:  cardW,
          height: slotH,
          child: GestureDetector(
            onTap: (team1.isNotEmpty && team2.isNotEmpty)
                ? () => _showKoMatchDialog(row)
                : null,
            child: _buildBracketCard(
              team1: team1, team2: team2,
              grp1:  grp1,  grp2:  grp2,
              goals1: g1,   goals2: g2,
              win1:  win1,  win2:  win2,
              color: color,
              isFinal: isFinal,
              hasScore: hasScore,
            ),
          ),
        ));
      }
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 32, 16),
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Round header pills ────────────────────────────────────────
            SizedBox(
              width: canvasW,
              child: Row(
                children: activeRounds.map((rk) {
                  final color  = roundColors[rk] ?? const Color(0xFF00CFFF);
                  final label  = roundLabels[rk]  ?? rk.toUpperCase();
                  final count  = expectedCount[rk] ?? 0;
                  return SizedBox(
                    width: cardW + gapH,
                    child: Center(
                      child: Column(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: color.withOpacity(0.5)),
                          ),
                          child: Text(label, style: TextStyle(
                              color: color, fontSize: 13,
                              fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                        ),
                        const SizedBox(height: 3),
                        Text('$count match${count == 1 ? '' : 'es'}',
                            style: TextStyle(color: color.withOpacity(0.5),
                                fontSize: 10)),
                      ]),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 12),

            // ── Bracket stack ─────────────────────────────────────────────
            SizedBox(
              width: canvasW,
              height: totalH,
              child: Stack(clipBehavior: Clip.none, children: [
                // Connector lines
                Positioned.fill(
                  child: CustomPaint(
                    painter: _FifaBracketLinePainter(
                      activeRounds: activeRounds,
                      expectedCount: expectedCount,
                      cardW:  cardW,
                      cardH:  slotH,
                      gapH:   gapH,
                      totalH: totalH,
                    ),
                  ),
                ),
                // All match cards
                ...cards,
              ]),
            ),

            // ── 3rd Place ─────────────────────────────────────────────────
            if (thirdRows.isNotEmpty) ...[
              const SizedBox(height: 24),
              Row(children: [
                const Icon(Icons.military_tech,
                    color: Color(0xFFCD7F32), size: 16),
                const SizedBox(width: 8),
                const Text('3RD PLACE MATCH',
                    style: TextStyle(color: Color(0xFFCD7F32),
                        fontSize: 12, fontWeight: FontWeight.w900,
                        letterSpacing: 1)),
              ]),
              const SizedBox(height: 8),
              ...thirdRows.map((row) {
                final team1   = row['team1']   as String? ?? '';
                final team2   = row['team2']   as String? ?? '';
                final team1Id = row['team1Id'] as int?    ?? 0;
                final team2Id = row['team2Id'] as int?    ?? 0;
                final matchId = row['matchId'] as int?    ?? 0;
                final scores  = matchId > 0 ? (_koScores[matchId] ?? {}) : {};
                final g1      = scores[team1Id];
                final g2      = scores[team2Id];
                final hasScore = g1 != null && g2 != null;
                final win1    = hasScore && g1! > g2!;
                final win2    = hasScore && g2! > g1!;
                return GestureDetector(
                  onTap: (team1.isNotEmpty && team2.isNotEmpty)
                      ? () => _showKoMatchDialog(row) : null,
                  child: SizedBox(
                    width: cardW,
                    height: slotH,
                    child: _buildBracketCard(
                      team1: team1, team2: team2,
                      grp1:  teamGroup[team1Id] ?? '',
                      grp2:  teamGroup[team2Id] ?? '',
                      goals1: g1,   goals2: g2,
                      win1:  win1,  win2:  win2,
                      color: const Color(0xFFCD7F32),
                      isFinal: false, hasScore: hasScore,
                    ),
                  ),
                );
              }),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ── Bracket match card ─────────────────────────────────────────────────────
  Widget _buildBracketCard({
    required String team1,  required String team2,
    required String grp1,   required String grp2,
    required int?   goals1, required int?   goals2,
    required bool   win1,   required bool   win2,
    required Color  color,
    required bool   isFinal,
    required bool   hasScore,
  }) {
    final hasTeams   = team1.isNotEmpty && team2.isNotEmpty;
    final winnerName = win1 ? team1 : win2 ? team2 : '';

    Widget teamSlot(String name, String grp, bool isWin, bool isLose,
        int? score) {
      final gc = grp.isNotEmpty ? _groupColor(grp) : Colors.transparent;
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: isWin
                ? const Color(0xFF00FF88).withOpacity(0.10)
                : isLose
                    ? Colors.black.withOpacity(0.15)
                    : Colors.transparent,
          ),
          child: Row(children: [
            // Group badge
            Container(
              width: 20, height: 20,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: grp.isNotEmpty
                    ? gc.withOpacity(isLose ? 0.06 : 0.18)
                    : Colors.white.withOpacity(0.04),
                shape: BoxShape.circle,
                border: Border.all(
                    color: grp.isNotEmpty
                        ? gc.withOpacity(isLose ? 0.15 : 0.6)
                        : Colors.white12,
                    width: 1),
              ),
              child: Center(child: Text(
                grp.isNotEmpty ? grp : '?',
                style: TextStyle(
                    color: grp.isNotEmpty
                        ? gc.withOpacity(isLose ? 0.25 : 1.0)
                        : Colors.white24,
                    fontSize: 9, fontWeight: FontWeight.w900),
              )),
            ),
            // Name
            Expanded(child: Text(
              name.isEmpty ? 'TBD' : name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: name.isEmpty ? Colors.white24
                    : isWin  ? const Color(0xFF00FF88)
                    : isLose ? Colors.white24
                    : Colors.white70,
                fontSize: 11,
                fontWeight: isWin ? FontWeight.w700 : FontWeight.w400,
              ),
            )),
            // Arrow for winner (non-final)
            if (isWin && !isFinal)
              const Icon(Icons.arrow_forward_ios_rounded,
                  color: Color(0xFF00FF88), size: 10),
            // Trophy for final winner
            if (isFinal && isWin)
              const Icon(Icons.emoji_events,
                  color: Color(0xFFFFD700), size: 13),
            // Score
            Container(
              width: 24, height: 20,
              alignment: Alignment.center,
              margin: const EdgeInsets.only(left: 4),
              decoration: BoxDecoration(
                color: hasScore
                    ? (isWin
                        ? const Color(0xFF00FF88).withOpacity(0.18)
                        : Colors.white.withOpacity(0.04))
                    : color.withOpacity(0.06),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: hasScore
                      ? (isWin
                          ? const Color(0xFF00FF88).withOpacity(0.4)
                          : Colors.white10)
                      : color.withOpacity(0.18),
                ),
              ),
              child: hasScore
                  ? Text('${score ?? '-'}',
                      style: TextStyle(
                          color: isWin
                              ? const Color(0xFF00FF88)
                              : Colors.white30,
                          fontSize: 11, fontWeight: FontWeight.bold))
                  : Icon(hasTeams ? Icons.touch_app : Icons.remove,
                      color: color.withOpacity(hasTeams ? 0.4 : 0.15),
                      size: 9),
            ),
          ]),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Card
      SizedBox(
        height: 68,
        child: Container(
          decoration: BoxDecoration(
            color: isFinal ? const Color(0xFF1A1200) : const Color(0xFF0C0820),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: hasScore
                  ? color.withOpacity(0.65)
                  : color.withOpacity(isFinal ? 0.60 : 0.28),
              width: isFinal ? 2 : 1,
            ),
          ),
          child: Column(children: [
            teamSlot(team1, grp1, win1, win2, goals1),
            Container(height: 1, color: color.withOpacity(0.18)),
            teamSlot(team2, grp2, win2, win1, goals2),
          ]),
        ),
      ),
      // Advancing footer
      if (hasScore && winnerName.isNotEmpty) ...[
        const SizedBox(height: 4),
        Container(
          height: 18,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: isFinal
                ? const Color(0xFFFFD700).withOpacity(0.07)
                : const Color(0xFF00FF88).withOpacity(0.07),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: isFinal
                  ? const Color(0xFFFFD700).withOpacity(0.3)
                  : const Color(0xFF00FF88).withOpacity(0.25),
            ),
          ),
          child: Row(children: [
            Icon(
              isFinal ? Icons.emoji_events : Icons.arrow_forward_rounded,
              color: isFinal
                  ? const Color(0xFFFFD700)
                  : const Color(0xFF00FF88),
              size: 10,
            ),
            const SizedBox(width: 4),
            Expanded(child: Text(
              isFinal ? '$winnerName  CHAMPION' : '$winnerName  advances',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isFinal
                    ? const Color(0xFFFFD700)
                    : const Color(0xFF00FF88),
                fontSize: 9, fontWeight: FontWeight.w700,
              ),
            )),
          ]),
        ),
      ] else ...[
        const SizedBox(height: 22), // placeholder height so slot stays consistent
      ],
    ]);
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

  // ── FIFA Full View: Group Stage tab + Knockout tab ──────────────────────────
  Widget _buildFifaFullView(
    List<Map<String, dynamic>> groupRows,
    List<Map<String, dynamic>> koRows, {
    required bool useSingleColumn,
  }) {
    final arenaSet   = groupRows.map((r) => (r['arena'] as int?) ?? 1).toSet();
    final arenaCount = arenaSet.isEmpty ? 1
        : arenaSet.reduce((a, b) => a > b ? a : b);

    return DefaultTabController(
      length: koRows.isEmpty ? 1 : 2,
      child: Column(children: [
        if (koRows.isNotEmpty)
          Container(
            color: const Color(0xFF0F0A2A),
            child: TabBar(
              indicatorColor: const Color(0xFF00FF88),
              indicatorWeight: 3,
              labelColor: const Color(0xFF00FF88),
              unselectedLabelColor: Colors.white38,
              labelStyle: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 12),
              tabs: const [
                Tab(text: '⚽  GROUP STAGE'),
                Tab(text: '🏆  KNOCKOUT'),
              ],
            ),
          ),
        Expanded(child: TabBarView(
          children: [
            _buildGroupScheduleView(groupRows, arenaCount, useSingleColumn),
            if (koRows.isNotEmpty)
              _buildKnockoutView(koRows),
          ],
        )),
      ]),
    );
  }

  // ── Group schedule: side-by-side arenas ──────────────────────────────────
  Widget _buildGroupScheduleView(
      List<Map<String, dynamic>> rows, int arenaCount, bool singleColumn) {

    if (rows.isEmpty) {
      return Center(child: Text('No group matches yet.',
          style: TextStyle(color: Colors.white.withOpacity(0.3))));
    }

    if (singleColumn || arenaCount <= 1) {
      return _buildSingleArenaList(rows);
    }

    // Re-number arenas sequentially per slot (no gaps)
    final Map<String, List<Map<String, dynamic>>> byTimeList = {};
    for (final row in rows) {
      final time = (row['time'] as String).isNotEmpty
          ? row['time'] as String : '__notime__';
      byTimeList.putIfAbsent(time, () => []);
      byTimeList[time]!.add(row);
    }
    for (final list in byTimeList.values) {
      list.sort((a, b) =>
          ((a['arena'] as int?) ?? 1).compareTo((b['arena'] as int?) ?? 1));
    }
    final Map<String, Map<int, Map<String, dynamic>>> byTime = {};
    for (final entry in byTimeList.entries) {
      byTime[entry.key] = {};
      for (int i = 0; i < entry.value.length; i++) {
        byTime[entry.key]![i + 1] = entry.value[i];
      }
    }
    final slots = byTime.keys.toList()
      ..sort((a, b) {
        if (a == '__notime__') return 1;
        if (b == '__notime__') return -1;
        return a.compareTo(b);
      });

    final maxMatchesInSlot = byTime.values
        .map((s) => s.length).fold(0, (a, b) => a > b ? a : b);
    final usedArenas   = List.generate(maxMatchesInSlot, (i) => i + 1);
    final headerArenas = usedArenas;

    return Column(children: [
      // Arena header row
      Container(
        decoration: const BoxDecoration(
            gradient: LinearGradient(
                colors: [Color(0xFF4A22AA), Color(0xFF3A1880)])),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(children: [
          const SizedBox(width: 28),
          const SizedBox(width: 54, child: Text('TIME',
              style: TextStyle(color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 12, letterSpacing: 0.8))),
          ...headerArenas.map((a) => Expanded(child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFFFFD700).withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: const Color(0xFFFFD700).withOpacity(0.4)),
            ),
            child: Center(child: Text('ARENA $a',
                style: const TextStyle(color: Color(0xFFFFD700),
                    fontSize: 11, fontWeight: FontWeight.w900,
                    letterSpacing: 1))),
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
                color: isEven
                    ? const Color(0xFF160C40)
                    : const Color(0xFF100830),
                border: const Border(
                    bottom: BorderSide(
                        color: Color(0xFF1A1050), width: 1)),
              ),
              padding: const EdgeInsets.symmetric(
                  vertical: 6, horizontal: 16),
              child: IntrinsicHeight(child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(width: 28, child: Center(child: Text(
                      '${idx + 1}',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.3),
                          fontSize: 13,
                          fontWeight: FontWeight.bold)))),
                  SizedBox(width: 54, child: Text(displayTime,
                      style: TextStyle(
                          color: displayTime == '—'
                              ? Colors.white.withOpacity(0.2)
                              : const Color(0xFF00CFFF),
                          fontSize: 13,
                          fontWeight: FontWeight.w600))),
                  ...headerArenas.map((a) {
                    final row = slotMatches[a];
                    if (row == null) {
                      return Expanded(child: Container(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.01),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: Colors.white.withOpacity(0.03),
                              width: 1),
                        ),
                        child: Center(child: Text('—',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.1),
                                fontSize: 11))),
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
                    final scoreCount = (row['scoreCount'] as int?) ?? 0;
                    final isDone = scoreCount >= 2 || (gm?.isDone ?? false);
                    final t1Wins = isDone && gm?.winner == gm?.team1;
                    final t2Wins = isDone && gm?.winner == gm?.team2;

                    return Expanded(child: GestureDetector(
                      onTap: null,
                      child: Container(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 4),
                        decoration: BoxDecoration(
                          color: isDone
                              ? const Color(0xFF0A1A0E)
                              : gc.withOpacity(0.07),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: isDone
                                  ? Colors.green.withOpacity(0.4)
                                  : gc.withOpacity(0.35),
                              width: 1.5),
                        ),
                        child: Column(mainAxisSize: MainAxisSize.min,
                            children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: gc.withOpacity(0.18),
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(8)),
                            ),
                            child: Center(child: Text('G$groupLabel',
                                style: TextStyle(color: gc,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900))),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 8),
                            child: isDone
                                ? const Center(child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.check_circle,
                                          color: Colors.green, size: 14),
                                      SizedBox(width: 6),
                                      Text('DONE', style: TextStyle(
                                          color: Colors.green,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 1)),
                                    ]))
                                : Row(children: [
                                    Expanded(child: Text(
                                        team1.isNotEmpty ? team1 : '—',
                                        textAlign: TextAlign.right,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight:
                                                FontWeight.w600))),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF00CFFF)
                                              .withOpacity(0.1),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          border: Border.all(
                                              color:
                                                  const Color(0xFF00CFFF)
                                                      .withOpacity(0.3)),
                                        ),
                                        child: const Text('vs',
                                            style: TextStyle(
                                                color: Color(0xFF00CFFF),
                                                fontSize: 10,
                                                fontWeight:
                                                    FontWeight.bold))),
                                    ),
                                    Expanded(child: Text(
                                        team2.isNotEmpty ? team2 : '—',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight:
                                                FontWeight.w600))),
                                  ]),
                          ),
                          GestureDetector(
                            onTap: !isDone && gm != null
                                ? () {
                                    final key = _statusKey(
                                        _soccerCategoryId ?? 0,
                                        gm!.matchId ?? 0);
                                    final cur = _statusMap[key] ??
                                        MatchStatus.pending;
                                    setState(() {
                                      _statusMap[key] = cur ==
                                              MatchStatus.pending
                                          ? MatchStatus.inProgress
                                          : MatchStatus.pending;
                                    });
                                  }
                                : null,
                            child: Builder(builder: (_) {
                              final key = _statusKey(
                                  _soccerCategoryId ?? 0,
                                  gm?.matchId ?? 0);
                              final st = isDone
                                  ? MatchStatus.done
                                  : (_statusMap[key] ??
                                      MatchStatus.pending);
                              if (st == MatchStatus.inProgress) {
                                return Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF00CFFF)
                                        .withOpacity(0.07),
                                    borderRadius:
                                        const BorderRadius.vertical(
                                            bottom: Radius.circular(8)),
                                  ),
                                  child: const Center(
                                      child: _BouncingSoccerBall()),
                                );
                              }
                              return Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 3),
                                decoration: BoxDecoration(
                                  color: st == MatchStatus.done
                                      ? Colors.green.withOpacity(0.08)
                                      : Colors.white.withOpacity(0.03),
                                  borderRadius:
                                      const BorderRadius.vertical(
                                          bottom: Radius.circular(8)),
                                ),
                                child: Center(
                                    child: st == MatchStatus.done
                                        ? const Row(
                                            mainAxisSize:
                                                MainAxisSize.min,
                                            children: [
                                              Icon(Icons.check_circle,
                                                  color: Colors.green,
                                                  size: 10),
                                              SizedBox(width: 4),
                                              Text('Done',
                                                  style: TextStyle(
                                                      color: Colors.green,
                                                      fontSize: 9,
                                                      fontWeight:
                                                          FontWeight.bold)),
                                            ])
                                        : Text('Tap to go live',
                                            style: TextStyle(
                                                color: Colors.white
                                                    .withOpacity(0.2),
                                                fontSize: 9,
                                                fontWeight:
                                                    FontWeight.bold))),
                              );
                            }),
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
    // Dynamic round order based on actual group count
    final koNumGroups  = _groups.isNotEmpty ? _groups.length : 8;
    final roundOrder   = _fifaRoundOrder(koNumGroups, totalRegisteredTeams: _soccerTeams.length);
    final koReal       = realElimMatches(koNumGroups);
    final koByes       = byeCount(koNumGroups);
    final elimKoLabel  = koReal > 0
        ? 'ELIMINATION (${koReal} matches, ${koByes} BYE)'
        : 'ELIMINATION';
    final roundLabels = {
      'elimination':    elimKoLabel,
      'round-of-16':    'ROUND OF 16',
      'quarter-finals': 'QUARTER FINALS',
      'semi-finals':    'SEMI FINALS',
      'third-place':    '3RD PLACE',
      'final':          'FINAL',
    };
    const roundColors = {
      'elimination':    Color(0xFF00CFFF),
      'round-of-16':    Color(0xFF00CFFF),
      'quarter-finals': Color(0xFF00FF88),
      'semi-finals':    Color(0xFFFF9F43),
      'third-place':    Color(0xFFCD7F32),
      'final':          Color(0xFFFFD700),
    };

    final Map<String, List<Map<String, dynamic>>> byRound = {};
    for (final row in koRows) {
      final bt = row['bracketType'] as String? ?? '';
      byRound.putIfAbsent(bt, () => []);
      byRound[bt]!.add(row);
    }
    final rounds = roundOrder.where((r) => byRound.containsKey(r)).toList();

    if (rounds.isEmpty) {
      return Center(child: Text('Knockout matches will appear after group stage.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 14)));
    }

    return ListView(
      padding: EdgeInsets.zero,
      children: rounds.map((roundKey) {
        final roundLabel  = roundLabels[roundKey] ?? roundKey.toUpperCase();
        final accentColor = roundColors[roundKey] ?? const Color(0xFF00CFFF);
        final matches     = byRound[roundKey]!;
        // Sort by time then matchId
        matches.sort((a, b) {
          final ta = a['time'] as String? ?? '';
          final tb = b['time'] as String? ?? '';
          if (ta != tb) return ta.compareTo(tb);
          return ((a['matchId'] as int?) ?? 0)
              .compareTo((b['matchId'] as int?) ?? 0);
        });

        // Group by time slot, then chunk into rows of max 2 arenas each.
        // This ensures QF (4 matches) shows as 2 rows of 2 instead of
        // 1 row of 3 + 1 row of 1 when 3 matches share the same time.
        const int maxArenasPerRow = 2;
        final Map<String, List<Map<String, dynamic>>> byTimeMap = {};
        for (final m in matches) {
          final t = (m['time'] as String? ?? '').isNotEmpty
              ? m['time'] as String : '__notime__';
          byTimeMap.putIfAbsent(t, () => []);
          byTimeMap[t]!.add(m);
        }
        final sortedTimeKeys = byTimeMap.keys.toList()
          ..sort((a, b) {
            if (a == '__notime__') return 1;
            if (b == '__notime__') return -1;
            return a.compareTo(b);
          });
        // Flatten into rows of max maxArenasPerRow
        final List<List<Map<String, dynamic>>> rows = [];
        final List<String> timeKeys = [];
        for (final t in sortedTimeKeys) {
          final slotMatches = byTimeMap[t]!;
          for (int i = 0; i < slotMatches.length; i += maxArenasPerRow) {
            final chunk = slotMatches.sublist(
                i, (i + maxArenasPerRow).clamp(0, slotMatches.length));
            rows.add(chunk);
            timeKeys.add(t);
          }
        }

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── Round header ──────────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                accentColor.withOpacity(0.18), accentColor.withOpacity(0.04),
              ]),
              border: Border(
                top:    BorderSide(color: accentColor.withOpacity(0.4)),
                bottom: BorderSide(color: accentColor.withOpacity(0.2)),
              ),
            ),
            child: Row(children: [
              Icon(
                roundKey == 'final' ? Icons.emoji_events
                    : roundKey == 'third-place' ? Icons.military_tech
                    : Icons.sports_soccer,
                color: accentColor, size: 16),
              const SizedBox(width: 10),
              Text(roundLabel, style: TextStyle(
                  color: accentColor, fontSize: 13,
                  fontWeight: FontWeight.w900, letterSpacing: 1.2)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accentColor.withOpacity(0.3)),
                ),
                child: Text(
                  '${matches.length} match${matches.length != 1 ? "es" : ""}',
                  style: TextStyle(color: accentColor,
                      fontSize: 10, fontWeight: FontWeight.bold)),
              ),
            ]),
          ),

          // ── Arena headers (based on max matches per row) ──────────────
          Container(
            color: const Color(0xFF080618),
            padding: const EdgeInsets.fromLTRB(86, 6, 16, 6),
            child: Row(
              children: List.generate(
                  rows.isEmpty ? 0 : rows.map((r) => r.length).reduce((a,b) => a>b?a:b), (a) =>
                Expanded(child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: accentColor.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: accentColor.withOpacity(0.3)),
                  ),
                  child: Center(child: Text('ARENA ${a + 1}',
                      style: TextStyle(color: accentColor,
                          fontSize: 10, fontWeight: FontWeight.w900,
                          letterSpacing: 0.8))),
                )),
              ),
            ),
          ),

          // ── Match rows (each row = up to perRow matches) ──────────────
          ...rows.asMap().entries.map((rowEntry) {
            final rowIdx     = rowEntry.key;
            final rowMatches = rowEntry.value;
            final isEven     = rowIdx % 2 == 0;

            // Time = the time key for this slot
            final rowTime = timeKeys[rowIdx] == '__notime__'
                ? '' : timeKeys[rowIdx];

            return Container(
              decoration: BoxDecoration(
                color: isEven
                    ? const Color(0xFF0C0825)
                    : const Color(0xFF080618),
                border: const Border(
                    bottom: BorderSide(color: Color(0xFF140E38), width: 1)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Row number
                SizedBox(width: 28,
                  child: Center(child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('${rowIdx + 1}',
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.3),
                            fontSize: 12, fontWeight: FontWeight.bold)),
                  )),
                ),
                // Time
                SizedBox(width: 58,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      rowTime.isNotEmpty ? rowTime : '—',
                      style: TextStyle(
                          color: rowTime.isNotEmpty
                              ? const Color(0xFF00CFFF) : Colors.white24,
                          fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                // Match cards
                ...rowMatches.map((row) {
                  final team1   = row['team1']   as String? ?? '';
                  final team2   = row['team2']   as String? ?? '';
                  final team1Id = row['team1Id'] as int?    ?? 0;
                  final team2Id = row['team2Id'] as int?    ?? 0;
                  final matchId = row['matchId'] as int?    ?? 0;
                  final scores  = _koScores[matchId] ?? {};
                  final g1      = scores[team1Id];
                  final g2      = scores[team2Id];
                  final hasScore = g1 != null && g2 != null;
                  final win1    = hasScore && g1! > g2!;
                  final win2    = hasScore && g2! > g1!;

                  return Expanded(child: GestureDetector(
                    onTap: (team1.isNotEmpty && team2.isNotEmpty)
                        ? () => _showKoMatchDialog(row) : null,
                    child: Container(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 3, vertical: 2),
                      decoration: BoxDecoration(
                        color: hasScore
                            ? const Color(0xFF0A1A0E)
                            : const Color(0xFF0F0A2A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: hasScore
                              ? Colors.green.withOpacity(0.4)
                              : accentColor.withOpacity(0.3),
                          width: 1.5,
                        ),
                      ),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        // Round badge
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: accentColor.withOpacity(0.15),
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(8)),
                          ),
                          child: Center(child: Text(roundLabel,
                              style: TextStyle(color: accentColor,
                                  fontSize: 10, fontWeight: FontWeight.w900))),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 8),
                          child: hasScore
                              ? const Center(child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.check_circle,
                                        color: Colors.green, size: 14),
                                    SizedBox(width: 6),
                                    Text('DONE',
                                        style: TextStyle(
                                            color: Colors.green,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: 1)),
                                  ]))
                              : Row(children: [
                                  Expanded(child: Text(
                                    team1.isEmpty ? 'TBD' : team1,
                                    textAlign: TextAlign.right,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: team1.isEmpty
                                            ? Colors.white24
                                            : Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600),
                                  )),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 5, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: accentColor.withOpacity(0.1),
                                        borderRadius:
                                            BorderRadius.circular(4),
                                        border: Border.all(
                                            color: accentColor
                                                .withOpacity(0.3)),
                                      ),
                                      child: Text('vs',
                                          style: TextStyle(
                                              color: accentColor,
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold))),
                                  ),
                                  Expanded(child: Text(
                                    team2.isEmpty ? 'TBD' : team2,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: team2.isEmpty
                                            ? Colors.white24
                                            : Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600),
                                  )),
                                ]),
                        ),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.03),
                            borderRadius: const BorderRadius.vertical(
                                bottom: Radius.circular(8)),
                          ),
                          child: Center(child: Text(
                            team1.isEmpty || team2.isEmpty ? 'TBD' : 'Pending',
                            style: TextStyle(
                                color: team1.isEmpty || team2.isEmpty
                                    ? Colors.white12 : Colors.white24,
                                fontSize: 9,
                                fontWeight: FontWeight.bold))),
                        ),
                      ]),
                    ),
                  ));
                }),
                // Pad remaining columns if this row has fewer than max
                ...List.generate(
                    rows.map((r) => r.length).reduce((a,b) => a>b?a:b) - rowMatches.length,
                    (_) => Expanded(child: Container(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 3, vertical: 2),
                      height: 90,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ))),
              ]),
            );
          }),
          const SizedBox(height: 4),
        ]);
      }).toList(),
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
              onTap: null,
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
                    onTap: null,
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
            child: status == MatchStatus.inProgress
                ? const _BouncingSoccerBall()
                : Container(
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
          // Groups are fixed when schedule is generated — use Generate Schedule to change
          if (_groupsGenerated)
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.08),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.green.withOpacity(0.3), width: 1),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: const [
                Icon(Icons.lock_rounded, color: Colors.green, size: 13),
                SizedBox(width: 7),
                Text('Groups locked — regenerate from Schedule page',
                    style: TextStyle(color: Colors.green, fontSize: 11,
                        fontWeight: FontWeight.bold)),
              ]),
            )
          else if (!canGenerate)
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
            ),
        ]),
      ),
      if (!_groupsGenerated)
        Expanded(child: _buildGroupsEmptyState(teamCount, canGenerate))
      else
        Expanded(child: Column(children: [
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
              ? '$teamCount teams · ${_groupSplitLabel(teamCount)}\nGenerate from the Generate Schedule page.'
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
                onPressed: () async {
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
        border: Border(bottom: BorderSide(color: Color(0xFF3D1E88), width: 1)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Left: ROBOVENTURE label ──────────────────────────────
          const Text('ROBOVENTURE',
              style: TextStyle(color: Colors.white30, fontSize: 13,
                  fontWeight: FontWeight.bold, letterSpacing: 2)),
          // ── Center: Category title ───────────────────────────────
          Expanded(
            child: Center(
              child: Text(title,
                  style: const TextStyle(color: Colors.white, fontSize: 24,
                      fontWeight: FontWeight.w900, letterSpacing: 3)),
            ),
          ),
          // ── Right: LIVE + Standings + Back ───────────────────────
          _buildLiveIndicator(),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'View Standings',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 22),
            onPressed: widget.onStandings,
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Back to Home',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: const Icon(Icons.arrow_back_ios_new, color: Color(0xFF00CFFF), size: 22),
            onPressed: widget.onBack,
          ),
        ],
      ),
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
      child: Column(
        children: [
          // ── Logo pill bar ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 0),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topCenter,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.08), width: 1.0),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F0FA),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF00CFFF).withOpacity(0.50), width: 1.5),
                          boxShadow: [
                            BoxShadow(color: const Color(0xFF00CFFF).withOpacity(0.30), blurRadius: 20, spreadRadius: 2),
                            BoxShadow(color: const Color(0xFF7B2FFF).withOpacity(0.25), blurRadius: 28, spreadRadius: 1),
                          ],
                        ),
                        child: Image.asset('assets/images/RoboventureLogo.png', height: 36, fit: BoxFit.contain),
                      ),
                      const SizedBox(width: 80),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F0FA),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF00CFFF).withOpacity(0.50), width: 1.5),
                          boxShadow: [
                            BoxShadow(color: const Color(0xFF00CFFF).withOpacity(0.30), blurRadius: 20, spreadRadius: 2),
                            BoxShadow(color: const Color(0xFF7B2FFF).withOpacity(0.25), blurRadius: 28, spreadRadius: 1),
                          ],
                        ),
                        child: Image.asset('assets/images/CreotecLogo.png', height: 36, fit: BoxFit.contain),
                      ),
                    ],
                  ),
                ),
                // ── Floating CenterLogo ───────────────────────────
                Positioned(
                  top: -30,
                  left: 0, right: 0,
                  child: Center(
                    child: Image.asset(
                      'assets/images/CenterLogo.png',
                      height: 80,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
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
    // FIFA phases: Group Stage → Knockout rounds (tracked via DB bracket_type)
    final koRows = _soccerScheduleRows
        .where((r) => (r['bracketType'] as String? ?? 'group') != 'group')
        .toList();
    final koHasTeams = koRows.any((r) =>
        (r['team1'] as String? ?? '').isNotEmpty);
    final phases = [
      ('GROUP\nSTAGE', _groupsGenerated && _allGroupMatchesDone()),
      ('KNOCKOUT',      koHasTeams),
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


// ════════════════════════════════════════════════════════════════════════════
// ROUND INFO — helper for bracket flow preview
// ════════════════════════════════════════════════════════════════════════════
class _RoundInfo {
  final String label;
  final int    matches;
  final int    byes;
  final Color  color;
  const _RoundInfo(this.label, this.matches, this.byes, this.color);
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

// ════════════════════════════════════════════════════════════════════════════
// FIFA BRACKET LINE PAINTER — draws connector lines between rounds
// ════════════════════════════════════════════════════════════════════════════
class _FifaBracketLinePainter extends CustomPainter {
  final List<String>                     activeRounds;
  final Map<String, int>                 expectedCount;
  final double cardW, cardH, gapH, totalH;

  const _FifaBracketLinePainter({
    required this.activeRounds,
    required this.expectedCount,
    required this.cardW,
    required this.cardH,
    required this.gapH,
    required this.totalH,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF4D3AAA).withOpacity(0.55)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    for (int ri = 0; ri < activeRounds.length - 1; ri++) {
      final curCount  = expectedCount[activeRounds[ri]]!;
      final nextCount = expectedCount[activeRounds[ri + 1]]!;

      final curSlotH  = totalH / curCount;
      final nextSlotH = totalH / nextCount;

      final x1 = ri * (cardW + gapH) + cardW;
      final x2 = (ri + 1) * (cardW + gapH);
      final mx = x1 + gapH / 2;

      for (int ni = 0; ni < nextCount; ni++) {
        final ny  = ni * nextSlotH + nextSlotH / 2;

        if (curCount == nextCount) {
          // 1-to-1: straight horizontal connector (BYE round feeding same-size next round)
          final cy = ni * curSlotH + curSlotH / 2;
          canvas.drawLine(Offset(x1, cy), Offset(mx, cy), paint);
          canvas.drawLine(Offset(mx, cy), Offset(mx, ny), paint);
          canvas.drawLine(Offset(mx, ny), Offset(x2, ny), paint);
        } else {
          // Merge: two current-round matches → one next-round match
          final ia = ni * 2;
          final ib = ni * 2 + 1;

          final cy1 = ia * curSlotH + curSlotH / 2;
          final cy2 = ib < curCount ? ib * curSlotH + curSlotH / 2 : cy1;

          canvas.drawLine(Offset(x1, cy1), Offset(mx, cy1), paint);
          if (ib < curCount) {
            canvas.drawLine(Offset(x1, cy2), Offset(mx, cy2), paint);
            canvas.drawLine(Offset(mx, cy1), Offset(mx, cy2), paint);
          }
          canvas.drawLine(Offset(mx, ny), Offset(x2, ny), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_FifaBracketLinePainter o) => true;
}

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

// ════════════════════════════════════════════════════════════════════════════
// BOUNCING SOCCER BALL — shown when match status is In Progress
// ════════════════════════════════════════════════════════════════════════════
class _BouncingSoccerBall extends StatefulWidget {
  const _BouncingSoccerBall();
  @override
  State<_BouncingSoccerBall> createState() => _BouncingSoccerBallState();
}

class _BouncingSoccerBallState extends State<_BouncingSoccerBall>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _bounce;
  late Animation<double>   _squash;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    )..repeat(reverse: true);

    // Ball moves up then comes back down
    _bounce = Tween(begin: 0.0, end: -18.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut,
          reverseCurve: Curves.bounceIn),
    );

    // Slight squash at bottom (wide + flat), stretch at top (narrow + tall)
    _squash = Tween(begin: 1.0, end: 0.85).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 52,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          return Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Transform.translate(
                offset: Offset(0, _bounce.value),
                child: Transform.scale(
                  scaleX: 2.0 - _squash.value,  // wider when squashed
                  scaleY: _squash.value,          // shorter when squashed
                  child: const Text('⚽', style: TextStyle(fontSize: 26)),
                ),
              ),
              const SizedBox(height: 2),
              // Shadow — shrinks when ball is high
              Opacity(
                opacity: 0.25 + (_ctrl.value * 0.35),
                child: Container(
                  width: 18 + (_ctrl.value * 6),
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}