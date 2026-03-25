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

  // category_id → { team_id → previous rank } for delta arrows
  Map<int, Map<int, int>> _previousRanks = {};

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
                  IconButton(
                    tooltip: 'Accomplishment Report',
                    icon: const Icon(Icons.emoji_events_rounded,
                        color: Color(0xFFFFD700)),
                    onPressed: _showAccomplishmentReport,
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
              tooltip: 'Accomplishment Report',
              icon: const Icon(Icons.emoji_events_rounded, color: Color(0xFFFFD700)),
              onPressed: _showAccomplishmentReport,
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

  // ── Overall standing — FIFA table format ───────────────────────────────────
  Widget _buildOverallStanding() {
    if (_soccerGroups.isEmpty) {
      return const Center(child: Text('No groups generated yet.',
          style: TextStyle(color: Colors.white54, fontSize: 14)));
    }

    final allTeams = <Map<String, dynamic>>[];
    for (final g in _soccerGroups) {
      for (final t in g.teams) {
        allTeams.add({
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
        });
      }
    }
    allTeams.sort((a, b) {
      if (b['points']   != a['points'])   return (b['points']   as int).compareTo(a['points']   as int);
      if (b['goalDiff'] != a['goalDiff']) return (b['goalDiff'] as int).compareTo(a['goalDiff'] as int);
      if (b['goalsFor'] != a['goalsFor']) return (b['goalsFor'] as int).compareTo(a['goalsFor'] as int);
      if (b['wins']     != a['wins'])     return (b['wins']     as int).compareTo(a['wins']     as int);
      return (a['teamName'] as String).compareTo(b['teamName'] as String);
    });

    // ── Header ─────────────────────────────────────────────────────────────
    Widget hdr(String t, {int flex = 1, bool right = false, Color? color}) =>
        Expanded(flex: flex, child: Text(t,
            textAlign: right ? TextAlign.right : TextAlign.center,
            style: TextStyle(
                color: color ?? Colors.white54,
                fontSize: 14, fontWeight: FontWeight.w900,
                letterSpacing: 0.5)));

    return Column(children: [
      // ── Column header row ─────────────────────────────────────────────
      Container(
        color: const Color(0xFF1A0A4A),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        child: Row(children: [
          // #
          const SizedBox(width: 36,
              child: Text('#', style: TextStyle(color: Colors.white54,
                  fontSize: 14, fontWeight: FontWeight.w900))),
          // Team
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

      // ── Rows ─────────────────────────────────────────────────────────
      Expanded(child: ListView.builder(
        itemCount: allTeams.length,
        itemBuilder: (_, i) {
          final team   = allTeams[i];
          final rank   = i + 1;
          final isEven = i % 2 == 0;
          final gc     = team['groupColor']   as Color;
          final name   = team['teamName']     as String;
          final group  = team['group']        as String;
          final mp     = team['matchesPlayed']as int;
          final w      = team['wins']         as int;
          final d      = team['draws']        as int;
          final l      = team['losses']       as int;
          final pts    = team['points']       as int;
          final gf     = team['goalsFor']     as int;
          final ga     = team['goalsAgainst'] as int;
          final gd     = team['goalDiff']     as int;

          final rankColor = _rankColor(rank);
          final isTop3    = rank <= 3;
          final gdStr = gd > 0 ? '+$gd' : '$gd';
          final gdColor = gd > 0
              ? const Color(0xFF00FF88)
              : gd < 0 ? Colors.redAccent : Colors.white38;

          Widget cell(String v, {int flex=1, Color? color, bool bold=false}) =>
              Expanded(flex: flex, child: Text(v,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: color ?? Colors.white70,
                      fontSize: 16,
                      fontWeight: bold ? FontWeight.w900 : FontWeight.w600)));

          return Container(
            decoration: BoxDecoration(
              gradient: isTop3
                  ? LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        rankColor.withOpacity(rank == 1 ? 0.12 : rank == 2 ? 0.07 : 0.05),
                        (isEven ? const Color(0xFF100838) : const Color(0xFF0C0628)),
                      ],
                    )
                  : null,
              color: isTop3 ? null : isEven
                  ? const Color(0xFF100838)
                  : const Color(0xFF0C0628),
              border: isTop3
                  ? Border(left: BorderSide(color: rankColor.withOpacity(0.7), width: 3))
                  : null,
            ),
            padding: const EdgeInsets.symmetric(
                horizontal: 24, vertical: 14),
            child: Row(children: [
              // Rank
              SizedBox(width: 36, child: isTop3
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
                          rank == 1 ? '🥇' : rank == 2 ? '🥈' : '🥉',
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
                    color: gc.withOpacity(0.15),
                    border: Border.all(color: gc.withOpacity(0.6), width: 1),
                  ),
                  child: Center(child: Text(group,
                      style: TextStyle(color: gc,
                          fontSize: 10, fontWeight: FontWeight.w900))),
                ),
                Expanded(child: Text(name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: isTop3 ? Colors.white : Colors.white70,
                        fontSize: isTop3 ? 15 : 14,
                        fontWeight: isTop3 ? FontWeight.w900 : FontWeight.w700))),
              ])),

              // M. (matches played)
              cell('$mp', flex: 1, color: Colors.white54),

              // W
              cell('$w', flex: 1,
                  color: w > 0 ? const Color(0xFF00FF88) : Colors.white24,
                  bold: w > 0),

              // D
              cell('$d', flex: 1,
                  color: d > 0 ? Colors.orange : Colors.white24),

              // L
              cell('$l', flex: 1,
                  color: l > 0 ? Colors.redAccent : Colors.white24),

              // Goals GF:GA
              Expanded(flex: 2, child: Text('$gf:$ga',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70,
                      fontSize: 16, fontWeight: FontWeight.w600,
                      letterSpacing: 0.5))),

              // Dif
              cell(gdStr, flex: 1, color: gdColor, bold: gd != 0),

              // Pt.
              Expanded(flex: 1, child: Container(
                height: 30,
                decoration: BoxDecoration(
                  color: pts > 0
                      ? const Color(0xFFFFD700).withOpacity(0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(5),
                  border: pts > 0
                      ? Border.all(color: const Color(0xFFFFD700).withOpacity(0.3))
                      : null,
                ),
                child: Center(child: Text('$pts',
                    style: TextStyle(
                        color: pts > 0
                            ? const Color(0xFFFFD700)
                            : Colors.white24,
                        fontSize: 16, fontWeight: FontWeight.w900))),
              )),
            ]),
          );
        },
      )),
    ]);
  }


  // ── Stat pill (W/D/L/MP) ──────────────────────────────────────────────────
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
        if (b.points   != a.points)   return b.points.compareTo(a.points);
        if (b.goalDiff != a.goalDiff) return b.goalDiff.compareTo(a.goalDiff);
        if (b.goalsFor != a.goalsFor) return b.goalsFor.compareTo(a.goalsFor);
        if (b.wins     != a.wins)     return b.wins.compareTo(a.wins);
        return a.teamName.compareTo(b.teamName);
      });

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
        border: Border.all(color: groupCol.withOpacity(0.4), width: 1.5),
        boxShadow: [BoxShadow(color: groupCol.withOpacity(0.08), blurRadius: 12)],
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
          final rank     = e.key + 1;
          final team     = e.value;
          final advances = rank <= 2;
          final isFirst  = rank == 1;
          final badgeCol = isFirst
              ? const Color(0xFFFFD700)
              : advances
                  ? const Color(0xFF00FF88)
                  : Colors.white12;
          final textCol  = advances ? Colors.white : Colors.white54;
          final gd       = team.goalDiff;
          final gdStr    = gd > 0 ? '+$gd' : '$gd';
          final gdColor  = gd > 0
              ? const Color(0xFF00FF88)
              : gd < 0
                  ? Colors.redAccent
                  : Colors.white38;

          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              gradient: advances
                  ? LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        badgeCol.withOpacity(isFirst ? 0.12 : 0.06),
                        Colors.transparent,
                      ],
                    )
                  : null,
              border: Border(
                bottom: BorderSide(
                    color: Colors.white.withOpacity(0.04), width: 1),
                left: advances
                    ? BorderSide(color: badgeCol.withOpacity(0.7), width: 2.5)
                    : BorderSide.none,
              ),
            ),
            child: Row(children: [
              // Rank badge
              Container(
                width: 28, height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: advances
                      ? RadialGradient(colors: [
                          badgeCol.withOpacity(0.3),
                          badgeCol.withOpacity(0.06),
                        ])
                      : null,
                  color: advances ? null : Colors.white.withOpacity(0.03),
                  border: Border.all(
                      color: advances ? badgeCol : Colors.white12, width: 1),
                  boxShadow: advances
                      ? [BoxShadow(
                          color: badgeCol.withOpacity(0.35),
                          blurRadius: 6)]
                      : null,
                ),
                child: Center(
                  child: advances && isFirst
                      ? const Text('★', style: TextStyle(color: Color(0xFFFFD700), fontSize: 11))
                      : advances
                          ? const Icon(Icons.arrow_upward_rounded, size: 12, color: Color(0xFF00FF88))
                          : Text('$rank',
                              style: TextStyle(color: Colors.white54,
                                  fontSize: 14, fontWeight: FontWeight.w900)),
                ),
              ),
              const SizedBox(width: 6),
              // Team name
              Expanded(child: Text(team.teamName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textCol,
                    fontSize: advances ? 14 : 13,
                    fontWeight: advances ? FontWeight.w900 : FontWeight.w400,
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
            gradient: LinearGradient(
              colors: [
                const Color(0xFF00FF88).withOpacity(0.08),
                Colors.transparent,
              ],
            ),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(11)),
            border: Border(top: BorderSide(color: groupCol.withOpacity(0.2))),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: const Color(0xFF00FF88).withOpacity(0.10),
                border: Border.all(
                    color: const Color(0xFF00FF88).withOpacity(0.3), width: 1),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.arrow_upward_rounded,
                    color: Color(0xFF00FF88), size: 10),
                const SizedBox(width: 4),
                Text('TOP 2 ADVANCE',
                    style: TextStyle(
                        color: const Color(0xFF00FF88).withOpacity(0.85),
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.8)),
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
        border: const Border(
            bottom: BorderSide(color: Color(0xFF00CFFF), width: 1.5)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00CFFF).withOpacity(0.12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            height: 44, width: 160,
            child: Image.asset('assets/images/RoboventureLogo.png',
                fit: BoxFit.contain, alignment: Alignment.centerLeft),
          ),
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF7B2FFF).withOpacity(0.35),
                  blurRadius: 24,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: Image.asset('assets/images/CenterLogo.png',
                height: 70, fit: BoxFit.contain),
          ),
          SizedBox(
            height: 44, width: 160,
            child: Image.asset('assets/images/CreotecLogo.png',
                fit: BoxFit.contain, alignment: Alignment.centerRight),
          ),
        ],
      ),
    );
  }

  // ── Accomplishment Report ────────────────────────────────────────────────
  void _showAccomplishmentReport() {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1A0550), Color(0xFF2D0E7A), Color(0xFF0C0628)],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.4), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFFD700).withOpacity(0.15),
                blurRadius: 30,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Header ────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    const Color(0xFFFFD700).withOpacity(0.15),
                    Colors.transparent,
                  ]),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
                  border: Border(
                    bottom: BorderSide(color: const Color(0xFFFFD700).withOpacity(0.25)),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.emoji_events_rounded,
                        color: Color(0xFFFFD700), size: 26),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'ACCOMPLISHMENT REPORT',
                        style: TextStyle(
                          color: Color(0xFFFFD700),
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white54),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              // ── Body ──────────────────────────────────────────────
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _categories.map((cat) {
                      final catId = int.tryParse(cat['category_id'].toString()) ?? 0;
                      final catName = (cat['category_type'] ?? '').toString().toUpperCase();
                      final isSoccer = catName.toLowerCase().contains('soccer');
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: _buildReportSection(catId, catName, isSoccer),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReportSection(int catId, String catName, bool isSoccer) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section title
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF5C2ECC).withOpacity(0.35),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
            ),
            child: Row(children: [
              Icon(isSoccer ? Icons.sports_soccer : Icons.sports_esports,
                  color: const Color(0xFF00CFFF), size: 16),
              const SizedBox(width: 8),
              Text(catName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  )),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: isSoccer
                ? _buildSoccerReportContent()
                : _buildRegularReportContent(catId),
          ),
        ],
      ),
    );
  }

  Widget _buildRegularReportContent(int catId) {
    final rows = _standingsByCategory[catId] ?? [];
    if (rows.isEmpty) {
      return const Text('No results yet.',
          style: TextStyle(color: Colors.white38, fontSize: 13));
    }

    // Detect if this category is timer-based
    final cat = _categories.firstWhere(
      (c) => (int.tryParse(c['category_id'].toString()) ?? 0) == catId,
      orElse: () => {},
    );
    final catName  = (cat['category_type'] ?? '').toString();
    final isTimer  = _isTimerCategory(catName);

    final top = rows.take(3).toList();
    final medals = ['🥇', '🥈', '🥉'];
    final medalColors = [
      const Color(0xFFFFD700),
      const Color(0xFFC0C0C0),
      const Color(0xFFCD7F32),
    ];
    return Column(
      children: [
        ...List.generate(top.length, (i) {
          final t   = top[i];
          final col = medalColors[i];
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: col.withOpacity(0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: col.withOpacity(0.25)),
            ),
            child: Row(children: [
              Text(medals[i], style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((t['team_name'] as String).toUpperCase(),
                        style: TextStyle(
                          color: col,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        )),
                    Text('Team ID: C${(t['team_id'] as int).toString().padLeft(3, '0')}R',
                        style: const TextStyle(color: Colors.white38, fontSize: 11)),
                  ],
                ),
              ),
              if (isTimer)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.timer_rounded, color: col, size: 14),
                  const SizedBox(width: 4),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(
                      t['bestTimeStr'] as String? ?? '—',
                      style: TextStyle(
                        color: col,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const Text('best time',
                        style: TextStyle(color: Colors.white38, fontSize: 10)),
                  ]),
                ])
              else
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${t['totalScore'] as int}',
                      style: TextStyle(
                        color: col,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      )),
                  const Text('pts',
                      style: TextStyle(color: Colors.white38, fontSize: 10)),
                ]),
            ]),
          );
        }),
        if (rows.length > 3) ...[
          const SizedBox(height: 4),
          Text('+${rows.length - 3} more team(s) participated',
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ],
    );
  }

  Widget _buildSoccerReportContent() {
    if (_soccerGroups.isEmpty) {
      return const Text('No results yet.',
          style: TextStyle(color: Colors.white38, fontSize: 13));
    }

    // Overall sorted list
    final all = <Map<String, dynamic>>[];
    for (final g in _soccerGroups) {
      for (final t in g.teams) {
        all.add({
          'name': t.teamName,
          'group': g.label,
          'pts': t.points,
          'w': t.wins,
          'd': t.draws,
          'l': t.losses,
          'gf': t.goalsFor,
          'ga': t.goalsAgainst,
          'gd': t.goalDiff,
          'gc': _groupColor(g.label),
        });
      }
    }
    all.sort((a, b) {
      if (b['pts'] != a['pts']) return (b['pts'] as int).compareTo(a['pts'] as int);
      if (b['gd']  != a['gd'])  return (b['gd']  as int).compareTo(a['gd']  as int);
      return (b['gf'] as int).compareTo(a['gf'] as int);
    });

    final medals = ['🥇', '🥈', '🥉'];
    final medalColors = [
      const Color(0xFFFFD700),
      const Color(0xFFC0C0C0),
      const Color(0xFFCD7F32),
    ];
    final top = all.take(3).toList();

    return Column(children: [
      ...List.generate(top.length, (i) {
        final t = top[i];
        final col = medalColors[i];
        final gc = t['gc'] as Color;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: col.withOpacity(0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: col.withOpacity(0.25)),
          ),
          child: Row(children: [
            Text(medals[i], style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            Container(
              width: 22, height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: gc.withOpacity(0.15),
                border: Border.all(color: gc.withOpacity(0.6)),
              ),
              child: Center(child: Text(t['group'] as String,
                  style: TextStyle(color: gc, fontSize: 9, fontWeight: FontWeight.w900))),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text((t['name'] as String).toUpperCase(),
                  style: TextStyle(
                    color: col, fontSize: 15, fontWeight: FontWeight.w900)),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${t['pts']} pts',
                  style: TextStyle(color: col, fontSize: 16, fontWeight: FontWeight.w900)),
              Text('${t['w']}W ${t['d']}D ${t['l']}L  ${t['gf']}:${t['ga']}',
                  style: const TextStyle(color: Colors.white38, fontSize: 10)),
            ]),
          ]),
        );
      }),
      if (all.length > 3) ...[
        const SizedBox(height: 4),
        Text('+${all.length - 3} more team(s) participated',
            style: const TextStyle(color: Colors.white38, fontSize: 12)),
      ],
    ]);
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