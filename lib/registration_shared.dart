// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'dart:async';

// ── Accent colors per step ────────────────────────────────────────────────────
const kStepColors = [
  Color(0xFF00CFFF),  // Step 1 — blue
  Color(0xFF967BB6),  // Step 2 — lavender
  Color(0xFFFFD700),  // Step 3 — gold
  Color(0xFF00E5A0),  // Step 4 — emerald
];
const kStepLabels  = ['School', 'Mentor', 'Team', 'Players'];

// ── Shared premium header ─────────────────────────────────────────────────────
class RegistrationHeader extends StatefulWidget {
  const RegistrationHeader({super.key});

  @override
  State<RegistrationHeader> createState() => _RegistrationHeaderState();
}

class _RegistrationHeaderState extends State<RegistrationHeader> {

  @override
  Widget build(BuildContext context) {
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
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [

          // ── Left: Makeblock logo — flush, no border ───────────────
          SizedBox(
            height: 44,
            width: 160,
            child: Image.asset(
              'assets/images/RoboventureLogo.png',
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
            ),
          ),

          // ── Center: CenterLogo with glow ──────────────────────────
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                    color: const Color(0xFF7B2FFF).withOpacity(0.35),
                    blurRadius: 24, spreadRadius: 4),
                BoxShadow(
                    color: const Color(0xFF00CFFF).withOpacity(0.15),
                    blurRadius: 16, spreadRadius: 2),
              ],
            ),
            child: Image.asset(
              'assets/images/CenterLogo.png',
              height: 70,
              fit: BoxFit.contain,
            ),
          ),

          // ── Right: CREOTEC logo — flush, no border ────────────────
          SizedBox(
            height: 44,
            width: 160,
            child: Image.asset(
              'assets/images/CreotecLogo.png',
              fit: BoxFit.contain,
              alignment: Alignment.centerRight,
            ),
          ),

        ],
      ),
    );
  }
}


// ── Standalone live clock badge (self-contained timer) ───────────────────────
class _LiveClockBadge extends StatefulWidget {
  const _LiveClockBadge();

  @override
  State<_LiveClockBadge> createState() => _LiveClockBadgeState();
}

class _LiveClockBadgeState extends State<_LiveClockBadge>
    with SingleTickerProviderStateMixin {
  late Timer _timer;
  late DateTime _now;
  late AnimationController _pulse;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    _pulse.dispose();
    super.dispose();
  }

  String get _time {
    final h = _now.hour.toString().padLeft(2, '0');
    final m = _now.minute.toString().padLeft(2, '0');
    final s = _now.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D2B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: const Color(0xFF00E5A0).withOpacity(0.35), width: 1),
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF00E5A0).withOpacity(0.12),
              blurRadius: 8),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulseAnim,
            builder: (_, __) => Container(
              width: 7, height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF00E5A0).withOpacity(_pulseAnim.value),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00E5A0).withOpacity(_pulseAnim.value * 0.6),
                    blurRadius: 6, spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 5),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('LIVE',
                  style: TextStyle(
                    color: Color(0xFF00E5A0),
                    fontSize: 8, fontWeight: FontWeight.w800,
                    letterSpacing: 1.5, height: 1.0,
                  )),
              Text(_time,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13, fontWeight: FontWeight.bold,
                    letterSpacing: 1, height: 1.2,
                  )),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Shared step indicator ─────────────────────────────────────────────────────
class StepIndicator extends StatelessWidget {
  final int activeStep; // 1-based

  const StepIndicator({super.key, required this.activeStep});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        final step     = index + 1;
        final isActive = step == activeStep;
        final isDone   = step < activeStep;
        final color    = kStepColors[index];

        return Row(
          children: [
            Column(
              children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: isActive
                        ? LinearGradient(colors: [color, color.withOpacity(0.7)])
                        : null,
                    color: isDone
                        ? color.withOpacity(0.8)
                        : !isActive ? Colors.white.withOpacity(0.08) : null,
                    border: Border.all(
                      color: isActive || isDone
                          ? color : Colors.white.withOpacity(0.2),
                      width: 2,
                    ),
                    boxShadow: isActive
                        ? [BoxShadow(color: color.withOpacity(0.5),
                            blurRadius: 16, spreadRadius: 2)]
                        : [],
                  ),
                  child: Center(
                    child: isDone
                        ? const Icon(Icons.check, color: Colors.white, size: 20)
                        : Text('$step',
                            style: TextStyle(
                              color: isActive
                                  ? Colors.white
                                  : Colors.white.withOpacity(0.3),
                              fontWeight: FontWeight.bold, fontSize: 16,
                            )),
                  ),
                ),
                const SizedBox(height: 6),
                Text(kStepLabels[index],
                    style: TextStyle(
                      color: isActive
                          ? color
                          : isDone
                              ? color.withOpacity(0.6)
                              : Colors.white.withOpacity(0.3),
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
                decoration: BoxDecoration(
                  gradient: isDone
                      ? LinearGradient(colors: [color, kStepColors[index + 1]])
                      : LinearGradient(colors: [
                          Colors.white.withOpacity(0.1),
                          Colors.white.withOpacity(0.1),
                        ]),
                ),
              ),
          ],
        );
      }),
    );
  }
}

