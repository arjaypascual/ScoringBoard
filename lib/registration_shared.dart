// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';

// ── Accent colors per step ────────────────────────────────────────────────────
const kStepColors = [
  Color(0xFF00CFFF), // Step 1 — blue
  Color(0xFF967BB6), // Step 2 — lavender
  Color(0xFFFFD700), // Step 3 — gold
  Color(0xFF00E5A0), // Step 4 — emerald
];
const kStepLabels = ['School', 'Mentor', 'Team', 'Players'];

// ═══════════════════════════════════════════════════════════════════════════════
// FIELD VALIDATOR
// Pure static helpers — each returns null if valid, or a clear error String.
//
// Example:
//   ValidatedField(
//     validator: (v) => FieldValidator.phoneNumber(v),
//   )
// ═══════════════════════════════════════════════════════════════════════════════

class FieldValidator {
  // ── School name ──────────────────────────────────────────────────────────
  static String? schoolName(String value) {
    final v = value.trim();
    if (v.isEmpty) {
      return 'School name is required.';
    }
    if (v.length < 3) {
      return 'School name is too short — please enter at least 3 characters.';
    }
    if (v.length > 120) {
      return 'School name is too long — maximum 120 characters.';
    }
    if (RegExp(r'^\d+$').hasMatch(v)) {
      return 'School name cannot be numbers only.';
    }
    return null;
  }

  // ── Generic person name (mentor, referee) ────────────────────────────────
  static String? personName(String value, {String fieldName = 'Name'}) {
    final v = value.trim();
    if (v.isEmpty) {
      return '$fieldName is required.';
    }
    if (v.length < 2) {
      return '$fieldName is too short — please enter at least 2 characters.';
    }
    if (v.length > 100) {
      return '$fieldName is too long — maximum 100 characters.';
    }
    if (!RegExp(r'[a-zA-ZñÑáéíóúÁÉÍÓÚ]').hasMatch(v)) {
      return '$fieldName must contain at least one letter.';
    }
    return null;
  }

  // ── Player full name (first + last required) ─────────────────────────────
  static String? playerName(String value, {int playerNum = 1}) {
    final v = value.trim();
    if (v.isEmpty) {
      return 'Player $playerNum name is required.';
    }
    if (v.length < 4) {
      return 'Please enter the full name of Player $playerNum.';
    }
    if (!v.contains(' ')) {
      return 'Please enter both first and last name for Player $playerNum.';
    }
    if (v.length > 100) {
      return 'Player $playerNum name is too long — maximum 100 characters.';
    }
    return null;
  }

  // ── Philippine mobile number ─────────────────────────────────────────────
  static String? phoneNumber(String value) {
    final v = value.trim();
    if (v.isEmpty) {
      return 'Contact number is required.';
    }
    if (!RegExp(r'^\d+$').hasMatch(v)) {
      return 'Contact number must contain digits only — no spaces or dashes.';
    }
    if (v.length < 11) {
      return 'Contact number is too short — must be exactly 11 digits.';
    }
    if (v.length > 11) {
      return 'Contact number is too long — must be exactly 11 digits.';
    }
    if (!v.startsWith('09')) {
      return 'Contact number must start with 09 (e.g. 09XXXXXXXXX).';
    }
    return null;
  }

  // ── Team name ─────────────────────────────────────────────────────────────
  static String? teamName(String value) {
    final v = value.trim();
    if (v.isEmpty) {
      return 'Team name is required.';
    }
    if (v.length < 2) {
      return 'Team name is too short — please enter at least 2 characters.';
    }
    if (v.length > 60) {
      return 'Team name is too long — maximum 60 characters.';
    }
    return null;
  }

