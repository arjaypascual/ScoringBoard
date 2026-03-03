import 'package:flutter/material.dart';
import 'db_helper.dart';
import 'step1_school.dart';
import 'step2_mentor.dart';
import 'step3_team.dart';
import 'step4_run.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await DBHelper.getConnection();
    print("✅ Connected to database!");
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
      title: 'RoboVenture Scoring',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D1A8C)),
        useMaterial3: true,
      ),
      home: const RegistrationFlow(),
    );
  }
}

class RegistrationFlow extends StatefulWidget {
  const RegistrationFlow({super.key});

  @override
  State<RegistrationFlow> createState() => _RegistrationFlowState();
}

class _RegistrationFlowState extends State<RegistrationFlow> {
  int _currentStep = 1;
  int? _schoolId;
  int? _mentorId;
  int? _teamId;

  void _goToStep(int step) {
    setState(() => _currentStep = step);
  }

  @override
  Widget build(BuildContext context) {
    switch (_currentStep) {
      case 1:
        return Step1School(
          onSkip: () => _goToStep(2),
          onRegistered: (schoolId) {
            setState(() {
              _schoolId = schoolId;
              _goToStep(2);
            });
          },
        );
      case 2:
        return Step2Mentor(
          onSkip: () => _goToStep(3),
          onRegistered: (mentorId) {
            setState(() {
              _mentorId = mentorId;
              _goToStep(3);
            });
          },
        );
      case 3:
        return Step3Team(
          onSkip: () => _goToStep(4),
          onRegistered: (teamId) {
            setState(() {
              _teamId = teamId;
              _goToStep(4);
            });
          },
        );
      case 4:
        // Passing the IDs here removes the "unused_field" warnings
        return Step4Run(
          schoolId: _schoolId,
          mentorId: _mentorId,
          teamId: _teamId,
        );
      default:
        return const Scaffold(
          body: Center(child: Text('Registration Flow Completed')),
        );
    }
  }
}