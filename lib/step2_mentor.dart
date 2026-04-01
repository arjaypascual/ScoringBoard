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

  // ── Validation state ──────────────────────────────────────────────────────
  String? _nameError;
  String? _contactError;
  bool    _isPresentHighlighted = false; // unused here but kept for symmetry

  @override
  void initState() {
    super.initState();
    _loadSchools();
    _contactController.addListener(() {
      setState(() {
        _contactLength = _contactController.text.length;
        // Live-clear contact error once the user starts correcting
        final t = _contactController.text;
        if (_contactError != null && t.length == 11 && t.startsWith('09')) {
          _contactError = null;
        }
      });
    });
    _nameController.addListener(() {
      setState(() {
        if (_nameError != null && _nameController.text.trim().isNotEmpty) {
          _nameError = null;
        }
      });
    });
  }

  Future<void> _loadSchools() async {
    try {
      final schools = await DBHelper.getSchools();
      final seen    = <int>{};
      final unique  = schools.where((s) {
        final id = int.tryParse(s['school_id'].toString());
        if (id == null || id == 0 || !seen.add(id)) return false;
        return true;
      }).toList();
      if (mounted) setState(() {
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

  // ── Validation helpers ────────────────────────────────────────────────────

  /// Returns true when the name is acceptable.
  /// Rules: 3–100 chars, letters / spaces / periods / hyphens only.
  bool _validateName(String value) {
    final name = value.trim();
    if (name.isEmpty) {
      _nameError = 'Mentor name is required.';
      return false;
    }
    if (name.length < 3) {
      _nameError = 'Name must be at least 3 characters.';
      return false;
    }
    if (name.length > 100) {
      _nameError = 'Name must not exceed 100 characters.';
      return false;
    }
    // Allow letters (including accented), spaces, hyphens, periods
    final validName = RegExp(r"^[a-zA-ZÀ-ÿ\s.\-]+$");
    if (!validName.hasMatch(name)) {
      _nameError = 'Name may only contain letters, spaces, hyphens, and periods.';
      return false;
    }
    _nameError = null;
    return true;
  }

  /// Returns true when the contact number is acceptable.
  /// Rules: exactly 11 digits, must start with "09".
  bool _validateContact(String value) {
    final contact = value.trim();
    if (contact.isEmpty) {
      _contactError = 'Contact number is required.';
      return false;
    }
    if (contact.length != 11) {
      _contactError = 'Contact number must be exactly 11 digits.';
      return false;
    }
    if (!contact.startsWith('09')) {
      _contactError = 'Contact number must start with 09.';
      return false;
    }
    _contactError = null;
    return true;
  }

  /// Checks the DB for an existing mentor with the same phone number.
  Future<bool> _isDuplicateContact(String contact) async {
    final conn   = await DBHelper.getConnection();
    final result = await conn.execute(
      "SELECT COUNT(*) as cnt FROM tbl_mentor WHERE mentor_number = :number",
      {"number": contact},
    );
    final cnt = int.tryParse(
        result.rows.first.assoc()['cnt']?.toString() ?? '0') ?? 0;
    return cnt > 0;
  }

  Future<void> _register() async {
    // ── Client-side validation ────────────────────────────────────────────
    final nameOk    = _validateName(_nameController.text);
    final contactOk = _validateContact(_contactController.text.trim());
    setState(() {}); // refresh error labels

    if (!nameOk || !contactOk) return;

    if (_selectedSchoolId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('❌ Please select a school.')));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final contact = _contactController.text.trim();

      // ── Duplicate phone number check ──────────────────────────────────
      if (await _isDuplicateContact(contact)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                '❌ A mentor with this contact number is already registered.'),
            backgroundColor: Colors.red));
        }
        return;
      }

      // ── Normalize name (trim + title-case) ────────────────────────────
      final rawName      = _nameController.text.trim();
      final normalizedName = rawName
          .split(' ')
          .map((w) => w.isEmpty
              ? w
              : w[0].toUpperCase() + w.substring(1).toLowerCase())
          .join(' ');

      final conn = await DBHelper.getConnection();
      await conn.execute(
        "INSERT INTO tbl_mentor (mentor_name, mentor_number, school_id) "
        "VALUES (:name, :number, :schoolId)",
        {
          "name":     normalizedName,
          "number":   contact,
          "schoolId": _selectedSchoolId,
        },
      );
      final result   = await conn.execute("SELECT LAST_INSERT_ID() as id");
      final mentorId = int.parse(
          result.rows.first.assoc()['LAST_INSERT_ID()'] ?? '0');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Mentor registered successfully!'),
          backgroundColor: Colors.green));
        widget.onRegistered(mentorId);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('❌ Error: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
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
                              label:      'MENTOR NAME',
                              hint:       'Enter mentor name',
                              controller: _nameController,
                              icon:       Icons.person_rounded,
                              accentColor: _accent,
                              isRequired: true,
                              errorText:  _nameError,
                            ),
                            const SizedBox(height: 18),

                            // Contact
                            _buildContactField(),
                            const SizedBox(height: 18),

                            // School
                            _buildSchoolDropdown(),
                            const SizedBox(height: 16),

                            buildInfoNote(
                                'If the mentor is already registered, you may skip this step.'),
                            const SizedBox(height: 28),

                            buildButtonRow(
                              onSkip:       widget.onSkip,
                              onRegister:   _register,
                              isLoading:    _isLoading,
                              accentColor:  _accent,
                              registerIcon: Icons.person_add_rounded,
                            ),
                          ],
                        ),
                      ),
                      if (widget.onBack != null)
                        Positioned(
                          top: 12, left: 12,
                          child: IconButton(
                            icon: const Icon(Icons.arrow_back_ios_new,
                                color: _accent, size: 18),
                            onPressed: widget.onBack),
                        ),
                      Positioned(
                        top: 12, right: 12,
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
    final bool hasError   = _contactError != null;
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
          controller:   _contactController,
          keyboardType: TextInputType.phone,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(11),
          ],
          decoration: InputDecoration(
            hintText: 'e.g. 09XXXXXXXXX',
            hintStyle: TextStyle(
                color: Colors.white.withOpacity(0.25), fontSize: 13),
            prefixIcon: Icon(Icons.phone_rounded,
                color: hasError
                    ? Colors.redAccent
                    : _accent.withOpacity(0.7),
                size: 20),
            suffixText: '$_contactLength/11',
            suffixStyle: TextStyle(
              fontSize: 12, fontWeight: FontWeight.bold,
              color: isComplete
                  ? const Color(0xFF00E5A0)
                  : hasError
                      ? Colors.redAccent
                      : Colors.white38,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            filled:    true,
            fillColor: Colors.white.withOpacity(0.05),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                  color: hasError
                      ? Colors.redAccent
                      : isComplete
                          ? const Color(0xFF00E5A0)
                          : Colors.white.withOpacity(0.15)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                  color: hasError
                      ? Colors.redAccent
                      : isComplete
                          ? const Color(0xFF00E5A0)
                          : _accent,
                  width: 2),
            ),
            errorText: _contactError,
            errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 11),
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
                  border:
                      Border.all(color: Colors.white.withOpacity(0.15)),
                ),
                child: const Center(
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: _accent)),
              )
            : DropdownButtonFormField<int>(
                value:         _selectedSchoolId,
                dropdownColor: const Color(0xFF2D0E7A),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                hint: Text('Select school',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.25), fontSize: 13)),
                icon: const Icon(Icons.keyboard_arrow_down_rounded,
                    color: _accent),
                isExpanded: true,
                items: _schools.map((s) {
                  final id = int.tryParse(s['school_id'].toString());
                  if (id == null) return null;
                  return DropdownMenuItem<int>(
                    value: id,
                    child: Text(s['school_name'] ?? '',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13),
                        overflow: TextOverflow.ellipsis),
                  );
                }).whereType<DropdownMenuItem<int>>().toList(),
                onChanged: (v) => setState(() => _selectedSchoolId = v),
                decoration: InputDecoration(
                  prefixIcon: Icon(Icons.school_rounded,
                      color: _accent.withOpacity(0.7), size: 20),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 14),
                  filled:    true,
                  fillColor: Colors.white.withOpacity(0.05),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide:
                        BorderSide(color: Colors.white.withOpacity(0.15)),
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