  // ── Birthdate (YYYY-MM-DD, age 5–25) ─────────────────────────────────────
  static String? birthdate(String value, {int playerNum = 1}) {
    final v = value.trim();
    if (v.isEmpty) {
      return 'Birthdate for Player $playerNum is required.';
    }
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(v)) {
      return 'Birthdate must be in YYYY-MM-DD format (e.g. 2010-05-14).';
    }
    DateTime dt;
    try {
      dt = DateTime.parse(v);
    } catch (_) {
      return 'Birthdate is not a valid date — please check month and day.';
    }
    final now = DateTime.now();
    if (dt.isAfter(now)) {
      return 'Birthdate cannot be a future date.';
    }
    final age = now.year -
        dt.year -
        (now.month < dt.month ||
                (now.month == dt.month && now.day < dt.day)
            ? 1
            : 0);
    if (age < 5) {
      return 'Player $playerNum seems too young — please check the birthdate.';
    }
    if (age > 25) {
      return 'Player $playerNum seems too old — please check the birthdate.';
    }
    return null;
  }

  // ── Generic required ──────────────────────────────────────────────────────
  static String? required(String value, {String fieldName = 'This field'}) {
    if (value.trim().isEmpty) return '$fieldName is required.';
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// VALIDATED FIELD
//
// Drop-in replacement for buildField().
// • Shows inline error below the field (animated slide-in/out)
// • Green checkmark when valid after user interaction
// • Red border + red icon when invalid
// • Optional live character counter (set maxLength:)
//
// HOW TO USE:
//
//   1. Declare a key in your State:
//        final _nameKey = GlobalKey<ValidatedFieldState>();
//
//   2. Place the widget:
//        ValidatedField(
//          key: _nameKey,
//          label: 'MENTOR NAME',
//          hint: 'Enter mentor name',
//          controller: _nameCtrl,
//          icon: Icons.person_rounded,
//          accentColor: _accent,
//          isRequired: true,
//          validator: (v) => FieldValidator.personName(v, fieldName: 'Mentor name'),
//        )
//
//   3. On submit button pressed:
//        final err = _nameKey.currentState?.validate();
//        if (err != null) return; // block submission
// ═══════════════════════════════════════════════════════════════════════════════

class ValidatedField extends StatefulWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final IconData icon;
  final Color accentColor;
  final bool isRequired;
  final bool isOptional;
  final TextInputType keyboardType;
  final String? Function(String)? validator;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLength;
  final bool readOnly;
  final VoidCallback? onTap;
  final Widget? suffix;

  const ValidatedField({
    super.key,
    required this.label,
    required this.hint,
    required this.controller,
    required this.icon,
    required this.accentColor,
    this.isRequired = false,
    this.isOptional = false,
    this.keyboardType = TextInputType.text,
    this.validator,
    this.inputFormatters,
    this.maxLength,
    this.readOnly = false,
    this.onTap,
    this.suffix,
  });

  @override
  State<ValidatedField> createState() => ValidatedFieldState();
}

class ValidatedFieldState extends State<ValidatedField> {
  String? _error;
  bool _dirty = false;

  /// Called by parent on submit. Returns error string or null if valid.
  String? validate() {
    final err = widget.validator?.call(widget.controller.text);
    setState(() {
      _error = err;
      _dirty = true;
    });
    return err;
  }

  /// Resets validation state (call after successful registration).
  void reset() => setState(() {
        _error = null;
        _dirty = false;
      });

  bool get _hasError => _dirty && _error != null;
  bool get _isOk => _dirty && _error == null && widget.validator != null;

