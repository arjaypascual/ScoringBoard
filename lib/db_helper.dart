import 'package:mysql_client/mysql_client.dart';

class DBHelper {
  static MySQLConnection? _connection;

  static const String _host         = "127.0.0.1";
  static const int    _port         = 3306;
  static const String _userName     = "root";
  static const String _password     = "root";
  static const String _databaseName = "roboventurecompetitiondb";

  // ── MIGRATIONS ───────────────────────────────────────────────────────────
  // Safe to call on every app start — adds arena_number if missing.
  static Future<void> runMigrations() async {
    final conn = await getConnection();
    try {
      await conn.execute("""
        ALTER TABLE tbl_teamschedule
        ADD COLUMN arena_number INT NOT NULL DEFAULT 1
      """);
      print("✅ Migration: arena_number column added.");
    } catch (_) {
      // Column already exists — safe to ignore
      print("ℹ️  Migration: arena_number already present.");
    }
  }

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

  // Wipes all existing schedule data in correct FK order before regenerating
  static Future<void> clearSchedule() async {
    final conn = await getConnection();
    await conn.execute("DELETE FROM tbl_teamschedule");
    await conn.execute("DELETE FROM tbl_match");
    await conn.execute("DELETE FROM tbl_schedule");
    print("✅ Schedule cleared.");
  }

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
    int arenaNumber = 1,
  }) async {
    final conn = await getConnection();
    await conn.execute("""
      INSERT INTO tbl_teamschedule (match_id, round_id, team_id, referee_id, arena_number)
      VALUES (:match, :round, :team, :ref, :arena)
    """, {
      "match": matchId,
      "round": roundId,
      "team":  teamId,
      "ref":   refereeId,
      "arena": arenaNumber,
    });
  }

  // ── ROUNDS ────────────────────────────────────────────────────────────────
  // Ensures tbl_round has enough rows for the max runs requested.
  // Safe to call repeatedly — uses INSERT IGNORE.
  static Future<void> seedRounds(int maxRounds) async {
    final conn = await getConnection();
    for (int i = 1; i <= maxRounds; i++) {
      await conn.execute("""
        INSERT IGNORE INTO tbl_round (round_id, round_type)
        VALUES (:id, :type)
      """, {
        "id":   i,
        "type": 'Round $i',
      });
    }
    print("✅ Rounds seeded up to $maxRounds.");
  }

  static Future<void> generateSchedule({
    required Map<int, int> runsPerCategory,
    required Map<int, int> arenasPerCategory,
    required String startTime,
    required String endTime,
    required int durationMinutes,
    required int intervalMinutes,
    bool lunchBreak = true,
  }) async {
    final conn = await getConnection();

    // ── Clear old schedule first ─────────────────────────────────────────────
    await clearSchedule();

    // ── Seed rounds ──────────────────────────────────────────────────────────
    final maxRuns = runsPerCategory.values.isEmpty
        ? 1
        : runsPerCategory.values.reduce((a, b) => a > b ? a : b);
    await seedRounds(maxRuns);

    // ── Get first available referee ──────────────────────────────────────────
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

    // ── Parse start / end times ───────────────────────────────────────────────
    final startParts = startTime.split(':');
    int hour   = int.parse(startParts[0]);
    int minute = int.parse(startParts[1]);

    final endParts  = endTime.split(':');
    final endLimitH = int.parse(endParts[0]);
    final endLimitM = int.parse(endParts[1]);
    int endLimitMinutes = endLimitH * 60 + endLimitM;

    // ── Helper: current time in minutes ──────────────────────────────────────
    int currentMinutes() => hour * 60 + minute;

    // ── Helper: skip lunch break 12:00–13:00 ─────────────────────────────────
    void skipLunch() {
      if (lunchBreak && hour == 12) {
        hour   = 13;
        minute = 0;
      }
    }

    void advanceTime(int minutes) {
      minute += minutes;
      while (minute >= 60) { minute -= 60; hour++; }
      skipLunch();
    }

    // Skip lunch if start time is in break
    skipLunch();

    // ── Schedule by category ─────────────────────────────────────────────────
    for (final entry in runsPerCategory.entries) {
      final categoryId = entry.key;
      final runs       = entry.value;
      final arenas     = arenasPerCategory[categoryId] ?? 1;

      final teams = await getTeamsByCategory(categoryId);
      if (teams.isEmpty) continue;

      for (int run = 0; run < runs; run++) {
        int teamIndex = 0;
        while (teamIndex < teams.length) {
          // ── Stop if current slot would exceed end time ──────────────────
          if (currentMinutes() + durationMinutes > endLimitMinutes) {
            print("⚠️  End time reached — remaining slots not scheduled.");
            return;
          }

          final batchEnd = (teamIndex + arenas) < teams.length
              ? teamIndex + arenas
              : teams.length;
          final batch = teams.sublist(teamIndex, batchEnd);

          final startHH  = hour.toString().padLeft(2, '0');
          final startMM  = minute.toString().padLeft(2, '0');
          final startStr = '$startHH:$startMM:00';

          int endHour   = hour;
          int endMinute = minute + durationMinutes;
          while (endMinute >= 60) { endMinute -= 60; endHour++; }
          final endStr =
              '${endHour.toString().padLeft(2, '0')}:${endMinute.toString().padLeft(2, '0')}:00';

          final scheduleId = await insertSchedule(
              startTime: startStr, endTime: endStr);
          final matchId = await insertMatch(scheduleId);

          for (int ai = 0; ai < batch.length; ai++) {
            final team   = batch[ai];
            final teamId = int.parse(team['team_id'].toString());
            await insertTeamSchedule(
              matchId:     matchId,
              roundId:     run + 1,
              teamId:      teamId,
              refereeId:   defaultRefereeId,
              arenaNumber: ai + 1,
            );
          }

          advanceTime(durationMinutes + intervalMinutes);
          teamIndex += arenas;
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