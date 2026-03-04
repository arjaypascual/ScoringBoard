import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'main.dart';
import 'schedule_viewer.dart';
import 'standings.dart';
import 'teams_players.dart';

class LandingPage extends StatefulWidget {
  const LandingPage({super.key});

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage>
    with TickerProviderStateMixin {
  late AnimationController _bgController;
  late AnimationController _logoController;
  late AnimationController _buttonsController;

  late Animation<double> _logoScale;
  late Animation<double> _logoOpacity;
  late Animation<double> _btn1Offset;
  late Animation<double> _btn2Offset;
  late Animation<double> _btn3Offset;
  late Animation<double> _btn4Offset;
  late Animation<double> _btn1Opacity;
  late Animation<double> _btn2Opacity;
  late Animation<double> _btn3Opacity;
  late Animation<double> _btn4Opacity;

  @override
  void initState() {
    super.initState();

    // Background rotation
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();

    // Logo entrance
    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _logoScale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.elasticOut),
    );
    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _logoController,
          curve: const Interval(0.0, 0.5, curve: Curves.easeIn)),
    );

    // Buttons staggered entrance
    _buttonsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _btn1Offset = Tween<double>(begin: 60.0, end: 0.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic)),
    );
    _btn2Offset = Tween<double>(begin: 60.0, end: 0.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.2, 0.75, curve: Curves.easeOutCubic)),
    );
    _btn3Offset = Tween<double>(begin: 60.0, end: 0.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.4, 0.9, curve: Curves.easeOutCubic)),
    );
    _btn4Offset = Tween<double>(begin: 60.0, end: 0.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.5, 1.0, curve: Curves.easeOutCubic)),
    );
    _btn1Opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.0, 0.5, curve: Curves.easeIn)),
    );
    _btn2Opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.2, 0.65, curve: Curves.easeIn)),
    );
    _btn3Opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.4, 0.8, curve: Curves.easeIn)),
    );
    _btn4Opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.5, 0.9, curve: Curves.easeIn)),
    );

    // Start animations
    Future.delayed(const Duration(milliseconds: 200), () {
      _logoController.forward();
    });
    Future.delayed(const Duration(milliseconds: 800), () {
      _buttonsController.forward();
    });
  }

  @override
  void dispose() {
    _bgController.dispose();
    _logoController.dispose();
    _buttonsController.dispose();
    super.dispose();
  }

  void _goToRegistration() {
    Navigator.of(context).push(
      _buildRoute(const RegistrationFlow()),
    );
  }

  void _goToSchedule() {
    Navigator.of(context).push(
      _buildRoute(ScheduleViewer(
        onRegister:  () => Navigator.of(context).pop(),
        onStandings: () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            _buildRoute(Standings(
              onBack: () => Navigator.of(context).pop(),
            )),
          );
        },
      )),
    );
  }

  void _goToStandings() {
    Navigator.of(context).push(
      _buildRoute(Standings(
        onBack: () => Navigator.of(context).pop(),
      )),
    );
  }

  void _goToTeams() {
    Navigator.of(context).push(
      _buildRoute(TeamsPlayers(
        onBack: () => Navigator.of(context).pop(),
      )),
    );
  }

  PageRoute _buildRoute(Widget page) {
    return PageRouteBuilder(
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, anim, __, child) {
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.05, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
            child: child,
          ),
        );
      },
      transitionDuration: const Duration(milliseconds: 350),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: Stack(
        children: [
          // ── Animated background ──────────────────────────────────────
          _buildBackground(size),

          // ── Geometric circuit decorations ────────────────────────────
          _buildCircuitLines(size),

          // ── Main content ─────────────────────────────────────────────
          SafeArea(
            child: Column(
              children: [
                // Header bar
                _buildTopBar(),

                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Logo
                          AnimatedBuilder(
                            animation: _logoController,
                            builder: (_, __) => Opacity(
                              opacity: _logoOpacity.value,
                              child: Transform.scale(
                                scale: _logoScale.value,
                                child: _buildLogo(),
                              ),
                            ),
                          ),

                          const SizedBox(height: 12), // reduced from 16

                          // Subtitle
                          AnimatedBuilder(
                            animation: _logoController,
                            builder: (_, __) => Opacity(
                              opacity: _logoOpacity.value,
                              child: const Text(
                                '4TH ROBOTICS COMPETITION',
                                style: TextStyle(
                                  color: Color(0xFF00CFFF),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 3,
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(height: 36), // reduced from 56

                          // Buttons
                          AnimatedBuilder(
                            animation: _buttonsController,
                            builder: (_, __) => Column(
                              children: [
                                _animatedButton(
                                  offset: _btn1Offset.value,
                                  opacity: _btn1Opacity.value,
                                  child: _NavButton(
                                    label: 'REGISTRATION',
                                    icon: Icons.app_registration_rounded,
                                    color: const Color(0xFF00CFFF),
                                    onTap: _goToRegistration,
                                  ),
                                ),
                                const SizedBox(height: 14), // reduced from 20
                                _animatedButton(
                                  offset: _btn2Offset.value,
                                  opacity: _btn2Opacity.value,
                                  child: _NavButton(
                                    label: 'SCHEDULE',
                                    icon: Icons.calendar_month_rounded,
                                    color: const Color(0xFF7B2FFF),
                                    onTap: _goToSchedule,
                                  ),
                                ),
                                const SizedBox(height: 14), // reduced from 20
                                _animatedButton(
                                  offset: _btn3Offset.value,
                                  opacity: _btn3Opacity.value,
                                  child: _NavButton(
                                    label: 'STANDINGS',
                                    icon: Icons.emoji_events_rounded,
                                    color: const Color(0xFFFFD700),
                                    onTap: _goToStandings,
                                  ),
                                ),
                                const SizedBox(height: 14), // reduced from 20
                                _animatedButton(
                                  offset: _btn4Offset.value,
                                  opacity: _btn4Opacity.value,
                                  child: _NavButton(
                                    label: 'TEAMS & PLAYERS',
                                    icon: Icons.groups_rounded,
                                    color: const Color(0xFF00E5A0),
                                    onTap: _goToTeams,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // Footer
                _buildFooter(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Background ───────────────────────────────────────────────────────────
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
        builder: (_, __) {
          return CustomPaint(
            painter: _OrbitPainter(_bgController.value),
          );
        },
      ),
    );
  }

  // ── Circuit line decorations ─────────────────────────────────────────────
  Widget _buildCircuitLines(Size size) {
    return Positioned.fill(
      child: CustomPaint(
        painter: _CircuitPainter(),
      ),
    );
  }

  // ── Top bar ──────────────────────────────────────────────────────────────
  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: const TextSpan(children: [
                  TextSpan(
                      text: 'Make',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                  TextSpan(
                      text: 'bl',
                      style: TextStyle(
                          color: Color(0xFF00CFFF),
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                  TextSpan(
                      text: 'ock',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                ]),
              ),
              const Text('Construct Your Dreams',
                  style: TextStyle(color: Colors.white38, fontSize: 9)),
            ],
          ),
          Image.asset('assets/images/CenterLogo.png',
              height: 70, fit: BoxFit.contain),
          const Text('CREOTEC',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 3)),
        ],
      ),
    );
  }

  // ── Logo ─────────────────────────────────────────────────────────────────
  Widget _buildLogo() {
    return Column(
      children: [
        Container(
          width: 180,
          height: 180,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7B2FFF).withOpacity(0.4),
                blurRadius: 60,
                spreadRadius: 20,
              ),
              BoxShadow(
                color: const Color(0xFF00CFFF).withOpacity(0.2),
                blurRadius: 40,
                spreadRadius: 10,
              ),
            ],
          ),
          child: Image.asset(
            'assets/images/RoboVentureLogo.png',
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _buildTextLogo(),
          ),
        ),
      ],
    );
  }

  Widget _buildTextLogo() {
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        colors: [Color(0xFF7B2FFF), Color(0xFF00CFFF), Color(0xFF7B2FFF)],
        stops: [0.0, 0.5, 1.0],
      ).createShader(bounds),
      child: const Text(
        'RoboVenture',
        style: TextStyle(
          color: Colors.white,
          fontSize: 48,
          fontWeight: FontWeight.w900,
          letterSpacing: 2,
        ),
      ),
    );
  }

  // ── Footer ───────────────────────────────────────────────────────────────
  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16), // reduced from 20
      child: Text(
        '© 2025 RoboVenture • Powered by Creotec',
        style: TextStyle(
          color: Colors.white.withOpacity(0.25),
          fontSize: 11,
          letterSpacing: 1,
        ),
      ),
    );
  }

  Widget _animatedButton({
    required double offset,
    required double opacity,
    required Widget child,
  }) {
    return Opacity(
      opacity: opacity,
      child: Transform.translate(
        offset: Offset(0, offset),
        child: child,
      ),
    );
  }
}

