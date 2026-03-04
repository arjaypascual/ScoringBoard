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
  // ── Runs per category (category_id → runs) ───────────────────────────────
  final Map<int, int> _runsPerCategory = {};
  List<Map<String, dynamic>> _categories = [];
  bool _isLoadingData = true;

  // ── Schedule settings ────────────────────────────────────────────────────
  final _startHourController   = TextEditingController(text: '09');
  final _startMinuteController = TextEditingController(text: '00');
  final _durationController    = TextEditingController(text: '6');
  final _intervalController    = TextEditingController(text: '0');

  bool _isGenerating = false;

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    try {
      final cats = await DBHelper.getCategories();
      setState(() {
        _categories = cats;
        for (final c in cats) {
          final id = int.tryParse(c['category_id'].toString()) ?? 0;
          _runsPerCategory[id] = 2; // default 2 runs
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

  // ── Generate ──────────────────────────────────────────────────────────────
  Future<void> _generateSchedule() async {
    final hour     = int.tryParse(_startHourController.text.trim())   ?? 9;
    final minute   = int.tryParse(_startMinuteController.text.trim()) ?? 0;
    final duration = int.tryParse(_durationController.text.trim())    ?? 6;
    final interval = int.tryParse(_intervalController.text.trim())    ?? 0;

    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('❌ Please enter a valid start time.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (duration <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('❌ Duration must be greater than 0.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isGenerating = true);
    try {
      final startTime =
          '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

      await DBHelper.generateSchedule(
        runsPerCategory: _runsPerCategory,
        startTime: startTime,
        durationMinutes: duration,
        intervalMinutes: interval,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Schedule generated successfully!'),
            backgroundColor: Colors.green,
          ),
        );

        // Auto-navigate to schedule viewer
        widget.onGenerated?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  // ── Dispose ───────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _startHourController.dispose();
    _startMinuteController.dispose();
    _durationController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFDDDDDD),
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: Center(
              child: Container(
                width: 700,
                padding: const EdgeInsets.fromLTRB(40, 32, 40, 36),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border:
                      Border.all(color: const Color(0xFF3D1A8C), width: 2),
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
                        // ── Title ───────────────────────────────────────
                        const Text(
                          'RoboVenture',
                          style: TextStyle(
                            fontFamily: 'serif',
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF3D1A8C),
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ── Two-column layout ───────────────────────────
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // LEFT — runs per team
                            Expanded(child: _buildRunsColumn()),

                            const SizedBox(width: 32),

                            // RIGHT — schedule settings
                            _buildScheduleColumn(),
                          ],
                        ),
                        const SizedBox(height: 32),

                        // ── Generate button ─────────────────────────────
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
                                      strokeWidth: 2, color: Colors.white),
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

                    // ── Back button ───────────────────────────────────────
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

                    // ── Close button ──────────────────────────────────────
                    Positioned(
                      top: 0,
                      right: 0,
                      child: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).maybePop(),
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
  }

  // ── LEFT: Runs per team column ────────────────────────────────────────────
  Widget _buildRunsColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'HOW MANY RUNS PER TEAM?',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 13,
            color: Color(0xFF3D1A8C),
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 20),
        _isLoadingData
            ? const Center(
                child: CircularProgressIndicator(strokeWidth: 2))
            : Column(
                children: _categories.map((c) {
                  final id =
                      int.tryParse(c['category_id'].toString()) ?? 0;
                  final name = c['category_type'] ?? '';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            name.toUpperCase(),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        _buildSpinner(id),
                      ],
                    ),
                  );
                }).toList(),
              ),
      ],
    );
  }

  // ── RIGHT: Schedule settings column ──────────────────────────────────────
  Widget _buildScheduleColumn() {
    return SizedBox(
      width: 200,
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
          const SizedBox(height: 20),

          // Start time
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('START TIME:',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 6),
                  // HH:MM inline
                  Row(
                    children: [
                      _smallNumberField(_startHourController,
                          maxVal: 23, width: 48),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Text(':',
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF3D1A8C))),
                      ),
                      _smallNumberField(_startMinuteController,
                          maxVal: 59, width: 48),
                    ],
                  ),
                ],
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('DURATION:',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 6),
                  _smallNumberField(_durationController,
                      maxVal: 999, width: 60),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Interval
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('INTERVAL:',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12)),
              const SizedBox(height: 6),
              _smallNumberField(_intervalController,
                  maxVal: 999, width: 60),
            ],
          ),
        ],
      ),
    );
  }

  // ── Spinner widget (up/down arrows) ───────────────────────────────────────
  Widget _buildSpinner(int categoryId) {
    final value = _runsPerCategory[categoryId] ?? 2;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFAAAAAA)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 48,
            height: 38,
            child: Center(
              child: Text(
                '$value',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ),
          ),
          Container(
            width: 1,
            height: 38,
            color: const Color(0xFFAAAAAA),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Up
              SizedBox(
                width: 28,
                height: 19,
                child: InkWell(
                  onTap: () => setState(
                      () => _runsPerCategory[categoryId] = value + 1),
                  child: const Icon(Icons.keyboard_arrow_up, size: 16),
                ),
              ),
              Container(height: 1, width: 28, color: const Color(0xFFAAAAAA)),
              // Down
              SizedBox(
                width: 28,
                height: 19,
                child: InkWell(
                  onTap: () {
                    if (value > 1) {
                      setState(
                          () => _runsPerCategory[categoryId] = value - 1);
                    }
                  },
                  child: const Icon(Icons.keyboard_arrow_down, size: 16),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Small number text field ───────────────────────────────────────────────
  Widget _smallNumberField(
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
            borderSide: const BorderSide(color: Color(0xFFAAAAAA)),
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