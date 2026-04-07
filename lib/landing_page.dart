// ignore_for_file: deprecated_member_use, unnecessary_underscores

import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'main.dart';
import 'schedule_viewer.dart';
import 'standings.dart';
import 'generate_schedule.dart';
import 'teams_players.dart';  // ADDED: import for TeamsPlayers
import 'dashboard.dart';

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

    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();

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

    _buttonsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _btn1Offset = Tween<double>(begin: 60.0, end: 0.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic)),
    );
    _btn2Offset = Tween<double>(begin: 60.0, end: 0.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.15, 0.70, curve: Curves.easeOutCubic)),
    );
    _btn3Offset = Tween<double>(begin: 60.0, end: 0.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.30, 0.82, curve: Curves.easeOutCubic)),
    );
    _btn4Offset = Tween<double>(begin: 60.0, end: 0.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.48, 1.0, curve: Curves.easeOutCubic)),
    );

    _btn1Opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.0, 0.45, curve: Curves.easeIn)),
    );
    _btn2Opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.15, 0.60, curve: Curves.easeIn)),
    );
    _btn3Opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.30, 0.72, curve: Curves.easeIn)),
    );
    _btn4Opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _buttonsController,
          curve: const Interval(0.48, 0.88, curve: Curves.easeIn)),
    );

    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) _logoController.forward();
    });
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) _buttonsController.forward();
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
    Navigator.of(context).push(_buildRoute(const RegistrationFlow()));
  }

  void _goToSchedule() {
    Navigator.of(context).push(
      _buildRoute(ScheduleViewer(
        onRegister: () => Navigator.of(context).pop(),
        onStandings: () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            _buildRoute(Standings(onBack: () => Navigator.of(context).pop())),
          );
        },
      )),
    );
  }

  void _goToStandings() {
    Navigator.of(context).push(
      _buildRoute(Standings(onBack: () => Navigator.of(context).pop())),
    );
  }

  void _goToGenerateSchedule() {
    Navigator.of(context).push(
      _buildRoute(GenerateSchedule(
        onBack: () => Navigator.of(context).pop(),
        onGenerated: () {
          Navigator.of(context).pop();
          _goToSchedule();
        },
      )),
    );
  }

  // ADDED: Navigation to TeamsPlayers page
  void _goToTeamsPlayers() {
    Navigator.of(context).push(
      _buildRoute(TeamsPlayers(
        onBack: () => Navigator.of(context).pop(),
      )),
    );
  }

  void _goToDashboard() {
    Navigator.of(context).push(
      _buildRoute(Dashboard(
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
          _buildBackground(size),
          _buildCircuitLines(size),
          SafeArea(
            child: Column(
              children: [
                // ── Header bar ─────────────────────────────────────────
                Container(
                  margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.08),
                      width: 1.0,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Roboventure logo container
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F0FA),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFF00CFFF).withOpacity(0.50),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF00CFFF).withOpacity(0.30),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                            BoxShadow(
                              color: const Color(0xFF7B2FFF).withOpacity(0.25),
                              blurRadius: 28,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Image.asset(
                          'assets/images/RoboventureLogo.png',
                          height: 36,
                          fit: BoxFit.contain,
                        ),
                      ),
                      // Center divider label
                      Text(
                        'PHILIPPINE ROBOTICS CUP 2026',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.20),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2.0,
                        ),
                      ),
                      // Creotec logo container
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F0FA),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFF00CFFF).withOpacity(0.50),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF00CFFF).withOpacity(0.30),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                            BoxShadow(
                              color: const Color(0xFF7B2FFF).withOpacity(0.25),
                              blurRadius: 28,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Image.asset(
                          'assets/images/CreotecLogo.png',
                          height: 36,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ],
                  ),
                ),

                Expanded(
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: size.height -
                            MediaQuery.of(context).padding.top -
                            MediaQuery.of(context).padding.bottom -
                            80, // header + footer approx
                      ),
                      child: IntrinsicHeight(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 540),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const SizedBox(height: 8),

                                  // ── Logo ──────────────────────────────────────
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
                                  const SizedBox(height: 20),

                                  // ── Buttons ───────────────────────────────────
                                  AnimatedBuilder(
                                    animation: _buttonsController,
                                    builder: (_, __) => Column(
                                      children: [

                                        // 1 ── REGISTRATION (primary)
                                        _animBtn(
                                          offset:  _btn1Offset.value,
                                          opacity: _btn1Opacity.value,
                                          child: _NavButton(
                                            label:     'REGISTRATION',
                                            subtitle:  'Register teams, mentors & players',
                                            icon:      Icons.app_registration_rounded,
                                            color:     const Color(0xFF00CFFF),
                                            isPrimary: true,
                                            onTap:     _goToRegistration,
                                          ),
                                        ),
                                        const SizedBox(height: 10),

                                        // 2 ── SCHEDULE + STANDINGS
                                        _animBtn(
                                          offset:  _btn2Offset.value,
                                          opacity: _btn2Opacity.value,
                                          child: Row(children: [
                                            Expanded(
                                              child: _NavButton(
                                                label:    'SCHEDULE',
                                                subtitle: 'View match schedule',
                                                icon:     Icons.calendar_month_rounded,
                                                color:    const Color(0xFF967BB6),
                                                onTap:    _goToSchedule,
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: _NavButton(
                                                label:    'STANDINGS',
                                                subtitle: 'View leaderboard',
                                                icon:     Icons.emoji_events_rounded,
                                                color:    const Color(0xFFFFD700),
                                                onTap:    _goToStandings,
                                              ),
                                            ),
                                          ]),
                                        ),
                                        const SizedBox(height: 10),

                                        // 3 ── GENERATE SCHEDULE
                                        _animBtn(
                                          offset:  _btn3Offset.value,
                                          opacity: _btn3Opacity.value,
                                          child: _NavButton(
                                            label:    'GENERATE SCHEDULE',
                                            subtitle: 'Auto-generate match brackets',
                                            icon:     Icons.auto_awesome_rounded,
                                            color:    const Color(0xFF00E5A0),
                                            onTap:    _goToGenerateSchedule,
                                          ),
                                        ),
                                        const SizedBox(height: 14),

                                        // 4 ── Teams & Players + Dashboard row
                                        _animBtn(
                                          offset:  _btn4Offset.value,
                                          opacity: _btn4Opacity.value,
                                          child: Row(children: [
                                            Expanded(child: _TeamsLink(
                                              icon: Icons.groups_rounded,
                                              label: 'View Teams & Players',
                                              onTap: _goToTeamsPlayers,
                                            )),
                                            const SizedBox(width: 10),
                                            Expanded(child: _TeamsLink(
                                              icon: Icons.dashboard_rounded,
                                              label: 'Dashboard',
                                              onTap: _goToDashboard,
                                            )),
                                          ]),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                _buildFooter(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackground(Size size) {
    return Container(
      width: size.width,
      height: size.height,
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.0, -0.2),
          radius: 1.4,
          colors: [
            Color(0xFF1E0B50),
            Color(0xFF0D0A2E),
            Color(0xFF060412),
          ],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
      child: Stack(
        children: [
          CustomPaint(
            size: Size(size.width, size.height),
            painter: _GridPainter(),
          ),
          AnimatedBuilder(
            animation: _bgController,
            builder: (_, __) =>
                CustomPaint(painter: _OrbitPainter(_bgController.value)),
          ),
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.center,
                colors: [Color(0x55000010), Colors.transparent],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              height: size.height * 0.3,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xAA060412), Colors.transparent],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCircuitLines(Size size) {
    return Positioned.fill(child: CustomPaint(painter: _CircuitPainter()));
  }

  Widget _buildLogo() {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Outer glow ring
        Container(
          width: 210,
          height: 210,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xFF7B2FFF).withOpacity(0.20),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7B2FFF).withOpacity(0.45),
                blurRadius: 80,
                spreadRadius: 25,
              ),
              BoxShadow(
                color: const Color(0xFF00CFFF).withOpacity(0.25),
                blurRadius: 50,
                spreadRadius: 10,
              ),
            ],
          ),
        ),
        // Inner subtle ring
        Container(
          width: 198,
          height: 198,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xFF00CFFF).withOpacity(0.12),
              width: 1.0,
            ),
          ),
        ),
        Image.asset('assets/images/CenterLogo.png',
            width: 185, height: 185, fit: BoxFit.contain),
      ],
    );
  }

  Widget _buildFooter() {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 6, height: 6,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF00CFFF),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '© 2026 RoboVenture',
            style: TextStyle(
              color: Colors.white.withOpacity(0.35),
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w500,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Container(width: 1, height: 12,
              color: Colors.white.withOpacity(0.15)),
          ),
          Text(
            'Powered by Creotec Philippines, Inc.',
            style: TextStyle(
              color: Colors.white.withOpacity(0.25),
              fontSize: 11,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            width: 6, height: 6,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF7B2FFF),
            ),
          ),
        ],
      ),
    );
  }

  Widget _animBtn({
    required double offset,
    required double opacity,
    required Widget child,
  }) {
    return Opacity(
      opacity: opacity,
      child: Transform.translate(offset: Offset(0, offset), child: child),
    );
  }
}

