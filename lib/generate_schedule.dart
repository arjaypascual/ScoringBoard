import 'package:flutter/material.dart';
import 'db_helper.dart';
import 'registration_shared.dart';

class GenerateSchedule extends StatefulWidget {
  final VoidCallback? onBack;
  final VoidCallback? onGenerated;

  const GenerateSchedule({
    super.key,
    this.onBack,
    this.onGenerated,
  });

  @override
  State<GenerateSchedule> createState() => _GenerateScheduleState();
}

class _GenerateScheduleState extends State<GenerateSchedule>
    with TickerProviderStateMixin {
  static const _accent       = Color(0xFF00CFFF);
  static const _soccerAccent = Color(0xFFFF6B35);

  // ── Non-soccer data ────────────────────────────────────────────────────────
  final Map<int, int>  _runsPerCategory      = {};
  final Map<int, int>  _arenasPerCategory    = {};
  final Map<int, int>  _teamCountPerCategory = {};
  final Map<int, bool> _expandedCategories   = {};
  List<Map<String, dynamic>> _categories     = [];

  // ── Soccer data ────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _soccerTeams      = [];
  int?                        _soccerCatId;
  bool                        _showSoccerTeams  = false;
  bool                        _bracketGenerated = false;

  // ── Shared state ───────────────────────────────────────────────────────────
  bool _isLoadingData = true;
  bool _isGenerating  = false;
  bool _isGenBracket  = false;

  TimeOfDay _startTime = const TimeOfDay(hour: 9,  minute: 0);
  TimeOfDay _endTime   = const TimeOfDay(hour: 17, minute: 0);
  final _durationController = TextEditingController(text: '6');
  final _intervalController = TextEditingController(text: '0');
  bool _lunchBreakEnabled   = true;

  static const int _maxTeamsPerArena = 30;

  // ── Animation controllers ──────────────────────────────────────────────────
  final Map<int, AnimationController> _catAnimCtrls = {};
  final Map<int, Animation<double>>   _catAnims     = {};
  late AnimationController _soccerTeamAnimCtrl;
  late Animation<double>   _soccerTeamAnim;

  @override
  void initState() {
    super.initState();
    _soccerTeamAnimCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _soccerTeamAnim = CurvedAnimation(
        parent: _soccerTeamAnimCtrl, curve: Curves.easeInOut);
    _loadCategories();
    _durationController.addListener(() => setState(() {}));
    _intervalController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final c in _catAnimCtrls.values) c.dispose();
    _soccerTeamAnimCtrl.dispose();
    _durationController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  // ── Load ───────────────────────────────────────────────────────────────────
  Future<void> _loadCategories() async {
    try {
      final cats = await DBHelper.getCategories();
      final seen = <int>{};
      final unique = cats.where((c) {
        final id = int.tryParse(c['category_id'].toString()) ?? 0;
        return id > 0 && seen.add(id);
      }).toList();

      final nonSoccer = <Map<String, dynamic>>[];
      int? soccerCatId;
      List<Map<String, dynamic>> soccerTeams = [];

      for (final c in unique) {
        final id   = int.tryParse(c['category_id'].toString()) ?? 0;
        final name = (c['category_type'] ?? '').toString().toLowerCase();
        if (name.contains('soccer')) {
          soccerCatId = id;
          soccerTeams = await DBHelper.getTeamsByCategory(id);
        } else {
          nonSoccer.add(c);
        }
      }

      final Map<int, int> teamCounts = {};
      for (final c in nonSoccer) {
        final id    = int.tryParse(c['category_id'].toString()) ?? 0;
        final teams = await DBHelper.getTeamsByCategory(id);
        teamCounts[id] = teams.length;
      }

      for (final c in nonSoccer) {
        final id   = int.tryParse(c['category_id'].toString()) ?? 0;
        final ctrl = AnimationController(
            vsync: this, duration: const Duration(milliseconds: 280));
        _catAnimCtrls[id] = ctrl;
        _catAnims[id] = CurvedAnimation(parent: ctrl, curve: Curves.easeInOut);
        _expandedCategories[id] = false;
      }

      setState(() {
        _categories  = nonSoccer;
        _soccerCatId = soccerCatId;
        _soccerTeams = soccerTeams;
        for (final c in nonSoccer) {
          final id    = int.tryParse(c['category_id'].toString()) ?? 0;
          final count = teamCounts[id] ?? 0;
          _runsPerCategory[id]      = 2;
          _arenasPerCategory[id]    = count == 0 ? 1 : (count / _maxTeamsPerArena).ceil();
          _teamCountPerCategory[id] = count;
        }
        _isLoadingData = false;
      });
    } catch (e) {
      setState(() => _isLoadingData = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('❌ Failed to load categories: $e'),
            backgroundColor: Colors.red));
      }
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  String? _arenaWarning(int id) {
    final teams  = _teamCountPerCategory[id] ?? 0;
    final arenas = _arenasPerCategory[id]    ?? 1;
    if (teams == 0) return null;
    if (teams > arenas * _maxTeamsPerArena)
      return '$teams teams — needs ≥${(teams / _maxTeamsPerArena).ceil()} arenas';
    return null;
  }

  bool get _hasArenaError => _categories.any((c) {
    final id = int.tryParse(c['category_id'].toString()) ?? 0;
    return _arenaWarning(id) != null;
  });

  void _toggleCategory(int id) {
    final open = _expandedCategories[id] ?? false;
    setState(() => _expandedCategories[id] = !open);
    open ? _catAnimCtrls[id]?.reverse() : _catAnimCtrls[id]?.forward();
  }

  void _toggleSoccerTeams() {
    setState(() => _showSoccerTeams = !_showSoccerTeams);
    _showSoccerTeams
        ? _soccerTeamAnimCtrl.forward()
        : _soccerTeamAnimCtrl.reverse();
  }

  void _snack(String msg, Color color) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));

  // ── Generate Schedule ──────────────────────────────────────────────────────
  Future<void> _generateSchedule() async {
    final duration = int.tryParse(_durationController.text.trim()) ?? 6;
    final interval = int.tryParse(_intervalController.text.trim()) ?? 0;
    if (duration <= 0) { _snack('❌ Duration must be > 0.', Colors.red); return; }
    final sm = _startTime.hour * 60 + _startTime.minute;
    final em = _endTime.hour   * 60 + _endTime.minute;
    if (em <= sm) { _snack('❌ End time must be after start time.', Colors.red); return; }
    if (_hasArenaError) { _snack('❌ Some categories exceed arena capacity.', Colors.red); return; }

    final confirmed = await _showConfirmDialog();
    if (confirmed != true) return;
    setState(() => _isGenerating = true);
    try {
      final st = '${_startTime.hour.toString().padLeft(2, '0')}:${_startTime.minute.toString().padLeft(2, '0')}';
      final et = '${_endTime.hour.toString().padLeft(2, '0')}:${_endTime.minute.toString().padLeft(2, '0')}';
      await DBHelper.generateSchedule(
        runsPerCategory:   _runsPerCategory,
        arenasPerCategory: _arenasPerCategory,
        startTime:         st,
        endTime:           et,
        durationMinutes:   duration,
        intervalMinutes:   interval,
        lunchBreak:        _lunchBreakEnabled,
      );
      if (mounted) { _snack('✅ Schedule generated!', Colors.green); widget.onGenerated?.call(); }
    } catch (e) {
      if (mounted) _snack('❌ Error: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  // ── Generate Bracket ───────────────────────────────────────────────────────
  Future<void> _generateBracket() async {
    final tc = _soccerTeams.length;
    // CHANGED: Minimum 4 teams, no maximum limit
    if (tc < 4) { 
      _snack('❌ Need at least 4 Soccer teams (have $tc).', Colors.red); 
      return; 
    }

    setState(() => _isGenBracket = true);
    await Future.delayed(const Duration(milliseconds: 700));
    setState(() { _bracketGenerated = true; _isGenBracket = false; });
    if (mounted) {
      _snack('✅ Bracket ready! Opening Soccer Groups...', Colors.green);
      await Future.delayed(const Duration(milliseconds: 800));
      widget.onGenerated?.call();
    }
  }

  // ── Confirm dialog ─────────────────────────────────────────────────────────
  Future<bool?> _showConfirmDialog() => showDialog<bool>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 400, padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xFF2D0E7A), Color(0xFF1E0A5A)]),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.orange.withOpacity(0.4), width: 1.5),
          boxShadow: [BoxShadow(color: Colors.orange.withOpacity(0.1),
              blurRadius: 30, spreadRadius: 4)],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(shape: BoxShape.circle,
                color: Colors.orange.withOpacity(0.15),
                border: Border.all(color: Colors.orange.withOpacity(0.4))),
            child: const Icon(Icons.warning_amber_rounded,
                color: Colors.orange, size: 30),
          ),
          const SizedBox(height: 16),
          const Text('Regenerate Schedule?',
              style: TextStyle(color: Colors.white, fontSize: 18,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Text('This will DELETE the existing schedule\nand generate a new one.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withOpacity(0.6),
                  fontSize: 13, height: 1.5)),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.white.withOpacity(0.2)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: Text('CANCEL', style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontWeight: FontWeight.bold)),
            )),
            const SizedBox(width: 12),
            Expanded(child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: Ink(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [Colors.orange, Color(0xFFE65100)]),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Center(child: Text('REGENERATE',
                      style: TextStyle(color: Colors.white,
                          fontWeight: FontWeight.bold, letterSpacing: 1))),
                ),
              ),
            )),
          ]),
        ]),
      ),
    ),
  );

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A0A4A),
      body: Column(children: [
        const RegistrationHeader(),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(children: [
                _buildScheduleCard(),
                const SizedBox(height: 20),
                if (_soccerCatId != null) _buildSoccerCard(),
                const SizedBox(height: 24),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CARD 1 — GENERATE SCHEDULE
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildScheduleCard() {
    return Container(
      width: 820,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF2D0E7A), Color(0xFF1E0A5A)]),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _accent.withOpacity(0.3), width: 1.5),
        boxShadow: [
          BoxShadow(color: _accent.withOpacity(0.08),
              blurRadius: 40, spreadRadius: 4),
          BoxShadow(color: Colors.black.withOpacity(0.4),
              blurRadius: 30, offset: const Offset(0, 10)),
        ],
      ),
      child: Stack(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 36, 40, 36),
          child: Column(mainAxisSize: MainAxisSize.min, children: [

            // Title
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(shape: BoxShape.circle,
                    color: _accent.withOpacity(0.1),
                    border: Border.all(color: _accent.withOpacity(0.3))),
                child: const Icon(Icons.calendar_month_rounded,
                    color: _accent, size: 22),
              ),
              const SizedBox(width: 14),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('GENERATE SCHEDULE',
                    style: TextStyle(color: Colors.white, fontSize: 20,
                        fontWeight: FontWeight.w800, letterSpacing: 2)),
                Text('Configure match schedule for all categories (except Soccer)',
                    style: TextStyle(color: Colors.white.withOpacity(0.4),
                        fontSize: 12)),
              ]),
            ]),

            const SizedBox(height: 24),
            buildDivider(_accent),
            const SizedBox(height: 16),

            // ── Categories accordion ─────────────────────────────────────
            _buildAccordionList(),

            const SizedBox(height: 24),
            buildDivider(_accent),
            const SizedBox(height: 20),

            // ── Schedule settings ────────────────────────────────────────
            _buildScheduleSettings(),

            const SizedBox(height: 28),
            buildDivider(_accent),
            const SizedBox(height: 20),

            // ── Generate button ──────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isGenerating ? null : _generateSchedule,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Ink(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: [Color(0xFF00CFFF), Color(0xFF0099CC)]),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [BoxShadow(color: _accent.withOpacity(0.4),
                        blurRadius: 20, spreadRadius: 2)],
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    alignment: Alignment.center,
                    child: _isGenerating
                        ? const SizedBox(width: 22, height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.auto_awesome_rounded,
                                  color: Colors.white, size: 20),
                              SizedBox(width: 10),
                              Text('GENERATE SCHEDULE',
                                  style: TextStyle(color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15, letterSpacing: 2)),
                            ]),
                  ),
                ),
              ),
            ),
          ]),
        ),

        Positioned(top: 12, left: 12,
          child: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, color: _accent, size: 18),
            onPressed: widget.onBack)),
        Positioned(top: 12, right: 12,
          child: IconButton(
            icon: Icon(Icons.close,
                color: Colors.white.withOpacity(0.35), size: 20),
            onPressed: () => Navigator.of(context).maybePop())),
      ]),
    );
  }

  // ── Accordion category list ────────────────────────────────────────────────
  Widget _buildAccordionList() {
    if (_isLoadingData) {
      return const Center(child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(strokeWidth: 2, color: _accent)));
    }
    if (_categories.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12)),
        child: Center(child: Text('No categories found.',
            style: TextStyle(color: Colors.white.withOpacity(0.3),
                fontSize: 13))),
      );
    }

    return Column(
      children: _categories.map((c) {
        final id      = int.tryParse(c['category_id'].toString()) ?? 0;
        final name    = (c['category_type'] ?? '').toString();
        final count   = _teamCountPerCategory[id] ?? 0;
        final runs    = _runsPerCategory[id]      ?? 2;
        final arenas  = _arenasPerCategory[id]    ?? 1;
        final warning = _arenaWarning(id);
        final isOpen  = _expandedCategories[id]   ?? false;

        final statusColor = warning != null
            ? Colors.orange
            : count == 0 ? Colors.white24 : Colors.green;

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: warning != null
                  ? Colors.orange.withOpacity(0.4)
                  : isOpen
                      ? _accent.withOpacity(0.4)
                      : Colors.white.withOpacity(0.08),
              width: 1.5,
            ),
          ),
          child: Column(children: [

            // ── Row header ──────────────────────────────────────────────
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _toggleCategory(id),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 13),
                child: Row(children: [
                  // Status dot
                  Container(width: 8, height: 8,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle, color: statusColor)),
                  const SizedBox(width: 10),

                  // Name
                  Expanded(child: Text(name.toUpperCase(),
                      style: const TextStyle(color: Colors.white,
                          fontWeight: FontWeight.bold, fontSize: 13))),

                  // Team count pill
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(
                      color: count == 0
                          ? Colors.white.withOpacity(0.04)
                          : _accent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: count == 0
                            ? Colors.white12
                            : _accent.withOpacity(0.35)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.groups_rounded, size: 11,
                          color: count == 0 ? Colors.white24 : _accent),
                      const SizedBox(width: 4),
                      Text('$count team${count != 1 ? 's' : ''}',
                          style: TextStyle(fontSize: 11,
                              color: count == 0 ? Colors.white24 : _accent,
                              fontWeight: FontWeight.bold)),
                    ]),
                  ),

                  // Collapsed summary chips
                  if (!isOpen) ...[
                    _chip('$runs run${runs != 1 ? 's' : ''}', _accent),
                    const SizedBox(width: 5),
                    _chip('$arenas arena${arenas != 1 ? 's' : ''}',
                        const Color(0xFF967BB6)),
                    const SizedBox(width: 8),
                  ],

                  // Warning badge
                  if (warning != null)
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: Colors.orange.withOpacity(0.4)),
                      ),
                      child: const Row(mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.warning_amber_rounded,
                                size: 11, color: Colors.orange),
                            SizedBox(width: 4),
                            Text('Needs more arenas',
                                style: TextStyle(fontSize: 9,
                                    color: Colors.orange,
                                    fontWeight: FontWeight.bold)),
                          ]),
                    ),

                  // Chevron
                  AnimatedRotation(
                    turns: isOpen ? 0.5 : 0,
                    duration: const Duration(milliseconds: 280),
                    child: const Icon(Icons.keyboard_arrow_down_rounded,
                        color: Colors.white38, size: 20),
                  ),
                ]),
              ),
            ),

            // ── Expanded body ───────────────────────────────────────────
            SizeTransition(
              sizeFactor: _catAnims[id] ??
                  const AlwaysStoppedAnimation(0),
              child: Column(children: [
                Container(height: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    color: _accent.withOpacity(0.1)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(children: [
                    Row(children: [
                      Expanded(child: _spinnerTile(
                        id: id, isRuns: true,
                        label: 'RUNS PER TEAM',
                        icon: Icons.repeat_rounded,
                        color: _accent,
                      )),
                      const SizedBox(width: 12),
                      Expanded(child: _spinnerTile(
                        id: id, isRuns: false,
                        label: 'ARENAS',
                        icon: Icons.place_rounded,
                        color: const Color(0xFF967BB6),
                        subLabel: 'max $_maxTeamsPerArena teams each',
                      )),
                    ]),
                    const SizedBox(height: 10),
                    if (warning != null)
                      _infoRow(icon: Icons.warning_amber_rounded,
                          color: Colors.orange, text: warning)
                    else if (count > 0)
                      _infoRow(
                        icon: Icons.check_circle_outline_rounded,
                        color: const Color(0xFF00E5A0),
                        text: 'Capacity OK: '
                            '${arenas * _maxTeamsPerArena} teams '
                            '($arenas × $_maxTeamsPerArena)',
                      ),
                  ]),
                ),
              ]),
            ),
          ]),
        );
      }).toList(),
    );
  }

  Widget _chip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withOpacity(0.08),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withOpacity(0.25)),
    ),
    child: Text(text, style: TextStyle(
        color: color.withOpacity(0.85), fontSize: 10,
        fontWeight: FontWeight.bold)),
  );

  Widget _infoRow({
    required IconData icon,
    required Color color,
    required String text,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: color.withOpacity(0.07),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Row(children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text(text,
              style: TextStyle(fontSize: 11, color: color))),
        ]),
      );

  Widget _spinnerTile({
    required int id,
    required bool isRuns,
    required String label,
    required IconData icon,
    required Color color,
    String? subLabel,
  }) {
    final value  = isRuns
        ? (_runsPerCategory[id]   ?? 2)
        : (_arenasPerCategory[id] ?? 1);
    final maxVal = isRuns ? 99 : 3;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 11, color: color.withOpacity(0.7)),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: color.withOpacity(0.8),
              fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
        ]),
        if (subLabel != null) ...[
          const SizedBox(height: 2),
          Text(subLabel, style: TextStyle(
              color: Colors.white.withOpacity(0.25), fontSize: 9,
              fontStyle: FontStyle.italic)),
        ],
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _spinBtn(icon: Icons.remove, color: color,
              onTap: value > 1 ? () => setState(() {
                if (isRuns) _runsPerCategory[id]   = value - 1;
                else        _arenasPerCategory[id] = value - 1;
              }) : null),
          Text('$value', style: TextStyle(color: color, fontSize: 22,
              fontWeight: FontWeight.w900)),
          _spinBtn(icon: Icons.add, color: color,
              onTap: value < maxVal ? () => setState(() {
                if (isRuns) _runsPerCategory[id]   = value + 1;
                else        _arenasPerCategory[id] = value + 1;
              }) : null),
        ]),
      ]),
    );
  }

  Widget _spinBtn({
    required IconData icon,
    required Color color,
    required VoidCallback? onTap,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 30, height: 30,
          decoration: BoxDecoration(shape: BoxShape.circle,
            color: onTap != null
                ? color.withOpacity(0.12)
                : Colors.white.withOpacity(0.03),
            border: Border.all(color: onTap != null
                ? color.withOpacity(0.4) : Colors.white12),
          ),
          child: Icon(icon, size: 14,
              color: onTap != null ? color : Colors.white12),
        ),
      );

  // ── Schedule Settings ──────────────────────────────────────────────────────
  Widget _buildScheduleSettings() {
    final timeError = (_endTime.hour * 60 + _endTime.minute) <=
        (_startTime.hour * 60 + _startTime.minute);

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionLabel('TIME SETTINGS'),
        const SizedBox(height: 10),
        _timeTile(label: 'START TIME', time: _startTime, isStart: true),
        const SizedBox(height: 8),
        _timeTile(label: 'END TIME',   time: _endTime,   isStart: false),
        if (timeError) ...[
          const SizedBox(height: 6),
          _infoRow(icon: Icons.error_outline_rounded, color: Colors.red,
              text: 'End time must be after start time'),
        ],
        const SizedBox(height: 12),
        _buildLunchToggle(),
      ])),
      const SizedBox(width: 20),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionLabel('MATCH TIMING'),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _buildNumberField(
              label: 'DURATION', subtitle: 'min / match',
              controller: _durationController)),
          const SizedBox(width: 12),
          Expanded(child: _buildNumberField(
              label: 'BREAK', subtitle: 'min between',
              controller: _intervalController)),
        ]),
        const SizedBox(height: 10),
        _buildTimingPreview(),
      ])),
    ]);
  }

  Widget _sectionLabel(String text) => Row(children: [
    Container(width: 3, height: 14,
        decoration: BoxDecoration(color: _accent,
            borderRadius: BorderRadius.circular(2))),
    const SizedBox(width: 8),
    Text(text, style: TextStyle(color: _accent.withOpacity(0.85),
        fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 1.5)),
  ]);

  Widget _timeTile({
    required String label,
    required TimeOfDay time,
    required bool isStart,
  }) {
    return GestureDetector(
      onTap: () => _pickTime(isStart),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _accent.withOpacity(0.25)),
        ),
        child: Row(children: [
          Container(padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(shape: BoxShape.circle,
                color: _accent.withOpacity(0.1)),
            child: const Icon(Icons.access_time_rounded,
                size: 14, color: _accent)),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 9,
                color: Colors.white.withOpacity(0.4),
                fontWeight: FontWeight.bold, letterSpacing: 0.5)),
            Text(_fmtTime(time), style: const TextStyle(fontSize: 16,
                fontWeight: FontWeight.bold, color: Colors.white)),
          ]),
          const Spacer(),
          Icon(Icons.edit_rounded, size: 14,
              color: Colors.white.withOpacity(0.3)),
        ]),
      ),
    );
  }

  Widget _buildNumberField({
    required String label,
    required String subtitle,
    required TextEditingController controller,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: Colors.white,
          fontWeight: FontWeight.w700, fontSize: 11, letterSpacing: 1)),
      const SizedBox(height: 6),
      TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white,
            fontSize: 18, fontWeight: FontWeight.bold),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(
              horizontal: 8, vertical: 12),
          filled: true,
          fillColor: Colors.white.withOpacity(0.05),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.15)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _accent, width: 2),
          ),
        ),
      ),
      const SizedBox(height: 4),
      Text(subtitle, style: TextStyle(fontSize: 9,
          color: Colors.white.withOpacity(0.35))),
    ]);
  }

  Widget _buildTimingPreview() {
    final duration  = int.tryParse(_durationController.text.trim()) ?? 0;
    final breakMins = int.tryParse(_intervalController.text.trim())  ?? 0;
    if (duration <= 0) return const SizedBox.shrink();

    String fmt(int hour, int min) {
      final total  = hour * 60 + min;
      final th     = total ~/ 60;
      final tm     = total % 60;
      final period = th < 12 ? 'AM' : 'PM';
      final h12    = th % 12 == 0 ? 12 : th % 12;
      return '${h12.toString().padLeft(2, '0')}:${tm.toString().padLeft(2, '0')} $period';
    }

    final h = _startTime.hour, m = _startTime.minute;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _accent.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _accent.withOpacity(0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.schedule_rounded, size: 11, color: _accent),
          const SizedBox(width: 5),
          const Text('EXAMPLE TIMING',
              style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold,
                  color: _accent, letterSpacing: 1)),
        ]),
        const SizedBox(height: 8),
        _previewRow('Match 1', fmt(h, m),
            fmt(h, m + duration), _accent),
        if (breakMins > 0) ...[
          const SizedBox(height: 4),
          Row(children: [
            const SizedBox(width: 6),
            Icon(Icons.coffee_rounded, size: 10,
                color: Colors.orange.shade400),
            const SizedBox(width: 4),
            Text('$breakMins min break',
                style: TextStyle(fontSize: 9,
                    color: Colors.orange.shade400,
                    fontStyle: FontStyle.italic)),
          ]),
          const SizedBox(height: 4),
        ] else
          const SizedBox(height: 4),
        _previewRow('Match 2',
            fmt(h, m + duration + breakMins),
            fmt(h, m + duration + breakMins + duration),
            const Color(0xFF00E5A0)),
      ]),
    );
  }

  Widget _previewRow(String label, String start, String end, Color color) =>
      Row(children: [
        Container(width: 3, height: 16,
            decoration: BoxDecoration(color: color,
                borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 8),
        Text('$label  ', style: TextStyle(fontSize: 10,
            fontWeight: FontWeight.bold, color: color)),
        Text('$start – $end', style: TextStyle(fontSize: 10,
            color: Colors.white.withOpacity(0.5))),
      ]);

  Widget _buildLunchToggle() {
    return GestureDetector(
      onTap: () => setState(() => _lunchBreakEnabled = !_lunchBreakEnabled),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: _lunchBreakEnabled
              ? const Color(0xFFFFD700).withOpacity(0.07)
              : Colors.white.withOpacity(0.03),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _lunchBreakEnabled
                ? const Color(0xFFFFD700).withOpacity(0.35)
                : Colors.white.withOpacity(0.1),
          ),
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: _lunchBreakEnabled
                  ? const Color(0xFFFFD700).withOpacity(0.15)
                  : Colors.white.withOpacity(0.05),
            ),
            child: Icon(Icons.restaurant_rounded, size: 14,
                color: _lunchBreakEnabled
                    ? const Color(0xFFFFD700) : Colors.white38),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('LUNCH BREAK', style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 11,
                    letterSpacing: 0.5,
                    color: _lunchBreakEnabled
                        ? const Color(0xFFFFD700) : Colors.white38)),
                Text('12:00 PM – 1:00 PM  •  No matches',
                    style: TextStyle(fontSize: 9, height: 1.4,
                        color: _lunchBreakEnabled
                            ? Colors.white38 : Colors.white24)),
              ])),
          Switch(
            value: _lunchBreakEnabled,
            onChanged: (v) => setState(() => _lunchBreakEnabled = v),
            activeColor: const Color(0xFFFFD700),
            inactiveThumbColor: Colors.white24,
            inactiveTrackColor: Colors.white12,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ]),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CARD 2 — SOCCER BRACKET
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildSoccerCard() {
    final tc          = _soccerTeams.length;
    // CHANGED: Now requires minimum 4 teams, no maximum limit
    final canGenerate = tc >= 4;

    return Container(
      width: 820,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF1E0A3A), Color(0xFF110720)]),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
            color: _soccerAccent.withOpacity(0.35), width: 1.5),
        boxShadow: [
          BoxShadow(color: _soccerAccent.withOpacity(0.07),
              blurRadius: 40, spreadRadius: 4),
          BoxShadow(color: Colors.black.withOpacity(0.4),
              blurRadius: 30, offset: const Offset(0, 10)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 32, 40, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [

          // ── Header ──────────────────────────────────────────────────────
          Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: _soccerAccent.withOpacity(0.12),
                  border: Border.all(
                      color: _soccerAccent.withOpacity(0.4))),
              child: const Icon(Icons.sports_soccer,
                  color: _soccerAccent, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('MBOT SOCCER — BRACKET',
                        style: TextStyle(color: Colors.white, fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5)),
                    Text(
                        'Separate from schedule  ·  '
                        'Group Stage → Play-In → Double Elim → Grand Final',
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.35),
                            fontSize: 11)),
                  ]),
            ),
            const SizedBox(width: 14),

            // ── Prominent team count badge ─────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: canGenerate
                    ? _accent.withOpacity(0.12)
                    : Colors.redAccent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: canGenerate
                      ? _accent.withOpacity(0.65)
                      : Colors.redAccent.withOpacity(0.65),
                  width: 2,
                ),
                boxShadow: [BoxShadow(
                  color: (canGenerate ? _accent : Colors.redAccent)
                      .withOpacity(0.2),
                  blurRadius: 10, spreadRadius: 1,
                )],
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.groups,
                    color: canGenerate ? _accent : Colors.redAccent,
                    size: 20),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$tc',
                          style: TextStyle(
                            color: canGenerate
                                ? _accent : Colors.redAccent,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1,
                            height: 1.0,
                          )),
                      Text('Teams Registered',
                          style: TextStyle(
                            color: (canGenerate
                                ? _accent : Colors.redAccent)
                                .withOpacity(0.7),
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                          )),
                    ]),
              ]),
            ),
          ]),

          const SizedBox(height: 20),
          Container(height: 1,
              color: _soccerAccent.withOpacity(0.15)),
          const SizedBox(height: 16),

          // ── Bracket flow diagram ─────────────────────────────────────
          _buildBracketFlow(),
          const SizedBox(height: 16),

          // ── Status notice ────────────────────────────────────────────
          if (!canGenerate)
            _infoRow(
              icon: Icons.error_outline_rounded,
              color: Colors.redAccent,
              // CHANGED: Updated message for minimum 4 teams
              text: 'Need at least 4 teams — ${4 - tc} more required.',
            )
          else if (_bracketGenerated)
            _infoRow(
              icon: Icons.check_circle_outline_rounded,
              color: Colors.green,
              text: 'Bracket generated! Go to the Soccer tab to manage groups.',
            ),

          const SizedBox(height: 14),

          // ── View Teams toggle ────────────────────────────────────────
          GestureDetector(
            onTap: _toggleSoccerTeams,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(children: [
                const Icon(Icons.people_alt_rounded,
                    color: Colors.white38, size: 16),
                const SizedBox(width: 10),
                Text('View All Registered Teams ($tc)',
                    style: const TextStyle(color: Colors.white54,
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const Spacer(),
                AnimatedRotation(
                  turns: _showSoccerTeams ? 0.5 : 0,
                  duration: const Duration(milliseconds: 300),
                  child: const Icon(Icons.keyboard_arrow_down_rounded,
                      color: Colors.white38, size: 20),
                ),
              ]),
            ),
          ),

          // ── Team list ────────────────────────────────────────────────
          SizeTransition(
            sizeFactor: _soccerTeamAnim,
            child: Column(children: [
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0620),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: Colors.white.withOpacity(0.06)),
                ),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                          colors: [Color(0xFF2D0E7A), Color(0xFF1A0850)]),
                      borderRadius: BorderRadius.vertical(
                          top: Radius.circular(11)),
                    ),
                    child: Row(children: [
                      _th('#',         flex: 1),
                      _th('ID',        flex: 2),
                      _th('TEAM NAME', flex: 5),
                    ]),
                  ),
                  if (_soccerTeams.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No teams registered yet.',
                          style: TextStyle(color: Colors.white24,
                              fontSize: 14)),
                    )
                  else
                    ..._soccerTeams.asMap().entries.map((e) {
                      final idx    = e.key;
                      final team   = e.value;
                      final rawId  = team['team_id']?.toString() ?? '';
                      final n      = int.tryParse(rawId);
                      final dispId = n != null
                          ? 'C${n.toString().padLeft(3, '0')}R' : rawId;
                      return Container(
                        decoration: BoxDecoration(
                          color: idx % 2 == 0
                              ? const Color(0xFF0D0830)
                              : const Color(0xFF090620),
                          border: const Border(bottom: BorderSide(
                              color: Color(0xFF1A1050), width: 1)),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 11),
                        child: Row(children: [
                          Expanded(flex: 1, child: Text('${idx + 1}',
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.3),
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold))),
                          Expanded(flex: 2, child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: _accent.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(
                                  color: _accent.withOpacity(0.4)),
                            ),
                            child: Text(dispId,
                                style: const TextStyle(
                                    color: _accent, fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1)),
                          )),
                          Expanded(flex: 5, child: Text(
                              team['team_name']?.toString() ?? '',
                              style: const TextStyle(color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600))),
                        ]),
                      );
                    }),
                ]),
              ),
            ]),
          ),

          const SizedBox(height: 20),

          // ── Generate Bracket button ──────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (canGenerate && !_isGenBracket)
                  ? _generateBracket
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                disabledBackgroundColor: Colors.transparent,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Ink(
                decoration: BoxDecoration(
                  gradient: canGenerate
                      ? const LinearGradient(
                          colors: [Color(0xFFFF6B35), Color(0xFFCC4A1A)])
                      : null,
                  color: canGenerate
                      ? null : Colors.white.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(12),
                  border: canGenerate
                      ? null : Border.all(color: Colors.white12),
                  boxShadow: canGenerate
                      ? [BoxShadow(
                          color: _soccerAccent.withOpacity(0.35),
                          blurRadius: 20, spreadRadius: 2)]
                      : [],
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  alignment: Alignment.center,
                  child: _isGenBracket
                      ? const SizedBox(width: 22, height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              _bracketGenerated
                                  ? Icons.refresh_rounded
                                  : Icons.account_tree_rounded,
                              color: canGenerate
                                  ? Colors.white : Colors.white24,
                              size: 20),
                            const SizedBox(width: 10),
                            Text(
                              _bracketGenerated
                                  ? 'REGENERATE BRACKET'
                                  : 'GENERATE BRACKET',
                              style: TextStyle(
                                color: canGenerate
                                    ? Colors.white : Colors.white24,
                                fontWeight: FontWeight.bold,
                                fontSize: 15, letterSpacing: 2,
                              )),
                          ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildBracketFlow() {
    const steps = [
      (Icons.grid_view_rounded,    'GROUP\nSTAGE', Color(0xFF00CFFF)),
      (Icons.sports_rounded,       'PLAY-IN',      Color(0xFF9B6FE8)),
      (Icons.account_tree_rounded, 'DOUBLE\nELIM', Color(0xFF7B6AFF)),
      (Icons.emoji_events_rounded, 'GRAND\nFINAL', Color(0xFFFFD700)),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
      ),
      child: Row(
        children: steps.asMap().entries.expand((e) {
          final idx  = e.key;
          final step = e.value;
          return [
            Expanded(child: Column(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(shape: BoxShape.circle,
                    color: step.$3.withOpacity(0.12),
                    border: Border.all(
                        color: step.$3.withOpacity(0.5), width: 1.5)),
                child: Icon(step.$1, color: step.$3, size: 18),
              ),
              const SizedBox(height: 6),
              Text(step.$2, textAlign: TextAlign.center,
                  style: TextStyle(color: step.$3, fontSize: 9,
                      fontWeight: FontWeight.bold, height: 1.3)),
            ])),
            if (idx < steps.length - 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 12, height: 1.5,
                      color: Colors.white.withOpacity(0.1)),
                  Icon(Icons.chevron_right,
                      color: Colors.white.withOpacity(0.15), size: 14),
                ]),
              ),
          ];
        }).toList(),
      ),
    );
  }

  Widget _th(String text, {int flex = 1}) => Expanded(
    flex: flex,
    child: Text(text, style: const TextStyle(color: Colors.white54,
        fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1)),
  );

  Future<void> _pickTime(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _startTime : _endTime,
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
              primary: _accent, onPrimary: Colors.black,
              surface: Color(0xFF2D0E7A), onSurface: Colors.white),
          timePickerTheme: TimePickerThemeData(
            dialHandColor: _accent,
            dialBackgroundColor: const Color(0xFF1E0A5A),
            hourMinuteColor: Colors.white.withOpacity(0.1),
            hourMinuteTextColor: Colors.white),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() {
      if (isStart) _startTime = picked; else _endTime = picked;
    });
  }

  String _fmtTime(TimeOfDay t) {
    final period = t.hour < 12 ? 'AM' : 'PM';
    final h12    = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    return '${h12.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} $period';
  }
}