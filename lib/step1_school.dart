import 'package:flutter/material.dart';
import 'db_helper.dart';

class Step1School extends StatefulWidget {
  final VoidCallback onSkip;
  final void Function(int schoolId) onRegistered;
  final VoidCallback? onBack;

  const Step1School({
    super.key,
    required this.onSkip,
    required this.onRegistered,
    this.onBack,
  });

  @override
  State<Step1School> createState() => _Step1SchoolState();
}

class _Step1SchoolState extends State<Step1School> {
  final _nameController   = TextEditingController();
  final _campusController = TextEditingController();
  String? _selectedRegion;
  bool _isLoading = false;

  final List<String> _regions = [
    'NCR - National Capital Region',
    'CAR - Cordillera Administrative Region',
    'Region I - Ilocos Region',
    'Region II - Cagayan Valley',
    'Region III - Central Luzon',
    'Region IV-A - CALABARZON',
    'Region IV-B - MIMAROPA',
    'Region V - Bicol Region',
    'Region VI - Western Visayas',
    'Region VII - Central Visayas',
    'Region VIII - Eastern Visayas',
    'Region IX - Zamboanga Peninsula',
    'Region X - Northern Mindanao',
    'Region XI - Davao Region',
    'Region XII - SOCCSKSARGEN',
    'Region XIII - Caraga',
    'BARMM - Bangsamoro',
  ];

  Future<void> _register() async {
    final name   = _nameController.text.trim();
    final campus = _campusController.text.trim();

    if (name.isEmpty || _selectedRegion == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in School Name and Region.')),
      );
      return;
    }

    final fullName = campus.isNotEmpty ? '$name - $campus' : name;

