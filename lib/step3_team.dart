import 'package:flutter/material.dart';
import 'db_helper.dart';

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
  final _nameController = TextEditingController();
  bool? _isPresent;
  int? _selectedCategoryId;
  int? _selectedMentorId;
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _mentors    = [];
  bool _isLoading     = false;
  bool _isLoadingData = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final categories = await DBHelper.getCategories();
      final conn       = await DBHelper.getConnection();
      final mentorResult = await conn.execute(
        "SELECT mentor_id, mentor_name FROM tbl_mentor ORDER BY mentor_name"
      );
      final mentors = mentorResult.rows.map((r) => r.assoc()).toList();

      // Deduplicate by ID to prevent dropdown assertion errors
      final seenCat = <int>{};
      final uniqueCategories = categories.where((c) {
        final id = int.tryParse(c['category_id'].toString() ?? '');
        if (id == null || id == 0 || !seenCat.add(id)) return false;
        return true;
      }).toList();

      final seenMen = <int>{};
      final uniqueMentors = mentors.where((m) {
        final id = int.tryParse(m['mentor_id'].toString() ?? '');
        if (id == null || id == 0 || !seenMen.add(id)) return false;
        return true;
      }).toList();

      setState(() {
        _categories    = uniqueCategories;
        _mentors       = uniqueMentors;
        // Reset selections if they no longer exist in the new list
        if (!uniqueCategories.any((c) =>
            int.tryParse(c['category_id'].toString()) == _selectedCategoryId)) {
          _selectedCategoryId = null;
        }
        if (!uniqueMentors.any((m) =>
            int.tryParse(m['mentor_id'].toString()) == _selectedMentorId)) {
          _selectedMentorId = null;
        }
        _isLoadingData = false;
      });
    } catch (e) {
      setState(() => _isLoadingData = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('❌ Failed to load data: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _register() async {
    if (_nameController.text.trim().isEmpty ||
        _isPresent == null ||
        _selectedCategoryId == null ||
        _selectedMentorId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields.')),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final conn = await DBHelper.getConnection();

      await conn.execute(
        """INSERT INTO tbl_team (team_name, team_ispresent, mentor_id, category_id)
           VALUES (:name, :present, :mentorId, :categoryId)""",
        {
          "name":       _nameController.text.trim(),
          "present":    _isPresent! ? 1 : 0,
          "mentorId":   _selectedMentorId,
          "categoryId": _selectedCategoryId,
        },
      );

      final result = await conn.execute("SELECT LAST_INSERT_ID() as id");
      final teamId = int.parse(
          result.rows.first.assoc()['LAST_INSERT_ID()'] ?? '0');

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Team registered successfully!'),
          backgroundColor: Colors.green,
        ),
      );

      widget.onRegistered(teamId);
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

                        // Team Name
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _fieldLabel('TEAM NAME:'),
                            const SizedBox(width: 16),
                            _textField(
                                hint: 'Enter team name',
                                controller: _nameController),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // Present?
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _fieldLabel('PRESENT?'),
                            const SizedBox(width: 16),
                            SizedBox(
                              width: 340,
                              child: Row(
                                children: [
                                  GestureDetector(
                                    onTap: () =>
                                        setState(() => _isPresent = true),
                                    child: Row(children: [
                                      Checkbox(
                                        value: _isPresent == true,
                                        onChanged: (_) => setState(
                                            () => _isPresent = true),
                                        activeColor:
                                            const Color(0xFF3D1A8C),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(3)),
                                      ),
                                      const Text('YES',
                                          style: TextStyle(
                                              fontWeight:
                                                  FontWeight.bold)),
                                    ]),
                                  ),
                                  const SizedBox(width: 24),
                                  GestureDetector(
                                    onTap: () =>
                                        setState(() => _isPresent = false),
                                    child: Row(children: [
                                      Checkbox(
                                        value: _isPresent == false,
                                        onChanged: (_) => setState(
                                            () => _isPresent = false),
                                        activeColor:
                                            const Color(0xFF3D1A8C),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(3)),
                                      ),
                                      const Text('NO',
                                          style: TextStyle(
                                              fontWeight:
                                                  FontWeight.bold)),
                                    ]),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // Category
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _fieldLabel('CATEGORY:'),
                            const SizedBox(width: 16),
                            _isLoadingData
                                ? const SizedBox(
                                    width: 340,
                                    height: 42,
                                    child: Center(
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2)))
                                : SizedBox(
                                    width: 340,
                                    height: 42,
                                    child: DropdownButtonFormField<int>(
                                      value: _selectedCategoryId,
                                      hint: const Text('Choose category',
                                          style: TextStyle(
                                              color: Colors.black26,
                                              fontSize: 13)),
                                      isExpanded: true,
                                      items: _categories
                                          .map((c) {
                                            final id = int.tryParse(
                                                c['category_id'].toString());
                                            if (id == null) return null;
                                            return DropdownMenuItem<int>(
                                              value: id,
                                              child: Text(
                                                  c['category_type'] ?? '',
                                                  style: const TextStyle(
                                                      fontSize: 13)),
                                            );
                                          })
                                          .whereType<DropdownMenuItem<int>>()
                                          .toList(),
                                      onChanged: (v) => setState(
                                          () => _selectedCategoryId = v),
                                      decoration: InputDecoration(
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                                horizontal: 14,
                                                vertical: 10),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          borderSide: const BorderSide(
                                              color: Color(0xFFAAAAAA)),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          borderSide: const BorderSide(
                                              color: Color(0xFF3D1A8C),
                                              width: 2),
                                        ),
                                      ),
                                    ),
                                  ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // Mentor
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _fieldLabel('MENTOR NAME:'),
                            const SizedBox(width: 16),
                            _isLoadingData
                                ? const SizedBox(
                                    width: 340,
                                    height: 42,
                                    child: Center(
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2)))
                                : SizedBox(
                                    width: 340,
                                    height: 42,
                                    child: DropdownButtonFormField<int>(
                                      value: _selectedMentorId,
                                      hint: const Text('Select mentor',
                                          style: TextStyle(
                                              color: Colors.black26,
                                              fontSize: 13)),
                                      isExpanded: true,
                                      items: _mentors
                                          .map((m) {
                                            final id = int.tryParse(
                                                m['mentor_id'].toString());
                                            if (id == null) return null;
                                            return DropdownMenuItem<int>(
                                              value: id,
                                              child: Text(
                                                  m['mentor_name'] ?? '',
                                                  style: const TextStyle(
                                                      fontSize: 13),
                                                  overflow:
                                                      TextOverflow.ellipsis),
                                            );
                                          })
                                          .whereType<DropdownMenuItem<int>>()
                                          .toList(),
                                      onChanged: (v) => setState(
                                          () => _selectedMentorId = v),
                                      decoration: InputDecoration(
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                                horizontal: 14,
                                                vertical: 10),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          borderSide: const BorderSide(
                                              color: Color(0xFFAAAAAA)),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          borderSide: const BorderSide(
                                              color: Color(0xFF3D1A8C),
                                              width: 2),
                                        ),
                                      ),
                                    ),
                                  ),
                          ],
                        ),
                        const SizedBox(height: 24),

                        const Text(
                          'Note: If the team is already registered, you may skip this step.',
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
                                    borderRadius:
                                        BorderRadius.circular(8)),
                              ),
                              child: const Text('SKIP',
                                  style: TextStyle(
                                      color: Color(0xFF3D1A8C),
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1)),
                            ),
                            const SizedBox(width: 24),
                            ElevatedButton(
                              onPressed: _isLoading ? null : _register,
                              style: ElevatedButton.styleFrom(
                                backgroundColor:
                                    const Color(0xFF00CFFF),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 44, vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(8)),
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
                                          letterSpacing: 1)),
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
                        onPressed: () =>
                            Navigator.of(context).maybePop(),
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

  // ── STEP INDICATOR ──────────────────────────────────────────────────────────
  Widget _buildStepIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        final step    = index + 1;
        final isActive = step == 3;
        final isDone   = step < 3;

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
                    ? const Icon(Icons.check,
                        color: Colors.white, size: 20)
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
          style: const TextStyle(
              fontWeight: FontWeight.w900, fontSize: 14)),
    );
  }

  Widget _textField(
      {required String hint,
      required TextEditingController controller}) {
    return SizedBox(
      width: 340,
      height: 42,
      child: TextField(
        controller: controller,
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
}