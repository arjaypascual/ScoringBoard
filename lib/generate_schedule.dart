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

class _GenerateScheduleState extends State<GenerateSchedule> {
  static const _accent = Color(0xFF00CFFF);

  final Map<int, int> _runsPerCategory      = {};
  final Map<int, int> _arenasPerCategory    = {};
  final Map<int, int> _teamCountPerCategory = {};

  List<Map<String, dynamic>> _categories = [];
  bool _isLoadingData = true;

  TimeOfDay _startTime = const TimeOfDay(hour: 9,  minute: 0);
  TimeOfDay _endTime   = const TimeOfDay(hour: 17, minute: 0);
  final _durationController = TextEditingController(text: '6');
  final _intervalController = TextEditingController(text: '0');

  bool _lunchBreakEnabled = true;
  bool _isGenerating      = false;

  static const int _maxTeamsPerArena = 15;

  @override
  void initState() {
    super.initState();
    _loadCategories();
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
      final seen = <int>{};
      final unique = cats.where((c) {
        final id = int.tryParse(c['category_id'].toString()) ?? 0;
        return id > 0 && seen.add(id);
      }).toList();

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
          _runsPerCategory[id]      = 2;
          _arenasPerCategory[id]    = count == 0 ? 1 : (count / _maxTeamsPerArena).ceil();
          _teamCountPerCategory[id] = count;
        }
        _isLoadingData = false;
      });
    } catch (e) {
      setState(() => _isLoadingData = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Failed to load categories: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  String? _arenaWarning(int categoryId) {
    final teams    = _teamCountPerCategory[categoryId] ?? 0;
    final arenas   = _arenasPerCategory[categoryId]    ?? 1;
    if (teams == 0) return null;
    if (teams > arenas * _maxTeamsPerArena) {
      return '$teams teams — needs ≥${(teams / _maxTeamsPerArena).ceil()} arenas';
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

  Future<void> _generateSchedule() async {
    final duration = int.tryParse(_durationController.text.trim()) ?? 6;
    final interval = int.tryParse(_intervalController.text.trim()) ?? 0;

    if (duration <= 0) { _snack('❌ Duration must be greater than 0.', Colors.red); return; }

    final startMin = _startTime.hour * 60 + _startTime.minute;
    final endMin   = _endTime.hour   * 60 + _endTime.minute;
    if (endMin <= startMin) { _snack('❌ End time must be after start time.', Colors.red); return; }
    if (_hasArenaError)     { _snack('❌ Some categories exceed arena capacity.', Colors.red); return; }

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

  Future<bool?> _showConfirmDialog() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xFF2D0E7A), Color(0xFF1E0A5A)],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: Colors.orange.withOpacity(0.4), width: 1.5),
            boxShadow: [
              BoxShadow(color: Colors.orange.withOpacity(0.1),
                  blurRadius: 30, spreadRadius: 4),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.orange.withOpacity(0.15),
                  border: Border.all(color: Colors.orange.withOpacity(0.4)),
                ),
                child: const Icon(Icons.warning_amber_rounded,
                    color: Colors.orange, size: 30),
              ),
              const SizedBox(height: 16),
              const Text('Regenerate Schedule?',
                  style: TextStyle(color: Colors.white, fontSize: 18,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              Text(
                'This will DELETE the existing schedule\nand generate a new one. Are you sure?',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.6), fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.white.withOpacity(0.2)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: Text('CANCEL',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.5),
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
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
                          child: Center(
                            child: Text('REGENERATE',
                                style: TextStyle(color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color));
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A0A4A),
      body: Column(
        children: [
          const RegistrationHeader(),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Container(
                  width: 820,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [Color(0xFF2D0E7A), Color(0xFF1E0A5A)],
                    ),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                        color: _accent.withOpacity(0.3), width: 1.5),
                    boxShadow: [
                      BoxShadow(color: _accent.withOpacity(0.08),
                          blurRadius: 40, spreadRadius: 4),
                      BoxShadow(color: Colors.black.withOpacity(0.4),
                          blurRadius: 30, offset: const Offset(0, 10)),
                    ],
                  ),
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(40, 36, 40, 36),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // ── Title ──────────────────────────────────────
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _accent.withOpacity(0.1),
                                    border: Border.all(
                                        color: _accent.withOpacity(0.3)),
                                  ),
                                  child: const Icon(Icons.calendar_month_rounded,
                                      color: _accent, size: 22),
                                ),
                                const SizedBox(width: 14),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('GENERATE SCHEDULE',
                                        style: TextStyle(color: Colors.white,
                                            fontSize: 20,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 2)),
                                    Text('Configure and generate the match schedule',
                                        style: TextStyle(
                                            color: Colors.white.withOpacity(0.4),
                                            fontSize: 12)),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 28),

                            // Gradient divider
                            buildDivider(_accent),
                            const SizedBox(height: 28),

                            // ── Two columns ────────────────────────────────
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: _buildCategoryColumn()),
                                const SizedBox(width: 28),
                                SizedBox(width: 240,
                                    child: _buildScheduleColumn()),
                              ],
                            ),
                            const SizedBox(height: 32),

                            buildDivider(_accent),
                            const SizedBox(height: 28),

                            // ── Generate button ────────────────────────────
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
                                    boxShadow: [
                                      BoxShadow(
                                          color: _accent.withOpacity(0.4),
                                          blurRadius: 20, spreadRadius: 2),
                                    ],
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
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 15,
                                                    letterSpacing: 2,
                                                  )),
                                            ],
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Back button
                      Positioned(top: 12, left: 12,
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back_ios_new,
                              color: _accent, size: 18),
                          onPressed: widget.onBack),
                      ),

                      // Close button
                      Positioned(top: 12, right: 12,
                        child: IconButton(
                          icon: Icon(Icons.close,
                              color: Colors.white.withOpacity(0.35), size: 20),
                          onPressed: () => Navigator.of(context).maybePop()),
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

  // ── LEFT: Category runs + arenas ──────────────────────────────────────────
  Widget _buildCategoryColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Column header
        Row(children: [
          const Expanded(
            child: Text('CATEGORY',
                style: TextStyle(color: _accent, fontWeight: FontWeight.w800,
                    fontSize: 11, letterSpacing: 1.5)),
          ),
          SizedBox(width: 90,
            child: Center(child: Text('RUNS',
                style: TextStyle(color: _accent.withOpacity(0.8),
                    fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 1.5)))),
          const SizedBox(width: 10),
          SizedBox(width: 90,
            child: Column(children: [
              Center(child: Text('ARENAS',
                  style: TextStyle(color: _accent.withOpacity(0.8),
                      fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 1.5))),
              Center(child: Text('max $_maxTeamsPerArena teams',
                  style: TextStyle(fontSize: 9,
                      color: Colors.white.withOpacity(0.3),
                      fontStyle: FontStyle.italic))),
            ])),
        ]),
        const SizedBox(height: 4),

        // Thin divider
        Container(height: 1, color: _accent.withOpacity(0.15)),
        const SizedBox(height: 14),

        // Category rows
        _isLoadingData
            ? const Center(child: CircularProgressIndicator(
                strokeWidth: 2, color: _accent))
            : Column(
                children: _categories.map((c) {
                  final id      = int.tryParse(c['category_id'].toString()) ?? 0;
                  final name    = (c['category_type'] ?? '').toString();
                  final count   = _teamCountPerCategory[id] ?? 0;
                  final warning = _arenaWarning(id);

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: warning != null
                            ? Colors.orange.withOpacity(0.4)
                            : _accent.withOpacity(0.15),
                      ),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            // Category info
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(name.toUpperCase(),
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13)),
                                  const SizedBox(height: 3),
                                  Row(children: [
                                    Icon(
                                      count == 0
                                          ? Icons.warning_amber_rounded
                                          : Icons.groups_rounded,
                                      size: 12,
                                      color: count == 0
                                          ? Colors.orange
                                          : Colors.white38,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '$count team${count != 1 ? 's' : ''} registered',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: count == 0
                                            ? Colors.orange
                                            : Colors.white38,
                                      ),
                                    ),
                                  ]),
                                ],
                              ),
                            ),
                            // Runs spinner
                            SizedBox(width: 90,
                                child: Center(
                                    child: _buildSpinner(id, isRuns: true))),
                            const SizedBox(width: 10),
                            // Arenas spinner
                            SizedBox(width: 90,
                                child: Center(
                                    child: _buildSpinner(id, isRuns: false))),
                          ],
                        ),

                        // Warning or capacity
                        if (warning != null) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color: Colors.orange.withOpacity(0.3)),
                            ),
                            child: Row(children: [
                              const Icon(Icons.warning_amber_rounded,
                                  size: 12, color: Colors.orange),
                              const SizedBox(width: 6),
                              Text(warning,
                                  style: const TextStyle(
                                      fontSize: 10, color: Colors.orange)),
                            ]),
                          ),
                        ] else if (count > 0) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00E5A0).withOpacity(0.08),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color: const Color(0xFF00E5A0)
                                      .withOpacity(0.25)),
                            ),
                            child: Row(children: [
                              const Icon(Icons.check_circle_outline_rounded,
                                  size: 12, color: Color(0xFF00E5A0)),
                              const SizedBox(width: 6),
                              Text(
                                'Capacity: ${(_arenasPerCategory[id] ?? 1) * _maxTeamsPerArena}'
                                ' teams (${_arenasPerCategory[id] ?? 1} × $_maxTeamsPerArena)',
                                style: const TextStyle(
                                    fontSize: 10, color: Color(0xFF00E5A0)),
                              ),
                            ]),
                          ),
                        ],
                      ],
                    ),
                  );
                }).toList(),
              ),
      ],
    );
  }

  // ── RIGHT: Schedule settings ───────────────────────────────────────────────
  Widget _buildScheduleColumn() {
    final timeError = (_endTime.hour * 60 + _endTime.minute) <=
        (_startTime.hour * 60 + _startTime.minute);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SCHEDULE SETTINGS',
            style: TextStyle(color: _accent.withOpacity(0.9),
                fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 1.5)),
        const SizedBox(height: 4),
        Container(height: 1, color: _accent.withOpacity(0.15)),
        const SizedBox(height: 16),

        // Start time
        _timeTile(label: 'START TIME', time: _startTime, isStart: true),
        const SizedBox(height: 10),

        // End time
        _timeTile(label: 'END TIME', time: _endTime, isStart: false),

        if (timeError) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.red.withOpacity(0.3)),
            ),
            child: const Row(children: [
              Icon(Icons.error_outline_rounded, size: 12, color: Colors.red),
              SizedBox(width: 6),
              Text('End must be after start',
                  style: TextStyle(fontSize: 10, color: Colors.red)),
            ]),
          ),
        ],

        const SizedBox(height: 16),

        // Duration + Break
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildNumberField(
              label: 'DURATION',
              subtitle: 'min / match',
              controller: _durationController,
            )),
            const SizedBox(width: 12),
            Expanded(child: _buildNumberField(
              label: 'BREAK',
              subtitle: 'min between',
              controller: _intervalController,
            )),
          ],
        ),
        const SizedBox(height: 12),

        // Timing preview
        _buildTimingPreview(),
        const SizedBox(height: 16),

        Container(height: 1, color: Colors.white.withOpacity(0.08)),
        const SizedBox(height: 14),

        // Lunch break toggle
        _buildLunchToggle(),
      ],
    );
  }

  // ── Time tile ──────────────────────────────────────────────────────────────
  Widget _timeTile({
    required String label,
    required TimeOfDay time,
    required bool isStart,
  }) {
    return GestureDetector(
      onTap: () => _pickTime(isStart),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _accent.withOpacity(0.25)),
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _accent.withOpacity(0.1),
            ),
            child: const Icon(Icons.access_time_rounded,
                size: 14, color: _accent),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: TextStyle(fontSize: 9,
                    color: Colors.white.withOpacity(0.4),
                    fontWeight: FontWeight.bold, letterSpacing: 0.5)),
            Text(_fmtTime(time),
                style: const TextStyle(fontSize: 16,
                    fontWeight: FontWeight.bold, color: Colors.white)),
          ]),
          const Spacer(),
          Icon(Icons.edit_rounded, size: 14, color: Colors.white.withOpacity(0.3)),
        ]),
      ),
    );
  }

  // ── Number field ────────────────────────────────────────────────────────────
  Widget _buildNumberField({
    required String label,
    required String subtitle,
    required TextEditingController controller,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: Colors.white,
                fontWeight: FontWeight.w700, fontSize: 11, letterSpacing: 1)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white,
              fontSize: 18, fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
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
        Text(subtitle,
            style: TextStyle(
                fontSize: 9, color: Colors.white.withOpacity(0.35))),
      ],
    );
  }

  // ── Timing preview ─────────────────────────────────────────────────────────
  Widget _buildTimingPreview() {
    final duration  = int.tryParse(_durationController.text.trim()) ?? 0;
    final breakMins = int.tryParse(_intervalController.text.trim())  ?? 0;
    if (duration <= 0) return const SizedBox.shrink();

    int h = _startTime.hour, m = _startTime.minute;

    String fmt(int hour, int min) {
      final total = hour * 60 + min;
      final th    = total ~/ 60;
      final tm    = total % 60;
      final period = th < 12 ? 'AM' : 'PM';
      final h12 = th % 12 == 0 ? 12 : th % 12;
      return '${h12.toString().padLeft(2, '0')}:${tm.toString().padLeft(2, '0')} $period';
    }

    final m1Start = fmt(h, m);
    final m1End   = fmt(h, m + duration);
    final m2Start = fmt(h, m + duration + breakMins);
    final m2End   = fmt(h, m + duration + breakMins + duration);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _accent.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _accent.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.schedule_rounded, size: 11, color: _accent),
            const SizedBox(width: 5),
            const Text('EXAMPLE TIMING',
                style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold,
                    color: _accent, letterSpacing: 1)),
          ]),
          const SizedBox(height: 8),
          _previewRow('Match 1', m1Start, m1End, _accent),
          if (breakMins > 0) ...[
            const SizedBox(height: 4),
            Row(children: [
              const SizedBox(width: 6),
              Icon(Icons.coffee_rounded, size: 10, color: Colors.orange.shade400),
              const SizedBox(width: 4),
              Text('$breakMins min break',
                  style: TextStyle(fontSize: 9, color: Colors.orange.shade400,
                      fontStyle: FontStyle.italic)),
            ]),
            const SizedBox(height: 4),
          ] else const SizedBox(height: 4),
          _previewRow('Match 2', m2Start, m2End, const Color(0xFF00E5A0)),
        ],
      ),
    );
  }

  Widget _previewRow(String label, String start, String end, Color color) {
    return Row(children: [
      Container(width: 3, height: 16,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 8),
      Text('$label  ',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold,
              color: color)),
      Text('$start – $end',
          style: TextStyle(fontSize: 10,
              color: Colors.white.withOpacity(0.5))),
    ]);
  }

  // ── Lunch break toggle ──────────────────────────────────────────────────────
  Widget _buildLunchToggle() {
    return GestureDetector(
      onTap: () => setState(() => _lunchBreakEnabled = !_lunchBreakEnabled),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _lunchBreakEnabled
                  ? const Color(0xFFFFD700).withOpacity(0.15)
                  : Colors.white.withOpacity(0.05),
            ),
            child: Icon(Icons.restaurant_rounded, size: 14,
                color: _lunchBreakEnabled
                    ? const Color(0xFFFFD700)
                    : Colors.white38),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('LUNCH BREAK',
                  style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5,
                    color: _lunchBreakEnabled
                        ? const Color(0xFFFFD700)
                        : Colors.white38,
                  )),
              Text('12:00 PM – 1:00 PM  •  No matches',
                  style: TextStyle(fontSize: 9, height: 1.4,
                      color: _lunchBreakEnabled
                          ? Colors.white38
                          : Colors.white24)),
            ],
          )),
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

  // ── Spinner ────────────────────────────────────────────────────────────────
  Widget _buildSpinner(int categoryId, {required bool isRuns}) {
    final value  = isRuns ? (_runsPerCategory[categoryId] ?? 2)
                          : (_arenasPerCategory[categoryId] ?? 1);
    final maxVal = isRuns ? 99 : 3;
    final color  = isRuns ? _accent : const Color(0xFF967BB6);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 38, height: 38,
            child: Center(
              child: Text('$value',
                  style: TextStyle(fontWeight: FontWeight.bold,
                      fontSize: 16, color: color)),
            ),
          ),
          Container(width: 1, height: 38,
              color: color.withOpacity(0.2)),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 26, height: 19,
                child: InkWell(
                  borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(8)),
                  onTap: () => setState(() {
                    if (value < maxVal) {
                      if (isRuns) _runsPerCategory[categoryId] = value + 1;
                      else _arenasPerCategory[categoryId] = value + 1;
                    }
                  }),
                  child: Icon(Icons.keyboard_arrow_up,
                      size: 16, color: color.withOpacity(0.8)),
                ),
              ),
              Container(height: 1, width: 26, color: color.withOpacity(0.2)),
              SizedBox(
                width: 26, height: 19,
                child: InkWell(
                  borderRadius: const BorderRadius.only(
                      bottomRight: Radius.circular(8)),
                  onTap: () => setState(() {
                    if (value > 1) {
                      if (isRuns) _runsPerCategory[categoryId] = value - 1;
                      else _arenasPerCategory[categoryId] = value - 1;
                    }
                  }),
                  child: Icon(Icons.keyboard_arrow_down,
                      size: 16, color: color.withOpacity(0.8)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  Future<void> _pickTime(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _startTime : _endTime,
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: _accent,
            onPrimary: Colors.black,
            surface: Color(0xFF2D0E7A),
            onSurface: Colors.white,
          ),
          timePickerTheme: TimePickerThemeData(
            dialHandColor: _accent,
            dialBackgroundColor: const Color(0xFF1E0A5A),
            hourMinuteColor: Colors.white.withOpacity(0.1),
            hourMinuteTextColor: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        if (isStart) _startTime = picked;
        else         _endTime   = picked;
      });
    }
  }

  String _fmtTime(TimeOfDay t) {
    final period = t.hour < 12 ? 'AM' : 'PM';
    final h12    = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    return '${h12.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} $period';
  }
}