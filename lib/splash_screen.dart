// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'db_helper.dart';
import 'landing_page.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // ── Animation controllers ────────────────────────────────────────────────
  late AnimationController _bgController;   // rotating orbit rings
  late AnimationController _logoController; // logo entrance
  late AnimationController _barController;  // progress bar fill
  late AnimationController _pulseController; // logo glow pulse

  late Animation<double> _logoScale;
  late Animation<double> _logoOpacity;
  late Animation<double> _barProgress;
  late Animation<double> _pulseAnim;

  // ── State ────────────────────────────────────────────────────────────────
  String _statusText = 'Initializing...';
  bool   _hasError   = false;

  static const _steps = [
    'Initializing...',
    'Connecting to database...',
    'Running migrations...',
    'Loading assets...',
    'Ready!',
  ];

  @override
  void initState() {
    super.initState();

    // Background orbit (loops forever)
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();

    // Logo entrance: scale + fade
    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _logoScale = Tween<double>(begin: 0.55, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.elasticOut),
    );
    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _logoController,
          curve: const Interval(0.0, 0.45, curve: Curves.easeIn)),
    );

    // Progress bar
    _barController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _barProgress = Tween<double>(begin: 0.0, end: 0.0).animate(
      CurvedAnimation(parent: _barController, curve: Curves.easeInOut),
    );

    // Logo glow pulse
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Kick off the startup sequence
    Future.delayed(const Duration(milliseconds: 200), () {
      _logoController.forward();
    });
    Future.delayed(const Duration(milliseconds: 600), _runStartup);
  }

  // ── Startup sequence ─────────────────────────────────────────────────────
  Future<void> _runStartup() async {
    await _setStep(0, 0.10); // Initializing
    await Future.delayed(const Duration(milliseconds: 350));

    await _setStep(1, 0.35); // Connecting DB
    try {
      await DBHelper.getConnection();
    } catch (e) {
      _showError('Database connection failed: $e');
      return;
    }

    await _setStep(2, 0.60); // Running migrations
    try {
      await DBHelper.runMigrations();
    } catch (e) {
      _showError('Migration failed: $e');
      return;
    }

    await _setStep(3, 0.85); // Loading assets
    await Future.delayed(const Duration(milliseconds: 400));

    await _setStep(4, 1.00); // Ready!
    await Future.delayed(const Duration(milliseconds: 600));

    _navigateToHome();
  }

  Future<void> _setStep(int index, double progress) async {
    if (!mounted) return;
    setState(() => _statusText = _steps[index]);
    _animateBar(progress);
    await Future.delayed(const Duration(milliseconds: 320));
  }

  void _animateBar(double target) {
    final double from = _barProgress.value;
    _barProgress = Tween<double>(begin: from, end: target).animate(
      CurvedAnimation(parent: _barController, curve: Curves.easeInOut),
    );
    _barController
      ..reset()
      ..forward();
  }

  void _showError(String msg) {
    if (!mounted) return;
    setState(() {
      _hasError   = true;
      _statusText = msg;
    });
    _animateBar(0.0);
  }

  void _navigateToHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const LandingPage(),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: anim,
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 600),
      ),
    );
  }

  @override
  void dispose() {
    _bgController.dispose();
    _logoController.dispose();
    _barController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: Stack(
        children: [
          // ── Animated background ──────────────────────────────────────
          _buildBackground(size),

          // ── Circuit line decorations (matches landing_page.dart) ─────
          Positioned.fill(child: CustomPaint(painter: _CircuitPainter())),

          // ── Main content ─────────────────────────────────────────────
          SafeArea(
            child: Column(
              children: [
                // ── Center: logo + loading card ───────────────────────
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Logo with pulse glow
                          AnimatedBuilder(
                            animation: Listenable.merge(
                                [_logoController, _pulseController]),
                            builder: (_, __) => Opacity(
                              opacity: _logoOpacity.value,
                              child: Transform.scale(
                                scale: _logoScale.value,
                                child: _buildLogo(),
                              ),
                            ),
                          ),

                          const SizedBox(height: 40),

                          // Loading card
                          _buildLoadingCard(),
                        ],
                      ),
                    ),
                  ),
                ),

                // ── Footer ───────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    '© 2026 RoboVenture • Powered by Creotec',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.25),
                      fontSize: 11,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Logo ─────────────────────────────────────────────────────────────────
  Widget _buildLogo() {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (_, __) => Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF7B2FFF)
                  .withOpacity(0.35 + 0.15 * _pulseAnim.value),
              blurRadius: 60 + 20 * _pulseAnim.value,
              spreadRadius: 15,
            ),
            BoxShadow(
              color: const Color(0xFF00CFFF)
                  .withOpacity(0.15 + 0.1 * _pulseAnim.value),
              blurRadius: 40,
              spreadRadius: 5,
            ),
          ],
        ),
        child: Image.asset(
          'assets/images/CenterLogo.png',
          width: 260,
          height: 260,
          fit: BoxFit.contain,
        ),
      ),
    );
  }

  // ── Loading card ─────────────────────────────────────────────────────────
  Widget _buildLoadingCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      decoration: BoxDecoration(
        color: const Color(0xFF130840).withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: (_hasError
                  ? const Color(0xFFFF5252)
                  : const Color(0xFF00CFFF))
              .withOpacity(0.3),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF7B2FFF).withOpacity(0.12),
            blurRadius: 32,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── App name row ───────────────────────────────────────────
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _hasError
                      ? const Color(0xFFFF5252)
                      : const Color(0xFF00CFFF),
                  boxShadow: [
                    BoxShadow(
                      color: (_hasError
                              ? const Color(0xFFFF5252)
                              : const Color(0xFF00CFFF))
                          .withOpacity(0.8),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'ROBOVENTURE',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 3,
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // ── Progress bar ──────────────────────────────────────────
          AnimatedBuilder(
            animation: _barProgress,
            builder: (_, __) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Stack(
                      children: [
                        // Track
                        Container(
                          height: 4,
                          width: double.infinity,
                          color: Colors.white.withOpacity(0.07),
                        ),
                        // Fill
                        FractionallySizedBox(
                          widthFactor: _barProgress.value,
                          child: Container(
                            height: 4,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: _hasError
                                    ? [
                                        const Color(0xFFFF5252),
                                        const Color(0xFFFF8A80),
                                      ]
                                    : [
                                        const Color(0xFF7B2FFF),
                                        const Color(0xFF00CFFF),
                                        const Color(0xFF00E5A0),
                                      ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${(_barProgress.value * 100).toInt()}%',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.35),
                      fontSize: 11,
                      fontFamily: 'monospace',
                      letterSpacing: 1,
                    ),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 14),

          // ── Status text ───────────────────────────────────────────
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            child: Row(
              key: ValueKey(_statusText),
              children: [
                if (!_hasError)
                  _PulsingDot()
                else
                  const Icon(Icons.error_outline,
                      color: Color(0xFFFF5252), size: 14),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _statusText,
                    style: TextStyle(
                      color: _hasError
                          ? const Color(0xFFFF5252)
                          : const Color(0xFF00CFFF).withOpacity(0.8),
                      fontSize: 12,
                      fontFamily: 'monospace',
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Retry button (only on error) ──────────────────────────
          if (_hasError) ...[
            const SizedBox(height: 20),
            GestureDetector(
              onTap: () {
                setState(() {
                  _hasError   = false;
                  _statusText = 'Retrying...';
                });
                _runStartup();
              },
              child: Container(
                width: double.infinity,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: const Color(0xFF00CFFF).withOpacity(0.5)),
                  color: const Color(0xFF00CFFF).withOpacity(0.08),
                ),
                child: const Center(
                  child: Text(
                    'RETRY',
                    style: TextStyle(
                      color: Color(0xFF00CFFF),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Background (same orbit rings as LandingPage) ──────────────────────────
  Widget _buildBackground(Size size) {
    return Container(
      width: size.width,
      height: size.height,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF0A0520),
            Color(0xFF1A0A4A),
            Color(0xFF0D1535),
          ],
          stops: [0.0, 0.5, 1.0],
        ),
      ),
      child: AnimatedBuilder(
        animation: _bgController,
        builder: (_, __) => CustomPaint(
          painter: _OrbitPainter(_bgController.value),
        ),
      ),
    );
  }
}

// ── Pulsing dot indicator ─────────────────────────────────────────────────────
class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF00CFFF).withOpacity(_anim.value),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF00CFFF).withOpacity(_anim.value * 0.8),
              blurRadius: 6,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Orbit rings painter (copied from LandingPage) ─────────────────────────────
class _OrbitPainter extends CustomPainter {
  final double progress;
  _OrbitPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    for (int i = 0; i < 3; i++) {
      final radius = 200.0 + i * 160;
      final angle  = progress * 2 * math.pi + i * (math.pi / 3);
      final paint  = Paint()
        ..color = const Color(0xFF7B2FFF).withOpacity(0.04 - i * 0.01)
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 1.5;

      canvas.drawCircle(
        Offset(cx + math.cos(angle) * 30, cy + math.sin(angle) * 20),
        radius,
        paint,
      );
    }

    final radial = RadialGradient(
      colors: [
        const Color(0xFF7B2FFF).withOpacity(0.15),
        Colors.transparent,
      ],
    );
    canvas.drawCircle(
      Offset(cx, cy),
      300,
      Paint()
        ..shader = radial.createShader(
            Rect.fromCircle(center: Offset(cx, cy), radius: 300)),
    );
  }

  @override
  bool shouldRepaint(_OrbitPainter old) => old.progress != progress;
}

// ── Circuit lines painter (copied from LandingPage) ───────────────────────────
class _CircuitPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color       = const Color(0xFF3D1A8C).withOpacity(0.25)
      ..strokeWidth = 1.0
      ..style       = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = const Color(0xFF00CFFF).withOpacity(0.3)
      ..style = PaintingStyle.fill;

    final leftPath = Path()
      ..moveTo(40, 80)
      ..lineTo(40, 200)
      ..lineTo(80, 200)
      ..lineTo(80, 280)
      ..lineTo(20, 280)
      ..moveTo(40, 340)
      ..lineTo(40, 420)
      ..lineTo(100, 420);

    final rightPath = Path()
      ..moveTo(size.width - 40, 120)
      ..lineTo(size.width - 40, 240)
      ..lineTo(size.width - 90, 240)
      ..lineTo(size.width - 90, 320)
      ..moveTo(size.width - 40, 380)
      ..lineTo(size.width - 40, 460)
      ..lineTo(size.width - 110, 460);

    canvas.drawPath(leftPath, paint);
    canvas.drawPath(rightPath, paint);

    for (final offset in [
      const Offset(40, 200),
      const Offset(80, 280),
      const Offset(40, 420),
    ]) {
      canvas.drawCircle(offset, 3, dotPaint);
    }
    for (final offset in [
      Offset(size.width - 40, 240),
      Offset(size.width - 90, 320),
      Offset(size.width - 40, 460),
    ]) {
      canvas.drawCircle(offset, 3, dotPaint);
    }
  }

  @override
  bool shouldRepaint(_CircuitPainter old) => false;
}