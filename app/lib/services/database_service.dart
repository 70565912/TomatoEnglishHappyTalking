import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path_lib;
import '../data/models/article_model.dart';
import '../data/models/learning_record_model.dart';

/// 本地 SQLite 数据库服务（静态单例，使用前需在 main() 中初始化 databaseFactory）
class DatabaseService {
  static Database? _db;

  static Future<Database> get _database async {
    return _db ??= await _open();
  }

  static Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final dbPath = path_lib.join(dir, 'english_love.db');
    return openDatabase(
      dbPath,
      version: 2,
      onCreate: (db, _) async {
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
      },
    );
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

  static Future<void> deleteArticle(int id) async {
    final db = await _database;
    await db.delete('articles', where: 'id = ?', whereArgs: [id]);
    await db.delete('learning_records', where: 'article_id = ?', whereArgs: [id]);
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
}
