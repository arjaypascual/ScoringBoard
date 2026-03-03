import 'package:mysql_client/mysql_client.dart';

class DBHelper {
  static MySQLConnection? _connection;

  static const String _host = "127.0.0.1";
  static const int _port = 3306;
  static const String _userName = "root";
  static const String _password = "root";
  static const String _databaseName = "roboventurecompetitiondb";

  // Get or create connection
  static Future<MySQLConnection> getConnection() async {
    try {
      if (_connection != null && _connection!.connected) {
        return _connection!;
      }
    } catch (_) {
      _connection = null;
    }

    _connection = await MySQLConnection.createConnection(
      host: _host,
      port: _port,
      userName: _userName,
      password: _password,
      databaseName: _databaseName,
      secure: false,
    );

    await _connection!.connect();
    print("✅ Database connected!");
    return _connection!;
  }

  // Close connection
  static Future<void> closeConnection() async {
    try {
      await _connection?.close();
    } catch (_) {}
    _connection = null;
    print("🔌 Database disconnected.");
  }

  // ─── TEAMS ───────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getTeams() async {
    final conn = await getConnection();
    final result = await conn.execute("""
      SELECT t.team_id, t.team_name, t.team_ispresent,
             c.category_type, m.mentor_name
      FROM tbl_team t
      JOIN tbl_category c ON t.category_id = c.category_id
      JOIN tbl_mentor m ON t.mentor_id = m.mentor_id
      ORDER BY t.team_id
    """);
    return result.rows.map((row) => row.assoc()).toList();
  }

  // Get teams filtered by category
  static Future<List<Map<String, dynamic>>> getTeamsByCategory(int categoryId) async {
    final conn = await getConnection();
    final result = await conn.execute("""
      SELECT t.team_id, t.team_name, t.team_ispresent,
             c.category_type, m.mentor_name
      FROM tbl_team t
      JOIN tbl_category c ON t.category_id = c.category_id
      JOIN tbl_mentor m ON t.mentor_id = m.mentor_id
      WHERE t.category_id = :categoryId
      ORDER BY t.team_id
    """, {"categoryId": categoryId});
    return result.rows.map((row) => row.assoc()).toList();
  }

  // ─── SCORES ──────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getScoresByTeam(int teamId) async {
    final conn = await getConnection();
    final result = await conn.execute(
      "SELECT * FROM tbl_score WHERE team_id = :teamId",
      {"teamId": teamId},
    );
    return result.rows.map((row) => row.assoc()).toList();
  }

  static Future<void> insertScore({
    required int independentScore,
    required int violation,
    required int totalScore,
    required String totalDuration,
    required int matchId,
    required int roundId,
    required int teamId,
    required int refereeId,
  }) async {
    final conn = await getConnection();
    await conn.execute("""
      INSERT INTO tbl_score 
      (score_independentscore, score_violation, score_totalscore,
       score_totalduration, score_isapproved, match_id, round_id, team_id, referee_id)
      VALUES (:indep, :viol, :total, :duration, 0, :match, :round, :team, :ref)
    """, {
      "indep": independentScore,
      "viol": violation,
      "total": totalScore,
      "duration": totalDuration,
      "match": matchId,
      "round": roundId,
      "team": teamId,
      "ref": refereeId,
    });
  }

  // ─── SCHEDULE ────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getSchedules() async {
    final conn = await getConnection();
    final result = await conn.execute("""
      SELECT ts.teamschedule_id, t.team_name, s.schedule_start, 
             s.schedule_end, r.round_type, ref.referee_name
      FROM tbl_teamschedule ts
      JOIN tbl_team t ON ts.team_id = t.team_id
      JOIN tbl_match m ON ts.match_id = m.match_id
      JOIN tbl_schedule s ON m.schedule_id = s.schedule_id
      JOIN tbl_round r ON ts.round_id = r.round_id
      JOIN tbl_referee ref ON ts.referee_id = ref.referee_id
      ORDER BY s.schedule_start
    """);
    return result.rows.map((row) => row.assoc()).toList();
  }

  /// Insert a new schedule slot and return its generated ID
  static Future<int> insertSchedule({
    required String startTime,
    required String endTime,
  }) async {
    final conn = await getConnection();
    final result = await conn.execute("""
      INSERT INTO tbl_schedule (schedule_start, schedule_end)
      VALUES (:start, :end)
    """, {
      "start": startTime,
      "end": endTime,
    });
    return result.lastInsertID.toInt();
  }

  /// Insert a match linked to a schedule slot and return its generated ID
  static Future<int> insertMatch(int scheduleId) async {
    final conn = await getConnection();
    final result = await conn.execute("""
      INSERT INTO tbl_match (schedule_id)
      VALUES (:scheduleId)
    """, {"scheduleId": scheduleId});
    return result.lastInsertID.toInt();
  }

  /// Insert a team schedule entry
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
      "team": teamId,
      "ref": refereeId,
    });
  }

  /// Generate and persist a full competition schedule.
  ///
  /// [runsPerCategory] maps category_id → number of runs.
  /// [startTime] is "HH:MM", [durationMinutes] is minutes per run,
  /// [intervalMinutes] is break between runs.
  static Future<void> generateSchedule({
    required Map<int, int> runsPerCategory,
    required String startTime,
    required int durationMinutes,
    required int intervalMinutes,
  }) async {
    // Parse start time
    final parts = startTime.split(':');
    int hour = int.parse(parts[0]);
    int minute = int.parse(parts[1]);

    for (final entry in runsPerCategory.entries) {
      final categoryId = entry.key;
      final runs = entry.value;

      // Fetch teams in this category
      final teams = await getTeamsByCategory(categoryId);
      if (teams.isEmpty) continue;

      for (final team in teams) {
        final teamId = int.parse(team['team_id'].toString());

        for (int run = 0; run < runs; run++) {
          // Calculate slot times
          final startHH = hour.toString().padLeft(2, '0');
          final startMM = minute.toString().padLeft(2, '0');
          final startStr = "$startHH:$startMM:00";

          minute += durationMinutes;
          while (minute >= 60) {
            minute -= 60;
            hour++;
          }
          final endHH = hour.toString().padLeft(2, '0');
          final endMM = minute.toString().padLeft(2, '0');
          final endStr = "$endHH:$endMM:00";

          // Insert schedule → match → team schedule
          final scheduleId = await insertSchedule(
            startTime: startStr,
            endTime: endStr,
          );
          final matchId = await insertMatch(scheduleId);
          await insertTeamSchedule(
            matchId: matchId,
            roundId: run + 1, // round 1, 2, etc.
            teamId: teamId,
            refereeId: 1,     // default referee; update as needed
          );

          // Add interval gap
          minute += intervalMinutes;
          while (minute >= 60) {
            minute -= 60;
            hour++;
          }
        }
      }
    }

    print("✅ Schedule generated successfully!");
  }

  // ─── RANKINGS ────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getRankings(int roundId) async {
    final conn = await getConnection();
    final result = await conn.execute("""
      SELECT t.team_name, c.category_type,
             SUM(s.score_totalscore) AS total_score
      FROM tbl_score s
      JOIN tbl_team t ON s.team_id = t.team_id
      JOIN tbl_category c ON t.category_id = c.category_id
      WHERE s.round_id = :roundId AND s.score_isapproved = 1
      GROUP BY s.team_id
      ORDER BY total_score DESC
    """, {"roundId": roundId});
    return result.rows.map((row) => row.assoc()).toList();
  }

  // ─── CATEGORIES ──────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getCategories() async {
    final conn = await getConnection();
    final result = await conn.execute("SELECT * FROM tbl_category ORDER BY category_id");
    return result.rows.map((row) => row.assoc()).toList();
  }

  /// Ensure the 4 required categories exist in the DB.
  /// Safe to call on startup — uses INSERT IGNORE to avoid duplicates.
  static Future<void> seedCategories() async {
    final conn = await getConnection();
    const categories = [
      'Aspiring Makers',
      'Emerging Innovators',
      'Navigation',
      'Soccer',
    ];
    for (final cat in categories) {
      await conn.execute("""
        INSERT IGNORE INTO tbl_category (category_type)
        VALUES (:cat)
      """, {"cat": cat});
    }
    print("✅ Categories seeded.");
  }

  /// Get category_id by name (useful for mapping UI labels to DB IDs)
  static Future<int?> getCategoryIdByName(String name) async {
    final conn = await getConnection();
    final result = await conn.execute("""
      SELECT category_id FROM tbl_category WHERE category_type = :name LIMIT 1
    """, {"name": name});
    if (result.rows.isEmpty) return null;
    return int.tryParse(result.rows.first.assoc()['category_id'].toString());
  }

  // ─── SCHOOLS ─────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getSchools() async {
    final conn = await getConnection();
    final result = await conn.execute(
      "SELECT * FROM tbl_school ORDER BY school_name"
    );
    return result.rows.map((row) => row.assoc()).toList();
  }
}