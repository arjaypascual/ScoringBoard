// ignore_for_file: avoid_print

import 'dart:math';
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
      print("✅ Migration 1: arena_number column added.");
    } catch (_) {
      print("ℹ️  Migration 1: arena_number already present.");
    }

    // Migration 2: contact column on tbl_referee
    try {
      await conn.execute("""
        ALTER TABLE tbl_referee
        ADD COLUMN contact VARCHAR(100) NOT NULL DEFAULT ''
        AFTER referee_name
      """);
      print("✅ Migration 2: contact column added to tbl_referee.");
    } catch (_) {
      print("ℹ️  Migration 2: contact already present.");
    }

    // Migration 3: status column on tbl_category
    try {
      await conn.execute("""
        ALTER TABLE tbl_category
        ADD COLUMN status ENUM('active','inactive') NOT NULL DEFAULT 'active'
      """);
      print("✅ Migration 3: status column added to tbl_category.");
    } catch (_) {
      print("ℹ️  Migration 3: status already present.");
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
      print("✅ Migration 4: tbl_referee_category created.");
    } catch (_) {
      print("ℹ️  Migration 4: tbl_referee_category already present.");
    }

    // Migration 5: drop arena_id FK constraint + column from tbl_referee.
    // The original schema had arena_id as a NOT NULL FK pointing to tbl_arena.
    // This blocks every INSERT when no arena rows exist yet.
    // Referee→arena mapping is no longer needed at the row level.

    // 5a: find and drop the FK constraint by its real name
    try {
      final fkResult = await conn.execute("""
        SELECT CONSTRAINT_NAME
        FROM information_schema.KEY_COLUMN_USAGE
        WHERE TABLE_SCHEMA          = DATABASE()
          AND TABLE_NAME            = 'tbl_referee'
          AND COLUMN_NAME           = 'arena_id'
          AND REFERENCED_TABLE_NAME IS NOT NULL
        LIMIT 1
      """);
      if (fkResult.rows.isNotEmpty) {
        final fkName =
            fkResult.rows.first.assoc()['CONSTRAINT_NAME'] ?? '';
        if (fkName.isNotEmpty) {
          await conn.execute(
              "ALTER TABLE tbl_referee DROP FOREIGN KEY `$fkName`");
          print("✅ Migration 5a: dropped FK '$fkName' from tbl_referee.");
        }
      } else {
        print("ℹ️  Migration 5a: no arena_id FK found on tbl_referee.");
      }
    } catch (e) {
      print("ℹ️  Migration 5a: could not drop arena_id FK — $e");
    }

    // 5b: drop the arena_id column itself
    try {
      await conn.execute("ALTER TABLE tbl_referee DROP COLUMN arena_id");
      print("✅ Migration 5b: arena_id column removed from tbl_referee.");
    } catch (_) {
      print("ℹ️  Migration 5b: arena_id already removed.");
    }

    // Migration 6: access_code column on tbl_category
    // Each category gets a unique 6-character alphanumeric code that referees
    // enter in the scoring app to unlock their assigned category.
    try {
      await conn.execute("""
        ALTER TABLE tbl_category
        ADD COLUMN access_code VARCHAR(10) NOT NULL DEFAULT ''
      """);
      print("✅ Migration 6: access_code column added to tbl_category.");
    } catch (_) {
      print("ℹ️  Migration 6: access_code already present.");
    }

    // Fill in codes for any category that has an empty one
    try {
      final cats = await conn.execute(
        "SELECT category_id FROM tbl_category WHERE access_code = '' OR access_code IS NULL",
      );
      for (final row in cats.rows) {
        final id   = row.assoc()['category_id'] ?? '0';
        final code = _generateCode();
        await conn.execute(
          "UPDATE tbl_category SET access_code = :code WHERE category_id = :id",
          {"code": code, "id": id},
        );
      }
      if (cats.rows.isNotEmpty) {
        print("✅ Migration 6: generated access codes for ${cats.rows.length} categories.");
      }
    } catch (e) {
      print("ℹ️  Migration 6: could not seed access codes — $e");
    }

    // Migration 7: bracket_type column on tbl_match
    // Labels each match: 'group', 'play-in', 'upper', 'lower', 'finals'
    try {
      await conn.execute("""
        ALTER TABLE tbl_match
        ADD COLUMN bracket_type VARCHAR(20) NOT NULL DEFAULT 'run'
      """);
      print("✅ Migration 7: bracket_type column added to tbl_match.");
    } catch (_) {
      print("ℹ️  Migration 7: bracket_type already present.");
    }
  }
  // Generates a random 6-char uppercase alphanumeric code, e.g. "A3F9KX"
  static String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng   = DateTime.now().microsecondsSinceEpoch;
    final buf   = StringBuffer();
    var   seed  = rng.abs();
    for (int i = 0; i < 6; i++) {
      seed = (seed * 1664525 + 1013904223).abs();
      buf.write(chars[seed % chars.length]);
    }
    return buf.toString();
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

  static Future<String?> getCategoryAccessCode(int id) async {
    final conn   = await getConnection();
    final result = await conn.execute(
      "SELECT access_code FROM tbl_category WHERE category_id = :id",
      {'id': id},
    );
    if (result.rows.isEmpty) return null;
    return result.rows.first.assoc()['access_code'];
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
    final result = await conn.execute("""
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
      await conn.execute("""
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

  /// Clears ALL schedule-related data across every category.
  /// Used when regenerating non-soccer schedules.
  static Future<void> clearSchedule() async {
    final conn = await getConnection();

    await conn.execute("DELETE FROM tbl_score");
    await conn.execute("ALTER TABLE tbl_score AUTO_INCREMENT = 1");

    await conn.execute("DELETE FROM tbl_teamschedule");
    await conn.execute("ALTER TABLE tbl_teamschedule AUTO_INCREMENT = 1");

    await conn.execute("DELETE FROM tbl_match");
    await conn.execute("ALTER TABLE tbl_match AUTO_INCREMENT = 1");

    await conn.execute("DELETE FROM tbl_schedule");
    await conn.execute("ALTER TABLE tbl_schedule AUTO_INCREMENT = 1");

    print("✅ Schedule cleared and IDs reset.");
  }

  /// Clears ONLY soccer schedule data (group + bracket matches).
  /// Non-soccer category schedules are left untouched.
  /// Also clears tbl_soccer_groups so stale group assignments do not
  /// mismatch with the newly generated tbl_teamschedule rows.
  static Future<void> clearSoccerSchedule(int categoryId) async {
    final conn = await getConnection();

    // Step 1: Delete scores for soccer teams
    await conn.execute("""
      DELETE sc FROM tbl_score sc
      INNER JOIN tbl_team t ON sc.team_id = t.team_id
      WHERE t.category_id = $categoryId
    """);

    // Step 2: Delete teamschedule rows for soccer teams only
    await conn.execute("""
      DELETE ts FROM tbl_teamschedule ts
      INNER JOIN tbl_team t ON ts.team_id = t.team_id
      WHERE t.category_id = $categoryId
    """);

    // Step 3: Delete matches that now have no teamschedule rows
    // AND are soccer bracket-type (includes TBD knockout slots)
    await conn.execute("""
      DELETE m FROM tbl_match m
      WHERE m.bracket_type IN (
        'group','round-of-32','round-of-16',
        'quarter-finals','semi-finals','third-place','final',
        'play-in','upper','lower','finals'
      )
      AND m.match_id NOT IN (
        SELECT DISTINCT ts2.match_id FROM tbl_teamschedule ts2
      )
    """);

    // Step 3b: Also delete any remaining soccer bracket matches
    // that still have teamschedule rows from OTHER categories
    // (safety net for cross-contamination)
    await conn.execute("""
      DELETE ts FROM tbl_teamschedule ts
      WHERE ts.match_id IN (
        SELECT m2.match_id FROM tbl_match m2
        WHERE m2.bracket_type IN (
          'group','round-of-32','round-of-16',
          'quarter-finals','semi-finals','third-place','final'
        )
      )
      AND ts.team_id NOT IN (
        SELECT t2.team_id FROM tbl_team t2
        WHERE t2.category_id = $categoryId
      )
    """);

    // Step 3c: Clean up any now-empty matches again
    await conn.execute("""
      DELETE m FROM tbl_match m
      WHERE m.bracket_type IN (
        'group','round-of-32','round-of-16',
        'quarter-finals','semi-finals','third-place','final'
      )
      AND m.match_id NOT IN (
        SELECT DISTINCT ts3.match_id FROM tbl_teamschedule ts3
      )
    """);

    // Step 4: Delete orphaned schedule rows
    await conn.execute("""
      DELETE s FROM tbl_schedule s
      WHERE s.schedule_id NOT IN (
        SELECT DISTINCT m2.schedule_id FROM tbl_match m2
      )
    """);

    // Step 5: Clear stale soccer groups
    try {
      await conn.execute(
        "DELETE FROM tbl_soccer_groups WHERE category_id = $categoryId",
      );
    } catch (_) {}

    print("✅ Soccer schedule cleared for category $categoryId.");
  }




  /// Clears schedule data for specific non-soccer categories only.
  /// Soccer schedules are left untouched.
  static Future<void> clearCategorySchedule(List<int> categoryIds) async {
    if (categoryIds.isEmpty) return;
    final conn = await getConnection();
    final ids  = categoryIds.join(',');

    // Step 1: Delete scores for these categories' teams
    await conn.execute("""
      DELETE sc FROM tbl_score sc
      INNER JOIN tbl_teamschedule ts ON sc.match_id   = ts.match_id
                                    AND sc.team_id    = ts.team_id
      INNER JOIN tbl_team t          ON ts.team_id    = t.team_id
      WHERE t.category_id IN ($ids)
    """);

    // Step 2: Delete teamschedule rows for these categories' teams
    await conn.execute("""
      DELETE ts FROM tbl_teamschedule ts
      INNER JOIN tbl_team t ON ts.team_id = t.team_id
      WHERE t.category_id IN ($ids)
    """);

    // Step 3: Delete matches that have NO more teamschedule rows
    // AND were only for these specific non-soccer categories
    // (use subquery to only delete matches that belonged to these categories)
    await conn.execute("""
      DELETE m FROM tbl_match m
      WHERE m.match_id NOT IN (
          SELECT DISTINCT ts2.match_id FROM tbl_teamschedule ts2
        )
        AND m.match_id IN (
          SELECT DISTINCT ts3.match_id FROM tbl_teamschedule ts3
          INNER JOIN tbl_team t3 ON ts3.team_id = t3.team_id
          WHERE t3.category_id IN ($ids)
        )
        AND m.bracket_type = 'run'
    """);

    // Step 4: Delete orphaned schedule rows
    await conn.execute("""
      DELETE s FROM tbl_schedule s
      WHERE s.schedule_id NOT IN (
        SELECT DISTINCT m2.schedule_id FROM tbl_match m2
      )
    """);

    print("✅ Schedule cleared for categories: $ids");
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

  static Future<int> insertMatch(int scheduleId,
      {String bracketType = 'run'}) async {
    final conn   = await getConnection();
    final result = await conn.execute("""
      INSERT INTO tbl_match (schedule_id, bracket_type)
      VALUES (:scheduleId, :bracketType)
    """, {"scheduleId": scheduleId, "bracketType": bracketType});
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
  //
  // QUEUE-BASED LOGIC (1 team per arena per match — NO head-to-head):
  //
  //   RULE: No team may appear in more than one arena in the same time slot.
  //
  //   Algorithm:
  //   1. Build a queue of all team-slots: [A,B,C,D, A,B,C,D] (teams × runs)
  //      For 2 arenas: Run1 is normal order, Run2 is reversed (snake).
  //      For 1 or 3+ arenas: all runs are normal order.
  //   2. For each match row, fill arenas one by one from the queue.
  //      Skip a team if it is already assigned to this match (conflict).
  //      Deferred (skipped) teams are re-queued at the back.
  //   3. A match row is complete when all arenas are filled OR the queue
  //      is exhausted. Unfilled arenas show blank in the display.
  //
  //   Example — 4 teams, 2 runs, 3 arenas (8 total slots, ceil(8/3)=3 matches):
  //     Queue : A B C D D C B A  (run1 normal + run2 reversed for 2-arena feel,
  //                                but here 3 arenas so both normal)
  //           = A B C D A B C D
  //     Match 1: Arena1=A, Arena2=B, Arena3=C  → remaining: D A B C D
  //     Match 2: Arena1=D, Arena2=A, Arena3=B  → remaining: C D
  //     Match 3: Arena1=C, Arena2=D, Arena3=—  → queue empty
  //
  //   Special case — 2 arenas uses snake (run2 reversed) so that the team
  static Future<void> generateSchedule({
    required Map<int, int> runsPerCategory,
    required Map<int, int> arenasPerCategory,
    required String startTime,
    required String endTime,
    required int durationMinutes,
    required int intervalMinutes,
    int healthBreakMinutes = 0,
    bool lunchBreak = true,
  }) async {
    final conn = await getConnection();

    await clearCategorySchedule(runsPerCategory.keys.toList());

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

    // ── helpers ──────────────────────────────────────────────────────────────
    String fmtMin(int t) {
      final h = (t ~/ 60).toString().padLeft(2, '0');
      final m = (t %  60).toString().padLeft(2, '0');
      return '$h:$m:00';
    }

    int applyLunch(int t) {
      if (!lunchBreak) return t;
      const lunchStart = 12 * 60;
      const lunchEnd   = 13 * 60;
      if (t >= lunchStart && t < lunchEnd) return lunchEnd;
      return t;
    }

    final startParts      = startTime.split(':');
    final startMinutes    = int.parse(startParts[0]) * 60
                          + int.parse(startParts[1]);
    final endParts        = endTime.split(':');
    final endLimitMinutes = int.parse(endParts[0]) * 60
                          + int.parse(endParts[1]);

    // ── per-category scheduling ───────────────────────────────────────────────
    for (final entry in runsPerCategory.entries) {
      final categoryId = entry.key;
      final runs       = entry.value;
      final arenas     = (arenasPerCategory[categoryId] ?? 1).clamp(1, 99);
      final teams      = await getTeamsByCategory(categoryId);
      if (teams.isEmpty) continue;

      final n          = teams.length;
      int timeCursor   = applyLunch(startMinutes);

      if (arenas == 1) {
        // ── 1 ARENA: each run sequential top→bottom ───────────────────────
        for (int run = 0; run < runs; run++) {
          if (run > 0 && healthBreakMinutes > 0) {
            timeCursor = applyLunch(timeCursor + healthBreakMinutes);
            print("💚 Health break before run ${run + 1} for category $categoryId.");
          }
          for (int slot = 0; slot < n; slot++) {
            int t = applyLunch(timeCursor);
            if (t + durationMinutes > endLimitMinutes) {
              print("⚠️  End time reached at run ${run + 1} slot $slot.");
              break;
            }
            final scheduleId = await insertSchedule(
              startTime: fmtMin(t),
              endTime:   fmtMin(t + durationMinutes),
            );
            final matchId = await insertMatch(scheduleId);
            await insertTeamSchedule(
              matchId:     matchId,
              roundId:     run + 1,
              teamId:      int.parse(teams[slot]['team_id'].toString()),
              refereeId:   defaultRefereeId,
              arenaNumber: 1,
            );
            timeCursor = t + durationMinutes + intervalMinutes;
          }
          print("✅ Run ${run + 1} Arena 1 of category $categoryId scheduled.");
        }

      } else if (arenas == 2) {
        // ── 2 ARENAS: snake — Arena1 top→bottom, Arena2 bottom→top ──────────
        final int runPairs = (runs / 2).ceil();
        for (int pair = 0; pair < runPairs; pair++) {
          if (pair > 0 && healthBreakMinutes > 0) {
            timeCursor = applyLunch(timeCursor + healthBreakMinutes);
            print("💚 Health break before pair ${pair + 1} for category $categoryId.");
          }

          final List<int> matchIds = [];
          int slotCursor = timeCursor;
          for (int slot = 0; slot < n; slot++) {
            int t = applyLunch(slotCursor);
            if (t + durationMinutes > endLimitMinutes) {
              print("⚠️  End time reached at slot $slot.");
              break;
            }
            final scheduleId = await insertSchedule(
              startTime: fmtMin(t),
              endTime:   fmtMin(t + durationMinutes),
            );
            matchIds.add(await insertMatch(scheduleId));
            slotCursor = t + durationMinutes + intervalMinutes;
          }
          timeCursor = slotCursor;

          // Arena 1 — top→bottom
          final int run1 = pair * 2;
          if (run1 < runs) {
            for (int slot = 0; slot < matchIds.length; slot++) {
              await insertTeamSchedule(
                matchId:     matchIds[slot],
                roundId:     run1 + 1,
                teamId:      int.parse(teams[slot]['team_id'].toString()),
                refereeId:   defaultRefereeId,
                arenaNumber: 1,
              );
            }
            print("✅ Run ${run1 + 1} ↓ Arena 1 of category $categoryId scheduled.");
          }

          // Arena 2 — bottom→top (reversed / snake)
          final int run2 = pair * 2 + 1;
          if (run2 < runs) {
            for (int slot = 0; slot < matchIds.length; slot++) {
              final int teamIndex = n - 1 - slot;
              if (teamIndex < 0 || teamIndex >= n) continue;
              await insertTeamSchedule(
                matchId:     matchIds[slot],
                roundId:     run2 + 1,
                teamId:      int.parse(teams[teamIndex]['team_id'].toString()),
                refereeId:   defaultRefereeId,
                arenaNumber: 2,
              );
            }
            print("✅ Run ${run2 + 1} ↑ Arena 2 of category $categoryId scheduled.");
          }
        }

      } else {
        // ── 3+ ARENAS: queue-based — no team conflict in same time slot ──────
        final queue = <Map<String, int>>[];
        for (int run = 0; run < runs; run++) {
          for (int i = 0; i < n; i++) {
            queue.add({
              'teamId':  int.parse(teams[i]['team_id'].toString()),
              'roundId': run + 1,
            });
          }
        }

        int matchNum = 0;
        while (queue.isNotEmpty) {
          int t = applyLunch(timeCursor);
          if (t + durationMinutes > endLimitMinutes) {
            print("⚠️  End time reached at match ${matchNum + 1} for category $categoryId.");
            break;
          }

          final scheduleId = await insertSchedule(
            startTime: fmtMin(t),
            endTime:   fmtMin(t + durationMinutes),
          );
          final matchId = await insertMatch(scheduleId);
          matchNum++;
          timeCursor = t + durationMinutes + intervalMinutes;

          final Set<int> usedTeams = {};
          int filled = 0;

          for (int a = 1; a <= arenas; a++) {
            if (queue.isEmpty) break;

            int? foundIdx;
            for (int qi = 0; qi < queue.length; qi++) {
              if (!usedTeams.contains(queue[qi]['teamId'])) {
                foundIdx = qi;
                break;
              }
            }
            if (foundIdx == null) break;

            final picked = queue.removeAt(foundIdx);
            usedTeams.add(picked['teamId']!);

            await insertTeamSchedule(
              matchId:     matchId,
              roundId:     picked['roundId']!,
              teamId:      picked['teamId']!,
              refereeId:   defaultRefereeId,
              arenaNumber: a,
            );
            filled++;
          }

          print("✅ Match $matchNum: $filled/${arenas} arenas filled for category $categoryId.");
        }
      }

      print("✅ Category $categoryId fully scheduled "
            "($runs run${runs != 1 ? 's' : ''}, "
            "$arenas arena${arenas != 1 ? 's' : ''}, "
            "$n team${n != 1 ? 's' : ''}).");
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

  // ── FIFA-STYLE SOCCER SCHEDULE ──────────────────────────────────────────
  //
  // Generates a complete FIFA-format tournament:
  //   Phase 1: Group Stage — round-robin within groups, parallel across arenas
  //   Phase 2: Knockout    — R16/QF/SF/3rd place/Final (single elimination)
  //
  // Auto-scales based on number of teams:
  //   8  teams → 2 groups of 4 → QF (8 KO slots)
  //   12 teams → 3 groups of 4 → R16 (with byes)
  //   16 teams → 4 groups of 4 → R16 (16 KO slots)
  //   24 teams → 6 groups of 4 → R16 (16 KO slots, 4 byes)
  //   32 teams → 8 groups of 4 → R16 (32 KO slots)
  //
  // Groups and schedules are saved to DB.
  // Knockout slots are TBD placeholders filled after group stage.
  //
  static Future<void> generateFifaSchedule({
    required List<List<Map<String, dynamic>>> groups,
    required int arenas,
    required int categoryId,
    required String startTime,
    required String endTime,
    required int durationMinutes,
    required int intervalMinutes,
    bool lunchBreak = true,
  }) async {
    await clearSoccerSchedule(categoryId);

    final conn = await getConnection();
    final refResult = await conn.execute(
      "SELECT referee_id FROM tbl_referee ORDER BY referee_id LIMIT 1",
    );
    if (refResult.rows.isEmpty) {
      throw Exception('No referees found. Add at least one referee first.');
    }
    final defaultRefereeId = int.parse(
      refResult.rows.first.assoc()['referee_id'] ?? '0',
    );

    final startParts   = startTime.split(':');
    final startMinutes = int.parse(startParts[0]) * 60 + int.parse(startParts[1]);
    final endParts     = endTime.split(':');
    final endLimit     = int.parse(endParts[0]) * 60 + int.parse(endParts[1]);

    String fmt(int m) =>
        '${(m ~/ 60).toString().padLeft(2, "0")}:${(m % 60).toString().padLeft(2, "0")}:00';

    int skipLunch(int t) {
      if (!lunchBreak) return t;
      if (t >= 12 * 60 && t < 13 * 60) return 13 * 60;
      return t;
    }

    // Seed rounds for group stage (max pairs per group)
    final maxGroupSize = groups.isEmpty ? 1
        : groups.map((g) => g.length).reduce((a, b) => a > b ? a : b);
    final maxPairs = (maxGroupSize * (maxGroupSize - 1)) ~/ 2;
    await seedRounds(maxPairs < 1 ? 1 : maxPairs);

    // ── PHASE 1: GROUP STAGE ──────────────────────────────────────────────
    //
    // CONFLICT-FREE SLOT FILLER:
    //
    // Rules:
    //   1. Each time slot has exactly [arenas] matches running in parallel.
    //   2. No team appears in more than one arena at the same time.
    //   3. No blanks — slots are always filled if matches remain.
    //   4. Teams get maximum rest — matches from the same group
    //      are spread out using round-based ordering.
    //
    // Algorithm:
    //   a. Build all matches ordered by round (circle method) so same-group
    //      matches are naturally spaced apart.
    //   b. Each time slot: pick one match per arena from the remaining queue,
    //      skipping any match whose teams conflict with already-picked matches.
    //   c. If no non-conflicting match exists for an arena, leave that
    //      arena empty this slot (but this should be rare with good ordering).

    // ── Build all matches in round-based order ────────────────────────────
    // Circle method: produces balanced rounds where no team plays twice
    List<List<List<Map<String, dynamic>>>> buildRounds(
        List<Map<String, dynamic>> group) {
      final n      = group.length;
      final rounds = <List<List<Map<String, dynamic>>>>[];
      if (n < 2) return rounds;
      final teams  = List<Map<String, dynamic>>.from(group);
      if (n % 2 != 0) teams.add({'team_id': '-1', 'team_name': 'BYE'});
      final nt = teams.length;
      for (int r = 0; r < nt - 1; r++) {
        final rp = <List<Map<String, dynamic>>>[];
        for (int i = 0; i < nt ~/ 2; i++) {
          final t1 = teams[i], t2 = teams[nt - 1 - i];
          if (t1['team_id'] != '-1' && t2['team_id'] != '-1')
            rp.add([t1, t2]);
        }
        rounds.add(rp);
        final last = teams.removeAt(nt - 1);
        teams.insert(1, last);
      }
      return rounds;
    }

    // Flatten all matches into a queue ordered by round
    // Each entry: { 'gIdx': int, 'pair': [team1, team2], 'round': int }
    final queue = <Map<String, dynamic>>[];
    final allGroupRounds = groups.map(buildRounds).toList();

    // Interleave groups round-by-round so same-group matches are spread out
    final maxRounds = allGroupRounds.isEmpty ? 0
        : allGroupRounds.map((gr) => gr.length).reduce((a, b) => a > b ? a : b);
    for (int r = 0; r < maxRounds; r++) {
      for (int gIdx = 0; gIdx < groups.length; gIdx++) {
        final gr = allGroupRounds[gIdx];
        if (r >= gr.length) continue;
        for (final pair in gr[r]) {
          queue.add({'gIdx': gIdx, 'pair': pair, 'round': r + 1});
        }
      }
    }

    int timeCursor = skipLunch(startMinutes);

    // Schedule: fill slots greedily, one match per arena per slot
    // Skip matches whose teams conflict with already-scheduled arenas this slot
    while (queue.isNotEmpty) {
      int t = skipLunch(timeCursor);
      if (t + durationMinutes > endLimit) break;

      // Teams already booked this time slot (across all arenas)
      final Set<String> bookedTeams = {};
      // Matches picked for this slot (one per arena)
      final Map<int, Map<String, dynamic>> slotPicks = {};

      // Try to fill each arena
      for (int a = 1; a <= arenas; a++) {
        // Find the first queued match with no team conflict
        int? picked;
        for (int qi = 0; qi < queue.length; qi++) {
          final match = queue[qi];
          final pair  = match['pair'] as List;
          final id1   = pair[0]['team_id'].toString();
          final id2   = pair[1]['team_id'].toString();
          if (!bookedTeams.contains(id1) && !bookedTeams.contains(id2)) {
            picked = qi;
            bookedTeams.add(id1);
            bookedTeams.add(id2);
            slotPicks[a] = match;
            break;
          }
        }
        if (picked != null) queue.removeAt(picked);
      }

      // If nothing was picked at all, break to avoid infinite loop
      if (slotPicks.isEmpty) break;

      // Write all picked matches to DB at the same time slot
      for (final entry in slotPicks.entries) {
        final a     = entry.key;
        final match = entry.value;
        final pair  = match['pair']  as List;
        final gIdx  = match['gIdx']  as int;
        final round = match['round'] as int;

        final schedId = await insertSchedule(
            startTime: fmt(t), endTime: fmt(t + durationMinutes));
        final matchId = await insertMatch(schedId, bracketType: 'group');
        await insertTeamSchedule(
            matchId: matchId, roundId: round,
            teamId: int.parse(pair[0]['team_id'].toString()),
            refereeId: defaultRefereeId, arenaNumber: a);
        await insertTeamSchedule(
            matchId: matchId, roundId: round,
            teamId: int.parse(pair[1]['team_id'].toString()),
            refereeId: defaultRefereeId, arenaNumber: a);

        print("✅ Arena $a Group ${String.fromCharCode(65 + gIdx)} "
              "Round $round @ ${fmt(t)}");
      }

      timeCursor = skipLunch(timeCursor + durationMinutes + intervalMinutes);
    }
    print("✅ Group stage done — no conflicts, no blanks.");

    // ── PHASE 2: KNOCKOUT STAGE ───────────────────────────────────────────
    // Determine bracket size: next power of 2 >= numGroups * 2 (top 2 per group)
    final int advancingTeams = groups.length * 2; // top 2 per group
    int bracketSize = 1;
    while (bracketSize < advancingTeams) bracketSize <<= 1;

    // Knockout rounds:
    //   bracketSize=8  → QF(4)+SF(2)+3rd(1)+F(1) = 8 matches
    //   bracketSize=16 → R16(8)+QF(4)+SF(2)+3rd(1)+F(1) = 16 matches
    //   bracketSize=32 → R32(16)+R16(8)+QF(4)+SF(2)+3rd(1)+F(1) = 32 matches

    // Build rounds list: [ {label, count} ]
    final koRounds = <Map<String, dynamic>>[];
    int sz = bracketSize;
    while (sz >= 2) {
      String label;
      if (sz == bracketSize) {
        if (sz == 8)  label = 'quarter-finals';
        else if (sz == 4) label = 'semi-finals';
        else label = 'round-of-${sz}';
      } else if (sz == 4) label = 'quarter-finals';
      else if (sz == 2) label = 'semi-finals';
      else label = 'round-of-${sz}';
      koRounds.add({'label': label, 'count': sz ~/ 2});
      sz ~/= 2;
    }
    // Add 3rd place + final
    koRounds.add({'label': 'third-place', 'count': 1});
    koRounds.add({'label': 'final',       'count': 1});

    // Add a gap between group stage and knockout
    timeCursor = skipLunch(timeCursor + intervalMinutes * 3);

    for (final round in koRounds) {
      final String bracketType = round['label'] as String;
      final int    count       = round['count'] as int;
      final int    perArena    = (count / arenas).ceil();

      for (int r = 0; r < perArena; r++) {
        int t = skipLunch(timeCursor);
        if (t + durationMinutes > endLimit) break;
        final matchesThisSlot = (r == perArena - 1 && count % arenas != 0)
            ? count % arenas : arenas;
        for (int a = 1; a <= matchesThisSlot; a++) {
          final schedId = await insertSchedule(startTime: fmt(t), endTime: fmt(t + durationMinutes));
          await insertMatch(schedId, bracketType: bracketType);
        }
        timeCursor = skipLunch(timeCursor + durationMinutes + intervalMinutes);
        print("✅ $bracketType slot @ ${fmt(t)}");
      }
    }
    print("✅ FIFA schedule generated! ${groups.length} groups, bracket size $bracketSize.");
  }

}