    setState(() => _isLoading = true);
    try {
      final conn = await DBHelper.getConnection();

      // ── Duplicate check ──────────────────────────────────────────
      final checkResult = await conn.execute(
        "SELECT COUNT(*) as cnt FROM tbl_school WHERE school_name = :name",
        {"name": fullName},
      );
      final count = int.tryParse(
              checkResult.rows.first.assoc()['cnt']?.toString() ?? '0') ??
          0;

      if (count > 0) {
        final label = campus.isNotEmpty
            ? '"$name" with campus "$campus"'
            : '"$name"';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '❌ School $label is already registered. Use a different campus or skip.'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
        setState(() => _isLoading = false);
        return;
      }

      // ── Insert ───────────────────────────────────────────────────
      await conn.execute(
        "INSERT INTO tbl_school (school_name, school_region) VALUES (:name, :region)",
        {"name": fullName, "region": _selectedRegion},
      );

      final result   = await conn.execute("SELECT LAST_INSERT_ID() as id");
      final schoolId = int.parse(
          result.rows.first.assoc()['LAST_INSERT_ID()'] ?? '0');

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ School registered successfully!'),
          backgroundColor: Colors.green,
        ),
      );
      widget.onRegistered(schoolId);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _campusController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A0A4A),
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Container(
                  width: 680,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF2D0E7A), Color(0xFF1E0A5A)],
                    ),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                        color: const Color(0xFF00CFFF).withOpacity(0.3),
                        width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF00CFFF).withOpacity(0.08),
                        blurRadius: 40,
                        spreadRadius: 4,
                      ),
                      BoxShadow(
                        color: Colors.black.withOpacity(0.4),
                        blurRadius: 30,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(48, 36, 48, 36),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildStepIndicator(),
                            const SizedBox(height: 10),
                            const Text(
                              'SCHOOL REGISTRATION',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Register your school to continue',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.4),
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 28),

                            // Gradient divider
                            Container(
                              height: 1,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(colors: [
                                  Colors.transparent,
                                  const Color(0xFF00CFFF).withOpacity(0.4),
                                  Colors.transparent,
                                ]),
                              ),
                            ),
                            const SizedBox(height: 24),

                            // School Name
                            _buildField(
                              label: 'SCHOOL NAME',
                              hint: 'Enter school name',
                              controller: _nameController,
                              icon: Icons.school_rounded,
                              isRequired: true,
                            ),
                            const SizedBox(height: 18),

                            // Campus
                            _buildField(
                              label: 'CAMPUS',
                              hint: 'e.g. Main, Annex, Branch',
                              controller: _campusController,
                              icon: Icons.location_city_rounded,
                              isOptional: true,
                            ),
                            const SizedBox(height: 18),

                            // Region
                            _buildRegionField(),
                            const SizedBox(height: 16),

                            // Live preview
                            AnimatedBuilder(
                              animation: Listenable.merge(
                                  [_nameController, _campusController]),
                              builder: (_, __) {
                                final name   = _nameController.text.trim();
                                final campus = _campusController.text.trim();
                                if (name.isEmpty) return const SizedBox.shrink();
                                final preview = campus.isNotEmpty
                                    ? '$name - $campus'
                                    : name;
                                return Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF00CFFF).withOpacity(0.08),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: const Color(0xFF00CFFF).withOpacity(0.25)),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.preview_rounded,
                                          color: Color(0xFF00CFFF), size: 15),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'Will be saved as:  "$preview"',
                                          style: const TextStyle(
                                            color: Color(0xFF00CFFF),
                                            fontSize: 12,
                                            fontStyle: FontStyle.italic,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                            const SizedBox(height: 10),

                            // Info note
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFD700).withOpacity(0.06),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: const Color(0xFFFFD700).withOpacity(0.20)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.info_outline_rounded,
                                      color: Color(0xFFFFD700), size: 15),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'If the school is already registered, skip this step. '
                                      'Campus is optional — use it to differentiate branches of the same school.',
                                      style: TextStyle(
                                        color: const Color(0xFFFFD700).withOpacity(0.85),
                                        fontSize: 11,
                                        height: 1.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 28),

                            // Buttons
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: widget.onSkip,
                                    style: OutlinedButton.styleFrom(
                                      side: BorderSide(
                                          color: Colors.white.withOpacity(0.2),
                                          width: 1.5),
                                      padding: const EdgeInsets.symmetric(vertical: 16),
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(10)),
                                    ),
                                    child: Text(
                                      'SKIP',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.55),
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.5,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  flex: 2,
                                  child: ElevatedButton(
                                    onPressed: _isLoading ? null : _register,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.transparent,
                                      shadowColor: Colors.transparent,
                                      padding: EdgeInsets.zero,
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(10)),
                                    ),
                                    child: Ink(
                                      decoration: BoxDecoration(
                                        gradient: const LinearGradient(
                                          colors: [Color(0xFF00CFFF), Color(0xFF0099CC)],
                                        ),
                                        borderRadius: BorderRadius.circular(10),
                                        boxShadow: [
                                          BoxShadow(
                                            color: const Color(0xFF00CFFF).withOpacity(0.35),
                                            blurRadius: 16,
                                            spreadRadius: 1,
                                          ),
                                        ],
                                      ),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 16),
                                        alignment: Alignment.center,
                                        child: _isLoading
                                            ? const SizedBox(
                                                width: 20, height: 20,
                                                child: CircularProgressIndicator(
                                                    strokeWidth: 2, color: Colors.white),
                                              )
                                            : const Row(
                                                mainAxisAlignment: MainAxisAlignment.center,
                                                children: [
                                                  Icon(Icons.app_registration_rounded,
                                                      color: Colors.white, size: 18),
                                                  SizedBox(width: 8),
                                                  Text('REGISTER',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontWeight: FontWeight.bold,
                                                        letterSpacing: 1.5,
                                                        fontSize: 13,
                                                      )),
                                                ],
                                              ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      if (widget.onBack != null)
                        Positioned(
                          top: 12, left: 12,
                          child: IconButton(
                            icon: const Icon(Icons.arrow_back_ios_new,
                                color: Color(0xFF00CFFF), size: 18),
                            onPressed: widget.onBack,
                          ),
                        ),

                      Positioned(
                        top: 12, right: 12,
                        child: IconButton(
                          icon: Icon(Icons.close,
                              color: Colors.white.withOpacity(0.35), size: 20),
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
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A0550), Color(0xFF2D0E7A), Color(0xFF1A0A4A)],
        ),
        border: const Border(
            bottom: BorderSide(color: Color(0xFF00CFFF), width: 1.5)),
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF00CFFF).withOpacity(0.12),
              blurRadius: 16,
              offset: const Offset(0, 4)),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left: Makeblock badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: const Color(0xFF00CFFF).withOpacity(0.35), width: 1.5),
              gradient: LinearGradient(colors: [
                const Color(0xFF00CFFF).withOpacity(0.12),
                const Color(0xFF00CFFF).withOpacity(0.04),
              ]),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: const BoxDecoration(
                      shape: BoxShape.circle, color: Color(0xFF00CFFF)),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RichText(
                      text: const TextSpan(children: [
                        TextSpan(text: 'Make',
                            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                        TextSpan(text: 'bl',
                            style: TextStyle(color: Color(0xFF00CFFF), fontSize: 18, fontWeight: FontWeight.bold)),
                        TextSpan(text: 'ock',
                            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                      ]),
                    ),
                    const Text('Construct Your Dreams',
                        style: TextStyle(color: Colors.white38, fontSize: 9, letterSpacing: 1)),
                  ],
                ),
              ],
            ),
          ),

          // Center: logo
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: const Color(0xFF7B2FFF).withOpacity(0.35), blurRadius: 24, spreadRadius: 4),
                BoxShadow(color: const Color(0xFF00CFFF).withOpacity(0.15), blurRadius: 16, spreadRadius: 2),
              ],
            ),
            child: Image.asset('assets/images/CenterLogo.png', height: 70, fit: BoxFit.contain),
          ),

          // Right: CREOTEC badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.30), width: 1.5),
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [
                const Color(0xFFFFD700).withOpacity(0.10),
                const Color(0xFFFFD700).withOpacity(0.03),
              ]),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text('CREOTEC',
                    style: TextStyle(color: Colors.white, fontSize: 22,
                        fontWeight: FontWeight.w900, letterSpacing: 4, height: 1.0)),
                const SizedBox(height: 3),
                Text('P H I L I P P I N E S ,  I N C .',
                    style: TextStyle(color: const Color(0xFFFFD700).withOpacity(0.75),
                        fontSize: 8, fontWeight: FontWeight.w600, letterSpacing: 2.5, height: 1.0)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── STEP INDICATOR ──────────────────────────────────────────────────────────
  Widget _buildStepIndicator() {
    final labels = ['School', 'Mentor', 'Team', 'Players'];
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        final step     = index + 1;
        final isActive = step == 1;
        final isDone   = step < 1;
        return Row(
          children: [
            Column(
              children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: isActive
                        ? const LinearGradient(
                            colors: [Color(0xFF00CFFF), Color(0xFF0099CC)])
                        : null,
                    color: !isActive ? Colors.white.withOpacity(0.08) : null,
                    border: Border.all(
                      color: isActive
                          ? const Color(0xFF00CFFF)
                          : Colors.white.withOpacity(0.2),
                      width: 2,
                    ),
                    boxShadow: isActive
                        ? [BoxShadow(
                            color: const Color(0xFF00CFFF).withOpacity(0.5),
                            blurRadius: 16, spreadRadius: 2)]
                        : [],
                  ),
                  child: Center(
                    child: isDone
                        ? const Icon(Icons.check, color: Colors.white, size: 20)
                        : Text('$step',
                            style: TextStyle(
                              color: isActive ? Colors.white : Colors.white.withOpacity(0.3),
                              fontWeight: FontWeight.bold, fontSize: 16,
                            )),
                  ),
                ),
                const SizedBox(height: 6),
                Text(labels[index],
                    style: TextStyle(
                      color: isActive ? const Color(0xFF00CFFF) : Colors.white.withOpacity(0.3),
                      fontSize: 10,
                      fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                      letterSpacing: 0.5,
                    )),
              ],
            ),
            if (step < 4)
              Container(
                width: 80, height: 2,
                margin: const EdgeInsets.only(bottom: 20),
                color: isDone
                    ? const Color(0xFF00CFFF)
                    : Colors.white.withOpacity(0.1),
              ),
          ],
        );
      }),
    );
  }

  // ── FIELD BUILDER ────────────────────────────────────────────────────────────
  Widget _buildField({
    required String label,
    required String hint,
    required TextEditingController controller,
    required IconData icon,
    bool isRequired = false,
    bool isOptional = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700,
                    fontSize: 12, letterSpacing: 1)),
            if (isRequired)
              const Text(' *', style: TextStyle(color: Color(0xFF00CFFF), fontWeight: FontWeight.bold)),
            if (isOptional)
              Text('  (optional)',
                  style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 11)),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.25), fontSize: 13),
            prefixIcon: Icon(icon, color: const Color(0xFF00CFFF).withOpacity(0.7), size: 20),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            filled: true,
            fillColor: Colors.white.withOpacity(0.05),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.15)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF00CFFF), width: 2),
            ),
          ),
        ),
      ],
    );
  }

  // ── REGION FIELD ─────────────────────────────────────────────────────────────
  Widget _buildRegionField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('SCHOOL REGION',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700,
                    fontSize: 12, letterSpacing: 1)),
            const Text(' *',
                style: TextStyle(color: Color(0xFF00CFFF), fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _selectedRegion,
          dropdownColor: const Color(0xFF2D0E7A),
          style: const TextStyle(color: Colors.white, fontSize: 13),
          hint: Text('Select region',
              style: TextStyle(color: Colors.white.withOpacity(0.25), fontSize: 13)),
          icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF00CFFF)),
          items: _regions.map((r) => DropdownMenuItem(
            value: r,
            child: Text(r, style: const TextStyle(color: Colors.white, fontSize: 13)),
          )).toList(),
          onChanged: (v) => setState(() => _selectedRegion = v),
          decoration: InputDecoration(
            prefixIcon: Icon(Icons.map_rounded,
                color: const Color(0xFF00CFFF).withOpacity(0.7), size: 20),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            filled: true,
            fillColor: Colors.white.withOpacity(0.05),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.15)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF00CFFF), width: 2),
            ),
          ),
        ),
      ],
    );
  }
}