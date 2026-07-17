import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

/// Reasons a Google Drive public-file request can fail, so the UI can show a
/// specific, actionable message instead of a generic "network error".
enum GDriveFileErrorType {
  invalidFileId,
  notFound,
  notPublic,
  quotaExceeded,
  network,
  unknown,
}

class GDriveFileException implements Exception {
  final GDriveFileErrorType type;
  final String message;

  GDriveFileException(this.type, this.message);

  @override
  String toString() => message;
}

/// Fetches files from Google Drive that have been shared "Anyone with the
/// link", using a restricted API key embedded in the app - the same
/// zero-setup pattern used by the GoogleDriveSync Calibre plugin's public
/// library import (public_api.py): no end-user OAuth flow, read-only access,
/// and the key itself is restricted (HTTP referrer / Android package +
/// SHA-1 + "Google Drive API" scope only) on the Google Cloud Console side,
/// so embedding it client-side carries no write/delete risk.
class GDrivePublicFileService {
  /// Restricted, read-only browser/Android key. Replace with your own key
  /// from Google Cloud Console (APIs & Services -> Credentials), restricted
  /// to the Google Drive API and to this app's package name + SHA-1
  /// signing certificate fingerprint. See the deployment guide for steps.
  static const String _apiKey = String.fromEnvironment(
    'GDRIVE_PUBLIC_API_KEY',
    defaultValue: 'REPLACE_WITH_YOUR_RESTRICTED_DRIVE_API_KEY',
  );

  static const String _driveFilesBase =
      'https://www.googleapis.com/drive/v3/files';

  final Logger _logger;
  final http.Client _client;

  GDrivePublicFileService({Logger? logger, http.Client? client})
    : _logger = logger ?? Logger(),
      _client = client ?? http.Client();

  /// A Drive file id is a URL-safe base64-ish token; Drive share links look
  /// like `.../file/d/<FILE_ID>/view` or `.../open?id=<FILE_ID>`.
  static final RegExp _fileIdPattern = RegExp(r'^[a-zA-Z0-9_-]{10,}$');

  /// Extracts a bare file id from either a raw id or a full Drive share URL.
  static String? extractFileId(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    if (_fileIdPattern.hasMatch(trimmed) && !trimmed.contains('/')) {
      return trimmed;
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;

    final dIndex = uri.pathSegments.indexOf('d');
    if (dIndex != -1 && dIndex + 1 < uri.pathSegments.length) {
      return uri.pathSegments[dIndex + 1];
    }

    final idParam = uri.queryParameters['id'];
    if (idParam != null && _fileIdPattern.hasMatch(idParam)) return idParam;

    return null;
  }

  Uri buildDirectDownloadUri(String fileId) {
    return Uri.parse('$_driveFilesBase/$fileId').replace(
      queryParameters: {'alt': 'media', 'key': _apiKey},
    );
  }

  Uri _metadataUri(String fileId) {
    return Uri.parse('$_driveFilesBase/$fileId').replace(
      queryParameters: {
        'fields': 'id,name,mimeType,size',
        'key': _apiKey,
      },
    );
  }

  Never _throwForStatus(int statusCode, String fileId, String body) {
    switch (statusCode) {
      case 404:
        throw GDriveFileException(
          GDriveFileErrorType.notFound,
          'File not found on Google Drive (id: $fileId). Double-check the '
          'file id / share link.',
        );
      case 403:
        final lower = body.toLowerCase();
        if (lower.contains('quota') || lower.contains('rate')) {
          throw GDriveFileException(
            GDriveFileErrorType.quotaExceeded,
            'Google Drive API quota exceeded. Try again later.',
          );
        }
        throw GDriveFileException(
          GDriveFileErrorType.notPublic,
          'This file is not shared publicly. In Google Drive, set sharing '
          'to "Anyone with the link" for this file (and its parent folder).',
        );
      default:
        throw GDriveFileException(
          GDriveFileErrorType.unknown,
          'Google Drive returned HTTP $statusCode for file $fileId.',
        );
    }
  }

  /// Downloads and returns the raw text content of a public JSON file by its
  /// Drive file id (used for `metadata_public.json`).
  Future<String> downloadJsonById(String fileId) async {
    if (_apiKey == 'REPLACE_WITH_YOUR_RESTRICTED_DRIVE_API_KEY') {
      _logger.w(
        'GDrivePublicFileService is using the placeholder API key - set '
        '--dart-define=GDRIVE_PUBLIC_API_KEY=... at build time.',
      );
    }

    final uri = buildDirectDownloadUri(fileId);
    http.Response response;
    try {
      response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw GDriveFileException(
        GDriveFileErrorType.network,
        'Timed out reaching Google Drive. Check your connection.',
      );
    } catch (e) {
      throw GDriveFileException(
        GDriveFileErrorType.network,
        'Could not reach Google Drive: $e',
      );
    }

    if (response.statusCode != 200) {
      _throwForStatus(response.statusCode, fileId, response.body);
    }

    return utf8.decode(response.bodyBytes);
  }

  /// Fetches basic metadata (name / mime type / size) for a file, useful to
  /// validate a file id before committing to a full download.
  Future<Map<String, dynamic>> fetchMetadata(String fileId) async {
    final uri = _metadataUri(fileId);
    http.Response response;
    try {
      response = await _client.get(uri).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw GDriveFileException(
        GDriveFileErrorType.network,
        'Timed out reaching Google Drive. Check your connection.',
      );
    } catch (e) {
      throw GDriveFileException(
        GDriveFileErrorType.network,
        'Could not reach Google Drive: $e',
      );
    }

    if (response.statusCode != 200) {
      _throwForStatus(response.statusCode, fileId, response.body);
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Opens a streamed GET request to a Drive file so callers (the local
  /// virtual OPDS server) can pipe bytes straight through to the HTTP
  /// response without buffering the whole file in memory.
  Future<http.StreamedResponse> openStream(String fileId, {String? range}) async {
    final uri = buildDirectDownloadUri(fileId);
    final request = http.Request('GET', uri);
    if (range != null) {
      request.headers['Range'] = range;
    }
    try {
      return await _client.send(request).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw GDriveFileException(
        GDriveFileErrorType.network,
        'Timed out starting download from Google Drive.',
      );
    } catch (e) {
      throw GDriveFileException(
        GDriveFileErrorType.network,
        'Could not reach Google Drive: $e',
      );
    }
  }

  void dispose() => _client.close();
}
