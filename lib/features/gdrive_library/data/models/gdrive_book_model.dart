import 'package:equatable/equatable.dart';

/// A single referenced file inside `metadata_public.json`
/// (a format, the cover, an extra file, or the metadata.opf), each of which
/// is just a pointer to a Google Drive file id.
class GDriveFileRef extends Equatable {
  final String localPath;
  final String filename;
  final String fileId;

  const GDriveFileRef({
    required this.localPath,
    required this.filename,
    required this.fileId,
  });

  static GDriveFileRef? tryParse(dynamic json) {
    if (json is! Map) return null;
    final fileId = json['file_id']?.toString();
    if (fileId == null || fileId.isEmpty) return null;
    return GDriveFileRef(
      localPath: json['local_path']?.toString() ?? '',
      filename: json['filename']?.toString() ?? '',
      fileId: fileId,
    );
  }

  Map<String, dynamic> toJson() => {
    'local_path': localPath,
    'filename': filename,
    'file_id': fileId,
  };

  factory GDriveFileRef.fromJson(Map<String, dynamic> json) => GDriveFileRef(
    localPath: json['local_path']?.toString() ?? '',
    filename: json['filename']?.toString() ?? '',
    fileId: json['file_id']?.toString() ?? '',
  );

  @override
  List<Object?> get props => [localPath, filename, fileId];
}

/// Known audiobook format codes. Kept as a constant so it's easy to extend
/// if a library exports additional audio containers.
const Set<String> kGDriveAudioFormatCodes = {
  'MP3',
  'M4A',
  'M4B',
  'AAC',
  'OGG',
  'FLAC',
};

/// Preference order used to pick a "primary" file when a book has more than
/// one file of a kind (e.g. both EPUB and MOBI).
const List<String> kGDriveEbookFormatPriority = [
  'EPUB',
  'AZW3',
  'MOBI',
  'PDF',
  'FB2',
  'TXT',
];

const List<String> kGDriveAudioFormatPriority = [
  'M4B',
  'MP3',
  'M4A',
  'AAC',
  'OGG',
  'FLAC',
];

/// Parses a single entry from the `books` object of a `metadata_public.json`
/// file exported by the companion desktop tool (not a real Calibre-Web
/// server). Field names/shape are documented in
/// `codex_prompt_gdrive_json_source.md`.
class GDriveBookModel extends Equatable {
  final int bookId;
  final String title;
  final String sort;
  final String authorSort;

  /// Raw, un-split authors string as stored by Calibre (authors joined by
  /// " & " when there's more than one).
  final String authors;
  final String? series;
  final double? seriesIndex;
  final String publisher;
  final List<String> tags;

  /// Calibre rating scale: 0-10 in steps of 2 (i.e. half-star granularity).
  final int? rating;
  final List<String> languages;
  final Map<String, String> identifiers;
  final String comments;
  final String isbn;
  final String? uuid;
  final bool hasCover;
  final DateTime? pubdate;
  final DateTime? timestamp;
  final DateTime? lastModified;
  final String bookFolder;

  /// Format code (e.g. "EPUB", "MP3") -> file reference. This is the single
  /// source of truth for both ebook and audiobook files - there is no
  /// separate "type" field upstream.
  final Map<String, GDriveFileRef> formats;
  final Map<String, GDriveFileRef> extraFiles;
  final GDriveFileRef? cover;
  final GDriveFileRef? metadataOpf;

  const GDriveBookModel({
    required this.bookId,
    required this.title,
    required this.sort,
    required this.authorSort,
    required this.authors,
    this.series,
    this.seriesIndex,
    this.publisher = '',
    this.tags = const [],
    this.rating,
    this.languages = const [],
    this.identifiers = const {},
    this.comments = '',
    this.isbn = '',
    this.uuid,
    this.hasCover = false,
    this.pubdate,
    this.timestamp,
    this.lastModified,
    this.bookFolder = '',
    this.formats = const {},
    this.extraFiles = const {},
    this.cover,
    this.metadataOpf,
  });

