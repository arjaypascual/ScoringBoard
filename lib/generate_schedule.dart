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
  static const _bg          = Color(0xFF0D0625);
  static const _accent      = Color(0xFF00CFFF);
  static const _soccerAccent = Color(0xFFFF6B35);

  // ── Non-soccer category data ───────────────────────────────────────────────
  final Map<int, int>  _runsPerCategory      = {};
  final Map<int, int>  _arenasPerCategory    = {};
  final Map<int, int>  _teamCountPerCategory = {};
  List<Map<String, dynamic>> _categories     = [];

  // ── Per-category timing ────────────────────────────────────────────────────
  final Map<int, TimeOfDay>             _startTimePerCat  = {};
  final Map<int, TextEditingController> _durationPerCat   = {};
  final Map<int, TextEditingController> _matchBreakPerCat = {};

  // Health break per category (= lunch break with editable window)
  final Map<int, bool>      _hbEnabled = {};
  final Map<int, TimeOfDay> _hbStart   = {};
  final Map<int, TimeOfDay> _hbEnd     = {};

  // ── Per-category generate state ────────────────────────────────────────────
  final Map<int, bool> _isGeneratingCat = {};
  final Map<int, bool> _generatedCat    = {};

  // ── Soccer data ────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _soccerTeams   = [];
  int?  _soccerCatId;
  bool  _showSoccerTeams  = false;
  bool  _bracketGenerated = false;
  bool  _isGenBracket     = false;

  // Soccer-specific timing settings
  TimeOfDay _soccerStartTime = const TimeOfDay(hour: 9, minute: 0);
  final TextEditingController _soccerDurationCtrl   = TextEditingController(text: '10');
  final TextEditingController _soccerMatchBreakCtrl = TextEditingController(text: '5');
  bool      _soccerHbEnabled = true;
  TimeOfDay _soccerHbStart   = const TimeOfDay(hour: 12, minute: 0);
  TimeOfDay _soccerHbEnd     = const TimeOfDay(hour: 13, minute: 0);

  // ── Shared ─────────────────────────────────────────────────────────────────
  bool _isLoadingData = true;

  static const int _maxTeamsPerArena = 30;

  static const _catColors = [
    Color(0xFF00CFFF),
    Color(0xFFFF9F43),
    Color(0xFF9B6FE8),
    Color(0xFF00E5A0),
    Color(0xFFFF6B6B),
    Color(0xFFFFD700),
    Color(0xFF48CAE4),
    Color(0xFFFF85A1),
  ];

  late AnimationController _soccerAnimCtrl;
  late Animation<double>   _soccerAnim;

  @override
  void initState() {
    super.initState();
    _soccerAnimCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _soccerAnim = CurvedAnimation(
        parent: _soccerAnimCtrl, curve: Curves.easeInOut);
    _loadCategories();
  }

  @override
  void dispose() {
    _soccerAnimCtrl.dispose();
    _soccerDurationCtrl.dispose();
    _soccerMatchBreakCtrl.dispose();
    for (final c in _durationPerCat.values) c.dispose();
    for (final c in _matchBreakPerCat.values) c.dispose();
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
        final id = int.tryParse(c['category_id'].toString()) ?? 0;
        _startTimePerCat[id]  = const TimeOfDay(hour: 8, minute: 0);
        _durationPerCat[id]   = TextEditingController(text: '6')
          ..addListener(() => setState(() {}));
        _matchBreakPerCat[id] = TextEditingController(text: '2')
          ..addListener(() => setState(() {}));
        _hbEnabled[id] = true;
        _hbStart[id]   = const TimeOfDay(hour: 12, minute: 0);
        _hbEnd[id]     = const TimeOfDay(hour: 13, minute: 0);
        _isGeneratingCat[id] = false;
        _generatedCat[id]    = false;
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
      if (mounted) _snack('Failed to load: $e', Colors.red);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  bool _isActive(Map<String, dynamic> c) =>
      (c['status'] ?? 'active').toString().toLowerCase() == 'active';

  String? _arenaWarning(int id) {
    final teams  = _teamCountPerCategory[id] ?? 0;
    final arenas = _arenasPerCategory[id]    ?? 1;
    if (teams == 0 || teams <= arenas * _maxTeamsPerArena) return null;
    return '$teams teams — needs ≥${(teams / _maxTeamsPerArena).ceil()} arenas';
  }

  void _snack(String msg, Color color) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));

  String _fmtTOD(TimeOfDay t) {
    final p = t.hour < 12 ? 'AM' : 'PM';
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    return '${h.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} $p';
  }

  int _hbDuration(TimeOfDay s, TimeOfDay e) =>
      ((e.hour * 60 + e.minute) - (s.hour * 60 + s.minute)).clamp(0, 1440);

  Future<TimeOfDay?> _pickTime(TimeOfDay init, Color accent) =>
      showTimePicker(
        context: context,
        initialTime: init,
        builder: (ctx, child) => Theme(
          data: Theme.of(ctx).copyWith(
            colorScheme: ColorScheme.dark(
                primary: accent, onPrimary: Colors.black,
                surface: const Color(0xFF2D0E7A), onSurface: Colors.white),
            timePickerTheme: TimePickerThemeData(
              dialHandColor: accent,
              dialBackgroundColor: const Color(0xFF1A0A4A),
              hourMinuteColor: Colors.white.withOpacity(0.1),
              hourMinuteTextColor: Colors.white),
          ),
          child: child!),
      );

  // ── Generate single category ───────────────────────────────────────────────
  Future<void> _generateForCategory(int id) async {
    final dur = int.tryParse(_durationPerCat[id]?.text.trim() ?? '') ?? 0;
    if (dur <= 0) { _snack('Duration must be > 0.', Colors.red); return; }
    final warn = _arenaWarning(id);
    if (warn != null) { _snack(warn, Colors.red); return; }

    final confirmed = await _showConfirmDialog();
    if (confirmed != true) return;

    setState(() => _isGeneratingCat[id] = true);
    try {
      final st       = _startTimePerCat[id] ?? const TimeOfDay(hour: 8, minute: 0);
      final interval = int.tryParse(_matchBreakPerCat[id]?.text.trim() ?? '0') ?? 0;
      final stStr    = '${st.hour.toString().padLeft(2, '0')}:${st.minute.toString().padLeft(2, '0')}';
      final enabled  = _hbEnabled[id] ?? false;
      final hbMins   = enabled
          ? _hbDuration(
              _hbStart[id] ?? const TimeOfDay(hour: 12, minute: 0),
              _hbEnd[id]   ?? const TimeOfDay(hour: 13, minute: 0))
          : 0;

      await DBHelper.generateSchedule(
        runsPerCategory:    {id: _runsPerCategory[id]   ?? 2},
        arenasPerCategory:  {id: _arenasPerCategory[id] ?? 1},
        startTime:          stStr,
        endTime:            '23:59',
        durationMinutes:    dur,
        intervalMinutes:    interval,
        healthBreakMinutes: hbMins,
        lunchBreak:         enabled,
      );

      setState(() => _generatedCat[id] = true);
      if (mounted) { _snack('✅ Schedule generated!', Colors.green); widget.onGenerated?.call(); }
    } catch (e) {
      if (mounted) _snack('Error: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isGeneratingCat[id] = false);
    }
  }

  // ── Generate Soccer bracket ────────────────────────────────────────────────
  Future<void> _generateBracket() async {
    final tc = _soccerTeams.length;
    if (tc < 4) { _snack('Need at least 4 Soccer teams (have $tc).', Colors.red); return; }

    final durVal = int.tryParse(_soccerDurationCtrl.text.trim()) ?? 10;
    if (durVal <= 0) { _snack('Soccer match duration must be > 0.', Colors.red); return; }

    final confirmed = await _showConfirmDialog();
    if (confirmed != true) return;

    final groups = <List<Map<String, dynamic>>>[];
    int idx = 0;
    while (idx < _soccerTeams.length) {
      final rem  = _soccerTeams.length - idx;
      final size = rem <= 4 ? rem : 4;
      groups.add(_soccerTeams.sublist(idx, idx + size));
      idx += size;
    }

    setState(() => _isGenBracket = true);
    try {
      final stStr    = '${_soccerStartTime.hour.toString().padLeft(2,'0')}:${_soccerStartTime.minute.toString().padLeft(2,'0')}';
      final interval = int.tryParse(_soccerMatchBreakCtrl.text.trim()) ?? 5;
      final hbMins   = _soccerHbEnabled
          ? _hbDuration(_soccerHbStart, _soccerHbEnd)
          : 0;

      await DBHelper.generateSoccerSchedule(
        groups:          groups,
        arenas:          1,
        categoryId:      _soccerCatId!,
        startTime:       stStr,
        endTime:         '23:59',
        durationMinutes: durVal,
        intervalMinutes: interval,
        lunchBreak:      _soccerHbEnabled,
      );

      setState(() { _bracketGenerated = true; _isGenBracket = false; });
      if (mounted) {
        _snack('Soccer bracket generated!', Colors.green);
        await Future.delayed(const Duration(milliseconds: 800));
        widget.onGenerated?.call();
      }
    } catch (e) {
      setState(() => _isGenBracket = false);
      if (mounted) _snack('Error: $e', Colors.red);
    }
  }

  // ── Confirm dialog ─────────────────────────────────────────────────────────
  Future<bool?> _showConfirmDialog() => showDialog<bool>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 360, padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xFF2D0E7A), Color(0xFF1E0A5A)]),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.orange.withOpacity(0.4), width: 1.5)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 54, height: 54,
            decoration: BoxDecoration(shape: BoxShape.circle,
                color: Colors.orange.withOpacity(0.15),
                border: Border.all(color: Colors.orange.withOpacity(0.4))),
            child: const Icon(Icons.warning_amber_rounded,
                color: Colors.orange, size: 28)),
          const SizedBox(height: 14),
          const Text('Regenerate Schedule?',
              style: TextStyle(color: Colors.white, fontSize: 17,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text('This will DELETE the existing schedule\nand generate a new one.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withOpacity(0.55),
                  fontSize: 13, height: 1.5)),
          const SizedBox(height: 22),
          Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.white.withOpacity(0.2)),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
              child: Text('CANCEL', style: TextStyle(
                  color: Colors.white.withOpacity(0.45),
                  fontWeight: FontWeight.bold)))),
            const SizedBox(width: 10),
            Expanded(child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
              child: Ink(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [Colors.orange, Color(0xFFCC4400)]),
                  borderRadius: BorderRadius.circular(10)),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 13),
                  child: Center(child: Text('REGENERATE',
                      style: TextStyle(color: Colors.white,
                          fontWeight: FontWeight.bold, letterSpacing: 1))))))),
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
      backgroundColor: _bg,
      body: Column(children: [
        const RegistrationHeader(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 36),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

              // ── Page title ───────────────────────────────────────────────
              Row(children: [
                IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new,
                        color: _accent, size: 18),
                    onPressed: widget.onBack),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _accent.withOpacity(0.1),
                      border: Border.all(color: _accent.withOpacity(0.3))),
                  child: const Icon(Icons.calendar_month_rounded,
                      color: _accent, size: 20)),
                const SizedBox(width: 12),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('GENERATE SCHEDULE',
                      style: TextStyle(color: Colors.white, fontSize: 20,
                          fontWeight: FontWeight.w900, letterSpacing: 2)),
                  Text('Configure & generate schedule per category independently',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.4), fontSize: 11)),
                ]),
              ]),

              const SizedBox(height: 28),

              // ── Category grid ─────────────────────────────────────────────
              if (_isLoadingData)
                const Center(child: Padding(
                    padding: EdgeInsets.all(60),
                    child: CircularProgressIndicator(color: _accent)))
              else if (_categories.isEmpty)
                _emptyBox()
              else
                _buildCategoryGrid(),

              // ── Soccer card (full width below grid) ───────────────────────
              if (_soccerCatId != null) ...[
                const SizedBox(height: 20),
                _buildSoccerCard(),
              ],

              const SizedBox(height: 36),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _emptyBox() => Container(
    padding: const EdgeInsets.all(36),
    decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12)),
    child: Center(child: Text('No categories found.',
        style: TextStyle(
            color: Colors.white.withOpacity(0.3), fontSize: 14))));

  // ══════════════════════════════════════════════════════════════════════════
  // 2-COLUMN GRID
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildCategoryGrid() {
    return LayoutBuilder(builder: (ctx, constraints) {
      // 2 columns if wide enough, else 1
      final cols      = constraints.maxWidth >= 700 ? 2 : 1;
      final spacing   = 18.0;
      final cardWidth = (constraints.maxWidth - spacing * (cols - 1)) / cols;

      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: _categories.asMap().entries.map((e) {
          final color = _catColors[e.key % _catColors.length];
          return SizedBox(
            width: cardWidth,
            child: _buildCategoryCard(e.value, color),
          );
        }).toList(),
      );
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CATEGORY CARD
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildCategoryCard(Map<String, dynamic> cat, Color accent) {
    final id     = int.tryParse(cat['category_id'].toString()) ?? 0;
    final name   = (cat['category_type'] ?? '').toString();
    final active = _isActive(cat);
    final count  = _teamCountPerCategory[id] ?? 0;
    final warn   = _arenaWarning(id);
    final isGen  = _isGeneratingCat[id] ?? false;
    final isDone = _generatedCat[id]    ?? false;

    final catIdx = _categories.indexWhere(
        (c) => int.tryParse(c['category_id'].toString()) == id);
    final letter = catIdx >= 0 && catIdx < 26
        ? String.fromCharCode(65 + catIdx) : '?';

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: active
                ? [accent.withOpacity(0.14), const Color(0xFF110730)]
                : [Colors.white.withOpacity(0.04), const Color(0xFF0D0625)]),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: !active
              ? Colors.white.withOpacity(0.08)
              : isDone
                  ? const Color(0xFF00E5A0).withOpacity(0.55)
                  : accent.withOpacity(0.45),
          width: 1.5),
        boxShadow: active
            ? [BoxShadow(color: accent.withOpacity(0.1),
                blurRadius: 28, spreadRadius: 2)]
            : [],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── Header ──────────────────────────────────────────────────────
          Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active
                    ? accent.withOpacity(0.18)
                    : Colors.white.withOpacity(0.06),
                border: Border.all(
                    color: active ? accent.withOpacity(0.7) : Colors.white24,
                    width: 2.5)),
              child: Center(child: Text(letter,
                  style: TextStyle(
                    color: active ? accent : Colors.white38,
                    fontWeight: FontWeight.w900, fontSize: 15)))),
            const SizedBox(width: 12),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name.toUpperCase(),
                  style: TextStyle(
                    color: active ? Colors.white : Colors.white38,
                    fontWeight: FontWeight.w800,
                    fontSize: 14, letterSpacing: 0.8)),
              Text(active
                  ? '$count team${count != 1 ? 's' : ''} registered'
                  : 'Inactive — locked',
                  style: TextStyle(
                    color: active
                        ? Colors.white.withOpacity(0.4)
                        : Colors.white24,
                    fontSize: 11)),
            ])),
            // Team badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: active
                    ? accent.withOpacity(0.12)
                    : Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: active
                        ? accent.withOpacity(0.55)
                        : Colors.white12,
                    width: 1.5)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.groups_rounded,
                    color: active ? accent : Colors.white24, size: 16),
                const SizedBox(width: 6),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('$count',
                      style: TextStyle(
                        color: active ? accent : Colors.white24,
                        fontSize: 18,
                        fontWeight: FontWeight.w900, height: 1.0)),
                  Text('Teams',
                      style: TextStyle(
                        color: (active ? accent : Colors.white24)
                            .withOpacity(0.65),
                        fontSize: 9, fontWeight: FontWeight.bold)),
                ]),
              ]),
            ),
          ]),

          // ── Inactive notice ──────────────────────────────────────────────
          if (!active) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.07),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.withOpacity(0.2))),
              child: Row(children: [
                const Icon(Icons.lock_outline_rounded,
                    size: 14, color: Colors.white38),
                const SizedBox(width: 10),
                Expanded(child: Text(
                    'This category is inactive. Activate it in the Category Manager to configure and generate a schedule.',
                    style: TextStyle(color: Colors.white38, fontSize: 11,
                        fontStyle: FontStyle.italic, height: 1.4))),
              ]),
            ),
          ],

          // ── Active body ──────────────────────────────────────────────────
          if (active) ...[
            const SizedBox(height: 18),
            _hDivider(accent),
            const SizedBox(height: 18),

            // Row 1: Start Time | Runs | Arenas
            _buildRow1(id, accent),
            const SizedBox(height: 12),

            // Row 2: Duration | Match Break
            _buildRow2(id, accent),
            const SizedBox(height: 16),

            // Health break
            _buildHealthBreak(
              enabled: _hbEnabled[id] ?? true,
              hbStart: _hbStart[id]   ?? const TimeOfDay(hour: 12, minute: 0),
              hbEnd:   _hbEnd[id]     ?? const TimeOfDay(hour: 13, minute: 0),
              accent:  accent,
              onToggle: (v) => setState(() => _hbEnabled[id] = v),
              onPickStart: () async {
                final p = await _pickTime(
                    _hbStart[id] ?? const TimeOfDay(hour: 12, minute: 0),
                    accent);
                if (p != null) setState(() => _hbStart[id] = p);
              },
              onPickEnd: () async {
                final p = await _pickTime(
                    _hbEnd[id] ?? const TimeOfDay(hour: 13, minute: 0),
                    accent);
                if (p != null) setState(() => _hbEnd[id] = p);
              },
            ),

            // Capacity info
            if (warn != null) ...[
              const SizedBox(height: 12),
              _infoRow(icon: Icons.warning_amber_rounded,
                  color: Colors.orange, text: warn),
            ] else if (count > 0) ...[
              const SizedBox(height: 12),
              _infoRow(
                icon: Icons.check_circle_outline_rounded,
                color: const Color(0xFF00E5A0),
                text: 'Capacity OK — '
                    '${(_arenasPerCategory[id] ?? 1) * _maxTeamsPerArena} slots '
                    '(${_arenasPerCategory[id] ?? 1} × $_maxTeamsPerArena)',
              ),
            ],

            const SizedBox(height: 18),
            _hDivider(accent),
            const SizedBox(height: 16),

            // Generate button
            _buildGenerateBtn(
              label:  isDone ? 'REGENERATE SCHEDULE' : 'GENERATE SCHEDULE',
              icon:   isDone ? Icons.refresh_rounded : Icons.auto_awesome_rounded,
              color:  accent,
              isLoading: isGen,
              onTap:  () => _generateForCategory(id),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _buildRow1(int id, Color accent) {
    final startT = _startTimePerCat[id] ?? const TimeOfDay(hour: 8, minute: 0);
    final runs   = _runsPerCategory[id]   ?? 2;
    final arenas = _arenasPerCategory[id] ?? 1;

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Start time
      Expanded(flex: 5, child: _tile(
        label: 'START TIME', icon: Icons.access_time_rounded, color: accent,
        child: _timePill(time: startT, color: accent,
            onTap: () async {
              final p = await _pickTime(startT, accent);
              if (p != null) setState(() => _startTimePerCat[id] = p);
            }),
      )),
      const SizedBox(width: 10),
      // Runs
      Expanded(flex: 3, child: _tile(
        label: 'RUNS / TEAM', icon: Icons.repeat_rounded,
        color: const Color(0xFF9B6FE8),
        child: _spinnerWidget(
          value: runs, color: const Color(0xFF9B6FE8),
          onDec: runs > 1
              ? () => setState(() => _runsPerCategory[id] = runs - 1) : null,
          onInc: runs < 99
              ? () => setState(() => _runsPerCategory[id] = runs + 1) : null,
        ),
      )),
      const SizedBox(width: 10),
      // Arenas
      Expanded(flex: 3, child: _tile(
        label: 'ARENAS', icon: Icons.place_rounded,
        color: const Color(0xFFFFD700),
        sublabel: 'max $_maxTeamsPerArena ea.',
        child: _spinnerWidget(
          value: arenas, color: const Color(0xFFFFD700),
          onDec: arenas > 1
              ? () => setState(() => _arenasPerCategory[id] = arenas - 1) : null,
          onInc: arenas < 10
              ? () => setState(() => _arenasPerCategory[id] = arenas + 1) : null,
        ),
      )),
    ]);
  }

  Widget _buildRow2(int id, Color accent) => Row(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
    Expanded(child: _tile(
      label: 'MATCH DURATION', icon: Icons.timer_rounded, color: accent,
      child: _numField(
          controller: _durationPerCat[id]!, color: accent, suffix: 'min'),
    )),
    const SizedBox(width: 10),
    Expanded(child: _tile(
      label: 'MATCH BREAK', icon: Icons.pause_circle_outline_rounded,
      color: Colors.orange.shade300,
      sublabel: 'optional',
      child: _numField(
          controller: _matchBreakPerCat[id]!,
          color: Colors.orange.shade300, suffix: 'min'),
    )),
  ]);

  // ══════════════════════════════════════════════════════════════════════════
  // SOCCER CARD  (full width, has own timing — no runs spinner)
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildSoccerCard() {
    final tc          = _soccerTeams.length;
    final canGenerate = tc >= 4;
    const accent      = _soccerAccent;

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF251040), Color(0xFF110720)]),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withOpacity(0.45), width: 1.5),
        boxShadow: [BoxShadow(color: accent.withOpacity(0.09),
            blurRadius: 30, spreadRadius: 2)]),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── Header ────────────────────────────────────────────────────────
          Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: accent.withOpacity(0.14),
                  border: Border.all(color: accent.withOpacity(0.5))),
              child: const Icon(Icons.sports_soccer,
                  color: accent, size: 22)),
            const SizedBox(width: 14),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('MBOT SOCCER — BRACKET',
                  style: TextStyle(color: Colors.white, fontSize: 15,
                      fontWeight: FontWeight.w800, letterSpacing: 1.2)),
              Text('Group Stage → Play-In → Double Elim → Grand Final',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.4), fontSize: 11)),
            ])),
            const SizedBox(width: 12),
            // Teams badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: canGenerate
                    ? _accent.withOpacity(0.12)
                    : Colors.redAccent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: canGenerate
                      ? _accent.withOpacity(0.65)
                      : Colors.redAccent.withOpacity(0.65),
                  width: 2)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.groups,
                    color: canGenerate ? _accent : Colors.redAccent, size: 18),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('$tc', style: TextStyle(
                      color: canGenerate ? _accent : Colors.redAccent,
                      fontSize: 20, fontWeight: FontWeight.w900, height: 1.0)),
                  Text('Teams Registered', style: TextStyle(
                      color: (canGenerate ? _accent : Colors.redAccent)
                          .withOpacity(0.7),
                      fontSize: 9, fontWeight: FontWeight.bold)),
                ]),
              ]),
            ),
          ]),

          const SizedBox(height: 18),
          Container(height: 1,
              color: accent.withOpacity(0.2)),
          const SizedBox(height: 16),

          // ── Bracket flow ──────────────────────────────────────────────────
          _buildBracketFlow(),
          const SizedBox(height: 18),
          _hDivider(accent),
          const SizedBox(height: 18),

          // ── Soccer schedule settings ─────────────────────────────────────
          // Row 1: Start Time | Match Duration | Match Break
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 4, child: _tile(
              label: 'START TIME', icon: Icons.access_time_rounded,
              color: accent,
              child: _timePill(
                time: _soccerStartTime, color: accent,
                onTap: () async {
                  final p = await _pickTime(_soccerStartTime, accent);
                  if (p != null) setState(() => _soccerStartTime = p);
                }),
            )),
            const SizedBox(width: 10),
            Expanded(flex: 3, child: _tile(
              label: 'MATCH DURATION', icon: Icons.timer_rounded,
              color: accent,
              child: _numField(
                  controller: _soccerDurationCtrl,
                  color: accent, suffix: 'min'),
            )),
            const SizedBox(width: 10),
            Expanded(flex: 3, child: _tile(
              label: 'MATCH BREAK', icon: Icons.pause_circle_outline_rounded,
              color: Colors.orange.shade300,
              sublabel: 'optional',
              child: _numField(
                  controller: _soccerMatchBreakCtrl,
                  color: Colors.orange.shade300, suffix: 'min'),
            )),
          ]),
          const SizedBox(height: 14),

          // Health break for soccer
          _buildHealthBreak(
            enabled:  _soccerHbEnabled,
            hbStart:  _soccerHbStart,
            hbEnd:    _soccerHbEnd,
            accent:   accent,
            onToggle: (v) => setState(() => _soccerHbEnabled = v),
            onPickStart: () async {
              final p = await _pickTime(_soccerHbStart, accent);
              if (p != null) setState(() => _soccerHbStart = p);
            },
            onPickEnd: () async {
              final p = await _pickTime(_soccerHbEnd, accent);
              if (p != null) setState(() => _soccerHbEnd = p);
            },
          ),

          if (!canGenerate) ...[
            const SizedBox(height: 12),
            _infoRow(icon: Icons.error_outline_rounded,
                color: Colors.redAccent,
                text: 'Need at least 4 teams — ${4 - tc} more required.'),
          ] else if (_bracketGenerated) ...[
            const SizedBox(height: 12),
            _infoRow(icon: Icons.check_circle_outline_rounded,
                color: Colors.green,
                text: 'Bracket generated! Go to the Soccer tab to manage groups.'),
          ],

          const SizedBox(height: 16),

          // ── View teams toggle ─────────────────────────────────────────────
          GestureDetector(
            onTap: () {
              setState(() => _showSoccerTeams = !_showSoccerTeams);
              _showSoccerTeams
                  ? _soccerAnimCtrl.forward()
                  : _soccerAnimCtrl.reverse();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12)),
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
                        color: Colors.white38, size: 20)),
              ]),
            ),
          ),

          SizeTransition(
            sizeFactor: _soccerAnim,
            child: Column(children: [
              const SizedBox(height: 10),
              _buildTeamTable(),
            ]),
          ),

          const SizedBox(height: 20),

          // ── Generate bracket button ───────────────────────────────────────
          _buildGenerateBtn(
            label:     _bracketGenerated ? 'REGENERATE BRACKET' : 'GENERATE BRACKET',
            icon:      _bracketGenerated ? Icons.refresh_rounded : Icons.account_tree_rounded,
            color:     canGenerate ? accent : Colors.white24,
            isLoading: _isGenBracket,
            onTap:     canGenerate ? _generateBracket : null,
            disabled:  !canGenerate,
          ),
        ]),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SHARED WIDGETS
  // ══════════════════════════════════════════════════════════════════════════

  // Health break row (reused by both category cards and soccer card)
  Widget _buildHealthBreak({
    required bool enabled,
    required TimeOfDay hbStart,
    required TimeOfDay hbEnd,
    required Color accent,
    required ValueChanged<bool> onToggle,
    required VoidCallback onPickStart,
    required VoidCallback onPickEnd,
  }) {
    const hbColor   = Color(0xFF00E5A0);
    final durationM = _hbDuration(hbStart, hbEnd);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: enabled
            ? hbColor.withOpacity(0.06)
            : Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: enabled ? hbColor.withOpacity(0.35) : Colors.white12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // Toggle header
        Row(children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: enabled
                  ? hbColor.withOpacity(0.15)
                  : Colors.white.withOpacity(0.05)),
            child: Icon(Icons.favorite_rounded, size: 14,
                color: enabled ? hbColor : Colors.white38)),
          const SizedBox(width: 11),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('HEALTH BREAK',
                style: TextStyle(
                  color: enabled ? hbColor : Colors.white38,
                  fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.8)),
            Text(enabled
                ? '${_fmtTOD(hbStart)} – ${_fmtTOD(hbEnd)}  •  ${durationM}min  •  No matches during this window'
                : 'Disabled — matches run continuously',
                style: TextStyle(
                  color: enabled ? Colors.white38 : Colors.white24,
                  fontSize: 10, height: 1.4)),
          ])),
          Switch(
            value: enabled,
            onChanged: onToggle,
            activeColor: hbColor,
            inactiveThumbColor: Colors.white24,
            inactiveTrackColor: Colors.white12,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ]),

        // Start / End time pickers
        if (enabled) ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('BREAK STARTS',
                  style: TextStyle(color: hbColor.withOpacity(0.7),
                      fontSize: 9, fontWeight: FontWeight.bold,
                      letterSpacing: 0.8)),
              const SizedBox(height: 5),
              GestureDetector(onTap: onPickStart,
                  child: _timePill(time: hbStart, color: hbColor)),
            ])),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Column(children: [
                const SizedBox(height: 14),
                Icon(Icons.arrow_forward_rounded,
                    color: hbColor.withOpacity(0.4), size: 16),
              ])),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('BREAK ENDS',
                  style: TextStyle(color: hbColor.withOpacity(0.7),
                      fontSize: 9, fontWeight: FontWeight.bold,
                      letterSpacing: 0.8)),
              const SizedBox(height: 5),
              GestureDetector(onTap: onPickEnd,
                  child: _timePill(time: hbEnd, color: hbColor)),
            ])),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: hbColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: hbColor.withOpacity(0.3))),
              child: Column(children: [
                Text('$durationM',
                    style: TextStyle(color: hbColor, fontSize: 18,
                        fontWeight: FontWeight.w900, height: 1.0)),
                Text('min', style: TextStyle(
                    color: hbColor.withOpacity(0.6), fontSize: 9,
                    fontWeight: FontWeight.bold)),
              ]),
            ),
          ]),
          if (durationM <= 0) ...[
            const SizedBox(height: 8),
            _infoRow(icon: Icons.error_outline_rounded,
                color: Colors.orange,
                text: 'Break end must be after break start.'),
          ],
        ],
      ]),
    );
  }

  Widget _tile({
    required String label,
    required IconData icon,
    required Color color,
    required Widget child,
    String? sublabel,
  }) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 10, color: color.withOpacity(0.75)),
          const SizedBox(width: 4),
          Flexible(child: Text(label, style: TextStyle(
              color: color.withOpacity(0.85), fontSize: 9,
              fontWeight: FontWeight.bold, letterSpacing: 0.8))),
        ]),
        if (sublabel != null) ...[
          const SizedBox(height: 1),
          Text(sublabel, style: TextStyle(
              color: Colors.white.withOpacity(0.28), fontSize: 8,
              fontStyle: FontStyle.italic)),
        ],
        const SizedBox(height: 6),
        child,
      ]);

  Widget _timePill({
    required TimeOfDay time,
    required Color color,
    VoidCallback? onTap,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.3))),
          child: Row(children: [
            Icon(Icons.access_time_rounded, size: 13, color: color),
            const SizedBox(width: 7),
            Expanded(child: Text(_fmtTOD(time),
                style: TextStyle(color: color, fontSize: 14,
                    fontWeight: FontWeight.bold))),
            if (onTap != null)
              Icon(Icons.edit_rounded, size: 11,
                  color: color.withOpacity(0.45)),
          ]),
        ),
      );

  Widget _spinnerWidget({
    required int value,
    required Color color,
    required VoidCallback? onDec,
    required VoidCallback? onInc,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.25))),
        child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
          _spinBtn(icon: Icons.remove, color: color, onTap: onDec),
          Text('$value', style: TextStyle(color: color, fontSize: 20,
              fontWeight: FontWeight.w900)),
          _spinBtn(icon: Icons.add, color: color, onTap: onInc),
        ]),
      );

  Widget _spinBtn({required IconData icon, required Color color,
      required VoidCallback? onTap}) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 28, height: 28,
          decoration: BoxDecoration(shape: BoxShape.circle,
            color: onTap != null
                ? color.withOpacity(0.14)
                : Colors.white.withOpacity(0.03),
            border: Border.all(
                color: onTap != null
                    ? color.withOpacity(0.5) : Colors.white12)),
          child: Icon(icon, size: 13,
              color: onTap != null ? color : Colors.white12)));

  Widget _numField({
    required TextEditingController controller,
    required Color color,
    required String suffix,
  }) =>
      Container(
        decoration: BoxDecoration(
          color: color.withOpacity(0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.25))),
        child: Row(children: [
          Expanded(child: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: TextStyle(color: color, fontSize: 18,
                fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 10),
              border: InputBorder.none,
              hintText: '0',
              hintStyle: TextStyle(color: color.withOpacity(0.3))),
          )),
          Padding(padding: const EdgeInsets.only(right: 10),
              child: Text(suffix, style: TextStyle(
                  color: color.withOpacity(0.5), fontSize: 11,
                  fontWeight: FontWeight.bold))),
        ]),
      );

  Widget _buildGenerateBtn({
    required String label,
    required IconData icon,
    required Color color,
    required bool isLoading,
    required VoidCallback? onTap,
    bool disabled = false,
  }) =>
      SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: isLoading || disabled ? null : onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(13))),
          child: Ink(
            decoration: BoxDecoration(
              gradient: (!isLoading && !disabled)
                  ? LinearGradient(colors: [
                      color, Color.lerp(color, Colors.black, 0.28)!,
                    ])
                  : null,
              color: (isLoading || disabled)
                  ? Colors.white.withOpacity(0.05) : null,
              borderRadius: BorderRadius.circular(13),
              border: (isLoading || disabled)
                  ? Border.all(color: Colors.white12) : null,
              boxShadow: (!isLoading && !disabled)
                  ? [BoxShadow(color: color.withOpacity(0.38),
                      blurRadius: 18, spreadRadius: 1)]
                  : []),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              alignment: Alignment.center,
              child: isLoading
                  ? SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: color))
                  : Row(mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon,
                            color: disabled
                                ? Colors.white24 : Colors.white, size: 18),
                        const SizedBox(width: 10),
                        Text(label,
                            style: TextStyle(
                              color: disabled ? Colors.white24 : Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13, letterSpacing: 1.8)),
                      ]),
            ),
          ),
        ),
      );

  Widget _hDivider(Color color) => Container(
    height: 1,
    decoration: BoxDecoration(gradient: LinearGradient(colors: [
      Colors.transparent, color.withOpacity(0.25), Colors.transparent,
    ])));

  Widget _infoRow({required IconData icon, required Color color,
      required String text}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: color.withOpacity(0.07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.25))),
        child: Row(children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text,
              style: TextStyle(fontSize: 11, color: color, height: 1.4))),
        ]));

  // ── Bracket flow steps ──────────────────────────────────────────────────────
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
        border: Border.all(color: Colors.white.withOpacity(0.07))),
      child: Row(children: steps.asMap().entries.expand((e) {
        final idx = e.key; final step = e.value;
        return [
          Expanded(child: Column(children: [
            Container(width: 38, height: 38,
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: step.$3.withOpacity(0.12),
                  border: Border.all(
                      color: step.$3.withOpacity(0.5), width: 1.5)),
              child: Icon(step.$1, color: step.$3, size: 16)),
            const SizedBox(height: 5),
            Text(step.$2, textAlign: TextAlign.center,
                style: TextStyle(color: step.$3, fontSize: 9,
                    fontWeight: FontWeight.bold, height: 1.3)),
          ])),
          if (idx < steps.length - 1)
            Padding(padding: const EdgeInsets.only(bottom: 14),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 10, height: 1.5,
                      color: Colors.white.withOpacity(0.1)),
                  Icon(Icons.chevron_right,
                      color: Colors.white.withOpacity(0.15), size: 13),
                ])),
        ];
      }).toList()),
    );
  }

  // ── Team table (inside soccer card) ────────────────────────────────────────
  Widget _buildTeamTable() => Container(
    decoration: BoxDecoration(
        color: const Color(0xFF0A0620),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.06))),
    child: Column(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: const BoxDecoration(
            gradient: LinearGradient(
                colors: [Color(0xFF2D0E7A), Color(0xFF1A0850)]),
            borderRadius: BorderRadius.vertical(top: Radius.circular(11))),
        child: Row(children: [
          _th('#', flex: 1), _th('ID', flex: 2), _th('TEAM NAME', flex: 5),
        ]),
      ),
      if (_soccerTeams.isEmpty)
        const Padding(padding: EdgeInsets.all(24),
            child: Text('No teams registered yet.',
                style: TextStyle(color: Colors.white24, fontSize: 14)))
      else
        ..._soccerTeams.asMap().entries.map((e) {
          final idx    = e.key; final team = e.value;
          final rawId  = team['team_id']?.toString() ?? '';
          final n      = int.tryParse(rawId);
          final dispId = n != null
              ? 'C${n.toString().padLeft(3, '0')}R' : rawId;
          return Container(
            decoration: BoxDecoration(
              color: idx % 2 == 0
                  ? const Color(0xFF0D0830) : const Color(0xFF090620),
              border: const Border(
                  bottom: BorderSide(color: Color(0xFF1A1050), width: 1))),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(children: [
              Expanded(flex: 1, child: Text('${idx + 1}',
                  style: TextStyle(color: Colors.white.withOpacity(0.3),
                      fontSize: 13, fontWeight: FontWeight.bold))),
              Expanded(flex: 2, child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: _accent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: _accent.withOpacity(0.4))),
                child: Text(dispId, style: const TextStyle(
                    color: _accent, fontSize: 11,
                    fontWeight: FontWeight.bold, letterSpacing: 1)))),
              Expanded(flex: 5, child: Text(
                  team['team_name']?.toString() ?? '',
                  style: const TextStyle(color: Colors.white,
                      fontSize: 14, fontWeight: FontWeight.w600))),
            ]),
          );
        }),
    ]),
  );

  Widget _th(String text, {int flex = 1}) => Expanded(
      flex: flex,
      child: Text(text, style: const TextStyle(color: Colors.white54,
          fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1)));
}