// ── Shared dark card wrapper ──────────────────────────────────────────────────
class RegistrationCard extends StatelessWidget {
  final Widget child;
  final int activeStep;
  final double width;

  const RegistrationCard({
    super.key,
    required this.child,
    required this.activeStep,
    this.width = 680,
  });

  @override
  Widget build(BuildContext context) {
    final color = kStepColors[activeStep - 1];
    return Container(
      width: width,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2D0E7A), Color(0xFF1E0A5A)],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withOpacity(0.35), width: 1.5),
        boxShadow: [
          BoxShadow(color: color.withOpacity(0.08), blurRadius: 40, spreadRadius: 4),
          BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 30,
              offset: const Offset(0, 10)),
        ],
      ),
      child: child,
    );
  }
}

// ── Shared field builder ──────────────────────────────────────────────────────
Widget buildField({
  required String label,
  required String hint,
  required TextEditingController controller,
  required IconData icon,
  required Color accentColor,
  bool isRequired = false,
  bool isOptional = false,
  TextInputType keyboardType = TextInputType.text,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white,
                  fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 1)),
          if (isRequired)
            Text(' *', style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
          if (isOptional)
            Text('  (optional)',
                style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 11)),
        ],
      ),
      const SizedBox(height: 8),
      TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.25), fontSize: 13),
          prefixIcon: Icon(icon, color: accentColor.withOpacity(0.7), size: 20),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          filled: true,
          fillColor: Colors.white.withOpacity(0.05),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.15)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: accentColor, width: 2),
          ),
        ),
      ),
    ],
  );
}

// ── Shared info note ──────────────────────────────────────────────────────────
Widget buildInfoNote(String text) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xFFFFD700).withOpacity(0.06),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.20)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline_rounded, color: Color(0xFFFFD700), size: 15),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: TextStyle(
                color: const Color(0xFFFFD700).withOpacity(0.85),
                fontSize: 11, height: 1.5,
              )),
        ),
      ],
    ),
  );
}

// ── Shared button row ─────────────────────────────────────────────────────────
Widget buildButtonRow({
  required VoidCallback? onSkip,
  required VoidCallback? onRegister,
  required bool isLoading,
  required Color accentColor,
  required IconData registerIcon,
  String skipLabel   = 'SKIP',
  String registerLabel = 'REGISTER',
}) {
  return Row(
    children: [
      Expanded(
        child: OutlinedButton(
          onPressed: onSkip,
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: Colors.white.withOpacity(0.2), width: 1.5),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(skipLabel,
              style: TextStyle(
                color: Colors.white.withOpacity(0.55),
                fontWeight: FontWeight.bold, letterSpacing: 1.5, fontSize: 13,
              )),
        ),
      ),
      const SizedBox(width: 16),
      Expanded(
        flex: 2,
        child: ElevatedButton(
          onPressed: isLoading ? null : onRegister,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Ink(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                  colors: [accentColor, accentColor.withOpacity(0.7)]),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(color: accentColor.withOpacity(0.4),
                    blurRadius: 16, spreadRadius: 1),
              ],
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              alignment: Alignment.center,
              child: isLoading
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(registerIcon, color: Colors.white, size: 18),
                        const SizedBox(width: 8),
                        Text(registerLabel,
                            style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold,
                              letterSpacing: 1.5, fontSize: 13,
                            )),
                      ],
                    ),
            ),
          ),
        ),
      ),
    ],
  );
}

// ── Gradient divider ──────────────────────────────────────────────────────────
Widget buildDivider(Color color) {
  return Container(
    height: 1,
    decoration: BoxDecoration(
      gradient: LinearGradient(colors: [
        Colors.transparent,
        color.withOpacity(0.5),
        Colors.transparent,
      ]),
    ),
  );
}