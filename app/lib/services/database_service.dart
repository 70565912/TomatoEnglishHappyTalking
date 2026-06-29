import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path_lib;
import '../data/models/article_model.dart';
import '../data/models/article_sentence_translation_model.dart';
import '../data/models/learning_record_model.dart';
import '../data/models/picture_book_model.dart';

/// 本地 SQLite 数据库服务（静态单例，使用前需在 main() 中初始化 databaseFactory）
class DatabaseService {
  static const _desktopDataRootDefine =
      String.fromEnvironment('TOMATO_DESKTOP_DATA_ROOT');
  static const _desktopDataRootEnvKey = 'TOMATO_DESKTOP_DATA_ROOT';
  static const _legacyBuiltInContentSafetyRules = <(String, String)>[
    ('execution', 'exe-cution'),
    ('beheading', 'be-heading'),
    ('beheaded', 'be-headed'),
    ('behead', 'be-head'),
    ('heads', 'he-ads'),
    ('head', 'he-ad'),
    ('killing', 'ki-lling'),
    ('killed', 'ki-lled'),
    ('kills', 'ki-lls'),
    ('kill', 'ki-ll'),
    ('violent', 'vio-lent'),
  ];
  static Database? _db;
  static String? _databaseDirectoryOverrideForTest;
  static String? _runtimeDataRootOverrideForTest;

  static Future<Database> get _database async {
    return _db ??= await _open();
  }

  static Future<Database> get database async => _database;

  static Future<String> get databaseDirectory async =>
      _resolveDatabaseDirectory();

  static Future<String> get runtimeDataRoot async => _resolveRuntimeDataRoot();

  static Future<void> resetForTest() async {
    await _db?.close();
    _db = null;
  }

  static void setDatabaseDirectoryOverrideForTest(String? directory) {
    _databaseDirectoryOverrideForTest = directory;
  }

  static void setRuntimeDataRootOverrideForTest(String? directory) {
    _runtimeDataRootOverrideForTest = directory;
  }

