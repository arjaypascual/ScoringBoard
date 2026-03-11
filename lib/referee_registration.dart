import 'package:flutter/material.dart';
import 'db_helper.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────────────────

class RefereeCategory {
  final int    categoryId;
  final String categoryType;

  const RefereeCategory({
    required this.categoryId,
    required this.categoryType,
  });

  factory RefereeCategory.fromMap(Map<String, dynamic> m) => RefereeCategory(
        categoryId:   int.parse(m['category_id'].toString()),
        categoryType: m['category_type'].toString(),
      );
}

class Referee {
  final int?   refereeId;
  final String refereeName;
  final String contact;
  final List<RefereeCategory> categories;

  const Referee({
    this.refereeId,
    required this.refereeName,
    required this.contact,
    this.categories = const [],
  });

  factory Referee.fromMap(Map<String, dynamic> m) => Referee(
        refereeId:   int.parse(m['referee_id'].toString()),
        refereeName: m['referee_name'].toString(),
        contact:     (m['contact'] ?? '').toString(),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// DB  — uses conn.execute() + named params to match your DBHelper
// ─────────────────────────────────────────────────────────────────────────────

class _RefereeDB {

  // ── Fetch active categories from tbl_category ─────────────────────────────
  static Future<List<RefereeCategory>> fetchCategories() async {
    final conn   = await DBHelper.getConnection();
    final result = await conn.execute(
      "SELECT * FROM tbl_category WHERE status = 'active' ORDER BY category_type",
    );
    return result.rows
        .map((r) => RefereeCategory.fromMap(r.assoc()))
        .toList();
  }

  // ── Fetch all referees + their assigned categories ────────────────────────
  static Future<List<Referee>> fetchReferees() async {
    final conn    = await DBHelper.getConnection();
    final allCats = await fetchCategories();
    final catMap  = {for (final c in allCats) c.categoryId: c};

    final refResult = await conn.execute(
      "SELECT * FROM tbl_referee ORDER BY referee_id",
    );
    final rows = refResult.rows.map((r) => r.assoc()).toList();

    final List<Referee> result = [];
    for (final row in rows) {
      final ref = Referee.fromMap(row);

      final catResult = await conn.execute(
        "SELECT category_id FROM tbl_referee_category WHERE referee_id = :rid",
        {"rid": ref.refereeId},
      );
      final cats = catResult.rows
          .map((r) => catMap[int.parse(r.assoc()['category_id'].toString())])
          .whereType<RefereeCategory>()
          .toList();

      result.add(Referee(
        refereeId:   ref.refereeId,
        refereeName: ref.refereeName,
        contact:     ref.contact,
        categories:  cats,
      ));
    }
    return result;
  }

  // ── Insert new referee ────────────────────────────────────────────────────
  static Future<int> insertReferee(String name, String contact) async {
    final conn   = await DBHelper.getConnection();
    final result = await conn.execute(
      "INSERT INTO tbl_referee (referee_name, contact) VALUES (:name, :contact)",
      {"name": name, "contact": contact},
    );
    return result.lastInsertID.toInt();
  }

  // ── Update existing referee ───────────────────────────────────────────────
  static Future<void> updateReferee(int id, String name, String contact) async {
    final conn = await DBHelper.getConnection();
    await conn.execute(
      "UPDATE tbl_referee SET referee_name = :name, contact = :contact WHERE referee_id = :id",
      {"name": name, "contact": contact, "id": id},
    );
  }

  // ── Set category assignments (delete then re-insert) ──────────────────────
  static Future<void> setCategories(int refereeId, List<int> catIds) async {
    final conn = await DBHelper.getConnection();
    await conn.execute(
      "DELETE FROM tbl_referee_category WHERE referee_id = :rid",
      {"rid": refereeId},
    );
    for (final cid in catIds) {
      await conn.execute(
        "INSERT INTO tbl_referee_category (referee_id, category_id) VALUES (:rid, :cid)",
        {"rid": refereeId, "cid": cid},
      );
    }
  }

  // ── Delete referee ────────────────────────────────────────────────────────
  static Future<void> deleteReferee(int id) async {
    final conn = await DBHelper.getConnection();
    await conn.execute(
      "DELETE FROM tbl_referee WHERE referee_id = :id",
      {"id": id},
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Page
// ─────────────────────────────────────────────────────────────────────────────

class RefereeRegistrationPage extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onDone;

  const RefereeRegistrationPage({
    super.key,
    required this.onBack,
    required this.onDone,
  });

  @override
  State<RefereeRegistrationPage> createState() =>
      _RefereeRegistrationPageState();
}

class _RefereeRegistrationPageState extends State<RefereeRegistrationPage> {
  List<Referee>         _referees   = [];
  List<RefereeCategory> _categories = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final cats = await _RefereeDB.fetchCategories();
      final refs = await _RefereeDB.fetchReferees();
      setState(() {
        _categories = cats;
        _referees   = refs;
        _loading    = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      _snack('Load failed: $e', const Color(0xFFFF6B6B));
    }
  }

  Future<void> _openForm({Referee? existing}) async {
    await showDialog(
      context: context,
      builder: (_) => _RefereeFormDialog(
        categories: _categories,
        existing:   existing,
        onSave: (name, contact, selectedCatIds) async {
          if (existing == null) {
            final newId = await _RefereeDB.insertReferee(name, contact);
            await _RefereeDB.setCategories(newId, selectedCatIds);
          } else {
            await _RefereeDB.updateReferee(
                existing.refereeId!, name, contact);
            await _RefereeDB.setCategories(
                existing.refereeId!, selectedCatIds);
          }
          await _load();
        },
      ),
    );
  }

  Future<void> _delete(Referee r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(name: r.refereeName),
    );
    if (ok == true) {
      await _RefereeDB.deleteReferee(r.refereeId!);
      await _load();
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: color.withOpacity(0.92),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: Text(msg,
          style: const TextStyle(
              color: Colors.black87, fontWeight: FontWeight.bold)),
      duration: const Duration(seconds: 2),
    ));
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0630),
      body: Column(children: [
        _buildHeader(),
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFF00FF9C)))
              : _referees.isEmpty
                  ? _EmptyState(onAdd: () => _openForm())
                  : _buildTable(),
        ),
      ]),
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A0550), Color(0xFF2D0E7A), Color(0xFF1A0A4A)],
        ),
        border: Border(
            bottom: BorderSide(color: Color(0xFF00FF9C), width: 1.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      child: Row(children: [
        IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: Color(0xFF00FF9C), size: 18),
          onPressed: widget.onBack,
        ),
        const SizedBox(width: 6),
        const Icon(Icons.sports_rounded,
            color: Color(0xFF00FF9C), size: 22),
        const SizedBox(width: 10),
        const Text('REFEREE REGISTRATION',
            style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w900,
                letterSpacing: 3)),
        const Spacer(),
        if (_referees.isNotEmpty) ...[
          _Chip('${_referees.length} TOTAL', const Color(0xFF00CFFF)),
          const SizedBox(width: 16),
        ],
        _GlowButton(
          label: '+  ADD REFEREE',
          color: const Color(0xFF00FF9C),
          onTap: () => _openForm(),
        ),
      ]),
    );
  }

  // ── Table ──────────────────────────────────────────────────────────────────
  Widget _buildTable() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: const [
            SizedBox(width: 44),
            SizedBox(width: 12),
            Expanded(flex: 3, child: _ColLabel('REFEREE NAME')),
            Expanded(flex: 3, child: _ColLabel('CONTACT')),
            Expanded(flex: 5, child: _ColLabel('ASSIGNED CATEGORIES')),
            SizedBox(width: 80, child: _ColLabel('ACTIONS')),
          ]),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ListView.separated(
            itemCount: _referees.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (_, i) => _RefereeRow(
              referee:  _referees[i],
              onEdit:   () => _openForm(existing: _referees[i]),
              onDelete: () => _delete(_referees[i]),
            ),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Referee row
// ─────────────────────────────────────────────────────────────────────────────

class _RefereeRow extends StatelessWidget {
  final Referee      referee;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _RefereeRow({
    required this.referee,
    required this.onEdit,
    required this.onDelete,
  });

  static const _colors = [
    Color(0xFFFFD700),
    Color(0xFF00CFFF),
    Color(0xFF00FF9C),
    Color(0xFFFF6B9D),
    Color(0xFFFF9D00),
  ];

  @override
  Widget build(BuildContext context) {
    final initials = referee.refereeName.trim().isEmpty
        ? '?'
        : referee.refereeName
            .trim()
            .split(' ')
            .where((w) => w.isNotEmpty)
            .take(2)
            .map((w) => w[0].toUpperCase())
            .join();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF130840),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: const Color(0xFF00FF9C).withOpacity(0.12)),
      ),
      child: Row(children: [
        // Avatar
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF00FF9C).withOpacity(0.08),
            border: Border.all(
                color: const Color(0xFF00FF9C).withOpacity(0.3)),
          ),
          child: Center(
            child: Text(initials,
                style: const TextStyle(
                    color: Color(0xFF00FF9C),
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                    letterSpacing: 1)),
          ),
        ),
        const SizedBox(width: 12),

        // Name
        Expanded(
          flex: 3,
          child: Text(referee.refereeName,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 13)),
        ),

        // Contact
        Expanded(
          flex: 3,
          child: Text(
            referee.contact.isEmpty ? '—' : referee.contact,
            style: TextStyle(
                color: referee.contact.isEmpty
                    ? Colors.white24
                    : Colors.white54,
                fontSize: 12),
          ),
        ),

        // Assigned categories
        Expanded(
          flex: 5,
          child: referee.categories.isEmpty
              ? const Text('No category assigned',
                  style: TextStyle(color: Colors.white24, fontSize: 11))
              : Wrap(
                  spacing: 6, runSpacing: 4,
                  children: List.generate(referee.categories.length, (i) {
                    final cat   = referee.categories[i];
                    final color = _colors[i % _colors.length];
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(20),
                        border:
                            Border.all(color: color.withOpacity(0.5)),
                      ),
                      child: Text(cat.categoryType,
                          style: TextStyle(
                              color: color,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1)),
                    );
                  }),
                ),
        ),

        // Actions
        SizedBox(
          width: 80,
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined,
                  color: Color(0xFF00CFFF), size: 17),
              onPressed: onEdit,
              tooltip: 'Edit',
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(6),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(Icons.delete_outline,
                  color: Colors.white.withOpacity(0.25), size: 17),
              onPressed: onDelete,
              tooltip: 'Delete',
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(6),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Add / Edit form dialog
// ─────────────────────────────────────────────────────────────────────────────

