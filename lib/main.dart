import 'package:flutter/material.dart';
import 'db_helper.dart';
import 'landing_page.dart';
import 'step1_school.dart';
import 'step2_mentor.dart';
import 'step3_team.dart';
import 'step4_player.dart';
import 'generate_schedule.dart';
import 'schedule_viewer.dart';
import 'standings.dart';
import 'excel_import.dart';
import 'referee_registration.dart';
import 'category_registration.dart'; // ← NEW

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await DBHelper.getConnection();
    print("✅ Connected to database!");
    await DBHelper.runMigrations();
  } catch (e) {
    print("❌ Connection failed: $e");
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RoboVenture',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D1A8C)),
        useMaterial3: true,
      ),
      home: const LandingPage(),
    );
  }
}

// ── Registration Flow ─────────────────────────────────────────────────────────
class RegistrationFlow extends StatefulWidget {
  const RegistrationFlow({super.key});

  @override
  State<RegistrationFlow> createState() => _RegistrationFlowState();
}

class _RegistrationFlowState extends State<RegistrationFlow> {
  // 0   = choose mode
  // -1  = excel import
  // -2  = referee registration
  // -3  = category registration  ← NEW
  // 1–7 = manual steps
  int _currentStep = 0;
  int? _teamId;

  void _goToStep(int step) => setState(() => _currentStep = step);

  @override
  Widget build(BuildContext context) {
    switch (_currentStep) {

      // ── Step 0: Choose registration mode ─────────────────────────────
      case 0:
        return _RegistrationChooser(
          onManual:   () => _goToStep(1),
          onExcel:    () => _goToStep(-1),
          onReferee:  () => _goToStep(-2),
          onCategory: () => _goToStep(-3), // ← NEW
          onBack:     () => Navigator.of(context).pop(),
        );

      // ── Step -1: Excel Bulk Import ────────────────────────────────────
      case -1:
        return ExcelImportPage(
          onDone: () => _goToStep(5),
        );

      // ── Step -2: Referee Registration ─────────────────────────────────
      case -2:
        return RefereeRegistrationPage(
          onBack: () => _goToStep(0),
          onDone: () => _goToStep(0),
        );

      // ── Step -3: Category Registration ────────────────────────────────
      case -3:
        return CategoryRegistrationPage(  // ← NEW
          onBack: () => _goToStep(0),
        );

      // ── Step 1: School ────────────────────────────────────────────────
      case 1:
        return Step1School(
          onSkip:       () => _goToStep(2),
          onRegistered: (_) => _goToStep(2),
          onBack:       () => _goToStep(0),
        );

      // ── Step 2: Mentor ────────────────────────────────────────────────
      case 2:
        return Step2Mentor(
          onSkip:       () => _goToStep(3),
          onRegistered: (_) => _goToStep(3),
          onBack:       () => _goToStep(1),
        );

      // ── Step 3: Team ──────────────────────────────────────────────────
      case 3:
        return Step3Team(
          onSkip: () => _goToStep(4),
          onRegistered: (teamId) {
            setState(() {
              _teamId = teamId;
              _goToStep(4);
            });
          },
          onBack: () => _goToStep(2),
        );

      // ── Step 4: Players ───────────────────────────────────────────────
      case 4:
        return Step4Player(
          teamId: _teamId,
          onDone: () => _goToStep(5),
          onBack: () => _goToStep(3),
          onSkip: () => _goToStep(5),
        );

      // ── Step 5: Generate Schedule ─────────────────────────────────────
      case 5:
        return GenerateSchedule(
          onBack:      () => _goToStep(4),
          onGenerated: () => _goToStep(6),
        );

      // ── Step 6: Schedule Viewer ───────────────────────────────────────
      case 6:
        return ScheduleViewer(
          onRegister:  () => _goToStep(0),
          onStandings: () => _goToStep(7),
        );

      // ── Step 7: Standings ─────────────────────────────────────────────
      case 7:
        return Standings(
          onBack: () => _goToStep(6),
        );

      default:
        return const Scaffold(
          body: Center(child: Text('Flow Completed')),
        );
    }
  }
}

