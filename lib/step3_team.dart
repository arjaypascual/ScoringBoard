import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'db_helper.dart';
import 'registration_shared.dart';

class Step3Team extends StatefulWidget {
  final VoidCallback onSkip;
  final void Function(int teamId) onRegistered;
  final VoidCallback? onBack;

  const Step3Team({
    super.key,
    required this.onSkip,
    required this.onRegistered,
    this.onBack,
  });

  @override
  State<Step3Team> createState() => _Step3TeamState();
}

class _Step3TeamState extends State<Step3Team> {
  static const _accent = Color(0xFFFFD700); // gold

  final _nameController = TextEditingController();
  bool? _isPresent;
  int?  _selectedCategoryId;
  int?  _selectedMentorId;
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _mentors    = [];
  bool _isLoading     = false;
  bool _isLoadingData = true;

  // ── Validation state ──────────────────────────────────────────────────────
  String? _nameError;
  bool    _presentError = false; // highlights the YES/NO toggle when unset

  @override
  void initState() {
    super.initState();
    _loadData();
    _nameController.addListener(() {
      final v = _nameController.text.trim();
      if (_nameError != null && v.isNotEmpty && v.length <= 80) {
        setState(() => _nameError = null);
      }
      // Enforce max length silently — prevents pasting oversized input
      if (_nameController.text.length > 80) {
        final trimmed = _nameController.text.substring(0, 80);
        _nameController.value = _nameController.value.copyWith(
          text: trimmed,
          selection: TextSelection.collapsed(offset: trimmed.length),
        );
      }
    });
  }

