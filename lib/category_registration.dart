import 'package:flutter/material.dart';
import 'db_helper.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

class Category {
  final int?   categoryId;
  final String categoryType;
  final String status; // 'active' | 'inactive'

  const Category({
    this.categoryId,
    required this.categoryType,
    required this.status,
  });

  bool get isActive => status == 'active';

  factory Category.fromMap(Map<String, dynamic> m) => Category(
        categoryId:   int.parse(m['category_id'].toString()),
        categoryType: m['category_type'].toString(),
        status:       (m['status'] ?? 'active').toString(),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// DB
// ─────────────────────────────────────────────────────────────────────────────

class _CategoryDB {
  static Future<List<Category>> fetchAll() async {
    final conn   = await DBHelper.getConnection();
    final result = await conn.execute(
      'SELECT * FROM tbl_category ORDER BY category_id',
    );
    return result.rows.map((r) => Category.fromMap(r.assoc())).toList();
  }

  static Future<void> insert(String categoryType) async {
    final conn = await DBHelper.getConnection();
    await conn.execute(
      "INSERT INTO tbl_category (category_type, status) VALUES (:type, 'active')",
      {'type': categoryType},
    );
  }

  static Future<void> update(int id, String categoryType) async {
    final conn = await DBHelper.getConnection();
    await conn.execute(
      'UPDATE tbl_category SET category_type = :type WHERE category_id = :id',
      {'type': categoryType, 'id': id},
    );
  }

  static Future<void> toggleStatus(int id, bool setActive) async {
    final conn = await DBHelper.getConnection();
    await conn.execute(
      'UPDATE tbl_category SET status = :status WHERE category_id = :id',
      {'status': setActive ? 'active' : 'inactive', 'id': id},
    );
  }

  static Future<void> delete(int id) async {
    final conn = await DBHelper.getConnection();
    await conn.execute(
      'DELETE FROM tbl_category WHERE category_id = :id',
      {'id': id},
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Page
// ─────────────────────────────────────────────────────────────────────────────

class CategoryRegistrationPage extends StatefulWidget {
  final VoidCallback onBack;

  const CategoryRegistrationPage({super.key, required this.onBack});

  @override
  State<CategoryRegistrationPage> createState() =>
      _CategoryRegistrationPageState();
}

class _CategoryRegistrationPageState
    extends State<CategoryRegistrationPage> {
  List<Category> _categories = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final cats = await _CategoryDB.fetchAll();
      setState(() {
        _categories = cats;
        _loading    = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      _snack('Load failed: $e', const Color(0xFFFF6B6B));
    }
  }

  // ── Open add / edit dialog ─────────────────────────────────────────────────
  Future<void> _openForm({Category? existing}) async {
    await showDialog(
      context: context,
      builder: (_) => _CategoryFormDialog(
        existing: existing,
        onSave: (name) async {
          if (existing == null) {
            await _CategoryDB.insert(name);
          } else {
            await _CategoryDB.update(existing.categoryId!, name);
          }
          await _load();
        },
      ),
    );
  }

  // ── Toggle active / inactive ───────────────────────────────────────────────
  Future<void> _toggleStatus(Category cat) async {
    try {
      await _CategoryDB.toggleStatus(cat.categoryId!, !cat.isActive);
      await _load();
    } catch (e) {
      _snack('Failed to update status: $e', const Color(0xFFFF6B6B));
    }
  }

  // ── Delete ─────────────────────────────────────────────────────────────────
  Future<void> _delete(Category cat) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(name: cat.categoryType),
    );
    if (ok == true) {
      try {
        await _CategoryDB.delete(cat.categoryId!);
        await _load();
      } catch (e) {
        _snack('Delete failed: $e', const Color(0xFFFF6B6B));
      }
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
    final active   = _categories.where((c) => c.isActive).length;
    final inactive = _categories.where((c) => !c.isActive).length;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0630),
      body: Column(children: [
        // ── Header ──────────────────────────────────────────────────────
        Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF1A0550),
                Color(0xFF2D0E7A),
                Color(0xFF1A0A4A)
              ],
            ),
            border: Border(
                bottom: BorderSide(color: Color(0xFFAA80FF), width: 1.5)),
          ),
          padding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_new,
                  color: Color(0xFFAA80FF), size: 18),
              onPressed: widget.onBack,
            ),
            const SizedBox(width: 6),
            const Icon(Icons.category_rounded,
                color: Color(0xFFAA80FF), size: 22),
            const SizedBox(width: 10),
            const Text('CATEGORY REGISTRATION',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3)),
            const Spacer(),
            // Summary chips
            if (_categories.isNotEmpty) ...[
              _Chip('${_categories.length} TOTAL',
                  const Color(0xFFAA80FF)),
              const SizedBox(width: 8),
              _Chip('$active ACTIVE', const Color(0xFF00FF9C)),
              const SizedBox(width: 8),
              _Chip('$inactive INACTIVE', const Color(0xFFFF6B6B)),
              const SizedBox(width: 16),
            ],
            _GlowButton(
              label: '+  ADD CATEGORY',
              color: const Color(0xFFAA80FF),
              onTap: () => _openForm(),
            ),
          ]),
        ),

        // ── Body ────────────────────────────────────────────────────────
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(
                      color: Color(0xFFAA80FF)))
              : _categories.isEmpty
                  ? _EmptyState(onAdd: () => _openForm())
                  : _buildTable(),
        ),
      ]),
    );
  }

  // ── Table ──────────────────────────────────────────────────────────────────
  Widget _buildTable() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        // Column headers
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: const [
            SizedBox(width: 48),
            SizedBox(width: 12),
            Expanded(flex: 1, child: _ColLabel('#')),
            Expanded(flex: 6, child: _ColLabel('CATEGORY NAME')),
            SizedBox(width: 130, child: _ColLabel('STATUS')),
            SizedBox(width: 90,  child: _ColLabel('ACTIONS')),
          ]),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ListView.separated(
            itemCount: _categories.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (_, i) => _CategoryRow(
              category:     _categories[i],
              index:        i + 1,
              onEdit:       () => _openForm(existing: _categories[i]),
              onToggle:     () => _toggleStatus(_categories[i]),
              onDelete:     () => _delete(_categories[i]),
            ),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Category row
// ─────────────────────────────────────────────────────────────────────────────

class _CategoryRow extends StatelessWidget {
  final Category     category;
  final int          index;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const _CategoryRow({
    required this.category,
    required this.index,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isActive    = category.isActive;
    final statusColor = isActive
        ? const Color(0xFF00FF9C)
        : const Color(0xFFFF6B6B);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF130840),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: const Color(0xFFAA80FF).withOpacity(0.12)),
      ),
      child: Row(children: [
        // Icon circle
        Container(
          width: 48, height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFAA80FF).withOpacity(0.08),
            border: Border.all(
                color: const Color(0xFFAA80FF).withOpacity(0.3)),
          ),
          child: const Center(
            child: Icon(Icons.category_rounded,
                color: Color(0xFFAA80FF), size: 20),
          ),
        ),
        const SizedBox(width: 12),

        // Index
        Expanded(
          flex: 1,
          child: Text(
            '$index',
            style: TextStyle(
                color: Colors.white.withOpacity(0.3),
                fontSize: 12,
                fontWeight: FontWeight.w700),
          ),
        ),

        // Category name
        Expanded(
          flex: 6,
          child: Text(
            category.categoryType,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 14),
          ),
        ),

        // Status toggle button
        SizedBox(
          width: 130,
          child: GestureDetector(
            onTap: onToggle,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: statusColor.withOpacity(0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isActive
                        ? Icons.check_circle_outline
                        : Icons.cancel_outlined,
                    color: statusColor,
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isActive ? 'ACTIVE' : 'INACTIVE',
                    style: TextStyle(
                        color: statusColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Actions
        SizedBox(
          width: 90,
          child: Row(children: [
            const SizedBox(width: 6),
            IconButton(
              icon: const Icon(Icons.edit_outlined,
                  color: Color(0xFF00CFFF), size: 18),
              onPressed: onEdit,
              tooltip: 'Edit',
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(6),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(Icons.delete_outline,
                  color: Colors.white.withOpacity(0.25), size: 18),
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
// Add / Edit dialog
// ─────────────────────────────────────────────────────────────────────────────

class _CategoryFormDialog extends StatefulWidget {
  final Category? existing;
  final Future<void> Function(String name) onSave;

  const _CategoryFormDialog({
    required this.onSave,
    this.existing,
  });

  @override
  State<_CategoryFormDialog> createState() => _CategoryFormDialogState();
}

class _CategoryFormDialogState extends State<_CategoryFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(
        text: widget.existing?.categoryType ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(_nameCtrl.text.trim());
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
        width: 440,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: const Color(0xFFAA80FF).withOpacity(0.35),
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
                      color: const Color(0xFFAA80FF).withOpacity(0.15))),
            ),
            child: Row(children: [
              const Icon(Icons.category_rounded,
                  color: Color(0xFFAA80FF), size: 20),
              const SizedBox(width: 10),
              Text(
                isEdit ? 'EDIT CATEGORY' : 'NEW CATEGORY',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    letterSpacing: 2),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close,
                    color: Colors.white38, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ]),
          ),

          // Form body
          Padding(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Label
                  const Text('CATEGORY NAME',
                      style: TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5)),
                  const SizedBox(height: 8),

                  // Text field
                  TextFormField(
                    controller: _nameCtrl,
                    autofocus:  true,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty)
                            ? 'Category name is required'
                            : null,
                    decoration: InputDecoration(
                      hintText: 'e.g. Aspiring Makers (mBot 1)',
                      hintStyle: TextStyle(
                          color: Colors.white.withOpacity(0.2),
                          fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF0E0630),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                              color: Colors.white.withOpacity(0.1))),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                              color: Color(0xFFAA80FF), width: 1.5)),
                      errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                              color: Color(0xFFFF6B6B))),
                      focusedErrorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                              color: Color(0xFFFF6B6B), width: 1.5)),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Helper note
                  Text(
                    isEdit
                        ? 'Note: status can be toggled from the list.'
                        : 'New categories are set to active by default.',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.25),
                        fontSize: 11),
                  ),
                  const SizedBox(height: 28),

                  // Buttons
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
                              width: 100,
                              child: Center(
                                child: SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFFAA80FF)),
                                ),
                              ))
                          : _GlowButton(
                              label: isEdit ? 'SAVE CHANGES' : 'ADD',
                              color: const Color(0xFFAA80FF),
                              onTap: _submit,
                            ),
                    ],
                  ),
                ],
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
        title: Text('Delete "$name"?',
            style: const TextStyle(
                color: Colors.white, fontSize: 15)),
        content: const Text(
            'This will also remove all referee assignments for this category.',
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
                color: const Color(0xFFAA80FF).withOpacity(0.08),
                border: Border.all(
                    color: const Color(0xFFAA80FF).withOpacity(0.3),
                    width: 1.5),
              ),
              child: const Icon(Icons.category_rounded,
                  color: Color(0xFFAA80FF), size: 40),
            ),
            const SizedBox(height: 24),
            const Text('NO CATEGORIES YET',
                style: TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Add your first category to get started.',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.3),
                    fontSize: 12)),
            const SizedBox(height: 28),
            _GlowButton(
                label: '+  ADD CATEGORY',
                color: const Color(0xFFAA80FF),
                onTap: onAdd),
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared widgets
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
                  ? [BoxShadow(
                      color: widget.color.withOpacity(0.3),
                      blurRadius: 14,
                      spreadRadius: 1)]
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