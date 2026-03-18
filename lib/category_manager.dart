import 'package:flutter/material.dart';
import 'db_helper.dart';

class CategoryManager extends StatefulWidget {
  final VoidCallback onBack;
  const CategoryManager({super.key, required this.onBack});

  @override
  State<CategoryManager> createState() => _CategoryManagerState();
}

class _CategoryManagerState extends State<CategoryManager>
    with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _categories = [];
  bool   _loading = true;
  String _error   = '';

  int?   _editingId;
  final  TextEditingController _editCtrl = TextEditingController();
  final  Set<int> _toggling = {};

  late final AnimationController _fadeCtrl;
  late final Animation<double>   _fadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 400));
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _load();
  }

  @override
  void dispose() {
    _editCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = ''; });
    _fadeCtrl.reset();
    try {
      final conn   = await DBHelper.getConnection();
      final result = await conn.execute(
        'SELECT category_id, category_type, status FROM tbl_category ORDER BY category_id',
      );
      setState(() {
        _categories = result.rows.map((r) => r.assoc()).toList();
        _loading    = false;
      });
      _fadeCtrl.forward();
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _toggle(int id, bool currentlyActive) async {
    if (_toggling.contains(id)) return;
    setState(() => _toggling.add(id));
    try {
      await DBHelper.toggleCategoryStatus(id, !currentlyActive);
      setState(() {
        for (final c in _categories) {
          if (int.parse(c['category_id'].toString()) == id) {
            c['status'] = currentlyActive ? 'inactive' : 'active';
          }
        }
        _toggling.remove(id);
      });
    } catch (e) {
      setState(() => _toggling.remove(id));
      _snack('Error: $e', Colors.red);
    }
  }

  Future<void> _rename(int id, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    try {
      await DBHelper.updateCategory(id, trimmed);
      setState(() {
        for (final c in _categories) {
          if (int.parse(c['category_id'].toString()) == id) {
            c['category_type'] = trimmed;
          }
        }
        _editingId = null;
      });
      _snack('Renamed to "$trimmed"', const Color(0xFF00FF88));
    } catch (e) {
      _snack('Error: $e', Colors.red);
    }
  }

  Future<void> _delete(int id, String name) async {
    final ok = await _confirmDelete(name);
    if (ok != true) return;
    try {
      await DBHelper.deleteCategory(id);
      setState(() => _categories.removeWhere(
          (c) => int.parse(c['category_id'].toString()) == id));
      _snack('"$name" deleted', Colors.orange);
    } catch (e) {
      _snack('Error: $e', Colors.red);
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: Text(msg,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      backgroundColor: color,
      duration: const Duration(seconds: 2),
    ));
  }

  Future<bool?> _confirmDelete(String name) => showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.7),
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 340, padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF1E0A4A), Color(0xFF2D0E7A)],
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.redAccent.withOpacity(0.5), width: 1.5),
          boxShadow: [BoxShadow(color: Colors.red.withOpacity(0.15),
              blurRadius: 40, spreadRadius: 4)],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 60, height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.red.withOpacity(0.12),
              border: Border.all(color: Colors.redAccent.withOpacity(0.5), width: 1.5),
            ),
            child: const Icon(Icons.delete_forever_rounded,
                color: Colors.redAccent, size: 28),
          ),
          const SizedBox(height: 18),
          const Text('Delete Category?',
              style: TextStyle(color: Colors.white, fontSize: 18,
                  fontWeight: FontWeight.w900, letterSpacing: 0.5)),
          const SizedBox(height: 10),
          Text('"$name" and all its data\nwill be permanently removed.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withOpacity(0.5),
                  fontSize: 13, height: 1.6)),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.white.withOpacity(0.15)),
                ),
              ),
              child: Text('CANCEL', style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontWeight: FontWeight.bold, letterSpacing: 1)),
            )),
            const SizedBox(width: 12),
            Expanded(child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: const Text('DELETE', style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w900,
                  letterSpacing: 1)),
            )),
          ]),
        ]),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final activeCount   = _categories.where((c) => c['status'] == 'active').length;
    final inactiveCount = _categories.length - activeCount;

    return Scaffold(
      backgroundColor: const Color(0xFF07051A),
      body: Column(children: [
        _buildHeader(activeCount, inactiveCount),
        Expanded(child: _loading
            ? _buildLoading()
            : _error.isNotEmpty
                ? _buildError()
                : _categories.isEmpty
                    ? _buildEmpty()
                    : FadeTransition(
                        opacity: _fadeAnim,
                        child: _buildList(),
                      )),
      ]),
    );
  }

  Widget _buildHeader(int active, int inactive) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFF1A0550), Color(0xFF2D0E7A), Color(0xFF180A4A)],
        ),
        border: Border(bottom: BorderSide(color: Color(0xFF3D1F9A), width: 1)),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded,
                  color: Color(0xFF00CFFF), size: 18),
              onPressed: widget.onBack,
            ),
            const Expanded(child: Text('CATEGORY MANAGER',
                style: TextStyle(color: Colors.white, fontSize: 17,
                    fontWeight: FontWeight.w900, letterSpacing: 2.5))),
            IconButton(
              icon: const Icon(Icons.refresh_rounded,
                  color: Colors.white38, size: 20),
              onPressed: _load,
              tooltip: 'Refresh',
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Row(children: [
            _headerStat(Icons.check_circle_rounded, 'ACTIVE',
                '$active', const Color(0xFF00FF88)),
            const SizedBox(width: 10),
            _headerStat(Icons.pause_circle_rounded, 'INACTIVE',
                '$inactive', Colors.white38),
            const SizedBox(width: 10),
            _headerStat(Icons.category_rounded, 'TOTAL',
                '${_categories.length}', const Color(0xFF00CFFF)),
          ]),
        ),
      ]),
    );
  }

  Widget _headerStat(IconData icon, String label, String value, Color color) =>
      Expanded(child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: TextStyle(color: color, fontSize: 18,
                fontWeight: FontWeight.w900)),
            Text(label, style: TextStyle(color: color.withOpacity(0.6),
                fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1)),
          ]),
        ]),
      ));

  Widget _buildList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      itemCount: _categories.length,
      itemBuilder: (_, i) => _buildCard(_categories[i], i),
    );
  }

  Widget _buildCard(Map<String, dynamic> cat, int idx) {
    final id         = int.parse(cat['category_id'].toString());
    final name       = cat['category_type'] as String;
    final isActive   = cat['status'] == 'active';
    final isEditing  = _editingId == id;
    final isToggling = _toggling.contains(id);

    const palette = [
      Color(0xFF00CFFF), Color(0xFFFF9F43), Color(0xFF7B6AFF),
      Color(0xFF00FF88), Color(0xFFFF6B6B), Color(0xFFFFD700),
      Color(0xFFFF4FD8), Color(0xFF43E8D8),
    ];
    final color = palette[idx % palette.length];

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFF0E0B2A) : const Color(0xFF080617),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isActive ? color.withOpacity(0.3) : Colors.white.withOpacity(0.07),
          width: 1.5,
        ),
        boxShadow: isActive ? [
          BoxShadow(color: color.withOpacity(0.08),
              blurRadius: 16, offset: const Offset(0, 4)),
        ] : [],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(children: [
          // Top accent bar
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            height: 3,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: isActive
                  ? [color.withOpacity(0.9), color.withOpacity(0.1)]
                  : [Colors.white.withOpacity(0.05), Colors.transparent]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              // Icon circle
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 50, height: 50,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive ? color.withOpacity(0.12) : Colors.white.withOpacity(0.04),
                  border: Border.all(
                    color: isActive ? color.withOpacity(0.4) : Colors.white.withOpacity(0.08),
                    width: 1.5,
                  ),
                ),
                child: Icon(Icons.category_rounded,
                    color: isActive ? color : Colors.white24, size: 22),
              ),
              const SizedBox(width: 14),

              // Name / edit
              Expanded(child: isEditing
                  ? _buildEditField(id)
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(name,
                          style: TextStyle(
                            color: isActive ? Colors.white : Colors.white38,
                            fontSize: 16, fontWeight: FontWeight.w800,
                          )),
                      const SizedBox(height: 4),
                      Row(children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          width: 6, height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isActive ? const Color(0xFF00FF88) : Colors.white24,
                            boxShadow: isActive ? [BoxShadow(
                                color: const Color(0xFF00FF88).withOpacity(0.6),
                                blurRadius: 4)] : [],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isActive ? 'Active — shown in schedule'
                                   : 'Inactive — hidden from schedule',
                          style: TextStyle(
                            color: isActive
                                ? const Color(0xFF00FF88).withOpacity(0.7)
                                : Colors.white.withOpacity(0.2),
                            fontSize: 11,
                          ),
                        ),
                      ]),
                    ])),

              if (!isEditing) ...[
                const SizedBox(width: 8),
                // Rename
                _actionBtn(Icons.edit_rounded, const Color(0xFF00CFFF), () {
                  _editCtrl.text = name;
                  setState(() => _editingId = id);
                }),
                const SizedBox(width: 6),
                // Delete
                _actionBtn(Icons.delete_outline_rounded, Colors.redAccent,
                    () => _delete(id, name)),
                const SizedBox(width: 10),
                // Toggle switch
                GestureDetector(
                  onTap: isToggling ? null : () => _toggle(id, isActive),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 56, height: 30,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(15),
                      color: isActive
                          ? const Color(0xFF00FF88).withOpacity(0.15)
                          : Colors.white.withOpacity(0.05),
                      border: Border.all(
                        color: isActive
                            ? const Color(0xFF00FF88).withOpacity(0.5)
                            : Colors.white.withOpacity(0.1),
                        width: 1.5,
                      ),
                    ),
                    child: Stack(children: [
                      Center(child: Padding(
                        padding: EdgeInsets.only(
                            left: isActive ? 0 : 14, right: isActive ? 14 : 0),
                        child: Text(isActive ? 'ON' : 'OFF',
                            style: TextStyle(
                              color: isActive
                                  ? const Color(0xFF00FF88)
                                  : Colors.white24,
                              fontSize: 8, fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            )),
                      )),
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeInOut,
                        left: isActive ? 28 : 3, top: 3,
                        child: isToggling
                            ? SizedBox(width: 24, height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2,
                                    color: isActive
                                        ? const Color(0xFF00FF88)
                                        : Colors.white38))
                            : Container(
                                width: 24, height: 24,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isActive
                                      ? const Color(0xFF00FF88)
                                      : Colors.white24,
                                  boxShadow: isActive ? [BoxShadow(
                                      color: const Color(0xFF00FF88).withOpacity(0.5),
                                      blurRadius: 8)] : [],
                                ),
                              ),
                      ),
                    ]),
                  ),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _buildEditField(int id) => Row(children: [
    Expanded(child: Container(
      height: 38,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF00CFFF).withOpacity(0.6)),
      ),
      child: TextField(
        controller: _editCtrl,
        autofocus: true,
        style: const TextStyle(color: Colors.white, fontSize: 14,
            fontWeight: FontWeight.w700),
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        ),
        onSubmitted: (v) => _rename(id, v),
      ),
    )),
    const SizedBox(width: 8),
    _actionBtn(Icons.check_rounded, const Color(0xFF00FF88),
        () => _rename(id, _editCtrl.text)),
    const SizedBox(width: 6),
    _actionBtn(Icons.close_rounded, Colors.white38,
        () => setState(() => _editingId = null)),
  ]);

  Widget _buildLoading() => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      SizedBox(width: 48, height: 48,
          child: CircularProgressIndicator(strokeWidth: 2.5,
              color: const Color(0xFF00CFFF).withOpacity(0.8))),
      const SizedBox(height: 16),
      Text('Loading categories...',
          style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 13)),
    ]),
  );

  Widget _buildError() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.red.withOpacity(0.1),
            border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
          ),
          child: const Icon(Icons.error_outline_rounded,
              color: Colors.redAccent, size: 30),
        ),
        const SizedBox(height: 16),
        Text(_error, textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded, color: Color(0xFF00CFFF)),
          label: const Text('Retry',
              style: TextStyle(color: Color(0xFF00CFFF))),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: const Color(0xFF00CFFF).withOpacity(0.4)),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ]),
    ),
  );

  Widget _buildEmpty() => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        width: 80, height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.03),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: const Icon(Icons.category_outlined,
            color: Colors.white24, size: 36),
      ),
      const SizedBox(height: 18),
      const Text('No categories found',
          style: TextStyle(color: Colors.white38, fontSize: 16,
              fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      Text('Categories are managed from the database',
          style: TextStyle(color: Colors.white.withOpacity(0.18), fontSize: 12)),
    ]),
  );

  Widget _actionBtn(IconData icon, Color color, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: color.withOpacity(0.25)),
          ),
          child: Icon(icon, color: color, size: 16),
        ),
      );
} 