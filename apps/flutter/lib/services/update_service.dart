import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

/// Une version publiée sur GitHub (onglet "Releases" de ta copie).
class AppUpdate {
  final int build;
  final String name;
  final String notes;
  final String downloadUrl;
  final int sizeBytes;

  AppUpdate({
    required this.build,
    required this.name,
    required this.notes,
    required this.downloadUrl,
    required this.sizeBytes,
  });
}

/// Mise à jour automatique (Windows) depuis les "Releases" GitHub.
///
/// Le numéro de version et le dépôt sont injectés à la compilation par le
/// script GitHub Actions (--dart-define=APP_BUILD / UPDATE_REPO).
class UpdateService {
  UpdateService._();

  static const int currentBuild = int.fromEnvironment('APP_BUILD');
  static const String repo = String.fromEnvironment('UPDATE_REPO');
  static const String _assetName = 'iptv-player-windows.zip';

  static bool get isSupported => Platform.isWindows && repo.isNotEmpty;

  static String get currentLabel =>
      currentBuild > 0 ? 'Version $currentBuild' : 'Version d\'origine';

  /// Renvoie la mise à jour disponible, ou null si l'application est à jour.
  /// Lance une exception si GitHub ne répond pas.
  static Future<AppUpdate?> checkForUpdate() async {
    if (!isSupported) return null;
    final res = await http.get(
      Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 15));

    if (res.statusCode == 404) return null; // aucune version publiée
    if (res.statusCode != 200) {
      throw Exception('GitHub a répondu ${res.statusCode}');
    }

    final data = json.decode(res.body) as Map<String, dynamic>;
    final tag = (data['tag_name'] ?? '') as String;
    final build = int.tryParse(tag.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    if (build <= currentBuild) return null;

    final assets = (data['assets'] as List? ?? []).whereType<Map>();
    final asset = assets.firstWhere(
      (a) => a['name'] == _assetName,
      orElse: () => const {},
    );
    final url = asset['browser_download_url'];
    if (url is! String) return null;

    return AppUpdate(
      build: build,
      name: (data['name'] ?? 'Version $build') as String,
      notes: (data['body'] ?? '') as String,
      downloadUrl: url,
      sizeBytes: (asset['size'] as num?)?.toInt() ?? 0,
    );
  }

  /// Supprime les fichiers ".old" laissés par une mise à jour précédente.
  static Future<void> cleanupOldFiles() async {
    if (!Platform.isWindows) return;
    try {
      final dir = File(Platform.resolvedExecutable).parent;
      await for (final f in dir.list(recursive: true)) {
        if (f is File && f.path.endsWith('.old')) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Télécharge la mise à jour, remplace les fichiers, relance l'appli.
  static Future<void> downloadAndInstall(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    final tempDir = Directory(
      '${Directory.systemTemp.path}\\iptv_player_update',
    );
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
    await tempDir.create(recursive: true);

    final zipPath = '${tempDir.path}\\update.zip';

    // 1. Téléchargement avec progression.
    final client = http.Client();
    try {
      final response = await client.send(
        http.Request('GET', Uri.parse(update.downloadUrl)),
      );
      if (response.statusCode != 200) {
        throw Exception('Téléchargement impossible (${response.statusCode})');
      }
      final total = response.contentLength ?? update.sizeBytes;
      var received = 0;
      final sink = File(zipPath).openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();
    } finally {
      client.close();
    }

    // 2. Installation par l'application elle-même (sans programme externe,
    //    que Windows peut bloquer) : Windows permet de RENOMMER un fichier en
    //    cours d'utilisation ; on renomme l'ancien en ".old" puis on écrit le
    //    nouveau à sa place. Les ".old" sont supprimés au prochain démarrage.
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final stamp = DateTime.now().millisecondsSinceEpoch;

    // Garde la trace pour tout remettre comme avant en cas d'erreur.
    final renamed = <(String original, String backup)>[];
    final written = <String>[];
    try {
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final rel = entry.name.replaceAll('/', '\\');
        final target = File('$appDir\\$rel');
        await target.parent.create(recursive: true);
        if (await target.exists()) {
          final backup = '${target.path}.$stamp.old';
          await target.rename(backup);
          renamed.add((target.path, backup));
        }
        await target.writeAsBytes(entry.content as List<int>, flush: true);
        written.add(target.path);
      }
    } catch (e) {
      for (final path in written) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      for (final r in renamed.reversed) {
        try {
          await File(r.$2).rename(r.$1);
        } catch (_) {}
      }
      throw Exception('Installation impossible : $e');
    }

    // 3. Relance la nouvelle version puis ferme celle-ci.
    try {
      await Process.start(
        Platform.resolvedExecutable,
        const [],
        workingDirectory: appDir,
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      // Si Windows refuse, l'utilisateur relance l'appli lui-même.
    }
    await Future.delayed(const Duration(milliseconds: 300));
    exit(0);
  }
}