  @override
  Widget build(BuildContext context) {
    final borderColor = _hasError
        ? Colors.redAccent.withOpacity(0.7)
        : _isOk
            ? const Color(0xFF00E5A0).withOpacity(0.7)
            : Colors.white.withOpacity(0.15);

    final focusColor = _hasError
        ? Colors.redAccent
        : _isOk
            ? const Color(0xFF00E5A0)
            : widget.accentColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Label row ─────────────────────────────────────────────────────
        Row(children: [
          Text(widget.label,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  letterSpacing: 1)),
          if (widget.isRequired)
            Text(' *',
                style: TextStyle(
                    color: widget.accentColor, fontWeight: FontWeight.bold)),
          if (widget.isOptional)
            Text('  (optional)',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.35), fontSize: 11)),
          const Spacer(),
          // Live character counter
          if (widget.maxLength != null)
            AnimatedBuilder(
              animation: widget.controller,
              builder: (_, __) {
                final len  = widget.controller.text.length;
                final full = len == widget.maxLength;
                return Text('$len / ${widget.maxLength}',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: full
                            ? const Color(0xFF00E5A0)
                            : Colors.white.withOpacity(0.35)));
              },
            ),
        ]),
        const SizedBox(height: 8),

        // ── Text field ────────────────────────────────────────────────────
        TextField(
          controller: widget.controller,
          keyboardType: widget.keyboardType,
          readOnly: widget.readOnly,
          onTap: widget.onTap,
          inputFormatters: widget.inputFormatters,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          onChanged: (_) {
            // Live re-validation once user has already attempted submit
            if (_dirty) {
              setState(() =>
                  _error = widget.validator?.call(widget.controller.text));
            }
          },
          decoration: InputDecoration(
            hintText: widget.hint,
            hintStyle: TextStyle(
                color: Colors.white.withOpacity(0.25), fontSize: 13),
            prefixIcon: Icon(widget.icon,
                color: _hasError
                    ? Colors.redAccent.withOpacity(0.8)
                    : widget.accentColor.withOpacity(0.7),
                size: 20),
            suffixIcon: widget.suffix ??
                (_hasError
                    ? const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(Icons.error_outline_rounded,
                            color: Colors.redAccent, size: 18))
                    : _isOk
                        ? Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(Icons.check_circle_outline_rounded,
                                color: const Color(0xFF00E5A0), size: 18))
                        : null),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            filled: true,
            fillColor: _hasError
                ? Colors.red.withOpacity(0.05)
                : Colors.white.withOpacity(0.05),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: focusColor, width: 2),
            ),
          ),
        ),

        // ── Inline error — animated slide + fade ──────────────────────────
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          transitionBuilder: (child, anim) => SizeTransition(
            sizeFactor: anim,
            child: FadeTransition(opacity: anim, child: child),
          ),
          child: _hasError
              ? Padding(
                  key: ValueKey(_error),
                  padding: const EdgeInsets.only(top: 7, left: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 1),
                        child: Icon(Icons.info_rounded,
                            color: Colors.redAccent, size: 13),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(_error!,
                            style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 11,
                                height: 1.4)),
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(key: ValueKey('__ok__')),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// SHARED PREMIUM HEADER
// ═══════════════════════════════════════════════════════════════════════════════

class RegistrationHeader extends StatelessWidget {
  const RegistrationHeader({super.key});

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
          SizedBox(
            height: 44, width: 160,
            child: Image.asset('assets/images/RoboventureLogo.png',
                fit: BoxFit.contain, alignment: Alignment.centerLeft),
          ),
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
            child: Image.asset('assets/images/CenterLogo.png',
                height: 70, fit: BoxFit.contain),
          ),
          SizedBox(
            height: 44, width: 160,
            child: Image.asset('assets/images/CreotecLogo.png',
                fit: BoxFit.contain, alignment: Alignment.centerRight),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// STEP INDICATOR
// ═══════════════════════════════════════════════════════════════════════════════

class StepIndicator extends StatelessWidget {
  final int activeStep;
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

        return Row(children: [
          Column(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutBack,
              width: isActive ? 48 : 44,
              height: isActive ? 48 : 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: isActive
                    ? LinearGradient(colors: [color, color.withOpacity(0.7)])
                    : null,
                color: isDone
                    ? color.withOpacity(0.8)
                    : !isActive
                        ? Colors.white.withOpacity(0.08)
                        : null,
                border: Border.all(
                  color: isActive || isDone
                      ? color
                      : Colors.white.withOpacity(0.2),
                  width: 2,
                ),
                boxShadow: isActive
                    ? [
                        BoxShadow(
                            color: color.withOpacity(0.5),
                            blurRadius: 16,
                            spreadRadius: 2)
                      ]
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
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
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
                  fontWeight:
                      isActive ? FontWeight.bold : FontWeight.normal,
                  letterSpacing: 0.5,
                )),
          ]),
          if (step < 4)
            Container(
              width: 80, height: 2,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                gradient: isDone
                    ? LinearGradient(
                        colors: [color, kStepColors[index + 1]])
                    : LinearGradient(colors: [
                        Colors.white.withOpacity(0.1),
                        Colors.white.withOpacity(0.1),
                      ]),
              ),
            ),
        ]);
      }),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// REGISTRATION CARD