// ── Nav Button ───────────────────────────────────────────────────────────────
class _NavButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _NavButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _hoverController;
  late Animation<double> _scaleAnim;
  late Animation<double> _glowAnim;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _hoverController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.04).animate(
      CurvedAnimation(parent: _hoverController, curve: Curves.easeOut),
    );
    _glowAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _hoverController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _hoverController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        _hoverController.forward();
      },
      onExit: (_) {
        setState(() => _hovered = false);
        _hoverController.reverse();
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _hoverController,
          builder: (_, __) {
            return Transform.scale(
              scale: _scaleAnim.value,
              child: Container(
                width: double.infinity,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: widget.color
                        .withOpacity(0.4 + 0.4 * _glowAnim.value),
                    width: 1.5,
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      widget.color
                          .withOpacity(0.08 + 0.12 * _glowAnim.value),
                      widget.color
                          .withOpacity(0.03 + 0.06 * _glowAnim.value),
                    ],
                  ),
                  boxShadow: _hovered
                      ? [
                          BoxShadow(
                            color: widget.color.withOpacity(0.35),
                            blurRadius: 24,
                            spreadRadius: 2,
                          ),
                        ]
                      : [],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(widget.icon, color: widget.color, size: 22),
                    const SizedBox(width: 14),
                    Text(
                      widget.label,
                      style: TextStyle(
                        color: _hovered ? widget.color : Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2.5,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ── Orbit painter (rotating bg rings) ────────────────────────────────────────
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

// ── Circuit painter (static decorative lines) ────────────────────────────────
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