// ── Registration mode chooser ─────────────────────────────────────────────────
class _RegistrationChooser extends StatelessWidget {
  final VoidCallback onManual;
  final VoidCallback onExcel;
  final VoidCallback onReferee;
  final VoidCallback onCategory; // ← NEW
  final VoidCallback onBack;

  const _RegistrationChooser({
    required this.onManual,
    required this.onExcel,
    required this.onReferee,
    required this.onCategory,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0630),
      body: Column(
        children: [
          // ── Header ────────────────────────────────────────────────────
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1A0550), Color(0xFF2D0E7A), Color(0xFF1A0A4A)],
              ),
              border: Border(
                bottom: BorderSide(color: Color(0xFF00CFFF), width: 1.5),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            child: Row(children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: Color(0xFF00CFFF), size: 18),
                onPressed: onBack,
              ),
              const SizedBox(width: 8),
              const Text('REGISTRATION',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3)),
            ]),
          ),

          // ── Body ──────────────────────────────────────────────────────
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('HOW WOULD YOU LIKE TO REGISTER?',
                      style: TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                          letterSpacing: 2,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 48),

                  // ── Row 1: Manual · Excel · Referee ───────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _ModeCard(
                        icon:     Icons.edit_note_rounded,
                        title:    'MANUAL',
                        subtitle: 'Register one team\nat a time, step by step',
                        color:    const Color(0xFFFFD700),
                        onTap:    onManual,
                      ),
                      const SizedBox(width: 32),
                      _ModeCard(
                        icon:     Icons.upload_file_rounded,
                        title:    'EXCEL IMPORT',
                        subtitle: 'Upload an Excel file to\nregister all teams at once',
                        color:    const Color(0xFF00CFFF),
                        onTap:    onExcel,
                      ),
                      const SizedBox(width: 32),
                      _ModeCard(
                        icon:     Icons.sports_rounded,
                        title:    'REFEREE',
                        subtitle: 'Register referees &\nassign categories',
                        color:    const Color(0xFF00FF9C),
                        onTap:    onReferee,
                      ),
                      const SizedBox(width: 32),
                      // ── NEW: Category card ─────────────────────────────
                      _ModeCard(
                        icon:     Icons.category_rounded,
                        title:    'CATEGORIES',
                        subtitle: 'Add categories &\nset active / inactive',
                        color:    const Color(0xFFAA80FF),
                        onTap:    onCategory,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Mode card ─────────────────────────────────────────────────────────────────
class _ModeCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  State<_ModeCard> createState() => _ModeCardState();
}

class _ModeCardState extends State<_ModeCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 200,
          height: 200,
          decoration: BoxDecoration(
            color: _hovered
                ? widget.color.withOpacity(0.1)
                : const Color(0xFF130840),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: _hovered
                  ? widget.color
                  : widget.color.withOpacity(0.25),
              width: _hovered ? 2.0 : 1.5,
            ),
            boxShadow: _hovered
                ? [BoxShadow(
                    color: widget.color.withOpacity(0.25),
                    blurRadius: 24, spreadRadius: 2)]
                : [],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 68, height: 68,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withOpacity(_hovered ? 0.2 : 0.1),
                  border: Border.all(
                      color: widget.color.withOpacity(0.4), width: 1.5),
                ),
                child: Icon(widget.icon, color: widget.color, size: 30),
              ),
              const SizedBox(height: 18),
              Text(widget.title,
                  style: TextStyle(
                      color: widget.color,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2)),
              const SizedBox(height: 8),
              Text(widget.subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.45),
                      fontSize: 10,
                      height: 1.5)),
            ],
          ),
        ),
      ),
    );
  }
}