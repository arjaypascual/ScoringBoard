// ignore_for_file: avoid_print

import 'package:mysql_client/mysql_client.dart';

class DBHelper {
  static MySQLConnection? _connection;

  static const String _host         = "localhost";
  static const int    _port         = 3306;
  static const String _userName     = "root";
  static const String _password     = "root";
  static const String _databaseName = "roboventuredb";

  // ── MIGRATIONS ───────────────────────────────────────────────────────────
  static Future<void> runMigrations() async {
    final conn = await getConnection();

    // Migration 1: arena_number column on tbl_teamschedule
    try {
      await conn.execute("""
        ALTER TABLE tbl_teamschedule
        ADD COLUMN arena_number INT NOT NULL DEFAULT 1
      """);
      print("✅ Migration: arena_number column added.");
    } catch (_) {
      print("ℹ️  Migration: arena_number already present.");
    }

    // Migration 2: contact column on tbl_referee
    try {
      await conn.execute("""
        ALTER TABLE tbl_referee
        ADD COLUMN contact VARCHAR(100) NOT NULL DEFAULT ''
        AFTER referee_name
      """);
      print("✅ Migration: contact column added to tbl_referee.");
    } catch (_) {
      print("ℹ️  Migration: contact already present.");
    }

    // Migration 3: status column on tbl_category
    try {
      await conn.execute("""
        ALTER TABLE tbl_category
        ADD COLUMN status ENUM('active','inactive') NOT NULL DEFAULT 'active'
      """);
      print("✅ Migration: status column added to tbl_category.");
    } catch (_) {
      print("ℹ️  Migration: status already present.");
    }

    // Migration 4: tbl_referee_category junction table
    try {
      await conn.execute("""
        CREATE TABLE IF NOT EXISTS tbl_referee_category (
          referee_id  INT NOT NULL,
          category_id INT NOT NULL,
          PRIMARY KEY (referee_id, category_id),
          FOREIGN KEY (referee_id)
            REFERENCES tbl_referee(referee_id) ON DELETE CASCADE,
          FOREIGN KEY (category_id)
            REFERENCES tbl_category(category_id) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
      """);
      print("✅ Migration: tbl_referee_category created.");
    } catch (_) {
      print("ℹ️  Migration: tbl_referee_category already present.");
    }
  }