class _RefereeFormDialog extends StatefulWidget {
  final List<RefereeCategory> categories;
  final Referee? existing;
  final Future<void> Function(
      String name,
      String contact,
      List<int> selectedCategoryIds) onSave;

  const _RefereeFormDialog({
    required this.categories,
    required this.onSave,
    this.existing,
  });

  @override
  State<_RefereeFormDialog> createState() => _RefereeFormDialogState();
}

class _RefereeFormDialogState extends State<_RefereeFormDialog> {
  final _formKey    = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _contactCtrl;
  late Set<int> _selectedCatIds;
  bool _saving = false;

  static const _colors = [
    Color(0xFFFFD700),
    Color(0xFF00CFFF),
    Color(0xFF00FF9C),
    Color(0xFFFF6B9D),
    Color(0xFFFF9D00),
  ];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl    = TextEditingController(text: e?.refereeName ?? '');
    _contactCtrl = TextEditingController(text: e?.contact ?? '');
    _selectedCatIds = {
      if (e != null) ...e.categories.map((c) => c.categoryId),
    };
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _contactCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_selectedCatIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please assign at least one category.'),
        backgroundColor: Color(0xFFFF6B6B),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(
        _nameCtrl.text.trim(),
        _contactCtrl.text.trim(),
        _selectedCatIds.toList(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        backgroundColor: const Color(0xFFFF6B6B),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;

    return Dialog(
      backgroundColor: const Color(0xFF130840),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: 500,
        constraints: const BoxConstraints(maxHeight: 520),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: const Color(0xFF00FF9C).withOpacity(0.3),
              width: 1.5),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [

          // Header
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color:
                          const Color(0xFF00FF9C).withOpacity(0.15))),
            ),
            child: Row(children: [
              const Icon(Icons.sports_rounded,
                  color: Color(0xFF00FF9C), size: 20),
              const SizedBox(width: 10),
              Text(isEdit ? 'EDIT REFEREE' : 'NEW REFEREE',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                      letterSpacing: 2)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close,
                    color: Colors.white38, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ]),
          ),

          // Body
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    // Name field
                    _Field(
                      controller: _nameCtrl,
                      label: 'REFEREE NAME',
                      hint:  'e.g. Juan dela Cruz',
                      validator: (v) =>
                          (v == null || v.trim().isEmpty)
                              ? 'Name is required'
                              : null,
                    ),
                    const SizedBox(height: 16),

                    // Contact field
                    _Field(
                      controller: _contactCtrl,
                      label: 'CONTACT',
                      hint:  'Phone number or email',
                    ),
                    const SizedBox(height: 24),

                    // ── Category assignment ─────────────────────────────
                    Row(
                      children: [
                        const _SectionLabel('ASSIGN CATEGORIES'),
                        const Spacer(),
                        if (_selectedCatIds.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00FF9C).withOpacity(0.12),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: const Color(0xFF00FF9C).withOpacity(0.4)),
                            ),
                            child: Text(
                              '\${_selectedCatIds.length} selected',
                              style: const TextStyle(
                                  color: Color(0xFF00FF9C),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    widget.categories.isEmpty
                        ? Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.03),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Row(children: [
                              Icon(Icons.info_outline,
                                  color: Colors.white24, size: 16),
                              const SizedBox(width: 10),
                              const Text('No active categories found.',
                                  style: TextStyle(
                                      color: Colors.white38, fontSize: 12)),
                            ]),
                          )
                        : Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.02),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                  color: Colors.white.withOpacity(0.07)),
                            ),
                            child: Column(
                              children: List.generate(
                                  widget.categories.length, (i) {
                                final cat   = widget.categories[i];
                                final sel   = _selectedCatIds.contains(cat.categoryId);
                                final color = _colors[i % _colors.length];
                                final isLast = i == widget.categories.length - 1;
                                return GestureDetector(
                                  onTap: () => setState(() => sel
                                      ? _selectedCatIds.remove(cat.categoryId)
                                      : _selectedCatIds.add(cat.categoryId)),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 160),
                                    decoration: BoxDecoration(
                                      color: sel
                                          ? color.withOpacity(0.08)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.vertical(
                                        top:    i == 0 ? const Radius.circular(14) : Radius.zero,
                                        bottom: isLast ? const Radius.circular(14) : Radius.zero,
                                      ),
                                      border: isLast
                                          ? null
                                          : Border(
                                              bottom: BorderSide(
                                                  color: Colors.white.withOpacity(0.06))),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 14),
                                    child: Row(children: [
                                      // Color dot
                                      AnimatedContainer(
                                        duration: const Duration(milliseconds: 160),
                                        width: 10, height: 10,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: sel ? color : color.withOpacity(0.25),
                                          boxShadow: sel
                                              ? [BoxShadow(
                                                  color: color.withOpacity(0.5),
                                                  blurRadius: 6)]
                                              : [],
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      // Category name
                                      Expanded(
                                        child: Text(
                                          cat.categoryType,
                                          style: TextStyle(
                                              color: sel
                                                  ? Colors.white
                                                  : Colors.white54,
                                              fontSize: 13,
                                              fontWeight: sel
                                                  ? FontWeight.w700
                                                  : FontWeight.w500),
                                        ),
                                      ),
                                      // Animated checkmark
                                      AnimatedContainer(
                                        duration: const Duration(milliseconds: 160),
                                        width: 24, height: 24,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: sel
                                              ? color
                                              : Colors.white.withOpacity(0.06),
                                          border: Border.all(
                                            color: sel
                                                ? color
                                                : Colors.white.withOpacity(0.15),
                                            width: 1.5,
                                          ),
                                        ),
                                        child: sel
                                            ? const Icon(Icons.check,
                                                color: Colors.black,
                                                size: 14)
                                            : null,
                                      ),
                                    ]),
                                  ),
                                );
                              }),
                            ),
                          ),

                    const SizedBox(height: 28),

                    // Action buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('CANCEL',
                              style: TextStyle(
                                  color: Colors.white38,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1)),
                        ),
                        const SizedBox(width: 12),
                        _saving
                            ? const SizedBox(
                                width: 110,
                                child: Center(
                                  child: SizedBox(
                                    width: 20, height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFF00FF9C)),
                                  ),
                                ))
                            : _GlowButton(
                                label: isEdit
                                    ? 'SAVE CHANGES'
                                    : 'REGISTER',
                                color: const Color(0xFF00FF9C),
                                onTap: _submit,
                              ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Confirm delete dialog
// ─────────────────────────────────────────────────────────────────────────────

class _ConfirmDialog extends StatelessWidget {
  final String name;
  const _ConfirmDialog({required this.name});

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: const Color(0xFF130840),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: Text('Delete $name?',
            style: const TextStyle(
                color: Colors.white, fontSize: 15)),
        content: const Text(
            'This will also remove all category assignments.',
            style: TextStyle(color: Colors.white54, fontSize: 12)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('CANCEL',
                style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('DELETE',
                style: TextStyle(
                    color: Color(0xFFFF6B6B),
                    fontWeight: FontWeight.w800)),
          ),
        ],
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty state
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 90, height: 90,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF00FF9C).withOpacity(0.08),
                border: Border.all(
                    color: const Color(0xFF00FF9C).withOpacity(0.3),
                    width: 1.5),
              ),
              child: const Icon(Icons.sports_rounded,
                  color: Color(0xFF00FF9C), size: 40),
            ),
            const SizedBox(height: 24),
            const Text('NO REFEREES REGISTERED',
                style: TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Add your first referee to get started.',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.3),
                    fontSize: 12)),
            const SizedBox(height: 28),
            _GlowButton(
                label: '+  ADD REFEREE',
                color: const Color(0xFF00FF9C),
                onTap: onAdd),
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Reusable widgets
// ─────────────────────────────────────────────────────────────────────────────

