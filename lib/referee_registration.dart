import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'db_helper.dart';
import 'registration_shared.dart';

// ── Color palette ─────────────────────────────────────────────────────────────
const _kAccent    = Color(0xFF00E5A0);
const _kBg        = Color(0xFF07041A);
const _kCard      = Color(0xFF0F0830);
const _kCardAlt   = Color(0xFF0C0628);
const _kPurple    = Color(0xFF7B2FFF);
const _kGold      = Color(0xFFFFD700);

const _kAvatarColors = [
  Color(0xFF00E5A0), Color(0xFF7B2FFF), Color(0xFF00CFFF),
  Color(0xFFFF9F43), Color(0xFFFF6B6B), Color(0xFFFFD700),
];
Color _avatarColor(String initials) =>
    _kAvatarColors[initials.codeUnitAt(0) % _kAvatarColors.length];

// ══════════════════════════════════════════════════════════════════════════════
// 1. SHIMMER WIDGET — animated loading skeleton
// ══════════════════════════════════════════════════════════════════════════════
class _Shimmer extends StatefulWidget {
  final double width;
  final double height;
  final double radius;
  const _Shimmer({required this.width, required this.height, this.radius = 8});

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
    _anim = Tween<double>(begin: -1.5, end: 1.5).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            begin: Alignment(_anim.value - 1, 0),
            end: Alignment(_anim.value, 0),
            colors: const [
              Color(0xFF0F0830),
              Color(0xFF1E1250),
              Color(0xFF0F0830),
            ],
          ),
        ),
      ),
    );
  }
}

// Shimmer skeleton row (desktop or mobile)
class _ShimmerRow extends StatelessWidget {
  final bool isMobile;
  const _ShimmerRow({this.isMobile = false});

  @override
  Widget build(BuildContext context) {
    if (isMobile) {
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _Shimmer(width: 46, height: 46, radius: 23),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _Shimmer(width: 120, height: 13, radius: 6),
              const SizedBox(height: 7),
              _Shimmer(width: 80, height: 10, radius: 5),
            ]),
            const Spacer(),
            Row(children: [
              _Shimmer(width: 32, height: 32, radius: 9),
              const SizedBox(width: 6),
              _Shimmer(width: 32, height: 32, radius: 9),
              const SizedBox(width: 6),
              _Shimmer(width: 32, height: 32, radius: 9),
            ]),
          ]),
          const SizedBox(height: 12),
          _Shimmer(width: double.infinity, height: 1, radius: 1),
          const SizedBox(height: 10),
          Row(children: [
            _Shimmer(width: 72, height: 26, radius: 20),
            const SizedBox(width: 6),
            _Shimmer(width: 84, height: 26, radius: 20),
          ]),
        ]),
      );
    }
    // Desktop row
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(children: [
        _Shimmer(width: 44, height: 44, radius: 22),
        const SizedBox(width: 14),
        Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Shimmer(width: 120, height: 13, radius: 6),
          const SizedBox(height: 7),
          _Shimmer(width: 70, height: 10, radius: 5),
        ])),
        Expanded(flex: 3, child: _Shimmer(width: 90, height: 13, radius: 6)),
        Expanded(flex: 5, child: Row(children: [
          _Shimmer(width: 64, height: 24, radius: 20),
          const SizedBox(width: 6),
          _Shimmer(width: 72, height: 24, radius: 20),
        ])),
        Row(children: [
          _Shimmer(width: 60, height: 28, radius: 8),
          const SizedBox(width: 6),
          _Shimmer(width: 44, height: 28, radius: 8),
          const SizedBox(width: 6),
          _Shimmer(width: 52, height: 28, radius: 8),
        ]),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 3. PULSING WARNING BADGE — animates when unassigned > 0
// ══════════════════════════════════════════════════════════════════════════════
class _PulsingPill extends StatefulWidget {
  final int count;
  const _PulsingPill({required this.count});

  @override
  State<_PulsingPill> createState() => _PulsingPillState();
}

class _PulsingPillState extends State<_PulsingPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.4, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final hasWarning = widget.count > 0;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(hasWarning ? 0.07 : 0.04),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.orange.withOpacity(
                hasWarning ? 0.15 + _pulse.value * 0.15 : 0.10),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          // Pulsing dot
          Container(
            width: 7, height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.orange.withOpacity(
                  hasWarning ? 0.45 + _pulse.value * 0.55 : 0.35),
              boxShadow: hasWarning ? [BoxShadow(
                color: Colors.orange.withOpacity(_pulse.value * 0.55),
                blurRadius: 7 * _pulse.value,
                spreadRadius: 1,
              )] : null,
            ),
          ),
          const SizedBox(width: 6),
          Text('${widget.count}',
              style: TextStyle(
                  color: Colors.orange.withOpacity(hasWarning ? 0.9 : 0.5),
                  fontSize: 13, fontWeight: FontWeight.w800)),
          const SizedBox(width: 5),
          Text('UNASSIGNED',
              style: TextStyle(
                  color: Colors.orange.withOpacity(hasWarning ? 0.55 : 0.30),
                  fontSize: 9, letterSpacing: 1, fontWeight: FontWeight.bold)),
        ]),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// MAIN PAGE
// ══════════════════════════════════════════════════════════════════════════════
class RefereeRegistrationPage extends StatefulWidget {
  final VoidCallback? onBack;
  final VoidCallback? onDone;

  const RefereeRegistrationPage({super.key, this.onBack, this.onDone});

  @override
  State<RefereeRegistrationPage> createState() =>
      _RefereeRegistrationPageState();
}

