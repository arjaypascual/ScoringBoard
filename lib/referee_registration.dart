import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'db_helper.dart';
import 'registration_shared.dart';

class RefereeRegistrationPage extends StatefulWidget {
  final VoidCallback? onBack;
  final VoidCallback? onDone;

  const RefereeRegistrationPage({super.key, this.onBack, this.onDone});

  @override
  State<RefereeRegistrationPage> createState() =>
      _RefereeRegistrationPageState();
}

class _RefereeRegistrationPageState extends State<RefereeRegistrationPage> {
  static const _accent    = Color(0xFF00E5A0);
  static const _bg        = Color(0xFF0D0625);
  static const _cardBg    = Color(0xFF130840);

  List<Map<String, dynamic>> _referees   = [];
  List<Map<String, dynamic>> _categories = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final refs  = await DBHelper.getReferees();
    final cats  = await DBHelper.getCategories();
    setState(() {
      _referees   = refs;
      _categories = cats;
      _loading    = false;
    });
  }

  void _snack(String msg, Color color) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));

  // ── Initials badge ─────────────────────────────────────────────────────────
  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
  }

  // ── Open add/edit dialog ───────────────────────────────────────────────────
  Future<void> _openDialog({Map<String, dynamic>? existing}) async {
    final nameCtrl    = TextEditingController(text: existing?['referee_name'] ?? '');
    final contactCtrl = TextEditingController(text: existing?['contact'] ?? '');

    // Load currently assigned categories for this referee
    final Set<int> selected = {};
    if (existing != null) {
      final id   = int.tryParse(existing['referee_id'].toString()) ?? 0;
      final cats = await DBHelper.getRefereeCategories(id);
      selected.addAll(cats.map((c) => int.tryParse(c['category_id'].toString()) ?? 0));
    }

    if (!mounted) return;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _RefereeDialog(
        existing:      existing,
        nameCtrl:      nameCtrl,
        contactCtrl:   contactCtrl,
        categories:    _categories,
        initialSelected: selected,
      ),
    );

    if (result != true) return;

    final name    = nameCtrl.text.trim();
    final contact = contactCtrl.text.trim();

    if (name.isEmpty) { _snack('Referee name is required.', Colors.red); return; }
    if (contact.isNotEmpty && contact.length != 11) {
      _snack('Contact number must be exactly 11 digits.', Colors.red);
      return;
    }

    try {
      int refereeId;
      if (existing == null) {
        refereeId = await DBHelper.insertReferee(name, contact);
      } else {
        refereeId = int.tryParse(existing['referee_id'].toString()) ?? 0;
        await DBHelper.updateReferee(refereeId, name, contact);
      }
      await DBHelper.setRefereeCategories(refereeId, selected.toList());
      await _load();
      if (mounted) _snack('✅ Referee saved!', Colors.green);
    } catch (e) {
      if (mounted) _snack('Error: $e', Colors.red);
    }
  }

  // ── Delete ─────────────────────────────────────────────────────────────────
  Future<void> _delete(Map<String, dynamic> ref) async {
    final id   = int.tryParse(ref['referee_id'].toString()) ?? 0;
    final name = ref['referee_name'] ?? '';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E0A5A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Referee?',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text('Remove "$name"? This cannot be undone.',
            style: TextStyle(color: Colors.white.withOpacity(0.6))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel',
                  style: TextStyle(color: Colors.white.withOpacity(0.4)))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('DELETE',
                  style: TextStyle(color: Colors.redAccent,
                      fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (ok != true) return;
    await DBHelper.deleteReferee(id);
    await _load();
    if (mounted) _snack('Referee deleted.', Colors.orange);
  }

  // ── Show access code dialog ────────────────────────────────────────────────
  Future<void> _showAccessCodes(Map<String, dynamic> ref) async {
    final id   = int.tryParse(ref['referee_id'].toString()) ?? 0;
    final cats = await DBHelper.getRefereeCategories(id);
    if (!mounted) return;

    // Load access codes for each assigned category
    final List<Map<String, dynamic>> codesInfo = [];
    for (final c in cats) {
      final catId   = int.tryParse(c['category_id'].toString()) ?? 0;
      final catName = c['category_type']?.toString() ?? '';
      final code    = await DBHelper.getCategoryAccessCode(catId);
      codesInfo.add({'name': catName, 'code': code ?? '—'});
    }

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 420,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [Color(0xFF2D0E7A), Color(0xFF1E0A5A)]),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _accent.withOpacity(0.4), width: 1.5)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Container(padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(shape: BoxShape.circle,
                    color: _accent.withOpacity(0.12),
                    border: Border.all(color: _accent.withOpacity(0.4))),
                child: const Icon(Icons.key_rounded, color: _accent, size: 18)),
              const SizedBox(width: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('ACCESS CODES',
                    style: TextStyle(color: Colors.white, fontSize: 16,
                        fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                Text('For ${ref['referee_name']}',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.4), fontSize: 11)),
              ]),
              const Spacer(),
              IconButton(icon: Icon(Icons.close,
                  color: Colors.white.withOpacity(0.35), size: 18),
                  onPressed: () => Navigator.pop(ctx)),
            ]),

            const SizedBox(height: 18),
            Container(height: 1,
                color: _accent.withOpacity(0.2)),
            const SizedBox(height: 16),

            if (codesInfo.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text('No categories assigned to this referee.',
                    style: TextStyle(color: Colors.white.withOpacity(0.4),
                        fontSize: 13)),
              )
            else
              ...codesInfo.map((info) => Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 13),
                decoration: BoxDecoration(
                  color: _accent.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _accent.withOpacity(0.2))),
                child: Row(children: [
                  const Icon(Icons.category_rounded,
                      size: 14, color: _accent),
                  const SizedBox(width: 10),
                  Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(info['name'],
                        style: const TextStyle(color: Colors.white,
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text('Access Code',
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.35),
                            fontSize: 10)),
                  ])),
                  // Code pill
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: _accent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _accent.withOpacity(0.45))),
                    child: Text(info['code'],
                        style: const TextStyle(
                            color: _accent, fontSize: 18,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2)),
                  ),
                  const SizedBox(width: 8),
                  // Copy button
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(
                          ClipboardData(text: info['code']));
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Code copied!'),
                              duration: Duration(seconds: 1)));
                    },
                    child: Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white12)),
                      child: const Icon(Icons.copy_rounded,
                          size: 14, color: Colors.white38)),
                  ),
                ]),
              )),

            const SizedBox(height: 8),
            Text('Referees enter this code in the scoring app\nto unlock their assigned category.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withOpacity(0.3),
                    fontSize: 10, height: 1.5)),
          ]),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(children: [
        const RegistrationHeader(),

        // ── Sub-header ───────────────────────────────────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [Color(0xFF1A0550), Color(0xFF2D0E7A)]),
            border: Border(bottom: BorderSide(
                color: _accent.withOpacity(0.3), width: 1))),
          child: Row(children: [
            IconButton(
              icon: Icon(Icons.arrow_back_ios_new,
                  color: _accent, size: 18),
              onPressed: widget.onBack),
            const SizedBox(width: 8),
            Container(padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: _accent.withOpacity(0.1),
                  border: Border.all(color: _accent.withOpacity(0.3))),
              child: const Icon(Icons.sports_rounded,
                  color: _accent, size: 18)),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('REFEREE REGISTRATION',
                  style: TextStyle(color: Colors.white, fontSize: 18,
                      fontWeight: FontWeight.w900, letterSpacing: 2)),
              Text('Manage referees & assign categories',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.4), fontSize: 11)),
            ]),
            const Spacer(),

            // Total count
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: _accent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _accent.withOpacity(0.4))),
              child: Text('${_referees.length} TOTAL',
                  style: TextStyle(color: _accent, fontSize: 11,
                      fontWeight: FontWeight.bold, letterSpacing: 1)),
            ),
            const SizedBox(width: 12),

            // Add button
            ElevatedButton.icon(
              onPressed: () => _openDialog(),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('ADD REFEREE',
                  style: TextStyle(fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(
                    horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            ),
          ]),
        ),

        // ── Content ─────────────────────────────────────────────────────────
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(
                  color: _accent))
              : _referees.isEmpty
                  ? _emptyState()
                  : _refereeList(),
        ),
      ]),
    );
  }

  Widget _emptyState() => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(width: 80, height: 80,
        decoration: BoxDecoration(shape: BoxShape.circle,
            color: _accent.withOpacity(0.08),
            border: Border.all(color: _accent.withOpacity(0.2))),
        child: const Icon(Icons.sports_rounded,
            color: _accent, size: 36)),
      const SizedBox(height: 20),
      const Text('No Referees Yet',
          style: TextStyle(color: Colors.white, fontSize: 18,
              fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text('Add your first referee to get started.',
          style: TextStyle(color: Colors.white.withOpacity(0.4),
              fontSize: 13)),
    ]),
  );

  Widget _refereeList() => SingleChildScrollView(
    padding: const EdgeInsets.all(28),
    child: Column(children: [

      // Table header
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [Color(0xFF1E0A5A), Color(0xFF130840)]),
          borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const SizedBox(width: 48),
          const SizedBox(width: 12),
          Expanded(flex: 4, child: _hdr('REFEREE NAME')),
          Expanded(flex: 3, child: _hdr('CONTACT')),
          Expanded(flex: 4, child: _hdr('CATEGORIES')),
          _hdr('ACTIONS', flex: 0),
          const SizedBox(width: 8),
        ]),
      ),
      const SizedBox(height: 6),

      // Rows
      ..._referees.asMap().entries.map((e) {
        final idx = e.key;
        final ref = e.value;
        return _refereeRow(ref, idx);
      }),
    ]),
  );

  Widget _refereeRow(Map<String, dynamic> ref, int idx) {
    final name    = ref['referee_name']?.toString() ?? '';
    final contact = ref['contact']?.toString() ?? '';

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: DBHelper.getRefereeCategories(
          int.tryParse(ref['referee_id'].toString()) ?? 0),
      builder: (ctx, snap) {
        final cats = snap.data ?? [];
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: idx % 2 == 0
                ? _cardBg
                : const Color(0xFF0F0630),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withOpacity(0.06))),
          child: Row(children: [
            // Avatar
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: _accent.withOpacity(0.12),
                  border: Border.all(color: _accent.withOpacity(0.4))),
              child: Center(child: Text(_initials(name),
                  style: TextStyle(color: _accent, fontSize: 13,
                      fontWeight: FontWeight.w900)))),
            const SizedBox(width: 12),

            // Name
            Expanded(flex: 4, child: Text(name,
                style: const TextStyle(color: Colors.white,
                    fontSize: 14, fontWeight: FontWeight.w600))),

            // Contact
            Expanded(flex: 3, child: Text(
                contact.isEmpty ? '—' : contact,
                style: TextStyle(
                    color: contact.isEmpty
                        ? Colors.white24 : Colors.white60,
                    fontSize: 13))),

            // Categories chips
            Expanded(flex: 4, child: cats.isEmpty
                ? Text('None assigned',
                    style: TextStyle(
                        color: Colors.white24, fontSize: 12,
                        fontStyle: FontStyle.italic))
                : Wrap(spacing: 5, runSpacing: 4,
                    children: cats.map((c) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _accent.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: _accent.withOpacity(0.35))),
                      child: Text(c['category_type']?.toString() ?? '',
                          style: TextStyle(color: _accent,
                              fontSize: 10,
                              fontWeight: FontWeight.bold)),
                    )).toList())),

            // Actions
            Row(mainAxisSize: MainAxisSize.min, children: [
              // Key (access codes)
              _iconBtn(icon: Icons.key_rounded, color: _accent,
                  onTap: () => _showAccessCodes(ref),
                  tooltip: 'View Access Codes'),
              const SizedBox(width: 6),
              // Edit
              _iconBtn(icon: Icons.edit_rounded,
                  color: Colors.white54,
                  onTap: () => _openDialog(existing: ref),
                  tooltip: 'Edit'),
              const SizedBox(width: 6),
              // Delete
              _iconBtn(icon: Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                  onTap: () => _delete(ref),
                  tooltip: 'Delete'),
            ]),
          ]),
        );
      },
    );
  }

  Widget _hdr(String text, {int flex = 1}) => Text(text,
      style: const TextStyle(color: Colors.white38,
          fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1));

  Widget _iconBtn({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    required String tooltip,
  }) =>
      Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: color.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withOpacity(0.25))),
            child: Icon(icon, size: 15, color: color)),
        ),
      );
}

