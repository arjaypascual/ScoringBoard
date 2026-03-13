import 'dart:async';
import 'package:flutter/material.dart';
import 'db_helper.dart';
import 'teams_players.dart';

class Standings extends StatefulWidget {
  final VoidCallback? onBack;

  const Standings({
    super.key,
    this.onBack,
  });

  @override
  State<Standings> createState() => _StandingsState();
}

class _StandingsState extends State<Standings>
    with TickerProviderStateMixin {
  TabController? _tabController;
  TabController? _soccerTabCtrl;
  List<Map<String, dynamic>> _categories = [];

  // category_id → list of standing rows
  Map<int, List<Map<String, dynamic>>> _standingsByCategory = {};

  bool _isLoading = true;
  DateTime? _lastUpdated;
  Timer?    _autoRefreshTimer;

  // Track changes using a data signature instead of just count
  String _lastDataSignature  = '';
  String _lastGroupSignature = '';

  // Soccer group stage data
  int?   _soccerCategoryId;
  List<_SoccerGroup> _soccerGroups = [];

  @override
  void initState() {
    super.initState();
    _loadData(initial: true);
    _autoRefreshTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _silentRefresh(),
    );
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _tabController?.dispose();
    _soccerTabCtrl?.dispose();
    super.dispose();
  }

  // ── Build a signature string to detect any data change ──────────────────
  String _buildSignature(List rows) {
    return rows.map((r) => r.toString()).join('|');
  }

  // ── Silent refresh — only rebuilds UI if data actually changed ───────────
  Future<void> _silentRefresh() async {
    try {
      final conn   = await DBHelper.getConnection();
      final result = await conn.execute(
          "SELECT score_id, team_id, round_id, score_totalscore FROM tbl_score ORDER BY score_id");
      final rows = result.rows.map((r) => r.assoc()).toList();
      final signature = _buildSignature(rows);

      if (signature != _lastDataSignature) {
        _lastDataSignature = signature;
        await _loadData(initial: false);
      }

      // Real-time group stage sync — reloads on group changes OR score submissions
      if (_soccerCategoryId != null) {
        try {
          final gResult = await conn.execute(
            "SELECT g.group_label, g.team_id, COALESCE(sc.score_totalscore, -1) as score"
            " FROM tbl_soccer_groups g"
            " LEFT JOIN tbl_teamschedule ts ON ts.team_id = g.team_id"
            " LEFT JOIN tbl_score sc ON sc.team_id = g.team_id AND sc.match_id = ts.match_id"
            " WHERE g.category_id = ${_soccerCategoryId}"
            " ORDER BY g.group_label, g.id, ts.match_id",
          );
          final gRows = gResult.rows.map((r) => r.assoc()).toList();
          final gSig  = _buildSignature(gRows);
          if (gSig != _lastGroupSignature) {
            _lastGroupSignature = gSig;
            await _loadSoccerGroups(catId: _soccerCategoryId);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  // ── Load data ─────────────────────────────────────────────────────────────
  Future<void> _loadData({bool initial = false}) async {
    if (initial) {
      setState(() => _isLoading = true);
    }

    try {
      final categories = await DBHelper.getCategories();
      final Map<int, List<Map<String, dynamic>>> standingsByCategory = {};

      for (final cat in categories) {
        final catId = int.tryParse(cat['category_id'].toString()) ?? 0;
        final rows  = await DBHelper.getScoresByCategory(catId);

        final Map<int, Map<String, dynamic>> teamMap = {};
        for (final row in rows) {
          final teamId   = int.tryParse(row['team_id'].toString()) ?? 0;
          final roundId  = int.tryParse(row['round_id']?.toString() ?? '0') ?? 0;
          final score    = int.tryParse(row['score_totalscore'].toString()) ?? 0;
          final duration = row['score_totalduration']?.toString() ?? '00:00';

          teamMap.putIfAbsent(teamId, () => {
            'team_id':   teamId,
            'team_name': row['team_name'] ?? '',
            'rounds':    <int, Map<String, dynamic>>{},
          });

          if (roundId > 0) {
            (teamMap[teamId]!['rounds']
                as Map<int, Map<String, dynamic>>)[roundId] = {
              'score':    score,
              'duration': duration,
            };
          }
        }

        if (teamMap.isEmpty) {
          final teams = await DBHelper.getTeamsByCategory(catId);
          for (final t in teams) {
            final teamId = int.tryParse(t['team_id'].toString()) ?? 0;
            teamMap[teamId] = {
              'team_id':   teamId,
              'team_name': t['team_name'] ?? '',
              'rounds':    <int, Map<String, dynamic>>{},
            };
          }
        }

        int maxRounds = 2;
        for (final t in teamMap.values) {
          final rounds = t['rounds'] as Map<int, Map<String, dynamic>>;
          if (rounds.keys.isNotEmpty) {
            final max = rounds.keys.reduce((a, b) => a > b ? a : b);
            if (max > maxRounds) maxRounds = max;
          }
        }

        final standings = teamMap.values.map((t) {
          final rounds = t['rounds'] as Map<int, Map<String, dynamic>>;
          int totalScore = 0;
          for (final r in rounds.values) {
            totalScore += (r['score'] as int);
          }
          return {
            'team_id':    t['team_id'],
            'team_name':  t['team_name'],
            'rounds':     rounds,
            'totalScore': totalScore,
            'maxRounds':  maxRounds,
          };
        }).toList();

        standings.sort((a, b) =>
            (b['totalScore'] as int).compareTo(a['totalScore'] as int));

        for (int i = 0; i < standings.length; i++) {
          standings[i]['rank'] = i + 1;
        }

        standingsByCategory[catId] = standings;
      }

      final previousTabIndex = _tabController?.index ?? 0;
      final prevSoccerIdx = _soccerTabCtrl?.index ?? 0;
      _tabController?.dispose();
      _tabController = TabController(
        length: categories.length,
        vsync: this,
        initialIndex: previousTabIndex.clamp(0, (categories.length - 1).clamp(0, 9999)),
      );
      _soccerTabCtrl?.dispose();
      _soccerTabCtrl = TabController(
        length: 2, vsync: this,
        initialIndex: prevSoccerIdx.clamp(0, 1),
      );


      // Find soccer category
      int? soccerCatId;
      for (final cat in categories) {
        if ((cat['category_type'] ?? '').toString().toLowerCase().contains('soccer')) {
          soccerCatId = int.tryParse(cat['category_id'].toString());
          break;
        }
      }

      setState(() {
        _categories          = categories;
        _standingsByCategory = standingsByCategory;
        _soccerCategoryId    = soccerCatId;
        _isLoading           = false;
        _lastUpdated         = DateTime.now();
      });

      // Load soccer group standings (pass id directly to avoid state timing issue)
      if (soccerCatId != null) await _loadSoccerGroups(catId: soccerCatId);
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Failed to load standings: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
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
                child: Text('No data found.',
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
                      text: (c['category_type'] ?? '')
                          .toString()
                          .toUpperCase());
                }).toList(),
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: _categories.map((cat) {
                  final catId =
                      int.tryParse(cat['category_id'].toString()) ?? 0;
                  final rows = _standingsByCategory[catId] ?? [];
                  return _buildStandingsView(cat, rows);
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Standings view per category ───────────────────────────────────────────
  Widget _buildStandingsView(
    Map<String, dynamic> category,
    List<Map<String, dynamic>> rows,
  ) {
    final categoryName =
        (category['category_type'] ?? '').toString().toUpperCase();
    final isSoccer = categoryName.toLowerCase().contains('soccer');
    if (isSoccer) return _buildSoccerStandingsView(category);

    final maxRounds =
        rows.isNotEmpty ? (rows.first['maxRounds'] as int? ?? 2) : 2;

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
              const Text(
                'ROBOVENTURE',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
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
                  _buildLiveIndicator(),
                  IconButton(
                    tooltip: 'Teams & Players',
                    icon: const Icon(Icons.groups_rounded,
                        color: Color(0xFF00E5A0)),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => TeamsPlayers(
                            onBack: () => Navigator.of(context).pop(),
                          ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'Back to Homepage',
                    icon: const Icon(Icons.arrow_back_ios_new,
                        color: Color(0xFF00CFFF)),
                    onPressed: widget.onBack,
                  ),
                ],
              ),
            ],
          ),
        ),

        // ── Table header ─────────────────────────────────────────────
        Container(
          color: const Color(0xFF5C2ECC),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
          child: Row(
            children: [
              _headerCell('RANK',       flex: 1),
              _headerCell('TEAM ID',    flex: 2),
              _headerCell('TEAM NAME:', flex: 3),
              ...List.generate(
                maxRounds,
                (i) => _headerCell(
                  _roundLabel(i + 1, categoryName),
                  flex: 2,
                  center: true,
                ),
              ),
              _headerCell('FINAL SCORE', flex: 2, center: true),
            ],
          ),
        ),

        // ── Rows ─────────────────────────────────────────────────────
        Expanded(
          child: rows.isEmpty
              ? const Center(
                  child: Text('No teams registered yet.',
                      style:
                          TextStyle(color: Colors.white54, fontSize: 14)),
                )
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row      = rows[index];
                    final rank     = row['rank'] as int;
                    final teamId   = row['team_id'];
                    final teamName = row['team_name'] as String;
                    final rounds   = row['rounds']
                        as Map<int, Map<String, dynamic>>;
                    final total    = row['totalScore'] as int;
                    final isEven   = index % 2 == 0;

                    return Container(
                      color: isEven
                          ? const Color(0xFF1E0E5A)
                          : const Color(0xFF160A42),
                      padding: const EdgeInsets.symmetric(
                          vertical: 16, horizontal: 24),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 1,
                            child: Text(
                              '$rank',
                              style: TextStyle(
                                color: _rankColor(rank),
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              'C${teamId.toString().padLeft(3, '0')}R',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              teamName.toUpperCase(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          ...List.generate(maxRounds, (i) {
                            final roundData = rounds[i + 1];
                            final score = roundData?['score'] ?? 0;
                            return Expanded(
                              flex: 2,
                              child: Text(
                                '$score',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                            );
                          }),
                          Expanded(
                            flex: 2,
                            child: Column(
                              children: [
                                Text(
                                  '$total',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                ),
                                Text(
                                  _bestDuration(rounds),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
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

  // ── Helpers ───────────────────────────────────────────────────────────────

  // ── Load soccer groups from DB ─────────────────────────────────────────────
  Future<void> _loadSoccerGroups({int? catId}) async {
    final id = catId ?? _soccerCategoryId;
    if (id == null) return;
    try {
      final conn = await DBHelper.getConnection();

      // Check table exists
      final check = await conn.execute(
        "SELECT COUNT(*) as cnt FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'tbl_soccer_groups'",
      );
      final exists = check.rows.isNotEmpty &&
          (int.tryParse(check.rows.first.assoc()['cnt']?.toString() ?? '0') ?? 0) > 0;
      if (!exists) return;

      // Load group assignments
      final result = await conn.execute(
        "SELECT group_label, team_id, team_name FROM tbl_soccer_groups WHERE category_id = $id ORDER BY group_label, id",
      );
      final rows = result.rows.map((r) => r.assoc()).toList();
      if (rows.isEmpty) return;

      // Build team stat map keyed by team_id
      final Map<int, _SoccerTeamStat> teamStatMap = {};
      final Map<String, List<int>>    groupTeamIds = {};
      for (final row in rows) {
        final label    = row['group_label']?.toString() ?? '';
        final teamId   = int.tryParse(row['team_id']?.toString() ?? '0') ?? 0;
        final teamName = row['team_name']?.toString() ?? '';
        teamStatMap[teamId] = _SoccerTeamStat(teamId: teamId, teamName: teamName);
        groupTeamIds.putIfAbsent(label, () => []);
        groupTeamIds[label]!.add(teamId);
      }

      // Load all match scores for soccer teams
      // Two rows per match (one per team) — we pair them by match_id
      final matchResult = await conn.execute(
        "SELECT ts.match_id, ts.team_id, COALESCE(sc.score_totalscore, -1) AS score"
        " FROM tbl_teamschedule ts"
        " JOIN tbl_team t ON ts.team_id = t.team_id"
        " LEFT JOIN tbl_score sc ON sc.team_id = ts.team_id AND sc.match_id = ts.match_id"
        " WHERE t.category_id = $id"
        " ORDER BY ts.match_id, ts.team_id",
      );
      final matchRows = matchResult.rows.map((r) => r.assoc()).toList();

      // Group by match_id
      final Map<String, List<Map<String, dynamic>>> byMatch = {};
      for (final row in matchRows) {
        final mid = row['match_id']?.toString() ?? '';
        byMatch.putIfAbsent(mid, () => []);
        byMatch[mid]!.add(row);
      }

      // Compute W/L/D per team
      for (final entries in byMatch.values) {
        if (entries.length != 2) continue;
        final s0 = int.tryParse(entries[0]['score']?.toString() ?? '-1') ?? -1;
        final s1 = int.tryParse(entries[1]['score']?.toString() ?? '-1') ?? -1;
        if (s0 < 0 || s1 < 0) continue; // skip if either score not yet submitted

        final t0 = int.tryParse(entries[0]['team_id']?.toString() ?? '0') ?? 0;
        final t1 = int.tryParse(entries[1]['team_id']?.toString() ?? '0') ?? 0;
        final stat0 = teamStatMap[t0];
        final stat1 = teamStatMap[t1];
        if (stat0 == null || stat1 == null) continue;

        if (s0 > s1) {
          stat0.wins++;   stat0.points++;
          stat1.losses++;
        } else if (s1 > s0) {
          stat1.wins++;   stat1.points++;
          stat0.losses++;
        } else {
          stat0.draws++;
          stat1.draws++;
        }
      }

      // Build sorted group list
      final labels = groupTeamIds.keys.toList()..sort();
      final groups = labels.map((label) {
        final teams = groupTeamIds[label]!.map((tid) => teamStatMap[tid]!).toList();
        return _SoccerGroup(label: label, teams: teams);
      }).toList();

      if (mounted) setState(() => _soccerGroups = groups);
    } catch (e) {
      print('loadSoccerGroups error: $e');
    }
  }

  // ── Soccer group standings view ──────────────────────────────────────────────
  Widget _buildSoccerStandingsView(Map<String, dynamic> category) {
    final categoryName = (category['category_type'] ?? '').toString().toUpperCase();
    return Column(children: [
      // Title bar
      Container(
        width: double.infinity,
        color: const Color(0xFF2D0E7A),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 32),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('ROBOVENTURE',
              style: TextStyle(color: Colors.white54, fontSize: 13,
                  fontWeight: FontWeight.bold, letterSpacing: 2)),
          Text(categoryName,
              style: const TextStyle(color: Colors.white, fontSize: 26,
                  fontWeight: FontWeight.bold, letterSpacing: 2)),
          Row(children: [
            _buildLiveIndicator(),
            IconButton(
              tooltip: 'Back to Homepage',
              icon: const Icon(Icons.arrow_back_ios_new, color: Color(0xFF00CFFF)),
              onPressed: widget.onBack,
            ),
          ]),
        ]),
      ),
      // Inner tabs: Group Stage | Overall
      Container(
        color: const Color(0xFF130742),
        child: TabBar(
          controller: _soccerTabCtrl,
          indicatorColor: const Color(0xFF00FF88),
          indicatorWeight: 3,
          labelColor: const Color(0xFF00FF88),
          unselectedLabelColor: Colors.white38,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1),
          tabs: const [
            Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.grid_view_rounded, size: 15),
              SizedBox(width: 6),
              Text('GROUP STAGE'),
            ])),
            Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.leaderboard, size: 15),
              SizedBox(width: 6),
              Text('OVERALL'),
            ])),
          ],
        ),
      ),
      Expanded(
        child: TabBarView(
          controller: _soccerTabCtrl,
          children: [
            // Tab 1: Group Stage
            _soccerGroups.isEmpty
                ? const Center(child: Text('No groups generated yet.',
                    style: TextStyle(color: Colors.white54, fontSize: 14)))
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: _buildGroupGrid(),
                  ),
            // Tab 2: Overall Standing
            _buildOverallStanding(),
          ],
        ),
      ),
    ]);
  }

  // ── Overall standing — all teams ranked by W/L/PTS ───────────────────────────
  Widget _buildOverallStanding() {
    if (_soccerGroups.isEmpty) {
      return const Center(child: Text('No groups generated yet.',
          style: TextStyle(color: Colors.white54, fontSize: 14)));
    }

    // Flatten all teams from all groups and sort by PTS > W > teamName
    final allTeams = <Map<String, dynamic>>[];
    for (final g in _soccerGroups) {
      for (final t in g.teams) {
        allTeams.add({
          'teamName':  t.teamName,
          'group':     g.label,
          'wins':      t.wins,
          'losses':    t.losses,
          'points':    t.points,
          'groupColor': _groupColor(g.label),
        });
      }
    }
    allTeams.sort((a, b) {
      if (b['points'] != a['points']) return (b['points'] as int).compareTo(a['points'] as int);
      if (b['wins']   != a['wins'])   return (b['wins']   as int).compareTo(a['wins']   as int);
      return (a['teamName'] as String).compareTo(b['teamName'] as String);
    });

    return Column(children: [
      // Header
      Container(
        color: const Color(0xFF5C2ECC),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
        child: Row(children: [
          _headerCell('RANK',  flex: 1),
          _headerCell('GRP',   flex: 1),
          _headerCell('TEAM NAME', flex: 5),
          _headerCell('W',  flex: 1, center: true),
          _headerCell('L',  flex: 1, center: true),
          _headerCell('PTS', flex: 1, center: true),
        ]),
      ),
      // Rows
      Expanded(
        child: ListView.builder(
          itemCount: allTeams.length,
          itemBuilder: (context, index) {
            final team     = allTeams[index];
            final rank     = index + 1;
            final isEven   = index % 2 == 0;
            final gc       = team['groupColor'] as Color;
            final wins     = team['wins']   as int;
            final losses   = team['losses'] as int;
            final points   = team['points'] as int;
            return Container(
              color: isEven ? const Color(0xFF1E0E5A) : const Color(0xFF160A42),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
              child: Row(children: [
                // Rank
                Expanded(flex: 1, child: Text('$rank',
                    style: TextStyle(color: _rankColor(rank),
                        fontWeight: FontWeight.bold, fontSize: 16))),
                // Group badge
                Expanded(flex: 1, child: Container(
                  width: 26, height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: gc.withOpacity(0.15),
                    border: Border.all(color: gc, width: 1.5),
                  ),
                  child: Center(child: Text(team['group'] as String,
                      style: TextStyle(color: gc, fontSize: 11,
                          fontWeight: FontWeight.bold))),
                )),
                // Team name
                Expanded(flex: 5, child: Text(
                    (team['teamName'] as String).toUpperCase(),
                    style: const TextStyle(color: Colors.white,
                        fontWeight: FontWeight.bold, fontSize: 14))),
                // W
                Expanded(flex: 1, child: Text('$wins',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: wins > 0 ? const Color(0xFF00FF88) : Colors.white24,
                        fontWeight: FontWeight.bold, fontSize: 16))),
                // L
                Expanded(flex: 1, child: Text('$losses',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: losses > 0 ? Colors.redAccent : Colors.white24,
                        fontWeight: FontWeight.bold, fontSize: 16))),
                // PTS
                Expanded(flex: 1, child: Text('$points',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: points > 0 ? const Color(0xFFFFD700) : Colors.white24,
                        fontWeight: FontWeight.bold, fontSize: 16))),
              ]),
            );
          },
        ),
      ),
    ]);
  }

  Widget _buildGroupGrid() {
    const int cols = 4;
    final rows = <List<_SoccerGroup>>[];
    for (int i = 0; i < _soccerGroups.length; i += cols) {
      rows.add(_soccerGroups.sublist(i, (i + cols).clamp(0, _soccerGroups.length)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows.map((rowGroups) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start,
          children: rowGroups.map((g) => Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: _buildGroupStandingCard(g),
            ),
          )).toList()),
      )).toList(),
    );
  }

  Widget _buildGroupStandingCard(_SoccerGroup group) {
    final groupCol = _groupColor(group.label);
    final sorted   = List<_SoccerTeamStat>.from(group.teams)
      ..sort((a, b) {
        if (b.points != a.points) return b.points.compareTo(a.points);
        if (b.wins   != a.wins)   return b.wins.compareTo(a.wins);
        return a.teamName.compareTo(b.teamName);
      });
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F0A2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: groupCol.withOpacity(0.4), width: 1.5),
        boxShadow: [BoxShadow(color: groupCol.withOpacity(0.08), blurRadius: 12)],
      ),
      child: Column(children: [
        // Header
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
                      fontSize: 14))),
            ),
            const SizedBox(width: 8),
            Text('GROUP ${group.label}',
                style: const TextStyle(color: Colors.white, fontSize: 13,
                    fontWeight: FontWeight.w900, letterSpacing: 1.5)),
          ]),
        ),
        // Column headers
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            border: Border(bottom: BorderSide(color: groupCol.withOpacity(0.2))),
          ),
          child: Row(children: [
            const SizedBox(width: 22),
            const SizedBox(width: 6),
            const Expanded(child: Text('TEAM',
                style: TextStyle(color: Colors.white38, fontSize: 9,
                    fontWeight: FontWeight.bold, letterSpacing: 0.8))),
            SizedBox(width: 24, child: Text('W', textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF00FF88),
                    fontSize: 9, fontWeight: FontWeight.bold))),
            SizedBox(width: 24, child: Text('L', textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent,
                    fontSize: 9, fontWeight: FontWeight.bold))),
            SizedBox(width: 28, child: Text('PTS', textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFFFD700),
                    fontSize: 9, fontWeight: FontWeight.bold))),
          ]),
        ),
        // Team rows
        ...sorted.asMap().entries.map((e) {
          final rank     = e.key + 1;
          final team     = e.value;
          final advances = rank <= 2;
          final isFirst  = rank == 1;
          final badgeCol = isFirst
              ? const Color(0xFFFFD700)
              : advances ? const Color(0xFF00FF88) : Colors.white12;
          final textCol  = advances ? badgeCol : Colors.white38;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: advances
                  ? (isFirst
                      ? const Color(0xFFFFD700).withOpacity(0.05)
                      : const Color(0xFF00FF88).withOpacity(0.04))
                  : Colors.transparent,
              border: Border(bottom: BorderSide(
                  color: Colors.white.withOpacity(0.04), width: 1)),
            ),
            child: Row(children: [
              Container(
                width: 22, height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: advances ? badgeCol.withOpacity(0.12) : Colors.white.withOpacity(0.03),
                  border: Border.all(color: badgeCol, width: 1),
                ),
                child: Center(child: Text('$rank',
                    style: TextStyle(color: textCol,
                        fontSize: 9, fontWeight: FontWeight.bold))),
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(team.teamName, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: advances ? Colors.white : Colors.white54,
                      fontSize: 12,
                      fontWeight: advances ? FontWeight.bold : FontWeight.w400))),
              SizedBox(width: 24, child: Text('${team.wins}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: team.wins > 0 ? const Color(0xFF00FF88) : Colors.white24,
                      fontSize: 12, fontWeight: FontWeight.bold))),
              SizedBox(width: 24, child: Text('${team.losses}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: team.losses > 0 ? Colors.redAccent : Colors.white24,
                      fontSize: 12, fontWeight: FontWeight.bold))),
              SizedBox(width: 28, child: Text('${team.points}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: team.points > 0 ? const Color(0xFFFFD700) : Colors.white24,
                      fontSize: 12, fontWeight: FontWeight.bold))),
            ]),
          );
        }),
        // Footer
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.02),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(11)),
            border: Border(top: BorderSide(color: groupCol.withOpacity(0.12))),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.arrow_upward,
                color: const Color(0xFF00FF88).withOpacity(0.6), size: 10),
            const SizedBox(width: 4),
            Text('Top 2 advance',
                style: TextStyle(color: const Color(0xFF00FF88).withOpacity(0.55),
                    fontSize: 9, fontWeight: FontWeight.bold)),
          ]),
        ),
      ]),
    );
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

  /// Uses "MATCH" for Soccer categories, "RUN" for everything else.
  String _roundLabel(int round, String categoryName) {
    final isSoccer = categoryName.toLowerCase().contains('soccer');
    final word     = isSoccer ? 'MATCH' : 'RUN';
    switch (round) {
      case 1:  return 'FIRST\n$word';
      case 2:  return 'SECOND\n$word';
      case 3:  return 'THIRD\n$word';
      default: return '$word $round';
    }
  }

  Color _rankColor(int rank) {
    switch (rank) {
      case 1:  return const Color(0xFFFFD700);
      case 2:  return const Color(0xFFC0C0C0);
      case 3:  return const Color(0xFFCD7F32);
      default: return Colors.white;
    }
  }

  String _bestDuration(Map<int, Map<String, dynamic>> rounds) {
    if (rounds.isEmpty) return '00:00';
    int    bestScore    = -1;
    String bestDuration = '00:00';
    for (final r in rounds.values) {
      final s = r['score'] as int? ?? 0;
      if (s > bestScore) {
        bestScore    = s;
        bestDuration = r['duration'] as String? ?? '00:00';
      }
    }
    return bestDuration;
  }

  // ── Widgets ───────────────────────────────────────────────────────────────

  Widget _headerCell(String text, {int flex = 1, bool center = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        textAlign: center ? TextAlign.center : TextAlign.left,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 12,
          letterSpacing: 0.5,
          height: 1.3,
        ),
      ),
    );
  }

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

  // ── Live indicator ────────────────────────────────────────────────────────
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
}

// ── Soccer group data models ─────────────────────────────────────────────────
class _SoccerTeamStat {
  final int    teamId;
  final String teamName;
  int wins   = 0;
  int losses = 0;
  int draws  = 0;
  int points = 0;
  _SoccerTeamStat({required this.teamId, required this.teamName});
}

class _SoccerGroup {
  final String              label;
  final List<_SoccerTeamStat> teams;
  _SoccerGroup({required this.label, required this.teams});
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