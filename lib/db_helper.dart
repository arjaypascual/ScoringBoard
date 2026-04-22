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

    // Migration 12: tbl_soccer_tiebreaker — stores tiebreaker matches when
    // two or more teams finish group stage with equal points/GD/GF at rank 2 or 3.
    try {
      await conn.execute('''
        CREATE TABLE IF NOT EXISTS tbl_soccer_tiebreaker (
          tiebreaker_id  INT AUTO_INCREMENT PRIMARY KEY,
          category_id    INT NOT NULL,
          group_label    VARCHAR(5) NOT NULL,
          team1_id       INT NOT NULL,
          team2_id       INT NOT NULL,
          team1_score    INT,
          team2_score    INT,
          winner_id      INT,
          created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          INDEX idx_cat_group (category_id, group_label)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
      ''');
      print('✅ Migration 12: tbl_soccer_tiebreaker created.');
    } catch (_) {
      print('ℹ️  Migration 12: tbl_soccer_tiebreaker already present.');
    }

    // Migration 13: scheduled_time + arena_number on tbl_soccer_tiebreaker
    // Tiebreaker matches are now shown in the Match Schedule tab with an assigned
    // time slot (right after the last group-stage match) and arena column.
    try {
      await conn.execute("""
        ALTER TABLE tbl_soccer_tiebreaker
        ADD COLUMN scheduled_time TIME NULL DEFAULT NULL
      """);
      print("✅ Migration 13a: scheduled_time column added to tbl_soccer_tiebreaker.");
    } catch (_) {
      print("ℹ️  Migration 13a: scheduled_time already present.");
    }
    try {
      await conn.execute("""
        ALTER TABLE tbl_soccer_tiebreaker
        ADD COLUMN arena_number INT NOT NULL DEFAULT 1
      """);
      print("✅ Migration 13b: arena_number column added to tbl_soccer_tiebreaker.");
    } catch (_) {
      print("ℹ️  Migration 13b: arena_number already present.");
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

    // Step 1: Get all soccer match IDs for THIS category only.
    // FIX: Added category_id filter so we only clear matches belonging
    // to this category — not other categories' knockout matches.
    final soccerMatchResult = await conn.execute("""
      SELECT match_id FROM tbl_match
      WHERE bracket_type IN (
        'group','round-of-32','elimination','round-of-16',
        'quarter-finals','semi-finals','third-place','final',
        'play-in','upper','lower','finals'
      )
      AND category_id = $categoryId
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

    // Step 6: Clear tiebreaker matches
    await clearTiebreakerMatches(categoryId);

    // Step 7: Reset AUTO_INCREMENT so new match_ids are sequential and
    // predictable. Without this, re-generated match_ids keep climbing and
    // ORDER BY match_id ASC no longer reflects insertion/arena order.
    try { await conn.execute("ALTER TABLE tbl_match AUTO_INCREMENT = 1"); } catch (_) {}
    try { await conn.execute("ALTER TABLE tbl_schedule AUTO_INCREMENT = 1"); } catch (_) {}
    try { await conn.execute("ALTER TABLE tbl_teamschedule AUTO_INCREMENT = 1"); } catch (_) {}
    try { await conn.execute("ALTER TABLE tbl_score AUTO_INCREMENT = 1"); } catch (_) {}

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

    // ── 0. Clear any stale KO seeding so INSERT IGNORE never produces duplicates ──
    // advanceToKnockout is idempotent: calling it again always re-seeds from scratch.
    // Deletes tbl_teamschedule + tbl_score rows for all KO matches of this category.
    const koTypesToClear = [
      'elimination','round-of-32','round-of-16','round-of-8',
      'quarter-finals','semi-finals','third-place','final',
    ];
    try {
      final inClause0 = koTypesToClear.map((t) => "'$t'").join(',');
      final staleResult = await conn.execute("""
        SELECT DISTINCT m.match_id FROM tbl_match m
        WHERE m.bracket_type IN ($inClause0) AND m.category_id = $categoryId
      """);
      final staleIds = staleResult.rows
          .map((r) => r.assoc()['match_id']?.toString() ?? '0')
          .where((id) => id != '0')
          .toList();
      if (staleIds.isNotEmpty) {
        final idList0 = staleIds.join(',');
        await conn.execute("DELETE FROM tbl_score        WHERE match_id IN ($idList0)");
        await conn.execute("DELETE FROM tbl_teamschedule WHERE match_id IN ($idList0)");
        print("ℹ️  advanceToKnockout: cleared stale seeding for ${staleIds.length} KO matches.");
      }
    } catch (e) {
      print("⚠️  advanceToKnockout: could not clear stale seeding — $e");
    }

    // ── 1. Get all groups and their teams ────────────────────────────────────
    // SOURCE: tbl_soccer_groups — guaranteed to have ALL teams in all groups,
    // even those with no scores yet. This prevents teams from being silently
    // dropped from allAdvancing when their tbl_teamschedule rows are missing.
    final groupResult = await conn.execute(
      "SELECT group_label, team_id FROM tbl_soccer_groups "
      "WHERE category_id = :catId ORDER BY group_label, id",
      {"catId": categoryId},
    );
    final Map<String, List<int>> groupTeams = {};
    for (final row in groupResult.rows) {
      final label  = row.assoc()['group_label'] ?? '';
      final teamId = int.tryParse(row.assoc()['team_id']?.toString() ?? '0') ?? 0;
      if (label.isEmpty || teamId == 0) continue;
      groupTeams.putIfAbsent(label, () => []);
      if (!groupTeams[label]!.contains(teamId)) groupTeams[label]!.add(teamId);
    }
    if (groupTeams.isEmpty) throw Exception('No groups found for category $categoryId');

    // ── PRE-CHECK: Ensure all group matches have scores for both teams ───────
    // If any match is missing scores, advanceToKnockout will produce incorrect
    // rankings, leading to TBD slots in the elimination bracket.
    final unscoredCheck = await conn.execute("""
      SELECT COUNT(*) AS unscored
      FROM tbl_match m
      JOIN tbl_teamschedule ts ON ts.match_id = m.match_id
      JOIN tbl_team t ON t.team_id = ts.team_id
      WHERE m.bracket_type = 'group'
        AND m.category_id  = :catId
        AND NOT EXISTS (
          SELECT 1 FROM tbl_score sc
          WHERE sc.match_id = m.match_id AND sc.team_id = ts.team_id
        )
    """, {"catId": categoryId});
    final unscoredCount = int.tryParse(
        unscoredCheck.rows.first.assoc()['unscored']?.toString() ?? '0') ?? 0;
    if (unscoredCount > 0) {
      print("⚠️  advanceToKnockout: $unscoredCount team-slots in group stage have no score yet. Proceeding with 0-stat fallback for unscored teams.");
    }
    print("ℹ️  Groups loaded: ${groupTeams.map((k,v) => MapEntry(k, v.length))}");

    // ── 2. Get scores per team from group stage using tbl_score ────────────────
    // Uses a per-match subquery to correctly compute W/D/L/GF/GA/PTS per team
    // FIX: Use tbl_soccer_groups as the base so ALL teams appear in stats,
    // even those with no tbl_teamschedule entries (unscored/missing matches).
    // Teams missing from tbl_teamschedule get 0 pts/gf/ga by default.
    final allGroupTeamIds = groupTeams.values.expand((v) => v).toSet().toList();
    final teamIdsIn = allGroupTeamIds.join(',');

    final scoreResult = teamIdsIn.isEmpty ? null : await conn.execute("""
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
        AND ts.team_id IN ($teamIdsIn)
      GROUP BY ts.team_id
    """, {"catId": categoryId});

    // Pre-seed ALL group teams with 0-stats so no team is ever missing.
    // Teams that have no tbl_teamschedule rows (e.g. schedule not generated yet,
    // or absent teams) will still appear in allAdvancing with 0 pts — they will
    // rank last within their group, which is the correct fallback behaviour.
    final Map<int, Map<String, int>> teamStats = {};
    for (final tid in allGroupTeamIds) {
      teamStats[tid] = {'pts': 0, 'gf': 0, 'ga': 0, 'gd': 0};
    }
    // Overwrite with real stats from tbl_score where available
    if (scoreResult != null) {
      for (final row in scoreResult.rows) {
        final tid = int.tryParse(row.assoc()['team_id']?.toString() ?? '0') ?? 0;
        final pts = int.tryParse(row.assoc()['points']?.toString() ?? '0') ?? 0;
        final gf  = int.tryParse(row.assoc()['goals_for']?.toString() ?? '0') ?? 0;
        final ga  = int.tryParse(row.assoc()['goals_against']?.toString() ?? '0') ?? 0;
        if (tid > 0) teamStats[tid] = {'pts': pts, 'gf': gf, 'ga': ga, 'gd': gf - ga};
      }
    }
    print("ℹ️  teamStats loaded for ${teamStats.length} teams (expected ${allGroupTeamIds.length})");

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
    //     ELIM pairings (standard bracket): Seed 3 vs Seed 6, Seed 4 vs Seed 5
    //     Same-group conflict resolution: if two paired teams share a group,
    //     swap the lower seeds between the two matchups to avoid the clash.
    //   This ensures top overall seeds never meet in ELIM and face the
    //   weakest possible ELIM survivor in the next round.
    //
    final labels = groupRanked.keys.toList()..sort();
    final n      = labels.length;
    final seeds  = <Map<String, dynamic>>[];           // real ELIM matchups
    final byeSeeds = <int>[];                           // team IDs that get BYEs (outer QF)
    List<List<int>> _directQFPairs = [];                // teams seeded directly into inner QF slots

    // Build a lookup: teamId → group label (for same-group conflict detection)
    final Map<int, String> teamGroup = {};
    for (final entry in groupTeams.entries) {
      for (final tid in entry.value) {
        teamGroup[tid] = entry.key;
      }
    }

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
      print("ℹ️  Overall seed #${i+1}: teamId=$tid group=${teamGroup[tid]} pts=${s['pts']} gd=${s['gd']} gf=${s['gf']}");
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
      } else if (advTeams == 6) {
        // ── SPECIAL CASE: 3 groups → 6 teams → ELIM(2) → SF(2) ─────────────
        // generateFifaSchedule creates: ELIM(2 matches), SF(2 matches)
        // NO QF round exists for 3 groups — top 2 seeds BYE directly to SF.
        //
        // Seeding:
        //   ELIM match 0: Seed 3 vs Seed 6  (lowest seeds fight)
        //   ELIM match 1: Seed 4 vs Seed 5
        //   BYE: Seed 1 → SF slot 0, Seed 2 → SF slot 1
        //
        // BYE seeds go directly to SF (not QF which doesn't exist)
        for (int i = 0; i < 2 && i < allAdvancing.length; i++) {
          byeSeeds.add(allAdvancing[i]); // Seed 1 and Seed 2
        }

        // ELIM pairs: seeds 3,4,5,6 → [3v6], [4v5]
        final List<int> elimTeams6 = allAdvancing.length >= 6
            ? allAdvancing.sublist(2) // seeds 3,4,5,6
            : allAdvancing.length > 2 ? allAdvancing.sublist(2) : [];
        {
          int lo = 0, hi = elimTeams6.length - 1;
          while (lo < hi) {
            seeds.add({'home': elimTeams6[lo], 'away': elimTeams6[hi]});
            lo++; hi--;
          }
          // Same-group conflict resolution for 3-group ELIM pairs
          bool conflictResolved = false;
          for (int attempt = 0; attempt < seeds.length * 2 && !conflictResolved; attempt++) {
            bool anyConflict = false;
            for (int pi = 0; pi < seeds.length; pi++) {
              final home = seeds[pi]['home'] as int;
              final away = seeds[pi]['away'] as int;
              if (teamGroup[home] != null &&
                  teamGroup[away] != null &&
                  teamGroup[home] == teamGroup[away]) {
                final nextPi = (pi + 1) % seeds.length;
                if (nextPi != pi) {
                  final swapAway = seeds[nextPi]['away'] as int;
                  if (teamGroup[home] != teamGroup[swapAway] &&
                      teamGroup[seeds[nextPi]['home'] as int] != teamGroup[away]) {
                    seeds[pi]['away']     = swapAway;
                    seeds[nextPi]['away'] = away;
                    print("ℹ️  3-grp ELIM conflict resolved: swapped between matches $pi and $nextPi");
                    anyConflict = true;
                    break;
                  }
                }
              }
            }
            if (!anyConflict) conflictResolved = true;
          }
        }
        // No direct QF pairs for 3-group — QF round doesn't exist
        _directQFPairs = [];
        print("ℹ️  3-group path: ${byeSeeds.length} BYEs → SF, ${seeds.length} ELIM matches (seeds 3-6)");
      } else if (n == 7) {
        // ── SPECIAL CASE: 7 groups → up to 14 teams → ELIM(6) → QF(4) → SF(2) ────
        // Uses n == 7 (group count) not advTeams == 14, so absent teams don't
        // accidentally fall through to the generic 5/6-group branch.
        //
        // Confirmed bracket design:
        //   QF 1: Seed 1 (BYE)  vs  Winner of ELIM 1
        //   QF 2: Winner ELIM 2 vs  Winner of ELIM 3
        //   QF 3: Winner ELIM 4 vs  Winner of ELIM 5
        //   QF 4: Seed 2 (BYE)  vs  Winner of ELIM 6
        //
        // Seed 1 → BYE → QF slot 0 (outer top)
        // Seed 2 → BYE → QF slot 3 (outer bottom)
        // Seeds 3–14 → 6 ELIM matches:
        //   ELIM 1: Seed 3  vs Seed 14  → feeds QF 1
        //   ELIM 2: Seed 4  vs Seed 11  → feeds QF 2 (top)
        //   ELIM 3: Seed 5  vs Seed 10  → feeds QF 2 (bottom)
        //   ELIM 4: Seed 6  vs Seed 9   → feeds QF 3 (top)
        //   ELIM 5: Seed 7  vs Seed 8   → feeds QF 3 (bottom)  (NOTE: only 12 available so Seed 13)
        //   ELIM 6: Seed 12 vs Seed 13  → feeds QF 4
        //
        // No direct QF inner pairs — all 4 QF slots wait for ELIM winners
        // (except Seed 1 and Seed 2 BYEs at outer slots).

        // BYE seeds: Seed 1 → QF slot 0, Seed 2 → QF slot 3
        if (allAdvancing.isNotEmpty) byeSeeds.add(allAdvancing[0]); // Seed 1
        if (allAdvancing.length > 1) byeSeeds.add(allAdvancing[1]); // Seed 2

        // ELIM teams: seeds 3..14 (indices 2..13)
        final List<int> elimTeams14 = allAdvancing.length > 2
            ? List<int>.from(allAdvancing.sublist(2))
            : <int>[];

        // ELIM pairings: bracket-style seeding
        //   Match 0: seed[0]  vs seed[et-1]  (3 vs 14) → QF 0  (single, with BYE Seed 1)
        //   Match 1: seed[1]  vs seed[8]     (4 vs 11) → QF 1  (merge top)
        //   Match 2: seed[2]  vs seed[7]     (5 vs 10) → QF 1  (merge bottom)
        //   Match 3: seed[3]  vs seed[6]     (6 vs  9) → QF 2  (merge top)
        //   Match 4: seed[4]  vs seed[5]     (7 vs  8) → QF 2  (merge bottom)
        //   Match 5: seed[9]  vs seed[10]    (12 vs 13)→ QF 3  (single, with BYE Seed 2)
        final List<List<int>> elimPairs14 = [];
        final int et = elimTeams14.length;
        if (et >= 2) {
          // E0: 3 vs 14 (or last available)
          elimPairs14.add([elimTeams14[0], elimTeams14[et - 1]]);
        }
        if (et >= 4) {
          // E1: 4 vs 11
          final opp1 = et > 8 ? 8 : et - 2;
          elimPairs14.add([elimTeams14[1], elimTeams14[opp1]]);
        }
        if (et >= 4) {
          // E2: 5 vs 10
          final opp2 = et > 7 ? 7 : et - 3;
          elimPairs14.add([elimTeams14[2], elimTeams14[opp2]]);
        }
        if (et >= 6) {
          // E3: 6 vs 9
          final opp3 = et > 6 ? 6 : et - 4;
          elimPairs14.add([elimTeams14[3], elimTeams14[opp3]]);
        }
        if (et >= 6) {
          // E4: 7 vs 8
          final idx4a = 4;
          final idx4b = (et > 5) ? 5 : et - 1;
          if (idx4a < et && idx4b < et && idx4a != idx4b) {
            elimPairs14.add([elimTeams14[idx4a], elimTeams14[idx4b]]);
          }
        }
        if (et >= 12) {
          // E5: 12 vs 13
          if (9 < et && 10 < et) {
            elimPairs14.add([elimTeams14[9], elimTeams14[10]]);
          }
        }

        // Same-group conflict resolution for ELIM pairs.
        // CRITICAL for 7-group: only swap the AWAY player within pairs that
        // share the SAME QF destination slot. Never swap across different QF
        // slots — that would mis-route a winner to the wrong QF match.
        //
        // QF slot groupings (from _elim7toQF = [0,1,1,2,2,3]):
        //   Slot 0: only pair index 0  (E0 alone → can't swap)
        //   Slot 1: pair indices 1,2   (E1 & E2 merge → can swap within)
        //   Slot 2: pair indices 3,4   (E3 & E4 merge → can swap within)
        //   Slot 3: only pair index 5  (E5 alone → can't swap)
        const List<List<int>> sameSlotGroups = [[1, 2], [3, 4]];
        for (int attempt = 0; attempt < 6; attempt++) {
          bool anyConflict = false;
          for (final grp in sameSlotGroups) {
            final pi = grp[0];
            final qi = grp[1];
            if (pi >= elimPairs14.length || qi >= elimPairs14.length) continue;
            // Check if either match in this QF-slot group has a same-group conflict
            for (final checkIdx in [pi, qi]) {
              final otherIdx = checkIdx == pi ? qi : pi;
              final home = elimPairs14[checkIdx][0];
              final away = elimPairs14[checkIdx][1];
              if (teamGroup[home] != null &&
                  teamGroup[away] != null &&
                  teamGroup[home] == teamGroup[away]) {
                // Try swapping away with the other match's away (same QF slot)
                final swapAway = elimPairs14[otherIdx][1];
                if (teamGroup[home] != teamGroup[swapAway] &&
                    teamGroup[elimPairs14[otherIdx][0]] != teamGroup[away]) {
                  elimPairs14[checkIdx][1] = swapAway;
                  elimPairs14[otherIdx][1] = away;
                  print("ℹ️  7-grp ELIM conflict resolved within QF slot: swapped [$checkIdx] ↔ [$otherIdx] away");
                  anyConflict = true;
                  break;
                }
              }
            }
            if (anyConflict) break;
          }
          if (!anyConflict) break;
        }

        for (final pair in elimPairs14) {
          seeds.add({'home': pair[0], 'away': pair[1]});
        }

        // No direct QF inner pairs — all QF slots are filled by ELIM winners + BYEs
        _directQFPairs = [];
        print("ℹ️  7-group path: Seed1+Seed2 BYE → QF outer slots. ${seeds.length} ELIM matches (seeds 3-14).");

      } else if (n == 9) {
        // ── SPECIAL CASE: 9 groups → 18 teams → ELIM(2) → R16(8) → QF(4) → SF(2) ──
        //
        // Bracket layout:
        //   R16 slot 0: Seed 3  vs Seed 14  (direct)
        //   R16 slot 1: Seed 5  vs Seed 12  (direct)
        //   R16 slot 2: Seed 7  vs Seed 10  (direct)
        //   R16 slot 3: Seed 1  (BYE) vs ELIM 0 winner  ← gitna top
        //   R16 slot 4: Seed 2  (BYE) vs ELIM 1 winner  ← gitna bottom
        //   R16 slot 5: Seed 9  vs Seed 8   (direct)
        //   R16 slot 6: Seed 11 vs Seed 6   (direct)
        //   R16 slot 7: Seed 13 vs Seed 4   (direct)
        //
        // ELIM 0: Seed 17 vs Seed 18  → R16 slot 3 (with Seed 1 BYE)
        // ELIM 1: Seed 15 vs Seed 16  → R16 slot 4 (with Seed 2 BYE)

        // BYE seeds: Seed 1 → R16 slot 3, Seed 2 → R16 slot 4
        if (allAdvancing.isNotEmpty) byeSeeds.add(allAdvancing[0]); // Seed 1
        if (allAdvancing.length > 1) byeSeeds.add(allAdvancing[1]); // Seed 2

        // ELIM pairings (bottom 4 seeds):
        //   ELIM 0: Seed 17 vs Seed 18 (indices 16, 17)
        //   ELIM 1: Seed 15 vs Seed 16 (indices 14, 15)
        final int ae = allAdvancing.length;
        if (ae >= 18) {
          seeds.add({'home': allAdvancing[16], 'away': allAdvancing[17]}); // ELIM 0
          seeds.add({'home': allAdvancing[14], 'away': allAdvancing[15]}); // ELIM 1
        } else if (ae >= 16) {
          seeds.add({'home': allAdvancing[ae - 2], 'away': allAdvancing[ae - 1]});
          if (ae >= 16) seeds.add({'home': allAdvancing[ae - 4], 'away': allAdvancing[ae - 3]});
        }

        // Same-group conflict resolution for ELIM pairs
        for (int attempt = 0; attempt < 4; attempt++) {
          bool anyConflict = false;
          for (int pi = 0; pi < seeds.length; pi++) {
            final home = seeds[pi]['home'] as int;
            final away = seeds[pi]['away'] as int;
            if (teamGroup[home] != null &&
                teamGroup[away] != null &&
                teamGroup[home] == teamGroup[away]) {
              final nextPi = (pi + 1) % seeds.length;
              if (nextPi != pi) {
                final swapAway = seeds[nextPi]['away'] as int;
                if (teamGroup[home] != teamGroup[swapAway] &&
                    teamGroup[seeds[nextPi]['home'] as int] != teamGroup[away]) {
                  seeds[pi]['away']     = swapAway;
                  seeds[nextPi]['away'] = away;
                  anyConflict = true;
                  break;
                }
              }
            }
          }
          if (!anyConflict) break;
        }

        // Direct R16 pairs (seeds 3–14, slots 0,1,2,5,6,7)
        // slot 0: Seed 3  vs Seed 14  (indices 2, 13)
        // slot 1: Seed 5  vs Seed 12  (indices 4, 11)
        // slot 2: Seed 7  vs Seed 10  (indices 6,  9)
        // slot 5: Seed 9  vs Seed 8   (indices 8,  7)
        // slot 6: Seed 11 vs Seed 6   (indices 10, 5)
        // slot 7: Seed 13 vs Seed 4   (indices 12, 3)
        final List<List<int>> direct9Pairs = [];
        final List<int> dIdx = [2, 4, 6, 8, 10, 12]; // home seed indices
        final List<int> oIdx = [13, 11, 9, 7, 5, 3];  // away seed indices
        for (int i = 0; i < dIdx.length; i++) {
          if (dIdx[i] < ae && oIdx[i] < ae) {
            direct9Pairs.add([allAdvancing[dIdx[i]], allAdvancing[oIdx[i]]]);
          }
        }
        _directQFPairs = direct9Pairs;

        print("ℹ️  9-group path: Seed1+Seed2 BYE → R16 slots 3&4. ${seeds.length} ELIM matches, ${direct9Pairs.length} direct R16 pairs.");

      } else {
        // ── GENERIC: 5, 6 groups (or other even counts) ──────────────────────
        //
        //   QF slot 0: Seed 1 (BYE) vs Winner of ELIM match 0
        //   QF slot 1: Seed 3 vs Seed 6   ← direct inner match
        //   QF slot 2: Seed 4 vs Seed 5   ← direct inner match
        //   QF slot 3: Seed 2 (BYE) vs Winner of ELIM match 1
        //
        // Top 2 seeds get BYEs. Middle seeds play direct QF inner slots.
        // Bottom seeds play in ELIM.

        // Always exactly 2 BYE seeds (Seed 1 and Seed 2)
        const int byeCount = 2;
        for (int i = 0; i < byeCount && i < allAdvancing.length; i++) {
          byeSeeds.add(allAdvancing[i]);
        }

        // ELIM teams = bottom (elimCnt * 2) seeds
        final int elimTeamCount = elimCnt * 2;
        final int directQFEnd   = advTeams - elimTeamCount;
        final List<int> directQFTeams = List<int>.from(
            allAdvancing.sublist(byeCount, directQFEnd.clamp(byeCount, allAdvancing.length)));
        final List<int> elimTeams = List<int>.from(
            allAdvancing.sublist(directQFEnd.clamp(0, allAdvancing.length)));

        // Direct QF pairings: highest vs lowest working inward
        List<List<int>> directPairs = [];
        {
          int lo = 0, hi = directQFTeams.length - 1;
          while (lo < hi) {
            directPairs.add([directQFTeams[lo], directQFTeams[hi]]);
            lo++; hi--;
          }
          // Same-group conflict resolution
          bool conflictResolved = false;
          for (int attempt = 0; attempt < directPairs.length * 2 && !conflictResolved; attempt++) {
            bool anyConflict = false;
            for (int pi = 0; pi < directPairs.length; pi++) {
              final home = directPairs[pi][0];
              final away = directPairs[pi][1];
              if (teamGroup[home] != null &&
                  teamGroup[away] != null &&
                  teamGroup[home] == teamGroup[away]) {
                final nextPi = (pi + 1) % directPairs.length;
                if (nextPi != pi) {
                  final swapAway = directPairs[nextPi][1];
                  if (teamGroup[home] != teamGroup[swapAway] &&
                      teamGroup[directPairs[nextPi][0]] != teamGroup[away]) {
                    directPairs[pi][1]     = swapAway;
                    directPairs[nextPi][1] = away;
                    print("ℹ️  Direct QF conflict resolved: swapped slots $pi and $nextPi");
                    anyConflict = true;
                    break;
                  }
                }
              }
            }
            if (!anyConflict) conflictResolved = true;
          }
        }

        // ELIM pairings: highest vs lowest working inward
        final List<List<int>> elimPairs = [];
        {
          int lo = 0, hi = elimTeams.length - 1;
          while (lo < hi) {
            elimPairs.add([elimTeams[lo], elimTeams[hi]]);
            lo++; hi--;
          }
          // Same-group conflict resolution
          bool conflictResolved = false;
          for (int attempt = 0; attempt < elimPairs.length * 2 && !conflictResolved; attempt++) {
            bool anyConflict = false;
            for (int pi = 0; pi < elimPairs.length; pi++) {
              final home = elimPairs[pi][0];
              final away = elimPairs[pi][1];
              if (teamGroup[home] != null &&
                  teamGroup[away] != null &&
                  teamGroup[home] == teamGroup[away]) {
                final nextPi = (pi + 1) % elimPairs.length;
                if (nextPi != pi) {
                  final swapAway = elimPairs[nextPi][1];
                  if (teamGroup[home] != teamGroup[swapAway] &&
                      teamGroup[elimPairs[nextPi][0]] != teamGroup[away]) {
                    elimPairs[pi][1]     = swapAway;
                    elimPairs[nextPi][1] = away;
                    print("ℹ️  ELIM conflict resolved: swapped matches $pi and $nextPi");
                    anyConflict = true;
                    break;
                  }
                }
              }
            }
            if (!anyConflict) conflictResolved = true;
          }
        }

        for (final pair in elimPairs) {
          seeds.add({'home': pair[0], 'away': pair[1]});
        }

        _directQFPairs = directPairs;
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
    // Compute arena_number per slot: matches sharing the same schedule_start each get
    // arena 1, 2, 3… in match_id order (matches were inserted in that order at schedule gen).
    // Group firstRoundMatches by schedule time to assign arenas correctly.
    {
      // Build a schedule_start lookup for first-round matches
      final schedTimeResult = await conn.execute("""
        SELECT m.match_id, TIME_FORMAT(s.schedule_start,'%H:%i') AS slot_time
        FROM tbl_match m
        JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
        WHERE m.bracket_type = :bt
          AND m.category_id  = :catId
        ORDER BY s.schedule_start ASC, m.match_id ASC
      """, {"bt": firstRound, "catId": categoryId});
      final Map<int, int> matchArena = {}; // matchId → arenaNumber
      final Map<String, int> slotCounter = {};
      for (final row in schedTimeResult.rows) {
        final mid  = int.tryParse(row.assoc()['match_id']?.toString() ?? '0') ?? 0;
        final slot = row.assoc()['slot_time']?.toString() ?? '';
        slotCounter[slot] = (slotCounter[slot] ?? 0) + 1;
        matchArena[mid] = slotCounter[slot]!;
      }

      for (int seedIdx = 0; seedIdx < seeds.length; seedIdx++) {
        if (seedIdx >= firstRoundMatches.length) break;
        final matchId = int.tryParse(
            firstRoundMatches[seedIdx]['match_id']?.toString() ?? '0') ?? 0;
        if (matchId == 0) continue;

        final homeId   = seeds[seedIdx]['home'] as int;
        final awayId   = seeds[seedIdx]['away'] as int;
        final arenaNum = matchArena[matchId] ?? 1;

        if (homeId > 0) {
          await conn.execute("""
            INSERT IGNORE INTO tbl_teamschedule
              (match_id, round_id, team_id, referee_id, arena_number)
            VALUES (:mid, 1, :tid, :rid, :arena)
          """, {"mid": matchId, "tid": homeId, "rid": refereeId, "arena": arenaNum});
        } else {
          print("⚠️  KO match $matchId arena $arenaNum: homeId is 0 — slot will show TBD. Check group scores are complete.");
        }
        if (awayId > 0) {
          await conn.execute("""
            INSERT IGNORE INTO tbl_teamschedule
              (match_id, round_id, team_id, referee_id, arena_number)
            VALUES (:mid, 1, :tid, :rid, :arena)
          """, {"mid": matchId, "tid": awayId, "rid": refereeId, "arena": arenaNum});
        } else {
          print("⚠️  KO match $matchId arena $arenaNum: awayId is 0 — slot will show TBD. Check group scores are complete and no ties are unresolved.");
        }
        print("✅ KO match $matchId arena $arenaNum seeded: home=$homeId away=$awayId");
      }
    }

    // ── 8. Seed BYE teams directly into the CORRECT next KO round ───────────
    if (byeSeeds.isNotEmpty) {
      // Rebuild the koRounds plan here (mirrors generateFifaSchedule logic)
      // so we can determine which round BYE teams belong in without relying
      // on a variable from a different function's scope.
      final int _advTeams2 = allAdvancing.length;
      int _bSize2 = 1; while (_bSize2 < _advTeams2) _bSize2 <<= 1;
      final int _halfB2   = _bSize2 ~/ 2;
      final int _elimReal2 = _advTeams2 - _halfB2;
      final localKoRounds = <Map<String, dynamic>>[];
      if (_advTeams2 <= 4) {
        localKoRounds.add({'label': 'semi-finals', 'count': 2});
      } else if (_advTeams2 == 8) {
        localKoRounds.add({'label': 'quarter-finals', 'count': 4});
        localKoRounds.add({'label': 'semi-finals',    'count': 2});
      } else if (_advTeams2 == 16) {
        localKoRounds.add({'label': 'round-of-16',    'count': 8});
        localKoRounds.add({'label': 'quarter-finals', 'count': 4});
        localKoRounds.add({'label': 'semi-finals',    'count': 2});
      } else if (_advTeams2 == 6) {
        localKoRounds.add({'label': 'elimination', 'count': 2});
        localKoRounds.add({'label': 'semi-finals', 'count': 2});
      } else if (_bSize2 <= 16) {
        localKoRounds.add({'label': 'elimination',    'count': _elimReal2});
        localKoRounds.add({'label': 'quarter-finals', 'count': 4});
        localKoRounds.add({'label': 'semi-finals',    'count': 2});
      } else {
        localKoRounds.add({'label': 'elimination',    'count': _elimReal2});
        localKoRounds.add({'label': 'round-of-16',    'count': 8});
        localKoRounds.add({'label': 'quarter-finals', 'count': 4});
        localKoRounds.add({'label': 'semi-finals',    'count': 2});
      }
      localKoRounds.add({'label': 'third-place', 'count': 1});
      localKoRounds.add({'label': 'final',       'count': 1});

      // Determine nextRound: the round AFTER 'elimination' in the plan.
      // This correctly handles 3 groups (→ SF) AND other group counts (→ QF).
      String nextRound = 'semi-finals'; // safe default
      final elimIdx = localKoRounds.indexWhere((r) => r['label'] == 'elimination');
      if (elimIdx >= 0 && elimIdx + 1 < localKoRounds.length) {
        final afterElim = localKoRounds[elimIdx + 1]['label'] as String;
        // Skip non-match rounds (third-place, final) — find real bracket round
        if (afterElim != 'third-place' && afterElim != 'final') {
          nextRound = afterElim;
        }
      } else if (localKoRounds.isNotEmpty) {
        // No elimination round — BYE goes into first KO round
        nextRound = localKoRounds.first['label'] as String;
      }

      print("ℹ️  Seeding ${byeSeeds.length} BYE team(s) directly into '$nextRound'");
      // Get next-round matches ordered by match_id ASC.
      // match_id order = insertion order = Arena 1,2,3,4 (since clearSoccerSchedule
      // now resets AUTO_INCREMENT before every re-generate).
      final nextRoundMatches = await conn.execute("""
        SELECT m.match_id
        FROM tbl_match m
        JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
        WHERE m.bracket_type = :nr
          AND m.category_id  = :catId
        ORDER BY s.schedule_start ASC, m.match_id ASC
      """, {"nr": nextRound, "catId": categoryId});

      final nextSlots = nextRoundMatches.rows
          .map((r) => int.tryParse(r.assoc()['match_id']?.toString() ?? '0') ?? 0)
          .where((id) => id > 0)
          .toList();

      // BYE slot positions:
      //   9-group: Seed1 → slot 3, Seed2 → slot 4 (gitna ng R16)
      //   7-group: Seed1 → slot 0 (Arena 1), Seed2 → slot 3 (Arena 4)
      //   Others:  Seed1 → slot 0, Seed2 → last slot
      // Arena number = slot index + 1 (explicit, not derived from counter)
      final List<int> byeSlotIndices = (n == 9)
          ? [3, 4]
          : [0, nextSlots.length - 1];
      for (int bi = 0; bi < byeSeeds.length; bi++) {
        final teamId  = byeSeeds[bi];
        final slotIdx = bi < byeSlotIndices.length ? byeSlotIndices[bi] : bi;
        if (teamId <= 0 || slotIdx >= nextSlots.length) continue;
        final matchId  = nextSlots[slotIdx];
        // Arena number is EXPLICITLY the 1-based position in the slot list.
        // This must match how advanceKnockoutWinner looks up QF slots.
        final arenaNum = slotIdx + 1;
        await conn.execute("""
          INSERT IGNORE INTO tbl_teamschedule
            (match_id, round_id, team_id, referee_id, arena_number)
          VALUES (:mid, 1, :tid, :rid, :arena)
        """, {"mid": matchId, "tid": teamId, "rid": refereeId, "arena": arenaNum});
        print("✅ BYE team $teamId → '$nextRound' slot $slotIdx match $matchId arena $arenaNum");
      }
    }

    // ── 8b. Seed direct pairs into correct round slots ──────────────────────
    // 9-group: direct pairs go into R16 outer slots (0,1,2,5,6,7)
    // Others:  direct pairs go into inner QF slots (1 and 2)
    if (_directQFPairs.isNotEmpty) {
      // Determine target round and slot indices
      final String directRound = (n == 9) ? 'round-of-16' : 'quarter-finals';
      final List<int> directSlotIndices = (n == 9)
          ? [0, 1, 2, 5, 6, 7]  // outer R16 slots for 9-group
          : [];                   // empty = use inner slots logic below

      final qfResult = await conn.execute("""
        SELECT m.match_id, TIME_FORMAT(s.schedule_start,'%H:%i') AS slot_time
        FROM tbl_match m
        JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
        WHERE m.bracket_type = :bt
          AND m.category_id  = :catId
        ORDER BY s.schedule_start ASC, m.match_id ASC
      """, {"bt": directRound, "catId": categoryId});
      final Map<int, int> qfMatchArena = {};
      final Map<String, int> qfSlotCounter = {};
      final List<int> qfSlots = [];
      for (final row in qfResult.rows) {
        final mid  = int.tryParse(row.assoc()['match_id']?.toString() ?? '0') ?? 0;
        final slot = row.assoc()['slot_time']?.toString() ?? '';
        if (mid <= 0) continue;
        qfSlotCounter[slot] = (qfSlotCounter[slot] ?? 0) + 1;
        qfMatchArena[mid]   = qfSlotCounter[slot]!;
        qfSlots.add(mid);
      }

      // Build the actual slot list to seed into
      final List<int> targetSlots;
      if (directSlotIndices.isNotEmpty) {
        // 9-group: explicit slot indices into R16
        targetSlots = directSlotIndices
            .where((i) => i < qfSlots.length)
            .map((i) => qfSlots[i])
            .toList();
      } else {
        // Others: inner slots (everything except outer 0 and last)
        targetSlots = qfSlots.length >= 2
            ? qfSlots.sublist(1, qfSlots.length - 1)
            : qfSlots;
      }

      for (int pi = 0; pi < _directQFPairs.length; pi++) {
        if (pi >= targetSlots.length) break;
        final matchId  = targetSlots[pi];
        final arenaNum = qfMatchArena[matchId] ?? 1;
        final homeId   = _directQFPairs[pi][0];
        final awayId   = _directQFPairs[pi][1];
        if (homeId > 0) {
          await conn.execute("""
            INSERT IGNORE INTO tbl_teamschedule
              (match_id, round_id, team_id, referee_id, arena_number)
            VALUES (:mid, 1, :tid, :rid, :arena)
          """, {"mid": matchId, "tid": homeId, "rid": refereeId, "arena": arenaNum});
        }
        if (awayId > 0) {
          await conn.execute("""
            INSERT IGNORE INTO tbl_teamschedule
              (match_id, round_id, team_id, referee_id, arena_number)
            VALUES (:mid, 1, :tid, :rid, :arena)
          """, {"mid": matchId, "tid": awayId, "rid": refereeId, "arena": arenaNum});
        }
        print("✅ Direct QF pair (Seed${pi*2+3} vs Seed${pi*2+4 + (_directQFPairs.length-1-pi)*2}) → QF inner slot $pi match $matchId");
      }
    }

    print("✅ Knockout seeding complete: ${seeds.length} ELIM matches, ${byeSeeds.length} BYEs, ${_directQFPairs.length} direct QF pairs.");
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

    // Get all KO match IDs for this category only.
    // FIX: Added category_id filter.
    final matchResult = await conn.execute("""
      SELECT DISTINCT m.match_id
      FROM tbl_match m
      WHERE m.bracket_type IN ($inClause)
        AND m.category_id = $categoryId
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
    Future<void> seedIntoRound(String targetType, int teamId, {int? forceMatchId}) async {
      int nextMatchId;
      String slotTime = '';

      if (forceMatchId != null && forceMatchId > 0) {
        // ── Forced slot: used by 7-group ELIM→QF explicit mapping ─────────────
        // Arena number = 1-based position ordered by schedule_start ASC, match_id ASC.
        // Must be consistent with BYE seeding (slotIndex + 1).
        final allQfResult = await conn.execute("""
          SELECT m2.match_id
          FROM tbl_match m2
          JOIN tbl_schedule s2 ON s2.schedule_id = m2.schedule_id
          WHERE m2.bracket_type = :bt AND m2.category_id = :catId
          ORDER BY s2.schedule_start ASC, m2.match_id ASC
        """, {"bt": targetType, "catId": categoryId});
        final allQfIds = allQfResult.rows
            .map((r) => int.tryParse(r.assoc()['match_id']?.toString() ?? '0') ?? 0)
            .where((id) => id > 0)
            .toList();
        final posIdx = allQfIds.indexOf(forceMatchId);
        final forcedArena = posIdx >= 0 ? posIdx + 1 : 1;

        await conn.execute("""
          INSERT IGNORE INTO tbl_teamschedule
            (match_id, round_id, team_id, referee_id, arena_number)
          VALUES (:nmid, 1, :tid, :rid, :arena)
        """, {"nmid": forceMatchId, "tid": teamId, "rid": refereeId, "arena": forcedArena});
        print("✅ Advance (forced): team $teamId -> $targetType match $forceMatchId arena $forcedArena");
        return;
      } else {
        // FIX: Added category_id filter so winner only seeds into THIS category's matches.
        final matchResult = await conn.execute("""
          SELECT m.match_id,
                 TIME_FORMAT(s.schedule_start,'%H:%i') AS slot_time,
                 COUNT(ts.teamschedule_id) AS team_count
          FROM tbl_match m
          JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
          LEFT JOIN tbl_teamschedule ts ON ts.match_id = m.match_id
          WHERE m.bracket_type = :bt
            AND m.category_id  = :catId
            AND m.match_id NOT IN (
              SELECT DISTINCT ts2.match_id FROM tbl_teamschedule ts2
              WHERE ts2.team_id = :tid
            )
          GROUP BY m.match_id, s.schedule_start
          HAVING team_count < 2
          ORDER BY s.schedule_start ASC, m.match_id ASC
          LIMIT 1
        """, {"bt": targetType, "tid": teamId, "catId": categoryId});
        if (matchResult.rows.isEmpty) return;
        final row = matchResult.rows.first.assoc();
        nextMatchId = int.tryParse(row['match_id']?.toString() ?? '0') ?? 0;
        slotTime    = row['slot_time']?.toString() ?? '';
        if (nextMatchId == 0) return;
      }

      // Compute arena_number: count how many other matches in the same time slot
      // already have this round type — position = existing count + 1
      final slotCountResult = await conn.execute("""
        SELECT COUNT(*) AS slot_cnt
        FROM tbl_match m2
        JOIN tbl_schedule s2 ON s2.schedule_id = m2.schedule_id
        WHERE m2.bracket_type = :bt
          AND TIME_FORMAT(s2.schedule_start,'%H:%i') = :stime
          AND m2.match_id <= :mid
        ORDER BY m2.match_id ASC
      """, {"bt": targetType, "stime": slotTime, "mid": nextMatchId});
      final arenaNum = slotCountResult.rows.isEmpty
          ? 1
          : (int.tryParse(slotCountResult.rows.first.assoc()['slot_cnt']?.toString() ?? '1') ?? 1);

      await conn.execute("""
        INSERT IGNORE INTO tbl_teamschedule
          (match_id, round_id, team_id, referee_id, arena_number)
        VALUES (:nmid, 1, :tid, :rid, :arena)
      """, {"nmid": nextMatchId, "tid": teamId, "rid": refereeId, "arena": arenaNum});
      print("✅ Advance: team $teamId -> $targetType (match $nextMatchId arena $arenaNum)");
    }

    // ── 7-group special: explicit ELIM→QF slot mapping ───────────────────────
    // Bracket design:
    //   QF 0: Seed 1 (BYE)     vs Winner of ELIM 0             → slot index 0
    //   QF 1: Winner of ELIM 1 vs Winner of ELIM 2             → slot index 1
    //   QF 2: Winner of ELIM 3 vs Winner of ELIM 4             → slot index 2
    //   QF 3: Seed 2 (BYE)     vs Winner of ELIM 5             → slot index 3
    //
    // ELIM match order (by match_id ASC):
    //   ELIM index 0 → QF slot 0  (with BYE Seed 1)
    //   ELIM index 1 → QF slot 1
    //   ELIM index 2 → QF slot 1  (merges with ELIM 1 winner)
    //   ELIM index 3 → QF slot 2
    //   ELIM index 4 → QF slot 2  (merges with ELIM 3 winner)
    //   ELIM index 5 → QF slot 3  (with BYE Seed 2)
    const List<int> _elim7toQF = [0, 1, 1, 2, 2, 3]; // ELIM index → QF slot index

    bool _advanced = false;
    if (currentType == 'elimination' && nextWinnerType == 'quarter-finals') {
      // Count how many elimination matches exist for this category
      final elimCountResult = await conn.execute("""
        SELECT COUNT(*) AS cnt FROM tbl_match
        WHERE bracket_type = 'elimination' AND category_id = :catId
      """, {"catId": categoryId});
      final elimCount = int.tryParse(
          elimCountResult.rows.firstOrNull?.assoc()['cnt']?.toString() ?? '0') ?? 0;

      if (elimCount == 6) {
        // ── 7-group path ─────────────────────────────────────────────────────
        // Find this match's ELIM index (0-based) using schedule_start ASC then
        // match_id ASC — MUST match the order used during schedule generation.
        final allElimResult = await conn.execute("""
          SELECT m.match_id FROM tbl_match m
          JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
          WHERE m.bracket_type = 'elimination' AND m.category_id = :catId
          ORDER BY s.schedule_start ASC, m.match_id ASC
        """, {"catId": categoryId});
        final elimMatchIds = allElimResult.rows
            .map((r) => int.tryParse(r.assoc()['match_id']?.toString() ?? '0') ?? 0)
            .where((id) => id > 0)
            .toList();
        final elimIdx = elimMatchIds.indexOf(matchId);

        print("ℹ️  7-group ELIM matchId=$matchId → elimIdx=$elimIdx (all ELIM ids: $elimMatchIds)");

        if (elimIdx >= 0 && elimIdx < _elim7toQF.length) {
          final qfSlotIdx = _elim7toQF[elimIdx];

          // Get QF matches ordered by schedule_start ASC then match_id ASC.
          // This matches the insertion order from generateFifaSchedule, and
          // also matches the BYE seeding in advanceToKnockout which assigns
          // arena_number = slotIndex + 1. So:
          //   qfMatchIds[0] = QF slot 0 = Arena 1 (BYE Seed1 + ELIM0 + ELIM4 winners)
          //   qfMatchIds[1] = QF slot 1 = Arena 2 (ELIM1 winner)
          //   qfMatchIds[2] = QF slot 2 = Arena 3 (ELIM2 winner)
          //   qfMatchIds[3] = QF slot 3 = Arena 4 (BYE Seed2 + ELIM3 + ELIM5 winners)
          final qfMatchesResult = await conn.execute("""
            SELECT m.match_id
            FROM tbl_match m
            JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
            WHERE m.bracket_type = 'quarter-finals' AND m.category_id = :catId
            ORDER BY s.schedule_start ASC, m.match_id ASC
          """, {"catId": categoryId});
          final qfMatchIds = qfMatchesResult.rows
              .map((r) => int.tryParse(r.assoc()['match_id']?.toString() ?? '0') ?? 0)
              .where((id) => id > 0)
              .toList();

          print("ℹ️  7-group QF slot $qfSlotIdx → QF matchIds: $qfMatchIds");

          if (qfSlotIdx < qfMatchIds.length) {
            final targetQfMatchId = qfMatchIds[qfSlotIdx];
            print("✅ 7-group: ELIM[$elimIdx] winner $winnerTeamId → QF slot $qfSlotIdx (match $targetQfMatchId)");
            await seedIntoRound('quarter-finals', winnerTeamId, forceMatchId: targetQfMatchId);
            _advanced = true;
          }
        }
      }
    }

    if (!_advanced && currentType == 'elimination' && nextWinnerType == 'round-of-16') {
      // ── 9-group path: ELIM → R16 explicit slot mapping ─────────────────────
      // ELIM match 0 (index 0) → R16 slot 3 (with Seed 1 BYE) ← gitna top
      // ELIM match 1 (index 1) → R16 slot 4 (with Seed 2 BYE) ← gitna bottom
      const List<int> _elim9toR16 = [3, 4]; // ELIM index → R16 slot index

      final allElimResult9 = await conn.execute("""
        SELECT m.match_id FROM tbl_match m
        JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
        WHERE m.bracket_type = 'elimination' AND m.category_id = :catId
        ORDER BY s.schedule_start ASC, m.match_id ASC
      """, {"catId": categoryId});
      final elimMatchIds9 = allElimResult9.rows
          .map((r) => int.tryParse(r.assoc()['match_id']?.toString() ?? '0') ?? 0)
          .where((id) => id > 0)
          .toList();
      final elimIdx9 = elimMatchIds9.indexOf(matchId);

      print("ℹ️  9-group ELIM matchId=$matchId → elimIdx=$elimIdx9 (all: $elimMatchIds9)");

      if (elimIdx9 >= 0 && elimIdx9 < _elim9toR16.length) {
        final r16SlotIdx = _elim9toR16[elimIdx9];

        final r16MatchesResult = await conn.execute("""
          SELECT m.match_id FROM tbl_match m
          JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
          WHERE m.bracket_type = 'round-of-16' AND m.category_id = :catId
          ORDER BY s.schedule_start ASC, m.match_id ASC
        """, {"catId": categoryId});
        final r16MatchIds = r16MatchesResult.rows
            .map((r) => int.tryParse(r.assoc()['match_id']?.toString() ?? '0') ?? 0)
            .where((id) => id > 0)
            .toList();

        if (r16SlotIdx < r16MatchIds.length) {
          final targetR16MatchId = r16MatchIds[r16SlotIdx];
          print("✅ 9-group: ELIM[$elimIdx9] winner $winnerTeamId → R16 slot $r16SlotIdx (match $targetR16MatchId)");
          await seedIntoRound('round-of-16', winnerTeamId, forceMatchId: targetR16MatchId);
          _advanced = true;
        }
      }
    }

    if (!_advanced) {
      await seedIntoRound(nextWinnerType, winnerTeamId);
    }
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

  // ── TIEBREAKER METHODS ────────────────────────────────────────────────────

  /// Generates tiebreaker matches for a group — one match per tied pair
  /// (round-robin among the tied teams). Clears any existing tiebreakers
  /// for this group first.
  ///
  /// Each tiebreaker match is assigned a scheduled_time immediately after the
  /// last group-stage match (one slot per arena, sequentially).
  static Future<void> generateTiebreakerMatches({
    required int categoryId,
    required String groupLabel,
    required List<int> teamIds,
  }) async {
    final conn = await getConnection();
    // Ensure table exists (migration may not have run on older installs)
    try {
      await conn.execute('''
        CREATE TABLE IF NOT EXISTS tbl_soccer_tiebreaker (
          tiebreaker_id  INT AUTO_INCREMENT PRIMARY KEY,
          category_id    INT NOT NULL,
          group_label    VARCHAR(5) NOT NULL,
          team1_id       INT NOT NULL,
          team2_id       INT NOT NULL,
          team1_score    INT,
          team2_score    INT,
          winner_id      INT,
          scheduled_time TIME NULL DEFAULT NULL,
          arena_number   INT NOT NULL DEFAULT 1,
          created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          INDEX idx_cat_group (category_id, group_label)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
      ''');
    } catch (_) {}
    // Ensure columns exist even on old installs
    try { await conn.execute("ALTER TABLE tbl_soccer_tiebreaker ADD COLUMN scheduled_time TIME NULL DEFAULT NULL"); } catch (_) {}
    try { await conn.execute("ALTER TABLE tbl_soccer_tiebreaker ADD COLUMN arena_number INT NOT NULL DEFAULT 1"); } catch (_) {}

    // Clear previous tiebreakers for this group
    await conn.execute(
      'DELETE FROM tbl_soccer_tiebreaker WHERE category_id = :cat AND group_label = :grp',
      {'cat': categoryId, 'grp': groupLabel},
    );

    // ── Determine schedule time: find the last group-stage match end time ──
    // Tiebreaker slots start right after the last group match, one per minute-slot.
    // We also detect how many arenas were used in group stage to spread ties.
    int lastGroupMinutes = 8 * 60; // default 08:00 fallback
    int matchDuration    = 10;     // default 10 min fallback
    int arenaCount       = 1;
    try {
      final lastResult = await conn.execute("""
        SELECT TIME_FORMAT(MAX(s.schedule_end), '%H:%i') AS last_end,
               TIMESTAMPDIFF(MINUTE,
                 MIN(s.schedule_start), MIN(s.schedule_end)) AS dur_min
        FROM tbl_match m
        JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
        WHERE m.bracket_type = 'group'
          AND m.category_id  = :catId
      """, {'catId': categoryId});
      if (lastResult.rows.isNotEmpty) {
        final row = lastResult.rows.first.assoc();
        final endStr = row['last_end']?.toString() ?? '';
        if (endStr.isNotEmpty) {
          final parts = endStr.split(':');
          lastGroupMinutes = (int.tryParse(parts[0]) ?? 8) * 60
                           + (int.tryParse(parts[1]) ?? 0);
        }
        matchDuration = int.tryParse(row['dur_min']?.toString() ?? '10') ?? 10;
        if (matchDuration <= 0) matchDuration = 10;
      }
      // Detect how many arenas were used in group stage
      final arenaResult = await conn.execute("""
        SELECT MAX(ts.arena_number) AS max_arena
        FROM tbl_teamschedule ts
        JOIN tbl_match m ON m.match_id = ts.match_id
        WHERE m.bracket_type = 'group'
          AND m.category_id  = :catId
      """, {'catId': categoryId});
      if (arenaResult.rows.isNotEmpty) {
        arenaCount = int.tryParse(
            arenaResult.rows.first.assoc()['max_arena']?.toString() ?? '1') ?? 1;
        if (arenaCount < 1) arenaCount = 1;
      }
    } catch (e) {
      print('ℹ️  generateTiebreakerMatches: could not read last group time — $e');
    }

    String fmtTime(int minutes) {
      final h = (minutes ~/ 60).toString().padLeft(2, '0');
      final m = (minutes  %  60).toString().padLeft(2, '0');
      return '$h:$m:00';
    }

    // Build all pairs
    final pairs = <List<int>>[];
    for (int i = 0; i < teamIds.length; i++) {
      for (int j = i + 1; j < teamIds.length; j++) {
        pairs.add([teamIds[i], teamIds[j]]);
      }
    }

    // Assign time slots: pack up to [arenaCount] matches per slot, then advance.
    int cursor = lastGroupMinutes + 5; // 5-min buffer after last group match
    int arena  = 1;
    for (int pi = 0; pi < pairs.length; pi++) {
      await conn.execute(
        'INSERT INTO tbl_soccer_tiebreaker '
        '(category_id, group_label, team1_id, team2_id, scheduled_time, arena_number) '
        'VALUES (:cat, :grp, :t1, :t2, :stime, :arenaNum)',
        {
          'cat':      categoryId,
          'grp':      groupLabel,
          't1':       pairs[pi][0],
          't2':       pairs[pi][1],
          'stime':    fmtTime(cursor),
          'arenaNum': arena,
        },
      );
      arena++;
      if (arena > arenaCount) {
        arena   = 1;
        cursor += matchDuration + 5;
      }
    }

    print('✅ Tiebreaker matches generated: group $groupLabel, teams $teamIds, '
          '${pairs.length} matches starting at ${fmtTime(lastGroupMinutes + 5)}');
  }

  /// Returns all tiebreaker matches for a category.
  /// If any existing rows have NULL scheduled_time (generated before Migration 13),
  /// they are backfilled automatically before returning.
  static Future<List<Map<String, dynamic>>> getTiebreakerMatches(int categoryId) async {
    final conn = await getConnection();
    try {
      await conn.execute('''
        CREATE TABLE IF NOT EXISTS tbl_soccer_tiebreaker (
          tiebreaker_id  INT AUTO_INCREMENT PRIMARY KEY,
          category_id    INT NOT NULL,
          group_label    VARCHAR(5) NOT NULL,
          team1_id       INT NOT NULL,
          team2_id       INT NOT NULL,
          team1_score    INT,
          team2_score    INT,
          winner_id      INT,
          scheduled_time TIME NULL DEFAULT NULL,
          arena_number   INT NOT NULL DEFAULT 1,
          created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          INDEX idx_cat_group (category_id, group_label)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
      ''');
    } catch (_) {}
    // Ensure columns exist on old installs
    try { await conn.execute("ALTER TABLE tbl_soccer_tiebreaker ADD COLUMN scheduled_time TIME NULL DEFAULT NULL"); } catch (_) {}
    try { await conn.execute("ALTER TABLE tbl_soccer_tiebreaker ADD COLUMN arena_number INT NOT NULL DEFAULT 1"); } catch (_) {}

    // ── Backfill: existing tiebreakers with NULL scheduled_time ──────────────
    // These were generated before Migration 13. Re-compute their time+arena
    // from the last group-stage match and patch the rows in-place.
    try {
      final nullCheck = await conn.execute(
        'SELECT COUNT(*) AS cnt FROM tbl_soccer_tiebreaker '
        'WHERE category_id = :cat AND scheduled_time IS NULL',
        {'cat': categoryId},
      );
      final nullCount = int.tryParse(
          nullCheck.rows.first.assoc()['cnt']?.toString() ?? '0') ?? 0;

      if (nullCount > 0) {
        // Read last group-stage end time and match duration
        int lastMin      = 8 * 60;
        int matchDur     = 10;
        int arenaCount   = 1;

        try {
          final lastResult = await conn.execute("""
            SELECT TIME_FORMAT(MAX(s.schedule_end), '%H:%i') AS last_end,
                   TIMESTAMPDIFF(MINUTE,
                     MIN(s.schedule_start), MIN(s.schedule_end)) AS dur_min
            FROM tbl_match m
            JOIN tbl_schedule s ON s.schedule_id = m.schedule_id
            WHERE m.bracket_type = 'group'
              AND m.category_id  = :catId
          """, {'catId': categoryId});
          if (lastResult.rows.isNotEmpty) {
            final row = lastResult.rows.first.assoc();
            final endStr = row['last_end']?.toString() ?? '';
            if (endStr.isNotEmpty) {
              final p = endStr.split(':');
              lastMin = (int.tryParse(p[0]) ?? 8) * 60 + (int.tryParse(p[1]) ?? 0);
            }
            matchDur = int.tryParse(row['dur_min']?.toString() ?? '10') ?? 10;
            if (matchDur <= 0) matchDur = 10;
          }
          final arenaResult = await conn.execute("""
            SELECT MAX(ts.arena_number) AS max_arena
            FROM tbl_teamschedule ts
            JOIN tbl_match m ON m.match_id = ts.match_id
            WHERE m.bracket_type = 'group' AND m.category_id = :catId
          """, {'catId': categoryId});
          if (arenaResult.rows.isNotEmpty) {
            arenaCount = int.tryParse(
                arenaResult.rows.first.assoc()['max_arena']?.toString() ?? '1') ?? 1;
            if (arenaCount < 1) arenaCount = 1;
          }
        } catch (_) {}

        String fmtT(int m) =>
            '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}:00';

        // Fetch all rows that need backfilling, ordered by group + tiebreaker_id
        final rows = await conn.execute(
          'SELECT tiebreaker_id, group_label FROM tbl_soccer_tiebreaker '
          'WHERE category_id = :cat AND scheduled_time IS NULL '
          'ORDER BY group_label, tiebreaker_id',
          {'cat': categoryId},
        );

        int cursor = lastMin + 5;
        int arena  = 1;
        for (final row in rows.rows) {
          final tbId = row.assoc()['tiebreaker_id']?.toString() ?? '0';
          await conn.execute(
            'UPDATE tbl_soccer_tiebreaker '
            'SET scheduled_time = :stime, arena_number = :arenaNum '
            'WHERE tiebreaker_id = :id',
            {'stime': fmtT(cursor), 'arenaNum': arena, 'id': tbId},
          );
          arena++;
          if (arena > arenaCount) {
            arena   = 1;
            cursor += matchDur + 5;
          }
        }
        print('✅ Backfilled scheduled_time/arena_number for $nullCount tiebreaker row(s).');
      }
    } catch (e) {
      print('ℹ️  getTiebreakerMatches backfill skipped: $e');
    }

    final result = await conn.execute(
      'SELECT tb.*, '
      't1.team_name AS team1_name, t2.team_name AS team2_name, '
      'tw.team_name AS winner_name '
      'FROM tbl_soccer_tiebreaker tb '
      'JOIN tbl_team t1 ON t1.team_id = tb.team1_id '
      'JOIN tbl_team t2 ON t2.team_id = tb.team2_id '
      'LEFT JOIN tbl_team tw ON tw.team_id = tb.winner_id '
      'WHERE tb.category_id = :cat '
      'ORDER BY tb.scheduled_time ASC, tb.arena_number ASC, tb.group_label, tb.tiebreaker_id',
      {'cat': categoryId},
    );
    return result.rows.map((r) => r.assoc()).toList();
  }

  /// Returns true when ALL tiebreaker matches for the category have a winner.
  static Future<bool> areTiebreakersComplete(int categoryId) async {
    final conn = await getConnection();
    try {
      final result = await conn.execute(
        'SELECT COUNT(*) AS total, '
        'SUM(CASE WHEN winner_id IS NOT NULL THEN 1 ELSE 0 END) AS done '
        'FROM tbl_soccer_tiebreaker WHERE category_id = :cat',
        {'cat': categoryId},
      );
      if (result.rows.isEmpty) return true;
      final row   = result.rows.first.assoc();
      final total = int.tryParse(row['total']?.toString() ?? '0') ?? 0;
      final done  = int.tryParse(row['done']?.toString()  ?? '0') ?? 0;
      return total == 0 || done >= total;
    } catch (_) {
      return true; // table doesn't exist yet = no tiebreakers needed
    }
  }

  /// Saves the score and winner for a tiebreaker match.
  static Future<void> saveTiebreakerScore({
    required int tiebreakerMatchId,
    required int team1Score,
    required int team2Score,
    required int winnerId,
  }) async {
    final conn = await getConnection();
    await conn.execute(
      'UPDATE tbl_soccer_tiebreaker '
      'SET team1_score = :s1, team2_score = :s2, winner_id = :win '
      'WHERE tiebreaker_id = :id',
      {
        'id':  tiebreakerMatchId,
        's1':  team1Score,
        's2':  team2Score,
        'win': winnerId,
      },
    );
    print('✅ Tiebreaker $tiebreakerMatchId saved: $team1Score-$team2Score winner=$winnerId');
  }

  /// Clears all tiebreaker matches for a category.
  static Future<void> clearTiebreakerMatches(int categoryId) async {
    final conn = await getConnection();
    try {
      await conn.execute(
        'DELETE FROM tbl_soccer_tiebreaker WHERE category_id = :cat',
        {'cat': categoryId},
      );
      print('✅ Tiebreaker matches cleared for category $categoryId.');
    } catch (_) {}
  }

}