  Future<void> _loadData() async {
    try {
      // ── Use only active categories in the dropdown ────────────────────
      final categories   = await DBHelper.getActiveCategories();
      final conn         = await DBHelper.getConnection();
      final mentorResult = await conn.execute(
          "SELECT mentor_id, mentor_name FROM tbl_mentor ORDER BY mentor_name");
      final mentors = mentorResult.rows.map((r) => r.assoc()).toList();

      final seenCat = <int>{};
      final uniqueCat = categories.where((c) {
        final id = int.tryParse(c['category_id'].toString());
        if (id == null || id == 0 || !seenCat.add(id)) return false;
        return true;
      }).toList();

      final seenMen = <int>{};
      final uniqueMen = mentors.where((m) {
        final id = int.tryParse(m['mentor_id'].toString());
        if (id == null || id == 0 || !seenMen.add(id)) return false;
        return true;
      }).toList();

      if (mounted) setState(() {
        _categories = uniqueCat;
        _mentors    = uniqueMen;
        if (!uniqueCat.any((c) =>
            int.tryParse(c['category_id'].toString()) == _selectedCategoryId))
          _selectedCategoryId = null;
        if (!uniqueMen.any((m) =>
            int.tryParse(m['mentor_id'].toString()) == _selectedMentorId))
          _selectedMentorId = null;
        _isLoadingData = false;
      });
    } catch (e) {
      setState(() => _isLoadingData = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('❌ Failed to load data: $e'),
              backgroundColor: Colors.red));
      }
    }
  }

  // ── Validation helpers ────────────────────────────────────────────────────

  /// Returns true when the team name is acceptable.
  /// Rules: 2–80 chars, must not be blank.
  bool _validateName(String value) {
    final name = value.trim();
    if (name.isEmpty) {
      _nameError = 'Team name is required.';
      return false;
    }
    if (name.length < 2) {
      _nameError = 'Team name must be at least 2 characters.';
      return false;
    }
    if (name.length > 80) {
      _nameError = 'Team name must not exceed 80 characters.';
      return false;
    }
    _nameError = null;
    return true;
  }

  /// Returns true when no other team with the same name exists in the same category.
  Future<bool> _isDuplicateTeam(String name, int categoryId) async {
    final conn   = await DBHelper.getConnection();
    final result = await conn.execute(
      "SELECT COUNT(*) as cnt FROM tbl_team "
      "WHERE LOWER(TRIM(team_name)) = LOWER(TRIM(:name)) "
      "AND category_id = :categoryId",
      {"name": name, "categoryId": categoryId},
    );
    final cnt = int.tryParse(
        result.rows.first.assoc()['cnt']?.toString() ?? '0') ?? 0;
    return cnt > 0;
  }

  Future<void> _register() async {
    // ── Client-side validation ────────────────────────────────────────────
    final nameOk = _validateName(_nameController.text);

    // Present toggle: highlight if nothing selected
    final bool presentOk = _isPresent != null;
    setState(() {
      _presentError = !presentOk;
    });

    if (!nameOk || !presentOk) return;

    if (_selectedCategoryId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Please select a category.')));
      return;
    }
    if (_selectedMentorId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Please select a mentor.')));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final name = _nameController.text.trim();

      // ── Duplicate team name within the same category ──────────────────
      if (await _isDuplicateTeam(name, _selectedCategoryId!)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '❌ A team named "$name" already exists in this category.'),
            backgroundColor: Colors.red));
        }
        return;
      }

      final conn = await DBHelper.getConnection();
      await conn.execute(
        """INSERT INTO tbl_team (team_name, team_ispresent, mentor_id, category_id)
           VALUES (:name, :present, :mentorId, :categoryId)""",
        {
          "name":       name,
          "present":    _isPresent! ? 1 : 0,
          "mentorId":   _selectedMentorId,
          "categoryId": _selectedCategoryId,
        },
      );
      final result = await conn.execute("SELECT LAST_INSERT_ID() as id");
      final teamId = int.parse(
          result.rows.first.assoc()['LAST_INSERT_ID()'] ?? '0');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Team registered successfully!'),
          backgroundColor: Colors.green));
        widget.onRegistered(teamId);
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
                  activeStep: 3,
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(48, 36, 48, 36),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const StepIndicator(activeStep: 3),
                            const SizedBox(height: 10),
                            const Text('TEAM REGISTRATION',
                                style: TextStyle(color: Colors.white,
                                    fontSize: 18, fontWeight: FontWeight.w800,
                                    letterSpacing: 2)),
                            const SizedBox(height: 4),
                            Text('Register your competing team',
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.4),
                                    fontSize: 12)),
                            const SizedBox(height: 28),
                            buildDivider(_accent),
                            const SizedBox(height: 24),

                            // Team Name
                            buildField(
                              label:       'TEAM NAME',
                              hint:        'Enter team name',
                              controller:  _nameController,
                              icon:        Icons.groups_rounded,
                              accentColor: _accent,
                              isRequired:  true,
                              errorText:   _nameError,
                            ),
                            const SizedBox(height: 18),

                            // Present toggle
                            _buildPresentToggle(),
                            const SizedBox(height: 18),

                            // Category
                            _buildDropdown(
                              label: 'CATEGORY',
                              icon:  Icons.category_rounded,
                              hint:  'Select category',
                              value: _selectedCategoryId,
                              items: _categories.map((c) {
                                final id = int.tryParse(
                                    c['category_id'].toString());
                                if (id == null) return null;
                                return DropdownMenuItem<int>(
                                  value: id,
                                  child: Text(c['category_type'] ?? '',
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 13)));
                              }).whereType<DropdownMenuItem<int>>().toList(),
                              onChanged: (v) =>
                                  setState(() => _selectedCategoryId = v),
                            ),
                            const SizedBox(height: 18),

                            // Mentor
                            _buildDropdown(
                              label: 'MENTOR',
                              icon:  Icons.person_rounded,
                              hint:  'Select mentor',
                              value: _selectedMentorId,
                              items: _mentors.map((m) {
                                final id = int.tryParse(
                                    m['mentor_id'].toString());
                                if (id == null) return null;
                                return DropdownMenuItem<int>(
                                  value: id,
                                  child: Text(m['mentor_name'] ?? '',
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 13),
                                      overflow: TextOverflow.ellipsis));
                              }).whereType<DropdownMenuItem<int>>().toList(),
                              onChanged: (v) =>
                                  setState(() => _selectedMentorId = v),
                            ),
                            const SizedBox(height: 16),

                            buildInfoNote(
                                'If the team is already registered, you may skip this step.'),
                            const SizedBox(height: 28),

                            buildButtonRow(
                              onSkip:       widget.onSkip,
                              onRegister:   _register,
                              isLoading:    _isLoading,
                              accentColor:  _accent,
                              registerIcon: Icons.group_add_rounded,
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

  Widget _buildPresentToggle() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('PRESENT?',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700,
                  fontSize: 12, letterSpacing: 1)),
          const Text(' *',
              style: TextStyle(color: _accent, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 8),
        Row(
          children: [
            _toggleChip(
                label:    'YES',
                selected: _isPresent == true,
                hasError: _presentError,
                onTap: () => setState(() {
                  _isPresent    = true;
                  _presentError = false;
                })),
            const SizedBox(width: 12),
            _toggleChip(
                label:    'NO',
                selected: _isPresent == false,
                hasError: _presentError,
                onTap: () => setState(() {
                  _isPresent    = false;
                  _presentError = false;
                })),
          ],
        ),
        // Error hint shown when neither option is selected and Register was tapped
        if (_presentError) ...[
          const SizedBox(height: 6),
          const Text('Please select YES or NO.',
              style: TextStyle(color: Colors.redAccent, fontSize: 11)),
        ],
      ],
    );
  }

  Widget _toggleChip({
    required String label,
    required bool   selected,
    required bool   hasError,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(
                  colors: [Color(0xFFFFD700), Color(0xFFFFA500)])
              : null,
          color: selected ? null : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? const Color(0xFFFFD700)
                : hasError
                    ? Colors.redAccent
                    : Colors.white.withOpacity(0.15),
            width: selected || hasError ? 2 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                      color: const Color(0xFFFFD700).withOpacity(0.35),
                      blurRadius:  12,
                      spreadRadius: 1)
                ]
              : [],
        ),
        child: Text(label,
            style: TextStyle(
              color: selected
                  ? Colors.black
                  : hasError
                      ? Colors.redAccent
                      : Colors.white.withOpacity(0.5),
              fontWeight: FontWeight.bold,
              fontSize:   13,
              letterSpacing: 1,
            )),
      ),
    );
  }

  Widget _buildDropdown({
    required String label,
    required IconData icon,
    required String hint,
    required int? value,
    required List<DropdownMenuItem<int>> items,
    required void Function(int?) onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text(label,
              style: const TextStyle(color: Colors.white,
                  fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 1)),
          const Text(' *',
              style: TextStyle(color: _accent, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 8),
        _isLoadingData
            ? Container(
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: Colors.white.withOpacity(0.15)),
                ),
                child: const Center(child: CircularProgressIndicator(
                    strokeWidth: 2, color: _accent)),
              )
            : DropdownButtonFormField<int>(
                value:         value,
                dropdownColor: const Color(0xFF2D0E7A),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                hint: Text(hint,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.25), fontSize: 13)),
                icon: const Icon(Icons.keyboard_arrow_down_rounded,
                    color: _accent),
                isExpanded: true,
                items:     items,
                onChanged: onChanged,
                decoration: InputDecoration(
                  prefixIcon: Icon(icon,
                      color: const Color(0xFFFFD700).withOpacity(0.7),
                      size:  20),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 14),
                  filled:    true,
                  fillColor: Colors.white.withOpacity(0.05),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                        color: Colors.white.withOpacity(0.15)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide:
                        const BorderSide(color: _accent, width: 2),
                  ),
                ),
              ),
      ],
    );
  }
}