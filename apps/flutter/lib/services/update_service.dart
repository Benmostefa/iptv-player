import 'dart:convert';
import 'dart:io';

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

  /// Télécharge la mise à jour, puis ferme l'application : un petit script
  /// remplace les fichiers et relance la nouvelle version.
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
    final extractDir = '${tempDir.path}\\files';

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

    // 2. Script qui attend la fermeture de l'appli, remplace et relance.
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final exeName = Platform.resolvedExecutable.split('\\').last;
    final script = '''
@echo off
chcp 65001 >nul
:wait
tasklist /FI "PID eq $pid" 2>nul | find "$pid" >nul
if not errorlevel 1 (
  timeout /t 1 /nobreak >nul
  goto wait
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '$zipPath' -DestinationPath '$extractDir' -Force"
robocopy "$extractDir" "$appDir" /E /R:5 /W:1 /NFL /NDL /NJH /NJS /NP >nul
start "" "$appDir\\$exeName"
''';
    final scriptFile = File('${tempDir.path}\\update.bat');
    await scriptFile.writeAsString(script.replaceAll('\n', '\r\n'));

    await Process.start(
      'cmd',
      ['/c', scriptFile.path],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );

    // 3. Ferme l'application pour libérer les fichiers.
    exit(0);
  }
}