  // ── CONNECTION ────────────────────────────────────────────────────────────
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
    final conn   = await getConnection();
    final result = await conn.execute(
      "SELECT * FROM tbl_school ORDER BY school_name",
    );
    return result.rows.map((r) => r.assoc()).toList();
  }

  // ── CATEGORIES ────────────────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getCategories() async {
    final conn   = await getConnection();
    final result = await conn.execute(
      "SELECT * FROM tbl_category ORDER BY category_id",
    );
    return result.rows.map((r) => r.assoc()).toList();
  }

  static Future<List<Map<String, dynamic>>> getActiveCategories() async {
    final conn   = await getConnection();
    final result = await conn.execute(
      "SELECT * FROM tbl_category WHERE status = 'active' ORDER BY category_id",
    );
    return result.rows.map((r) => r.assoc()).toList();
  }

  static Future<void> insertCategory(String categoryType) async {
    final conn = await getConnection();
    await conn.execute(
      "INSERT INTO tbl_category (category_type, status) VALUES (:type, 'active')",
      {'type': categoryType},
    );
    print("✅ Category '$categoryType' inserted.");
  }

  static Future<void> updateCategory(int id, String categoryType) async {
    final conn = await getConnection();
    await conn.execute(
      "UPDATE tbl_category SET category_type = :type WHERE category_id = :id",
      {'type': categoryType, 'id': id},
    );
    print("✅ Category $id updated.");
  }

  static Future<void> toggleCategoryStatus(int id, bool setActive) async {
    final conn = await getConnection();
    await conn.execute(
      "UPDATE tbl_category SET status = :status WHERE category_id = :id",
      {'status': setActive ? 'active' : 'inactive', 'id': id},
    );
    print("✅ Category $id status → ${setActive ? 'active' : 'inactive'}.");
  }

  static Future<void> deleteCategory(int id) async {
    final conn = await getConnection();
    await conn.execute(
      "DELETE FROM tbl_category WHERE category_id = :id",
      {'id': id},
    );
    print("✅ Category $id deleted.");
  }

  static Future<void> seedCategories() async {
    const categories = [
      'Aspiring Makers (mBot 1)',
      'Emerging Innovators (mBot 2)',
      'Navigation',
      'Soccer',
    ];
    for (final cat in categories) {
      final conn = await getConnection();
      await conn.execute(
        "INSERT IGNORE INTO tbl_category (category_type) VALUES (:cat)",
        {"cat": cat},
      );
    }
    print("✅ Categories seeded.");
  }

  // ── REFEREES ──────────────────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getReferees() async {
    final conn   = await getConnection();
    final result = await conn.execute(
      "SELECT * FROM tbl_referee ORDER BY referee_id",
    );
    return result.rows.map((r) => r.assoc()).toList();
  }

  static Future<int> insertReferee(String name, String contact) async {
    final conn   = await getConnection();
    final result = await conn.execute(
      "INSERT INTO tbl_referee (referee_name, contact) VALUES (:name, :contact)",
      {"name": name, "contact": contact},
    );
    print("✅ Referee '$name' inserted.");
    return result.lastInsertID.toInt();
  }

  static Future<void> updateReferee(int id, String name, String contact) async {
    final conn = await getConnection();
    await conn.execute(
      "UPDATE tbl_referee SET referee_name = :name, contact = :contact WHERE referee_id = :id",
      {"name": name, "contact": contact, "id": id},
    );
    print("✅ Referee $id updated.");
  }

  static Future<void> deleteReferee(int id) async {
    final conn = await getConnection();
    await conn.execute(
      "DELETE FROM tbl_referee WHERE referee_id = :id",
      {"id": id},
    );
    print("✅ Referee $id deleted.");
  }

  // ── REFEREE ↔ CATEGORY ────────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getRefereeCategories(
      int refereeId) async {
    final conn   = await getConnection();
    final result = await conn.execute(
      """
      SELECT c.category_id, c.category_type
      FROM tbl_referee_category rc
      JOIN tbl_category c ON rc.category_id = c.category_id
      WHERE rc.referee_id = :rid
      ORDER BY c.category_type
      """,
      {"rid": refereeId},
    );
    return result.rows.map((r) => r.assoc()).toList();
  }

  static Future<void> setRefereeCategories(
      int refereeId, List<int> categoryIds) async {
    final conn = await getConnection();
    await conn.execute(
      "DELETE FROM tbl_referee_category WHERE referee_id = :rid",
      {"rid": refereeId},
    );
    for (final cid in categoryIds) {
      await conn.execute(
        """
        INSERT INTO tbl_referee_category (referee_id, category_id)
        VALUES (:rid, :cid)
        """,
        {"rid": refereeId, "cid": cid},
      );
    }
    print("✅ Referee $refereeId categories updated.");
  }

  // ── TEAMS ─────────────────────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getTeams() async {
    final conn   = await getConnection();
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
    final conn   = await getConnection();
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

  /// Clears all schedule-related data in the correct FK-safe order:
  /// tbl_score → tbl_teamschedule → tbl_match → tbl_schedule
  static Future<void> clearSchedule() async {
    final conn = await getConnection();

    // 1. Delete scores first (references tbl_match)
    await conn.execute("DELETE FROM tbl_score");
    await conn.execute("ALTER TABLE tbl_score AUTO_INCREMENT = 1");

    // 2. Delete team schedules (references tbl_match and tbl_round)
    await conn.execute("DELETE FROM tbl_teamschedule");
    await conn.execute("ALTER TABLE tbl_teamschedule AUTO_INCREMENT = 1");

    // 3. Delete matches (references tbl_schedule)
    await conn.execute("DELETE FROM tbl_match");
    await conn.execute("ALTER TABLE tbl_match AUTO_INCREMENT = 1");

    // 4. Delete schedules last
    await conn.execute("DELETE FROM tbl_schedule");
    await conn.execute("ALTER TABLE tbl_schedule AUTO_INCREMENT = 1");

    print("✅ Schedule cleared and IDs reset.");
  }

  static Future<int> insertSchedule({
    required String startTime,
    required String endTime,
  }) async {
    final conn   = await getConnection();
    final result = await conn.execute("""
      INSERT INTO tbl_schedule (schedule_start, schedule_end)
      VALUES (:start, :end)
    """, {"start": startTime, "end": endTime});
    return result.lastInsertID.toInt();
  }

  static Future<int> insertMatch(int scheduleId) async {
    final conn   = await getConnection();
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

  // ── GENERATE SCHEDULE ─────────────────────────────────────────────────────
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

    await clearSchedule();

    final maxRuns = runsPerCategory.values.isEmpty
        ? 1
        : runsPerCategory.values.reduce((a, b) => a > b ? a : b);
    await seedRounds(maxRuns);

    final refResult = await conn.execute(
      "SELECT referee_id FROM tbl_referee ORDER BY referee_id LIMIT 1",
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

    final startParts      = startTime.split(':');
    final startHourBase   = int.parse(startParts[0]);
    final startMinuteBase = int.parse(startParts[1]);

    final endParts        = endTime.split(':');
    final endLimitH       = int.parse(endParts[0]);
    final endLimitM       = int.parse(endParts[1]);
    final endLimitMinutes = endLimitH * 60 + endLimitM;

    for (final entry in runsPerCategory.entries) {
      final categoryId = entry.key;
      final runs       = entry.value;
      final teams      = await getTeamsByCategory(categoryId);
      if (teams.isEmpty) continue;

      int hour   = startHourBase;
      int minute = startMinuteBase;

      int currentMinutes() => hour * 60 + minute;

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

      skipLunch();

      for (int run = 0; run < runs; run++) {
        int teamIndex = 0;
        while (teamIndex < teams.length) {
          if (currentMinutes() + durationMinutes > endLimitMinutes) {
            print("⚠️  End time reached for category $categoryId.");
            break;
          }

          final team1 = teams[teamIndex];
          final team2 = (teamIndex + 1) < teams.length
              ? teams[teamIndex + 1]
              : null;

          final startHH  = hour.toString().padLeft(2, '0');
          final startMM  = minute.toString().padLeft(2, '0');
          final startStr = '$startHH:$startMM:00';

          int endHour   = hour;
          int endMinute = minute + durationMinutes;
          while (endMinute >= 60) { endMinute -= 60; endHour++; }
          final endStr =
              '${endHour.toString().padLeft(2, '0')}:'
              '${endMinute.toString().padLeft(2, '0')}:00';

          final scheduleId = await insertSchedule(
              startTime: startStr, endTime: endStr);
          final matchId = await insertMatch(scheduleId);

          await insertTeamSchedule(
            matchId:     matchId,
            roundId:     run + 1,
            teamId:      int.parse(team1['team_id'].toString()),
            refereeId:   defaultRefereeId,
            arenaNumber: 1,
          );

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
          teamIndex += 2;
        }
      }

      print("✅ Category $categoryId scheduled.");
    }

    print("✅ Schedule generated successfully!");
  }

  // ── SCORES ────────────────────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getScoresByCategory(
      int categoryId) async {
    final conn   = await getConnection();
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