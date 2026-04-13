// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'db_helper.dart';

class Dashboard extends StatefulWidget {
  final VoidCallback? onBack;
  const Dashboard({super.key, this.onBack});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard>
    with TickerProviderStateMixin {
  // ── palette ────────────────────────────────────────────────────────────────
  static const _bg     = Color(0xFF07041A);
  static const _accent = Color(0xFF00CFFF);
  static const _green  = Color(0xFF00E5A0);
  static const _gold   = Color(0xFFFFD700);
  static const _orange = Color(0xFFFF9F43);
  static const _purple = Color(0xFF9B6FE8);
  static const _red    = Color(0xFFFF6B6B);

  // ── data ──────────────────────────────────────────────────────────────────
  int _totalSchools     = 0;
  int _totalMentors     = 0;
  int _totalTeams       = 0;
  int _totalPlayers     = 0;
  int _totalReferees    = 0;
  int _totalCategories  = 0;
  int _activeCategories = 0;
  int _totalMatches     = 0;
  int _matchesDone      = 0;
  int _matchesPending   = 0;
  List<Map<String, dynamic>> _categoryStats = [];

  bool      _isLoading    = true;
  DateTime? _lastRefreshed;
  Timer?    _autoRefresh;

  // ── animation controllers ─────────────────────────────────────────────────
  late AnimationController _fadeCtrl;
  late AnimationController _donutCtrl;
  late AnimationController _barCtrl;
  late AnimationController _countCtrl;
  late AnimationController _pulseCtrl;

  late Animation<double> _fadeAnim;
  late Animation<double> _donutAnim;
  late Animation<double> _barAnim;
  late Animation<double> _countAnim;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _donutCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _barCtrl   = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _countCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat(reverse: true);

    _fadeAnim  = CurvedAnimation(parent: _fadeCtrl,  curve: Curves.easeOut);
    _donutAnim = CurvedAnimation(parent: _donutCtrl, curve: Curves.easeOutCubic);
    _barAnim   = CurvedAnimation(parent: _barCtrl,   curve: Curves.easeOutCubic);
    _countAnim = CurvedAnimation(parent: _countCtrl, curve: Curves.easeOutCubic);
    _pulseAnim = Tween<double>(begin: 0.4, end: 1.0)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _loadData();
    _autoRefresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _loadData(silent: true);
    });
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    _fadeCtrl.dispose();
    _donutCtrl.dispose();
    _barCtrl.dispose();
    _countCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ── Data loading ───────────────────────────────────────────────────────────
  Future<void> _loadData({bool silent = false}) async {
    if (!silent) setState(() => _isLoading = true);
    try {
      final conn = await DBHelper.getConnection();
      Future<int> count(String sql) async {
        final r = await conn.execute(sql);
        return int.tryParse(
                r.rows.first.assoc().values.first?.toString() ?? '0') ?? 0;
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
      ]);

      final doneResult = await conn.execute(
          'SELECT COUNT(DISTINCT match_id) AS cnt FROM tbl_score');
      final matchesDone = int.tryParse(
              doneResult.rows.first.assoc()['cnt']?.toString() ?? '0') ?? 0;

      final catResult = await conn.execute('''
        SELECT c.category_id, c.category_type, c.status,
               COUNT(DISTINCT t.team_id)   AS team_count,
               COUNT(DISTINCT p.player_id) AS player_count,
               COUNT(DISTINCT ts.match_id) AS match_count,
               COUNT(DISTINCT sc.match_id) AS done_count
        FROM tbl_category c
        LEFT JOIN tbl_team         t  ON t.category_id = c.category_id
        LEFT JOIN tbl_player       p  ON p.team_id     = t.team_id
        LEFT JOIN tbl_teamschedule ts ON ts.team_id    = t.team_id
        LEFT JOIN tbl_score        sc ON sc.match_id   = ts.match_id
        GROUP BY c.category_id, c.category_type, c.status
        ORDER BY c.category_id
      ''');

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
        _categoryStats    = catResult.rows.map((r) => r.assoc()).toList();
        _isLoading        = false;
        _lastRefreshed    = DateTime.now();
      });

      _fadeCtrl.forward(from: 0);
      _countCtrl.forward(from: 0);
      await Future.delayed(const Duration(milliseconds: 200));
      _donutCtrl.forward(from: 0);
      _barCtrl.forward(from: 0);
    } catch (e) {
      debugPrint('Dashboard DB error: $e');
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('❌ Failed to load dashboard.'),
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
              ? const Center(child: CircularProgressIndicator(color: _accent))
              : FadeTransition(
                  opacity: _fadeAnim,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildLiveRow(),
                        const SizedBox(height: 20),
                        _buildTopStats(),
                        const SizedBox(height: 24),
                        _buildMatchProgress(),
                        const SizedBox(height: 24),
                        _buildCategoryBreakdown(),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
        ),
      ]),
    );
  }

  // ── Header — consistent with schedule_viewer ──────────────────────────────
  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF2D0E7A), Color(0xFF1A0850)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        border: Border(bottom: BorderSide(color: Color(0xFF3D1E88), width: 1)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text('ROBOVENTURE',
              style: TextStyle(color: Colors.white30, fontSize: 13,
                  fontWeight: FontWeight.bold, letterSpacing: 2)),
          Expanded(
            child: Center(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _accent.withOpacity(0.12),
                      border: Border.all(color: _accent.withOpacity(0.4))),
                  child: const Icon(Icons.dashboard_rounded, color: _accent, size: 16),
                ),
                const SizedBox(width: 10),
                const Text('DASHBOARD',
                    style: TextStyle(color: Colors.white, fontSize: 20,
                        fontWeight: FontWeight.w900, letterSpacing: 3)),
              ]),
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: const Icon(Icons.refresh_rounded, color: _accent, size: 20),
            onPressed: () => _loadData(),
          ),
          IconButton(
            tooltip: 'Back to Home',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: const Icon(Icons.arrow_back_ios_new, color: _accent, size: 20),
            onPressed: widget.onBack,
          ),
        ],
      ),
    );
  }

  // ── Live status row with pulsing dot ──────────────────────────────────────
  Widget _buildLiveRow() {
    final t = _lastRefreshed;
    final timeStr = t == null
        ? '--:--:--'
        : '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}:'
          '${t.second.toString().padLeft(2, '0')}';

    return Row(children: [
      AnimatedBuilder(
        animation: _pulseAnim,
        builder: (_, __) => Container(
          width: 8, height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _green.withOpacity(_pulseAnim.value),
            boxShadow: [BoxShadow(
                color: _green.withOpacity(_pulseAnim.value * 0.6),
                blurRadius: 6, spreadRadius: 1)],
          ),
        ),
      ),
      const SizedBox(width: 7),
      Text('LIVE  $timeStr',
          style: TextStyle(color: _green.withOpacity(0.8), fontSize: 11,
              fontWeight: FontWeight.bold, letterSpacing: 1)),
      const SizedBox(width: 8),
      Text('• auto-refreshes every 30s',
          style: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 10)),
    ]);
  }

  // ── Stat cards with count-up + bar chart ──────────────────────────────────
  Widget _buildTopStats() {
    final stats = [
      _StatCard(label: 'Schools',    value: _totalSchools,    icon: Icons.school_rounded,        color: _accent),
      _StatCard(label: 'Mentors',    value: _totalMentors,    icon: Icons.person_rounded,         color: _purple),
      _StatCard(label: 'Teams',      value: _totalTeams,      icon: Icons.groups_rounded,         color: _gold),
      _StatCard(label: 'Players',    value: _totalPlayers,    icon: Icons.sports_esports_rounded, color: _green),
      _StatCard(label: 'Referees',   value: _totalReferees,   icon: Icons.sports_rounded,         color: _orange),
      _StatCard(label: 'Categories', value: _totalCategories, icon: Icons.category_rounded,       color: _red,
          subtitle: '$_activeCategories active'),
    ];
    final maxVal = stats.map((s) => s.value).fold(0, (a, b) => a > b ? a : b);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle('REGISTRATION SUMMARY', Icons.how_to_reg_rounded, _accent),
      const SizedBox(height: 14),

      // Animated count-up stat cards
      AnimatedBuilder(
        animation: _countAnim,
        builder: (_, __) => Wrap(
          spacing: 12,
          runSpacing: 12,
          children: stats.map((s) {
            final displayVal = (_countAnim.value * s.value).round();
            return _buildStatCard(s, displayVal);
          }).toList(),
        ),
      ),

      const SizedBox(height: 16),

      // Animated horizontal bar chart
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        decoration: BoxDecoration(
          color: _accent.withOpacity(0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _accent.withOpacity(0.15), width: 1.5),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('REGISTRATION OVERVIEW',
              style: TextStyle(color: Colors.white.withOpacity(0.4),
                  fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.bold)),
          const SizedBox(height: 14),
          AnimatedBuilder(
            animation: _barAnim,
            builder: (_, __) => Column(
              children: stats.map((s) {
                final fraction = maxVal == 0
                    ? 0.0
                    : ((s.value / maxVal) * _barAnim.value).clamp(0.0, 1.0);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: Row(children: [
                    SizedBox(width: 82,
                        child: Text(s.label,
                            style: TextStyle(color: Colors.white.withOpacity(0.6),
                                fontSize: 11, fontWeight: FontWeight.w500))),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Stack(children: [
                        Container(height: 16,
                            decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.04),
                                borderRadius: BorderRadius.circular(4))),
                        FractionallySizedBox(
                          widthFactor: fraction,
                          child: Container(
                            height: 16,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                  colors: [s.color.withOpacity(0.55), s.color]),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ]),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(width: 28,
                        child: Text('${s.value}',
                            style: TextStyle(color: s.color, fontSize: 12,
                                fontWeight: FontWeight.w900))),
                  ]),
                );
              }).toList(),
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _buildStatCard(_StatCard s, int displayVal) {
    return Container(
      width: 155,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [s.color.withOpacity(0.10), s.color.withOpacity(0.03)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: s.color.withOpacity(0.28), width: 1.5),
        boxShadow: [
          BoxShadow(color: s.color.withOpacity(0.08), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: s.color.withOpacity(0.14),
              border: Border.all(color: s.color.withOpacity(0.35))),
          child: Icon(s.icon, color: s.color, size: 18),
        ),
        const SizedBox(height: 12),
        Text('$displayVal',
            style: TextStyle(color: s.color, fontSize: 32,
                fontWeight: FontWeight.w900, height: 1.0)),
        const SizedBox(height: 4),
        Text(s.label,
            style: TextStyle(color: Colors.white.withOpacity(0.65),
                fontSize: 12, fontWeight: FontWeight.w600)),
        if (s.subtitle != null) ...[
          const SizedBox(height: 2),
          Text(s.subtitle!,
              style: TextStyle(color: s.color.withOpacity(0.55), fontSize: 10)),
        ],
      ]),
    );
  }

  // ── Match progress — animated donut ───────────────────────────────────────
  Widget _buildMatchProgress() {
    final targetPct = _totalMatches == 0
        ? 0.0
        : (_matchesDone / _totalMatches).clamp(0.0, 1.0);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle('MATCH PROGRESS', Icons.sports_score_rounded, _green),
      const SizedBox(height: 12),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [_green.withOpacity(0.07), _green.withOpacity(0.02)],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _green.withOpacity(0.22), width: 1.5),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Animated donut
            AnimatedBuilder(
              animation: _donutAnim,
              builder: (_, __) {
                final animPct = _donutAnim.value * targetPct;
                return SizedBox(
                  width: 140, height: 140,
                  child: CustomPaint(
                    painter: _DonutChartPainter(
                      fraction: animPct,
                      doneColor: _green,
                      pendingColor: _orange,
                      bgColor: Colors.white.withOpacity(0.05),
                    ),
                    child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text('${(animPct * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(color: Colors.white,
                                fontSize: 24, fontWeight: FontWeight.w900, height: 1.0)),
                        Text('done',
                            style: TextStyle(color: Colors.white.withOpacity(0.4),
                                fontSize: 10, letterSpacing: 1.2)),
                      ]),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(width: 28),
            // Stats + animated progress bar
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _matchPill(label: 'Total Matches', value: _totalMatches, color: _accent),
                const SizedBox(height: 12),
                _matchPill(label: 'Completed',     value: _matchesDone,    color: _green),
                const SizedBox(height: 12),
                _matchPill(label: 'Pending',       value: _matchesPending, color: _orange),
                const SizedBox(height: 16),
                AnimatedBuilder(
                  animation: _donutAnim,
                  builder: (_, __) {
                    final animPct = _donutAnim.value * targetPct;
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Stack(children: [
                        Container(height: 8,
                            decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.06),
                                borderRadius: BorderRadius.circular(6))),
                        FractionallySizedBox(
                          widthFactor: animPct,
                          child: Container(
                            height: 8,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                  colors: [Color(0xFF00E5A0), Color(0xFF00CFFF)]),
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        _legendDot(_green,  'Completed'),
                        const SizedBox(width: 14),
                        _legendDot(_orange, 'Pending'),
                      ]),
                    ]);
                  },
                ),
              ]),
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _legendDot(Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 8, height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 10)),
    ],
  );

  Widget _matchPill({required String label, required int value, required Color color}) {
    return Row(children: [
      Container(width: 3, height: 32,
          decoration: BoxDecoration(
              gradient: LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter,
                  colors: [color, color.withOpacity(0.3)]),
              borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 12),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$value',
            style: TextStyle(color: color, fontSize: 20,
                fontWeight: FontWeight.w900, height: 1.0)),
        Text(label,
            style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 10)),
      ]),
    ]);
  }

  // ── Category breakdown ─────────────────────────────────────────────────────
  Widget _buildCategoryBreakdown() {
    if (_categoryStats.isEmpty) return const SizedBox();

    final catColors = [_accent, _orange, _purple, _green, _red, _gold];
    final maxTeams  = _categoryStats
        .map((c) => int.tryParse(c['team_count']?.toString() ?? '0') ?? 0)
        .fold(0, (a, b) => a > b ? a : b);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle('CATEGORY BREAKDOWN', Icons.category_rounded, _orange),
      const SizedBox(height: 12),

      // Animated teams-per-category bar chart
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        decoration: BoxDecoration(
          color: _orange.withOpacity(0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _orange.withOpacity(0.18), width: 1.5),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('TEAMS PER CATEGORY',
              style: TextStyle(color: Colors.white.withOpacity(0.4),
                  fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          AnimatedBuilder(
            animation: _barAnim,
            builder: (_, __) => Column(
              children: _categoryStats.asMap().entries.map((e) {
                final i     = e.key;
                final cat   = e.value;
                final color = catColors[i % catColors.length];
                final name  = cat['category_type']?.toString() ?? '';
                final teams = int.tryParse(cat['team_count']?.toString() ?? '0') ?? 0;
                final frac  = maxTeams == 0
                    ? 0.0
                    : ((teams / maxTeams) * _barAnim.value).clamp(0.0, 1.0);

                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(width: 8, height: 8,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(name,
                          style: TextStyle(color: Colors.white.withOpacity(0.75),
                              fontSize: 11, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis)),
                      Text('$teams teams',
                          style: TextStyle(color: color, fontSize: 11,
                              fontWeight: FontWeight.w900)),
                    ]),
                    const SizedBox(height: 6),
                    Stack(children: [
                      Container(height: 10,
                          decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.04),
                              borderRadius: BorderRadius.circular(5))),
                      FractionallySizedBox(
                        widthFactor: frac,
                        child: Container(
                          height: 10,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                                colors: [color.withOpacity(0.6), color]),
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                      ),
                    ]),
                  ]),
                );
              }).toList(),
            ),
          ),
        ]),
      ),

      const SizedBox(height: 12),

      // Per-category detail cards
      ...(_categoryStats.asMap().entries.map((e) {
        final i       = e.key;
        final cat     = e.value;
        final color   = catColors[i % catColors.length];
        final name    = cat['category_type']?.toString() ?? '';
        final teams   = int.tryParse(cat['team_count']?.toString()   ?? '0') ?? 0;
        final players = int.tryParse(cat['player_count']?.toString() ?? '0') ?? 0;
        final matches = int.tryParse(cat['match_count']?.toString()  ?? '0') ?? 0;
        final done    = int.tryParse(cat['done_count']?.toString()   ?? '0') ?? 0;
        final isActive = (cat['status']?.toString() ?? 'active') == 'active';
        final pct     = matches == 0 ? 0.0 : (done / matches).clamp(0.0, 1.0);

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: isActive
                    ? [color.withOpacity(0.08), color.withOpacity(0.02)]
                    : [Colors.white.withOpacity(0.02), Colors.transparent],
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isActive
                    ? color.withOpacity(0.28)
                    : Colors.white.withOpacity(0.08),
                width: 1.5,
              ),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 10, height: 10,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isActive ? color : Colors.white24)),
                const SizedBox(width: 10),
                Expanded(child: Text(name,
                    style: TextStyle(
                        color: isActive ? Colors.white : Colors.white38,
                        fontWeight: FontWeight.w700, fontSize: 13))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (isActive ? color : Colors.red).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: (isActive ? color : Colors.red).withOpacity(0.3)),
                  ),
                  child: Text(isActive ? 'ACTIVE' : 'INACTIVE',
                      style: TextStyle(
                          color: isActive ? color : Colors.redAccent,
                          fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1)),
                ),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                _catStat(label: 'Teams',   value: teams,   color: color),
                const SizedBox(width: 24),
                _catStat(label: 'Players', value: players, color: color),
                const SizedBox(width: 24),
                _catStat(label: 'Matches', value: matches, color: color),
                const SizedBox(width: 24),
                _catStat(label: 'Done',    value: done,    color: _green),
              ]),
              if (matches > 0) ...[
                const SizedBox(height: 12),
                AnimatedBuilder(
                  animation: _barAnim,
                  builder: (_, __) => Row(children: [
                    Expanded(
                      child: Stack(children: [
                        Container(height: 6,
                            decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.06),
                                borderRadius: BorderRadius.circular(3))),
                        FractionallySizedBox(
                          widthFactor: (pct * _barAnim.value).clamp(0.0, 1.0),
                          child: Container(height: 6,
                              decoration: BoxDecoration(
                                  color: color,
                                  borderRadius: BorderRadius.circular(3))),
                        ),
                      ]),
                    ),
                    const SizedBox(width: 10),
                    Text('${(pct * 100).toStringAsFixed(0)}%',
                        style: TextStyle(color: color, fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  ]),
                ),
              ],
            ]),
          ),
        );
      }).toList()),
    ]);
  }

  Widget _catStat({required String label, required int value, required Color color}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('$value',
          style: TextStyle(color: color, fontSize: 18,
              fontWeight: FontWeight.w900, height: 1.0)),
      Text(label,
          style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 10)),
    ]);
  }

  // ── Shared ─────────────────────────────────────────────────────────────────
  Widget _sectionTitle(String title, IconData icon, Color color) {
    return Row(children: [
      Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withOpacity(0.12),
            border: Border.all(color: color.withOpacity(0.35))),
        child: Icon(icon, color: color, size: 14),
      ),
      const SizedBox(width: 10),
      Text(title,
          style: TextStyle(color: color.withOpacity(0.9), fontSize: 11,
              fontWeight: FontWeight.bold, letterSpacing: 1.5)),
    ]);
  }
}

