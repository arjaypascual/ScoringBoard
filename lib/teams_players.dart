// ignore_for_file: unnecessary_to_list_in_spreads, deprecated_member_use

import 'dart:async';
import 'package:flutter/material.dart';
import 'db_helper.dart';

// ── Accent palette per category index ────────────────────────────────────────
const _kCatColors = [
  Color(0xFF00CFFF), // blue
  Color(0xFF967BB6), // lavender
  Color(0xFFFFD700), // gold
  Color(0xFF00E5A0), // emerald
  Color(0xFFFF6B6B), // coral
  Color(0xFFFF8C42), // orange
];

Color _catColor(int index) => _kCatColors[index % _kCatColors.length];

String _fmtTeamId(String rawId) {
  if (rawId.isEmpty) return '';
  final n = int.tryParse(rawId);
  if (n == null) return rawId;
  return 'C${n.toString().padLeft(3, '0')}R';
}

// ─────────────────────────────────────────────────────────────────────────────
class TeamsPlayers extends StatefulWidget {
  final VoidCallback? onBack;
  const TeamsPlayers({super.key, this.onBack});

  @override
  State<TeamsPlayers> createState() => _TeamsPlayersState();
}

class _TeamsPlayersState extends State<TeamsPlayers>
    with TickerProviderStateMixin {
  TabController? _tabController;
  List<Map<String, dynamic>> _categories = [];

  // category_id → all teams
  Map<int, List<Map<String, dynamic>>> _teamsByCategory = {};
  // team_id → players
  Map<int, List<Map<String, dynamic>>> _playersByTeam = {};

  bool _isLoading  = true;
  DateTime? _lastUpdated;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadData();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 15), (_) => _loadData(silent: true));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _tabController?.dispose();
    super.dispose();
  }

  // ── Load all data ─────────────────────────────────────────────────────────
  Future<void> _loadData({bool silent = false}) async {
    if (!silent) setState(() => _isLoading = true);
    try {
      final categories = await DBHelper.getCategories();
      final conn       = await DBHelper.getConnection();

      // Load all teams with mentor info
      final Map<int, List<Map<String, dynamic>>> teamsByCategory = {};
      for (final cat in categories) {
        final catId = int.tryParse(cat['category_id'].toString()) ?? 0;
        final teams = await DBHelper.getTeamsByCategory(catId);
        teamsByCategory[catId] = teams;
      }

      // Load all players grouped by team
      final playerResult = await conn.execute("""
        SELECT
          p.player_id,
          p.player_name,
          p.player_ispresent,
          p.team_id
        FROM tbl_player p
        ORDER BY p.team_id, p.player_name
      """);
      final Map<int, List<Map<String, dynamic>>> playersByTeam = {};
      for (final row in playerResult.rows) {
        final r      = row.assoc();
        final teamId = int.tryParse(r['team_id']?.toString() ?? '0') ?? 0;
        playersByTeam.putIfAbsent(teamId, () => []).add(r);
      }

      final prevIndex = _tabController?.index ?? 0;
      _tabController?.dispose();
      _tabController = TabController(
        length: categories.length,
        vsync: this,
        initialIndex: prevIndex.clamp(0, (categories.length - 1).clamp(0, 999)),
      );

      setState(() {
        _categories      = categories;
        _teamsByCategory = teamsByCategory;
        _playersByTeam   = playersByTeam;
        _isLoading       = false;
        _lastUpdated     = DateTime.now();
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('❌ Failed to load: $e'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  // ── Mark all teams present or absent ────────────────────────────────────────
  Future<void> _markAllTeams(int catId, bool present) async {
    final val = present ? 1 : 0;
    try {
      final conn = await DBHelper.getConnection();
      await conn.execute(
        "UPDATE tbl_team SET team_ispresent = $val WHERE category_id = $catId",
      );
      await _loadData(silent: true);
      if (mounted) {
        final label = present ? 'All teams marked Present ✅' : 'All teams marked Absent ❌';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(label),
          backgroundColor:
              present ? const Color(0xFF1A5C2A) : const Color(0xFF5C1A1A),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('❌ Failed to update: $e'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  // ── Toggle team presence in DB ────────────────────────────────────────────
  Future<void> _toggleTeamPresence(int teamId, bool currentlyPresent) async {
    final newValue = currentlyPresent ? 0 : 1;
    try {
      final conn = await DBHelper.getConnection();
      await conn.execute(
        "UPDATE tbl_team SET team_ispresent = $newValue WHERE team_id = $teamId",
      );
      await _loadData(silent: true);
      if (mounted) {
        final label = !currentlyPresent ? 'Present ✅' : 'Absent ❌';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Team marked as $label'),
          backgroundColor:
              !currentlyPresent ? const Color(0xFF1A5C2A) : const Color(0xFF5C1A1A),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('❌ Failed to update attendance: $e'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0720),
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
                child: Text('No categories found.',
                    style: TextStyle(color: Colors.white38, fontSize: 16)),
              ),
            )
          else ...[
            _buildTabBar(),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: _categories.asMap().entries.map((e) {
                  final catId = int.tryParse(
                          e.value['category_id'].toString()) ?? 0;
                  return _CategoryView(
                    category:           e.value,
                    catIndex:           e.key,
                    catId:              catId,
                    teams:              _teamsByCategory[catId] ?? [],
                    playersByTeam:      _playersByTeam,
                    lastUpdated:        _lastUpdated,
                    onBack:             widget.onBack,
                    onRefresh:          () => _loadData(),
                    onTogglePresence:   _toggleTeamPresence,
                    onMarkAll:          (present) => _markAllTeams(catId, present),
                  );
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Tab bar ───────────────────────────────────────────────────────────────
  Widget _buildTabBar() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF130A30),
        border: Border(bottom: BorderSide(color: Color(0xFF2A1560), width: 1)),
      ),
      child: TabBar(
        controller: _tabController,
        isScrollable: true,
        indicatorWeight: 3,
        indicatorColor: const Color(0xFF00CFFF),
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white38,
        labelStyle: const TextStyle(
            fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.2),
        tabs: _categories.asMap().entries.map((e) {
          final catId  = int.tryParse(e.value['category_id'].toString()) ?? 0;
          final teams  = _teamsByCategory[catId] ?? [];
          final present = teams.where(
              (t) => t['team_ispresent'].toString() == '1').length;
          final accent = _catColor(e.key);
          return Tab(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8, height: 8,
                    decoration: BoxDecoration(
                        color: accent, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Text((e.value['category_type'] ?? '')
                      .toString().toUpperCase()),
                  const SizedBox(width: 8),
                  // Present count badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: Colors.green.withOpacity(0.4), width: 1),
                    ),
                    child: Text('$present',
                        style: const TextStyle(
                            color: Colors.green,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 4),
                  // Absent count badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: Colors.red.withOpacity(0.35), width: 1),
                    ),
                    child: Text('${teams.length - present}',
                        style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── App header ────────────────────────────────────────────────────────────
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
}

// ─────────────────────────────────────────────────────────────────────────────
// Category view — split into PRESENT / ABSENT columns
// ─────────────────────────────────────────────────────────────────────────────
class _CategoryView extends StatefulWidget {
  final Map<String, dynamic>            category;
  final int                             catIndex;
  final int                             catId;
  final List<Map<String, dynamic>>      teams;
  final Map<int, List<Map<String, dynamic>>> playersByTeam;
  final DateTime?                       lastUpdated;
  final VoidCallback?                   onBack;
  final VoidCallback                    onRefresh;
  final Future<void> Function(int teamId, bool currentlyPresent) onTogglePresence;
  final Future<void> Function(bool present) onMarkAll;

  const _CategoryView({
    required this.category,
    required this.catIndex,
    required this.catId,
    required this.teams,
    required this.playersByTeam,
    required this.lastUpdated,
    required this.onRefresh,
    required this.onTogglePresence,
    required this.onMarkAll,
    this.onBack,
  });

  @override
  State<_CategoryView> createState() => _CategoryViewState();
}

class _CategoryViewState extends State<_CategoryView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent       = _catColor(widget.catIndex);
    final categoryName = (widget.category['category_type'] ?? '').toString().toUpperCase();
    final allTeams     = widget.teams;
    final present      = allTeams.where((t) => t['team_ispresent'].toString() == '1').toList();
    final absent       = allTeams.where((t) => t['team_ispresent'].toString() != '1').toList();
    final total        = allTeams.length;
    final presentCount = present.length;
    final pct          = total == 0 ? 0.0 : presentCount / total;

    // Filter by search query
    final q = _searchQuery.toLowerCase();
    final filteredPresent = q.isEmpty
        ? present
        : present.where((t) =>
            (t['team_name'] ?? '').toString().toLowerCase().contains(q)).toList();
    final filteredAbsent = q.isEmpty
        ? absent
        : absent.where((t) =>
            (t['team_name'] ?? '').toString().toLowerCase().contains(q)).toList();

    return Column(
      children: [
        // ── Category title bar ─────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF130A30),
            border: Border(
                bottom: BorderSide(color: accent.withOpacity(0.3), width: 1)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
          child: Row(
            children: [
              // Category name badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    accent.withOpacity(0.18),
                    accent.withOpacity(0.05),
                  ]),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: accent.withOpacity(0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.category_rounded, color: accent, size: 16),
                    const SizedBox(width: 10),
                    Text(categoryName,
                        style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                            letterSpacing: 1.5)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Stats chips
              _statChip(Icons.groups_rounded, '$total', 'TOTAL',
                  Colors.white54, Colors.white12),
              const SizedBox(width: 8),
              _statChip(Icons.check_circle_rounded, '$presentCount', 'PRESENT',
                  Colors.green, Colors.green.withOpacity(0.12)),
              const SizedBox(width: 8),
              _statChip(Icons.cancel_rounded, '${absent.length}', 'ABSENT',
                  Colors.redAccent, Colors.red.withOpacity(0.10)),
              const Spacer(),
              _LiveIndicator(lastUpdated: widget.lastUpdated),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh_rounded,
                    color: Color(0xFF00CFFF), size: 20),
                onPressed: widget.onRefresh,
              ),
              if (widget.onBack != null)
                IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back_ios_new,
                      color: Color(0xFF00CFFF), size: 18),
                  onPressed: widget.onBack,
                ),
            ],
          ),
        ),

        // ── Attendance summary + progress bar ──────────────────────────
        Container(
          color: const Color(0xFF0C0720),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'ATTENDANCE',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '$presentCount / $total teams',
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  // Percentage badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: pct >= 1.0
                          ? Colors.green.withOpacity(0.18)
                          : pct >= 0.5
                              ? Colors.orange.withOpacity(0.15)
                              : Colors.red.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: pct >= 1.0
                            ? Colors.green.withOpacity(0.5)
                            : pct >= 0.5
                                ? Colors.orange.withOpacity(0.4)
                                : Colors.red.withOpacity(0.4),
                      ),
                    ),
                    child: Text(
                      '${(pct * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                        color: pct >= 1.0
                            ? Colors.green
                            : pct >= 0.5
                                ? Colors.orange
                                : Colors.redAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Mark All Present button
                  _markAllBtn(
                    icon: Icons.check_circle_rounded,
                    label: 'All Present',
                    color: Colors.green,
                    onTap: () => widget.onMarkAll(true),
                  ),
                  const SizedBox(width: 8),
                  // Mark All Absent button
                  _markAllBtn(
                    icon: Icons.cancel_rounded,
                    label: 'All Absent',
                    color: Colors.redAccent,
                    onTap: () => widget.onMarkAll(false),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  children: [
                    Container(
                      height: 8,
                      width: double.infinity,
                      color: Colors.white.withOpacity(0.06),
                    ),
                    AnimatedFractionallySizedBox(
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOut,
                      widthFactor: pct.clamp(0.0, 1.0),
                      child: Container(
                        height: 8,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: pct >= 1.0
                                ? [Colors.green, const Color(0xFF00FF88)]
                                : pct >= 0.5
                                    ? [Colors.orange, Colors.amber]
                                    : [Colors.redAccent, Colors.red],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // ── Search bar ─────────────────────────────────────────────────
        Container(
          color: const Color(0xFF0F0828),
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: accent.withOpacity(0.25)),
                  ),
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Search teams…',
                      hintStyle: TextStyle(
                          color: Colors.white24, fontSize: 13),
                      prefixIcon: Icon(Icons.search_rounded,
                          color: accent.withOpacity(0.6), size: 18),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? GestureDetector(
                              onTap: () {
                                _searchCtrl.clear();
                                setState(() => _searchQuery = '');
                              },
                              child: Icon(Icons.close_rounded,
                                  color: Colors.white38, size: 16),
                            )
                          : null,
                      border: InputBorder.none,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 9),
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),
              ),
            ],
          ),
        ),

        // ── Column headers ─────────────────────────────────────────────
        Container(
          color: const Color(0xFF0F0828),
          padding: const EdgeInsets.fromLTRB(28, 4, 28, 8),
          child: Row(
            children: [
              Expanded(
                child: _sectionHeader(
                    Icons.check_circle_outline_rounded,
                    'PRESENT',
                    '${filteredPresent.length} team${filteredPresent.length != 1 ? "s" : ""}',
                    Colors.green),
              ),
              Container(width: 1, height: 36,
                  color: Colors.white.withOpacity(0.08)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 20),
                  child: _sectionHeader(
                      Icons.cancel_outlined,
                      'ABSENT',
                      '${filteredAbsent.length} team${filteredAbsent.length != 1 ? "s" : ""}',
                      Colors.redAccent),
                ),
              ),
            ],
          ),
        ),

        // ── Two-column team list ───────────────────────────────────────
        Expanded(
          child: allTeams.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.group_off_rounded,
                          color: accent.withOpacity(0.2), size: 64),
                      const SizedBox(height: 16),
                      Text('No teams in $categoryName yet.',
                          style: const TextStyle(
                              color: Colors.white24, fontSize: 15)),
                    ],
                  ),
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // PRESENT column
                    Expanded(
                      child: _TeamColumn(
                        teams:              filteredPresent,
                        playersByTeam:      widget.playersByTeam,
                        accent:             Colors.green,
                        isEmpty:            filteredPresent.isEmpty,
                        emptyLabel:         _searchQuery.isNotEmpty
                            ? 'No results'
                            : 'No teams present',
                        catIndex:           widget.catIndex,
                        isPresent:          true,
                        onTogglePresence:   widget.onTogglePresence,
                      ),
                    ),
                    // Divider
                    Container(
                      width: 1,
                      color: Colors.white.withOpacity(0.06),
                    ),
                    // ABSENT column
                    Expanded(
                      child: _TeamColumn(
                        teams:              filteredAbsent,
                        playersByTeam:      widget.playersByTeam,
                        accent:             Colors.redAccent,
                        isEmpty:            filteredAbsent.isEmpty,
                        emptyLabel:         _searchQuery.isNotEmpty
                            ? 'No results'
                            : 'All teams present!',
                        catIndex:           widget.catIndex,
                        isPresent:          false,
                        onTogglePresence:   widget.onTogglePresence,
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _markAllBtn({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withOpacity(0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 13),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _statChip(
      IconData icon, String value, String label, Color color, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.3))),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 6),
          Text(value,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: color.withOpacity(0.7),
                  fontSize: 9,
                  letterSpacing: 1)),
        ],
      ),
    );
  }

  Widget _sectionHeader(
      IconData icon, String title, String sub, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 8),
        Text(title,
            style: TextStyle(
                color: color,
                fontWeight: FontWeight.w900,
                fontSize: 12,
                letterSpacing: 1.5)),
        const SizedBox(width: 8),
        Text(sub,
            style: TextStyle(
                color: color.withOpacity(0.5), fontSize: 10)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Scrollable column of team cards
// ─────────────────────────────────────────────────────────────────────────────
class _TeamColumn extends StatelessWidget {
  final List<Map<String, dynamic>>           teams;
  final Map<int, List<Map<String, dynamic>>> playersByTeam;
  final Color   accent;
  final bool    isEmpty;
  final String  emptyLabel;
  final int     catIndex;
  final bool    isPresent;
  final Future<void> Function(int teamId, bool currentlyPresent) onTogglePresence;

  const _TeamColumn({
    required this.teams,
    required this.playersByTeam,
    required this.accent,
    required this.isEmpty,
    required this.emptyLabel,
    required this.catIndex,
    required this.isPresent,
    required this.onTogglePresence,
  });

  @override
  Widget build(BuildContext context) {
    if (isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isPresent ? Icons.group_off_rounded : Icons.celebration_rounded,
              color: accent.withOpacity(0.2),
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(emptyLabel,
                style: TextStyle(
                    color: accent.withOpacity(0.4), fontSize: 13)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: teams.length,
      itemBuilder: (context, index) {
        final team   = teams[index];
        final teamId = int.tryParse(team['team_id']?.toString() ?? '0') ?? 0;
        final players = playersByTeam[teamId] ?? [];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _TeamCard(
            team:             team,
            players:          players,
            accent:           accent,
            catIndex:         catIndex,
            cardIndex:        index,
            isPresent:        isPresent,
            onTogglePresence: onTogglePresence,
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Expandable team card with player list
// ─────────────────────────────────────────────────────────────────────────────
class _TeamCard extends StatefulWidget {
  final Map<String, dynamic>           team;
  final List<Map<String, dynamic>>     players;
  final Color  accent;
  final int    catIndex;
  final int    cardIndex;
  final bool   isPresent;
  final Future<void> Function(int teamId, bool currentlyPresent) onTogglePresence;

  const _TeamCard({
    required this.team,
    required this.players,
    required this.accent,
    required this.catIndex,
    required this.cardIndex,
    required this.isPresent,
    required this.onTogglePresence,
  });

  @override
  State<_TeamCard> createState() => _TeamCardState();
}

class _TeamCardState extends State<_TeamCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late AnimationController _ctrl;
  late Animation<double>   _expandAnim;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _expandAnim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    _expanded ? _ctrl.forward() : _ctrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final team       = widget.team;
    final teamName   = (team['team_name'] ?? '').toString();
    final teamId     = team['team_id']?.toString() ?? '';
    final mentorName = team['mentor_name']?.toString() ?? '—';
    final accent     = widget.accent;

    final presentPlayers = widget.players
        .where((p) => p['player_ispresent'].toString() == '1').length;
    final totalPlayers   = widget.players.length;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _hovered
                ? accent.withOpacity(0.6)
                : accent.withOpacity(0.2),
            width: 1.5,
          ),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              accent.withOpacity(_hovered ? 0.10 : 0.05),
              const Color(0xFF0D0720),
            ],
          ),
          boxShadow: _hovered
              ? [BoxShadow(
                  color: accent.withOpacity(0.15),
                  blurRadius: 16, spreadRadius: 1)]
              : [],
        ),
        child: Column(
          children: [
            // ── Card header ──────────────────────────────────────────
            InkWell(
              onTap: widget.players.isNotEmpty ? _toggle : null,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                child: Row(
                  children: [
                    // Team ID badge
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                      decoration: BoxDecoration(
                        color: accent.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: accent.withOpacity(0.3), width: 1),
                      ),
                      child: Text(
                        _fmtTeamId(teamId),
                        style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w900,
                            fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 12),

                    // Team name + mentor
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            teamName,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                                letterSpacing: 0.3),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Icon(Icons.person_outline_rounded,
                                  color: Colors.white38, size: 12),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  mentorName,
                                  style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 11),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Player count pill
                    if (totalPlayers > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: Colors.white.withOpacity(0.12)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.people_alt_rounded,
                                color: Colors.white38, size: 12),
                            const SizedBox(width: 5),
                            Text(
                              '$presentPlayers/$totalPlayers',
                              style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(width: 8),

                    // ── Tappable attendance badge ─────────────────────
                    GestureDetector(
                      onTap: () {
                        final teamId = int.tryParse(
                            widget.team['team_id']?.toString() ?? '0') ?? 0;
                        if (teamId > 0) {
                          widget.onTogglePresence(teamId, widget.isPresent);
                        }
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: widget.isPresent
                              ? Colors.green.withOpacity(0.15)
                              : Colors.red.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: widget.isPresent
                                ? Colors.green.withOpacity(0.5)
                                : Colors.red.withOpacity(0.4),
                            width: 1.5,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6, height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: widget.isPresent
                                    ? Colors.green
                                    : Colors.redAccent,
                                boxShadow: [
                                  BoxShadow(
                                    color: widget.isPresent
                                        ? Colors.green.withOpacity(0.5)
                                        : Colors.red.withOpacity(0.4),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              widget.isPresent ? 'Present' : 'Absent',
                              style: TextStyle(
                                color: widget.isPresent
                                    ? Colors.green
                                    : Colors.redAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.swap_horiz_rounded,
                              color: widget.isPresent
                                  ? Colors.green.withOpacity(0.6)
                                  : Colors.redAccent.withOpacity(0.6),
                              size: 12,
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(width: 8),

                    // Expand chevron
                    if (widget.players.isNotEmpty)
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0.0,
                        duration: const Duration(milliseconds: 220),
                        child: Icon(Icons.keyboard_arrow_down_rounded,
                            color: accent.withOpacity(0.7), size: 20),
                      ),
                  ],
                ),
              ),
            ),

            // ── Expandable player list ───────────────────────────────
            SizeTransition(
              sizeFactor: _expandAnim,
              child: Column(
                children: [
                  Container(
                    height: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                        Colors.transparent,
                        accent.withOpacity(0.3),
                        Colors.transparent,
                      ]),
                    ),
                  ),
                  // Player grid header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                    child: Row(
                      children: [
                        const Expanded(
                          flex: 3,
                          child: Text('PLAYER',
                              style: TextStyle(
                                  color: Colors.white24,
                                  fontSize: 9,
                                  letterSpacing: 1.5,
                                  fontWeight: FontWeight.bold)),
                        ),
                        const Expanded(
                          flex: 2,
                          child: Text('STATUS',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: Colors.white24,
                                  fontSize: 9,
                                  letterSpacing: 1.5,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                  // Player rows
                  ...widget.players.asMap().entries.map((e) {
                    final p           = e.value;
                    final playerPresent =
                        p['player_ispresent'].toString() == '1';
                    final fullName =
                        p['player_name']?.toString() ?? '';
                    final isEven    = e.key % 2 == 0;

                    return Container(
                      color: isEven
                          ? Colors.white.withOpacity(0.02)
                          : Colors.transparent,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          // Player avatar + name
                          Expanded(
                            flex: 3,
                            child: Row(
                              children: [
                                Container(
                                  width: 28, height: 28,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: playerPresent
                                        ? Colors.green.withOpacity(0.15)
                                        : Colors.red.withOpacity(0.12),
                                    border: Border.all(
                                      color: playerPresent
                                          ? Colors.green.withOpacity(0.4)
                                          : Colors.red.withOpacity(0.3),
                                    ),
                                  ),
                                  child: Center(
                                    child: Text(
                                      fullName.isNotEmpty
                                          ? fullName[0].toUpperCase()
                                          : '?',
                                      style: TextStyle(
                                        color: playerPresent
                                            ? Colors.green
                                            : Colors.redAccent,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    fullName,
                                    style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Status badge
                          Expanded(
                            flex: 2,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: playerPresent
                                      ? Colors.green.withOpacity(0.12)
                                      : Colors.red.withOpacity(0.10),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: playerPresent
                                        ? Colors.green.withOpacity(0.4)
                                        : Colors.red.withOpacity(0.35),
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 6, height: 6,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: playerPresent
                                            ? Colors.green
                                            : Colors.redAccent,
                                        boxShadow: [
                                          BoxShadow(
                                            color: playerPresent
                                                ? Colors.green
                                                    .withOpacity(0.5)
                                                : Colors.red
                                                    .withOpacity(0.4),
                                            blurRadius: 4,
                                          )
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      playerPresent ? 'Present' : 'Absent',
                                      style: TextStyle(
                                        color: playerPresent
                                            ? Colors.green
                                            : Colors.redAccent,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Live indicator widget
// ─────────────────────────────────────────────────────────────────────────────
class _LiveIndicator extends StatefulWidget {
  final DateTime? lastUpdated;
  const _LiveIndicator({this.lastUpdated});

  @override
  State<_LiveIndicator> createState() => _LiveIndicatorState();
}

class _LiveIndicatorState extends State<_LiveIndicator>
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
    final t = widget.lastUpdated;
    final timeStr = t == null
        ? '--:--:--'
        : '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}:'
          '${t.second.toString().padLeft(2, '0')}';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeTransition(
          opacity: _anim,
          child: Container(
            width: 7, height: 7,
            decoration: const BoxDecoration(
                color: Color(0xFF00FF88), shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('LIVE',
                style: TextStyle(
                    color: Color(0xFF00FF88),
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2)),
            Text(timeStr,
                style: const TextStyle(
                    color: Colors.white38, fontSize: 8)),
          ],
        ),
      ],
    );
  }
}