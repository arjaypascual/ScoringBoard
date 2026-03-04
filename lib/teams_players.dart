import 'package:flutter/material.dart';
import 'db_helper.dart';

class TeamsPlayers extends StatefulWidget {
  final VoidCallback? onBack;

  const TeamsPlayers({super.key, this.onBack});

  @override
  State<TeamsPlayers> createState() => _TeamsPlayersState();
}

class _TeamsPlayersState extends State<TeamsPlayers>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;
  List<Map<String, dynamic>> _categories = [];

  // category_id → list of teams
  Map<int, List<Map<String, dynamic>>> _teamsByCategory = {};

  bool _isLoading = true;
  DateTime? _lastUpdated;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  // ── Load ──────────────────────────────────────────────────────────────────
  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final categories = await DBHelper.getCategories();
      final Map<int, List<Map<String, dynamic>>> teamsByCategory = {};

      for (final cat in categories) {
        final catId = int.tryParse(cat['category_id'].toString()) ?? 0;
        final teams = await DBHelper.getTeamsByCategory(catId);
        teamsByCategory[catId] = teams;
      }

      _tabController?.dispose();
      _tabController = TabController(
        length: categories.length,
        vsync: this,
      );

      setState(() {
        _categories      = categories;
        _teamsByCategory = teamsByCategory;
        _isLoading       = false;
        _lastUpdated     = DateTime.now();
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Failed to load teams: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A0A4A),
      body: Column(
        children: [
          _buildHeader(),
          if (_isLoading)
            const Expanded(
              child: Center(
                child: CircularProgressIndicator(color: Color(0xFF00CFFF)),
              ),
            )
          else if (_categories.isEmpty)
            const Expanded(
              child: Center(
                child: Text('No categories found.',
                    style: TextStyle(color: Colors.white54, fontSize: 16)),
              ),
            )
          else ...[
            // ── Category tabs ──────────────────────────────────────────
            Container(
              color: const Color(0xFF2D0E7A),
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                indicatorColor: const Color(0xFF00CFFF),
                indicatorWeight: 3,
                labelColor: const Color(0xFF00CFFF),
                unselectedLabelColor: Colors.white54,
                labelStyle: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 1),
                tabs: _categories.map((c) {
                  final catId =
                      int.tryParse(c['category_id'].toString()) ?? 0;
                  final count = _teamsByCategory[catId]?.length ?? 0;
                  return Tab(
                    child: Row(
                      children: [
                        Text((c['category_type'] ?? '')
                            .toString()
                            .toUpperCase()),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00CFFF).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$count',
                            style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF00CFFF),
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),

            // ── Tab views ──────────────────────────────────────────────
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: _categories.map((cat) {
                  final catId =
                      int.tryParse(cat['category_id'].toString()) ?? 0;
                  final teams = _teamsByCategory[catId] ?? [];
                  return _buildCategoryTab(cat, teams);
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Category tab content ──────────────────────────────────────────────────
  Widget _buildCategoryTab(
    Map<String, dynamic> category,
    List<Map<String, dynamic>> teams,
  ) {
    final categoryName =
        (category['category_type'] ?? '').toString().toUpperCase();

    return Column(
      children: [
        // Title bar
        Container(
          width: double.infinity,
          color: const Color(0xFF2D0E7A),
          padding:
              const EdgeInsets.symmetric(vertical: 14, horizontal: 32),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'ROBOVENTURE',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              Text(
                categoryName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              Row(
                children: [
                  _buildLiveIndicator(),
                  if (widget.onBack != null)
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new,
                          color: Color(0xFF00CFFF)),
                      tooltip: 'Back',
                      onPressed: widget.onBack,
                    ),
                ],
              ),
            ],
          ),
        ),

        // Cards grid
        Expanded(
          child: teams.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.group_off,
                          color: Colors.white24, size: 64),
                      const SizedBox(height: 16),
                      const Text(
                        'No teams registered yet.',
                        style: TextStyle(
                            color: Colors.white38, fontSize: 16),
                      ),
                    ],
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 280,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                      childAspectRatio: 1.3,
                    ),
                    itemCount: teams.length,
                    itemBuilder: (context, index) {
                      return _TeamCard(
                        team: teams[index],
                        index: index,
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  // ── Live indicator ────────────────────────────────────────────────────────
  Widget _buildLiveIndicator() {
    final timeStr = _lastUpdated == null
        ? 'Loading...'
        : '${_lastUpdated!.hour.toString().padLeft(2, '0')}:'
          '${_lastUpdated!.minute.toString().padLeft(2, '0')}:'
          '${_lastUpdated!.second.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PulsingDot(),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('LIVE',
                  style: TextStyle(
                      color: Color(0xFF00FF88),
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
              Text(timeStr,
                  style: const TextStyle(color: Colors.white54, fontSize: 9)),
            ],
          ),
        ],
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF2D0E7A),
      padding:
          const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
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
                          fontSize: 22,
                          fontWeight: FontWeight.bold)),
                  TextSpan(
                      text: 'bl',
                      style: TextStyle(
                          color: Color(0xFF00CFFF),
                          fontSize: 22,
                          fontWeight: FontWeight.bold)),
                  TextSpan(
                      text: 'ock',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold)),
                ]),
              ),
              const Text('Construct Your Dreams',
                  style: TextStyle(
                      color: Colors.white54, fontSize: 10)),
            ],
          ),
          Image.asset('assets/images/CenterLogo.png',
              height: 80, fit: BoxFit.contain),
          const Text('CREOTEC',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 3)),
        ],
      ),
    );
  }
}

