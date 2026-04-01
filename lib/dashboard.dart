// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'package:flutter/material.dart';
import 'db_helper.dart';

class Dashboard extends StatefulWidget {
  final VoidCallback? onBack;

  const Dashboard({super.key, this.onBack});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard>
    with SingleTickerProviderStateMixin {
  // ── palette ────────────────────────────────────────────────────────────────
  static const _bg       = Color(0xFF07041A);
  static const _accent   = Color(0xFF00CFFF);
  static const _green    = Color(0xFF00E5A0);
  static const _gold     = Color(0xFFFFD700);
  static const _orange   = Color(0xFFFF9F43);
  static const _purple   = Color(0xFF9B6FE8);
  static const _red      = Color(0xFFFF6B6B);

  // ── summary data ──────────────────────────────────────────────────────────
  int _totalSchools    = 0;
  int _totalMentors    = 0;
  int _totalTeams      = 0;
  int _totalPlayers    = 0;
  int _totalReferees   = 0;
  int _totalCategories = 0;
  int _activeCategories = 0;

  int _totalMatches    = 0;
  int _matchesDone     = 0;
  int _matchesPending  = 0;

  // per-category breakdown
  List<Map<String, dynamic>> _categoryStats = [];

  // recently registered teams (last 5)
  List<Map<String, dynamic>> _recentTeams = [];

  bool _isLoading = true;
  DateTime? _lastRefreshed;
  Timer? _autoRefresh;

  late final AnimationController _fadeCtrl;
  late final Animation<double>   _fadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _loadData();
    _autoRefresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _loadData(silent: true);
    });
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    _fadeCtrl.dispose();
    super.dispose();
  }

  // ── Data loading ───────────────────────────────────────────────────────────
  Future<void> _loadData({bool silent = false}) async {
    if (!silent) setState(() => _isLoading = true);
    try {
      final conn = await DBHelper.getConnection();

      // counts
      Future<int> count(String sql) async {
        final r = await conn.execute(sql);
        return int.tryParse(
                r.rows.first.assoc().values.first?.toString() ?? '0') ??
            0;
      }

      final results = await Future.wait([
        count('SELECT COUNT(*) FROM tbl_school'),
        count('SELECT COUNT(*) FROM tbl_mentor'),
        count('SELECT COUNT(*) FROM tbl_team'),
        count('SELECT COUNT(*) FROM tbl_player'),
        count('SELECT COUNT(*) FROM tbl_referee'),
        count('SELECT COUNT(*) FROM tbl_category'),
        count("SELECT COUNT(*) FROM tbl_category WHERE status='active'"),
        count('SELECT COUNT(DISTINCT match_id) FROM tbl_teamschedule'),
        count("SELECT COUNT(DISTINCT match_id) FROM tbl_score")
            .catchError((_) async => 0),
      ]);

      // matches done = matches that have at least one score row
      final doneResult = await conn.execute(
          'SELECT COUNT(DISTINCT match_id) AS cnt FROM tbl_score');
      final matchesDone =
          int.tryParse(doneResult.rows.first.assoc()['cnt']?.toString() ?? '0') ?? 0;

      // per-category breakdown
      final catResult = await conn.execute('''
        SELECT
          c.category_id,
          c.category_type,
          c.status,
          COUNT(DISTINCT t.team_id)   AS team_count,
          COUNT(DISTINCT p.player_id) AS player_count,
          COUNT(DISTINCT ts.match_id) AS match_count,
          COUNT(DISTINCT sc.match_id) AS done_count
        FROM tbl_category c
        LEFT JOIN tbl_team         t  ON t.category_id = c.category_id
        LEFT JOIN tbl_player       p  ON p.team_id      = t.team_id
        LEFT JOIN tbl_teamschedule ts ON ts.team_id     = t.team_id
        LEFT JOIN tbl_score        sc ON sc.match_id    = ts.match_id
        GROUP BY c.category_id, c.category_type, c.status
        ORDER BY c.category_id
      ''');
      final catStats =
          catResult.rows.map((r) => r.assoc()).toList();

      // recent teams (last 5)
      final recentResult = await conn.execute('''
        SELECT t.team_name, c.category_type, t.team_id
        FROM tbl_team t
        JOIN tbl_category c ON t.category_id = c.category_id
        ORDER BY t.team_id DESC
        LIMIT 5
      ''');
      final recentTeams =
          recentResult.rows.map((r) => r.assoc()).toList();

      setState(() {
        _totalSchools     = results[0];
        _totalMentors     = results[1];
        _totalTeams       = results[2];
        _totalPlayers     = results[3];
        _totalReferees    = results[4];
        _totalCategories  = results[5];
        _activeCategories = results[6];
        _totalMatches     = results[7];
        _matchesDone      = matchesDone;
        _matchesPending   = results[7] - matchesDone;
        _categoryStats    = catStats;
        _recentTeams      = recentTeams;
        _isLoading        = false;
        _lastRefreshed    = DateTime.now();
      });
      if (!silent) _fadeCtrl.forward(from: 0);
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('❌ Failed to load dashboard: $e'),
            backgroundColor: Colors.red));
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(children: [
        _buildHeader(),
        Expanded(
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: _accent))
              : FadeTransition(
                  opacity: _fadeAnim,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(28, 20, 28, 32),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildRefreshRow(),
                          const SizedBox(height: 20),
                          _buildTopStats(),
                          const SizedBox(height: 24),
                          _buildMatchProgress(),
                          const SizedBox(height: 24),
                          _buildCategoryBreakdown(),
                          const SizedBox(height: 24),
                          _buildRecentTeams(),
                        ]),
                  ),
                ),
        ),
      ]),
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A0550), Color(0xFF2D0E7A), Color(0xFF1A0A4A)],
        ),
        border: Border(
            bottom: BorderSide(color: _accent, width: 1.5)),
      ),
      child: Row(children: [
        IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: _accent, size: 18),
          onPressed: widget.onBack,
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _accent.withOpacity(0.12),
              border: Border.all(color: _accent.withOpacity(0.4))),
          child: const Icon(Icons.dashboard_rounded,
              color: _accent, size: 20),
        ),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('DASHBOARD',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 3)),
          Text('Tournament summary at a glance',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontSize: 11)),
        ]),
        const Spacer(),
        // Manual refresh button
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh_rounded, color: _accent, size: 20),
          onPressed: () => _loadData(),
        ),
      ]),
    );
  }

  // ── Refresh row ────────────────────────────────────────────────────────────
  Widget _buildRefreshRow() {
    final t = _lastRefreshed;
    final label = t == null
        ? ''
        : 'Last updated ${t.hour.toString().padLeft(2, '0')}:'
            '${t.minute.toString().padLeft(2, '0')}:'
            '${t.second.toString().padLeft(2, '0')}';
    return Row(children: [
      Container(
        width: 8, height: 8,
        decoration: const BoxDecoration(
            shape: BoxShape.circle, color: _green),
      ),
      const SizedBox(width: 6),
      Text(label,
          style: TextStyle(
              color: Colors.white.withOpacity(0.35),
              fontSize: 11)),
      const SizedBox(width: 6),
      Text('• auto-refreshes every 30s',
          style: TextStyle(
              color: Colors.white.withOpacity(0.2), fontSize: 10)),
    ]);
  }

  // ── Top stat cards ─────────────────────────────────────────────────────────
  Widget _buildTopStats() {
    final stats = [
      _StatCard(label: 'Schools',    value: _totalSchools,    icon: Icons.school_rounded,            color: _accent),
      _StatCard(label: 'Mentors',    value: _totalMentors,    icon: Icons.person_rounded,             color: _purple),
      _StatCard(label: 'Teams',      value: _totalTeams,      icon: Icons.groups_rounded,             color: _gold),
      _StatCard(label: 'Players',    value: _totalPlayers,    icon: Icons.sports_esports_rounded,     color: _green),
      _StatCard(label: 'Referees',   value: _totalReferees,   icon: Icons.sports_rounded,             color: _orange),
      _StatCard(label: 'Categories', value: _totalCategories, icon: Icons.category_rounded,           color: _red,
          subtitle: '$_activeCategories active'),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle('REGISTRATION SUMMARY', Icons.how_to_reg_rounded, _accent),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: stats.map((s) => _buildStatCard(s)).toList(),
      ),
    ]);
  }

  Widget _buildStatCard(_StatCard s) {
    return Container(
      width: 155,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: s.color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: s.color.withOpacity(0.25), width: 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: s.color.withOpacity(0.12),
              border: Border.all(color: s.color.withOpacity(0.3))),
          child: Icon(s.icon, color: s.color, size: 18),
        ),
        const SizedBox(height: 12),
        Text(s.value.toString(),
            style: TextStyle(
                color: s.color,
                fontSize: 32,
                fontWeight: FontWeight.w900,
                height: 1.0)),
        const SizedBox(height: 4),
        Text(s.label,
            style: TextStyle(
                color: Colors.white.withOpacity(0.65),
                fontSize: 12,
                fontWeight: FontWeight.w600)),
        if (s.subtitle != null) ...[
          const SizedBox(height: 2),
          Text(s.subtitle!,
              style: TextStyle(
                  color: s.color.withOpacity(0.55),
                  fontSize: 10)),
        ],
      ]),
    );
  }

  // ── Match progress ─────────────────────────────────────────────────────────
  Widget _buildMatchProgress() {
    final pct = _totalMatches == 0
        ? 0.0
        : (_matchesDone / _totalMatches).clamp(0.0, 1.0);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle('MATCH PROGRESS', Icons.sports_score_rounded, _green),
      const SizedBox(height: 12),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _green.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _green.withOpacity(0.2), width: 1.5),
        ),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: _matchPill(
                  label: 'Total Matches',
                  value: _totalMatches,
                  color: _accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _matchPill(
                  label: 'Completed',
                  value: _matchesDone,
                  color: _green),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _matchPill(
                  label: 'Pending',
                  value: _matchesPending,
                  color: _orange),
            ),
          ]),
          const SizedBox(height: 20),
          // Progress bar
          Row(children: [
            Text('${(pct * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                    color: _green,
                    fontWeight: FontWeight.w900,
                    fontSize: 18)),
            const SizedBox(width: 12),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 10,
                  backgroundColor: Colors.white.withOpacity(0.07),
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(_green),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              _totalMatches == 0
                  ? 'No schedule generated yet'
                  : '$_matchesDone of $_totalMatches matches completed',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.35),
                  fontSize: 11),
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _matchPill(
      {required String label,
      required int value,
      required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value.toString(),
            style: TextStyle(
                color: color,
                fontSize: 26,
                fontWeight: FontWeight.w900,
                height: 1.0)),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(
                color: Colors.white.withOpacity(0.45), fontSize: 11)),
      ]),
    );
  }

  // ── Per-category breakdown ─────────────────────────────────────────────────
  Widget _buildCategoryBreakdown() {
    if (_categoryStats.isEmpty) return const SizedBox();

    final catColors = [_accent, _orange, _purple, _green, _red, _gold];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle(
          'CATEGORY BREAKDOWN', Icons.category_rounded, _orange),
      const SizedBox(height: 12),
      ...(_categoryStats.asMap().entries.map((e) {
        final i     = e.key;
        final cat   = e.value;
        final color = catColors[i % catColors.length];
        final name  = cat['category_type']?.toString() ?? '';
        final teams = int.tryParse(cat['team_count']?.toString() ?? '0') ?? 0;
        final players = int.tryParse(cat['player_count']?.toString() ?? '0') ?? 0;
        final matches = int.tryParse(cat['match_count']?.toString() ?? '0') ?? 0;
        final done    = int.tryParse(cat['done_count']?.toString() ?? '0') ?? 0;
        final isActive = (cat['status']?.toString() ?? 'active') == 'active';
        final pct = matches == 0 ? 0.0 : (done / matches).clamp(0.0, 1.0);

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: isActive
                  ? color.withOpacity(0.05)
                  : Colors.white.withOpacity(0.02),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isActive
                    ? color.withOpacity(0.25)
                    : Colors.white.withOpacity(0.08),
                width: 1.5,
              ),
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(children: [
                Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive ? color : Colors.white24,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(name,
                      style: TextStyle(
                          color:
                              isActive ? Colors.white : Colors.white38,
                          fontWeight: FontWeight.w700,
                          fontSize: 13)),
                ),
                if (!isActive)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: Colors.red.withOpacity(0.3)),
                    ),
                    child: const Text('INACTIVE',
                        style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1)),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                      border:
                          Border.all(color: color.withOpacity(0.3)),
                    ),
                    child: Text('ACTIVE',
                        style: TextStyle(
                            color: color,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1)),
                  ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                _catStat(label: 'Teams',   value: teams,   color: color),
                const SizedBox(width: 20),
                _catStat(label: 'Players', value: players, color: color),
                const SizedBox(width: 20),
                _catStat(label: 'Matches', value: matches, color: color),
                const SizedBox(width: 20),
                _catStat(label: 'Done',    value: done,    color: _green),
              ]),
              if (matches > 0) ...[
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: pct,
                        minHeight: 6,
                        backgroundColor:
                            Colors.white.withOpacity(0.06),
                        valueColor:
                            AlwaysStoppedAnimation<Color>(color),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('${(pct * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                ]),
              ],
            ]),
          ),
        );
      })),
    ]);
  }

  Widget _catStat(
      {required String label,
      required int value,
      required Color color}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value.toString(),
          style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.w900,
              height: 1.0)),
      Text(label,
          style: TextStyle(
              color: Colors.white.withOpacity(0.4), fontSize: 10)),
    ]);
  }

  // ── Recent teams ───────────────────────────────────────────────────────────
  Widget _buildRecentTeams() {
    if (_recentTeams.isEmpty) return const SizedBox();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle('RECENTLY REGISTERED TEAMS',
          Icons.new_releases_rounded, _purple),
      const SizedBox(height: 12),
      Container(
        decoration: BoxDecoration(
          color: _purple.withOpacity(0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _purple.withOpacity(0.2)),
        ),
        child: Column(
          children: _recentTeams.asMap().entries.map((e) {
            final i    = e.key;
            final team = e.value;
            final id   = team['team_id']?.toString() ?? '';
            final n    = int.tryParse(id);
            final dispId =
                n != null ? 'C${n.toString().padLeft(3, '0')}R' : id;
            final isLast = i == _recentTeams.length - 1;
            return Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                border: isLast
                    ? null
                    : Border(
                        bottom: BorderSide(
                            color: Colors.white.withOpacity(0.06))),
              ),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _purple.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: _purple.withOpacity(0.35)),
                  ),
                  child: Text(dispId,
                      style: const TextStyle(
                          color: _purple,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                      team['team_name']?.toString() ?? '',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13)),
                ),
                Text(
                    team['category_type']?.toString() ?? '',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.35),
                        fontSize: 11)),
              ]),
            );
          }).toList(),
        ),
      ),
    ]);
  }

  // ── Shared ─────────────────────────────────────────────────────────────────
  Widget _sectionTitle(String title, IconData icon, Color color) {
    return Row(children: [
      Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withOpacity(0.1),
            border: Border.all(color: color.withOpacity(0.3))),
        child: Icon(icon, color: color, size: 14),
      ),
      const SizedBox(width: 10),
      Text(title,
          style: TextStyle(
              color: color.withOpacity(0.85),
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5)),
    ]);
  }
}

// ── Internal model ─────────────────────────────────────────────────────────────
class _StatCard {
  final String   label;
  final int      value;
  final IconData icon;
  final Color    color;
  final String?  subtitle;
  const _StatCard(
      {required this.label,
      required this.value,
      required this.icon,
      required this.color,
      this.subtitle});
}