// ── Nav Button ────────────────────────────────────────────────────────────────
class _NavButton extends StatefulWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final Color color;
  final bool isPrimary;
  final VoidCallback onTap;

  const _NavButton({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
    this.isPrimary = false,
  });

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _hoverCtrl;
  late Animation<double> _scaleAnim;
  late Animation<double> _glowAnim;

  @override
  void initState() {
    super.initState();
    _hoverCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 180));
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.03)
        .animate(CurvedAnimation(parent: _hoverCtrl, curve: Curves.easeOut));
    _glowAnim = Tween<double>(begin: 0.0, end: 1.0)
        .animate(CurvedAnimation(parent: _hoverCtrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _hoverCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double height = widget.isPrimary ? 76 : 64;

    return MouseRegion(
      onEnter: (_) => _hoverCtrl.forward(),
      onExit:  (_) => _hoverCtrl.reverse(),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _hoverCtrl,
          builder: (_, __) => Transform.scale(
            scale: _scaleAnim.value,
            child: Container(
              width: double.infinity,
              height: height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.isPrimary ? 16 : 12),
                gradient: widget.isPrimary
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          widget.color,
                          widget.color.withOpacity(0.75),
                          const Color(0xFF0099CC),
                        ],
                      )
                    : LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          widget.color
                              .withOpacity(0.10 + 0.12 * _glowAnim.value),
                          widget.color
                              .withOpacity(0.04 + 0.06 * _glowAnim.value),
                        ],
                      ),
                border: widget.isPrimary
                    ? null
                    : Border.all(
                        color: widget.color
                            .withOpacity(0.5 + 0.4 * _glowAnim.value),
                        width: 1.5,
                      ),
                boxShadow: _hoverCtrl.value > 0
                    ? [
                        BoxShadow(
                          color: widget.color.withOpacity(
                              widget.isPrimary ? 0.55 : 0.30),
                          blurRadius: widget.isPrimary ? 32 : 20,
                          spreadRadius: widget.isPrimary ? 4 : 1,
                        ),
                      ]
                    : widget.isPrimary
                        ? [
                            BoxShadow(
                              color: widget.color.withOpacity(0.30),
                              blurRadius: 20, spreadRadius: 2,
                            ),
                          ]
                        : [],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.isPrimary)
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.2),
                      ),
                      child: Icon(widget.icon, color: Colors.white, size: 22),
                    )
                  else
                    Icon(widget.icon, color: widget.color, size: 22),
                  const SizedBox(width: 14),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.label,
                        style: TextStyle(
                          color: widget.isPrimary ? Colors.white : Colors.white,
                          fontSize: widget.isPrimary ? 18 : 15,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2.5,
                        ),
                      ),
                      Text(
                        widget.subtitle,
                        style: TextStyle(
                          color: widget.isPrimary
                              ? Colors.white.withOpacity(0.75)
                              : widget.color.withOpacity(0.6),
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Subtle text link (Teams & Players / Dashboard) ───────────────────────────
class _TeamsLink extends StatefulWidget {
  final VoidCallback onTap;
  final IconData icon;
  final String label;
  const _TeamsLink({
    required this.onTap,
    this.icon  = Icons.groups_rounded,
    this.label = 'View Teams & Players',
  });

  @override
  State<_TeamsLink> createState() => _TeamsLinkState();
}

class _TeamsLinkState extends State<_TeamsLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _hovered
                ? const Color(0xFF7B2FFF).withOpacity(0.12)
                : Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hovered
                  ? const Color(0xFF7B2FFF).withOpacity(0.40)
                  : Colors.white.withOpacity(0.08),
              width: 1.0,
            ),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color: const Color(0xFF7B2FFF).withOpacity(0.15),
                      blurRadius: 12, spreadRadius: 1,
                    )
                  ]
                : [],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon,
                  size: 16,
                  color: Colors.white.withOpacity(_hovered ? 0.75 : 0.40)),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: TextStyle(
                  color: Colors.white.withOpacity(_hovered ? 0.75 : 0.40),
                  fontSize: 12,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Grid mesh painter ─────────────────────────────────────────────────────────
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF7B2FFF).withOpacity(0.06)
      ..strokeWidth = 0.6
      ..style = PaintingStyle.stroke;
    const spacing = 48.0;
    for (double x = 0; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    // Dot intersections
    final dotPaint = Paint()
      ..color = const Color(0xFF7B2FFF).withOpacity(0.12)
      ..style = PaintingStyle.fill;
    for (double x = 0; x < size.width; x += spacing) {
      for (double y = 0; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 1.2, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}

// ── Orbit painter ─────────────────────────────────────────────────────────────
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
      canvas.drawCircle(
        Offset(cx + math.cos(angle) * 30, cy + math.sin(angle) * 20),
        radius,
        Paint()
          ..color = const Color(0xFF7B2FFF).withOpacity(0.04 - i * 0.01)
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    final radial = RadialGradient(colors: [
      const Color(0xFF7B2FFF).withOpacity(0.15),
      Colors.transparent,
    ]);
    canvas.drawCircle(
      Offset(cx, cy), 300,
      Paint()
        ..shader = radial.createShader(
            Rect.fromCircle(center: Offset(cx, cy), radius: 300)),
    );
  }

  @override
  bool shouldRepaint(_OrbitPainter old) => old.progress != progress;
}

// ── Circuit painter ───────────────────────────────────────────────────────────
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

    for (final o in [
      const Offset(40, 200), const Offset(80, 280), const Offset(40, 420),
    ]) { canvas.drawCircle(o, 3, dotPaint); }
    for (final o in [
      Offset(size.width - 40, 240),
      Offset(size.width - 90, 320),
      Offset(size.width - 40, 460),
    ]) { canvas.drawCircle(o, 3, dotPaint); }
  }

  @override
  bool shouldRepaint(_CircuitPainter old) => false;
}