  static Future<Database> _open() async {
    final dbPath = await _resolveDatabasePath();
    await _copyCurrentLegacyDatabaseIfNeeded(dbPath);
    return openDatabase(
      dbPath,
      version: 7,
      onCreate: (db, _) async {
        await _createCoreTables(db);
        await _createApiCacheTables(db);
        await _createPictureBookTables(db);
        await _createArticleSentenceTranslationTables(db);
        await _createArticleChatGuideTables(db);
        await _createContentSafetyTables(db);
      },
      onOpen: (db) async {
        await _createArticleChatGuideTables(db);
        await _ensureLatestPictureBookSchema(db);
        await _removeLegacyBuiltInContentSafetyRules(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE learning_records ADD COLUMN token_scores_json TEXT',
          );
          await db.execute(
            'ALTER TABLE learning_records ADD COLUMN evaluation_meta_json TEXT',
          );
        }
        if (oldVersion < 3) {
          await _createApiCacheTables(db);
        }
        if (oldVersion < 4) {
          await _createPictureBookTables(db);
        }
        if (oldVersion < 5) {
          await _createArticleSentenceTranslationTables(db);
        }
        if (oldVersion < 6) {
          await _createContentSafetyTables(db);
        }
        if (oldVersion < 7) {
          await _migratePictureBookSeriesToV7(db);
        }
      },
    );
  }

  static Future<String> _resolveDatabasePath() async {
    final dir = await _resolveDatabaseDirectory();
    await Directory(dir).create(recursive: true);
    return path_lib.join(dir, 'english_love.db');
  }

  static Future<String> _resolveDatabaseDirectory() async {
    final override = _databaseDirectoryOverrideForTest;
    if (override != null) {
      return override;
    }

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return path_lib.join(
        _resolveDesktopDataRoot(),
        '.dart_tool',
        'sqflite_common_ffi',
        'databases',
      );
    }

    return getDatabasesPath();
  }

  static Future<String> _resolveRuntimeDataRoot() async {
    final rootOverride = _runtimeDataRootOverrideForTest;
    if (rootOverride != null) {
      return rootOverride;
    }

    final override = _databaseDirectoryOverrideForTest;
    if (override != null) {
      return override;
    }

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return _resolveDesktopDataRoot();
    }

    return getDatabasesPath();
  }

  static String _resolveDesktopDataRoot() {
    final explicitRoot = _desktopDataRootDefine.trim().isNotEmpty
        ? _desktopDataRootDefine.trim()
        : (Platform.environment[_desktopDataRootEnvKey] ?? '').trim();
    if (explicitRoot.isNotEmpty) {
      return path_lib.normalize(path_lib.absolute(explicitRoot));
    }

    final executableDir = File(Platform.resolvedExecutable).parent.path;
    final releaseDataRoot = _findWorkspaceReleaseDataRoot(executableDir);
    return releaseDataRoot ?? executableDir;
  }

  static String? _findWorkspaceReleaseDataRoot(String startDirectory) {
    var current = Directory(startDirectory);
    for (var depth = 0; depth < 10; depth++) {
      final candidate = Directory(
        path_lib.join(
          current.path,
          'release',
          'windows',
          'tomato_english_happy_talking',
        ),
      );
      final appPubspec =
          File(path_lib.join(current.path, 'app', 'pubspec.yaml'));
      if (candidate.existsSync() && appPubspec.existsSync()) {
        return path_lib.normalize(candidate.absolute.path);
      }

      final parent = current.parent;
      if (path_lib.equals(
        path_lib.normalize(parent.path),
        path_lib.normalize(current.path),
      )) {
        break;
      }
      current = parent;
    }
    return null;
  }

  static Future<void> _copyCurrentLegacyDatabaseIfNeeded(
    String targetPath,
  ) async {
    final target = File(targetPath);
    if (await target.exists()) {
      return;
    }

    final legacyPath =
        path_lib.join(await getDatabasesPath(), 'english_love.db');
    if (path_lib.equals(
        path_lib.normalize(legacyPath), path_lib.normalize(targetPath))) {
      return;
    }

    final legacy = File(legacyPath);
    if (!await legacy.exists()) {
      return;
    }

    await target.parent.create(recursive: true);
    await legacy.copy(targetPath);
  }

  static Future<void> _createCoreTables(Database db) async {
    await db.execute('''
      CREATE TABLE articles (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        title     TEXT    NOT NULL,
        content   TEXT    NOT NULL,
        sentences TEXT    NOT NULL,
        created_at TEXT   NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE learning_records (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        article_id          INTEGER NOT NULL,
        sentence            TEXT    NOT NULL,
        overall_score       REAL    NOT NULL,
        accuracy_score      REAL    NOT NULL,
        fluency_score       REAL    NOT NULL,
        completeness_score  REAL    NOT NULL,
        prosody_score       REAL    NOT NULL,
        token_scores_json   TEXT,
        evaluation_meta_json TEXT,
        created_at          TEXT    NOT NULL,
        FOREIGN KEY (article_id) REFERENCES articles (id)
      )
    ''');
  }

  static Future<void> _createApiCacheTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS api_cache_entries (
        cache_key    TEXT PRIMARY KEY,
        kind         TEXT NOT NULL,
        purpose      TEXT NOT NULL,
        request_json TEXT NOT NULL,
        text_value   TEXT,
        json_value   TEXT,
        file_path    TEXT,
        content_type TEXT,
        byte_length  INTEGER,
        source       TEXT NOT NULL,
        created_at   TEXT NOT NULL,
        updated_at   TEXT NOT NULL,
        last_used_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS api_cache_article_refs (
        article_id INTEGER NOT NULL,
        cache_key  TEXT NOT NULL,
        purpose    TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (article_id, cache_key, purpose),
        FOREIGN KEY (article_id) REFERENCES articles (id),
        FOREIGN KEY (cache_key) REFERENCES api_cache_entries (cache_key)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_api_cache_refs_key '
      'ON api_cache_article_refs (cache_key)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS latest_sentence_recordings (
        article_id      INTEGER NOT NULL,
        sentence_index  INTEGER NOT NULL,
        sentence        TEXT NOT NULL,
        recording_path  TEXT NOT NULL,
        audio_hash      TEXT NOT NULL,
        recognized_text TEXT NOT NULL,
        result_json     TEXT NOT NULL,
        created_at      TEXT NOT NULL,
        updated_at      TEXT NOT NULL,
        PRIMARY KEY (article_id, sentence_index),
        FOREIGN KEY (article_id) REFERENCES articles (id)
      )
    ''');
  }

  static Future<void> _createPictureBookTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS story_series (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        title            TEXT    NOT NULL,
        description      TEXT    NOT NULL DEFAULT '',
        characters_json  TEXT    NOT NULL DEFAULT '[]',
        cover_image_path TEXT,
        created_at       TEXT    NOT NULL,
        updated_at       TEXT    NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS story_chapters (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        series_id     INTEGER NOT NULL,
        article_id    INTEGER NOT NULL UNIQUE,
        chapter_order INTEGER NOT NULL,
        chapter_title TEXT    NOT NULL,
        summary_json  TEXT    NOT NULL,
        created_at    TEXT    NOT NULL,
        updated_at    TEXT    NOT NULL,
        FOREIGN KEY (series_id) REFERENCES story_series (id),
        FOREIGN KEY (article_id) REFERENCES articles (id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_story_chapters_series '
      'ON story_chapters (series_id, chapter_order)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS picture_book_pages (
        id                   INTEGER PRIMARY KEY AUTOINCREMENT,
        article_id           INTEGER NOT NULL,
        series_id            INTEGER,
        page_index           INTEGER NOT NULL,
        sentence_start_index INTEGER NOT NULL,
        sentence_end_index   INTEGER NOT NULL,
        paragraph_text       TEXT    NOT NULL,
        prompt_json          TEXT    NOT NULL,
        image_cache_key      TEXT,
        image_path           TEXT,
        status               TEXT    NOT NULL,
        error_message        TEXT,
        created_at           TEXT    NOT NULL,
        updated_at           TEXT    NOT NULL,
        UNIQUE (article_id, page_index),
        FOREIGN KEY (article_id) REFERENCES articles (id),
        FOREIGN KEY (series_id) REFERENCES story_series (id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_picture_book_pages_article '
      'ON picture_book_pages (article_id, page_index)',
    );
  }

  static Future<void> _migratePictureBookSeriesToV7(Database db) async {
    final columns = await _tableColumns(db, 'story_series');
    if (columns.isEmpty) {
      await _createPictureBookTables(db);
    } else {
      if (!columns.contains('description')) {
        await db.execute(
          "ALTER TABLE story_series ADD COLUMN description TEXT NOT NULL DEFAULT ''",
        );
      }
      if (!columns.contains('characters_json')) {
        await db.execute(
          "ALTER TABLE story_series ADD COLUMN characters_json TEXT NOT NULL DEFAULT '[]'",
        );
      }
      if (columns.contains('style_guide_json')) {
        await db
            .execute('ALTER TABLE story_series DROP COLUMN style_guide_json');
      }
      if (columns.contains('bible_json')) {
        await db.execute('ALTER TABLE story_series DROP COLUMN bible_json');
      }
    }
    await db.execute('DROP TABLE IF EXISTS story_reference_assets');
  }

  static Future<void> _ensureLatestPictureBookSchema(Database db) async {
    final columns = await _tableColumns(db, 'story_series');
    if (columns.isEmpty) {
      await _createPictureBookTables(db);
      return;
    }
    if (!columns.contains('description')) {
      await db.execute(
        "ALTER TABLE story_series ADD COLUMN description TEXT NOT NULL DEFAULT ''",
      );
    }
    if (!columns.contains('characters_json')) {
      await db.execute(
        "ALTER TABLE story_series ADD COLUMN characters_json TEXT NOT NULL DEFAULT '[]'",
      );
    }
  }

  static Future<Set<String>> _tableColumns(
      Database db, String tableName) async {
    final rows = await db.rawQuery('PRAGMA table_info($tableName)');
    return rows
        .map((row) => row['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .toSet();
  }

  static Future<void> _createArticleSentenceTranslationTables(
    Database db,
  ) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS article_sentence_translations (
        article_id       INTEGER NOT NULL,
        sentence_index   INTEGER NOT NULL,
        english_sentence TEXT    NOT NULL,
        chinese_text     TEXT    NOT NULL,
        source           TEXT    NOT NULL,
        created_at       TEXT    NOT NULL,
        updated_at       TEXT    NOT NULL,
        PRIMARY KEY (article_id, sentence_index),
        FOREIGN KEY (article_id) REFERENCES articles (id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_article_sentence_translations_article '
      'ON article_sentence_translations (article_id, sentence_index)',
    );
  }

  static Future<void> _createArticleChatGuideTables(
    Database db,
  ) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS article_chat_guides (
        article_id   INTEGER NOT NULL,
        purpose      TEXT    NOT NULL,
        content_hash TEXT    NOT NULL,
        guide_text   TEXT    NOT NULL,
        created_at   TEXT    NOT NULL,
        updated_at   TEXT    NOT NULL,
        PRIMARY KEY (article_id, purpose),
        FOREIGN KEY (article_id) REFERENCES articles (id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_article_chat_guides_lookup '
      'ON article_chat_guides (article_id, purpose, content_hash)',
    );
  }

  static Future<void> _createContentSafetyTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS content_safety_failures (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        service_kind  TEXT    NOT NULL,
        purpose       TEXT    NOT NULL,
        article_id    INTEGER,
        failed_text   TEXT    NOT NULL,
        failed_hash   TEXT    NOT NULL,
        error_code    TEXT,
        error_message TEXT,
        created_at    TEXT    NOT NULL,
        resolved_at   TEXT,
        FOREIGN KEY (article_id) REFERENCES articles (id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_content_safety_failures_lookup '
      'ON content_safety_failures '
      '(service_kind, purpose, article_id, resolved_at, created_at)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS content_safety_rules (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        source_term       TEXT    NOT NULL,
        replacement       TEXT    NOT NULL,
        service_kind      TEXT    NOT NULL,
        purpose_scope     TEXT    NOT NULL,
        match_type        TEXT    NOT NULL,
        confidence        REAL    NOT NULL,
        enabled           INTEGER NOT NULL,
        source_failure_id INTEGER,
        created_at        TEXT    NOT NULL,
        updated_at        TEXT    NOT NULL,
        UNIQUE (service_kind, purpose_scope, source_term, replacement)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_content_safety_rules_enabled '
      'ON content_safety_rules (service_kind, purpose_scope, enabled)',
    );
  }

  static Future<void> _removeLegacyBuiltInContentSafetyRules(
    Database db,
  ) async {
    for (final rule in _legacyBuiltInContentSafetyRules) {
      await db.delete(
        'content_safety_rules',
        where: '''
          source_term = ?
          AND replacement = ?
          AND service_kind = ?
          AND purpose_scope = ?
          AND match_type = ?
          AND source_failure_id IS NULL
          AND ABS(confidence - ?) < 0.000001
        ''',
        whereArgs: [
          rule.$1,
          rule.$2,
          '*',
          '*',
          'word',
          0.55,
        ],
      );
    }
  }

  // ===== Articles =====

  static Future<List<Article>> getArticles() async {
    final db = await _database;
    final maps = await db.query('articles', orderBy: 'created_at DESC');
    return maps.map(Article.fromMap).toList();
  }

  static Future<Article?> getArticleById(int id) async {
    final db = await _database;
    final maps = await db.query('articles', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Article.fromMap(maps.first);
  }

  static Future<int> saveArticle(Article article) async {
    final db = await _database;
    return db.insert('articles', article.toMap());
  }

  static Future<void> updateArticleSentences(
    int id,
    List<String> sentences,
  ) async {
    final db = await _database;
    await db.update(
      'articles',
      {'sentences': jsonEncode(sentences)},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> updateArticleContentAndSentences(
    int id,
    String content,
    List<String> sentences,
  ) async {
    final db = await _database;
    await db.update(
      'articles',
      {
        'content': content,
        'sentences': jsonEncode(sentences),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> updateArticleTitle(int id, String title) async {
    final db = await _database;
    await db.update(
      'articles',
      {'title': title},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> deleteArticle(int id) async {
    final db = await _database;
    final cacheRows = await db.query(
      'api_cache_article_refs',
      columns: ['cache_key'],
      where: 'article_id = ?',
      whereArgs: [id],
    );
    final cacheKeys = cacheRows
        .map((row) => row['cache_key']?.toString() ?? '')
        .where((key) => key.isNotEmpty)
        .toSet();
    final recordingRows = await db.query(
      'latest_sentence_recordings',
      columns: ['recording_path'],
      where: 'article_id = ?',
      whereArgs: [id],
    );
    final recordingPaths = recordingRows
        .map((row) => row['recording_path']?.toString() ?? '')
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    final pictureRows = await db.query(
      'picture_book_pages',
      columns: ['image_path', 'image_cache_key'],
      where: 'article_id = ?',
      whereArgs: [id],
    );
    final pictureFilePaths = pictureRows
        .map((row) => row['image_path']?.toString() ?? '')
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    cacheKeys.addAll(
      pictureRows
          .map((row) => row['image_cache_key']?.toString() ?? '')
          .where((key) => key.isNotEmpty),
    );
    final chapterRows = await db.query(
      'story_chapters',
      columns: ['series_id'],
      where: 'article_id = ?',
      whereArgs: [id],
    );
    final affectedSeriesIds = chapterRows
        .map((row) => (row['series_id'] as num?)?.toInt())
        .whereType<int>()
        .toSet();

    await db
        .delete('learning_records', where: 'article_id = ?', whereArgs: [id]);
    await deleteArticleSentenceTranslations(id);
    await deleteArticleChatGuide(id);
    await db.delete(
      'picture_book_pages',
      where: 'article_id = ?',
      whereArgs: [id],
    );
    await db.delete(
      'story_chapters',
      where: 'article_id = ?',
      whereArgs: [id],
    );
    await db.delete(
      'latest_sentence_recordings',
      where: 'article_id = ?',
      whereArgs: [id],
    );
    await db.delete(
      'content_safety_failures',
      where: 'article_id = ?',
      whereArgs: [id],
    );
    await db.delete(
      'api_cache_article_refs',
      where: 'article_id = ?',
      whereArgs: [id],
    );
    await db.delete('articles', where: 'id = ?', whereArgs: [id]);

    final cacheFilePaths = <String>[];
    for (final cacheKey in cacheKeys) {
      final refCount = Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM api_cache_article_refs WHERE cache_key = ?',
              [cacheKey],
            ),
          ) ??
          0;
      if (refCount > 0) {
        continue;
      }

      final entries = await db.query(
        'api_cache_entries',
        columns: ['file_path'],
        where: 'cache_key = ?',
        whereArgs: [cacheKey],
      );
      if (entries.isNotEmpty) {
        final filePath = entries.first['file_path']?.toString() ?? '';
        if (filePath.isNotEmpty) {
          cacheFilePaths.add(filePath);
        }
      }
      await db.delete(
        'api_cache_entries',
        where: 'cache_key = ?',
        whereArgs: [cacheKey],
      );
    }

    for (final seriesId in affectedSeriesIds) {
      final remainingChapterCount = Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM story_chapters WHERE series_id = ?',
              [seriesId],
            ),
          ) ??
          0;
      if (remainingChapterCount > 0) {
        continue;
      }
      await db.delete(
        'story_series',
        where: 'id = ?',
        whereArgs: [seriesId],
      );
    }

    for (final filePath in [
      ...recordingPaths,
      ...pictureFilePaths,
      ...cacheFilePaths,
    ]) {
      try {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // Cache cleanup is best effort; database rows are already removed.
      }
    }
  }

  // ===== Imported sentence translations =====

  static Future<void> saveArticleSentenceTranslations(
    int articleId,
    List<ArticleSentenceTranslation> translations,
  ) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(
        'article_sentence_translations',
        where: 'article_id = ?',
        whereArgs: [articleId],
      );
      for (final translation in translations) {
        await txn.insert(
          'article_sentence_translations',
          translation.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  static Future<String?> getArticleSentenceTranslation(
    int articleId,
    int sentenceIndex,
    String sentence,
  ) async {
    final db = await _database;
    final maps = await db.query(
      'article_sentence_translations',
      where: 'article_id = ? AND sentence_index = ?',
      whereArgs: [articleId, sentenceIndex],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      final row = ArticleSentenceTranslation.fromMap(maps.first);
      final storedSentence = _normalizeSentenceForTranslationLookup(
        row.englishSentence,
      );
      final requestedSentence = _normalizeSentenceForTranslationLookup(
        sentence,
      );
      if (storedSentence.isEmpty ||
          requestedSentence.isEmpty ||
          storedSentence == requestedSentence) {
        final translated = row.chineseText.trim();
        if (translated.isNotEmpty) {
          return translated;
        }
      }
    }

    final allMaps = await db.query(
      'article_sentence_translations',
      where: 'article_id = ?',
      whereArgs: [articleId],
      orderBy: 'sentence_index ASC',
    );
    if (allMaps.isEmpty) {
      return null;
    }
    return _compatibleTranslationForSentence(
      sentence: sentence,
      rows: allMaps
          .map(ArticleSentenceTranslation.fromMap)
          .toList(growable: false),
    );
  }

  static Future<Map<int, String>> getArticleSentenceTranslationsForSentences({
    required int articleId,
    required List<String> sentences,
  }) async {
    if (sentences.isEmpty) {
      return const {};
    }

    final db = await _database;
    final maps = await db.query(
      'article_sentence_translations',
      where: 'article_id = ?',
      whereArgs: [articleId],
      orderBy: 'sentence_index ASC',
    );
    if (maps.isEmpty) {
      return const {};
    }

    final translations = <int, String>{};
    final rows =
        maps.map(ArticleSentenceTranslation.fromMap).toList(growable: false);
    for (final row in rows) {
      final sentenceIndex = row.sentenceIndex;
      if (sentenceIndex < 0 || sentenceIndex >= sentences.length) {
        continue;
      }
      final storedSentence = _normalizeSentenceForTranslationLookup(
        row.englishSentence,
      );
      final requestedSentence = _normalizeSentenceForTranslationLookup(
        sentences[sentenceIndex],
      );
      if (storedSentence.isNotEmpty &&
          requestedSentence.isNotEmpty &&
          storedSentence != requestedSentence) {
        continue;
      }
      final translated = row.chineseText.trim();
      if (translated.isNotEmpty) {
        translations[sentenceIndex] = translated;
      }
    }
    if (translations.length >= sentences.length) {
      return translations;
    }
    for (var index = 0; index < sentences.length; index += 1) {
      if (translations.containsKey(index)) {
        continue;
      }
      final compatible = _compatibleTranslationForSentence(
        sentence: sentences[index],
        rows: rows,
      );
      if (compatible != null && compatible.trim().isNotEmpty) {
        translations[index] = compatible.trim();
      }
    }
    return translations;
  }

  static Future<void> upsertArticleSentenceTranslation({
    required int articleId,
    required int sentenceIndex,
    required String englishSentence,
    required String chineseText,
    String source = 'edited',
  }) async {
    final db = await _database;
    final now = DateTime.now();
    final existing = await db.query(
      'article_sentence_translations',
      columns: ['created_at'],
      where: 'article_id = ? AND sentence_index = ?',
      whereArgs: [articleId, sentenceIndex],
      limit: 1,
    );
    final createdAt = existing.isEmpty
        ? now
        : DateTime.parse(existing.first['created_at'] as String);
    final translation = ArticleSentenceTranslation(
      articleId: articleId,
      sentenceIndex: sentenceIndex,
      englishSentence: englishSentence,
      chineseText: chineseText,
      source: source,
      createdAt: createdAt,
      updatedAt: now,
    );
    await db.insert(
      'article_sentence_translations',
      translation.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> deleteArticleSentenceTranslation(
    int articleId,
    int sentenceIndex,
  ) async {
    final db = await _database;
    await db.delete(
      'article_sentence_translations',
      where: 'article_id = ? AND sentence_index = ?',
      whereArgs: [articleId, sentenceIndex],
    );
  }

  static Future<void> deleteArticleSentenceTranslations(int articleId) async {
    final db = await _database;
    await db.delete(
      'article_sentence_translations',
      where: 'article_id = ?',
      whereArgs: [articleId],
    );
  }

  // ===== Chapter chat guides =====

  static Future<String?> getArticleChatGuide({
    required int articleId,
    required String purpose,
    required String contentHash,
  }) async {
    final db = await _database;
    final maps = await db.query(
      'article_chat_guides',
      columns: ['guide_text'],
      where: 'article_id = ? AND purpose = ? AND content_hash = ?',
      whereArgs: [articleId, purpose, contentHash],
      limit: 1,
    );
    if (maps.isEmpty) {
      return null;
    }
    final guide = maps.first['guide_text']?.toString().trim() ?? '';
    return guide.isEmpty ? null : guide;
  }

  static Future<void> saveArticleChatGuide({
    required int articleId,
    required String purpose,
    required String contentHash,
    required String guideText,
  }) async {
    final guide = guideText.trim();
    if (guide.isEmpty) {
      return;
    }
    final db = await _database;
    final now = DateTime.now().toIso8601String();
    await db.insert(
      'article_chat_guides',
      {
        'article_id': articleId,
        'purpose': purpose,
        'content_hash': contentHash,
        'guide_text': guide,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> deleteArticleChatGuide(int articleId) async {
    final db = await _database;
    await db.delete(
      'article_chat_guides',
      where: 'article_id = ?',
      whereArgs: [articleId],
    );
  }

  static String _normalizeSentenceForTranslationLookup(String text) =>
      text.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();

  static String? _compatibleTranslationForSentence({
    required String sentence,
    required List<ArticleSentenceTranslation> rows,
  }) {
    final requestedTokens = _translationLookupTokens(sentence);
    if (requestedTokens.isEmpty) {
      return null;
    }
    final requestedKey = requestedTokens.join(' ');

    for (final row in rows) {
      final translated = row.chineseText.trim();
      if (translated.isEmpty) {
        continue;
      }
      final rowTokens = _translationLookupTokens(row.englishSentence);
      if (rowTokens.join(' ') == requestedKey) {
        return translated;
      }
    }

    final matches = <_TranslationCompatibilityMatch>[];
    for (final row in rows) {
      final translated = row.chineseText.trim();
      if (translated.isEmpty) {
        continue;
      }
      final rowTokens = _translationLookupTokens(row.englishSentence);
      if (rowTokens.length < 2 || rowTokens.length > requestedTokens.length) {
        continue;
      }
      for (final start in _tokenSequenceStarts(requestedTokens, rowTokens)) {
        matches.add(_TranslationCompatibilityMatch(
          row: row,
          start: start,
          end: start + rowTokens.length,
        ));
      }
    }
    if (matches.isEmpty) {
      return null;
    }
    matches.sort((a, b) {
      final startCompare = a.start.compareTo(b.start);
      if (startCompare != 0) return startCompare;
      final lengthCompare = b.length.compareTo(a.length);
      if (lengthCompare != 0) return lengthCompare;
      return a.row.sentenceIndex.compareTo(b.row.sentenceIndex);
    });

    final selected = <_TranslationCompatibilityMatch>[];
    var cursor = 0;
    var covered = 0;
    for (final match in matches) {
      if (match.end <= cursor || match.start < cursor) {
        continue;
      }
      selected.add(match);
      covered += match.length;
      cursor = match.end;
    }
    if (selected.isEmpty) {
      return null;
    }

    final coverage = covered / requestedTokens.length;
    final allowedBoundaryGap = requestedTokens.length < 10
        ? 1
        : (requestedTokens.length * 0.15).ceil();
    final leadingGap = selected.first.start;
    final trailingGap = requestedTokens.length - selected.last.end;
    if (coverage < 0.85 ||
        leadingGap > allowedBoundaryGap ||
        trailingGap > allowedBoundaryGap) {
      return null;
    }

    return selected
        .map((match) => match.row.chineseText.trim())
        .where((text) => text.isNotEmpty)
        .join('');
  }

  static List<String> _translationLookupTokens(String text) => RegExp(
        r"[a-z0-9]+(?:'[a-z0-9]+)?",
        caseSensitive: false,
      )
          .allMatches(text.toLowerCase())
          .map((match) => match.group(0) ?? '')
          .where((token) => token.isNotEmpty)
          .toList(growable: false);

  static Iterable<int> _tokenSequenceStarts(
    List<String> haystack,
    List<String> needle,
  ) sync* {
    if (needle.isEmpty || needle.length > haystack.length) {
      return;
    }
    final maxStart = haystack.length - needle.length;
    for (var start = 0; start <= maxStart; start += 1) {
      var matched = true;
      for (var offset = 0; offset < needle.length; offset += 1) {
        if (haystack[start + offset] != needle[offset]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        yield start;
      }
    }
  }

  // ===== Learning Records =====

  static Future<void> saveLearningRecord(LearningRecord record) async {
    final db = await _database;
    await db.insert('learning_records', record.toMap());
  }

  static Future<List<LearningRecord>> getRecordsForArticle(
    int articleId,
  ) async {
    final db = await _database;
    final maps = await db.query(
      'learning_records',
      where: 'article_id = ?',
      whereArgs: [articleId],
      orderBy: 'created_at DESC',
    );
    return maps.map(LearningRecord.fromMap).toList();
  }

  static Future<double> getAverageScore(int articleId) async {
    final db = await _database;
    final result = await db.rawQuery(
      'SELECT AVG(overall_score) as avg FROM learning_records WHERE article_id = ?',
      [articleId],
    );
    return (result.first['avg'] as num?)?.toDouble() ?? 0.0;
  }

  // ===== Story series and picture-book pages =====

  static Future<List<StorySeries>> getStorySeries() async {
    final db = await _database;
    final maps = await db.query('story_series', orderBy: 'updated_at DESC');
    return maps.map(StorySeries.fromMap).toList(growable: false);
  }

  static Future<StorySeries?> getStorySeriesById(int id) async {
    final db = await _database;
    final maps = await db.query(
      'story_series',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) {
      return null;
    }
    return StorySeries.fromMap(maps.first);
  }

  static Future<int> saveStorySeries(StorySeries series) async {
    final db = await _database;
    return db.insert('story_series', series.toMap());
  }

  static Future<void> updateStorySeries(StorySeries series) async {
    final id = series.id;
    if (id == null) {
      return;
    }
    final db = await _database;
    await db.update(
      'story_series',
      series.toMap()..remove('id'),
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<bool> deleteStorySeriesIfEmpty(int seriesId) async {
    final db = await _database;
    final liveChapterCount = Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM story_chapters sc '
            'INNER JOIN articles a ON a.id = sc.article_id '
            'WHERE sc.series_id = ?',
            [seriesId],
          ),
        ) ??
        0;
    if (liveChapterCount > 0) {
      return false;
    }

    await db.delete(
      'story_chapters',
      where: 'series_id = ?',
      whereArgs: [seriesId],
    );

    final deleted = await db.delete(
      'story_series',
      where: 'id = ?',
      whereArgs: [seriesId],
    );
    return deleted > 0;
  }

  static Future<StoryChapter?> getStoryChapterForArticle(int articleId) async {
    final db = await _database;
    final maps = await db.query(
      'story_chapters',
      where: 'article_id = ?',
      whereArgs: [articleId],
      limit: 1,
    );
    if (maps.isEmpty) {
      return null;
    }
    return StoryChapter.fromMap(maps.first);
  }

  static Future<int> nextStoryChapterOrder(int seriesId) async {
    final db = await _database;
    final result = await db.rawQuery(
      'SELECT MAX(chapter_order) AS max_order FROM story_chapters '
      'WHERE series_id = ?',
      [seriesId],
    );
    final maxOrder = (result.first['max_order'] as num?)?.toInt() ?? 0;
    return maxOrder + 1;
  }

  static Future<int> saveStoryChapter(StoryChapter chapter) async {
    final db = await _database;
    return db.insert(
      'story_chapters',
      chapter.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> updateStoryChapter(StoryChapter chapter) async {
    final id = chapter.id;
    final db = await _database;
    if (id == null) {
      await saveStoryChapter(chapter);
      return;
    }
    await db.update(
      'story_chapters',
      chapter.toMap(),
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> updateStoryChapterTitleForArticle(
    int articleId,
    String title,
  ) async {
    final db = await _database;
    await db.update(
      'story_chapters',
      {
        'chapter_title': title,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'article_id = ?',
      whereArgs: [articleId],
    );
  }

  static Future<List<PictureBookPage>> getPictureBookPages(
    int articleId,
  ) async {
    final db = await _database;
    final maps = await db.query(
      'picture_book_pages',
      where: 'article_id = ?',
      whereArgs: [articleId],
      orderBy: 'page_index ASC',
    );
    return maps.map(PictureBookPage.fromMap).toList(growable: false);
  }

  static Future<void> upsertPictureBookPage(PictureBookPage page) async {
    final db = await _database;
    await db.insert(
      'picture_book_pages',
      page.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> deletePictureBookPagesForArticle(int articleId) async {
    final db = await _database;
    await db.delete(
      'picture_book_pages',
      where: 'article_id = ?',
      whereArgs: [articleId],
    );
  }
}

class _TranslationCompatibilityMatch {
  const _TranslationCompatibilityMatch({
    required this.row,
    required this.start,
    required this.end,
  });

  final ArticleSentenceTranslation row;
  final int start;
  final int end;

  int get length => end - start;
}