  /// The upstream schema stores dates as `YYYY-MM-DD HH:mm:ss+00:00`, which
  /// is not directly accepted by `DateTime.parse` (no `T` separator).
  static DateTime? _parseCalibreDate(dynamic value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    if (raw.isEmpty || raw.toLowerCase() == 'none' || raw.toLowerCase() == 'null') {
      return null;
    }
    // Normalize "YYYY-MM-DD HH:mm:ss+00:00" -> "YYYY-MM-DDTHH:mm:ss+00:00"
    final normalized = raw.contains('T') ? raw : raw.replaceFirst(' ', 'T');
    return DateTime.tryParse(normalized);
  }

  static List<String> _stringList(dynamic value) {
    if (value is List) return value.map((e) => e.toString()).toList();
    if (value is String && value.isNotEmpty) return [value];
    return const [];
  }

  static Map<String, String> _stringMap(dynamic value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
    }
    return const {};
  }

  static Map<String, GDriveFileRef> _fileRefMap(dynamic value) {
    if (value is! Map) return const {};
    final result = <String, GDriveFileRef>{};
    value.forEach((key, v) {
      final ref = GDriveFileRef.tryParse(v);
      if (ref != null) result[key.toString().toUpperCase()] = ref;
    });
    return result;
  }

  factory GDriveBookModel.fromJson(String bookIdKey, Map<String, dynamic> json) {
    final idFromKey = int.tryParse(bookIdKey);
    final idFromField =
        json['book_id'] is num
            ? (json['book_id'] as num).toInt()
            : int.tryParse(json['book_id']?.toString() ?? '');

    return GDriveBookModel(
      bookId: idFromField ?? idFromKey ?? 0,
      title: json['title']?.toString() ?? 'Unknown Title',
      sort: json['sort']?.toString() ?? '',
      authorSort: json['author_sort']?.toString() ?? '',
      authors: json['authors']?.toString() ?? 'Unknown',
      series: (json['series']?.toString().isNotEmpty ?? false)
          ? json['series'].toString()
          : null,
      seriesIndex:
          json['series_index'] == null
              ? null
              : double.tryParse(json['series_index'].toString()),
      publisher: json['publisher']?.toString() ?? '',
      tags: _stringList(json['tags']),
      rating: json['rating'] == null ? null : int.tryParse(json['rating'].toString()),
      languages: _stringList(json['languages']),
      identifiers: _stringMap(json['identifiers']),
      comments: json['comments']?.toString() ?? '',
      isbn: json['isbn']?.toString() ?? '',
      uuid: json['uuid']?.toString(),
      hasCover: json['has_cover'] == true,
      pubdate: _parseCalibreDate(json['pubdate']),
      timestamp: _parseCalibreDate(json['timestamp']),
      lastModified: _parseCalibreDate(json['last_modified']),
      bookFolder: json['book_folder']?.toString() ?? '',
      formats: _fileRefMap(json['formats']),
      extraFiles: _fileRefMap(json['extra_files']),
      cover: GDriveFileRef.tryParse(json['cover']),
      metadataOpf: GDriveFileRef.tryParse(json['metadata_opf']),
    );
  }

  /// Authors split on Calibre's " & " joiner, for display/filtering.
  List<String> get authorList =>
      authors.split(' & ').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  List<String> get formatCodes => formats.keys.toList();

  bool get isAudiobook =>
      formats.keys.any((code) => kGDriveAudioFormatCodes.contains(code));

  String? get primaryEbookFileId {
    for (final code in kGDriveEbookFormatPriority) {
      final ref = formats[code];
      if (ref != null) return ref.fileId;
    }
    // Fall back to any non-audio format if none of the known codes matched.
    for (final entry in formats.entries) {
      if (!kGDriveAudioFormatCodes.contains(entry.key)) return entry.value.fileId;
    }
    return null;
  }

  String? get primaryAudioFileId {
    for (final code in kGDriveAudioFormatPriority) {
      final ref = formats[code];
      if (ref != null) return ref.fileId;
    }
    return null;
  }

  String? get coverFileId => cover?.fileId;

  /// Star rating out of 5 (Calibre stores 0-10 in half-star steps).
  double? get starRating => rating == null ? null : rating! / 2.0;

  Map<String, dynamic> toCacheJson() => {
    'book_id': bookId,
    'title': title,
    'sort': sort,
    'author_sort': authorSort,
    'authors': authors,
    'series': series,
    'series_index': seriesIndex,
    'publisher': publisher,
    'tags': tags,
    'rating': rating,
    'languages': languages,
    'identifiers': identifiers,
    'comments': comments,
    'isbn': isbn,
    'uuid': uuid,
    'has_cover': hasCover,
    'pubdate': pubdate?.toIso8601String(),
    'timestamp': timestamp?.toIso8601String(),
    'last_modified': lastModified?.toIso8601String(),
    'book_folder': bookFolder,
    'formats': formats.map((k, v) => MapEntry(k, v.toJson())),
    'extra_files': extraFiles.map((k, v) => MapEntry(k, v.toJson())),
    'cover': cover?.toJson(),
    'metadata_opf': metadataOpf?.toJson(),
  };

  factory GDriveBookModel.fromCacheJson(Map<String, dynamic> json) {
    Map<String, GDriveFileRef> refMap(dynamic value) {
      if (value is! Map) return const {};
      final result = <String, GDriveFileRef>{};
      value.forEach((k, v) {
        if (v is Map) {
          result[k.toString()] = GDriveFileRef.fromJson(
            Map<String, dynamic>.from(v),
          );
        }
      });
      return result;
    }

    return GDriveBookModel(
      bookId: json['book_id'] as int? ?? 0,
      title: json['title']?.toString() ?? 'Unknown Title',
      sort: json['sort']?.toString() ?? '',
      authorSort: json['author_sort']?.toString() ?? '',
      authors: json['authors']?.toString() ?? 'Unknown',
      series: json['series']?.toString(),
      seriesIndex: (json['series_index'] as num?)?.toDouble(),
      publisher: json['publisher']?.toString() ?? '',
      tags: _stringList(json['tags']),
      rating: json['rating'] as int?,
      languages: _stringList(json['languages']),
      identifiers: _stringMap(json['identifiers']),
      comments: json['comments']?.toString() ?? '',
      isbn: json['isbn']?.toString() ?? '',
      uuid: json['uuid']?.toString(),
      hasCover: json['has_cover'] == true,
      pubdate: json['pubdate'] != null ? DateTime.tryParse(json['pubdate']) : null,
      timestamp:
          json['timestamp'] != null ? DateTime.tryParse(json['timestamp']) : null,
      lastModified:
          json['last_modified'] != null
              ? DateTime.tryParse(json['last_modified'])
              : null,
      bookFolder: json['book_folder']?.toString() ?? '',
      formats: refMap(json['formats']),
      extraFiles: refMap(json['extra_files']),
      cover: json['cover'] is Map ? GDriveFileRef.fromJson(Map<String, dynamic>.from(json['cover'])) : null,
      metadataOpf: json['metadata_opf'] is Map
          ? GDriveFileRef.fromJson(Map<String, dynamic>.from(json['metadata_opf']))
          : null,
    );
  }

  @override
  List<Object?> get props => [
    bookId,
    title,
    sort,
    authorSort,
    authors,
    series,
    seriesIndex,
    publisher,
    tags,
    rating,
    languages,
    identifiers,
    comments,
    isbn,
    uuid,
    hasCover,
    pubdate,
    timestamp,
    lastModified,
    bookFolder,
    formats,
    extraFiles,
    cover,
    metadataOpf,
  ];
}

