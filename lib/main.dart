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
      home: const LandingPage(), // ← starts at landing page
    );
  }
}

// ── Registration Flow (launched from LandingPage → REGISTRATION button) ──────
class RegistrationFlow extends StatefulWidget {
  const RegistrationFlow({super.key});

  @override
  State<RegistrationFlow> createState() => _RegistrationFlowState();
}

class _RegistrationFlowState extends State<RegistrationFlow> {
  int _currentStep = 1;
  int? _teamId;

  void _goToStep(int step) => setState(() => _currentStep = step);

  @override
  Widget build(BuildContext context) {
    switch (_currentStep) {
      // ── Step 1: School ────────────────────────────────────────────────
      case 1:
        return Step1School(
          onSkip:       () => _goToStep(2),
          onRegistered: (_) => _goToStep(2),
          onBack:       () => Navigator.of(context).pop(), // back to landing
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
          onRegister:  () => _goToStep(1),
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