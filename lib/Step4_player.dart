import 'package:flutter/material.dart';
import 'db_helper.dart';

class Step4Player extends StatefulWidget {
  final int? teamId;
  final VoidCallback? onDone;
  final VoidCallback? onBack;

  const Step4Player({
    super.key,
    this.teamId,
    this.onDone,
    this.onBack,
  });

  @override
  State<Step4Player> createState() => _Step4PlayerState();
}

class _Step4PlayerState extends State<Step4Player> {
  // ── Controllers & State ──────────────────────────────────────────────────────
  final _player1NameController = TextEditingController();
  final _player2NameController = TextEditingController();
  final _player1BirthdateController = TextEditingController();
  final _player2BirthdateController = TextEditingController();

  bool? _player1IsPresent;
  bool? _player2IsPresent;

  int? _selectedTeamId;
  List<Map<String, dynamic>> _teams = [];

  bool _isLoading = false;
  bool _isLoadingData = true;

  // ── Lifecycle ────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final teams = await DBHelper.getTeams();
      setState(() {
        _teams = teams;
        // Pre-select team from previous step if provided
        if (widget.teamId != null) {
          _selectedTeamId = widget.teamId;
        }
        _isLoadingData = false;
      });
    } catch (e) {
      setState(() => _isLoadingData = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Failed to load data: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ── Validation helpers ───────────────────────────────────────────────────────
  bool _isValidDate(String value) {
    // Accepts YYYY-MM-DD
    final regex = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    if (!regex.hasMatch(value)) return false;
    try {
      DateTime.parse(value);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Register action ──────────────────────────────────────────────────────────
  Future<void> _register() async {
    final p1Name = _player1NameController.text.trim();
    final p2Name = _player2NameController.text.trim();
    final p1Birth = _player1BirthdateController.text.trim();
    final p2Birth = _player2BirthdateController.text.trim();

    // Validation
    if (p1Name.isEmpty ||
        p2Name.isEmpty ||
        p1Birth.isEmpty ||
        p2Birth.isEmpty ||
        _player1IsPresent == null ||
        _player2IsPresent == null ||
        _selectedTeamId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields.')),
      );
      return;
    }

    if (!_isValidDate(p1Birth)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Player 1 birthdate must be in YYYY-MM-DD format.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (!_isValidDate(p2Birth)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Player 2 birthdate must be in YYYY-MM-DD format.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final conn = await DBHelper.getConnection();

      // Insert Player 1
      await conn.execute(
        """INSERT INTO tbl_player
             (player_name, player_birthdate, player_ispresent, team_id)
           VALUES (:name, :birthdate, :present, :teamId)""",
        {
          "name": p1Name,
          "birthdate": p1Birth,
          "present": _player1IsPresent! ? 1 : 0,
          "teamId": _selectedTeamId,
        },
      );

      // Insert Player 2
      await conn.execute(
        """INSERT INTO tbl_player
             (player_name, player_birthdate, player_ispresent, team_id)
           VALUES (:name, :birthdate, :present, :teamId)""",
        {
          "name": p2Name,
          "birthdate": p2Birth,
          "present": _player2IsPresent! ? 1 : 0,
          "teamId": _selectedTeamId,
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Players registered successfully!'),
            backgroundColor: Colors.green,
          ),
        );

        // Show completion dialog
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 28),
                SizedBox(width: 10),
                Text(
                  'Registration Complete!',
                  style: TextStyle(
                    color: Color(0xFF3D1A8C),
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ],
            ),
            content: const Text(
              'All players have been successfully registered.\nYou may now close this window.',
              style: TextStyle(fontSize: 14),
            ),
            actions: [
              ElevatedButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  widget.onDone?.call();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00CFFF),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                ),
                child: const Text(
                  'DONE',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Dispose ──────────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _player1NameController.dispose();
    _player2NameController.dispose();
    _player1BirthdateController.dispose();
    _player2BirthdateController.dispose();
    super.dispose();
  }

  // ── Build ────────────────────────────────────────────────────────────────────
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
                width: 900,
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
                        _buildStepIndicator(),
                        const SizedBox(height: 32),

                        // ── Two-column player form ──────────────────────────
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Player 1 column
                            _buildPlayerColumn(
                              label: 'PLAYER 1 NAME:',
                              nameController: _player1NameController,
                              birthdateController: _player1BirthdateController,
                              isPresent: _player1IsPresent,
                              onPresentChanged: (v) =>
                                  setState(() => _player1IsPresent = v),
                            ),

                            const SizedBox(width: 40),

                            // Player 2 column
                            _buildPlayerColumn(
                              label: 'PLAYER 2 NAME:',
                              nameController: _player2NameController,
                              birthdateController: _player2BirthdateController,
                              isPresent: _player2IsPresent,
                              onPresentChanged: (v) =>
                                  setState(() => _player2IsPresent = v),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),

                        // ── Team Name dropdown ──────────────────────────────
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _fieldLabel('TEAM NAME:'),
                            const SizedBox(width: 16),
                            _isLoadingData
                                ? const SizedBox(
                                    width: 340,
                                    height: 42,
                                    child: Center(
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    ),
                                  )
                                : SizedBox(
                                    width: 340,
                                    height: 42,
                                    child: DropdownButtonFormField<int>(
                                      value: _selectedTeamId,
                                      hint: const Text(
                                        'Select team',
                                        style: TextStyle(
                                            color: Colors.black26,
                                            fontSize: 13),
                                      ),
                                      isExpanded: true,
                                      items: _teams.map((t) {
                                        return DropdownMenuItem<int>(
                                          value: int.tryParse(
                                              t['team_id'].toString()),
                                          child: Text(
                                            t['team_name'] ?? '',
                                            style: const TextStyle(
                                                fontSize: 13),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        );
                                      }).toList(),
                                      onChanged: (v) =>
                                          setState(() => _selectedTeamId = v),
                                      decoration: InputDecoration(
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                                horizontal: 14, vertical: 10),
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
                        const SizedBox(height: 32),

                        // ── Register button ─────────────────────────────────
                        ElevatedButton(
                          onPressed: _isLoading ? null : _register,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00CFFF),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 56, vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
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

                    // ── Back button ───────────────────────────────────────
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

                    // ── Close button ──────────────────────────────────────────
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

  // ── Player column builder ────────────────────────────────────────────────────
  Widget _buildPlayerColumn({
    required String label,
    required TextEditingController nameController,
    required TextEditingController birthdateController,
    required bool? isPresent,
    required void Function(bool) onPresentChanged,
  }) {
    return SizedBox(
      width: 340,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Name
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
          ),
          const SizedBox(height: 8),
          _textField(hint: 'Enter player name', controller: nameController),
          const SizedBox(height: 16),

          // Birthdate
          const Text(
            'BIRTHDATE:',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
          ),
          const SizedBox(height: 8),
          _textField(hint: 'YYYY-MM-DD', controller: birthdateController),
          const SizedBox(height: 16),

          // Present?
          const Text(
            'PRESENT?',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              // YES
              GestureDetector(
                onTap: () => onPresentChanged(true),
                child: Row(
                  children: [
                    Checkbox(
                      value: isPresent == true,
                      onChanged: (_) => onPresentChanged(true),
                      activeColor: const Color(0xFF3D1A8C),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const Text('YES',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // NO
              GestureDetector(
                onTap: () => onPresentChanged(false),
                child: Row(
                  children: [
                    Checkbox(
                      value: isPresent == false,
                      onChanged: (_) => onPresentChanged(false),
                      activeColor: const Color(0xFF3D1A8C),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const Text('NO',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Header ───────────────────────────────────────────────────────────────────
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
                text: const TextSpan(
                  children: [
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
                  ],
                ),
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

  // ── Step Indicator ───────────────────────────────────────────────────────────
  Widget _buildStepIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        final step = index + 1;
        final isActive = step == 4;
        final isDone = step < 4;

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
                    : Text(
                        '$step',
                        style: TextStyle(
                          color: isActive
                              ? Colors.white
                              : const Color(0xFF3D1A8C),
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
                color: isDone
                    ? const Color(0xFF3D1A8C)
                    : const Color(0xFFCCCCCC),
              ),
          ],
        );
      }),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────
  Widget _fieldLabel(String text) {
    return SizedBox(
      width: 160,
      child: Text(
        text,
        style:
            const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
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