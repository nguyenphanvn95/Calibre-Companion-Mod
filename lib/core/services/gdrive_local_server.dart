import 'dart:async';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'package:calibre_web_companion/core/services/gdrive_public_file_service.dart';
import 'package:calibre_web_companion/features/gdrive_library/data/local/gdrive_library_cache.dart';
import 'package:calibre_web_companion/features/gdrive_library/data/models/gdrive_book_model.dart';

/// An embedded HTTP server (`http://127.0.0.1:<port>`) that speaks just
/// enough OPDS (Atom feed + cover + download routes) to be indistinguishable,
/// from the rest of the app's point of view, from a real `server_type ==
/// 'opds'` server.
///
/// This is the core trick that lets `gdrive_json` reuse `book_view`,
/// `book_details`, and `BookCoverWidget` almost unmodified: those already
/// know how to talk to an OPDS server, so instead of teaching them a new
/// protocol, this class *is* that protocol, backed by a local SQLite cache
/// (`GDriveLibraryCache`) built from a `metadata_public.json` file, and it
/// streams actual book/cover bytes from Google Drive on demand
/// (`GDrivePublicFileService`).
class GDriveLocalServer {
  static final GDriveLocalServer _instance = GDriveLocalServer._internal();
  factory GDriveLocalServer() => _instance;
  GDriveLocalServer._internal();

  final Logger _logger = Logger();

  HttpServer? _httpServer;
  GDriveLibraryCache? _cache;
  GDrivePublicFileService? _fileService;
  String? _driveFileId;

  bool get isRunning => _httpServer != null;
  int? get port => _httpServer?.port;
  String get baseUrl => 'http://127.0.0.1:${port ?? 0}';
  String? get currentDriveFileId => _driveFileId;

  /// Starts (or reuses) the local server for the given Drive file id.
  ///
  /// If the server is already running for the same file id and
  /// [forceRefresh] is false, this is a no-op and just returns the current
  /// port. Otherwise it (re)downloads `metadata_public.json`, rebuilds the
  /// SQLite cache, and (re)binds the HTTP server to a fresh OS-assigned port.
  Future<int> start({
    required String driveFileId,
    bool forceRefresh = false,
  }) async {
    final cleanId = GDrivePublicFileService.extractFileId(driveFileId);
    if (cleanId == null || cleanId.isEmpty) {
      throw GDriveFileException(
        GDriveFileErrorType.invalidFileId,
        'That doesn\'t look like a Google Drive file id or share link.',
      );
    }

    if (isRunning && _driveFileId == cleanId && !forceRefresh) {
      return port!;
    }

    _fileService ??= GDrivePublicFileService();
    _cache ??= GDriveLibraryCache();

    final needsResync =
        forceRefresh || await _cache!.needsResync(cleanId);

    if (needsResync) {
      _logger.i('Downloading metadata_public.json (file id: $cleanId)...');
      final raw = await _fileService!.downloadJsonById(cleanId);
      await _cache!.rebuildFromJson(raw, sourceFileId: cleanId);
    } else {
      _logger.i('Reusing cached GDrive library for file id: $cleanId');
    }

    _driveFileId = cleanId;

    await _bindServer();
    return port!;
  }