class _RefereeRegistrationPageState extends State<RefereeRegistrationPage>
    with SingleTickerProviderStateMixin {

  List<Map<String, dynamic>> _referees         = [];
  List<Map<String, dynamic>> _categories       = [];
  Map<int, List<Map<String, dynamic>>> _refCategoriesMap = {};
  bool   _loading = true;
  String _search  = '';
  AnimationController? _fabAnim;

  @override
  void initState() {
    super.initState();
    _fabAnim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700))
      ..forward();
    _load();
  }

  @override
  void dispose() { _fabAnim?.dispose(); super.dispose(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    final refs = await DBHelper.getReferees();
    final cats = await DBHelper.getCategories();
    final Map<int, List<Map<String, dynamic>>> map = {};
    for (final ref in refs) {
      final id = int.tryParse(ref['referee_id'].toString()) ?? 0;
      map[id] = await DBHelper.getRefereeCategories(id);
    }
    setState(() {
      _referees         = refs;
      _categories       = cats;
      _refCategoriesMap = map;
      _loading          = false;
    });
  }

  void _snack(String msg, {bool success = true}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: (success ? _kAccent : Colors.redAccent).withOpacity(0.2),
          ),
          child: Icon(
            success ? Icons.check_rounded : Icons.error_outline_rounded,
            color: success ? _kAccent : Colors.redAccent,
            size: 14,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(msg,
            style: TextStyle(
              color: Colors.white.withOpacity(0.9),
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ]),
      backgroundColor: success ? const Color(0xFF0D2B1E) : const Color(0xFF2B0D0D),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      elevation: 8,
    ));
  }

  String _initials(String name) {
    final p = name.trim().split(RegExp(r'\s+'));
    if (p.isEmpty) return '?';
    if (p.length == 1) return p[0][0].toUpperCase();
    return (p[0][0] + p[p.length - 1][0]).toUpperCase();
  }

  // ── 2. SLIDE-IN DIALOG via showGeneralDialog ───────────────────────────────
  Future<void> _openDialog({Map<String, dynamic>? existing}) async {
    final nameCtrl    = TextEditingController(text: existing?['referee_name'] ?? '');
    final contactCtrl = TextEditingController(text: existing?['contact'] ?? '');
    final Set<int> selected = {};
    if (existing != null) {
      final id   = int.tryParse(existing['referee_id'].toString()) ?? 0;
      final cats = await DBHelper.getRefereeCategories(id);
      selected.addAll(cats.map((c) => int.tryParse(c['category_id'].toString()) ?? 0));
    }
    if (!mounted) return;

    final result = await showGeneralDialog<Set<int>>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.65),
      transitionDuration: const Duration(milliseconds: 340),
      transitionBuilder: (ctx, anim, _, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
      pageBuilder: (ctx, _, __) => _RefereeDialog(
        existing: existing, nameCtrl: nameCtrl, contactCtrl: contactCtrl,
        categories: _categories, initialSelected: selected,
      ),
    );
    if (result == null) return;

    final name    = nameCtrl.text.trim();
    final contact = contactCtrl.text.trim();
    // ── Name validation ───────────────────────────────────────────────────
    if (name.isEmpty) {
      _snack('Referee name is required.', success: false); return;
    }
    if (name.length < 2) {
      _snack('Name must be at least 2 characters.', success: false); return;
    }
    if (name.length > 100) {
      _snack('Name must not exceed 100 characters.', success: false); return;
    }
    final validName = RegExp(r"^[a-zA-ZÀ-ÿ\s.\-]+$");
    if (!validName.hasMatch(name)) {
      _snack('Name may only contain letters, spaces, hyphens, and periods.', success: false); return;
    }
    // ── Contact validation ────────────────────────────────────────────────
    if (contact.isEmpty) {
      _snack('Contact number is required.', success: false); return;
    }
    if (contact.length != 11) {
      _snack('Contact number must be exactly 11 digits.', success: false); return;
    }
    if (!contact.startsWith('09')) {
      _snack('Contact number must start with 09.', success: false); return;
    }
    try {
      int refereeId;
      if (existing == null) {
        refereeId = await DBHelper.insertReferee(name, contact);
      } else {
        refereeId = int.tryParse(existing['referee_id'].toString()) ?? 0;
        await DBHelper.updateReferee(refereeId, name, contact);
      }
      await DBHelper.setRefereeCategories(refereeId, result.toList());
      await _load();
      if (mounted) _snack('Referee saved successfully!');
    } catch (e) {
      if (mounted) _snack('Error: $e', success: false);
    }
  }

  Future<void> _delete(Map<String, dynamic> ref) async {
    final id   = int.tryParse(ref['referee_id'].toString()) ?? 0;
    final name = ref['referee_name'] ?? '';
    final ok   = await showGeneralDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.65),
      transitionDuration: const Duration(milliseconds: 260),
      transitionBuilder: (ctx, anim, _, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1.0).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
      pageBuilder: (ctx, _, __) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: _kCard,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.redAccent.withOpacity(0.35), width: 1.5),
            boxShadow: [
              BoxShadow(color: Colors.red.withOpacity(0.12), blurRadius: 50),
              BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 30),
            ],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.redAccent.withOpacity(0.08),
                border: Border.all(color: Colors.redAccent.withOpacity(0.3), width: 1.5),
                boxShadow: [BoxShadow(
                    color: Colors.redAccent.withOpacity(0.15), blurRadius: 20, spreadRadius: 2)],
              ),
              child: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent, size: 28),
            ),
            const SizedBox(height: 20),
            const Text('Delete Referee?',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13, height: 1.6),
                children: [
                  const TextSpan(text: 'Are you sure you want to remove\n'),
                  TextSpan(text: '"$name"',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                  const TextSpan(text: '?\nThis action cannot be undone.'),
                ],
              ),
            ),
            const SizedBox(height: 28),
            Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx, false),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.white.withOpacity(0.10)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text('CANCEL', style: TextStyle(
                    color: Colors.white.withOpacity(0.38),
                    fontWeight: FontWeight.bold, letterSpacing: 1)),
              )),
              const SizedBox(width: 12),
              Expanded(child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: const Text('DELETE',
                    style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1)),
              )),
            ]),
          ]),
        ),
      ),
    );
    if (ok != true) return;
    await DBHelper.deleteReferee(id);
    await _load();
    if (mounted) _snack('Referee deleted.', success: false);
  }

  Future<void> _showAccessCodes(Map<String, dynamic> ref) async {
    final id   = int.tryParse(ref['referee_id'].toString()) ?? 0;
    final cats = await DBHelper.getRefereeCategories(id);
    if (!mounted) return;
    final List<Map<String, dynamic>> codesInfo = [];
    for (final c in cats) {
      final catId   = int.tryParse(c['category_id'].toString()) ?? 0;
      final catName = c['category_type']?.toString() ?? '';
      final code    = await DBHelper.getCategoryAccessCode(catId);
      codesInfo.add({'name': catName, 'code': code ?? '—'});
    }
    if (!mounted) return;

    await showGeneralDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.65),
      transitionDuration: const Duration(milliseconds: 300),
      transitionBuilder: (ctx, anim, _, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return SlideTransition(
          position: Tween<Offset>(
              begin: const Offset(0, 0.06), end: Offset.zero).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
      pageBuilder: (ctx, _, __) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 460,
          decoration: BoxDecoration(
            color: _kCard,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: _kAccent.withOpacity(0.25), width: 1.5),
            boxShadow: [
              BoxShadow(color: _kAccent.withOpacity(0.06), blurRadius: 60, spreadRadius: 5),
              BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 30),
            ],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                    colors: [_kGold.withOpacity(0.08), Colors.transparent]),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(23)),
                border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.05))),
              ),
              child: Row(children: [
                Container(
                  width: 42, height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _kGold.withOpacity(0.10),
                    border: Border.all(color: _kGold.withOpacity(0.35)),
                    boxShadow: [BoxShadow(color: _kGold.withOpacity(0.15), blurRadius: 12)],
                  ),
                  child: const Icon(Icons.key_rounded, color: _kGold, size: 18),
                ),
                const SizedBox(width: 14),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('ACCESS CODES',
                      style: TextStyle(color: Colors.white, fontSize: 15,
                          fontWeight: FontWeight.w900, letterSpacing: 2)),
                  Text(ref['referee_name'] ?? '',
                      style: TextStyle(color: _kAccent.withOpacity(0.55), fontSize: 11)),
                ]),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close_rounded,
                      color: Colors.white.withOpacity(0.3), size: 18),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: codesInfo.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Column(children: [
                        Container(
                          width: 64, height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withOpacity(0.03),
                            border: Border.all(color: Colors.white.withOpacity(0.07)),
                          ),
                          child: const Icon(Icons.category_outlined,
                              color: Colors.white24, size: 28),
                        ),
                        const SizedBox(height: 14),
                        Text('No categories assigned.',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.3), fontSize: 13)),
                      ]))
                  : Column(children: [
                      ...codesInfo.map((info) => Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.025),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: _kAccent.withOpacity(0.10)),
                        ),
                        child: Row(children: [
                          Expanded(child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(info['name'], style: const TextStyle(
                                color: Colors.white, fontSize: 13,
                                fontWeight: FontWeight.w700)),
                            const SizedBox(height: 3),
                            Text('ACCESS CODE', style: TextStyle(
                                color: Colors.white.withOpacity(0.22),
                                fontSize: 9, letterSpacing: 1.2)),
                          ])),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 10),
                            decoration: BoxDecoration(
                              color: _kAccent.withOpacity(0.07),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: _kAccent.withOpacity(0.35)),
                              boxShadow: [BoxShadow(
                                  color: _kAccent.withOpacity(0.08), blurRadius: 10)],
                            ),
                            child: Text(info['code'], style: const TextStyle(
                                color: _kAccent, fontSize: 22,
                                fontWeight: FontWeight.w900, letterSpacing: 4)),
                          ),
                          const SizedBox(width: 10),
                          Tooltip(
                            message: 'Copy code',
                            child: GestureDetector(
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: info['code']));
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Code copied!'),
                                        duration: Duration(seconds: 1),
                                        behavior: SnackBarBehavior.floating));
                              },
                              child: Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.04),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                      color: Colors.white.withOpacity(0.08)),
                                ),
                                child: const Icon(Icons.copy_rounded,
                                    size: 15, color: Colors.white38),
                              ),
                            ),
                          ),
                        ]),
                      )),
                      const SizedBox(height: 6),
                      Text(
                          'Referees enter this code to unlock their assigned category.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.2), fontSize: 10)),
                    ]),
            ),
          ]),
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // BUILD
  // ════════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final filtered = _referees.where((r) {
      final q = _search.toLowerCase();
      return q.isEmpty ||
          (r['referee_name'] ?? '').toString().toLowerCase().contains(q) ||
          (r['contact'] ?? '').toString().contains(q);
    }).toList();

    final assigned = _referees.where((r) {
      final id = int.tryParse(r['referee_id'].toString()) ?? 0;
      return (_refCategoriesMap[id] ?? []).isNotEmpty;
    }).length;
    final unassigned = _referees.length - assigned;

    // 4. RESPONSIVE — mobile breakpoint
    final isMobile = MediaQuery.of(context).size.width < 700;

    return Scaffold(
      backgroundColor: _kBg,
      body: Column(children: [
        const RegistrationHeader(),

        // ── Sub-header ────────────────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xFF160B42), Color(0xFF0F0630)],
            ),
            border: Border(bottom: BorderSide(color: _kAccent.withOpacity(0.15))),
          ),
          padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 16 : 24,
              vertical: isMobile ? 10 : 14),
          child: isMobile
              ? _buildMobileHeader(unassigned, assigned)
              : _buildDesktopHeader(unassigned, assigned),
        ),

        // ── Content ───────────────────────────────────────────────────────
        Expanded(child: _loading
            ? _buildShimmerLoading(isMobile)
            : _referees.isEmpty
                ? _buildEmpty()
                : isMobile
                    ? _buildMobileList(filtered)
                    : _buildDesktopList(filtered)),
      ]),
    );
  }

  // ── Mobile header ──────────────────────────────────────────────────────────
  Widget _buildMobileHeader(int unassigned, int assigned) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          GestureDetector(
            onTap: widget.onBack,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: Icon(Icons.arrow_back_ios_new_rounded, color: _kAccent, size: 14),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                  colors: [_kAccent.withOpacity(0.18), _kAccent.withOpacity(0.03)]),
              shape: BoxShape.circle,
              border: Border.all(color: _kAccent.withOpacity(0.3)),
            ),
            child: const Icon(Icons.sports_rounded, color: _kAccent, size: 16),
          ),
          const SizedBox(width: 10),
          const Text('REFEREE REG.',
              style: TextStyle(color: Colors.white, fontSize: 15,
                  fontWeight: FontWeight.w900, letterSpacing: 1.5)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: () => _openDialog(),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text('ADD',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _kAccent, foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _statPill(Icons.groups_rounded, '${_referees.length}', 'TOTAL', Colors.white54),
          const SizedBox(width: 6),
          _statPill(Icons.check_circle_rounded, '$assigned', 'ASSIGNED', _kAccent),
          const SizedBox(width: 6),
          _PulsingPill(count: unassigned),
        ]),
        const SizedBox(height: 10),
        Container(
          height: 38,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: TextField(
            onChanged: (v) => setState(() => _search = v),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search referees…',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.22), fontSize: 13),
              prefixIcon: Icon(Icons.search_rounded,
                  color: _kAccent.withOpacity(0.45), size: 17),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
      ]);

  // ── Desktop header ─────────────────────────────────────────────────────────
  Widget _buildDesktopHeader(int unassigned, int assigned) => Row(children: [
    Tooltip(
      message: 'Go back',
      child: GestureDetector(
        onTap: widget.onBack,
        child: Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Icon(Icons.arrow_back_ios_new_rounded, color: _kAccent, size: 15),
        ),
      ),
    ),
    const SizedBox(width: 16),
    Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
            colors: [_kAccent.withOpacity(0.18), _kAccent.withOpacity(0.03)]),
        shape: BoxShape.circle,
        border: Border.all(color: _kAccent.withOpacity(0.3)),
        boxShadow: [BoxShadow(color: _kAccent.withOpacity(0.12), blurRadius: 12)],
      ),
      child: const Icon(Icons.sports_rounded, color: _kAccent, size: 18),
    ),
    const SizedBox(width: 14),
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('REFEREE REGISTRATION',
          style: TextStyle(color: Colors.white, fontSize: 17,
              fontWeight: FontWeight.w900, letterSpacing: 2)),
      Text('Manage referees & assign categories',
          style: TextStyle(color: Colors.white.withOpacity(0.28), fontSize: 11)),
    ]),
    const Spacer(),
    _statPill(Icons.groups_rounded, '${_referees.length}', 'TOTAL', Colors.white54),
    const SizedBox(width: 8),
    _statPill(Icons.check_circle_rounded, '$assigned', 'ASSIGNED', _kAccent),
    const SizedBox(width: 8),
    _PulsingPill(count: unassigned),   // 3. Pulsing badge
    const SizedBox(width: 20),
    Container(
      width: 220, height: 40,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: TextField(
        onChanged: (v) => setState(() => _search = v),
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          hintText: 'Search referees…',
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.22), fontSize: 13),
          prefixIcon: Icon(Icons.search_rounded,
              color: _kAccent.withOpacity(0.45), size: 17),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    ),
    const SizedBox(width: 12),
    ScaleTransition(
      scale: _fabAnim != null
          ? CurvedAnimation(parent: _fabAnim!, curve: Curves.elasticOut)
          : const AlwaysStoppedAnimation(1.0),
      child: ElevatedButton.icon(
        onPressed: () => _openDialog(),
        icon: const Icon(Icons.add_rounded, size: 18),
        label: const Text('ADD REFEREE',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1, fontSize: 13)),
        style: ElevatedButton.styleFrom(
          backgroundColor: _kAccent,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          elevation: 0,
        ),
      ),
    ),
  ]);

  // ── 1. Shimmer loading ─────────────────────────────────────────────────────
  Widget _buildShimmerLoading(bool isMobile) => SingleChildScrollView(
    padding: EdgeInsets.all(isMobile ? 16 : 24),
    child: Column(children: [
      if (!isMobile) ...[
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: _kCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(0.05)),
          ),
          child: Row(children: [
            const SizedBox(width: 58),
            Expanded(flex: 4, child: _Shimmer(width: 100, height: 10, radius: 5)),
            Expanded(flex: 3, child: _Shimmer(width: 70, height: 10, radius: 5)),
            Expanded(flex: 5, child: _Shimmer(width: 130, height: 10, radius: 5)),
            _Shimmer(width: 60, height: 10, radius: 5),
          ]),
        ),
      ],
      ...List.generate(5, (_) => _ShimmerRow(isMobile: isMobile)),
    ]),
  );

  Widget _buildEmpty() => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        width: 96, height: 96,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _kAccent.withOpacity(0.05),
          border: Border.all(color: _kAccent.withOpacity(0.18), width: 2),
          boxShadow: [BoxShadow(color: _kAccent.withOpacity(0.06), blurRadius: 30)],
        ),
        child: Icon(Icons.sports_rounded,
            color: _kAccent.withOpacity(0.45), size: 42),
      ),
      const SizedBox(height: 24),
      const Text('No Referees Yet',
          style: TextStyle(color: Colors.white, fontSize: 22,
              fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Text('Tap "ADD REFEREE" to register your first referee.',
          style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 13)),
      const SizedBox(height: 28),
      ElevatedButton.icon(
        onPressed: () => _openDialog(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('ADD FIRST REFEREE',
            style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1)),
        style: ElevatedButton.styleFrom(
          backgroundColor: _kAccent, foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
        ),
      ),
    ]),
  );

  // ── Desktop table ──────────────────────────────────────────────────────────
  Widget _buildDesktopList(List<Map<String, dynamic>> filtered) =>
      SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                _kPurple.withOpacity(0.12), _kPurple.withOpacity(0.03)]),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _kPurple.withOpacity(0.15)),
            ),
            child: Row(children: [
              const SizedBox(width: 52), const SizedBox(width: 14),
              Expanded(flex: 4, child: _hdrCell('REFEREE NAME')),
              Expanded(flex: 3, child: _hdrCell('CONTACT')),
              Expanded(flex: 5, child: _hdrCell('ASSIGNED CATEGORIES')),
              _hdrCell('ACTIONS'), const SizedBox(width: 4),
            ]),
          ),
          const SizedBox(height: 10),
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Column(children: [
                Icon(Icons.search_off_rounded, color: Colors.white24, size: 40),
                const SizedBox(height: 12),
                Text('No referees match "$_search".',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.28), fontSize: 14)),
              ]),
            )
          else
            ...filtered.asMap().entries.map((e) => _RefereeRow(
              ref:      e.value, idx: e.key,
              cats:     _refCategoriesMap[
                  int.tryParse(e.value['referee_id'].toString()) ?? 0] ?? [],
              initials: _initials(e.value['referee_name'] ?? ''),
              onEdit:   () => _openDialog(existing: e.value),
              onDelete: () => _delete(e.value),
              onCodes:  () => _showAccessCodes(e.value),
            )),
        ]),
      );

  // ── 4. Mobile card list ────────────────────────────────────────────────────
  Widget _buildMobileList(List<Map<String, dynamic>> filtered) =>
      SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(children: [
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Column(children: [
                Icon(Icons.search_off_rounded, color: Colors.white24, size: 40),
                const SizedBox(height: 12),
                Text('No referees match "$_search".',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.28), fontSize: 14)),
              ]),
            )
          else
            ...filtered.map((r) => _RefereeMobileCard(
              ref:      r,
              cats:     _refCategoriesMap[
                  int.tryParse(r['referee_id'].toString()) ?? 0] ?? [],
              initials: _initials(r['referee_name'] ?? ''),
              onEdit:   () => _openDialog(existing: r),
              onDelete: () => _delete(r),
              onCodes:  () => _showAccessCodes(r),
            )),
        ]),
      );

  Widget _statPill(IconData icon, String value, String label, Color color) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: color.withOpacity(0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.18)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 13),
          const SizedBox(width: 6),
          Text(value, style: TextStyle(
              color: color, fontSize: 13, fontWeight: FontWeight.w800)),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(
              color: color.withOpacity(0.55), fontSize: 9,
              letterSpacing: 1, fontWeight: FontWeight.bold)),
        ]),
      );

  Widget _hdrCell(String t) => Text(t,
      style: TextStyle(color: Colors.white.withOpacity(0.28),
          fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2));
}