// ═══════════════════════════════════════════════════════════════════════════════

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
          BoxShadow(
              color: color.withOpacity(0.08),
              blurRadius: 40,
              spreadRadius: 4),
          BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 30,
              offset: const Offset(0, 10)),
        ],
      ),
      child: child,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// LEGACY buildField — still works, prefer ValidatedField for new code
// ═══════════════════════════════════════════════════════════════════════════════

Widget buildField({
  required String label,
  required String hint,
  required TextEditingController controller,
  required IconData icon,
  required Color accentColor,
  bool isRequired = false,
  bool isOptional = false,
  TextInputType keyboardType = TextInputType.text,
  String? errorText,
}) {
  final hasError = errorText != null && errorText.isNotEmpty;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Text(label,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 12,
                letterSpacing: 1)),
        if (isRequired)
          Text(' *',
              style: TextStyle(
                  color: accentColor, fontWeight: FontWeight.bold)),
        if (isOptional)
          Text('  (optional)',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.35), fontSize: 11)),
      ]),
      const SizedBox(height: 8),
      TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle:
              TextStyle(color: Colors.white.withOpacity(0.25), fontSize: 13),
          prefixIcon: Icon(icon,
              color: hasError
                  ? Colors.redAccent.withOpacity(0.8)
                  : accentColor.withOpacity(0.7),
              size: 20),
          suffixIcon: hasError
              ? const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.error_outline_rounded,
                      color: Colors.redAccent, size: 18))
              : null,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          filled: true,
          fillColor: hasError
              ? Colors.red.withOpacity(0.05)
              : Colors.white.withOpacity(0.05),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
                color: hasError
                    ? Colors.redAccent.withOpacity(0.7)
                    : Colors.white.withOpacity(0.15)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
                color: hasError ? Colors.redAccent : accentColor, width: 2),
          ),
          errorText: errorText,
          errorStyle:
              const TextStyle(color: Colors.redAccent, fontSize: 11),
        ),
      ),
    ],
  );
}

// ── Info note ─────────────────────────────────────────────────────────────────
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
        const Icon(Icons.info_outline_rounded,
            color: Color(0xFFFFD700), size: 15),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  color: const Color(0xFFFFD700).withOpacity(0.85),
                  fontSize: 11,
                  height: 1.5)),
        ),
      ],
    ),
  );
}

// ── Button row ────────────────────────────────────────────────────────────────
Widget buildButtonRow({
  required VoidCallback? onSkip,
  required VoidCallback? onRegister,
  required bool isLoading,
  required Color accentColor,
  required IconData registerIcon,
  String skipLabel     = 'SKIP',
  String registerLabel = 'REGISTER',
}) {
  return Row(
    children: [
      Expanded(
        child: OutlinedButton(
          onPressed: onSkip,
          style: OutlinedButton.styleFrom(
            side: BorderSide(
                color: Colors.white.withOpacity(0.2), width: 1.5),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(skipLabel,
              style: TextStyle(
                  color: Colors.white.withOpacity(0.55),
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                  fontSize: 13)),
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
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          child: Ink(
            decoration: BoxDecoration(
              gradient: onRegister != null
                  ? LinearGradient(
                      colors: [accentColor, accentColor.withOpacity(0.7)])
                  : null,
              color: onRegister == null
                  ? Colors.white.withOpacity(0.08)
                  : null,
              borderRadius: BorderRadius.circular(10),
              boxShadow: onRegister != null
                  ? [
                      BoxShadow(
                          color: accentColor.withOpacity(0.4),
                          blurRadius: 16,
                          spreadRadius: 1)
                    ]
                  : [],
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
                        Icon(registerIcon,
                            color: onRegister != null
                                ? Colors.white
                                : Colors.white38,
                            size: 18),
                        const SizedBox(width: 8),
                        Text(registerLabel,
                            style: TextStyle(
                                color: onRegister != null
                                    ? Colors.white
                                    : Colors.white38,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.5,
                                fontSize: 13)),
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