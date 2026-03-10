import 'package:mysql_client/mysql_client.dart';

class DBHelper {
  static MySQLConnection? _connection;

  static const String _host         = "127.0.0.1";
  static const int    _port         = 3306;
  static const String _userName     = "root";
  static const String _password     = "root";
  static const String _databaseName = "roboventuredb";

  // ── MIGRATIONS ───────────────────────────────────────────────────────────
  static Future<void> runMigrations() async {
    final conn = await getConnection();
    try {
      await conn.execute("""
        ALTER TABLE tbl_teamschedule
        ADD COLUMN arena_number INT NOT NULL DEFAULT 1
      """);
      print("✅ Migration: arena_number column added.");
    } catch (_) {
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

  static Future<List<Map<String, dynamic>>> getSchools() async {
    final conn = await getConnection();
    final result = await conn.execute(
      "SELECT * FROM tbl_school ORDER BY school_name"
    );
    return result.rows.map((r) => r.assoc()).toList();
  }

  // ── CATEGORIES ────────────────────────────────────────────────────────────

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
      'Aspiring Makers (mBot 1)',
      'Emerging Innovators (mBot 2)',
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

  static Future<void> clearSchedule() async {
    final conn = await getConnection();
    await conn.execute("DELETE FROM tbl_teamschedule");
    await conn.execute("DELETE FROM tbl_match");
    await conn.execute("DELETE FROM tbl_schedule");
    // ✅ Reset AUTO_INCREMENT so match IDs start from 1 again
    await conn.execute("ALTER TABLE tbl_teamschedule AUTO_INCREMENT = 1");
    await conn.execute("ALTER TABLE tbl_match AUTO_INCREMENT = 1");
    await conn.execute("ALTER TABLE tbl_schedule AUTO_INCREMENT = 1");
    print("✅ Schedule cleared and IDs reset.");
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
    final startParts  = startTime.split(':');
    final startHourBase   = int.parse(startParts[0]);
    final startMinuteBase = int.parse(startParts[1]);

    final endParts      = endTime.split(':');
    final endLimitH     = int.parse(endParts[0]);
    final endLimitM     = int.parse(endParts[1]);
    final endLimitMinutes = endLimitH * 60 + endLimitM;

    // ── Schedule each category — ALL reset to startTime ──────────────────────
    for (final entry in runsPerCategory.entries) {
      final categoryId = entry.key;
      final runs       = entry.value;
      final teams = await getTeamsByCategory(categoryId);
      if (teams.isEmpty) continue;

      // ✅ Reset time to startTime for EVERY category
      int hour   = startHourBase;
      int minute = startMinuteBase;

      // ── Helper: current time in minutes ────────────────────────────────────
      int currentMinutes() => hour * 60 + minute;

      // ── Helper: skip lunch break 12:00–13:00 ───────────────────────────────
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

      // Skip lunch if category starts in lunch window
      skipLunch();

      for (int run = 0; run < runs; run++) {
        // ✅ Pair teams: [0 vs 1], [2 vs 3], [4 vs 5]...
        // If odd number of teams, last team gets a BYE (paired alone)
        int teamIndex = 0;
        while (teamIndex < teams.length) {
          if (currentMinutes() + durationMinutes > endLimitMinutes) {
            print("⚠️  End time reached for category $categoryId — remaining slots not scheduled.");
            break;
          }

          // Grab up to 2 teams per match slot (1 per arena side)
          final team1 = teams[teamIndex];
          final team2 = (teamIndex + 1) < teams.length ? teams[teamIndex + 1] : null;

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

          // Insert team1 as arena 1
          await insertTeamSchedule(
            matchId:     matchId,
            roundId:     run + 1,
            teamId:      int.parse(team1['team_id'].toString()),
            refereeId:   defaultRefereeId,
            arenaNumber: 1,
          );

          // Insert team2 as arena 2 only if it exists (no blank slot)
          if (team2 != null) {
            await insertTeamSchedule(
              matchId:     matchId,
              roundId:     run + 1,
              teamId:      int.parse(team2['team_id'].toString()),
              refereeId:   defaultRefereeId,
              arenaNumber: 2,
            );
          }

          advanceTime(durationMinutes + intervalMinutes);
          teamIndex += 2; // always advance by 2 (pair per match)
        }
      }

      print("✅ Category $categoryId scheduled.");
    }

    print("✅ Schedule generated successfully!");
  }

  // ── SCORES ────────────────────────────────────────────────────────────────

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