// ══════════════════════════════════════════════════════════════════════════════
// DESKTOP ROW WIDGET
// ══════════════════════════════════════════════════════════════════════════════
class _RefereeRow extends StatefulWidget {
  final Map<String, dynamic>       ref;
  final int                        idx;
  final List<Map<String, dynamic>> cats;
  final String                     initials;
  final VoidCallback               onEdit;
  final VoidCallback               onDelete;
  final VoidCallback               onCodes;

  const _RefereeRow({
    required this.ref, required this.idx, required this.cats,
    required this.initials, required this.onEdit,
    required this.onDelete, required this.onCodes,
  });

  @override
  State<_RefereeRow> createState() => _RefereeRowState();
}

class _RefereeRowState extends State<_RefereeRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final name    = widget.ref['referee_name']?.toString() ?? '';
    final contact = widget.ref['contact']?.toString() ?? '';
    final aColor  = _avatarColor(widget.initials);
    final hasCats = widget.cats.isNotEmpty;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 7),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        decoration: BoxDecoration(
          color: _hovered
              ? _kAccent.withOpacity(0.04)
              : widget.idx % 2 == 0 ? _kCard : _kCardAlt,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _hovered
                ? _kAccent.withOpacity(0.25)
                : Colors.white.withOpacity(0.045),
            width: 1.5,
          ),
          boxShadow: _hovered
              ? [BoxShadow(color: _kAccent.withOpacity(0.04), blurRadius: 24)]
              : [],
        ),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [aColor.withOpacity(0.25), aColor.withOpacity(0.06)]),
              border: Border.all(color: aColor.withOpacity(0.5), width: 1.5),
            ),
            child: Center(child: Text(widget.initials,
                style: TextStyle(color: aColor, fontSize: 14,
                    fontWeight: FontWeight.w900))),
          ),
          const SizedBox(width: 14),
          Expanded(flex: 4, child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: const TextStyle(
                  color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Row(children: [
                Container(
                  width: 6, height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hasCats ? _kAccent : Colors.orange,
                    boxShadow: [BoxShadow(
                      color: (hasCats ? _kAccent : Colors.orange).withOpacity(0.5),
                      blurRadius: 4)],
                  ),
                ),
                const SizedBox(width: 6),
                Text(hasCats ? 'Assigned' : 'Unassigned',
                    style: TextStyle(
                        color: hasCats
                            ? _kAccent.withOpacity(0.65)
                            : Colors.orange.withOpacity(0.65),
                        fontSize: 10, fontWeight: FontWeight.w600)),
              ]),
            ],
          )),
          Expanded(flex: 3, child: Row(children: [
            if (contact.isNotEmpty) ...[
              Icon(Icons.phone_rounded,
                  size: 11, color: Colors.white.withOpacity(0.22)),
              const SizedBox(width: 6),
            ],
            Text(contact.isEmpty ? '—' : contact,
                style: TextStyle(
                    color: contact.isEmpty ? Colors.white24 : Colors.white60,
                    fontSize: 13)),
          ])),
          Expanded(flex: 5, child: !hasCats
              ? Row(children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 12, color: Colors.orange.withOpacity(0.4)),
                  const SizedBox(width: 6),
                  Text('None assigned', style: TextStyle(
                      color: Colors.orange.withOpacity(0.4),
                      fontSize: 12, fontStyle: FontStyle.italic)),
                ])
              : Wrap(spacing: 5, runSpacing: 5,
                  children: widget.cats.map((c) {
                    final catName = c['category_type']?.toString() ?? '';
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _kAccent.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: _kAccent.withOpacity(0.25)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(width: 5, height: 5,
                            decoration: const BoxDecoration(
                                shape: BoxShape.circle, color: _kAccent)),
                        const SizedBox(width: 5),
                        Text(catName, style: const TextStyle(
                            color: _kAccent, fontSize: 10,
                            fontWeight: FontWeight.w700)),
                      ]),
                    );
                  }).toList())),
          Row(mainAxisSize: MainAxisSize.min, children: [
            _actionBtn(Icons.key_rounded, _kGold, 'Codes', widget.onCodes),
            const SizedBox(width: 6),
            _actionBtn(Icons.edit_rounded, Colors.white54, 'Edit', widget.onEdit),
            const SizedBox(width: 6),
            _actionBtn(Icons.delete_outline_rounded, Colors.redAccent,
                'Delete', widget.onDelete),
          ]),
        ]),
      ),
    );
  }

  Widget _actionBtn(IconData icon, Color color, String label,
      VoidCallback onTap) =>
      Tooltip(
        message: label,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: color.withOpacity(0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withOpacity(0.20)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 5),
              Text(label, style: TextStyle(
                  color: color, fontSize: 10, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      );
}

// ══════════════════════════════════════════════════════════════════════════════
// 4. MOBILE CARD WIDGET — expandable, tap to reveal categories
// ══════════════════════════════════════════════════════════════════════════════
class _RefereeMobileCard extends StatefulWidget {
  final Map<String, dynamic>       ref;
  final List<Map<String, dynamic>> cats;
  final String                     initials;
  final VoidCallback               onEdit;
  final VoidCallback               onDelete;
  final VoidCallback               onCodes;

  const _RefereeMobileCard({
    required this.ref, required this.cats, required this.initials,
    required this.onEdit, required this.onDelete, required this.onCodes,
  });

  @override
  State<_RefereeMobileCard> createState() => _RefereeMobileCardState();
}

class _RefereeMobileCardState extends State<_RefereeMobileCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _expandAnim;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _expandAnim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    _expanded ? _ctrl.forward() : _ctrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final name    = widget.ref['referee_name']?.toString() ?? '';
    final contact = widget.ref['contact']?.toString() ?? '';
    final aColor  = _avatarColor(widget.initials);
    final hasCats = widget.cats.isNotEmpty;

    return GestureDetector(
      onTap: _toggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _expanded
                ? _kAccent.withOpacity(0.28)
                : Colors.white.withOpacity(0.06),
            width: 1.5,
          ),
          boxShadow: _expanded
              ? [BoxShadow(color: _kAccent.withOpacity(0.05), blurRadius: 20)]
              : [],
        ),
        child: Column(children: [
          // Main row
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                    colors: [aColor.withOpacity(0.28), aColor.withOpacity(0.07)]),
                  border: Border.all(color: aColor.withOpacity(0.55), width: 1.5),
                ),
                child: Center(child: Text(widget.initials,
                    style: TextStyle(color: aColor, fontSize: 15,
                        fontWeight: FontWeight.w900))),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(
                      color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Row(children: [
                    Container(
                      width: 6, height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: hasCats ? _kAccent : Colors.orange,
                        boxShadow: [BoxShadow(
                          color: (hasCats ? _kAccent : Colors.orange).withOpacity(0.5),
                          blurRadius: 4)],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(hasCats ? 'Assigned' : 'Unassigned',
                        style: TextStyle(
                            color: hasCats
                                ? _kAccent.withOpacity(0.7)
                                : Colors.orange.withOpacity(0.7),
                            fontSize: 11, fontWeight: FontWeight.w600)),
                    if (contact.isNotEmpty) ...[
                      const SizedBox(width: 10),
                      Icon(Icons.phone_rounded,
                          size: 11, color: Colors.white.withOpacity(0.25)),
                      const SizedBox(width: 4),
                      Text(contact, style: TextStyle(
                          color: Colors.white.withOpacity(0.45), fontSize: 11)),
                    ],
                  ]),
                ],
              )),
              // Action icon buttons
              Row(mainAxisSize: MainAxisSize.min, children: [
                _mobileAction(Icons.key_rounded, _kGold, widget.onCodes),
                const SizedBox(width: 6),
                _mobileAction(Icons.edit_rounded, Colors.white54, widget.onEdit),
                const SizedBox(width: 6),
                _mobileAction(Icons.delete_outline_rounded,
                    Colors.redAccent, widget.onDelete),
              ]),
            ]),
          ),

          // Expandable categories section
          SizeTransition(
            sizeFactor: _expandAnim,
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                    top: BorderSide(color: Colors.white.withOpacity(0.05))),
              ),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('ASSIGNED CATEGORIES',
                    style: TextStyle(color: _kAccent, fontSize: 9,
                        fontWeight: FontWeight.w700, letterSpacing: 1.2)),
                const SizedBox(height: 8),
                !hasCats
                    ? Row(children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 13, color: Colors.orange.withOpacity(0.5)),
                        const SizedBox(width: 6),
                        Text('No categories assigned yet',
                            style: TextStyle(
                                color: Colors.orange.withOpacity(0.5),
                                fontSize: 12, fontStyle: FontStyle.italic)),
                      ])
                    : Wrap(spacing: 6, runSpacing: 6,
                        children: widget.cats.map((c) {
                          final catName = c['category_type']?.toString() ?? '';
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: _kAccent.withOpacity(0.07),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: _kAccent.withOpacity(0.28)),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Container(width: 5, height: 5,
                                  decoration: const BoxDecoration(
                                      shape: BoxShape.circle, color: _kAccent)),
                              const SizedBox(width: 5),
                              Text(catName, style: const TextStyle(
                                  color: _kAccent, fontSize: 11,
                                  fontWeight: FontWeight.w700)),
                            ]),
                          );
                        }).toList()),
              ]),
            ),
          ),

          // Expand chevron
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              border: Border(
                  top: BorderSide(color: Colors.white.withOpacity(0.04))),
            ),
            child: Center(
              child: AnimatedRotation(
                turns: _expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 220),
                child: Icon(Icons.keyboard_arrow_down_rounded,
                    color: Colors.white.withOpacity(0.2), size: 18),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _mobileAction(IconData icon, Color color, VoidCallback onTap) =>
      GestureDetector(
        // Use onTapDown to stop propagation to the card toggle
        onTap: () => onTap(),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withOpacity(0.07),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: color.withOpacity(0.22)),
          ),
          child: Icon(icon, size: 15, color: color),
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
    required this.existing, required this.nameCtrl,
    required this.contactCtrl, required this.categories,
    required this.initialSelected,
  });

  @override
  State<_RefereeDialog> createState() => _RefereeDialogState();
}

