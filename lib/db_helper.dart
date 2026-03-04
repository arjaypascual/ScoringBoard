import 'package:mysql_client/mysql_client.dart';

class DBHelper {
  static MySQLConnection? _connection;

  static const String _host         = "127.0.0.1";
  static const int    _port         = 3306;
  static const String _userName     = "root";
  static const String _password     = "root";
  static const String _databaseName = "roboventurecompetitiondb";

  // ── Connection ────────────────────────────────────────────────────────────

  static Future<MySQLConnection> getConnection() async {
    try {
      if (_connection != null && _connection!.connected) {
        return _connection!;
      }
    } catch (_) {
      _connection = null;
    }

    _connection = await MySQLConnection.createConnection(
      host:         _host,
      port:         _port,
      userName:     _userName,
      password:     _password,
      databaseName: _databaseName,
      secure:       false,
    );

    await _connection!.connect();
    print("✅ Database connected!");
    return _connection!;
  }

  static Future<void> closeConnection() async {
    try { await _connection?.close(); } catch (_) {}
    _connection = null;
    print("🔌 Database disconnected.");
  }

  // ── SCHOOLS ───────────────────────────────────────────────────────────────
  // Used in: Step 1

  static Future<List<Map<String, dynamic>>> getSchools() async {
    final conn = await getConnection();
    final result = await conn.execute(
      "SELECT * FROM tbl_school ORDER BY school_name"
    );
    return result.rows.map((r) => r.assoc()).toList();
  }

  // ── CATEGORIES ────────────────────────────────────────────────────────────
  // Used in: Step 3, Generate Schedule, Schedule Viewer, Standings

  static Future<List<Map<String, dynamic>>> getCategories() async {
    final conn = await getConnection();
    final result = await conn.execute(
      "SELECT * FROM tbl_category ORDER BY category_id"
    );
    return result.rows.map((r) => r.assoc()).toList();
  }

  static Future<void> seedCategories() async {
    final conn = await getConnection();
    const categories = [
      'Aspiring Makers',
      'Emerging Innovators',
      'Navigation',
      'Soccer',
    ];
    for (final cat in categories) {
      await conn.execute(
        "INSERT IGNORE INTO tbl_category (category_type) VALUES (:cat)",
        {"cat": cat},
      );
    }
    print("✅ Categories seeded.");
  }

  // ── TEAMS ─────────────────────────────────────────────────────────────────
  // Used in: Step 3, Step 4, Generate Schedule, Standings

  static Future<List<Map<String, dynamic>>> getTeams() async {
    final conn = await getConnection();
    final result = await conn.execute("""
      SELECT t.team_id, t.team_name, t.team_ispresent,
             c.category_type, m.mentor_name
      FROM tbl_team t
      JOIN tbl_category c ON t.category_id = c.category_id
      JOIN tbl_mentor   m ON t.mentor_id   = m.mentor_id
      ORDER BY t.team_id
    """);
    return result.rows.map((r) => r.assoc()).toList();
  }

  static Future<List<Map<String, dynamic>>> getTeamsByCategory(
      int categoryId) async {
    final conn = await getConnection();
    final result = await conn.execute("""
      SELECT t.team_id, t.team_name, t.team_ispresent,
             c.category_type, m.mentor_name
      FROM tbl_team t
      JOIN tbl_category c ON t.category_id = c.category_id
      JOIN tbl_mentor   m ON t.mentor_id   = m.mentor_id
      WHERE t.category_id = :categoryId
      ORDER BY t.team_id
    """, {"categoryId": categoryId});
    return result.rows.map((r) => r.assoc()).toList();
  }

  // ── SCHEDULE ──────────────────────────────────────────────────────────────
  // Used in: Generate Schedule, Schedule Viewer

  static Future<int> insertSchedule({
    required String startTime,
    required String endTime,
  }) async {
    final conn = await getConnection();
    final result = await conn.execute("""
      INSERT INTO tbl_schedule (schedule_start, schedule_end)
      VALUES (:start, :end)
    """, {"start": startTime, "end": endTime});
    return result.lastInsertID.toInt();
  }

