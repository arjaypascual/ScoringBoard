import 'package:flutter/material.dart';
import 'db_helper.dart';

class Step1School extends StatefulWidget {
  final VoidCallback onSkip;
  final void Function(int schoolId) onRegistered;

  const Step1School({super.key, required this.onSkip, required this.onRegistered});

  @override
  State<Step1School> createState() => _Step1SchoolState();
}

class _Step1SchoolState extends State<Step1School> {
  final _nameController = TextEditingController();
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
    if (_nameController.text.trim().isEmpty || _selectedRegion == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields.')),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final conn = await DBHelper.getConnection();

      // Insert school
      await conn.execute(
        "INSERT INTO tbl_school (school_name, school_region) VALUES (:name, :region)",
        {
          "name": _nameController.text.trim(),
          "region": _selectedRegion,
        },
      );

      // Get the new school ID
      final result = await conn.execute("SELECT LAST_INSERT_ID() as id");
      final schoolId = int.parse(
        result.rows.first.assoc()['LAST_INSERT_ID()'] ?? '0',
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ School registered successfully!'),
          backgroundColor: Colors.green,
        ),
      );

      // Go to next step
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFDDDDDD),
      body: Column(
        children: [
          // ── HEADER ──
          _buildHeader(),

          // ── FORM CARD ──
          Expanded(
            child: Center(
              child: Container(
                width: 860,
                padding: const EdgeInsets.fromLTRB(40, 32, 40, 32),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF3D1A8C), width: 2),
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
                        // Step indicator
                        _buildStepIndicator(),
                        const SizedBox(height: 36),

                        // School Name field
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _fieldLabel('SCHOOL NAME:'),
                            const SizedBox(width: 16),
                            _textField(
                              hint: 'Enter school name',
                              controller: _nameController,
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // School Region dropdown
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _fieldLabel('SCHOOL REGION:'),
                            const SizedBox(width: 16),
                            _regionDropdown(),
                          ],
                        ),
                        const SizedBox(height: 24),

                        // Note
                        const Text(
                          'Note: If the school is already registered, you may skip this step.',
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
                            // SKIP
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
                              child: const Text(
                                'SKIP',
                                style: TextStyle(
                                  color: Color(0xFF3D1A8C),
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                            const SizedBox(width: 24),

                            // REGISTER
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
                                          color: Colors.white),
                                    )
                                  : const Text(
                                      'REGISTER',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1,
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ],
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
      color: const Color(0xFF967BB6),
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Makeblock
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: const TextSpan(
                  children: [
                    TextSpan(
                      text: 'Make',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold),
                    ),
                    TextSpan(
                      text: 'bl',
                      style: TextStyle(
                          color: Color(0xFF00CFFF),
                          fontSize: 22,
                          fontWeight: FontWeight.bold),
                    ),
                    TextSpan(
                      text: 'ock',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              const Text(
                'Construct Your Dreams',
                style: TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ],
          ),

          // Center logo
          Image.asset(
            'assets/images/CenterLogo.png',
            height: 100,
            fit: BoxFit.contain,
          ),

          // CREOTEC
          const Text(
            'CREOTEC',
            style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 3),
          ),
        ],
      ),
    );
  }

  // ── STEP INDICATOR ──────────────────────────────────────────────────────────
  Widget _buildStepIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        final step = index + 1;
        final isActive = step == 1;

        return Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive ? const Color(0xFF3D1A8C) : Colors.white,
                border: Border.all(color: const Color(0xFF3D1A8C), width: 2),
              ),
              child: Center(
                child: Text(
                  '$step',
                  style: TextStyle(
                    color: isActive ? Colors.white : const Color(0xFF3D1A8C),
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            if (step < 4)
              Container(
                width: 120,
                height: 2,
                color: const Color(0xFFCCCCCC),
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
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
      ),
    );
  }

  Widget _textField({
    required String hint,
    required TextEditingController controller,
  }) {
    return SizedBox(
      width: 340,
      height: 42,
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Colors.black26, fontSize: 13),
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

  Widget _regionDropdown() {
    return SizedBox(
      width: 340,
      height: 42,
      child: DropdownButtonFormField<String>(
        value: _selectedRegion,
        hint: const Text('Select region',
            style: TextStyle(color: Colors.black26, fontSize: 13)),
        items: _regions
            .map((r) => DropdownMenuItem(
                  value: r,
                  child: Text(r, style: const TextStyle(fontSize: 13)),
                ))
            .toList(),
        onChanged: (v) => setState(() => _selectedRegion = v),
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