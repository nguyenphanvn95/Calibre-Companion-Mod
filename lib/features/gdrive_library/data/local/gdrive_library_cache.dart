import 'dart:convert';

import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:calibre_web_companion/features/gdrive_library/data/models/gdrive_book_model.dart';

/// Local SQLite cache for a `metadata_public.json` "GDrive JSON" library.
///
/// The cache is rebuilt wholesale from the JSON every time the user refreshes
/// (see `GDriveLocalServer.start`) - there is intentionally no incremental
/// diffing in v1 (fine for the ~90 book / 320KB sample; left as a TODO for
/// larger libraries).
class GDriveLibraryCache {
  static const _dbName = 'gdrive_library_cache.db';
  static const _dbVersion = 1;

  final Logger _logger;
  Database? _db;

  GDriveLibraryCache({Logger? logger}) : _logger = logger ?? Logger();

  Future<Database> _openDb() async {
    if (_db != null && _db!.isOpen) return _db!;

    final docsDir = await getApplicationDocumentsDirectory();
    final path = p.join(docsDir.path, _dbName);

    _db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE books (
            book_id INTEGER PRIMARY KEY,
            title TEXT,
            sort TEXT,
            author_sort TEXT,
            authors TEXT,
            series TEXT,
            series_index REAL,
            publisher TEXT,
            tags_json TEXT,
            rating INTEGER,
            languages_json TEXT,
            comments TEXT,
            isbn TEXT,
            uuid TEXT,
            has_cover INTEGER,
            cover_file_id TEXT,
            formats_json TEXT,
            last_modified TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_books_title ON books(title)',
        );
        await db.execute(
          'CREATE INDEX idx_books_author_sort ON books(author_sort)',
        );
        await db.execute(
          'CREATE INDEX idx_books_series ON books(series)',
        );
        await db.execute('''
          CREATE TABLE library_meta (
            key TEXT PRIMARY KEY,
            value TEXT
          )
        ''');
      },
    );
    return _db!;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Wipes and repopulates the whole cache from a raw `metadata_public.json`
  /// string. Returns the parsed index (mostly useful for tests).
  Future<GDriveLibraryIndexModel> rebuildFromJson(
    String rawJson, {
    required String sourceFileId,
  }) async {
    final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
    final index = GDriveLibraryIndexModel.fromJson(decoded);
    final db = await _openDb();

    await db.transaction((txn) async {
      await txn.delete('books');

      final batch = txn.batch();
      for (final book in index.books) {
        batch.insert('books', {
          'book_id': book.bookId,
          'title': book.title,
          'sort': book.sort.isEmpty ? book.title : book.sort,
          'author_sort': book.authorSort,
          'authors': book.authors,
          'series': book.series,
          'series_index': book.seriesIndex,
          'publisher': book.publisher,
          'tags_json': jsonEncode(book.tags),
          'rating': book.rating,
          'languages_json': jsonEncode(book.languages),
          'comments': book.comments,
          'isbn': book.isbn,
          'uuid': book.uuid,
          'has_cover': book.hasCover ? 1 : 0,
          'cover_file_id': book.coverFileId,
          'formats_json': jsonEncode(
            book.formats.map((k, v) => MapEntry(k, v.toJson())),
          ),
          'last_modified': book.lastModified?.toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);

      await txn.insert('library_meta', {
        'key': 'generated_at',
        'value': index.generatedAt?.toIso8601String() ?? '',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('library_meta', {
        'key': 'source_file_id',
        'value': sourceFileId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('library_meta', {
        'key': 'library_path',
        'value': index.libraryPath,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('library_meta', {
        'key': 'book_count',
        'value': index.books.length.toString(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });

    _logger.i('GDrive library cache rebuilt: ${index.books.length} books');
    return index;
  }

  Future<String?> getMeta(String key) async {
    final db = await _openDb();
    final rows = await db.query(
      'library_meta',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// True when the currently cached data was generated from a different
  /// Drive file id, or the cache is empty - i.e. a re-download is needed.
  Future<bool> needsResync(String sourceFileId) async {
    final storedId = await getMeta('source_file_id');
    final count = await getMeta('book_count');
    return storedId != sourceFileId || storedId == null || count == '0' || count == null;
  }

  GDriveBookModel _rowToBook(Map<String, Object?> row) {
    Map<String, GDriveFileRef> parseFormats(String? raw) {
      if (raw == null || raw.isEmpty) return const {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (k, v) => MapEntry(k, GDriveFileRef.fromJson(Map<String, dynamic>.from(v))),
      );
    }

    List<String> parseList(String? raw) {
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
      return const [];
    }

    final coverFileId = row['cover_file_id'] as String?;

    return GDriveBookModel(
      bookId: row['book_id'] as int,
      title: row['title'] as String? ?? 'Unknown Title',
      sort: row['sort'] as String? ?? '',
      authorSort: row['author_sort'] as String? ?? '',
      authors: row['authors'] as String? ?? 'Unknown',
      series: row['series'] as String?,
      seriesIndex: (row['series_index'] as num?)?.toDouble(),
      publisher: row['publisher'] as String? ?? '',
      tags: parseList(row['tags_json'] as String?),
      rating: row['rating'] as int?,
      languages: parseList(row['languages_json'] as String?),
      comments: row['comments'] as String? ?? '',
      isbn: row['isbn'] as String? ?? '',
      uuid: row['uuid'] as String?,
      hasCover: (row['has_cover'] as int? ?? 0) == 1,
      lastModified:
          row['last_modified'] != null
              ? DateTime.tryParse(row['last_modified'] as String)
              : null,
      formats: parseFormats(row['formats_json'] as String?),
      cover: coverFileId == null
          ? null
          : GDriveFileRef(localPath: '', filename: 'cover.jpg', fileId: coverFileId),
    );
  }

  Future<List<GDriveBookModel>> queryBooks({
    int offset = 0,
    int limit = 50,
    String? search,
    String sortBy = 'title',
    String sortOrder = 'asc',
    String? filterTag,
    String? filterAuthor,
    String? filterSeries,
  }) async {
    final db = await _openDb();

    final where = <String>[];
    final whereArgs = <Object?>[];

    if (search != null && search.trim().isNotEmpty) {
      where.add('(title LIKE ? OR authors LIKE ? OR series LIKE ?)');
      final like = '%${search.trim()}%';
      whereArgs.addAll([like, like, like]);
    }
    if (filterAuthor != null && filterAuthor.isNotEmpty) {
      where.add('authors LIKE ?');
      whereArgs.add('%$filterAuthor%');
    }
    if (filterSeries != null && filterSeries.isNotEmpty) {
      where.add('series = ?');
      whereArgs.add(filterSeries);
    }
    if (filterTag != null && filterTag.isNotEmpty) {
      where.add('tags_json LIKE ?');
      whereArgs.add('%"$filterTag"%');
    }

    final orderColumn = switch (sortBy) {
      'authors' || 'author' => 'author_sort',
      'series' => 'series',
      'added' || 'timestamp' || 'last_modified' => 'last_modified',
      _ => 'sort',
    };
    final direction = sortOrder.toLowerCase() == 'desc' ? 'DESC' : 'ASC';

    final rows = await db.query(
      'books',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: '$orderColumn COLLATE NOCASE $direction',
      limit: limit,
      offset: offset,
    );

    return rows.map(_rowToBook).toList();
  }

  Future<int> countBooks({String? search}) async {
    final db = await _openDb();
    if (search != null && search.trim().isNotEmpty) {
      final like = '%${search.trim()}%';
      final rows = await db.rawQuery(
        'SELECT COUNT(*) as c FROM books WHERE title LIKE ? OR authors LIKE ? OR series LIKE ?',
        [like, like, like],
      );
      return Sqflite.firstIntValue(rows) ?? 0;
    }
    final rows = await db.rawQuery('SELECT COUNT(*) as c FROM books');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<GDriveBookModel?> getBookById(int id) async {
    final db = await _openDb();
    final rows = await db.query(
      'books',
      where: 'book_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToBook(rows.first);
  }

  Future<List<String>> listTags() async {
    final db = await _openDb();
    final rows = await db.query('books', columns: ['tags_json']);
    final tags = <String>{};
    for (final row in rows) {
      final raw = row['tags_json'] as String?;
      if (raw == null || raw.isEmpty) continue;
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        tags.addAll(decoded.map((e) => e.toString()));
      }
    }
    final list = tags.toList()..sort();
    return list;
  }

  Future<List<String>> listAuthors() async {
    final db = await _openDb();
    final rows = await db.query(
      'books',
      columns: ['authors'],
      distinct: true,
    );
    final authors = <String>{};
    for (final row in rows) {
      final raw = row['authors'] as String?;
      if (raw == null || raw.isEmpty) continue;
      authors.addAll(raw.split(' & ').map((e) => e.trim()));
    }
    final list = authors.toList()..sort();
    return list;
  }

  Future<List<String>> listSeries() async {
    final db = await _openDb();
    final rows = await db.query(
      'books',
      columns: ['series'],
      distinct: true,
      where: 'series IS NOT NULL AND series != ""',
    );
    final series = rows.map((r) => r['series'] as String).toSet().toList()..sort();
    return series;
  }
}