class _ColLabel extends StatelessWidget {
  final String text;
  const _ColLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          color: Colors.white38,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5));
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          color: Colors.white38,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5));
}

class _Chip extends StatelessWidget {
  final String label;
  final Color  color;
  const _Chip(this.label, this.color);
  @override
  Widget build(BuildContext context) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Text(label,
            style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2)),
      );
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label, hint;

  final String? Function(String?)? validator;

  const _Field({
    required this.controller,
    required this.label,
    required this.hint,

    this.validator,
  });

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(
                color: Colors.white38,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5)),
        const SizedBox(height: 6),
        TextFormField(
          controller:   controller,

          validator:    validator,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
                color: Colors.white.withOpacity(0.2), fontSize: 12),
            filled: true,
            fillColor: const Color(0xFF0E0630),
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 12),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                    color: Colors.white.withOpacity(0.1), width: 1)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(
                    color: Color(0xFF00FF9C), width: 1.5)),
            errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(
                    color: Color(0xFFFF6B6B), width: 1)),
            focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(
                    color: Color(0xFFFF6B6B), width: 1.5)),
          ),
        ),
      ]);
}

class _GlowButton extends StatefulWidget {
  final String label;
  final Color  color;
  final VoidCallback onTap;
  const _GlowButton({
    required this.label,
    required this.color,
    required this.onTap,
  });
  @override
  State<_GlowButton> createState() => _GlowButtonState();
}

class _GlowButtonState extends State<_GlowButton> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit:  (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              color: _hovered
                  ? widget.color.withOpacity(0.2)
                  : widget.color.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: _hovered
                      ? widget.color
                      : widget.color.withOpacity(0.4),
                  width: 1.5),
              boxShadow: _hovered
                  ? [
                      BoxShadow(
                          color: widget.color.withOpacity(0.3),
                          blurRadius: 14,
                          spreadRadius: 1)
                    ]
                  : [],
            ),
            child: Text(widget.label,
                style: TextStyle(
                    color: widget.color,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5)),
          ),
        ),
      );
}