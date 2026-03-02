import 'package:flutter/material.dart';
import 'db_helper.dart';
import 'step1_school.dart';
import 'step2_mentor.dart';
import 'step3_team.dart';

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
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
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
            _schoolId = schoolId;
            print('✅ School registered with ID: $schoolId');
            _goToStep(2);
          },
        );
      case 2:
        return Step2Mentor(
          onSkip: () => _goToStep(3),
          onRegistered: (mentorId) {
            _mentorId = mentorId;
            print('✅ Mentor registered with ID: $mentorId');
            _goToStep(3);
          },
        );
      case 3:
        return Step3Team(
          onSkip: () => _goToStep(4),
          onRegistered: (teamId) {
            _teamId = teamId;
            print('✅ Team registered with ID: $teamId');
            _goToStep(4);
          },
        );
      case 4:
        // Step 4 placeholder - replace with Step4 widget when ready
        return Scaffold(
          body: Center(
            child: Text(
              'Step 4 - Coming Soon\nSchool ID: $_schoolId\nMentor ID: $_mentorId\nTeam ID: $_teamId',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20),
            ),
          ),
        );
      default:
        return const Scaffold(
          body: Center(child: Text('Done!')),
        );
    }
  }
}