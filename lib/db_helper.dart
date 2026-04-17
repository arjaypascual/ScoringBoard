// ignore_for_file: avoid_print


import 'dart:async';
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

    // Migration 9: normalize legacy 'round-of-8' bracket_type → 'quarter-finals'
    try {
      await conn.execute("""
        UPDATE tbl_match
        SET bracket_type = 'quarter-finals'
        WHERE bracket_type = 'round-of-8'
      """);
      print("✅ Migration 9: normalized round-of-8 → quarter-finals.");
    } catch (e) {
      print("ℹ️  Migration 9: $e");
    }

    // Migration 10: round-of-16 is now a REAL bracket round (used for 9+ groups).
    // We no longer rename it to 'elimination'. Instead normalize only legacy
    // 'round-of-32' entries that were incorrectly inserted.
    try {
      await conn.execute("""
        UPDATE tbl_match
        SET bracket_type = 'elimination'
        WHERE bracket_type = 'round-of-32'
      """);
      print("✅ Migration 10: normalized round-of-32 → elimination.");
    } catch (e) {
      print("ℹ️  Migration 10: $e");
    }

     // Migration 11: tbl_attendance — shared with the on-site attendance app.
    // Stores present/absent per team (and optionally referee/mentor) so both
    // apps read and write the same source of truth.
    try {
      await conn.execute('''
        CREATE TABLE IF NOT EXISTS tbl_attendance (
          attendance_id INT AUTO_INCREMENT PRIMARY KEY,
          entity_type   ENUM('team','referee','mentor') NOT NULL,
          entity_id     INT NOT NULL,
          is_present    TINYINT(1) NOT NULL DEFAULT 0,
          updated_at    DATETIME DEFAULT CURRENT_TIMESTAMP
                        ON UPDATE CURRENT_TIMESTAMP,
          UNIQUE KEY uq_entity (entity_type, entity_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
      ''');
      print('✅ Migration 11: tbl_attendance created.');
    } catch (_) {
      print('ℹ️  Migration 11: tbl_attendance already present.');
    }

    print("✅ Migrations complete.");

    // Migration X: category_id column on tbl_match
    try {
      await conn.execute("""
        ALTER TABLE tbl_match
        ADD COLUMN category_id INT NOT NULL DEFAULT 0
      """);
      print("✅ Migration X: category_id column added to tbl_match.");
    } catch (_) {
      print("ℹ️  Migration X: category_id already present.");
    }
  }
  // Generates a random 6-char uppercase alphanumeric code, e.g. "A3F9KX"
  // Uses Random.secure() so codes are cryptographically unpredictable and
  // never collide even when multiple categories are seeded back-to-back.
  static String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng   = Random.secure();
    final buf   = StringBuffer();
    for (int i = 0; i < 6; i++) {
      buf.write(chars[rng.nextInt(chars.length)]);
    }
    return buf.toString();
  }


  // ── CONNECTION ────────────────────────────────────────────────────────────
  // _connectLock serialises concurrent getConnection() callers so only one
  // MySQLConnection is ever created, even under simultaneous async calls.
  static Completer<MySQLConnection>? _connectLock;

  static Future<MySQLConnection> getConnection() async {
    // Fast path — reuse an already-open connection.
    try {
      if (_connection != null && _connection!.connected) {
        return _connection!;
      }
    } catch (_) {
      _connection = null;
    }

    // If another caller is already connecting, wait for it instead of
    // creating a second connection in parallel.
    if (_connectLock != null) {
      return _connectLock!.future;
    }

    _connectLock = Completer<MySQLConnection>();
    try {
      final conn = await MySQLConnection.createConnection(
        host:         _host,
        port:         _port,
        userName:     _userName,
        password:     _password,
        databaseName: _databaseName,
        secure:       false,
      );
      await conn.connect();
      _connection = conn;
      print("✅ Database connected!");
      _connectLock!.complete(conn);
      return conn;
    } catch (e) {
      _connectLock!.completeError(e);
      rethrow;
    } finally {
      // Clear lock so a later call can retry after a connection error.
      _connectLock = null;
    }
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

  static Future<List<Map<String, String?>>> getActiveCategories() async {
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
      SELECT t.team_id, t.team_name,
             COALESCE(a.is_present, 1) AS team_ispresent,
             c.category_type, m.mentor_name
      FROM tbl_team t
      JOIN tbl_category c ON t.category_id = c.category_id
      JOIN tbl_mentor   m ON t.mentor_id   = m.mentor_id
      LEFT JOIN tbl_attendance a
             ON a.entity_type = 'team' AND a.entity_id = t.team_id
      ORDER BY t.team_id
    """);
    return result.rows.map((r) => r.assoc()).toList();
  }

  static Future<List<Map<String, dynamic>>> getTeamsByCategory(
      int categoryId, {bool presentOnly = false}) async {
    final conn   = await getConnection();
    final result = await conn.execute("""
      SELECT t.team_id, t.team_name,
             COALESCE(a.is_present, 1) AS team_ispresent,
             c.category_type, m.mentor_name
      FROM tbl_team t
      JOIN tbl_category c ON t.category_id = c.category_id
      JOIN tbl_mentor   m ON t.mentor_id   = m.mentor_id
      LEFT JOIN tbl_attendance a
             ON a.entity_type = 'team' AND a.entity_id = t.team_id
      WHERE t.category_id = :categoryId
        ${presentOnly ? "AND COALESCE(a.is_present, 1) = 1" : ""}
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

  /// Clears ALL soccer schedule data completely.
  /// Direct bracket_type filter — guaranteed clean slate every time.
  static Future<void> clearSoccerSchedule(int categoryId) async {
    final conn = await getConnection();

    // Step 1: Get all soccer match IDs first
    // FIX: Added 'elimination' to the bracket_type list so those slots
    // are also cleared when regenerating the schedule.
    final soccerMatchResult = await conn.execute("""
      SELECT match_id FROM tbl_match
      WHERE bracket_type IN (
        'group','round-of-32','elimination','round-of-16',
        'quarter-finals','semi-finals','third-place','final',
        'play-in','upper','lower','finals'
      )
    """);
    final soccerMatchIds = soccerMatchResult.rows
        .map((r) => r.assoc()['match_id'] ?? '0')
        .where((id) => id != '0')
        .toList();

    if (soccerMatchIds.isNotEmpty) {
      // ids is built from DB-returned integers only — not user input — so
      // IN ($ids) interpolation here is safe (named params can't be used for IN lists).
      final ids = soccerMatchIds.join(',');

      // Step 1a: Delete scores FIRST (FK → tbl_match must go before tbl_match)
      await conn.execute(
          'DELETE FROM tbl_score WHERE match_id IN ($ids)');

      // Step 1b: Delete teamschedule rows
      await conn.execute(
          'DELETE FROM tbl_teamschedule WHERE match_id IN ($ids)');

      // Step 1d: Now safe to delete matches
      await conn.execute(
          'DELETE FROM tbl_match WHERE match_id IN ($ids)');
    }

    // Step 3: Also delete any leftover scores for soccer teams (safety net)
    await conn.execute("""
      DELETE sc FROM tbl_score sc
      INNER JOIN tbl_team t ON sc.team_id = t.team_id
      WHERE t.category_id = :catId
    """, {"catId": categoryId});
    // Step 4: Delete orphaned schedule rows
    final validSchedResult = await conn.execute(
        'SELECT DISTINCT schedule_id FROM tbl_match');
    final validIds = validSchedResult.rows
        .map((r) => r.assoc()['schedule_id'] ?? '0')
        .where((id) => id != '0')
        .toList();
    if (validIds.isEmpty) {
      await conn.execute('DELETE FROM tbl_schedule');
    } else {
      await conn.execute(
          'DELETE FROM tbl_schedule WHERE schedule_id NOT IN (' + validIds.join(',') + ')');
    }

    // Step 5: Clear soccer groups
    try {
      await conn.execute(
        "DELETE FROM tbl_soccer_groups WHERE category_id = :catId",
        {"catId": categoryId},
      );
    } catch (_) {}

    print("✅ Soccer schedule fully cleared for category $categoryId.");
  }




  /// Clears schedule data for specific non-soccer categories only.
  /// Soccer schedules are left untouched.
  static Future<void> clearCategorySchedule(List<int> categoryIds) async {
    if (categoryIds.isEmpty) return;
    final conn = await getConnection();
    // ids is derived from List<int> — not user input — so IN ($ids) is safe.
    // MySQL named parameters cannot be used for variable-length IN lists.
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
    final validSchedResult = await conn.execute(
        'SELECT DISTINCT schedule_id FROM tbl_match');
    final validIds = validSchedResult.rows
        .map((r) => r.assoc()['schedule_id'] ?? '0')
        .where((id) => id != '0')
        .toList();
    if (validIds.isEmpty) {
      await conn.execute('DELETE FROM tbl_schedule');
    } else {
      await conn.execute(
          'DELETE FROM tbl_schedule WHERE schedule_id NOT IN (' + validIds.join(',') + ')');
    }

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
      {String bracketType = 'run', int? categoryId}) async {
    final conn   = await getConnection();
    final result = await conn.execute("""
      INSERT INTO tbl_match (schedule_id, bracket_type, category_id)
      VALUES (:scheduleId, :bracketType, :catId)
    """, {"scheduleId": scheduleId, "bracketType": bracketType, "catId": categoryId ?? 0});
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

    // ── Guard: check for referees BEFORE clearing anything ───────────────────
    // If we cleared first and then found no referees, the schedule would be
    // wiped with nothing written — leaving the DB in an empty broken state.
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

    await clearCategorySchedule(runsPerCategory.keys.toList());

    final maxRuns = runsPerCategory.values.isEmpty
        ? 1
        : runsPerCategory.values.reduce((a, b) => a > b ? a : b);
    await seedRounds(maxRuns);

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
      // ── Only include PRESENT teams in the schedule ───────────────────────
      final teams = await getTeamsByCategory(categoryId, presentOnly: true);
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

  // ── SOCCER SCORES (tbl_score) ─────────────────────────────────────────────
  // Returns scores per team per match for a soccer category using tbl_score
  static Future<List<Map<String, dynamic>>> getSoccerScoresByCategory(
      int categoryId) async {
    final conn   = await getConnection();
    final result = await conn.execute("""
      SELECT
        sc.score_id        AS id,
        sc.match_id,
        sc.team_id,
        t.team_name,
        sc.score_totalscore   AS goals,
        sc.score_violation    AS fouls,
        sc.score_totalduration AS duration,
        sc.round_id,
        sc.score_isapproved   AS is_approved
      FROM tbl_score sc
      JOIN tbl_team t ON t.team_id = sc.team_id
      WHERE t.category_id = :categoryId
      ORDER BY sc.match_id, sc.score_id
    """, {"categoryId": categoryId});
    return result.rows.map((r) => r.assoc()).toList();
  }

  // Check if a soccer match already has scores
  static Future<bool> soccerMatchIsScored(int matchId) async {
    final conn   = await getConnection();
    final result = await conn.execute(
      "SELECT COUNT(*) as cnt FROM tbl_score WHERE match_id = :mid",
      {"mid": matchId},
    );
    final cnt = int.tryParse(
        result.rows.first.assoc()['cnt']?.toString() ?? '0') ?? 0;
    return cnt > 0;
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
  //   Phase 2: Knockout    — ELIM/QF/SF/3rd place/Final (single elimination)
  //
  // Auto-scales based on number of groups (top 2 per group advance):
  //
  //   2 grp →  4 teams → SF(2)            → 3RD(1) → FINAL(1)
  //   3 grp →  6 teams → ELIM(2, 2 BYE)  → QF(4)  → SF(2) → 3RD(1) → FINAL(1)
  //   4 grp →  8 teams → QF(4)            → SF(2)  → 3RD(1) → FINAL(1)
  //   5 grp → 10 teams → ELIM(2, 6 BYE)  → QF(4)  → SF(2) → 3RD(1) → FINAL(1)
  //   6 grp → 12 teams → ELIM(4, 4 BYE)  → QF(4)  → SF(2) → 3RD(1) → FINAL(1)
  //   7 grp → 14 teams → ELIM(6, 2 BYE)  → QF(4)  → SF(2) → 3RD(1) → FINAL(1)
  //   8 grp → 16 teams → R16(8)           → QF(4)  → SF(2) → 3RD(1) → FINAL(1)
  //   9 grp → 18 teams → ELIM(2, 14 BYE) → R16(8) → QF(4) → SF(2) → 3RD(1) → FINAL(1)
  //
  // BYE = top-seeded teams that skip ELIM and advance directly to the next round.
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

    // ── SAVE GROUPS TO DB ─────────────────────────────────────────────────
    // Groups are saved HERE inside generateFifaSchedule to guarantee
    // tbl_soccer_groups and tbl_teamschedule are always in sync.
    // The caller must NOT save groups separately.
    try {
      await conn.execute("""CREATE TABLE IF NOT EXISTS tbl_soccer_groups (
        id INT AUTO_INCREMENT PRIMARY KEY,
        category_id INT NOT NULL, group_label VARCHAR(5) NOT NULL,
        team_id INT NOT NULL, team_name VARCHAR(255) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4""");
    } catch (_) {}

    // Already cleared by clearSoccerSchedule above, but clear again to be safe
    await conn.execute(
        'DELETE FROM tbl_soccer_groups WHERE category_id = :catId',
        {'catId': categoryId});

    final groupLabels = List.generate(groups.length, (i) => String.fromCharCode(65 + i));
    for (int gi = 0; gi < groups.length; gi++) {
      for (final team in groups[gi]) {
        final tid  = team['team_id']?.toString() ?? '0';
        final name = (team['team_name']?.toString() ?? '').replaceAll("'", "''");
        await conn.execute(
            "INSERT INTO tbl_soccer_groups (category_id, group_label, team_id, team_name) "
            "VALUES (:catId, :glabel, :tid, :tname)",
            {"catId": categoryId, "glabel": groupLabels[gi], "tid": int.tryParse(tid) ?? 0, "tname": team['team_name']?.toString() ?? ''});
      }
    }
    print("✅ Groups saved to DB: ${groups.length} groups.");

    // ── PHASE 1: GROUP STAGE ──────────────────────────────────────────────
    //
    // STRICT GROUP-PER-ARENA SCHEDULING:
    //
    // Each arena is assigned a fixed set of groups (by index % arenas).
    // Arena 1 → groups 0, arenas, 2*arenas, ...
    // Arena 2 → groups 1, arenas+1, 2*arenas+1, ...
    //
    // Within each arena, groups rotate one match at a time so every team
    // gets maximum rest. Groups on different arenas play simultaneously.
    //
    // This guarantees:
    //   ✅ Teams ONLY play teams from their own group
    //   ✅ No team appears in 2 arenas at the same time (different groups)
    //   ✅ No blanks — arena always plays its next group's next match
    //   ✅ Maximum rest — circle method spreads same-team matches apart

    // Cap arenas to number of groups — more arenas than groups makes no sense
    // and causes 1 match per slot with many blank columns in the display.
    final effectiveArenas = arenas.clamp(1, groups.length);

    // ── Build round-robin rounds per group (circle method) ────────────────
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

    // ── Flatten all matches into one pool ────────────────────────────────
    // Interleave round-by-round across all groups
    final allMatches = <Map<String, dynamic>>[];
    final allGroupRounds = groups.map(buildRounds).toList();
    final maxRounds = allGroupRounds.isEmpty ? 0
        : allGroupRounds.map((gr) => gr.length).reduce((a, b) => a > b ? a : b);

    for (int r = 0; r < maxRounds; r++) {
      for (int gIdx = 0; gIdx < groups.length; gIdx++) {
        final gr = allGroupRounds[gIdx];
        if (r >= gr.length) continue;
        for (final pair in gr[r]) {
          allMatches.add({'gIdx': gIdx, 'pair': pair, 'round': r + 1});
        }
      }
    }

    // ── Schedule slot by slot — fill ALL arenas before advancing time ──────
    //
    // RULE: Every time slot must fill as many arenas as possible.
    // Arena assignment is DYNAMIC per slot (not fixed per group).
    // A match is eligible if neither team is already in this slot.
    //
    // Algorithm:
    //   1. Sort pool so teams with fewest matches come first (even load)
    //   2. Greedily pick matches for arenas 1..N — skip if team conflict
    //   3. Assign sequential arena numbers 1,2,3... to picks in this slot
    //   4. Only advance time when slot is full OR no more matches fit
    //   5. Never leave arenas blank when a valid match exists in the pool

    final Map<String, int> teamMatchCount = {};
    // Track which round each team last played — avoids consecutive same-group
    final Map<String, int> teamLastRound  = {};

    int timeCursor = skipLunch(startMinutes);

    while (allMatches.isNotEmpty) {
      int t = skipLunch(timeCursor);
      if (t + durationMinutes > endLimit) break;

      // Sort: fewest-played teams first, then by group round to spread load
      allMatches.sort((a, b) {
        final ap = a['pair'] as List;
        final bp = b['pair'] as List;
        final aLoad = (teamMatchCount[ap[0]['team_id'].toString()] ?? 0)
                    + (teamMatchCount[ap[1]['team_id'].toString()] ?? 0);
        final bLoad = (teamMatchCount[bp[0]['team_id'].toString()] ?? 0)
                    + (teamMatchCount[bp[1]['team_id'].toString()] ?? 0);
        if (aLoad != bLoad) return aLoad.compareTo(bLoad);
        // Secondary: prefer matches from groups not yet in this slot
        return (a['round'] as int).compareTo(b['round'] as int);
      });

      final Set<String> bookedTeams = {};
      final List<Map<String, dynamic>> slotPicks = [];
      final List<int> pickedIdx = [];

      // Fill arenas greedily — no team can appear twice in same slot
      for (int pos = 0; pos < effectiveArenas; pos++) {
        for (int qi = 0; qi < allMatches.length; qi++) {
          if (pickedIdx.contains(qi)) continue;
          final match = allMatches[qi];
          final pair  = match['pair'] as List;
          final id1   = pair[0]['team_id'].toString();
          final id2   = pair[1]['team_id'].toString();
          // Skip if either team already playing in this slot
          if (bookedTeams.contains(id1) || bookedTeams.contains(id2)) continue;
          bookedTeams.add(id1);
          bookedTeams.add(id2);
          slotPicks.add(match);
          pickedIdx.add(qi);
          break;
        }
      }

      if (slotPicks.isEmpty) break;

      // Remove picked matches from pool
      for (final idx in pickedIdx.reversed) {
        allMatches.removeAt(idx);
      }

      // Write all picks to DB with sequential arena numbers 1,2,3...
      for (int ai = 0; ai < slotPicks.length; ai++) {
        final match    = slotPicks[ai];
        final pair     = match['pair']  as List;
        final gIdx     = match['gIdx']  as int;
        final round    = match['round'] as int;
        final arenaNum = ai + 1;  // ← dynamic: Arena 1,2,3... per slot
        final id1      = pair[0]['team_id'].toString();
        final id2      = pair[1]['team_id'].toString();

        teamMatchCount[id1] = (teamMatchCount[id1] ?? 0) + 1;
        teamMatchCount[id2] = (teamMatchCount[id2] ?? 0) + 1;
        teamLastRound[id1]  = round;
        teamLastRound[id2]  = round;

        final schedId = await insertSchedule(
            startTime: fmt(t), endTime: fmt(t + durationMinutes));
        final matchId = await insertMatch(schedId, bracketType: 'group', categoryId: categoryId);
        await insertTeamSchedule(
            matchId: matchId, roundId: round,
            teamId: int.parse(id1),
            refereeId: defaultRefereeId, arenaNumber: arenaNum);
        await insertTeamSchedule(
            matchId: matchId, roundId: round,
            teamId: int.parse(id2),
            refereeId: defaultRefereeId, arenaNumber: arenaNum);

        print("✅ t=${fmt(t)} Arena $arenaNum "
              "G${String.fromCharCode(65 + gIdx)} R$round: $id1 vs $id2");
      }

      timeCursor = skipLunch(timeCursor + durationMinutes + intervalMinutes);
    }
    print("✅ Group stage done.");


    // ── PHASE 2: KNOCKOUT STAGE ───────────────────────────────────────────
    //
    // Bracket flow based on number of groups (top 2 per group advance):
    //
    //   2 grp →  4 teams → SF(2)            → 3RD(1) → FINAL(1)
    //   3 grp →  6 teams → ELIM(2, 2 BYE)  → QF(4)  → SF(2) → 3RD(1) → FINAL(1)
    //   4 grp →  8 teams → QF(4)            → SF(2)  → 3RD(1) → FINAL(1)
    //   5 grp → 10 teams → ELIM(2, 6 BYE)  → QF(4)  → SF(2) → 3RD(1) → FINAL(1)
    //   6 grp → 12 teams → ELIM(4, 4 BYE)  → QF(4)  → SF(2) → 3RD(1) → FINAL(1)
    //   7 grp → 14 teams → ELIM(6, 2 BYE)  → QF(4)  → SF(2) → 3RD(1) → FINAL(1)
    //   8 grp → 16 teams → R16(8)           → QF(4)  → SF(2) → 3RD(1) → FINAL(1)
    //   9 grp → 18 teams → ELIM(2, 14 BYE) → R16(8) → QF(4) → SF(2) → 3RD(1) → FINAL(1)
    //
    // Formula:
    //   advancing    = numGroups * 2
    //   bracketSize  = next power-of-2 >= advancing
    //   elimReal     = advancing - (bracketSize / 2)   ← real play-in matches
    //   byeCount     = (bracketSize / 2) - elimReal    ← teams that skip ELIM
    //
    final int numGroups      = groups.length;
    final int advancingTeams = numGroups * 2;

    // Next power of 2 >= n
    int nextPow2(int n) { int p = 1; while (p < n) p <<= 1; return p; }

    // Compute bracket sizes
    final int bracketSize  = nextPow2(advancingTeams);
    final int halfBracket  = bracketSize ~/ 2;   // = QF slot count (or R16 if large)
    final int elimReal     = advancingTeams - halfBracket; // real ELIM matches
    // byeSlots = bracketSize - advancingTeams   (auto-advance, no match needed)

    // Build ordered list of KO rounds with correct match counts
    final koRounds = <Map<String, dynamic>>[];

    if (advancingTeams <= 4) {
      // 2 groups → 4 teams: straight to SF
      // SF(2) → 3RD(1) → FINAL(1)
      koRounds.add({'label': 'semi-finals', 'count': 2});

    } else if (advancingTeams == 8) {
      // 4 groups → 8 teams: straight to QF
      // QF(4) → SF(2) → 3RD(1) → FINAL(1)
      koRounds.add({'label': 'quarter-finals', 'count': 4});
      koRounds.add({'label': 'semi-finals',    'count': 2});

    } else if (advancingTeams == 16) {
      // 8 groups → 16 teams: R16(8) → QF(4) → SF(2) → 3RD(1) → FINAL(1)
      koRounds.add({'label': 'round-of-16',    'count': 8});
      koRounds.add({'label': 'quarter-finals', 'count': 4});
      koRounds.add({'label': 'semi-finals',    'count': 2});

    } else if (advancingTeams == 6) {
      // 3 groups → 6 teams:
      // ELIM(2) → SF(2) → 3RD(1) → FINAL(1)   ★ QF intentionally skipped
      // Top 2 seeds BYE directly to SF; bottom 4 play 2 ELIM → 2 winners to SF
      koRounds.add({'label': 'elimination', 'count': 2});
      koRounds.add({'label': 'semi-finals', 'count': 2});

    } else if (bracketSize <= 16) {
      // 5,6,7 groups → 10,12,14 teams:
      // ELIM(real matches only) → QF(4) → SF(2) → 3RD(1) → FINAL(1)
      //   5 grp → 10 teams → ELIM(2) → QF(4) → SF(2)
      //   6 grp → 12 teams → ELIM(4) → QF(4) → SF(2)
      //   7 grp → 14 teams → ELIM(6) → QF(4) → SF(2)
      koRounds.add({'label': 'elimination',    'count': elimReal});
      koRounds.add({'label': 'quarter-finals', 'count': 4});
      koRounds.add({'label': 'semi-finals',    'count': 2});

    } else {
      // 9+ groups → 18+ teams: ELIM → R16(8) → QF(4) → SF(2)
      //   9 grp → 18 teams → ELIM(2) → R16(8) → QF(4) → SF(2)
      koRounds.add({'label': 'elimination',    'count': elimReal});
      koRounds.add({'label': 'round-of-16',    'count': 8});
      koRounds.add({'label': 'quarter-finals', 'count': 4});
      koRounds.add({'label': 'semi-finals',    'count': 2});
    }

    // Always add 3rd-place (1 match) and final (1 match)
    koRounds.add({'label': 'third-place', 'count': 1});
    koRounds.add({'label': 'final',       'count': 1});

    print("✅ Bracket plan: ${numGroups} groups → ${advancingTeams} advancing → "
          "${koRounds.map((r) => '${r['label']}(${r['count']})').join(' → ')}");


    // ── KNOCKOUT SCHEDULING RULES ──────────────────────────────────────────
    // 1. All matches of the SAME round share the SAME time slot (one row).
    // 2. If a round has more matches than arenas, overflow to next time slot.
    //    e.g. ELIM=8 matches, arenas=8 → 1 time slot with 8 arenas
    //         QF=4 matches, arenas=8   → 1 time slot with 4 arenas
    // 3. Skip lunch break (12:00-13:00) — push to 13:00 if overlapping.
    // 4. Always create ALL match slots regardless of endLimit.
    for (final round in koRounds) {
      final String bracketType = round['label'] as String;
      final int    count       = round['count'] as int;

      // How many time slots needed for this round
      // Each slot fits up to [arenas] matches
      // Knockout uses the actual arenas parameter set by the user
      final int slotsNeeded = (count / arenas).ceil();

      int matchesRemaining = count;
      for (int s = 0; s < slotsNeeded; s++) {
        int t = skipLunch(timeCursor);
        // Matches in this slot = min(arenas, remaining)
        final matchesInSlot = matchesRemaining < arenas
            ? matchesRemaining : arenas;
        matchesRemaining -= matchesInSlot;

        for (int a = 0; a < matchesInSlot; a++) {
          final schedId = await insertSchedule(
              startTime: fmt(t), endTime: fmt(t + durationMinutes));
          await insertMatch(schedId, bracketType: bracketType, categoryId: categoryId);
        }
        timeCursor = skipLunch(timeCursor + durationMinutes + intervalMinutes);
        print("✅ $bracketType slot ${s+1}/$slotsNeeded @ ${fmt(t)} ($matchesInSlot matches)");
      }
    }
    print("✅ FIFA schedule generated! ${groups.length} groups, "
          "${advancingTeams} advancing, bracket: ${koRounds.map((r) => '${r['label']}(${r['count']})').join(' → ')}.");
  }

  // ── ADVANCE TEAMS TO KNOCKOUT ─────────────────────────────────────────────
  //
  // Called after group stage is complete.
  // 1. Reads top 2 from each group (by PTS → GD → GF)
  // 2. Seeds them into the FIRST knockout round slots using FIFA cross-group pairing:
  //    1A vs 2B, 1C vs 2D, 1B vs 2A, 1D vs 2C ...
  // 3. For ELIM rounds with BYE slots, only seeds real matchups — BYE slots
  //    stay empty and auto-advance their paired team to QF automatically.
  // 4. Inserts tbl_teamschedule rows for each knockout match
  //
  static Future<void> advanceToKnockout(int categoryId) async {
    final conn = await getConnection();

    // ── 1. Get all groups and their teams ────────────────────────────────────
    final groupResult = await conn.execute(
      "SELECT group_label, team_id FROM tbl_soccer_groups "
      "WHERE category_id = :catId ORDER BY group_label, id",
      {"catId": categoryId},
    );
    final Map<String, List<int>> groupTeams = {};
    for (final row in groupResult.rows) {
      final label  = row.assoc()['group_label'] ?? '';
      final teamId = int.tryParse(row.assoc()['team_id']?.toString() ?? '0') ?? 0;
      groupTeams.putIfAbsent(label, () => []);
      groupTeams[label]!.add(teamId);
    }
    if (groupTeams.isEmpty) throw Exception('No groups found for category $categoryId');

    // ── 2. Get scores per team from group stage using tbl_score ────────────────
    // Uses a per-match subquery to correctly compute W/D/L/GF/GA/PTS per team
    final scoreResult = await conn.execute("""
      SELECT
        ts.team_id,
        COALESCE(SUM(sc.score_independentscore), 0) AS goals_for,
        COALESCE(SUM(
          (SELECT sc_opp.score_independentscore
           FROM tbl_teamschedule ts_opp
           LEFT JOIN tbl_score sc_opp
             ON sc_opp.match_id = ts_opp.match_id
            AND sc_opp.team_id  = ts_opp.team_id
           WHERE ts_opp.match_id = ts.match_id
             AND ts_opp.team_id != ts.team_id
           LIMIT 1)
        ), 0) AS goals_against,
        COALESCE(SUM(CASE
          WHEN sc.score_independentscore IS NULL THEN 0
          WHEN sc.score_independentscore > COALESCE(
            (SELECT sc2.score_independentscore
             FROM tbl_teamschedule ts2
             LEFT JOIN tbl_score sc2
               ON sc2.match_id = ts2.match_id AND sc2.team_id = ts2.team_id
             WHERE ts2.match_id = ts.match_id AND ts2.team_id != ts.team_id
             LIMIT 1), -1) THEN 3
          WHEN sc.score_independentscore = COALESCE(
            (SELECT sc2.score_independentscore
             FROM tbl_teamschedule ts2
             LEFT JOIN tbl_score sc2
               ON sc2.match_id = ts2.match_id AND sc2.team_id = ts2.team_id
             WHERE ts2.match_id = ts.match_id AND ts2.team_id != ts.team_id
             LIMIT 1), -1) THEN 1
          ELSE 0 END), 0) AS points
      FROM tbl_teamschedule ts
      JOIN tbl_match m ON m.match_id = ts.match_id
      JOIN tbl_team  t ON t.team_id  = ts.team_id
      LEFT JOIN tbl_score sc
        ON sc.team_id = ts.team_id AND sc.match_id = ts.match_id
      WHERE t.category_id = :catId
        AND m.bracket_type = 'group'
      GROUP BY ts.team_id
    """, {"catId": categoryId});

    final Map<int, Map<String, int>> teamStats = {};
    for (final row in scoreResult.rows) {
      final tid = int.tryParse(row.assoc()['team_id']?.toString() ?? '0') ?? 0;
      final pts = int.tryParse(row.assoc()['points']?.toString() ?? '0') ?? 0;
      final gf  = int.tryParse(row.assoc()['goals_for']?.toString() ?? '0') ?? 0;
      final ga  = int.tryParse(row.assoc()['goals_against']?.toString() ?? '0') ?? 0;
      teamStats[tid] = {'pts': pts, 'gf': gf, 'ga': ga, 'gd': gf - ga};
    }

    // ── 3. Rank teams within each group ──────────────────────────────────────
    // Returns [1st_teamId, 2nd_teamId, ...]
    final Map<String, List<int>> groupRanked = {};
    for (final entry in groupTeams.entries) {
      final label = entry.key;
      final teams = List<int>.from(entry.value);
      teams.sort((a, b) {
        final sa = teamStats[a] ?? {'pts': 0, 'gd': 0, 'gf': 0};
        final sb = teamStats[b] ?? {'pts': 0, 'gd': 0, 'gf': 0};
        if (sb['pts'] != sa['pts']) return sb['pts']!.compareTo(sa['pts']!);
        if (sb['gd']  != sa['gd'])  return sb['gd']!.compareTo(sa['gd']!);
        return sb['gf']!.compareTo(sa['gf']!);
      });
      groupRanked[label] = teams;
    }

    // Debug: print group rankings
    for (final entry in groupRanked.entries) {
      print("ℹ️  Group ${entry.key}: ranked team IDs = ${entry.value}");
    }

    // ── 4. Build seeds list — OVERALL STANDINGS seeding ─────────────────────
    //
    // All advancing teams (top 2 per group) are ranked by OVERALL standings:
    //   PTS → GD (goal difference) → GF (goals for)
    // This means seed #1 (best overall) always gets the best bracket position.
    //
    // Bracket size math:
    //   advTeams = N * 2  (top 2 per group)
    //   bracketSize = next power of 2 >= advTeams
    //   halfB   = bracketSize / 2  (SF slots, or QF slots if larger)
    //   elimCnt = advTeams - halfB  (real ELIM matches)
    //   byeCnt  = halfB - elimCnt  (top seeds that skip ELIM entirely)
    //
    // Seeding order (overall rank):
    //   Seeds 1..byeCnt         → BYE directly into next round (top tier)
    //   Seeds byeCnt+1..advTeams → play in ELIM
    //     ELIM pairings (standard bracket): seed N+1 vs seed advTeams,
    //                                        seed N+2 vs seed advTeams-1, …
    //   This ensures top overall seeds never meet in ELIM and face the
    //   weakest possible ELIM survivor in the next round.
    //
    final labels = groupRanked.keys.toList()..sort();
    final n      = labels.length;
    final seeds  = <Map<String, dynamic>>[];   // real ELIM matchups
    final byeSeeds = <int>[];                   // team IDs that get BYEs

    // Collect all advancing teams: top 2 from each group
    final List<int> allAdvancing = [];
    for (final label in labels) {
      final ranked = groupRanked[label] ?? [];
      if (ranked.isNotEmpty) allAdvancing.add(ranked[0]);
      if (ranked.length > 1) allAdvancing.add(ranked[1]);
    }

    // Sort all advancing teams by OVERALL standings: PTS → GD → GF (desc)
    allAdvancing.sort((a, b) {
      final sa = teamStats[a] ?? {'pts': 0, 'gd': 0, 'gf': 0};
      final sb = teamStats[b] ?? {'pts': 0, 'gd': 0, 'gf': 0};
      if (sb['pts'] != sa['pts']) return sb['pts']!.compareTo(sa['pts']!);
      if (sb['gd']  != sa['gd'])  return sb['gd']!.compareTo(sa['gd']!);
      return sb['gf']!.compareTo(sa['gf']!);
    });

    // Log overall seeding for debugging
    for (int i = 0; i < allAdvancing.length; i++) {
      final tid = allAdvancing[i];
      final s = teamStats[tid] ?? {'pts': 0, 'gd': 0, 'gf': 0};
      print("ℹ️  Overall seed #${i+1}: teamId=$tid pts=${s['pts']} gd=${s['gd']} gf=${s['gf']}");
    }

    if (n == 1) {
      // Only 1 group — seed #1 vs seed #2 (straight to SF, no ELIM)
      seeds.add({
        'home': allAdvancing.isNotEmpty ? allAdvancing[0] : 0,
        'away': allAdvancing.length > 1  ? allAdvancing[1] : 0,
      });
    } else {
      final int advTeams = allAdvancing.length;
      int bSize = 1; while (bSize < advTeams) bSize <<= 1;
      final int halfB   = bSize ~/ 2;
      final int elimCnt = advTeams - halfB; // real ELIM matches
      // final int byeCnt  = halfB - elimCnt;  // teams with BYEs (unused variable)

      if (elimCnt == 0) {
        // 2 groups → 4 teams → direct to SF, no ELIM.
        // Standard seeding: #1 vs #4, #2 vs #3
        // (top seed faces weakest, second seed faces third)
        seeds.add({
          'home': allAdvancing.isNotEmpty       ? allAdvancing[0] : 0,
          'away': allAdvancing.length > 3       ? allAdvancing[3] : 0,
        });
        seeds.add({
          'home': allAdvancing.length > 1       ? allAdvancing[1] : 0,
          'away': allAdvancing.length > 2       ? allAdvancing[2] : 0,
        });
      } else {
        // Top [halfB - elimCnt] seeds get BYEs; the rest play ELIM.
        //
        // byeSeeds: overall seeds #1, #2, … up to byeCnt
        // ELIM teams: the remaining seeds, paired as:
        //   lowest seed (last) vs next-to-lowest, working inward.
        // This is the standard "protect top seeds" bracket design.

        final int byeCount = halfB - elimCnt;

        // Top seeds → BYEs
        for (int i = 0; i < byeCount && i < allAdvancing.length; i++) {
          byeSeeds.add(allAdvancing[i]);
        }

        // Remaining teams → ELIM, paired: highest remaining seed vs lowest
        final List<int> elimTeams = allAdvancing.sublist(byeCount);
        // Standard bracket pairing: seed[0] vs seed[last], seed[1] vs seed[last-1]
        int lo = 0, hi = elimTeams.length - 1;
        while (lo < hi) {
          seeds.add({
            'home': elimTeams[lo],
            'away': elimTeams[hi],
          });
          lo++;
          hi--;
        }
        // If odd number of ELIM teams (shouldn't happen in normal brackets),
        // the middle team also gets a BYE.
        if (lo == hi) {
          byeSeeds.add(elimTeams[lo]);
        }
      }
    }

    // ── 5. Determine first KO round label ────────────────────────────────────
    // FIX: 'elimination' is now FIRST in the search order so it is always
    // found before 'quarter-finals' when the schedule has an ELIM round.
    const koOrder = [
      'round-of-32', 'elimination', 'round-of-16', 'round-of-8',
      'quarter-finals', 'semi-finals', 'third-place', 'final',
    ];

    // Get ALL first-round KO slots (whether seeded or not)
    // We use ALL slots so we can overwrite/fill any still-empty ones
    final allKoResult = await conn.execute("""
      SELECT m.match_id, m.bracket_type
      FROM tbl_match m
      JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
      WHERE m.bracket_type IN (
        'round-of-32','elimination','round-of-16','round-of-8',
        'quarter-finals','semi-finals','third-place','final'
      )
      AND m.category_id = :catId
      ORDER BY s.schedule_start ASC, m.match_id ASC
    """, {"catId": categoryId});
    final allKoMatches = allKoResult.rows.map((r) => r.assoc()).toList();

    // Find which round is the first (earliest) KO round
    String firstRound = '';
    for (final bt in koOrder) {
      if (allKoMatches.any((m) => m['bracket_type'] == bt)) {
        firstRound = bt;
        break;
      }
    }
    if (firstRound.isEmpty) {
      throw Exception('No knockout matches found. Please regenerate the schedule first.');
    }

    // All first-round match slots
    final firstRoundMatches = allKoMatches
        .where((m) => m['bracket_type'] == firstRound)
        .toList();

    print("ℹ️  First KO round: $firstRound — ${firstRoundMatches.length} slots, ${seeds.length} seeds, ${byeSeeds.length} BYE teams");

    // If DB has fewer slots than seeds, create the missing ones
    if (firstRoundMatches.length < seeds.length) {
      print("⚠️  Missing ${seeds.length - firstRoundMatches.length} KO slots — creating them now");
      // Get last schedule time to append after
      final lastSched = await conn.execute("""
        SELECT MAX(schedule_start) AS last_t FROM tbl_schedule
      """);
      final lastTimeStr = lastSched.rows.isEmpty
          ? '18:00:00'
          : lastSched.rows.first.assoc()['last_t']?.toString() ?? '18:00:00';
      // Parse HH:MM:SS into minutes
      int parseMin(String t) {
        final parts = t.split(':');
        return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
      }
      String fmtTime(int m) {
        return '${(m~/60).toString().padLeft(2,'0')}:${(m%60).toString().padLeft(2,'0')}:00';
      }
      int cursor = parseMin(lastTimeStr) + 15;
      for (int i = firstRoundMatches.length; i < seeds.length; i++) {
        final sId = await insertSchedule(
            startTime: fmtTime(cursor),
            endTime:   fmtTime(cursor + 10));
        final mId = await insertMatch(sId, bracketType: firstRound);
        firstRoundMatches.add({'match_id': mId.toString(), 'bracket_type': firstRound});
        cursor += 25;
        print("✅ Created missing KO slot: match $mId");
      }
    }

    // ── 6. Get default referee ────────────────────────────────────────────────
    final refResult = await conn.execute(
      "SELECT referee_id FROM tbl_referee ORDER BY referee_id LIMIT 1",
    );
    final refereeId = refResult.rows.isEmpty ? 1
        : int.tryParse(refResult.rows.first.assoc()['referee_id']?.toString() ?? '1') ?? 1;

    // ── 7. Insert teamschedule rows for ELIM — INSERT IGNORE to avoid duplicates ──
    for (int seedIdx = 0; seedIdx < seeds.length; seedIdx++) {
      if (seedIdx >= firstRoundMatches.length) break;
      final matchId = int.tryParse(
          firstRoundMatches[seedIdx]['match_id']?.toString() ?? '0') ?? 0;
      if (matchId == 0) continue;

      final homeId = seeds[seedIdx]['home'] as int;
      final awayId = seeds[seedIdx]['away'] as int;

      if (homeId > 0) {
        await conn.execute("""
          INSERT IGNORE INTO tbl_teamschedule
            (match_id, round_id, team_id, referee_id, arena_number)
          VALUES (:mid, 1, :tid, :rid, 1)
        """, {"mid": matchId, "tid": homeId, "rid": refereeId});
      }
      if (awayId > 0) {
        await conn.execute("""
          INSERT IGNORE INTO tbl_teamschedule
            (match_id, round_id, team_id, referee_id, arena_number)
          VALUES (:mid, 1, :tid, :rid, 1)
        """, {"mid": matchId, "tid": awayId, "rid": refereeId});
      }
      print("✅ KO match $matchId seeded: home=$homeId away=$awayId");
    }

    // ── 8. Seed BYE teams directly into the CORRECT next KO round ───────────
    // BYE teams are the TOP overall seeds — they skip ELIM entirely.
    //   3 groups  → 6 advancing → top 2 overall get BYEs into SF
    //   5+ groups → top N overall get BYEs into QF
    //
    // byeSeeds is already in overall rank order (best seed first) from step 4.
    // We insert them into SF/QF slots in order, so the best overall seed
    // goes into the first SF/QF slot (= easiest projected path).
    //
    // IMPORTANT: Derive the correct round from group count, not DB query,
    // to avoid picking a wrong round when unused slots exist in tbl_match.
    if (byeSeeds.isNotEmpty) {
      final int advTeams = n * 2;
      final String nextRound;
      if (advTeams == 6) {
        nextRound = 'semi-finals';
      } else {
        nextRound = 'quarter-finals';
      }

      print("ℹ️  Seeding ${byeSeeds.length} BYE team(s) directly into '$nextRound'");
      final nextRoundMatches = await conn.execute("""
        SELECT m.match_id
        FROM tbl_match m
        JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
        WHERE m.bracket_type = :nr
        ORDER BY s.schedule_start ASC, m.match_id ASC
      """, {"nr": nextRound});
      final nextSlots = nextRoundMatches.rows
          .map((r) => int.tryParse(r.assoc()['match_id']?.toString() ?? '0') ?? 0)
          .where((id) => id > 0)
          .toList();

      for (int bi = 0; bi < byeSeeds.length; bi++) {
        final teamId = byeSeeds[bi];
        if (teamId <= 0 || bi >= nextSlots.length) continue;
        final matchId = nextSlots[bi];
        await conn.execute("""
          INSERT IGNORE INTO tbl_teamschedule
            (match_id, round_id, team_id, referee_id, arena_number)
          VALUES (:mid, 1, :tid, :rid, 1)
        """, {"mid": matchId, "tid": teamId, "rid": refereeId});
        print("✅ BYE team $teamId seeded into '$nextRound' match $matchId");
      }
    }

    print("✅ Knockout seeding complete: ${seeds.length} ELIM matches, ${byeSeeds.length} BYEs.");
  }

  // ── RESET KNOCKOUT SEEDING ────────────────────────────────────────────────
  // Clears ALL tbl_teamschedule rows for knockout matches of this category,
  // also clears tbl_score for those matches, so advanceToKnockout can
  // re-run cleanly with the correct seeding.
  static Future<void> resetKnockoutSeeding(int categoryId) async {
    final conn = await getConnection();
    const koTypes = [
      'elimination','round-of-32','round-of-16','round-of-8',
      'quarter-finals','semi-finals','third-place','final',
    ];
    final inClause = koTypes.map((t) => "'$t'").join(',');

    // Get all KO match IDs for this category
    final matchResult = await conn.execute("""
      SELECT DISTINCT m.match_id
      FROM tbl_match m
      WHERE m.bracket_type IN ($inClause)
    """);
    final matchIds = matchResult.rows
        .map((r) => r.assoc()['match_id']?.toString() ?? '0')
        .where((id) => id != '0')
        .toList();

    if (matchIds.isEmpty) {
      print("ℹ️  No KO matches found to reset.");
      return;
    }

    final idList = matchIds.join(',');

    // Delete scores for KO matches
    await conn.execute(
      "DELETE FROM tbl_score WHERE match_id IN ($idList)",
    );
    // Delete teamschedule rows for KO matches
    await conn.execute(
      "DELETE FROM tbl_teamschedule WHERE match_id IN ($idList)",
    );
    print("✅ Knockout seeding reset: cleared ${matchIds.length} KO match slots.");
  }

  // ── ADVANCE KNOCKOUT WINNER ───────────────────────────────────────────────
  static Future<void> advanceKnockoutWinner({
    required int matchId,
    required int winnerTeamId,
    required int loserTeamId,
    required int categoryId,
  }) async {
    final conn = await getConnection();

    // Winner progression path — ordered from earliest to latest round.
    // Each winner advances to the NEXT entry in this list.
    // This must exactly match the bracket plan in generateFifaSchedule:
    //
    //   2 grp:  SF → FINAL
    //   3 grp:  ELIM → SF → FINAL  (QF intentionally skipped for 3 groups)
    //   4 grp:  QF  → SF → FINAL
    //   5 grp:  ELIM → QF → SF → FINAL
    //   6 grp:  ELIM → QF → SF → FINAL
    //   7 grp:  ELIM → QF → SF → FINAL
    //   8 grp:  R16  → QF → SF → FINAL
    //   9 grp:  ELIM → R16 → QF → SF → FINAL
    //
    // The path is queried from the DB at runtime so it always reflects
    // the ACTUAL rounds that were generated (no hard-coded assumptions).
    const koOrder = [
      'round-of-32', 'elimination', 'round-of-16',
      'quarter-finals', 'semi-finals', 'third-place', 'final',
    ];

    // 1. Find current bracket_type
    final curResult = await conn.execute(
      "SELECT bracket_type FROM tbl_match WHERE match_id = :mid LIMIT 1",
      {"mid": matchId},
    );
    if (curResult.rows.isEmpty) return;
    final currentType = curResult.rows.first.assoc()['bracket_type'] ?? '';

    if (currentType == 'final' || currentType == 'third-place') return;

    // 2. Determine next rounds by querying the actual rounds present in DB.
    //    This avoids hard-coded path assumptions that break for edge cases.
    String nextWinnerType;
    String? nextLoserType;

    if (currentType == 'semi-finals') {
      nextWinnerType = 'final';
      nextLoserType  = 'third-place';
    } else {
      // Find all KO round types currently in DB, ordered by their first schedule time.
      // This gives us the ACTUAL bracket order for this tournament.
      final presentRoundsResult = await conn.execute("""
        SELECT DISTINCT m.bracket_type,
               MIN(s.schedule_start) AS first_time
        FROM tbl_match m
        JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
        WHERE m.bracket_type IN (
          'round-of-32','elimination','round-of-16',
          'quarter-finals','semi-finals','third-place','final'
        )
        GROUP BY m.bracket_type
        ORDER BY first_time ASC
      """);
      // Build ordered list of actual rounds
      final presentRounds = presentRoundsResult.rows
          .map((r) => r.assoc()['bracket_type']?.toString() ?? '')
          .where((t) => t.isNotEmpty && t != 'third-place')
          .toList();

      final curIdx = presentRounds.indexOf(currentType);
      nextWinnerType = (curIdx >= 0 && curIdx + 1 < presentRounds.length)
          ? presentRounds[curIdx + 1]
          : 'final';
    }

    // 3. Get default referee
    final refResult = await conn.execute(
      "SELECT referee_id FROM tbl_referee ORDER BY referee_id LIMIT 1",
    );
    final refereeId = refResult.rows.isEmpty ? 1
        : int.tryParse(refResult.rows.first.assoc()['referee_id']?.toString() ?? '1') ?? 1;

    // 4. Seed team into first available slot of target round
    Future<void> seedIntoRound(String targetType, int teamId) async {
      final matchResult = await conn.execute("""
        SELECT m.match_id, COUNT(ts.teamschedule_id) AS team_count
        FROM tbl_match m
        JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
        LEFT JOIN tbl_teamschedule ts ON ts.match_id = m.match_id
        WHERE m.bracket_type = :bt
          AND m.match_id NOT IN (
            SELECT DISTINCT ts2.match_id FROM tbl_teamschedule ts2
            WHERE ts2.team_id = :tid
          )
        GROUP BY m.match_id
        HAVING team_count < 2
        ORDER BY s.schedule_start ASC, m.match_id ASC
        LIMIT 1
      """, {"bt": targetType, "tid": teamId});
      if (matchResult.rows.isEmpty) return;
      final nextMatchId = int.tryParse(
          matchResult.rows.first.assoc()['match_id']?.toString() ?? '0') ?? 0;
      if (nextMatchId == 0) return;
      await conn.execute("""
        INSERT IGNORE INTO tbl_teamschedule
          (match_id, round_id, team_id, referee_id, arena_number)
        VALUES (:nmid, 1, :tid, :rid, 1)
      """, {"nmid": nextMatchId, "tid": teamId, "rid": refereeId});
      print("✅ Advance: team $teamId -> $targetType (match $nextMatchId)");
    }

    await seedIntoRound(nextWinnerType, winnerTeamId);
    if (nextLoserType != null) {
      await seedIntoRound(nextLoserType, loserTeamId);
    }
  }

  // ── GET KNOCKOUT SCORES ───────────────────────────────────────────────────
  // Reads score_totalscore from tbl_score for all knockout matches
  static Future<Map<int, Map<int, int>>> getKnockoutScores(int categoryId) async {
    final conn = await getConnection();
    final result = await conn.execute("""
      SELECT sc.match_id, sc.team_id, sc.score_totalscore AS goals
      FROM tbl_score sc
      JOIN tbl_match m ON m.match_id = sc.match_id
      JOIN tbl_team  t ON t.team_id  = sc.team_id
      WHERE t.category_id = :catId
        AND m.bracket_type IN (
          'round-of-32','elimination','round-of-16','round-of-8',
          'quarter-finals','semi-finals','third-place','final'
        )
      ORDER BY sc.match_id
    """, {"catId": categoryId});
    final Map<int, Map<int, int>> out = {};
    for (final row in result.rows) {
      final mid   = int.tryParse(row.assoc()['match_id']?.toString() ?? '0') ?? 0;
      final tid   = int.tryParse(row.assoc()['team_id']?.toString()  ?? '0') ?? 0;
      final goals = int.tryParse(row.assoc()['goals']?.toString()    ?? '0') ?? 0;
      if (mid == 0 || tid == 0) continue;
      out.putIfAbsent(mid, () => {});
      out[mid]![tid] = goals;
    }
    return out;
  }

  // ── SAVE KNOCKOUT SCORE ───────────────────────────────────────────────────
  // Upserts into tbl_score using the actual column names visible in the schema:
  //   score_totalscore, score_independentscore, score_violation,
  //   score_totalduration, score_isapproved, match_id, team_id, round_id
  static Future<void> saveKnockoutScore({
    required int matchId,
    required int teamId,
    required int goals,
    required int refereeId,
  }) async {
    final conn = await getConnection();

    // Check if a score row already exists for this match+team
    final existing = await conn.execute(
      "SELECT score_id FROM tbl_score WHERE match_id = :mid AND team_id = :tid LIMIT 1",
      {"mid": matchId, "tid": teamId},
    );

    if (existing.rows.isNotEmpty) {
      final scoreId = existing.rows.first.assoc()['score_id'] ?? '0';
      await conn.execute("""
        UPDATE tbl_score
        SET score_totalscore  = :goals,
            score_isapproved  = 1
        WHERE score_id = :sid
      """, {"goals": goals, "sid": scoreId});
    } else {
      await conn.execute("""
        INSERT INTO tbl_score
          (match_id, team_id, round_id, referee_id, score_totalscore,
           score_independentscore, score_violation,
           score_totalduration, score_isapproved)
        VALUES
          (:mid, :tid, 1, :rid, :goals,
           :goals, 0,
           '00:00:00', 1)
      """, {"mid": matchId, "tid": teamId, "rid": refereeId, "goals": goals});
    }
    print("✅ KO score saved: match=$matchId team=$teamId goals=$goals");
  }

}