  static Future<int> insertMatch(int scheduleId) async {
    final conn = await getConnection();
    final result = await conn.execute("""
      INSERT INTO tbl_match (schedule_id) VALUES (:scheduleId)
    """, {"scheduleId": scheduleId});
    return result.lastInsertID.toInt();
  }

  static Future<void> insertTeamSchedule({
    required int matchId,
    required int roundId,
    required int teamId,
    required int refereeId,
  }) async {
    final conn = await getConnection();
    await conn.execute("""
      INSERT INTO tbl_teamschedule (match_id, round_id, team_id, referee_id)
      VALUES (:match, :round, :team, :ref)
    """, {
      "match": matchId,
      "round": roundId,
      "team":  teamId,
      "ref":   refereeId,
    });
  }

  static Future<void> generateSchedule({
    required Map<int, int> runsPerCategory,
    required String startTime,
    required int durationMinutes,
    required int intervalMinutes,
  }) async {
    final conn = await getConnection();

    // ── Get first available referee from DB (fixes FK constraint error) ──
    final refResult = await conn.execute(
      "SELECT referee_id FROM tbl_referee ORDER BY referee_id LIMIT 1"
    );
    if (refResult.rows.isEmpty) {
      throw Exception(
        'No referees found in tbl_referee. '
        'Please add at least one referee before generating a schedule.',
      );
    }
    final defaultRefereeId = int.parse(
      refResult.rows.first.assoc()['referee_id'] ?? '0',
    );

    final parts = startTime.split(':');
    int hour   = int.parse(parts[0]);
    int minute = int.parse(parts[1]);

    for (final entry in runsPerCategory.entries) {
      final categoryId = entry.key;
      final runs       = entry.value;

      final teams = await getTeamsByCategory(categoryId);
      if (teams.isEmpty) continue;

      for (final team in teams) {
        final teamId = int.parse(team['team_id'].toString());

        for (int run = 0; run < runs; run++) {
          final startStr =
              '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:00';

          minute += durationMinutes;
          while (minute >= 60) { minute -= 60; hour++; }

          final endStr =
              '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:00';

          final scheduleId = await insertSchedule(
              startTime: startStr, endTime: endStr);
          final matchId = await insertMatch(scheduleId);
          await insertTeamSchedule(
            matchId:   matchId,
            roundId:   run + 1,
            teamId:    teamId,
            refereeId: defaultRefereeId, // ✅ real referee from DB
          );

          minute += intervalMinutes;
          while (minute >= 60) { minute -= 60; hour++; }
        }
      }
    }
    print("✅ Schedule generated successfully!");
  }

  // ── SCORES ────────────────────────────────────────────────────────────────
  // Used in: Standings

  static Future<List<Map<String, dynamic>>> getScoresByCategory(
      int categoryId) async {
    final conn = await getConnection();
    final result = await conn.execute("""
      SELECT
        t.team_id,
        t.team_name,
        s.round_id,
        COALESCE(s.score_totalscore,    0)       AS score_totalscore,
        COALESCE(s.score_totalduration, '00:00') AS score_totalduration
      FROM tbl_team t
      LEFT JOIN tbl_score s ON s.team_id = t.team_id
      WHERE t.category_id = :categoryId
      ORDER BY t.team_id, s.round_id
    """, {"categoryId": categoryId});
    return result.rows.map((r) => r.assoc()).toList();
  }

  static Future<void> upsertScore({
    required int teamId,
    required int roundId,
    required int matchId,
    required int refereeId,
    required int independentScore,
    required int violation,
    required int totalScore,
    required String totalDuration,
  }) async {
    final conn = await getConnection();
    await conn.execute("""
      INSERT INTO tbl_score
        (score_independentscore, score_violation, score_totalscore,
         score_totalduration, score_isapproved,
         match_id, round_id, team_id, referee_id)
      VALUES
        (:indep, :viol, :total, :duration, 0,
         :match, :round, :team, :ref)
      ON DUPLICATE KEY UPDATE
        score_independentscore = :indep,
        score_violation        = :viol,
        score_totalscore       = :total,
        score_totalduration    = :duration
    """, {
      "indep":    independentScore,
      "viol":     violation,
      "total":    totalScore,
      "duration": totalDuration,
      "match":    matchId,
      "round":    roundId,
      "team":     teamId,
      "ref":      refereeId,
    });
  }
}