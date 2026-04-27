import 'dart:async';
import 'package:flutter/material.dart';
import 'db_helper.dart';
import 'teams_players.dart';
import 'export_service.dart';

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
  List<Map<String, String?>> _categories = [];

  // category_id → list of standing rows
  Map<int, List<Map<String, dynamic>>> _standingsByCategory = {};

  bool _isLoading = true;
  DateTime? _lastUpdated;
  Timer?    _autoRefreshTimer;

  // Track changes using a data signature instead of just count
  String _lastDataSignature  = '';
  String _lastGroupSignature = '';

  // category_id → { team_id → previous rank } for delta arrows
  Map<int, Map<int, int>> _previousRanks = {};

  // Soccer group stage data
  int?   _soccerCategoryId;
  List<_SoccerGroup> _soccerGroups = [];

  // Resolved tiebreaker winners: groupLabel → winner teamId
  Map<String, int> _tiebreakerWinners = {};

  // ── Final Ranking (from knockout results) ─────────────────────────────────
  // null = not yet determined, empty list = tournament not started
  List<_FinalRankEntry> _finalRanking = [];

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
          "SELECT score_id, team_id, round_id, score_totalscore, score_totalduration FROM tbl_score ORDER BY score_id");
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
            await _loadFinalRanking(catId: _soccerCategoryId);
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
      final categories = await DBHelper.getActiveCategories();
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
          // Compute best (fastest) time in seconds for timer-based categories
          int bestTimeSecs = 999999;
          String bestTimeStr = '—';
          for (final r in rounds.values) {
            final dur  = r['duration'] as String? ?? '';
            final secs = _parseDurationSeconds(dur);
            if (secs < bestTimeSecs) {
              bestTimeSecs = secs;
              bestTimeStr  = _formatDuration(dur);
            }
          }
          return {
            'team_id':    t['team_id'],
            'team_name':  t['team_name'],
            'rounds':     rounds,
            'totalScore': totalScore,
            'maxRounds':  maxRounds,
            'bestTimeSecs': bestTimeSecs,
            'bestTimeStr':  bestTimeStr,
          };
        }).toList();

        final categoryName = (cat['category_type'] ?? '').toString();
        final isTimer = _isTimerCategory(categoryName);

        if (isTimer) {
          // Fastest time first; teams with no time go to the bottom
          standings.sort((a, b) =>
              (a['bestTimeSecs'] as int).compareTo(b['bestTimeSecs'] as int));
        } else {
          standings.sort((a, b) =>
              (b['totalScore'] as int).compareTo(a['totalScore'] as int));
        }

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
        length: 3, vsync: this,
        initialIndex: prevSoccerIdx.clamp(0, 2),
      );

      // Find soccer category
      int? soccerCatId;
      for (final cat in categories) {
        if ((cat['category_type'] ?? '').toString().toLowerCase().contains('soccer')) {
          soccerCatId = int.tryParse(cat['category_id'].toString());
          break;
        }
      }

      // ── Snapshot previous ranks before overwriting ──────────────────
      final Map<int, Map<int, int>> newPrevRanks = {};
      for (final entry in _standingsByCategory.entries) {
        newPrevRanks[entry.key] = {
          for (final r in entry.value)
            (r['team_id'] as int): (r['rank'] as int),
        };
      }

      setState(() {
        _previousRanks       = newPrevRanks;
        _categories          = categories;
        _standingsByCategory = standingsByCategory;
        _soccerCategoryId    = soccerCatId;
        _isLoading           = false;
        _lastUpdated         = DateTime.now();
      });

      // Load soccer group standings (pass id directly to avoid state timing issue)
      if (soccerCatId != null) await _loadSoccerGroups(catId: soccerCatId);
      if (soccerCatId != null) await _loadFinalRanking(catId: soccerCatId);
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

    final isTimer  = _isTimerCategory(categoryName);

    final catId    = int.tryParse(category['category_id'].toString()) ?? 0;
    final prevRank = _previousRanks[catId] ?? {};
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
                  // ── Export standings ───────────────────────────────
                  IconButton(
                    tooltip: 'Export Standings',
                    icon: const Icon(Icons.download_rounded,
                        color: Color(0xFF00FF9C)),
                    onPressed: _showExportDialog,
                  ),
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
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 24),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: const Text(
                  'RANK',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    letterSpacing: 0.5,
                    height: 1.3,
                  ),
                ),
              ),
              // Delta column header — narrow fixed width
              const SizedBox(
                width: 32,
                child: Text(
                  '±',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              _headerCell('TEAM ID',   flex: 2),
              _headerCell('TEAM NAME', flex: 3),
              ...List.generate(
                maxRounds,
                (i) => _headerCell(
                  _roundLabel(i + 1, categoryName),
                  flex: 3,
                  center: true,
                ),
              ),
              _headerCell(isTimer ? 'BEST\nTIME' : 'TOTAL\nSCORE', flex: 2, center: true),
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
                    final teamId   = row['team_id'] as int;
                    final teamName = row['team_name'] as String;
                    final rounds   = row['rounds']
                        as Map<int, Map<String, dynamic>>;
                    final total    = row['totalScore'] as int;
                    final isEven   = index % 2 == 0;

                    final rankCol = _rankColor(rank);
                    final isTop3  = rank <= 3;
                    final rowGlow = rank == 1
                        ? const Color(0xFFFFD700)
                        : rank == 2
                            ? const Color(0xFFC0C0C0)
                            : rank == 3
                                ? const Color(0xFFCD7F32)
                                : null;

                    // ── Delta calculation ──────────────────────────
                    final oldRank = prevRank[teamId];
                    Widget deltaWidget;
                    if (oldRank == null || oldRank == rank) {
                      deltaWidget = const Text(
                        '—',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      );
                    } else if (rank < oldRank) {
                      // Moved up (lower rank number = better position)
                      deltaWidget = Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.arrow_drop_up_rounded,
                            color: Color(0xFF00FF88),
                            size: 24,
                          ),
                          Text(
                            '+${oldRank - rank}',
                            style: const TextStyle(
                              color: Color(0xFF00FF88),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              height: 0.8,
                            ),
                          ),
                        ],
                      );
                    } else {
                      // Moved down
                      deltaWidget = Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.arrow_drop_down_rounded,
                            color: Color(0xFFFF6B6B),
                            size: 24,
                          ),
                          Text(
                            '-${rank - oldRank}',
                            style: const TextStyle(
                              color: Color(0xFFFF6B6B),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              height: 0.8,
                            ),
                          ),
                        ],
                      );
                    }

                    return Container(
                      decoration: BoxDecoration(
                        gradient: isTop3
                            ? LinearGradient(
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                                colors: [
                                  rowGlow!.withOpacity(rank == 1
                                      ? 0.13
                                      : rank == 2
                                          ? 0.08
                                          : 0.06),
                                  (isEven
                                      ? const Color(0xFF1E0E5A)
                                      : const Color(0xFF160A42)),
                                ],
                              )
                            : null,
                        color: isTop3
                            ? null
                            : isEven
                                ? const Color(0xFF1E0E5A)
                                : const Color(0xFF160A42),
                        border: isTop3
                            ? Border(
                                left: BorderSide(
                                    color: rowGlow!.withOpacity(0.7),
                                    width: 3))
                            : null,
                      ),
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 20),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // ── Rank ──────────────────────────────────
                          SizedBox(
                            width: 48,
                            child: Center(
                              child: isTop3
                                  ? Container(
                                      width: 38,
                                      height: 38,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: RadialGradient(colors: [
                                          rankCol.withOpacity(0.35),
                                          rankCol.withOpacity(0.08),
                                        ]),
                                        border: Border.all(
                                            color: rankCol.withOpacity(0.8),
                                            width: 1.5),
                                        boxShadow: [
                                          BoxShadow(
                                            color: rankCol.withOpacity(0.4),
                                            blurRadius: 8,
                                            spreadRadius: 1,
                                          ),
                                        ],
                                      ),
                                      child: Center(
                                        child: Text(
                                          rank == 1
                                              ? '🥇'
                                              : rank == 2
                                                  ? '🥈'
                                                  : '🥉',
                                          style: const TextStyle(fontSize: 16),
                                        ),
                                      ),
                                    )
                                  : Container(
                                      width: 38,
                                      height: 38,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.white.withOpacity(0.06),
                                        border: Border.all(
                                            color: Colors.white30, width: 1.5),
                                      ),
                                      child: Center(
                                        child: Text(
                                          '$rank',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w900,
                                            fontSize: 16,
                                          ),
                                        ),
                                      ),
                                    ),
                            ),
                          ),

                          // ── Delta arrow ───────────────────────────
                          SizedBox(
                            width: 32,
                            child: Center(child: deltaWidget),
                          ),

                          // ── Team ID ───────────────────────────────
                          Expanded(
                            flex: 2,
                            child: Text(
                              'C${teamId.toString().padLeft(3, '0')}R',
                              style: TextStyle(
                                color: isTop3 ? Colors.white : Colors.white70,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ),

                          // ── Team Name ─────────────────────────────
                          Expanded(
                            flex: 3,
                            child: Text(
                              teamName.toUpperCase(),
                              style: TextStyle(
                                color: isTop3 ? Colors.white : Colors.white70,
                                fontWeight: isTop3
                                    ? FontWeight.w900
                                    : FontWeight.bold,
                                fontSize: isTop3 ? 15 : 14,
                                shadows: isTop3
                                    ? [
                                        Shadow(
                                          color: rowGlow!.withOpacity(0.4),
                                          blurRadius: 6,
                                        )
                                      ]
                                    : null,
                              ),
                            ),
                          ),

                          // ── Per-run columns ───────────────────────
                          ...List.generate(maxRounds, (i) {
                            final roundData = rounds[i + 1];
                            final score    = roundData?['score'] as int?;
                            final duration = roundData?['duration'] as String?;
                            final hasData  = roundData != null;
                            final fmtDur   = _formatDuration(duration ?? '');

                            if (isTimer) {
                              // Timer categories: show only the lap time in MM:SS
                              return Expanded(
                                flex: 3,
                                child: Text(
                                  hasData && fmtDur != '—' ? fmtDur : '—',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: hasData && fmtDur != '—'
                                        ? const Color(0xFF00CFFF)
                                        : Colors.white30,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              );
                            }

                            // Score-based categories: score on top + time below
                            return Expanded(
                              flex: 3,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Text(
                                    hasData && score != null ? '$score' : '—',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: hasData && score != null
                                          ? Colors.white
                                          : Colors.white30,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    hasData && fmtDur != '—' ? fmtDur : '',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Color(0xFF00CFFF),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),

                          // ── Last column: best time (timer) OR total score + best time ──
                          Expanded(
                            flex: 2,
                            child: isTimer
                                // Timer category: show best time prominently
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      Container(
                                        padding: isTop3
                                            ? const EdgeInsets.symmetric(
                                                horizontal: 10, vertical: 3)
                                            : EdgeInsets.zero,
                                        decoration: isTop3
                                            ? BoxDecoration(
                                                borderRadius: BorderRadius.circular(6),
                                                color: rowGlow!.withOpacity(0.15),
                                                border: Border.all(
                                                    color: rowGlow.withOpacity(0.4),
                                                    width: 1),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: rowGlow.withOpacity(0.25),
                                                    blurRadius: 6,
                                                  ),
                                                ],
                                              )
                                            : null,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.timer_rounded,
                                              color: isTop3 ? rowGlow! : const Color(0xFF00FF88),
                                              size: 13,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              row['bestTimeStr'] as String? ?? '—',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: isTop3 ? rowGlow! : const Color(0xFF00FF88),
                                                fontWeight: FontWeight.w900,
                                                fontSize: isTop3 ? 18 : 16,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  )
                                // Score-based category: total score + best time below
                                : Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      Container(
                                        padding: isTop3
                                            ? const EdgeInsets.symmetric(
                                                horizontal: 10, vertical: 3)
                                            : EdgeInsets.zero,
                                        decoration: isTop3
                                            ? BoxDecoration(
                                                borderRadius: BorderRadius.circular(6),
                                                color: rowGlow!.withOpacity(0.15),
                                                border: Border.all(
                                                    color: rowGlow.withOpacity(0.4),
                                                    width: 1),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: rowGlow.withOpacity(0.25),
                                                    blurRadius: 6,
                                                  ),
                                                ],
                                              )
                                            : null,
                                        child: Text(
                                          '$total',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: isTop3 ? rowGlow! : Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: isTop3 ? 20 : 18,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          const Icon(
                                            Icons.timer_outlined,
                                            color: Color(0xFF00FF88),
                                            size: 11,
                                          ),
                                          const SizedBox(width: 3),
                                          Text(
                                            _bestDuration(rounds),
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: Color(0xFF00FF88),
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              letterSpacing: 0.4,
                                            ),
                                          ),
                                        ],
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
        "SELECT ts.match_id, ts.team_id,"
        " COALESCE(sc.score_totalscore, -1) AS score,"
        " COALESCE(sc.score_violation, 0)   AS fouls"
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

        // Track goals, fouls, matches played
        final f0 = int.tryParse(entries[0]['fouls']?.toString() ?? '0') ?? 0;
        final f1 = int.tryParse(entries[1]['fouls']?.toString() ?? '0') ?? 0;
        stat0.goalsFor     += s0;
        stat0.goalsAgainst += s1;
        stat0.fouls        += f0;
        stat0.matchesPlayed++;
        stat1.goalsFor     += s1;
        stat1.goalsAgainst += s0;
        stat1.fouls        += f1;
        stat1.matchesPlayed++;

        if (s0 > s1) {
          stat0.wins++;   stat0.points += 3;
          stat1.losses++;
        } else if (s1 > s0) {
          stat1.wins++;   stat1.points += 3;
          stat0.losses++;
        } else {
          stat0.draws++; stat0.points++;
          stat1.draws++; stat1.points++;
        }
      }

      // Build sorted group list
      final labels = groupTeamIds.keys.toList()..sort();
      final groups = labels.map((label) {
        final teams = groupTeamIds[label]!.map((tid) => teamStatMap[tid]!).toList();
        return _SoccerGroup(label: label, teams: teams);
      }).toList();

      // ── Load resolved tiebreaker winners ──────────────────────────────────
      Map<String, int> tbWinners = {};
      try {
        final tbCheck = await conn.execute(
          "SELECT COUNT(*) AS cnt FROM information_schema.tables "
          "WHERE table_schema = DATABASE() AND table_name = 'tbl_soccer_tiebreaker'",
        );
        final tbExists = (int.tryParse(
                tbCheck.rows.first.assoc()['cnt']?.toString() ?? '0') ?? 0) > 0;
        if (tbExists) {
          final tbResult = await conn.execute(
            'SELECT group_label, winner_id FROM tbl_soccer_tiebreaker '
            'WHERE category_id = $id ORDER BY group_label, tiebreaker_id',
          );
          final Map<String, List<int>> byGroup = {};
          for (final row in tbResult.rows) {
            final grp = row.assoc()['group_label']?.toString() ?? '';
            final wId = int.tryParse(row.assoc()['winner_id']?.toString() ?? '0') ?? 0;
            if (grp.isEmpty) continue;
            byGroup.putIfAbsent(grp, () => []);
            byGroup[grp]!.add(wId);
          }
          for (final entry in byGroup.entries) {
            final winners = entry.value;
            if (winners.isNotEmpty && winners.every((w) => w > 0)) {
              final freq = <int, int>{};
              for (final w in winners) freq[w] = (freq[w] ?? 0) + 1;
              final best = freq.entries.reduce((a, b) => a.value >= b.value ? a : b);
              tbWinners[entry.key] = best.key;
            }
          }
        }
      } catch (_) {}

      if (mounted) setState(() {
        _soccerGroups      = groups;
        _tiebreakerWinners = tbWinners;
      });
    } catch (e) {
      print('loadSoccerGroups error: $e');
    }
  }

  // ── Comparator used for group-stage sorting (points → GD → GF → W → name) ─
  int _cmpGroupStat(_SoccerTeamStat a, _SoccerTeamStat b) {
    if (b.points   != a.points)   return b.points.compareTo(a.points);
    if (b.goalDiff != a.goalDiff) return b.goalDiff.compareTo(a.goalDiff);
    if (b.goalsFor != a.goalsFor) return b.goalsFor.compareTo(a.goalsFor);
    if (b.wins     != a.wins)     return b.wins.compareTo(a.wins);
    return a.teamName.compareTo(b.teamName);
  }

  // ── Returns true when rank-2 and rank-3 teams in [sortedTeams] are tied ──
  // i.e. the 2nd-place slot cannot be determined yet → tie-breaker needed.
  bool _hasCutLineTie(List<_SoccerTeamStat> sortedTeams) {
    if (sortedTeams.length < 3) return false;
    final second = sortedTeams[1];
    final third  = sortedTeams[2];
    return second.points   == third.points   &&
           second.goalDiff == third.goalDiff &&
           second.goalsFor == third.goalsFor &&
           second.wins     == third.wins;
  }

  // ── Load final ranking from knockout results ──────────────────────────────
  // Reads the final, third-place, and semi-final results from tbl_score /
  // tbl_match to determine Champion (1st), Runner-up (2nd), 3rd place, 4th.
  Future<void> _loadFinalRanking({required int? catId}) async {
    if (catId == null) return;
    try {
      final conn = await DBHelper.getConnection();

      // Query: for each KO match type, get scores ordered desc
      // We read 'final' and 'third-place' matches with their scores
      final result = await conn.execute("""
        SELECT
          m.bracket_type,
          m.match_id,
          t.team_id,
          t.team_name,
          COALESCE(sc.score_totalscore, -1) AS goals
        FROM tbl_match m
        JOIN tbl_teamschedule ts ON ts.match_id = m.match_id
        JOIN tbl_team t          ON t.team_id   = ts.team_id
        LEFT JOIN tbl_score sc   ON sc.match_id = m.match_id
                                AND sc.team_id  = ts.team_id
        WHERE t.category_id = :catId
          AND m.bracket_type IN ('final', 'third-place', 'semi-finals')
        ORDER BY m.bracket_type, m.match_id, sc.score_totalscore DESC
      """, {"catId": catId});

      // Group by match_id → {bracket_type, teams: [{teamId, teamName, goals}]}
      final Map<int, Map<String, dynamic>> byMatch = {};
      for (final row in result.rows) {
        final mid  = int.tryParse(row.assoc()['match_id']?.toString() ?? '0') ?? 0;
        final bt   = row.assoc()['bracket_type']?.toString() ?? '';
        final tid  = int.tryParse(row.assoc()['team_id']?.toString() ?? '0') ?? 0;
        final name = row.assoc()['team_name']?.toString() ?? '';
        final g    = int.tryParse(row.assoc()['goals']?.toString() ?? '-1') ?? -1;
        if (mid == 0 || tid == 0) continue;
        byMatch.putIfAbsent(mid, () => {'bracketType': bt, 'teams': <Map<String, dynamic>>[]});
        (byMatch[mid]!['teams'] as List<Map<String, dynamic>>).add({
          'teamId': tid, 'teamName': name, 'goals': g,
        });
      }

      // Find the final match and third-place match
      Map<String, dynamic>? finalMatch;
      Map<String, dynamic>? thirdMatch;
      // Also collect semi-final losers as fallback for 3rd/4th if no third-place match scored
      final List<Map<String, dynamic>> semiMatches = [];

      for (final m in byMatch.values) {
        final bt = m['bracketType'] as String;
        if (bt == 'final')       finalMatch = m;
        if (bt == 'third-place') thirdMatch = m;
        if (bt == 'semi-finals') semiMatches.add(m);
      }

      final List<_FinalRankEntry> ranking = [];

      // ── Determine 1st and 2nd from Final ──────────────────────────────────
      if (finalMatch != null) {
        final teams = finalMatch['teams'] as List<Map<String, dynamic>>;
        if (teams.length == 2) {
          final t0g = teams[0]['goals'] as int;
          final t1g = teams[1]['goals'] as int;
          if (t0g >= 0 && t1g >= 0 && t0g != t1g) {
            // Scores available — determine winner
            final winner = t0g > t1g ? teams[0] : teams[1];
            final loser  = t0g > t1g ? teams[1] : teams[0];
            ranking.add(_FinalRankEntry(
              rank: 1,
              teamId:   winner['teamId'] as int,
              teamName: winner['teamName'] as String,
              goals:    winner['goals'] as int,
            ));
            ranking.add(_FinalRankEntry(
              rank: 2,
              teamId:   loser['teamId'] as int,
              teamName: loser['teamName'] as String,
              goals:    loser['goals'] as int,
            ));
          } else if (t0g < 0 && t1g < 0) {
            // Final exists but no scores yet — show as TBD
            for (int i = 0; i < teams.length; i++) {
              ranking.add(_FinalRankEntry(
                rank: i + 1,
                teamId:   teams[i]['teamId'] as int,
                teamName: teams[i]['teamName'] as String,
                goals: -1,
              ));
            }
          }
        }
      }

      // ── Determine 3rd and 4th from third-place match ──────────────────────
      if (thirdMatch != null) {
        final teams = thirdMatch['teams'] as List<Map<String, dynamic>>;
        if (teams.length == 2) {
          final t0g = teams[0]['goals'] as int;
          final t1g = teams[1]['goals'] as int;
          if (t0g >= 0 && t1g >= 0 && t0g != t1g) {
            final winner = t0g > t1g ? teams[0] : teams[1];
            final loser  = t0g > t1g ? teams[1] : teams[0];
            ranking.add(_FinalRankEntry(
              rank: 3,
              teamId:   winner['teamId'] as int,
              teamName: winner['teamName'] as String,
              goals:    winner['goals'] as int,
            ));
            ranking.add(_FinalRankEntry(
              rank: 4,
              teamId:   loser['teamId'] as int,
              teamName: loser['teamName'] as String,
              goals:    loser['goals'] as int,
            ));
          } else if (t0g < 0 && t1g < 0) {
            for (int i = 0; i < teams.length; i++) {
              ranking.add(_FinalRankEntry(
                rank: i + 3,
                teamId:   teams[i]['teamId'] as int,
                teamName: teams[i]['teamName'] as String,
                goals: -1,
              ));
            }
          }
        }
      } else if (semiMatches.length >= 2) {
        // No third-place match data yet — show semi losers as 3rd/4th TBD
        int rk = 3;
        for (final sm in semiMatches) {
          final teams = sm['teams'] as List<Map<String, dynamic>>;
          final t0g = teams.isNotEmpty ? (teams[0]['goals'] as int) : -1;
          final t1g = teams.length > 1 ? (teams[1]['goals'] as int) : -1;
          // Loser of semi = t with lower goals
          Map<String, dynamic>? loser;
          if (t0g >= 0 && t1g >= 0 && t0g != t1g) {
            loser = t0g < t1g ? teams[0] : teams[1];
          }
          if (loser != null) {
            ranking.add(_FinalRankEntry(
              rank: rk++,
              teamId:   loser['teamId'] as int,
              teamName: loser['teamName'] as String,
              goals: -1,
            ));
          }
        }
      }

      if (mounted) setState(() => _finalRanking = ranking);

      // ── Append group-stage eliminated teams (rank 3+ per group) ─────────
      // Only add if the knockout ranking already has at least 1 entry (tournament started).
      // If a group still has an unresolved cut-line tie (rank 2 == rank 3 on all criteria),
      // skip that group entirely — we cannot determine who is eliminated until tie-breaker
      // is played or resolved.
      if (ranking.isNotEmpty && _soccerGroups.isNotEmpty) {
        // Collect all teams that already appear in the ranking (qualified to KO)
        final rankedIds = ranking.map((e) => e.teamId).toSet();

        // Gather eliminated (rank 3+) from every group, skipping groups with
        // an unresolved cut-line tie between rank 2 and rank 3.
        final List<_SoccerTeamStat> eliminatedTeams = [];
        for (final g in _soccerGroups) {
          final sorted = List<_SoccerTeamStat>.from(g.teams)..sort(_cmpGroupStat);

          // If rank 2 and rank 3 are still perfectly equal → tie-breaker pending.
          // Do NOT mark anyone from this group as eliminated yet.
          if (_hasCutLineTie(sorted)) continue;

          for (int i = 2; i < sorted.length; i++) {
            if (!rankedIds.contains(sorted[i].teamId)) {
              eliminatedTeams.add(sorted[i]);
            }
          }
        }

        // Sort the eliminated pool by overall performance
        eliminatedTeams.sort(_cmpGroupStat);

        final List<_FinalRankEntry> full = List.from(ranking);
        int nextRank = (ranking.map((e) => e.rank).fold(0, (a, b) => a > b ? a : b)) + 1;
        for (final t in eliminatedTeams) {
          full.add(_FinalRankEntry(
            rank:        nextRank++,
            teamId:      t.teamId,
            teamName:    t.teamName,
            goals:       -1,
            isEliminated: true,
          ));
        }
        if (mounted) setState(() => _finalRanking = full);
      }
    } catch (e) {
      print('_loadFinalRanking error: $e');
    }
  }
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
            // ── Export standings ──────────────────────────────────────
            IconButton(
              tooltip: 'Export Standings',
              icon: const Icon(Icons.download_rounded, color: Color(0xFF00FF9C)),
              onPressed: _showExportDialog,
            ),
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
            Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.emoji_events, size: 15),
              SizedBox(width: 6),
              Text('FINAL RANKING'),
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
            // Tab 3: Final Ranking
            _buildFinalRankingView(),
          ],
        ),
      ),
    ]);
  }

  // ── Overall standing — FIFA table format ───────────────────────────────────
  Widget _buildOverallStanding() {
    if (_soccerGroups.isEmpty) {
      return const Center(child: Text('No groups generated yet.',
          style: TextStyle(color: Colors.white54, fontSize: 14)));
    }

    // ── Sort comparator ────────────────────────────────────────────────────
    int _cmp(Map<String, dynamic> a, Map<String, dynamic> b) {
      if (b['points']   != a['points'])   return (b['points']   as int).compareTo(a['points']   as int);
      if (b['goalDiff'] != a['goalDiff']) return (b['goalDiff'] as int).compareTo(a['goalDiff'] as int);
      if (b['goalsFor'] != a['goalsFor']) return (b['goalsFor'] as int).compareTo(a['goalsFor'] as int);
      if (b['wins']     != a['wins'])     return (b['wins']     as int).compareTo(a['wins']     as int);
      return (a['teamName'] as String).compareTo(b['teamName'] as String);
    }

    // ── Build per-group team lists, pick top 2 vs eliminated ──────────────
    final qualifiers  = <Map<String, dynamic>>[];
    final pending     = <Map<String, dynamic>>[];
    final eliminated  = <Map<String, dynamic>>[];

    for (final g in _soccerGroups) {
      final groupTeams = g.teams.map((t) => {
        'teamId':       t.teamId,
        'teamName':     t.teamName,
        'group':        g.label,
        'wins':         t.wins,
        'losses':       t.losses,
        'draws':        t.draws,
        'points':       t.points,
        'goalsFor':     t.goalsFor,
        'goalsAgainst': t.goalsAgainst,
        'goalDiff':     t.goalDiff,
        'fouls':        t.fouls,
        'matchesPlayed':t.matchesPlayed,
        'winPct':       t.winPct,
        'groupColor':   _groupColor(g.label),
      }).toList()..sort(_cmp);

      final statsSorted  = List<_SoccerTeamStat>.from(g.teams)..sort(_cmpGroupStat);
      final tieAtCut     = _hasCutLineTie(statsSorted);
      final tbWinnerId   = _tiebreakerWinners[g.label] ?? 0;
      final tieResolved  = tieAtCut && tbWinnerId > 0;
      final tiePending   = tieAtCut && tbWinnerId == 0;

      for (int gi = 0; gi < groupTeams.length; gi++) {
        final teamId = groupTeams[gi]['teamId'] as int;
        if (tiePending) {
          // Tie not yet resolved — rank 1 confirmed, rest in pending
          if (gi == 0) {
            qualifiers.add(groupTeams[gi]);
          } else {
            pending.add(groupTeams[gi]);
          }
        } else if (tieResolved) {
          // Tiebreaker done — rank 1 and TB winner advance, rest eliminated
          if (gi == 0 || teamId == tbWinnerId) {
            qualifiers.add(groupTeams[gi]);
          } else {
            eliminated.add(groupTeams[gi]);
          }
        } else {
          // No tie — normal top 2 advance
          if (gi < 2) {
            qualifiers.add(groupTeams[gi]);
          } else {
            eliminated.add(groupTeams[gi]);
          }
        }
      }
    }

    // Sort each bucket
    qualifiers.sort(_cmp);
    pending.sort(_cmp);
    eliminated.sort(_cmp);

    // ── Header ─────────────────────────────────────────────────────────────
    Widget hdr(String t, {int flex = 1, bool right = false, Color? color}) =>
        Expanded(flex: flex, child: Text(t,
            textAlign: right ? TextAlign.right : TextAlign.center,
            style: TextStyle(
                color: color ?? Colors.white54,
                fontSize: 14, fontWeight: FontWeight.w900,
                letterSpacing: 0.5)));

    // ── Build a single row widget ──────────────────────────────────────────
    Widget _buildRow(Map<String, dynamic> team, int rank, bool isEliminated) {
      final isEven    = rank % 2 == 0;
      final gc        = team['groupColor']    as Color;
      final name      = team['teamName']      as String;
      final group     = team['group']         as String;
      final mp        = team['matchesPlayed'] as int;
      final w         = team['wins']          as int;
      final d         = team['draws']         as int;
      final l         = team['losses']        as int;
      final pts       = team['points']        as int;
      final gf        = team['goalsFor']      as int;
      final ga        = team['goalsAgainst']  as int;
      final gd        = team['goalDiff']      as int;

      final rankColor = isEliminated ? Colors.white24 : _rankColor(rank);
      final isTop2    = !isEliminated && rank <= 2;
      final gdStr     = gd > 0 ? '+$gd' : '$gd';
      final gdColor   = isEliminated
          ? Colors.white24
          : gd > 0
              ? const Color(0xFF00FF88)
              : gd < 0 ? Colors.redAccent : Colors.white38;

      // Eliminated row: dark/dimmed styling
      final eliminatedBg   = isEven
          ? const Color(0xFF0A0518)
          : const Color(0xFF080415);

      Widget cell(String v, {int flex = 1, Color? color, bool bold = false}) =>
          Expanded(flex: flex, child: Text(v,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: color ?? (isEliminated ? Colors.white24 : Colors.white70),
                  fontSize: 16,
                  fontWeight: bold ? FontWeight.w900 : FontWeight.w600)));

      return Container(
        decoration: BoxDecoration(
          gradient: isTop2
              ? LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    rankColor.withOpacity(rank == 1 ? 0.12 : 0.07),
                    (isEven ? const Color(0xFF100838) : const Color(0xFF0C0628)),
                  ],
                )
              : null,
          color: isTop2 ? null : isEliminated
              ? eliminatedBg
              : isEven
                  ? const Color(0xFF100838)
                  : const Color(0xFF0C0628),
          border: isTop2
              ? Border(left: BorderSide(color: rankColor.withOpacity(0.7), width: 3))
              : isEliminated
                  ? const Border(left: BorderSide(color: Color(0xFF3A1A1A), width: 3))
                  : null,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: Row(children: [
          // Rank / skull
          SizedBox(width: 36, child: isEliminated
              ? Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.red.withOpacity(0.07),
                    border: Border.all(color: Colors.red.withOpacity(0.25), width: 1),
                  ),
                  child: const Center(child: Text('💀',
                      style: TextStyle(fontSize: 14))),
                )
              : isTop2
                  ? Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(colors: [
                          rankColor.withOpacity(0.3),
                          rankColor.withOpacity(0.06),
                        ]),
                        border: Border.all(color: rankColor.withOpacity(0.7), width: 1.5),
                        boxShadow: [BoxShadow(color: rankColor.withOpacity(0.35), blurRadius: 7)],
                      ),
                      child: Center(child: Text(
                          rank == 1 ? '🥇' : '🥈',
                          style: const TextStyle(fontSize: 16))),
                    )
                  : Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.05),
                        border: Border.all(color: Colors.white24, width: 1),
                      ),
                      child: Center(child: Text('$rank',
                          style: const TextStyle(color: Colors.white70,
                              fontSize: 18, fontWeight: FontWeight.w900))))),

          // Group badge + Team name
          Expanded(flex: 5, child: Row(children: [
            Container(
              width: 24, height: 24,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (isEliminated ? gc.withOpacity(0.06) : gc.withOpacity(0.15)),
                border: Border.all(
                    color: isEliminated ? gc.withOpacity(0.2) : gc.withOpacity(0.6),
                    width: 1),
              ),
              child: Center(child: Text(group,
                  style: TextStyle(
                      color: isEliminated ? gc.withOpacity(0.3) : gc,
                      fontSize: 10, fontWeight: FontWeight.w900))),
            ),
            Expanded(child: Text(name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: isEliminated
                        ? Colors.white24
                        : isTop2 ? Colors.white : Colors.white70,
                    fontSize: isTop2 ? 15 : 14,
                    fontWeight: isTop2 ? FontWeight.w900 : FontWeight.w700,
                    decoration: isEliminated ? TextDecoration.lineThrough : null,
                    decorationColor: Colors.white24))),
            if (isEliminated)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.red.withOpacity(0.25), width: 1),
                ),
                child: const Text('OUT',
                    style: TextStyle(
                        color: Colors.redAccent,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1)),
              ),
          ])),

          // M. (matches played)
          cell('$mp', flex: 1, color: isEliminated ? Colors.white24 : Colors.white54),

          // W
          cell('$w', flex: 1,
              color: isEliminated ? Colors.white24 : (w > 0 ? const Color(0xFF00FF88) : Colors.white24),
              bold: w > 0 && !isEliminated),

          // D
          cell('$d', flex: 1,
              color: isEliminated ? Colors.white24 : (d > 0 ? Colors.orange : Colors.white24)),

          // L
          cell('$l', flex: 1,
              color: isEliminated ? Colors.red.withOpacity(0.35) : (l > 0 ? Colors.redAccent : Colors.white24)),

          // Goals GF:GA
          Expanded(flex: 2, child: Text('$gf:$ga',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: isEliminated ? Colors.white24 : Colors.white70,
                  fontSize: 16, fontWeight: FontWeight.w600,
                  letterSpacing: 0.5))),

          // Dif
          cell(gdStr, flex: 1, color: gdColor, bold: gd != 0 && !isEliminated),

          // Pt.
          Expanded(flex: 1, child: Container(
            height: 30,
            decoration: BoxDecoration(
              color: isEliminated
                  ? Colors.transparent
                  : pts > 0
                      ? const Color(0xFFFFD700).withOpacity(0.12)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
              border: (!isEliminated && pts > 0)
                  ? Border.all(color: const Color(0xFFFFD700).withOpacity(0.3))
                  : null,
            ),
            child: Center(child: Text('$pts',
                style: TextStyle(
                    color: isEliminated
                        ? Colors.white24
                        : pts > 0
                            ? const Color(0xFFFFD700)
                            : Colors.white24,
                    fontSize: 16, fontWeight: FontWeight.w900))),
          )),
        ]),
      );
    }

    // ── Divider between qualifiers and eliminated ──────────────────────────
    Widget _eliminatedDivider() => Container(
      color: const Color(0xFF0D0420),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Row(children: [
        Expanded(child: Container(height: 1,
            color: Colors.red.withOpacity(0.25))),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.red.withOpacity(0.10),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.red.withOpacity(0.30), width: 1),
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Text('💀', style: TextStyle(fontSize: 11)),
            SizedBox(width: 6),
            Text('ELIMINATED',
                style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5)),
          ]),
        ),
        Expanded(child: Container(height: 1,
            color: Colors.red.withOpacity(0.25))),
      ]),
    );

    // ── Divider for tie-breaker pending section ────────────────────────────
    Widget _tieBreakerDivider() => Container(
      color: const Color(0xFF110830),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Row(children: [
        Expanded(child: Container(height: 1,
            color: const Color(0xFFFFAA00).withOpacity(0.35))),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFFFAA00).withOpacity(0.10),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: const Color(0xFFFFAA00).withOpacity(0.45), width: 1),
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Text('⚔️', style: TextStyle(fontSize: 11)),
            SizedBox(width: 6),
            Text('TIE-BREAKER PENDING',
                style: TextStyle(
                    color: Color(0xFFFFAA00),
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5)),
          ]),
        ),
        Expanded(child: Container(height: 1,
            color: const Color(0xFFFFAA00).withOpacity(0.35))),
      ]),
    );

    // ── Row for a pending (tie-breaker) team ─────────────────────────────
    Widget _buildPendingRow(Map<String, dynamic> team, int idx) {
      final isEven = idx % 2 == 0;
      final gc     = team['groupColor']    as Color;
      final name   = team['teamName']      as String;
      final group  = team['group']         as String;
      final mp     = team['matchesPlayed'] as int;
      final w      = team['wins']          as int;
      final d      = team['draws']         as int;
      final l      = team['losses']        as int;
      final pts    = team['points']        as int;
      final gf     = team['goalsFor']      as int;
      final ga     = team['goalsAgainst']  as int;
      final gd     = team['goalDiff']      as int;
      final gdStr  = gd > 0 ? '+$gd' : '$gd';
      final gdColor = gd > 0
          ? const Color(0xFF00FF88)
          : gd < 0 ? Colors.redAccent : Colors.white38;

      Widget cell(String v, {int flex = 1, Color? color, bool bold = false}) =>
          Expanded(flex: flex, child: Text(v,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: color ?? const Color(0xFFFFCC55),
                  fontSize: 16,
                  fontWeight: bold ? FontWeight.w900 : FontWeight.w600)));

      return Container(
        decoration: BoxDecoration(
          color: isEven
              ? const Color(0xFF180F08).withOpacity(0.85)
              : const Color(0xFF130C06).withOpacity(0.85),
          border: const Border(
              left: BorderSide(color: Color(0xFFFFAA00), width: 3)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: Row(children: [
          // ⚔️ icon instead of rank number
          SizedBox(width: 36, child: Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFFFAA00).withOpacity(0.12),
              border: Border.all(
                  color: const Color(0xFFFFAA00).withOpacity(0.45), width: 1.5),
            ),
            child: const Center(child: Text('⚔️',
                style: TextStyle(fontSize: 13))),
          )),

          // Group badge + team name
          Expanded(flex: 5, child: Row(children: [
            Container(
              width: 20, height: 20,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: gc.withOpacity(0.25),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: gc.withOpacity(0.6), width: 1),
              ),
              child: Center(child: Text(group,
                  style: TextStyle(
                      color: gc, fontSize: 10, fontWeight: FontWeight.w900))),
            ),
            Expanded(child: Text(name.toUpperCase(),
                style: const TextStyle(
                    color: Color(0xFFFFCC55),
                    fontSize: 14,
                    fontWeight: FontWeight.w800))),
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFFFAA00).withOpacity(0.12),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                    color: const Color(0xFFFFAA00).withOpacity(0.45), width: 1),
              ),
              child: const Text('TIE',
                  style: TextStyle(
                      color: Color(0xFFFFAA00),
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1)),
            ),
          ])),

          cell('$mp', flex: 1, color: Colors.white54),
          cell('$w',  flex: 1, color: w > 0 ? const Color(0xFF00FF88) : Colors.white24,
              bold: w > 0),
          cell('$d',  flex: 1, color: d > 0 ? Colors.orange : Colors.white24),
          cell('$l',  flex: 1, color: l > 0 ? Colors.redAccent : Colors.white24),
          Expanded(flex: 2, child: Text('$gf:$ga',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Color(0xFFFFCC55), fontSize: 16,
                  fontWeight: FontWeight.w600, letterSpacing: 0.5))),
          cell(gdStr, flex: 1, color: gdColor, bold: gd != 0),
          Expanded(flex: 1, child: Container(
            height: 30,
            decoration: BoxDecoration(
              color: pts > 0
                  ? const Color(0xFFFFAA00).withOpacity(0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
              border: pts > 0
                  ? Border.all(
                      color: const Color(0xFFFFAA00).withOpacity(0.35))
                  : null,
            ),
            child: Center(child: Text('$pts',
                style: TextStyle(
                    color: pts > 0
                        ? const Color(0xFFFFAA00)
                        : Colors.white24,
                    fontSize: 16, fontWeight: FontWeight.w900))),
          )),
        ]),
      );
    }

    // ── Build the full item list ───────────────────────────────────────────
    // Layout: qualifier rows
    //         [tie-breaker divider]  ← only if pending.isNotEmpty
    //         pending rows
    //         [eliminated divider]   ← only if eliminated.isNotEmpty
    //         eliminated rows
    final hasPending  = pending.isNotEmpty;
    final hasElim     = eliminated.isNotEmpty;
    int totalItems = qualifiers.length;
    if (hasPending)  totalItems += 1 + pending.length;
    if (hasElim)     totalItems += 1 + eliminated.length;

    return Column(children: [
      // Column header row
      Container(
        color: const Color(0xFF1A0A4A),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        child: Row(children: [
          const SizedBox(width: 36,
              child: Text('#', style: TextStyle(color: Colors.white54,
                  fontSize: 14, fontWeight: FontWeight.w900))),
          const Expanded(flex: 5, child: Text('TEAM',
              style: TextStyle(color: Colors.white54, fontSize: 14,
                  fontWeight: FontWeight.w900, letterSpacing: 0.5))),
          hdr('M.',  flex: 1),
          hdr('W',   flex: 1, color: const Color(0xFF00FF88)),
          hdr('D',   flex: 1, color: Colors.orange),
          hdr('L',   flex: 1, color: Colors.redAccent),
          hdr('GOALS', flex: 2),
          hdr('DIF', flex: 1),
          hdr('PT.', flex: 1, color: const Color(0xFFFFD700)),
        ]),
      ),
      const Divider(height: 1, color: Color(0xFF2A1A6A)),

      // Rows
      Expanded(child: ListView.builder(
        itemCount: totalItems,
        itemBuilder: (_, i) {
          // ── Qualifier rows ──────────────────────────────────────────
          if (i < qualifiers.length) {
            return _buildRow(qualifiers[i], i + 1, false);
          }

          // ── Tie-breaker pending section ─────────────────────────────
          if (hasPending) {
            final pendingStart = qualifiers.length;
            if (i == pendingStart) return _tieBreakerDivider();
            final pi = i - pendingStart - 1;
            if (pi < pending.length) {
              return _buildPendingRow(pending[pi], pi + 1);
            }
          }

          // ── Eliminated section ──────────────────────────────────────
          if (hasElim) {
            final elimStart = qualifiers.length
                + (hasPending ? 1 + pending.length : 0);
            if (i == elimStart) return _eliminatedDivider();
            final ei = i - elimStart - 1;
            if (ei < eliminated.length) {
              return _buildRow(eliminated[ei], ei + 1, true);
            }
          }

          return const SizedBox.shrink();
        },
      )),
    ]);
  }

  // ── Final Ranking View ────────────────────────────────────────────────────
  Widget _buildFinalRankingView() {
    // ── Empty state ──────────────────────────────────────────────────────────
    if (_finalRanking.isEmpty) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Color(0xFF0E0730), Color(0xFF1A0A4A)],
          ),
        ),
        child: Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            // Trophy icon with glow rings
            Stack(alignment: Alignment.center, children: [
              Container(width: 130, height: 130,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: const Color(0xFFFFD700).withOpacity(0.08), width: 1),
                )),
              Container(width: 100, height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: const Color(0xFFFFD700).withOpacity(0.15), width: 1),
                )),
              Container(width: 72, height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    const Color(0xFFFFD700).withOpacity(0.18),
                    const Color(0xFFFFD700).withOpacity(0.02),
                  ]),
                  border: Border.all(
                      color: const Color(0xFFFFD700).withOpacity(0.4), width: 1.5),
                  boxShadow: [BoxShadow(
                      color: const Color(0xFFFFD700).withOpacity(0.25),
                      blurRadius: 24)],
                ),
                child: const Center(child: Text('🏆',
                    style: TextStyle(fontSize: 34)))),
            ]),
            const SizedBox(height: 28),
            const Text('TOURNAMENT NOT FINISHED',
                style: TextStyle(
                    color: Color(0xFFFFD700),
                    fontSize: 15, fontWeight: FontWeight.w900,
                    letterSpacing: 2)),
            const SizedBox(height: 10),
            const Text(
                'Complete the knockout stage to reveal\nthe final rankings.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white30,
                    fontSize: 13, height: 1.6)),
          ]),
        ),
      );
    }

    // ── Sort entries ─────────────────────────────────────────────────────────
    final sorted = List<_FinalRankEntry>.from(_finalRanking)
      ..sort((a, b) => a.rank.compareTo(b.rank));

    final top3      = sorted.where((e) => e.rank <= 3 && !e.isEliminated).toList();
    final others    = sorted.where((e) => e.rank >  3 && !e.isEliminated).toList();
    final eliminated = sorted.where((e) => e.isEliminated).toList();

    // Colors per rank
    Color _rc(int rank) {
      switch (rank) {
        case 1:  return const Color(0xFFFFD700);
        case 2:  return const Color(0xFFE8E8E8);
        case 3:  return const Color(0xFFCD7F32);
        default: return const Color(0xFF00CFFF);
      }
    }
    String _emoji(int rank) {
      switch (rank) {
        case 1:  return '🏆';
        case 2:  return '🥈';
        case 3:  return '🥉';
        default: return '$rank';
      }
    }
    String _rlabel(int rank) {
      switch (rank) {
        case 1:  return 'CHAMPION';
        case 2:  return 'RUNNER-UP';
        case 3:  return '3RD PLACE';
        default: return '${rank}TH PLACE';
      }
    }

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [Color(0xFF0A051E), Color(0xFF130742)],
        ),
      ),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

          // ══════════════════════════════════════════════════════════════════
          // HERO HEADER
          // ══════════════════════════════════════════════════════════════════
          Container(
            padding: const EdgeInsets.fromLTRB(0, 32, 0, 0),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFFFFD700).withOpacity(0.07),
                  Colors.transparent,
                ],
              ),
            ),
            child: Column(children: [
              // Sparkle line
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _sparkle(), const SizedBox(width: 8),
                _sparkle(), const SizedBox(width: 12),
                const Text('✦', style: TextStyle(
                    color: Color(0xFFFFD700), fontSize: 16)),
                const SizedBox(width: 12),
                _sparkle(), const SizedBox(width: 8),
                _sparkle(),
              ]),
              const SizedBox(height: 10),
              const Text('FINAL RANKING',
                  style: TextStyle(
                      color: Color(0xFFFFD700),
                      fontSize: 28, fontWeight: FontWeight.w900,
                      letterSpacing: 4)),
              const SizedBox(height: 4),
              Text('ROBOVENTURE  •  PHILIPPINE ROBOTICS CUP',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.3),
                      fontSize: 10, letterSpacing: 2,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 20),
              // Divider with trophy
              Row(children: [
                Expanded(child: Container(height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                        Colors.transparent,
                        const Color(0xFFFFD700).withOpacity(0.4),
                      ]),
                    ))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(colors: [
                        const Color(0xFFFFD700).withOpacity(0.20),
                        const Color(0xFFFFD700).withOpacity(0.03),
                      ]),
                      border: Border.all(
                          color: const Color(0xFFFFD700).withOpacity(0.5)),
                      boxShadow: [BoxShadow(
                          color: const Color(0xFFFFD700).withOpacity(0.3),
                          blurRadius: 12)],
                    ),
                    child: const Center(child: Text('🏆',
                        style: TextStyle(fontSize: 18))),
                  ),
                ),
                Expanded(child: Container(height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                        const Color(0xFFFFD700).withOpacity(0.4),
                        Colors.transparent,
                      ]),
                    ))),
              ]),
            ]),
          ),

          // ══════════════════════════════════════════════════════════════════
          // VISUAL PODIUM — top 3 side by side (2nd | 1st | 3rd)
          // ══════════════════════════════════════════════════════════════════
          if (top3.isNotEmpty) ...[
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _buildPodium(top3, _rc, _emoji, _rlabel),
            ),
          ],

          // ══════════════════════════════════════════════════════════════════
          // 4TH PLACE + BEYOND — horizontal slim cards
          // ══════════════════════════════════════════════════════════════════
          if (others.isNotEmpty) ...[
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                Expanded(child: Divider(color: Colors.white.withOpacity(0.08))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('OTHER FINALISTS',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.25),
                          fontSize: 10, letterSpacing: 1.5,
                          fontWeight: FontWeight.w700)),
                ),
                Expanded(child: Divider(color: Colors.white.withOpacity(0.08))),
              ]),
            ),
            const SizedBox(height: 12),
            ...others.map((e) => _buildSlimRankCard(e, _rc(e.rank), _emoji(e.rank), _rlabel(e.rank))),
          ],

          // ══════════════════════════════════════════════════════════════════
          // ELIMINATED — group stage losers with dimmed styling
          // ══════════════════════════════════════════════════════════════════
          if (eliminated.isNotEmpty) ...[
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                Expanded(child: Divider(color: Colors.red.withOpacity(0.25))),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.red.withOpacity(0.30), width: 1),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('💀', style: TextStyle(fontSize: 11)),
                    SizedBox(width: 6),
                    Text('ELIMINATED',
                        style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.5)),
                  ]),
                ),
                Expanded(child: Divider(color: Colors.red.withOpacity(0.25))),
              ]),
            ),
            const SizedBox(height: 12),
            ...eliminated.map((e) => _buildEliminatedRankCard(e)),
          ],

          // ── Footer note ──────────────────────────────────────────────────
          const SizedBox(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.03),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withOpacity(0.06)),
              ),
              child: Row(children: [
                const Icon(Icons.info_outline, color: Colors.white24, size: 13),
                const SizedBox(width: 8),
                const Expanded(child: Text(
                  'Based on knockout results — Final & 3rd Place match. '
                  'Separate from Group Stage standings.',
                  style: TextStyle(color: Colors.white24,
                      fontSize: 10, height: 1.4),
                )),
              ]),
            ),
          ),
          const SizedBox(height: 32),
        ]),
      ),
    );
  }

  // ── Visual podium widget ──────────────────────────────────────────────────
  // Arranges: 2nd (left) | 1st (center, tallest) | 3rd (right)
  Widget _buildPodium(
    List<_FinalRankEntry> top3,
    Color Function(int) rc,
    String Function(int) emoji,
    String Function(int) rlabel,
  ) {
    // Map rank → entry
    final Map<int, _FinalRankEntry> byRank = {
      for (final e in top3) e.rank: e,
    };

    // Display order: 2nd, 1st, 3rd
    final displayOrder = [2, 1, 3];
    final podiumHeights = {1: 110.0, 2: 80.0, 3: 60.0};

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: displayOrder.map((rank) {
        final entry   = byRank[rank];
        final color   = rc(rank);
        final em      = emoji(rank);
        final label   = rlabel(rank);
        final podH    = podiumHeights[rank]!;
        final isFirst = rank == 1;
        final pending = entry == null || entry.goals < 0;
        final name    = entry?.teamName ?? '— TBD —';

        return Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ── Avatar circle with emoji ────────────────────────────────
              Stack(alignment: Alignment.topRight, children: [
                Container(
                  width: isFirst ? 88 : 68,
                  height: isFirst ? 88 : 68,
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      color.withOpacity(isFirst ? 0.35 : 0.20),
                      color.withOpacity(0.04),
                    ]),
                    border: Border.all(
                        color: color.withOpacity(isFirst ? 0.80 : 0.55),
                        width: isFirst ? 2.5 : 1.8),
                    boxShadow: [BoxShadow(
                        color: color.withOpacity(isFirst ? 0.45 : 0.20),
                        blurRadius: isFirst ? 28 : 14,
                        spreadRadius: isFirst ? 2 : 0)],
                  ),
                  child: Center(child: Text(em,
                      style: TextStyle(fontSize: isFirst ? 38 : 28))),
                ),

              ]),

              // ── Team name ──────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  pending ? '— TBD —' : name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: pending ? Colors.white24 : Colors.white,
                    fontSize: isFirst ? 20 : 17,
                    fontWeight: FontWeight.w900,
                    height: 1.2,
                    letterSpacing: 0.3,
                    fontStyle: pending ? FontStyle.italic : FontStyle.normal,
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // ── Podium block ───────────────────────────────────────────
              Container(
                height: podH,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      color.withOpacity(isFirst ? 0.30 : 0.18),
                      color.withOpacity(0.05),
                    ],
                  ),
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(10)),
                  border: Border(
                    top:   BorderSide(color: color.withOpacity(0.6),
                        width: isFirst ? 2.5 : 1.5),
                    left:  BorderSide(color: color.withOpacity(0.3), width: 1),
                    right: BorderSide(color: color.withOpacity(0.3), width: 1),
                  ),
                  boxShadow: [BoxShadow(
                      color: color.withOpacity(isFirst ? 0.25 : 0.10),
                      blurRadius: 20, offset: const Offset(0, -4))],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Rank number big
                    Text(rank == 1 ? '1ST' : rank == 2 ? '2ND' : '3RD',
                        style: TextStyle(
                            color: color,
                            fontSize: isFirst ? 22 : 16,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1)),
                    const SizedBox(height: 3),
                    // Label
                    Text(label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: color.withOpacity(0.7),
                            fontSize: 8, fontWeight: FontWeight.w700,
                            letterSpacing: 0.8)),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ── Slim rank card for 4th place and beyond ───────────────────────────────
  Widget _buildSlimRankCard(
      _FinalRankEntry entry, Color color, String em, String label) {
    final pending = entry.goals < 0;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0828),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.25), width: 1),
        boxShadow: [BoxShadow(
            color: color.withOpacity(0.06), blurRadius: 10)],
      ),
      child: Row(children: [
        // Rank badge
        Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [
              color.withOpacity(0.15),
              color.withOpacity(0.02),
            ]),
            border: Border.all(color: color.withOpacity(0.4), width: 1.5),
          ),
          child: Center(child: Text(em,
              style: TextStyle(
                  color: color,
                  fontSize: 14, fontWeight: FontWeight.w900))),
        ),
        const SizedBox(width: 14),
        // Label + name
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(
                color: color.withOpacity(0.6),
                fontSize: 9, fontWeight: FontWeight.w900,
                letterSpacing: 1)),
            const SizedBox(height: 3),
            Text(pending ? '— TBD —' : entry.teamName,
                style: TextStyle(
                    color: pending ? Colors.white24 : Colors.white70,
                    fontSize: 18, fontWeight: FontWeight.w800,
                    fontStyle: pending ? FontStyle.italic : FontStyle.normal)),
          ],
        )),
      ]),
    );
  }

  // ── Eliminated rank card — dimmed styling ────────────────────────────────
  Widget _buildEliminatedRankCard(_FinalRankEntry entry) {
    String ordinal;
    switch (entry.rank) {
      case 1:  ordinal = 'CHAMPION';   break;
      case 2:  ordinal = 'RUNNER-UP';  break;
      case 3:  ordinal = '3RD PLACE';  break;
      case 4:  ordinal = '4TH PLACE';  break;
      default: ordinal = '${entry.rank}TH PLACE';
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF080518),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.withOpacity(0.18), width: 1),
      ),
      child: Row(children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.red.withOpacity(0.07),
            border: Border.all(color: Colors.red.withOpacity(0.25), width: 1),
          ),
          child: Center(child: Text(
            "${entry.rank}",
            style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 13, fontWeight: FontWeight.w900),
          )),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ordinal,
                style: TextStyle(
                    color: Colors.red.withOpacity(0.4),
                    fontSize: 9, fontWeight: FontWeight.w900,
                    letterSpacing: 1)),
            const SizedBox(height: 2),
            Text(entry.teamName,
                style: const TextStyle(
                    color: Colors.white30,
                    fontSize: 16, fontWeight: FontWeight.w700)),
          ],
        )),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.red.withOpacity(0.08),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: Colors.red.withOpacity(0.2)),
          ),
          child: const Text('OUT',
              style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: 9, fontWeight: FontWeight.w900,
                  letterSpacing: 1)),
        ),
      ]),
    );
  }

  // ── Sparkle dot helper ────────────────────────────────────────────────────
  Widget _sparkle() => Container(
    width: 4, height: 4,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: const Color(0xFFFFD700).withOpacity(0.5),
    ),
  );
  Widget _statPill(String label, String value, Color color) =>
      Expanded(child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Column(children: [
          Text(value, style: TextStyle(color: color,
              fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: color.withOpacity(0.6),
              fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
        ]),
      ));

  // ── Stat bar with percentage ──────────────────────────────────────────────
  Widget _statBar({
    required String label,
    required String value,
    required double pct,
    required Color  color,
    bool invertColor = false,
  }) {
    final barColor = invertColor
        ? Color.lerp(const Color(0xFF00FF88), Colors.redAccent, pct)!
        : color;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label, style: TextStyle(
            color: Colors.white.withOpacity(0.4),
            fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
        const Spacer(),
        Text(value, style: TextStyle(
            color: barColor,
            fontSize: 12, fontWeight: FontWeight.w900)),
      ]),
      const SizedBox(height: 5),
      Stack(children: [
        // Background track
        Container(
          height: 6,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        // Filled bar
        FractionallySizedBox(
          widthFactor: pct.clamp(0.0, 1.0),
          child: Container(
            height: 6,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                barColor.withOpacity(0.9),
                barColor.withOpacity(0.4),
              ]),
              borderRadius: BorderRadius.circular(3),
              boxShadow: [BoxShadow(
                  color: barColor.withOpacity(0.4),
                  blurRadius: 4)],
            ),
          ),
        ),
      ]),
    ]);
  }


  Widget _buildGroupGrid() {
    const int cols = 4;
    final rows = <List<_SoccerGroup>>[];
    for (int i = 0; i < _soccerGroups.length; i += cols) {
      rows.add(_soccerGroups.sublist(i, (i + cols).clamp(0, _soccerGroups.length)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows.map((rowGroups) {
        final filledChildren = <Widget>[
          ...rowGroups.map((g) => Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: _buildGroupStandingCard(g),
            ),
          )),
          ...List.generate(cols - rowGroups.length, (_) => const Expanded(child: SizedBox())),
        ];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: filledChildren),
        );
      }).toList(),
    );
  }

  Widget _buildGroupStandingCard(_SoccerGroup group) {
    final groupCol    = _groupColor(group.label);
    final sorted      = List<_SoccerTeamStat>.from(group.teams)
      ..sort(_cmpGroupStat);

    final tieAtCut    = _hasCutLineTie(sorted);
    final tbWinnerId  = _tiebreakerWinners[group.label] ?? 0;
    final tieResolved = tieAtCut && tbWinnerId > 0;
    final tiePending  = tieAtCut && tbWinnerId == 0;

    // FIFA-style column header helper
    Widget col(String t, {Color color = Colors.white38}) =>
        SizedBox(width: 32, child: Text(t,
            textAlign: TextAlign.center,
            style: TextStyle(color: color, fontSize: 11,
                fontWeight: FontWeight.bold, letterSpacing: 0.5)));

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F0A2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: tiePending
              ? const Color(0xFFFFAA00).withOpacity(0.55)
              : tieResolved
                  ? const Color(0xFF00FF88).withOpacity(0.50)
                  : groupCol.withOpacity(0.4),
          width: (tiePending || tieResolved) ? 2 : 1.5,
        ),
        boxShadow: [BoxShadow(
          color: tiePending
              ? const Color(0xFFFFAA00).withOpacity(0.12)
              : tieResolved
                  ? const Color(0xFF00FF88).withOpacity(0.10)
                  : groupCol.withOpacity(0.08),
          blurRadius: 12,
        )],
      ),
      child: Column(children: [
        // ── Group header ────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
                colors: [groupCol.withOpacity(0.35), groupCol.withOpacity(0.08)]),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
          ),
          child: Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: groupCol.withOpacity(0.2),
                  border: Border.all(color: groupCol, width: 1.5)),
              child: Center(child: Text(group.label,
                  style: TextStyle(color: groupCol,
                      fontWeight: FontWeight.w900, fontSize: 15))),
            ),
            const SizedBox(width: 8),
            Text('GROUP ${group.label}',
                style: const TextStyle(color: Colors.white, fontSize: 14,
                    fontWeight: FontWeight.w900, letterSpacing: 1.5)),
            if (tiePending) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFAA00).withOpacity(0.18),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: const Color(0xFFFFAA00).withOpacity(0.6), width: 1),
                ),
                child: const Text('⚔️ TIE',
                    style: TextStyle(
                        color: Color(0xFFFFAA00),
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.8)),
              ),
            ] else if (tieResolved) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF00FF88).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: const Color(0xFF00FF88).withOpacity(0.55), width: 1),
                ),
                child: const Text('✓ RESOLVED',
                    style: TextStyle(
                        color: Color(0xFF00FF88),
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.8)),
              ),
            ],
          ]),
        ),
        // ── Column headers: P W D L GD PTS ─────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.04),
            border: Border(bottom: BorderSide(color: groupCol.withOpacity(0.2))),
          ),
          child: Row(children: [
            const SizedBox(width: 28),
            const SizedBox(width: 6),
            const Expanded(child: Text('TEAM',
                style: TextStyle(color: Colors.white38, fontSize: 11,
                    fontWeight: FontWeight.bold, letterSpacing: 0.8))),
            col('P'),
            col('W',  color: const Color(0xFF00FF88)),
            col('D',  color: Colors.orange),
            col('L',  color: Colors.redAccent),
            col('GD', color: Colors.white38),
            col('PTS',color: const Color(0xFFFFD700)),
          ]),
        ),
        // ── Team rows ───────────────────────────────────────────────
        ...sorted.asMap().entries.map((e) {
          final rank   = e.key + 1;
          final team   = e.value;

          final bool isPendingTie = tiePending && rank >= 2;
          final bool isEliminated = tieResolved
              ? (rank == 1 ? false : team.teamId != tbWinnerId)
              : (!tiePending && rank > 2);
          final bool advances    = !isEliminated && !isPendingTie;
          final bool isFirst     = rank == 1;
          final bool isTbWinner  = tieResolved && team.teamId == tbWinnerId;

          final badgeCol = isPendingTie
              ? const Color(0xFFFFAA00)
              : isEliminated
                  ? Colors.white12
                  : isFirst
                      ? const Color(0xFFFFD700)
                      : const Color(0xFF00FF88);
          final textCol = isPendingTie
              ? const Color(0xFFFFCC55)
              : isEliminated
                  ? Colors.white24
                  : Colors.white;
          final gd    = team.goalDiff;
          final gdStr = gd > 0 ? '+$gd' : '$gd';
          final gdColor = gd > 0
              ? const Color(0xFF00FF88)
              : gd < 0
                  ? Colors.redAccent
                  : Colors.white38;

          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              gradient: (advances || isPendingTie)
                  ? LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        badgeCol.withOpacity(isFirst ? 0.12 : 0.06),
                        Colors.transparent,
                      ],
                    )
                  : null,
              color: isEliminated ? const Color(0xFF080415) : null,
              border: Border(
                bottom: BorderSide(color: Colors.white.withOpacity(0.04), width: 1),
                left: (advances || isPendingTie)
                    ? BorderSide(color: badgeCol.withOpacity(0.7), width: 2.5)
                    : isEliminated
                        ? const BorderSide(color: Color(0xFF3A1A1A), width: 2.5)
                        : BorderSide.none,
              ),
            ),
            child: Row(children: [
              // Rank badge
              Container(
                width: 28, height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: (advances || isPendingTie)
                      ? RadialGradient(colors: [
                          badgeCol.withOpacity(0.3),
                          badgeCol.withOpacity(0.06),
                        ])
                      : null,
                  color: (advances || isPendingTie)
                      ? null
                      : isEliminated
                          ? Colors.red.withOpacity(0.08)
                          : Colors.white.withOpacity(0.03),
                  border: Border.all(
                      color: (advances || isPendingTie)
                          ? badgeCol
                          : isEliminated
                              ? Colors.red.withOpacity(0.25)
                              : Colors.white12,
                      width: 1),
                  boxShadow: (advances || isPendingTie)
                      ? [BoxShadow(color: badgeCol.withOpacity(0.35), blurRadius: 6)]
                      : null,
                ),
                child: Center(
                  child: isPendingTie
                      ? const Text('⚔️', style: TextStyle(fontSize: 11))
                      : isEliminated
                          ? const Text('💀', style: TextStyle(fontSize: 11))
                          : isTbWinner
                              ? const Text('✓', style: TextStyle(
                                  color: Color(0xFF00FF88),
                                  fontSize: 13, fontWeight: FontWeight.w900))
                              : advances && isFirst
                                  ? const Text('★', style: TextStyle(
                                      color: Color(0xFFFFD700), fontSize: 11))
                                  : advances
                                      ? const Icon(Icons.arrow_upward_rounded,
                                          size: 12, color: Color(0xFF00FF88))
                                      : Text('$rank',
                                          style: const TextStyle(color: Colors.white54,
                                              fontSize: 14, fontWeight: FontWeight.w900)),
                ),
              ),
              const SizedBox(width: 6),
              // Team name
              Expanded(child: Text(team.teamName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textCol,
                    fontSize: (advances || isPendingTie) ? 14 : 13,
                    fontWeight: (advances || isPendingTie)
                        ? FontWeight.w900
                        : FontWeight.w400,
                    decoration: isEliminated ? TextDecoration.lineThrough : null,
                    decorationColor: Colors.white24,
                    shadows: advances && isFirst
                        ? [const Shadow(color: Color(0x66FFD700), blurRadius: 8)]
                        : null,
                  ))),
              // P (played)
              SizedBox(width: 32, child: Text('${team.matchesPlayed}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54,
                      fontSize: 13, fontWeight: FontWeight.bold))),
              // W
              SizedBox(width: 32, child: Text('${team.wins}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: team.wins > 0
                          ? const Color(0xFF00FF88)
                          : Colors.white24,
                      fontSize: 13, fontWeight: FontWeight.bold))),
              // D
              SizedBox(width: 32, child: Text('${team.draws}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: team.draws > 0
                          ? Colors.orange
                          : Colors.white24,
                      fontSize: 13, fontWeight: FontWeight.bold))),
              // L
              SizedBox(width: 32, child: Text('${team.losses}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: team.losses > 0
                          ? Colors.redAccent
                          : Colors.white24,
                      fontSize: 13, fontWeight: FontWeight.bold))),
              // GD
              SizedBox(width: 32, child: Text(gdStr,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: gdColor,
                      fontSize: 13, fontWeight: FontWeight.bold))),
              // PTS
              SizedBox(width: 32, child: Container(
                height: 26,
                decoration: BoxDecoration(
                  color: team.points > 0
                      ? const Color(0xFFFFD700).withOpacity(0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Center(child: Text('${team.points}',
                    style: TextStyle(
                        color: team.points > 0
                            ? const Color(0xFFFFD700)
                            : Colors.white24,
                        fontSize: 13, fontWeight: FontWeight.w900))),
              )),
            ]),
          );
        }),
        // Footer
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              tieResolved
                  ? const Color(0xFF00FF88).withOpacity(0.08)
                  : tiePending
                      ? const Color(0xFFFFAA00).withOpacity(0.08)
                      : const Color(0xFF00FF88).withOpacity(0.08),
              Colors.transparent,
            ]),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(11)),
            border: Border(top: BorderSide(color: groupCol.withOpacity(0.2))),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (tieResolved)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: const Color(0xFF00FF88).withOpacity(0.10),
                  border: Border.all(color: const Color(0xFF00FF88).withOpacity(0.4), width: 1),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('✓', style: TextStyle(color: Color(0xFF00FF88),
                      fontSize: 10, fontWeight: FontWeight.w900)),
                  SizedBox(width: 4),
                  Text('TIEBREAKER RESOLVED', style: TextStyle(
                      color: Color(0xFF00FF88), fontSize: 9,
                      fontWeight: FontWeight.w900, letterSpacing: 0.8)),
                ]),
              )
            else if (tiePending)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: const Color(0xFFFFAA00).withOpacity(0.10),
                  border: Border.all(color: const Color(0xFFFFAA00).withOpacity(0.35), width: 1),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('⚔️', style: TextStyle(fontSize: 9)),
                  SizedBox(width: 4),
                  Text('TIE-BREAKER PENDING', style: TextStyle(
                      color: Color(0xFFFFAA00), fontSize: 9,
                      fontWeight: FontWeight.w900, letterSpacing: 0.8)),
                ]),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: const Color(0xFF00FF88).withOpacity(0.10),
                  border: Border.all(color: const Color(0xFF00FF88).withOpacity(0.3), width: 1),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.arrow_upward_rounded, color: Color(0xFF00FF88), size: 10),
                  SizedBox(width: 4),
                  Text('TOP 2 ADVANCE', style: TextStyle(
                      color: Color(0xFF00FF88), fontSize: 9,
                      fontWeight: FontWeight.w900, letterSpacing: 0.8)),
                ]),
              ),
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

  /// Returns true for categories that rank by fastest time (navigation, line tracing).
  bool _isTimerCategory(String categoryName) {
    final n = categoryName.toLowerCase();
    return n.contains('navigation') || n.contains('line tracing') || n.contains('line-tracing');
  }

  /// Parses "MM:SS" → total seconds.
  /// Returns 999999 for missing / zero times so those teams sort to the bottom.
  int _parseDurationSeconds(String dur) {
    final parts = dur.split(':');
    if (parts.length < 2) return 999999;
    final m = int.tryParse(parts[0]) ?? 0;
    final s = int.tryParse(parts[1]) ?? 0;
    final total = m * 60 + s;
    return total == 0 ? 999999 : total;
  }

  /// Ensures duration is displayed as MM:SS (zero-padded).
  String _formatDuration(String dur) {
    if (dur.isEmpty || dur == '00:00') return '—';
    final parts = dur.split(':');
    if (parts.length < 2) return dur;
    final m = (int.tryParse(parts[0]) ?? 0).toString().padLeft(2, '0');
    final s = (int.tryParse(parts[1]) ?? 0).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Returns the best (fastest, i.e. shortest) duration string across all rounds.
  String _bestDuration(Map<int, Map<String, dynamic>> rounds) {
    if (rounds.isEmpty) return '—';
    int    bestSecs     = 999999;
    String bestDuration = '—';
    for (final r in rounds.values) {
      final dur  = r['duration'] as String? ?? '';
      final secs = _parseDurationSeconds(dur);
      if (secs < bestSecs) {
        bestSecs     = secs;
        bestDuration = _formatDuration(dur);
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
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFF1A0550), Color(0xFF2D0E7A), Color(0xFF1A0A4A)],
        ),
        border: const Border(bottom: BorderSide(color: Color(0xFF00CFFF), width: 1.5)),
        boxShadow: [
          BoxShadow(color: const Color(0xFF00CFFF).withOpacity(0.12),
              blurRadius: 16, offset: const Offset(0, 4)),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 10),
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
              crossAxisAlignment: CrossAxisAlignment.center,
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
          // ── Floating CenterLogo ─────────────────────────────
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
    );
  }

  // ── Export Dialog ─────────────────────────────────────────────────────────
  void _showExportDialog() {
    // Convert internal soccer group model to the export DTO
    List<SoccerGroupExport> _toExportGroups() {
      return _soccerGroups.map((g) => SoccerGroupExport(
        label: g.label,
        teams: g.teams.map((t) => SoccerTeamExport(
          teamName:     t.teamName,
          wins:         t.wins,
          losses:       t.losses,
          draws:        t.draws,
          points:       t.points,
          goalsFor:     t.goalsFor,
          goalsAgainst: t.goalsAgainst,
          fouls:        t.fouls,
          matchesPlayed:t.matchesPlayed,
        )).toList(),
      )).toList();
    }

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A0A4A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF00FF9C), width: 1.5),
        ),
        title: const Row(children: [
          Icon(Icons.download_rounded, color: Color(0xFF00FF9C), size: 22),
          SizedBox(width: 10),
          Text('Export Standings',
              style: TextStyle(color: Colors.white,
                  fontWeight: FontWeight.w900, fontSize: 18)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Choose a format to export the current standings:',
                style: TextStyle(color: Colors.white70, height: 1.5)),
            const SizedBox(height: 20),
            // ── PDF row ────────────────────────────────────────────────
            _ExportOptionTile(
              icon: Icons.picture_as_pdf_rounded,
              label: 'Export as PDF',
              subtitle: 'Printable standings report',
              color: const Color(0xFFFF6B6B),
              onTap: () {
                Navigator.of(context).pop();
                ExportService.exportStandingsToPdf(
                  context:             context,
                  categories:          _categories,
                  standingsByCategory: _standingsByCategory,
                  soccerGroups:        _toExportGroups(),
                );
              },
            ),
            const SizedBox(height: 12),
            // ── Excel row ──────────────────────────────────────────────
            _ExportOptionTile(
              icon: Icons.table_chart_rounded,
              label: 'Export as Excel',
              subtitle: 'Spreadsheet with all categories',
              color: const Color(0xFF00E5A0),
              onTap: () {
                Navigator.of(context).pop();
                ExportService.exportStandingsToExcel(
                  context:             context,
                  categories:          _categories,
                  standingsByCategory: _standingsByCategory,
                  soccerGroups:        _toExportGroups(),
                );
              },
            ),
            const SizedBox(height: 20),
            const Divider(color: Colors.white12),
            const SizedBox(height: 12),
            const Text('Attendance Records',
                style: TextStyle(color: Colors.white54, fontSize: 12,
                    fontWeight: FontWeight.bold, letterSpacing: 1)),
            const SizedBox(height: 10),
            // ── Attendance PDF ─────────────────────────────────────────
            _ExportOptionTile(
              icon: Icons.people_alt_rounded,
              label: 'Attendance → PDF',
              subtitle: 'Teams, players & match counts',
              color: const Color(0xFFFFD700),
              onTap: () {
                Navigator.of(context).pop();
                ExportService.exportAttendanceToPdf(context);
              },
            ),
            const SizedBox(height: 12),
            // ── Attendance Excel ───────────────────────────────────────
            _ExportOptionTile(
              icon: Icons.grid_on_rounded,
              label: 'Attendance → Excel',
              subtitle: 'Teams, players & match counts',
              color: const Color(0xFFFF9F43),
              onTap: () {
                Navigator.of(context).pop();
                ExportService.exportAttendanceToExcel(context);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
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

// ── Export option tile ────────────────────────────────────────────────────────
class _ExportOptionTile extends StatefulWidget {
  final IconData  icon;
  final String    label;
  final String    subtitle;
  final Color     color;
  final VoidCallback onTap;
  const _ExportOptionTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });
  @override
  State<_ExportOptionTile> createState() => _ExportOptionTileState();
}

class _ExportOptionTileState extends State<_ExportOptionTile> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _hovered
                ? widget.color.withOpacity(0.12)
                : widget.color.withOpacity(0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _hovered
                  ? widget.color
                  : widget.color.withOpacity(0.3),
              width: 1.5,
            ),
          ),
          child: Row(children: [
            Icon(widget.icon, color: widget.color, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.label,
                        style: TextStyle(
                            color: widget.color,
                            fontWeight: FontWeight.w800,
                            fontSize: 13)),
                    const SizedBox(height: 2),
                    Text(widget.subtitle,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                  ]),
            ),
            Icon(Icons.chevron_right_rounded,
                color: widget.color.withOpacity(0.5), size: 18),
          ]),
        ),
      ),
    );
  }
}

// ── Soccer group data models ─────────────────────────────────────────────────
class _SoccerTeamStat {
  final int    teamId;
  final String teamName;
  int wins          = 0;
  int losses        = 0;
  int draws         = 0;
  int points        = 0;
  int goalsFor      = 0;
  int goalsAgainst  = 0;
  int fouls         = 0;
  int matchesPlayed = 0;
  int get goalDiff  => goalsFor - goalsAgainst;
  double get winPct => matchesPlayed == 0 ? 0 : wins / matchesPlayed;
  _SoccerTeamStat({required this.teamId, required this.teamName});
}

class _SoccerGroup {
  final String              label;
  final List<_SoccerTeamStat> teams;
  _SoccerGroup({required this.label, required this.teams});
}

// ── Final ranking entry model ─────────────────────────────────────────────────
class _FinalRankEntry {
  final int    rank;
  final int    teamId;
  final String teamName;
  final int    goals;        // -1 = pending/not yet played
  final bool   isEliminated; // true = eliminated at group stage
  const _FinalRankEntry({
    required this.rank,
    required this.teamId,
    required this.teamName,
    required this.goals,
    this.isEliminated = false,
  });
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