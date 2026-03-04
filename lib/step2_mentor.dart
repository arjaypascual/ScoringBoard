import 'package:flutter/material.dart';
import 'db_helper.dart';

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
  final _nameController    = TextEditingController();
  final _contactController = TextEditingController();
  int? _selectedSchoolId;
  List<Map<String, dynamic>> _schools = [];
  bool _isLoading        = false;
  bool _isLoadingSchools = true;

  @override
  void initState() {
    super.initState();
    _loadSchools();
  }

  Future<void> _loadSchools() async {
    try {
      final schools = await DBHelper.getSchools();

      // Deduplicate by school_id to prevent dropdown assertion errors
      final seen = <int>{};
      final uniqueSchools = schools.where((s) {
        final id = int.tryParse(s['school_id'].toString() ?? '');
        if (id == null || id == 0 || !seen.add(id)) return false;
        return true;
      }).toList();

      setState(() {
        _schools          = uniqueSchools;
        if (!uniqueSchools.any((s) =>
            int.tryParse(s['school_id'].toString()) == _selectedSchoolId)) {
          _selectedSchoolId = null;
        }
        _isLoadingSchools = false;
      });
    } catch (e) {
      setState(() => _isLoadingSchools = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('❌ Failed to load schools: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _register() async {
    if (_nameController.text.trim().isEmpty ||
        _contactController.text.trim().isEmpty ||
        _selectedSchoolId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields.')),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final conn = await DBHelper.getConnection();

      await conn.execute(
        "INSERT INTO tbl_mentor (mentor_name, mentor_number, school_id) VALUES (:name, :number, :schoolId)",
        {
          "name":     _nameController.text.trim(),
          "number":   _contactController.text.trim(),
          "schoolId": _selectedSchoolId,
        },
      );

      final result   = await conn.execute("SELECT LAST_INSERT_ID() as id");
      final mentorId = int.parse(
          result.rows.first.assoc()['LAST_INSERT_ID()'] ?? '0');

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Mentor registered successfully!'),
          backgroundColor: Colors.green,
        ),
      );

      widget.onRegistered(mentorId);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('❌ Error: $e'), backgroundColor: Colors.red),
      );
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
      backgroundColor: const Color(0xFFDDDDDD),
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: Center(
              child: Container(
                width: 860,
                padding: const EdgeInsets.fromLTRB(40, 32, 40, 32),
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
                        _buildStepIndicator(),
                        const SizedBox(height: 36),

                        // Mentor Name
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _fieldLabel('MENTOR NAME:'),
                            const SizedBox(width: 16),
                            _textField(
                                hint: 'Enter mentor name',
                                controller: _nameController),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // Contact No.
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _fieldLabel('CONTACT NO.:'),
                            const SizedBox(width: 16),
                            _textField(
                              hint: 'Enter contact number',
                              controller: _contactController,
                              keyboardType: TextInputType.phone,
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // School dropdown
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _fieldLabel('SCHOOL NAME:'),
                            const SizedBox(width: 16),
                            _schoolDropdown(),
                          ],
                        ),
                        const SizedBox(height: 24),

                        const Text(
                          'Note: If the mentor is already registered, you may skip this step.',
                          style: TextStyle(
                            color: Color(0xFF3D1A8C),
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                        const SizedBox(height: 28),

                        // Buttons
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            OutlinedButton(
                              onPressed: widget.onSkip,
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(
                                    color: Color(0xFF3D1A8C), width: 2),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 44, vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                              ),
                              child: const Text('SKIP',
                                  style: TextStyle(
                                    color: Color(0xFF3D1A8C),
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1,
                                  )),
                            ),
                            const SizedBox(width: 24),
                            ElevatedButton(
                              onPressed: _isLoading ? null : _register,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00CFFF),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 44, vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                              ),
                              child: _isLoading
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white))
                                  : const Text('REGISTER',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1,
                                      )),
                            ),
                          ],
                        ),
                      ],
                    ),

                    // Back button
                    if (widget.onBack != null)
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

  // ── HEADER ──────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF2D0E7A),
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
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
                  style: TextStyle(color: Colors.white54, fontSize: 10)),
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

  // ── STEP INDICATOR ──────────────────────────────────────────────────────────
  Widget _buildStepIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        final step    = index + 1;
        final isActive = step == 2;
        final isDone   = step < 2;

        return Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive || isDone
                    ? const Color(0xFF3D1A8C)
                    : Colors.white,
                border:
                    Border.all(color: const Color(0xFF3D1A8C), width: 2),
              ),
              child: Center(
                child: isDone
                    ? const Icon(Icons.check, color: Colors.white, size: 20)
                    : Text('$step',
                        style: TextStyle(
                          color: isActive
                              ? Colors.white
                              : const Color(0xFF3D1A8C),
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        )),
              ),
            ),
            if (step < 4)
              Container(
                width: 120,
                height: 2,
                color: isDone
                    ? const Color(0xFF3D1A8C)
                    : const Color(0xFFCCCCCC),
              ),
          ],
        );
      }),
    );
  }

  // ── HELPERS ─────────────────────────────────────────────────────────────────
  Widget _fieldLabel(String text) {
    return SizedBox(
      width: 160,
      child: Text(text,
          style:
              const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
    );
  }

  Widget _textField({
    required String hint,
    required TextEditingController controller,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return SizedBox(
      width: 340,
      height: 42,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle:
              const TextStyle(color: Colors.black26, fontSize: 13),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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

  Widget _schoolDropdown() {
    if (_isLoadingSchools) {
      return const SizedBox(
        width: 340,
        height: 42,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return SizedBox(
      width: 340,
      height: 42,
      child: DropdownButtonFormField<int>(
        value: _selectedSchoolId,
        hint: const Text('Select school',
            style: TextStyle(color: Colors.black26, fontSize: 13)),
        isExpanded: true,
        items: _schools
            .map((s) {
              final id = int.tryParse(s['school_id'].toString());
              if (id == null) return null;
              return DropdownMenuItem<int>(
                value: id,
                child: Text(s['school_name'] ?? '',
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              );
            })
            .whereType<DropdownMenuItem<int>>()
            .toList(),
        onChanged: (v) => setState(() => _selectedSchoolId = v),
        decoration: InputDecoration(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
}