// ══════════════════════════════════════════════════════════════════════════════
// ADD / EDIT DIALOG
// ══════════════════════════════════════════════════════════════════════════════
class _RefereeDialog extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final TextEditingController nameCtrl;
  final TextEditingController contactCtrl;
  final List<Map<String, dynamic>> categories;
  final Set<int> initialSelected;

  const _RefereeDialog({
    required this.existing,
    required this.nameCtrl,
    required this.contactCtrl,
    required this.categories,
    required this.initialSelected,
  });

  @override
  State<_RefereeDialog> createState() => _RefereeDialogState();
}

class _RefereeDialogState extends State<_RefereeDialog> {
  static const _accent = Color(0xFF00E5A0);
  late final Set<int> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set.from(widget.initialSelected);
  }

  bool get _isEdit => widget.existing != null;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 500,
        constraints: const BoxConstraints(maxHeight: 700),
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xFF2D0E7A), Color(0xFF1E0A5A)]),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _accent.withOpacity(0.35), width: 1.5),
          boxShadow: [BoxShadow(color: _accent.withOpacity(0.08),
              blurRadius: 40, spreadRadius: 4)]),
        child: Column(mainAxisSize: MainAxisSize.min, children: [

          // Header
          Row(children: [
            Container(padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: _accent.withOpacity(0.12),
                  border: Border.all(color: _accent.withOpacity(0.4))),
              child: const Icon(Icons.sports_rounded,
                  color: _accent, size: 18)),
            const SizedBox(width: 12),
            Text(_isEdit ? 'EDIT REFEREE' : 'NEW REFEREE',
                style: const TextStyle(color: Colors.white, fontSize: 17,
                    fontWeight: FontWeight.w800, letterSpacing: 1.5)),
            const Spacer(),
            IconButton(
              icon: Icon(Icons.close,
                  color: Colors.white.withOpacity(0.35), size: 18),
              onPressed: () => Navigator.pop(context, false)),
          ]),

          const SizedBox(height: 22),

          // Referee Name
          _fieldLabel('REFEREE NAME'),
          const SizedBox(height: 6),
          _textField(controller: widget.nameCtrl,
              hint: 'e.g. Juan dela Cruz'),

          const SizedBox(height: 16),

          // Contact — max 11 digits
          Row(children: [
            _fieldLabel('CONTACT'),
            const SizedBox(width: 6),
            Text('(max 11 digits)',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.3),
                    fontSize: 9, fontStyle: FontStyle.italic)),
          ]),
          const SizedBox(height: 6),
          _textField(
            controller: widget.contactCtrl,
            hint: 'e.g. 09123456789',
            inputType: TextInputType.phone,
            maxLength: 11,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(11),
            ],
          ),

          const SizedBox(height: 20),

          // Assign categories
          _fieldLabel('ASSIGN CATEGORIES'),
          const SizedBox(height: 10),

          Flexible(child: SingleChildScrollView(
            child: Column(children: widget.categories.map((cat) {
              final id      = int.tryParse(cat['category_id'].toString()) ?? 0;
              final name    = cat['category_type']?.toString() ?? '';
              final active  = (cat['status'] ?? 'active').toString() == 'active';
              final checked = _selected.contains(id);

              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: checked
                      ? _accent.withOpacity(0.07)
                      : Colors.white.withOpacity(0.03),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: checked
                        ? _accent.withOpacity(0.4)
                        : Colors.white.withOpacity(0.08))),
                child: ListTile(
                  dense: true,
                  leading: Container(
                    width: 10, height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: active
                          ? _accent : Colors.white24)),
                  title: Text(name,
                      style: TextStyle(
                        color: active ? Colors.white : Colors.white38,
                        fontSize: 13, fontWeight: FontWeight.w600)),
                  subtitle: active
                      ? null
                      : Text('Inactive',
                          style: TextStyle(
                              color: Colors.white24, fontSize: 10,
                              fontStyle: FontStyle.italic)),
                  trailing: Switch(
                    value: checked,
                    onChanged: active
                        ? (v) => setState(() {
                              if (v) _selected.add(id);
                              else   _selected.remove(id);
                            })
                        : null,
                    activeColor: _accent,
                    inactiveThumbColor: Colors.white24,
                    inactiveTrackColor: Colors.white12,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              );
            }).toList()),
          )),

          const SizedBox(height: 22),

          // Buttons
          Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => Navigator.pop(context, false),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.white.withOpacity(0.2)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
              child: Text('CANCEL',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.45),
                      fontWeight: FontWeight.bold)))),
            const SizedBox(width: 12),
            Expanded(child: ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
              child: Ink(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    _accent,
                    Color.lerp(_accent, Colors.black, 0.25)!,
                  ]),
                  borderRadius: BorderRadius.circular(10)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(child: Text(
                      _isEdit ? 'SAVE CHANGES' : 'ADD REFEREE',
                      style: const TextStyle(color: Colors.black,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1))))))),
          ]),
        ]),
      ),
    );
  }

  Widget _fieldLabel(String text) => Align(
    alignment: Alignment.centerLeft,
    child: Text(text, style: const TextStyle(
        color: Color(0xFF00E5A0), fontSize: 10,
        fontWeight: FontWeight.bold, letterSpacing: 1)),
  );

  Widget _textField({
    required TextEditingController controller,
    required String hint,
    TextInputType? inputType,
    int? maxLength,
    List<TextInputFormatter>? inputFormatters,
  }) =>
      TextField(
        controller: controller,
        keyboardType: inputType,
        maxLength: maxLength,
        inputFormatters: inputFormatters,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.25),
              fontSize: 13),
          counterStyle: TextStyle(
              color: Colors.white.withOpacity(0.35), fontSize: 10),
          filled: true,
          fillColor: Colors.white.withOpacity(0.05),
          contentPadding: const EdgeInsets.symmetric(
              horizontal: 16, vertical: 13),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
                color: Colors.white.withOpacity(0.15))),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(
                color: Color(0xFF00E5A0), width: 1.5)),
        ),
      );
}