// ── Donut chart painter ────────────────────────────────────────────────────────
class _DonutChartPainter extends CustomPainter {
  final double fraction;
  final Color  doneColor;
  final Color  pendingColor;
  final Color  bgColor;

  const _DonutChartPainter({
    required this.fraction,
    required this.doneColor,
    required this.pendingColor,
    required this.bgColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const strokeW    = 15.0;
    final center     = Offset(size.width / 2, size.height / 2);
    final radius     = (size.shortestSide / 2) - strokeW / 2;
    const startAngle = -math.pi / 2;

    final bgPaint = Paint()
      ..color       = bgColor
      ..style       = PaintingStyle.stroke
      ..strokeWidth = strokeW;

    final donePaint = Paint()
      ..shader = LinearGradient(
        colors: [doneColor.withOpacity(0.7), doneColor],
        begin: Alignment.topLeft, end: Alignment.bottomRight,
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style       = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeCap   = StrokeCap.round;

    final pendPaint = Paint()
      ..color       = pendingColor.withOpacity(0.35)
      ..style       = PaintingStyle.stroke
      ..strokeWidth = strokeW - 5
      ..strokeCap   = StrokeCap.round;

    final glowPaint = Paint()
      ..color       = doneColor.withOpacity(0.25)
      ..style       = PaintingStyle.stroke
      ..strokeWidth = strokeW + 6
      ..maskFilter  = const MaskFilter.blur(BlurStyle.normal, 6);

    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawArc(rect, 0, math.pi * 2, false, bgPaint);

    if (fraction < 1.0) {
      canvas.drawArc(rect,
          startAngle + fraction * math.pi * 2,
          (1.0 - fraction) * math.pi * 2,
          false, pendPaint);
    }
    if (fraction > 0) {
      canvas.drawArc(rect, startAngle, fraction * math.pi * 2, false, glowPaint);
      canvas.drawArc(rect, startAngle, fraction * math.pi * 2, false, donePaint);
    }
  }

  @override
  bool shouldRepaint(_DonutChartPainter old) => old.fraction != fraction;
}

// ── Internal model ─────────────────────────────────────────────────────────────
class _StatCard {
  final String   label;
  final int      value;
  final IconData icon;
  final Color    color;
  final String?  subtitle;
  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.subtitle,
  });
}