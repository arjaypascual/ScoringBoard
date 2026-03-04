import 'package:flutter/material.dart';
import 'db_helper.dart';

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
    with SingleTickerProviderStateMixin {
  TabController? _tabController;
  List<Map<String, dynamic>> _categories = [];

  // category_id → list of standing rows
  // Each row: { rank, team_id(display), team_name, round1, round2, ..., finalScore, finalDuration }
  Map<int, List<Map<String, dynamic>>> _standingsByCategory = {};

  bool _isLoading = true;

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

  // ── Load data ─────────────────────────────────────────────────────────────
  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final categories = await DBHelper.getCategories();
      final Map<int, List<Map<String, dynamic>>> standingsByCategory = {};

      for (final cat in categories) {
        final catId = int.tryParse(cat['category_id'].toString()) ?? 0;
        final rows  = await DBHelper.getScoresByCategory(catId);

        // Group by team
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
            (teamMap[teamId]!['rounds'] as Map<int, Map<String, dynamic>>)[roundId] = {
              'score':    score,
              'duration': duration,
            };
          }
        }

        // If no score rows yet, fall back to just listing teams
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

        // Determine max rounds across all teams
        int maxRounds = 2; // minimum 2 shown
        for (final t in teamMap.values) {
          final rounds = t['rounds'] as Map<int, Map<String, dynamic>>;
          if (rounds.keys.isNotEmpty) {
            final max = rounds.keys.reduce((a, b) => a > b ? a : b);
            if (max > maxRounds) maxRounds = max;
          }
        }

        // Build standing rows, sorted by total score desc
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

        // Assign rank
        for (int i = 0; i < standings.length; i++) {
          standings[i]['rank'] = i + 1;
        }

        standingsByCategory[catId] = standings;
      }

      _tabController?.dispose();
      _tabController = TabController(
        length: categories.length,
        vsync: this,
      );

      setState(() {
        _categories          = categories;
        _standingsByCategory = standingsByCategory;
        _isLoading           = false;
      });
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
            // ── Category Tabs ────────────────────────────────────────
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

            // ── Tab Views ────────────────────────────────────────────
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

    final maxRounds =
        rows.isNotEmpty ? (rows.first['maxRounds'] as int? ?? 2) : 2;

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
              // Refresh + Back buttons
              Row(
                children: [
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh, color: Color(0xFF00CFFF)),
                    onPressed: _loadData,
                  ),
                  IconButton(
                    tooltip: 'Back to Schedule',
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
          padding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
          child: Row(
            children: [
              _headerCell('RANK',    flex: 1),
              _headerCell('TEAM ID', flex: 2),
              _headerCell('TEAM NAME:', flex: 3),
              ...List.generate(
                maxRounds,
                (i) => _headerCell(
                  _roundLabel(i + 1),
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
                          // Rank
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

                          // Team ID (display as team_id padded)
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

                          // Team Name
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

                          // Round scores (dynamic)
                          ...List.generate(maxRounds, (i) {
                            final roundData = rounds[i + 1];
                            final score = roundData?['score'] ?? 0;
                            return Expanded(
                              flex: 2,
                              child: Column(
                                children: [
                                  Text(
                                    '$score',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),

                          // Final score + duration
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

  String _roundLabel(int round) {
    switch (round) {
      case 1:  return 'FIRST\nMATCH';
      case 2:  return 'SECOND\nMATCH';
      case 3:  return 'THIRD\nMATCH';
      default: return 'MATCH $round';
    }
  }

  Color _rankColor(int rank) {
    switch (rank) {
      case 1:  return const Color(0xFFFFD700); // Gold
      case 2:  return const Color(0xFFC0C0C0); // Silver
      case 3:  return const Color(0xFFCD7F32); // Bronze
      default: return Colors.white;
    }
  }

  String _bestDuration(Map<int, Map<String, dynamic>> rounds) {
    if (rounds.isEmpty) return '00:00';
    // Return duration of best (highest score) round
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

  Widget _headerCell(String text,
      {int flex = 1, bool center = false}) {
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
}