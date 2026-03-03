import 'package:flutter/material.dart';
import 'db_helper.dart';

class Step4Run extends StatefulWidget {
  final int? schoolId;
  final int? mentorId;
  final int? teamId;

  const Step4Run({
    super.key,
    this.schoolId,
    this.mentorId,
    this.teamId,
  });

  @override
  State<Step4Run> createState() => _Step4RunState();
}

class _Step4RunState extends State<Step4Run> {
  final _aspiringController = TextEditingController(text: '2');
  final _emergingController = TextEditingController(text: '2');
  final _navigationController = TextEditingController(text: '2');
  final _soccerController = TextEditingController(text: '2');
  final _startTimeController = TextEditingController(text: '09:00');
  final _durationController = TextEditingController(text: '6');
  final _intervalController = TextEditingController(text: '0');

  bool _isGenerating = false;

  @override
  void dispose() {
    _aspiringController.dispose();
    _emergingController.dispose();
    _navigationController.dispose();
    _soccerController.dispose();
    _startTimeController.dispose();
    _durationController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  Future<void> _generateSchedule() async {
    setState(() => _isGenerating = true);
    try {
      final aspiringId = await DBHelper.getCategoryIdByName('Aspiring Makers');
      final emergingId = await DBHelper.getCategoryIdByName('Emerging Innovators');
      final navigationId = await DBHelper.getCategoryIdByName('Navigation');
      final soccerId = await DBHelper.getCategoryIdByName('Soccer');

      final runsPerCategory = <int, int>{};
      if (aspiringId != null) runsPerCategory[aspiringId] = int.tryParse(_aspiringController.text) ?? 2;
      if (emergingId != null) runsPerCategory[emergingId] = int.tryParse(_emergingController.text) ?? 2;
      if (navigationId != null) runsPerCategory[navigationId] = int.tryParse(_navigationController.text) ?? 2;
      if (soccerId != null) runsPerCategory[soccerId] = int.tryParse(_soccerController.text) ?? 2;

      await DBHelper.generateSchedule(
        runsPerCategory: runsPerCategory,
        startTime: _startTimeController.text.trim(),
        durationMinutes: int.tryParse(_durationController.text) ?? 6,
        intervalMinutes: int.tryParse(_intervalController.text) ?? 0,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Schedule generated successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _isGenerating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFDDDDDD),
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: Container(
              // Checkered background like in screenshot
              decoration: const BoxDecoration(
                color: Color(0xFFCCCCDD),
              ),
              child: Center(
                child: Container(
                  width: 620,
                  padding: const EdgeInsets.fromLTRB(28, 20, 28, 28),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF3D1A8C), width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.15),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // RoboVenture title
                          const Text(
                            'RoboVenture',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF3D1A8C),
                              letterSpacing: 2,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                          const SizedBox(height: 20),

                          // Two-column form
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // LEFT: How many runs
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'HOW MANY RUNS PER TEAM?',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 11,
                                        color: Color(0xFF3D1A8C),
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                    _runRow('ASPIRING MAKERS', _aspiringController),
                                    const SizedBox(height: 10),
                                    _runRow('EMERGING INNOVATORS', _emergingController),
                                    const SizedBox(height: 10),
                                    _runRow('NAVIGATION', _navigationController),
                                    const SizedBox(height: 10),
                                    _runRow('SOCCER', _soccerController),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 24),
                              // RIGHT: Schedule
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'SCHEDULE',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 11,
                                        color: Color(0xFF3D1A8C),
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                    // Start time + Duration side by side
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              _scheduleLabel('START TIME:'),
                                              const SizedBox(height: 4),
                                              _plainTextField(_startTimeController),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        SizedBox(
                                          width: 80,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              _scheduleLabel('DURATION:'),
                                              const SizedBox(height: 4),
                                              _spinnerField(_durationController),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    // Interval
                                    SizedBox(
                                      width: 80,
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          _scheduleLabel('INTERVAL:'),
                                          const SizedBox(height: 4),
                                          _spinnerField(_intervalController),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 24),

                          // Generate button
                          ElevatedButton(
                            onPressed: _isGenerating ? null : _generateSchedule,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF4A2CC7),
                              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: const BorderSide(color: Color(0xFF00CFFF), width: 2),
                              ),
                            ),
                            child: _isGenerating
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Text(
                                    'GENERATE SCHEDULE',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 13,
                                      letterSpacing: 1.5,
                                    ),
                                  ),
                          ),
                        ],
                      ),

                      // Close button top-right
                      Positioned(
                        top: -8,
                        right: -8,
                        child: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => Navigator.of(context).maybePop(),
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

  // ── HEADER ──────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF2D0E7A),
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: const TextSpan(
                  children: [
                    TextSpan(text: 'Make', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                    TextSpan(text: 'bl', style: TextStyle(color: Color(0xFF00CFFF), fontSize: 20, fontWeight: FontWeight.bold)),
                    TextSpan(text: 'ock', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const Text('Construct Your Dreams', style: TextStyle(color: Colors.white54, fontSize: 9)),
            ],
          ),
          Image.asset('assets/images/CenterLogo.png', height: 70, fit: BoxFit.contain),
          const Text('CREOTEC', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 3)),
        ],
      ),
    );
  }

  // ── HELPERS ─────────────────────────────────────────────────────────────────

  Widget _runRow(String label, TextEditingController controller) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 11,
              color: Color(0xFF222222),
            ),
          ),
        ),
        SizedBox(width: 72, child: _spinnerField(controller)),
      ],
    );
  }

  Widget _scheduleLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 11,
        color: Color(0xFF222222),
      ),
    );
  }

  Widget _spinnerField(TextEditingController controller) {
    return SizedBox(
      height: 36,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFAAAAAA)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            Container(
              width: 20,
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: Colors.grey.shade300)),
              ),
              child: Column(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        final val = int.tryParse(controller.text) ?? 0;
                        setState(() => controller.text = (val + 1).toString());
                      },
                      child: const Center(child: Icon(Icons.arrow_drop_up, size: 16)),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        final val = int.tryParse(controller.text) ?? 0;
                        if (val > 0) setState(() => controller.text = (val - 1).toString());
                      },
                      child: const Center(child: Icon(Icons.arrow_drop_down, size: 16)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _plainTextField(TextEditingController controller) {
    return SizedBox(
      height: 36,
      child: TextField(
        controller: controller,
        textAlign: TextAlign.center,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: Color(0xFFAAAAAA)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: Color(0xFF3D1A8C), width: 2),
          ),
        ),
      ),
    );
  }
}