// ── Pulsing dot animation ─────────────────────────────────────────────────────
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
        CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: Color(0xFF00FF88),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

// ── Team Card ─────────────────────────────────────────────────────────────────
class _TeamCard extends StatefulWidget {
  final Map<String, dynamic> team;
  final int index;

  const _TeamCard({required this.team, required this.index});

  @override
  State<_TeamCard> createState() => _TeamCardState();
}

class _TeamCardState extends State<_TeamCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  bool _hovered = false;

  static const List<Color> _accentColors = [
    Color(0xFF00CFFF),
    Color(0xFF7B2FFF),
    Color(0xFFFF6B6B),
    Color(0xFF00E5A0),
    Color(0xFFFFD700),
    Color(0xFFFF8C42),
  ];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.03).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent =
        _accentColors[widget.index % _accentColors.length];
    final teamName =
        (widget.team['team_name'] ?? '').toString().toUpperCase();
    final isPresent =
        widget.team['team_ispresent'].toString() == '1';
    final mentorName =
        widget.team['mentor_name']?.toString() ?? '—';
    final teamId = widget.team['team_id']?.toString() ?? '';

    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        _controller.forward();
      },
      onExit: (_) {
        setState(() => _hovered = false);
        _controller.reverse();
      },
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, __) => Transform.scale(
          scale: _scaleAnim.value,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: accent.withOpacity(_hovered ? 0.7 : 0.25),
                width: 1.5,
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  accent.withOpacity(_hovered ? 0.12 : 0.06),
                  const Color(0xFF1A0A4A),
                ],
              ),
              boxShadow: _hovered
                  ? [
                      BoxShadow(
                        color: accent.withOpacity(0.25),
                        blurRadius: 20,
                        spreadRadius: 2,
                      )
                    ]
                  : [],
            ),
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top row: team ID badge + present indicator
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: accent.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'C${teamId.padLeft(3, '0')}R',
                        style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isPresent
                                ? Colors.green
                                : Colors.red.shade400,
                            boxShadow: [
                              BoxShadow(
                                color: isPresent
                                    ? Colors.green.withOpacity(0.5)
                                    : Colors.red.withOpacity(0.4),
                                blurRadius: 6,
                              )
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isPresent ? 'PRESENT' : 'ABSENT',
                          style: TextStyle(
                            color: isPresent
                                ? Colors.green
                                : Colors.red.shade400,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 14),

                Text(
                  teamName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                    letterSpacing: 0.5,
                    height: 1.2,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),

                const Spacer(),

                Container(
                  height: 1,
                  color: accent.withOpacity(0.15),
                  margin: const EdgeInsets.only(bottom: 10),
                ),

                Row(
                  children: [
                    Icon(Icons.person_outline,
                        color: accent.withOpacity(0.7), size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        mentorName,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          letterSpacing: 0.3,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}