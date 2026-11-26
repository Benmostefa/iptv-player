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

    // 2. Script PowerShell (fenêtre cachée) : attend la fermeture de
    //    l'appli (et la force au bout de 8 s), remplace les fichiers, relance.
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final exePath = Platform.resolvedExecutable;
    String q(String v) => v.replaceAll("'", "''"); // échappement PowerShell
    final script = '''
\$ErrorActionPreference = 'SilentlyContinue'
\$log = '${q(tempDir.path)}\\update.log'
"Début \$(Get-Date)" | Out-File \$log
Wait-Process -Id $pid -Timeout 8
Stop-Process -Id $pid -Force
Start-Sleep -Seconds 1
Expand-Archive -LiteralPath '${q(zipPath)}' -DestinationPath '${q(extractDir)}' -Force
for (\$i = 0; \$i -lt 10; \$i++) {
  try {
    Copy-Item -Path '${q(extractDir)}\\*' -Destination '${q(appDir)}' -Recurse -Force -ErrorAction Stop
    "Copie OK" | Out-File \$log -Append
    break
  } catch {
    "Essai \$i : \$_" | Out-File \$log -Append
    Start-Sleep -Seconds 1
  }
}
Start-Process -FilePath '${q(exePath)}' -WorkingDirectory '${q(appDir)}'
''';
    final scriptFile = File('${tempDir.path}\\update.ps1');
    // BOM UTF-8 pour que PowerShell lise bien les accents des chemins.
    await scriptFile.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(script)]);

    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        scriptFile.path,
      ],
      mode: ProcessStartMode.detached,
    );

    // 3. Ferme l'application pour libérer les fichiers.
    exit(0);
  }
}