/// The top-level shape of `metadata_public.json`.
class GDriveLibraryIndexModel extends Equatable {
  final String libraryPath;
  final DateTime? generatedAt;
  final String source;
  final String? driveFolderUrl;
  final List<GDriveBookModel> books;

  const GDriveLibraryIndexModel({
    required this.libraryPath,
    required this.generatedAt,
    required this.source,
    required this.driveFolderUrl,
    required this.books,
  });

  factory GDriveLibraryIndexModel.fromJson(Map<String, dynamic> json) {
    final rawBooks = json['books'];
    final books = <GDriveBookModel>[];

    if (rawBooks is Map) {
      rawBooks.forEach((key, value) {
        if (value is Map) {
          books.add(
            GDriveBookModel.fromJson(key.toString(), Map<String, dynamic>.from(value)),
          );
        }
      });
    }

    return GDriveLibraryIndexModel(
      libraryPath: json['library_path']?.toString() ?? '',
      generatedAt: DateTime.tryParse(json['generated_at']?.toString() ?? ''),
      source: json['source']?.toString() ?? '',
      driveFolderUrl: json['drive_folder_url']?.toString(),
      books: books,
    );
  }

  @override
  List<Object?> get props => [libraryPath, generatedAt, source, driveFolderUrl, books];
}