  Future<void> _bindServer() async {
    // Rebind is needed even when reusing the cache, since the OS-assigned
    // port from a previous app run is gone by the time the app restarts.
    await _closeHttpServer();

    final router = Router();
    router.get('/', _handleFeed);
    router.get('/opds/cover/<bookId>', _handleCover);
    router.get('/<bookId>/download', _handleDownload);
    router.get('/opds/download/<bookId>/<format>', _handleDownloadWithFormat);

    final handler = const Pipeline().addHandler(router.call);

    _httpServer = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0, // let the OS pick a free port
    );
    _logger.i('GDrive local server listening on $baseUrl');
  }

  /// Re-downloads the JSON and rebuilds the cache for the currently
  /// configured source (used by a "Refresh library" action).
  Future<void> refresh() async {
    final id = _driveFileId;
    if (id == null) {
      throw StateError('GDriveLocalServer has not been started yet.');
    }
    await start(driveFileId: id, forceRefresh: true);
  }

  Future<void> _closeHttpServer() async {
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  /// Stops the server and releases the port/DB handle. Call on logout or
  /// when switching to a different server type.
  Future<void> stop() async {
    await _closeHttpServer();
    await _cache?.close();
    _cache = null;
    _fileService?.dispose();
    _fileService = null;
    _driveFileId = null;
  }

  // ---------------------------------------------------------------------
  // Route handlers
  // ---------------------------------------------------------------------

  Future<Response> _handleFeed(Request request) async {
    final cache = _cache;
    if (cache == null) return Response.internalServerError(body: 'Not ready');

    final params = request.url.queryParameters;
    final search = params['search'];
    final offset = int.tryParse(params['offset'] ?? '') ?? 0;
    final limit = int.tryParse(params['limit'] ?? '') ?? 500;
    final sort = params['sort'] ?? 'title';
    final order = params['order'] ?? 'asc';

    final books = await cache.queryBooks(
      offset: offset,
      limit: limit,
      search: search,
      sortBy: sort,
      sortOrder: order,
    );

    final xml = _buildAtomFeed(books);
    return Response.ok(
      xml,
      headers: {'content-type': 'application/atom+xml; charset=utf-8'},
    );
  }

  Future<Response> _handleCover(Request request, String bookId) async {
    final cache = _cache;
    final fileService = _fileService;
    if (cache == null || fileService == null) {
      return Response.internalServerError(body: 'Not ready');
    }

    final id = int.tryParse(bookId);
    if (id == null) return Response.notFound('Invalid book id');

    final book = await cache.getBookById(id);
    final fileId = book?.coverFileId;
    if (fileId == null) return Response.notFound('No cover for book $bookId');

    return _proxyDriveFile(fileService, fileId, defaultContentType: 'image/jpeg');
  }

  Future<Response> _handleDownload(Request request, String bookId) async {
    final cache = _cache;
    final fileService = _fileService;
    if (cache == null || fileService == null) {
      return Response.internalServerError(body: 'Not ready');
    }

    final id = int.tryParse(bookId);
    if (id == null) return Response.notFound('Invalid book id');

    final book = await cache.getBookById(id);
    if (book == null) return Response.notFound('Book $bookId not found');

    final fileId = book.primaryEbookFileId ?? book.primaryAudioFileId;
    if (fileId == null) {
      return Response.notFound('Book $bookId has no downloadable file');
    }

    return _proxyDriveFile(
      fileService,
      fileId,
      defaultContentType: 'application/octet-stream',
    );
  }

  Future<Response> _handleDownloadWithFormat(
    Request request,
    String bookId,
    String format,
  ) async {
    final cache = _cache;
    final fileService = _fileService;
    if (cache == null || fileService == null) {
      return Response.internalServerError(body: 'Not ready');
    }

    final id = int.tryParse(bookId);
    if (id == null) return Response.notFound('Invalid book id');

    final book = await cache.getBookById(id);
    if (book == null) return Response.notFound('Book $bookId not found');

    final ref = book.formats[format.toUpperCase()];
    if (ref == null) {
      return Response.notFound('Book $bookId has no $format file');
    }

    return _proxyDriveFile(
      fileService,
      ref.fileId,
      defaultContentType: _mimeForFormatCode(format.toUpperCase()),
      filename: ref.filename,
    );
  }

  Future<Response> _proxyDriveFile(
    GDrivePublicFileService fileService,
    String fileId, {
    required String defaultContentType,
    String? filename,
  }) async {
    try {
      final streamed = await fileService.openStream(fileId);
      final headers = <String, String>{
        'content-type':
            streamed.headers['content-type'] ?? defaultContentType,
      };
      if (filename != null && filename.isNotEmpty) {
        headers['content-disposition'] = 'attachment; filename="$filename"';
      }
      if (streamed.contentLength != null) {
        headers['content-length'] = streamed.contentLength.toString();
      }
      return Response(
        streamed.statusCode,
        body: streamed.stream,
        headers: headers,
      );
    } on GDriveFileException catch (e) {
      _logger.w('Drive proxy failed for $fileId: ${e.message}');
      return Response.internalServerError(body: e.message);
    } catch (e) {
      _logger.e('Drive proxy failed for $fileId: $e');
      return Response.internalServerError(body: 'Failed to stream file');
    }
  }

  // ---------------------------------------------------------------------
  // Atom feed rendering
  // ---------------------------------------------------------------------

  static const Map<String, String> _formatMimeTypes = {
    'EPUB': 'application/epub+zip',
    'PDF': 'application/pdf',
    'MOBI': 'application/x-mobipocket-ebook',
    'AZW3': 'application/vnd.amazon.mobi8-ebook',
    'FB2': 'application/fb2',
    'CBZ': 'application/vnd.comicbook+zip',
    'CBR': 'application/vnd.comicbook-rar',
    'TXT': 'text/plain',
  };

  String _mimeForFormatCode(String code) =>
      _formatMimeTypes[code.toUpperCase()] ?? 'application/octet-stream';

  String _buildAtomFeed(List<GDriveBookModel> books) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln(
      '<feed xmlns="http://www.w3.org/2005/Atom" '
      'xmlns:opds="http://opds-spec.org/2010/catalog">',
    );
    buffer.writeln('<id>urn:gdrive-json:library</id>');
    buffer.writeln('<title>${_escape('GDrive JSON Library')}</title>');
    buffer.writeln(
      '<updated>${DateTime.now().toUtc().toIso8601String()}</updated>',
    );

    for (final book in books) {
      buffer.write(_buildEntry(book));
    }

    buffer.writeln('</feed>');
    return buffer.toString();
  }

  String _buildEntry(GDriveBookModel book) {
    final buffer = StringBuffer();
    buffer.writeln('<entry>');
    buffer.writeln('<title>${_escape(book.title)}</title>');
    buffer.writeln('<id>urn:uuid:${book.bookId}</id>');
    buffer.writeln(
      '<author><name>${_escape(book.authors)}</name></author>',
    );

    final published = book.pubdate ?? book.timestamp;
    if (published != null) {
      buffer.writeln(
        '<published>${published.toUtc().toIso8601String()}</published>',
      );
    }
    final updated = book.lastModified ?? published ?? DateTime.now();
    buffer.writeln('<updated>${updated.toUtc().toIso8601String()}</updated>');

    for (final tag in book.tags) {
      buffer.writeln(
        '<category term="${_escapeAttr(tag)}" label="${_escapeAttr(tag)}"/>',
      );
    }

    if (book.comments.isNotEmpty) {
      buffer.writeln(
        '<content type="text">${_cdata(book.comments)}</content>',
      );
    }

    if (book.hasCover && book.coverFileId != null) {
      buffer.writeln(
        '<link rel="http://opds-spec.org/image" '
        'href="/opds/cover/${book.bookId}" type="image/jpeg"/>',
      );
      buffer.writeln(
        '<link rel="http://opds-spec.org/image/thumbnail" '
        'href="/opds/cover/${book.bookId}" type="image/jpeg"/>',
      );
    }

    // Only the primary file is exposed here: the app's download call
    // (`GET /{bookId}/download`) always fetches whichever file this feed
    // marked as primary, so advertising other formats we can't actually
    // serve under a distinct request would just produce a filename/content
    // mismatch. See gdrive_local_server.dart notes.
    final primaryFormat = _primaryFormatCode(book);
    if (primaryFormat != null) {
      buffer.writeln(
        '<link rel="http://opds-spec.org/acquisition" '
        'href="/${book.bookId}/download" '
        'type="${_mimeForFormatCode(primaryFormat)}"/>',
      );
    }

    buffer.writeln('</entry>');
    return buffer.toString();
  }

  String? _primaryFormatCode(GDriveBookModel book) {
    for (final code in kGDriveEbookFormatPriority) {
      if (book.formats.containsKey(code)) return code;
    }
    for (final code in kGDriveAudioFormatPriority) {
      if (book.formats.containsKey(code)) return code;
    }
    return book.formats.keys.isEmpty ? null : book.formats.keys.first;
  }

  String _escape(String input) => input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  String _escapeAttr(String input) =>
      _escape(input).replaceAll('"', '&quot;');

  /// Wraps text in a CDATA section, escaping any literal `]]>` sequence
  /// (which would otherwise prematurely terminate the section).
  String _cdata(String input) =>
      '<![CDATA[${input.replaceAll(']]>', ']]]]><![CDATA[>')}]]>';
}