class _RefereeDialogState extends State<_RefereeDialog> {
  late final Set<int> _selected;
  bool get _isEdit => widget.existing != null;
  int _phoneLen = 0;

  @override
  void initState() {
    super.initState();
    _selected = Set.from(widget.initialSelected);
    _phoneLen = widget.contactCtrl.text.length;
    widget.contactCtrl.addListener(() {
      if (mounted) setState(() => _phoneLen = widget.contactCtrl.text.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 520,
        constraints: const BoxConstraints(maxHeight: 700),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: _kAccent.withOpacity(0.25), width: 1.5),
          boxShadow: [
            BoxShadow(color: _kAccent.withOpacity(0.06), blurRadius: 70, spreadRadius: 5),
            BoxShadow(color: _kPurple.withOpacity(0.10), blurRadius: 40),
            BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 30),
          ],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [

          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                  colors: [_kAccent.withOpacity(0.08), Colors.transparent]),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(23)),
              border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.05))),
            ),
            child: Row(children: [
              Container(
                width: 42, height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _kAccent.withOpacity(0.09),
                  border: Border.all(color: _kAccent.withOpacity(0.3)),
                  boxShadow: [BoxShadow(
                      color: _kAccent.withOpacity(0.12), blurRadius: 12)],
                ),
                child: const Icon(Icons.sports_rounded, color: _kAccent, size: 18),
              ),
              const SizedBox(width: 14),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_isEdit ? 'EDIT REFEREE' : 'NEW REFEREE',
                    style: const TextStyle(color: Colors.white, fontSize: 16,
                        fontWeight: FontWeight.w900, letterSpacing: 2)),
                Text(_isEdit
                    ? 'Update referee info & categories'
                    : 'Fill in details to register a referee',
                    style: TextStyle(color: Colors.white.withOpacity(0.28), fontSize: 11)),
              ]),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.close_rounded,
                    color: Colors.white.withOpacity(0.25), size: 18),
                onPressed: () => Navigator.pop(context, null),
              ),
            ]),
          ),

          // Form body
          Flexible(child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

              _label('REFEREE NAME'),
              const SizedBox(height: 8),
              _field(controller: widget.nameCtrl,
                  hint: 'e.g. Juan dela Cruz', icon: Icons.person_rounded,
                  maxLength: 100,
                  inputFormatters: [LengthLimitingTextInputFormatter(100)]),

              const SizedBox(height: 20),

              Row(children: [
                _label('CONTACT NUMBER'),
                const SizedBox(width: 8),
                Text('(required, starts with 09)', style: TextStyle(
                    color: Colors.white.withOpacity(0.2),
                    fontSize: 9, fontStyle: FontStyle.italic)),
                const Spacer(),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: _phoneLen == 11
                        ? _kAccent.withOpacity(0.12)
                        : _phoneLen > 0
                            ? Colors.orange.withOpacity(0.10)
                            : Colors.white.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _phoneLen == 11
                          ? _kAccent.withOpacity(0.4)
                          : _phoneLen > 0
                              ? Colors.orange.withOpacity(0.3)
                              : Colors.white.withOpacity(0.08),
                    ),
                  ),
                  child: Text('$_phoneLen / 11',
                      style: TextStyle(
                        color: _phoneLen == 11
                            ? _kAccent
                            : _phoneLen > 0 ? Colors.orange : Colors.white38,
                        fontSize: 10, fontWeight: FontWeight.w700,
                      )),
                ),
              ]),
              const SizedBox(height: 8),
              _field(
                controller: widget.contactCtrl,
                hint: 'e.g. 09123456789',
                icon: Icons.phone_rounded,
                inputType: TextInputType.phone,
                maxLength: 11,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(11),
                ],
              ),

              const SizedBox(height: 22),

              Row(children: [
                _label('ASSIGN CATEGORIES'),
                const SizedBox(width: 10),
                if (_selected.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(
                      color: _kAccent.withOpacity(0.09),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _kAccent.withOpacity(0.3)),
                    ),
                    child: Text('${_selected.length} selected',
                        style: const TextStyle(color: _kAccent, fontSize: 9,
                            fontWeight: FontWeight.w700)),
                  ),
              ]),
              const SizedBox(height: 10),

              ...widget.categories.map((cat) {
                final id      = int.tryParse(cat['category_id'].toString()) ?? 0;
                final name    = cat['category_type']?.toString() ?? '';
                final active  = (cat['status'] ?? 'active').toString() == 'active';
                final checked = _selected.contains(id);

                return GestureDetector(
                  onTap: active ? () => setState(() {
                    if (checked) _selected.remove(id);
                    else _selected.add(id);
                  }) : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                    decoration: BoxDecoration(
                      color: checked
                          ? _kAccent.withOpacity(0.06)
                          : Colors.white.withOpacity(0.02),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: checked
                            ? _kAccent.withOpacity(0.40)
                            : Colors.white.withOpacity(0.07),
                        width: checked ? 1.5 : 1,
                      ),
                    ),
                    child: Row(children: [
                      Container(
                        width: 7, height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: active ? _kAccent : Colors.white24,
                          boxShadow: active ? [BoxShadow(
                              color: _kAccent.withOpacity(0.4), blurRadius: 4)] : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, style: TextStyle(
                              color: active ? Colors.white : Colors.white38,
                              fontSize: 13, fontWeight: FontWeight.w700)),
                          if (!active)
                            Text('Inactive', style: TextStyle(
                                color: Colors.white24, fontSize: 9,
                                fontStyle: FontStyle.italic)),
                        ],
                      )),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        width: 22, height: 22,
                        decoration: BoxDecoration(
                          color: checked ? _kAccent : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: checked
                                ? _kAccent : Colors.white.withOpacity(0.16),
                            width: 1.5,
                          ),
                          boxShadow: checked ? [BoxShadow(
                              color: _kAccent.withOpacity(0.3), blurRadius: 6)] : null,
                        ),
                        child: checked
                            ? const Icon(Icons.check_rounded, size: 14, color: Colors.black)
                            : null,
                      ),
                    ]),
                  ),
                );
              }),
            ]),
          )),

          // Footer
          Container(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 22),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
            ),
            child: Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => Navigator.pop(context, null),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.white.withOpacity(0.10)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text('CANCEL', style: TextStyle(
                    color: Colors.white.withOpacity(0.35),
                    fontWeight: FontWeight.bold, letterSpacing: 1)),
              )),
              const SizedBox(width: 12),
              Expanded(child: ElevatedButton(
                onPressed: () => Navigator.pop(context, Set<int>.from(_selected)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                  shadowColor: _kAccent.withOpacity(0.4),
                ),
                child: Text(_isEdit ? 'SAVE CHANGES' : 'ADD REFEREE',
                    style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1)),
              )),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(color: _kAccent, fontSize: 10,
          fontWeight: FontWeight.w700, letterSpacing: 1.2));

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
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
          hintStyle: TextStyle(
              color: Colors.white.withOpacity(0.18), fontSize: 13),
          prefixIcon: Icon(icon, color: _kAccent.withOpacity(0.4), size: 18),
          counterText: '',
          filled: true,
          fillColor: Colors.white.withOpacity(0.035),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(13),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.09)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(13),
            borderSide: const BorderSide(color: _kAccent, width: 1.5),
          ),
        ),
      );
}