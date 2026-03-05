import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'db_helper.dart';
import 'registration_shared.dart';

class Step2Mentor extends StatefulWidget {
  final VoidCallback onSkip;
  final void Function(int mentorId) onRegistered;
  final VoidCallback? onBack;

  const Step2Mentor({
    super.key,
    required this.onSkip,
    required this.onRegistered,
    this.onBack,
  });

  @override
  State<Step2Mentor> createState() => _Step2MentorState();
}

class _Step2MentorState extends State<Step2Mentor> {
  static const _accent = Color(0xFF967BB6); // lavender

  final _nameController    = TextEditingController();
  final _contactController = TextEditingController();
  int? _selectedSchoolId;
  List<Map<String, dynamic>> _schools = [];
  bool _isLoading        = false;
  bool _isLoadingSchools = true;
  int  _contactLength    = 0;

  @override
  void initState() {
    super.initState();
    _loadSchools();
    _contactController.addListener(
        () => setState(() => _contactLength = _contactController.text.length));
  }

  Future<void> _loadSchools() async {
    try {
      final schools = await DBHelper.getSchools();
      final seen = <int>{};
      final unique = schools.where((s) {
        final id = int.tryParse(s['school_id'].toString() ?? '');
        if (id == null || id == 0 || !seen.add(id)) return false;
        return true;
      }).toList();
      setState(() {
        _schools = unique;
        if (!unique.any((s) =>
            int.tryParse(s['school_id'].toString()) == _selectedSchoolId)) {
          _selectedSchoolId = null;
        }
        _isLoadingSchools = false;
      });
    } catch (e) {
      setState(() => _isLoadingSchools = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Failed to load schools: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _register() async {
    final contact = _contactController.text.trim();
    if (_nameController.text.trim().isEmpty || contact.isEmpty ||
        _selectedSchoolId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields.')));
      return;
    }
    if (contact.length != 11) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('❌ Contact number must be exactly 11 digits.'),
        backgroundColor: Colors.red));
      return;
    }
    setState(() => _isLoading = true);
    try {
      final conn = await DBHelper.getConnection();
      await conn.execute(
        "INSERT INTO tbl_mentor (mentor_name, mentor_number, school_id) VALUES (:name, :number, :schoolId)",
        {"name": _nameController.text.trim(), "number": contact, "schoolId": _selectedSchoolId},
      );
      final result   = await conn.execute("SELECT LAST_INSERT_ID() as id");
      final mentorId = int.parse(result.rows.first.assoc()['LAST_INSERT_ID()'] ?? '0');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('✅ Mentor registered successfully!'),
        backgroundColor: Colors.green));
      widget.onRegistered(mentorId);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Error: $e'), backgroundColor: Colors.red));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _contactController.dispose();
    super.dispose();
  }

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
                child: RegistrationCard(
                  activeStep: 2,
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(48, 36, 48, 36),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const StepIndicator(activeStep: 2),
                            const SizedBox(height: 10),
                            const Text('MENTOR REGISTRATION',
                                style: TextStyle(color: Colors.white,
                                    fontSize: 18, fontWeight: FontWeight.w800,
                                    letterSpacing: 2)),
                            const SizedBox(height: 4),
                            Text('Register the team mentor',
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.4),
                                    fontSize: 12)),
                            const SizedBox(height: 28),
                            buildDivider(_accent),
                            const SizedBox(height: 24),

                            // Name
                            buildField(
                              label: 'MENTOR NAME', hint: 'Enter mentor name',
                              controller: _nameController,
                              icon: Icons.person_rounded,
                              accentColor: _accent, isRequired: true,
                            ),
                            const SizedBox(height: 18),

                            // Contact
                            _buildContactField(),
                            const SizedBox(height: 18),

                            // School
                            _buildSchoolDropdown(),
                            const SizedBox(height: 16),

                            buildInfoNote('If the mentor is already registered, you may skip this step.'),
                            const SizedBox(height: 28),

                            buildButtonRow(
                              onSkip: widget.onSkip,
                              onRegister: _register,
                              isLoading: _isLoading,
                              accentColor: _accent,
                              registerIcon: Icons.person_add_rounded,
                            ),
                          ],
                        ),
                      ),
                      if (widget.onBack != null)
                        Positioned(top: 12, left: 12,
                          child: IconButton(
                            icon: const Icon(Icons.arrow_back_ios_new,
                                color: _accent, size: 18),
                            onPressed: widget.onBack),
                        ),
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

  Widget _buildContactField() {
    final bool isComplete = _contactLength == 11;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('CONTACT NO.',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700,
                  fontSize: 12, letterSpacing: 1)),
          const Text(' *',
              style: TextStyle(color: _accent, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _contactController,
          keyboardType: TextInputType.phone,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(11),
          ],
          decoration: InputDecoration(
            hintText: 'e.g. 09XXXXXXXXX',
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.25), fontSize: 13),
            prefixIcon: Icon(Icons.phone_rounded,
                color: _accent.withOpacity(0.7), size: 20),
            suffixText: '$_contactLength/11',
            suffixStyle: TextStyle(
              fontSize: 12, fontWeight: FontWeight.bold,
              color: isComplete ? const Color(0xFF00E5A0) : Colors.white38,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            filled: true,
            fillColor: Colors.white.withOpacity(0.05),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                  color: isComplete
                      ? const Color(0xFF00E5A0)
                      : Colors.white.withOpacity(0.15)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                  color: isComplete ? const Color(0xFF00E5A0) : _accent,
                  width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSchoolDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('SCHOOL',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700,
                  fontSize: 12, letterSpacing: 1)),
          const Text(' *',
              style: TextStyle(color: _accent, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 8),
        _isLoadingSchools
            ? Container(
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white.withOpacity(0.15)),
                ),
                child: const Center(
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: _accent)),
              )
            : DropdownButtonFormField<int>(
                value: _selectedSchoolId,
                dropdownColor: const Color(0xFF2D0E7A),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                hint: Text('Select school',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.25), fontSize: 13)),
                icon: const Icon(Icons.keyboard_arrow_down_rounded, color: _accent),
                isExpanded: true,
                items: _schools.map((s) {
                  final id = int.tryParse(s['school_id'].toString());
                  if (id == null) return null;
                  return DropdownMenuItem<int>(
                    value: id,
                    child: Text(s['school_name'] ?? '',
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        overflow: TextOverflow.ellipsis),
                  );
                }).whereType<DropdownMenuItem<int>>().toList(),
                onChanged: (v) => setState(() => _selectedSchoolId = v),
                decoration: InputDecoration(
                  prefixIcon: Icon(Icons.school_rounded,
                      color: _accent.withOpacity(0.7), size: 20),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
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
      ],
    );
  }
}