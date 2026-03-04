import 'package:flutter/material.dart';
import 'db_helper.dart';

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

class _GenerateScheduleState extends State<GenerateSchedule> {
  // category_id → runs per team
  final Map<int, int> _runsPerCategory = {};
  // category_id → number of arenas
  final Map<int, int> _arenasPerCategory = {};
  // category_id → actual team count (loaded from DB)
  final Map<int, int> _teamCountPerCategory = {};

  List<Map<String, dynamic>> _categories = [];
  bool _isLoadingData = true;

  // Schedule settings — using TimeOfDay for clock pickers
  TimeOfDay _startTime = const TimeOfDay(hour: 9,  minute: 0);
  TimeOfDay _endTime   = const TimeOfDay(hour: 17, minute: 0);
  final _durationController = TextEditingController(text: '6');
  final _intervalController = TextEditingController(text: '0');

  bool _lunchBreakEnabled = true;
  bool _isGenerating      = false;

  static const int _maxTeamsPerArena = 15;

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _loadCategories();
    // Rebuild timing preview whenever duration or break changes
    _durationController.addListener(() => setState(() {}));
    _intervalController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _durationController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    try {
      final cats = await DBHelper.getCategories();

      // Deduplicate
      final seen = <int>{};
      final unique = cats.where((c) {
        final id = int.tryParse(c['category_id'].toString()) ?? 0;
        return id > 0 && seen.add(id);
      }).toList();

      // Load team counts per category
      final Map<int, int> teamCounts = {};
      for (final c in unique) {
        final id    = int.tryParse(c['category_id'].toString()) ?? 0;
        final teams = await DBHelper.getTeamsByCategory(id);
        teamCounts[id] = teams.length;
      }

      setState(() {
        _categories = unique;
        for (final c in unique) {
          final id    = int.tryParse(c['category_id'].toString()) ?? 0;
          final count = teamCounts[id] ?? 0;
          _runsPerCategory[id]    = 2;
          // Auto-calculate minimum arenas needed: ceil(count / 15)
          _arenasPerCategory[id]  =
              count == 0 ? 1 : (count / _maxTeamsPerArena).ceil();
          _teamCountPerCategory[id] = count;
        }
        _isLoadingData = false;
      });
    } catch (e) {
      setState(() => _isLoadingData = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Failed to load categories: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ── Validation ────────────────────────────────────────────────────────────
  // Returns error message if arenas are insufficient, null if ok
  String? _arenaWarning(int categoryId) {
    final teams  = _teamCountPerCategory[categoryId] ?? 0;
    final arenas = _arenasPerCategory[categoryId]    ?? 1;
    if (teams == 0) return null;
    final capacity = arenas * _maxTeamsPerArena;
    if (teams > capacity) {
      return '$teams teams, needs ≥${(teams / _maxTeamsPerArena).ceil()} arenas';
    }
    return null;
  }

  bool get _hasArenaError {
    for (final cat in _categories) {
      final id = int.tryParse(cat['category_id'].toString()) ?? 0;
      if (_arenaWarning(id) != null) return true;
    }
    return false;
  }

  // ── Generate ──────────────────────────────────────────────────────────────
  Future<void> _generateSchedule() async {
    final duration = int.tryParse(_durationController.text.trim()) ?? 6;
    final interval = int.tryParse(_intervalController.text.trim()) ?? 0;

    if (duration <= 0) {
      _snack('❌ Duration must be greater than 0.', Colors.red);
      return;
    }

    // Validate end time is after start time
    final startMinutes = _startTime.hour * 60 + _startTime.minute;
    final endMinutes   = _endTime.hour   * 60 + _endTime.minute;
    if (endMinutes <= startMinutes) {
      _snack('❌ End time must be after start time.', Colors.red);
      return;
    }

    if (_hasArenaError) {
      _snack('❌ Some categories have more teams than arena capacity. Increase arenas.', Colors.red);
      return;
    }

    // ── Confirm overwrite ───────────────────────────────────────────────────
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 26),
            SizedBox(width: 10),
            Text('Regenerate Schedule?',
                style: TextStyle(
                    color: Color(0xFF3D1A8C),
                    fontWeight: FontWeight.bold,
                    fontSize: 18)),
          ],
        ),
        content: const Text(
          'This will DELETE the existing schedule and generate a new one.\n\nAre you sure?',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('CANCEL',
                style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00CFFF),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('REGENERATE',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isGenerating = true);
    try {
      final startTime =
          '${_startTime.hour.toString().padLeft(2, '0')}:${_startTime.minute.toString().padLeft(2, '0')}';
      final endTime =
          '${_endTime.hour.toString().padLeft(2, '0')}:${_endTime.minute.toString().padLeft(2, '0')}';

      await DBHelper.generateSchedule(
        runsPerCategory:   _runsPerCategory,
        arenasPerCategory: _arenasPerCategory,
        startTime:         startTime,
        endTime:           endTime,
        durationMinutes:   duration,
        intervalMinutes:   interval,
        lunchBreak:        _lunchBreakEnabled,
      );

      if (mounted) {
        _snack('✅ Schedule generated successfully!', Colors.green);
        widget.onGenerated?.call();
      }
    } catch (e) {
      if (mounted) _snack('❌ Error: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFDDDDDD),
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Container(
                  width: 780,
                  padding: const EdgeInsets.fromLTRB(40, 32, 40, 36),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: const Color(0xFF3D1A8C), width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.15),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Title
                          const Text(
                            'RoboVenture',
                            style: TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF3D1A8C),
                              letterSpacing: 2,
                            ),
                          ),
                          const SizedBox(height: 28),

                          // Two-column layout
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // LEFT — runs + arenas per category
                              Expanded(child: _buildRunsColumn()),
                              const SizedBox(width: 32),
                              // RIGHT — schedule settings
                              _buildScheduleColumn(),
                            ],
                          ),
                          const SizedBox(height: 32),

                          // Generate button
                          ElevatedButton(
                            onPressed: _isGenerating ? null : _generateSchedule,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00CFFF),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 48, vertical: 16),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                            child: _isGenerating
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white),
                                  )
                                : const Text(
                                    'GENERATE SCHEDULE',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                      letterSpacing: 1.5,
                                    ),
                                  ),
                          ),
                        ],
                      ),

                      // Back button
                      Positioned(
                        top: 0,
                        left: 0,
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back_ios_new,
                              color: Color(0xFF3D1A8C)),
                          tooltip: 'Back',
                          onPressed: widget.onBack,
                        ),
                      ),

                      // Close button
                      Positioned(
                        top: 0,
                        right: 0,
                        child: IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () =>
                              Navigator.of(context).maybePop(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── LEFT: Runs + Arenas per category ──────────────────────────────────────
  Widget _buildRunsColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header row
        Row(
          children: [
            const Expanded(
              child: Text(
                'CATEGORY',
                style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                    color: Color(0xFF3D1A8C),
                    letterSpacing: 0.5),
              ),
            ),
            SizedBox(
              width: 90,
              child: Center(
                child: const Text(
                  'RUNS',
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                      color: Color(0xFF3D1A8C),
                      letterSpacing: 0.5),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 90,
              child: Center(
                child: const Text(
                  'ARENAS',
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                      color: Color(0xFF3D1A8C),
                      letterSpacing: 0.5),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Max per arena label
        Row(
          children: [
            const Spacer(),
            SizedBox(
              width: 90,
              child: Center(),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 90,
              child: Center(
                child: Text(
                  'max $_maxTeamsPerArena teams',
                  style: const TextStyle(
                      fontSize: 9,
                      color: Colors.black38,
                      fontStyle: FontStyle.italic),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Category rows
        _isLoadingData
            ? const Center(
                child: CircularProgressIndicator(strokeWidth: 2))
            : Column(
                children: _categories.map((c) {
                  final id    = int.tryParse(c['category_id'].toString()) ?? 0;
                  final name  = (c['category_type'] ?? '').toString();
                  final count = _teamCountPerCategory[id] ?? 0;
                  final warning = _arenaWarning(id);

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            // Category name + team count
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name.toUpperCase(),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    '$count team${count != 1 ? 's' : ''} registered',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: count == 0
                                          ? Colors.orange
                                          : Colors.black45,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Runs spinner
                            SizedBox(
                              width: 90,
                              child: Center(child: _buildSpinner(id, isRuns: true)),
                            ),
                            const SizedBox(width: 8),
                            // Arenas spinner
                            SizedBox(
                              width: 90,
                              child: Center(
                                  child: _buildSpinner(id, isRuns: false)),
                            ),
                          ],
                        ),
                        // Warning
                        if (warning != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                const Icon(Icons.warning_amber_rounded,
                                    size: 12, color: Colors.orange),
                                const SizedBox(width: 4),
                                Text(
                                  warning,
                                  style: const TextStyle(
                                      fontSize: 10, color: Colors.orange),
                                ),
                              ],
                            ),
                          ),
                        // Capacity info
                        if (warning == null && count > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                const Icon(Icons.check_circle_outline,
                                    size: 12, color: Colors.green),
                                const SizedBox(width: 4),
                                Text(
                                  'Capacity: ${(_arenasPerCategory[id] ?? 1) * _maxTeamsPerArena} teams '
                                  '(${_arenasPerCategory[id] ?? 1} × $_maxTeamsPerArena)',
                                  style: const TextStyle(
                                      fontSize: 10, color: Colors.green),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  );
                }).toList(),
              ),
      ],
    );
  }

  // ── Time picker helper ────────────────────────────────────────────────────
  Future<void> _pickTime(bool isStart) async {
    final initial = isStart ? _startTime : _endTime;
    final picked  = await showTimePicker(
      context: context,
      initialTime: initial,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary:   Color(0xFF3D1A8C),
              onPrimary: Colors.white,
              surface:   Colors.white,
              onSurface: Color(0xFF3D1A8C),
            ),
            timePickerTheme: const TimePickerThemeData(
              dialHandColor:       Color(0xFF3D1A8C),
              dialBackgroundColor: Color(0xFFF0EAFF),
              hourMinuteColor:     Color(0xFFEDE7FF),
              hourMinuteTextColor: Color(0xFF3D1A8C),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        if (isStart) _startTime = picked;
        else         _endTime   = picked;
      });
    }
  }

  String _fmtTime(TimeOfDay t) {
    final h  = t.hour.toString().padLeft(2, '0');
    final m  = t.minute.toString().padLeft(2, '0');
    final period = t.hour < 12 ? 'AM' : 'PM';
    final h12 = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    return '${h12.toString().padLeft(2, '0')}:$m $period';
  }

  Widget _timeTile({
    required String label,
    required TimeOfDay time,
    required bool isStart,
  }) {
    return GestureDetector(
      onTap: () => _pickTime(isStart),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF0EAFF),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF3D1A8C).withOpacity(0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.access_time_rounded,
                size: 16, color: Color(0xFF3D1A8C)),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 9,
                        color: Colors.black45,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5)),
                Text(_fmtTime(time),
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF3D1A8C))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Timing preview ────────────────────────────────────────────────────────
  Widget _buildTimingPreview() {
    final duration = int.tryParse(_durationController.text.trim()) ?? 0;
    final breakMins = int.tryParse(_intervalController.text.trim()) ?? 0;
    if (duration <= 0) return const SizedBox.shrink();

    // Compute match 1 and match 2 start/end using start time
    int h = _startTime.hour;
    int m = _startTime.minute;

    String fmt(int hour, int min) {
      min = min % 60;
      hour = hour + (min < 0 ? -1 : 0);
      final period = hour < 12 ? 'AM' : 'PM';
      final h12 = hour % 12 == 0 ? 12 : hour % 12;
      return '${h12.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')} $period';
    }

    final m1Start = fmt(h, m);
    int em = m + duration;
    int eh = h + em ~/ 60; em = em % 60;
    final m1End = fmt(eh, em);

    // Break
    int bm = em + breakMins;
    int bh = eh + bm ~/ 60; bm = bm % 60;
    final m2Start = fmt(bh, bm);
    int em2 = bm + duration;
    int eh2 = bh + em2 ~/ 60; em2 = em2 % 60;
    final m2End = fmt(eh2, em2);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF3D1A8C).withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: const Color(0xFF3D1A8C).withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('EXAMPLE TIMING:',
              style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF3D1A8C),
                  letterSpacing: 0.5)),
          const SizedBox(height: 6),
          _previewRow('Match 1', m1Start, m1End,
              const Color(0xFF3D1A8C)),
          if (breakMins > 0) ...[
            const SizedBox(height: 3),
            Row(
              children: [
                const SizedBox(width: 8),
                Icon(Icons.coffee_outlined,
                    size: 10, color: Colors.orange.shade700),
                const SizedBox(width: 4),
                Text('$breakMins min break',
                    style: TextStyle(
                        fontSize: 9,
                        color: Colors.orange.shade700,
                        fontStyle: FontStyle.italic)),
              ],
            ),
            const SizedBox(height: 3),
          ] else
            const SizedBox(height: 3),
          _previewRow('Match 2', m2Start, m2End,
              const Color(0xFF00CFFF)),
        ],
      ),
    );
  }

  Widget _previewRow(String label, String start, String end, Color color) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text('$label  ',
            style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: color)),
        Text('$start – $end',
            style: const TextStyle(
                fontSize: 9, color: Colors.black54)),
      ],
    );
  }

  // ── RIGHT: Schedule settings ───────────────────────────────────────────────
  Widget _buildScheduleColumn() {
    return SizedBox(
      width: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SCHEDULE',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 13,
              color: Color(0xFF3D1A8C),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 16),

          // ── Start time ──────────────────────────────────────────────────
          _timeTile(label: 'START TIME', time: _startTime, isStart: true),
          const SizedBox(height: 10),

          // ── End time ────────────────────────────────────────────────────
          _timeTile(label: 'END TIME', time: _endTime, isStart: false),

          // Warn if end ≤ start
          if ((_endTime.hour * 60 + _endTime.minute) <=
              (_startTime.hour * 60 + _startTime.minute))
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 12, color: Colors.red),
                  SizedBox(width: 4),
                  Text('End must be after start',
                      style: TextStyle(fontSize: 10, color: Colors.red)),
                ],
              ),
            ),

          const SizedBox(height: 16),

          // ── Duration + Break ─────────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('DURATION:',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 11)),
                  const SizedBox(height: 6),
                  _smallField(_durationController, maxVal: 999, width: 60),
                  const Text('min / match',
                      style: TextStyle(fontSize: 9, color: Colors.black38)),
                ],
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('BREAK:',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 11)),
                  const SizedBox(height: 6),
                  _smallField(_intervalController, maxVal: 999, width: 60),
                  const Text('min between',
                      style: TextStyle(fontSize: 9, color: Colors.black38)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ── Live timing preview ──────────────────────────────────────────
          _buildTimingPreview(),
          const SizedBox(height: 20),

          // ── Divider ─────────────────────────────────────────────────────
          const Divider(color: Color(0xFFDDDDDD)),
          const SizedBox(height: 12),

          // ── Lunch break toggle ──────────────────────────────────────────
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _lunchBreakEnabled
                  ? const Color(0xFF3D1A8C).withOpacity(0.06)
                  : Colors.grey.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _lunchBreakEnabled
                    ? const Color(0xFF3D1A8C).withOpacity(0.3)
                    : Colors.grey.withOpacity(0.2),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.no_meals_outlined,
                              size: 14,
                              color: _lunchBreakEnabled
                                  ? const Color(0xFF3D1A8C)
                                  : Colors.grey),
                          const SizedBox(width: 6),
                          Text('LUNCH BREAK',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                  color: _lunchBreakEnabled
                                      ? const Color(0xFF3D1A8C)
                                      : Colors.grey)),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text('12:00 PM – 1:00 PM\nNo matches scheduled',
                          style: TextStyle(
                              fontSize: 9,
                              color: _lunchBreakEnabled
                                  ? Colors.black45
                                  : Colors.black26,
                              height: 1.4)),
                    ],
                  ),
                ),
                Switch(
                  value: _lunchBreakEnabled,
                  onChanged: (v) =>
                      setState(() => _lunchBreakEnabled = v),
                  activeColor: const Color(0xFF3D1A8C),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Spinner (shared for runs and arenas) ──────────────────────────────────
  Widget _buildSpinner(int categoryId, {required bool isRuns}) {
    final value = isRuns
        ? (_runsPerCategory[categoryId]    ?? 2)
        : (_arenasPerCategory[categoryId]  ?? 1);
    final minVal = isRuns ? 1 : 1;
    final maxVal = isRuns ? 99 : 10;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFAAAAAA)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: Text(
                '$value',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),
          Container(width: 1, height: 36, color: const Color(0xFFAAAAAA)),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Up
              SizedBox(
                width: 24,
                height: 18,
                child: InkWell(
                  onTap: () => setState(() {
                    if (value < maxVal) {
                      if (isRuns) {
                        _runsPerCategory[categoryId] = value + 1;
                      } else {
                        _arenasPerCategory[categoryId] = value + 1;
                      }
                    }
                  }),
                  child: const Icon(Icons.keyboard_arrow_up, size: 15),
                ),
              ),
              Container(
                  height: 1, width: 24, color: const Color(0xFFAAAAAA)),
              // Down
              SizedBox(
                width: 24,
                height: 18,
                child: InkWell(
                  onTap: () => setState(() {
                    if (value > minVal) {
                      if (isRuns) {
                        _runsPerCategory[categoryId] = value - 1;
                      } else {
                        _arenasPerCategory[categoryId] = value - 1;
                      }
                    }
                  }),
                  child: const Icon(Icons.keyboard_arrow_down, size: 15),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Small text field ──────────────────────────────────────────────────────
  Widget _smallField(
    TextEditingController controller, {
    required int maxVal,
    double width = 60,
  }) {
    return SizedBox(
      width: width,
      height: 42,
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: const TextStyle(
            fontSize: 18, fontWeight: FontWeight.bold),
        decoration: InputDecoration(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide:
                const BorderSide(color: Color(0xFFAAAAAA)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide:
                const BorderSide(color: Color(0xFF3D1A8C), width: 2),
          ),
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────
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
                text: const TextSpan(children: [
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
                ]),
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