import 'package:flutter/material.dart';
import 'db_helper.dart';
import 'registration_shared.dart';

class Step4Player extends StatefulWidget {
  final int? teamId;
  final VoidCallback? onDone;
  final VoidCallback? onBack;
  final VoidCallback? onSkip;

  const Step4Player({
    super.key,
    this.teamId,
    this.onDone,
    this.onBack,
    this.onSkip,
  });

  @override
  State<Step4Player> createState() => _Step4PlayerState();
}

class _Step4PlayerState extends State<Step4Player> {
  static const _accent = Color(0xFF00E5A0); // emerald

  final _p1NameCtrl  = TextEditingController();
  final _p2NameCtrl  = TextEditingController();
  final _p1BirthCtrl = TextEditingController();
  final _p2BirthCtrl = TextEditingController();

  DateTime? _p1Birthdate;
  DateTime? _p2Birthdate;
  bool? _p1Present;
  bool? _p2Present;

  int? _selectedTeamId;
  List<Map<String, dynamic>> _teams = [];
  bool _isLoading     = false;
  bool _isLoadingData = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final teams = await DBHelper.getTeams();
      final seen  = <int>{};
      final unique = teams.where((t) {
        final id = int.tryParse(t['team_id'].toString() ?? '');
        if (id == null || id == 0 || !seen.add(id)) return false;
        return true;
      }).toList();
      setState(() {
        _teams = unique;
        if (widget.teamId != null &&
            unique.any((t) =>
                int.tryParse(t['team_id'].toString()) == widget.teamId)) {
          _selectedTeamId = widget.teamId;
        }
        _isLoadingData = false;
      });
    } catch (e) {
      setState(() => _isLoadingData = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Failed to load data: $e'),
              backgroundColor: Colors.red));
      }
    }
  }

  bool _isValidDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    try { DateTime.parse(value); return true; } catch (_) { return false; }
  }

  Future<void> _register() async {
    final p1Name  = _p1NameCtrl.text.trim();
    final p2Name  = _p2NameCtrl.text.trim();
    final p1Birth = _p1BirthCtrl.text.trim();
    final p2Birth = _p2BirthCtrl.text.trim();

    if (p1Name.isEmpty || p2Name.isEmpty || p1Birth.isEmpty || p2Birth.isEmpty ||
        _p1Present == null || _p2Present == null || _selectedTeamId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields.')));
      return;
    }
    if (!_isValidDate(p1Birth)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Player 1 birthdate must be YYYY-MM-DD format.'),
        backgroundColor: Colors.orange));
      return;
    }
    if (!_isValidDate(p2Birth)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Player 2 birthdate must be YYYY-MM-DD format.'),
        backgroundColor: Colors.orange));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final conn = await DBHelper.getConnection();
      for (final p in [
        {"name": p1Name, "birthdate": p1Birth, "present": _p1Present! ? 1 : 0},
        {"name": p2Name, "birthdate": p2Birth, "present": _p2Present! ? 1 : 0},
      ]) {
        await conn.execute(
          """INSERT INTO tbl_player (player_name, player_birthdate, player_ispresent, team_id)
             VALUES (:name, :birthdate, :present, :teamId)""",
          {...p, "teamId": _selectedTeamId},
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ Players registered successfully!'),
          backgroundColor: Colors.green));
        _showSuccessDialog();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Error: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xFF2D0E7A), Color(0xFF1E0A5A)],
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
                color: const Color(0xFF00E5A0).withOpacity(0.4), width: 1.5),
            boxShadow: [
              BoxShadow(color: const Color(0xFF00E5A0).withOpacity(0.15),
                  blurRadius: 40, spreadRadius: 4),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64, height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                      colors: [Color(0xFF00E5A0), Color(0xFF00BFA5)]),
                  boxShadow: [BoxShadow(
                      color: const Color(0xFF00E5A0).withOpacity(0.5),
                      blurRadius: 20, spreadRadius: 4)],
                ),
                child: const Icon(Icons.check_rounded,
                    color: Colors.white, size: 36),
              ),
              const SizedBox(height: 20),
              const Text('Registration Complete!',
                  style: TextStyle(color: Colors.white, fontSize: 20,
                      fontWeight: FontWeight.w800, letterSpacing: 1)),
              const SizedBox(height: 8),
              Text('All players have been successfully registered.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.6), fontSize: 13,
                      height: 1.5)),
              const SizedBox(height: 28),
              ElevatedButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  widget.onDone?.call();
                },
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
                        colors: [Color(0xFF00E5A0), Color(0xFF00BFA5)]),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [BoxShadow(
                        color: const Color(0xFF00E5A0).withOpacity(0.4),
                        blurRadius: 16, spreadRadius: 1)],
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 48, vertical: 14),
                    child: Text('DONE',
                        style: TextStyle(color: Colors.white,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2, fontSize: 14)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickDate({
    required DateTime? current,
    required void Function(DateTime) onPicked,
    required TextEditingController controller,
  }) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime(2010),
      firstDate: DateTime(1990),
      lastDate: DateTime.now(),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF00E5A0),
            onPrimary: Colors.black,
            surface: Color(0xFF2D0E7A),
            onSurface: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      onPicked(picked);
      controller.text =
          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    }
  }

  @override
  void dispose() {
    _p1NameCtrl.dispose(); _p2NameCtrl.dispose();
    _p1BirthCtrl.dispose(); _p2BirthCtrl.dispose();
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
                  activeStep: 4,
                  width: 820,
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(48, 36, 48, 36),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const StepIndicator(activeStep: 4),
                            const SizedBox(height: 10),
                            const Text('PLAYER REGISTRATION',
                                style: TextStyle(color: Colors.white,
                                    fontSize: 18, fontWeight: FontWeight.w800,
                                    letterSpacing: 2)),
                            const SizedBox(height: 4),
                            Text('Register both players for the team',
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.4),
                                    fontSize: 12)),
                            const SizedBox(height: 28),
                            buildDivider(_accent),
                            const SizedBox(height: 24),

                            // Two-column player forms
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: _buildPlayerCard(
                                  playerNum: 1,
                                  nameCtrl: _p1NameCtrl,
                                  birthCtrl: _p1BirthCtrl,
                                  birthdate: _p1Birthdate,
                                  onDatePicked: (d) => setState(() => _p1Birthdate = d),
                                  isPresent: _p1Present,
                                  onPresentChanged: (v) => setState(() => _p1Present = v),
                                )),
                                const SizedBox(width: 20),
                                Expanded(child: _buildPlayerCard(
                                  playerNum: 2,
                                  nameCtrl: _p2NameCtrl,
                                  birthCtrl: _p2BirthCtrl,
                                  birthdate: _p2Birthdate,
                                  onDatePicked: (d) => setState(() => _p2Birthdate = d),
                                  isPresent: _p2Present,
                                  onPresentChanged: (v) => setState(() => _p2Present = v),
                                )),
                              ],
                            ),
                            const SizedBox(height: 20),

                            // Team dropdown
                            _buildTeamDropdown(),
                            const SizedBox(height: 16),

                            buildInfoNote('SKIP will go directly to Generate Schedule.'),
                            const SizedBox(height: 28),

                            buildButtonRow(
                              onSkip: widget.onSkip,
                              onRegister: _register,
                              isLoading: _isLoading,
                              accentColor: _accent,
                              registerIcon: Icons.how_to_reg_rounded,
                            ),
                          ],
                        ),
                      ),
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

  Widget _buildPlayerCard({
    required int playerNum,
    required TextEditingController nameCtrl,
    required TextEditingController birthCtrl,
    required DateTime? birthdate,
    required void Function(DateTime) onDatePicked,
    required bool? isPresent,
    required void Function(bool) onPresentChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _accent.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Player header
          Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                    colors: [Color(0xFF00E5A0), Color(0xFF00BFA5)]),
                boxShadow: [BoxShadow(
                    color: _accent.withOpacity(0.4), blurRadius: 10)],
              ),
              child: Center(child: Text('$playerNum',
                  style: const TextStyle(color: Colors.black,
                      fontWeight: FontWeight.bold, fontSize: 14))),
            ),
            const SizedBox(width: 10),
            Text('PLAYER $playerNum',
                style: const TextStyle(color: _accent, fontSize: 14,
                    fontWeight: FontWeight.w800, letterSpacing: 1.5)),
          ]),
          const SizedBox(height: 16),

          // Name
          _playerField(label: 'NAME', hint: 'Enter player name',
              controller: nameCtrl, icon: Icons.person_outline_rounded),
          const SizedBox(height: 14),

          // Birthdate
          _playerLabel('BIRTHDATE'),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => _pickDate(
                current: birthdate, onPicked: onDatePicked, controller: birthCtrl),
            child: Container(
              height: 50,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: birthdate != null
                      ? _accent.withOpacity(0.5)
                      : Colors.white.withOpacity(0.15),
                ),
              ),
              child: Row(children: [
                Icon(Icons.calendar_month_rounded,
                    color: _accent.withOpacity(0.7), size: 20),
                const SizedBox(width: 10),
                Text(
                  birthdate != null
                      ? '${birthdate.year}-${birthdate.month.toString().padLeft(2, '0')}-${birthdate.day.toString().padLeft(2, '0')}'
                      : 'Select birthdate',
                  style: TextStyle(
                    color: birthdate != null
                        ? Colors.white
                        : Colors.white.withOpacity(0.3),
                    fontSize: 13,
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 14),

          // Present
          _playerLabel('PRESENT?'),
          const SizedBox(height: 8),
          Row(children: [
            _presentChip(label: 'YES', selected: isPresent == true,
                onTap: () => onPresentChanged(true)),
            const SizedBox(width: 10),
            _presentChip(label: 'NO', selected: isPresent == false,
                onTap: () => onPresentChanged(false)),
          ]),
        ],
      ),
    );
  }

  Widget _playerLabel(String text) => Text(text,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700,
          fontSize: 11, letterSpacing: 1));

  Widget _playerField({
    required String label,
    required String hint,
    required TextEditingController controller,
    required IconData icon,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _playerLabel(label),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
                color: Colors.white.withOpacity(0.25), fontSize: 12),
            prefixIcon: Icon(icon, color: _accent.withOpacity(0.7), size: 18),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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

  Widget _presentChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(
                  colors: [Color(0xFF00E5A0), Color(0xFF00BFA5)])
              : null,
          color: selected ? null : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? _accent : Colors.white.withOpacity(0.15),
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [BoxShadow(color: _accent.withOpacity(0.35),
                  blurRadius: 10, spreadRadius: 1)]
              : [],
        ),
        child: Text(label,
            style: TextStyle(
              color: selected ? Colors.black : Colors.white.withOpacity(0.4),
              fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1,
            )),
      ),
    );
  }

  Widget _buildTeamDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('TEAM',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700,
                  fontSize: 12, letterSpacing: 1)),
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
                  border: Border.all(color: Colors.white.withOpacity(0.15)),
                ),
                child: const Center(child: CircularProgressIndicator(
                    strokeWidth: 2, color: _accent)),
              )
            : DropdownButtonFormField<int>(
                value: _selectedTeamId,
                dropdownColor: const Color(0xFF2D0E7A),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                hint: Text('Select team',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.25), fontSize: 13)),
                icon: const Icon(Icons.keyboard_arrow_down_rounded,
                    color: _accent),
                isExpanded: true,
                items: _teams.map((t) {
                  final id = int.tryParse(t['team_id'].toString());
                  if (id == null) return null;
                  return DropdownMenuItem<int>(
                    value: id,
                    child: Text(t['team_name'] ?? '',
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        overflow: TextOverflow.ellipsis),
                  );
                }).whereType<DropdownMenuItem<int>>().toList(),
                onChanged: (v) => setState(() => _selectedTeamId = v),
                decoration: InputDecoration(
                  prefixIcon: Icon(Icons.groups_rounded,
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