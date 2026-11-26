import 'package:another_iptv_player/services/update_service.dart';
import 'package:flutter/material.dart';

/// Vérifie s'il existe une nouvelle version et propose de l'installer.
/// [silent] : ne rien afficher si l'appli est à jour ou en cas d'erreur
/// (utilisé pour la vérification automatique au démarrage).
Future<void> checkForUpdates(BuildContext context, {bool silent = false}) async {
  if (!UpdateService.isSupported) {
    if (!silent) {
      _snack(context, 'Mise à jour automatique disponible seulement sur Windows.');
    }
    return;
  }

  AppUpdate? update;
  try {
    update = await UpdateService.checkForUpdate();
  } catch (e) {
    if (!silent && context.mounted) {
      _snack(context, 'Impossible de vérifier les mises à jour : $e');
    }
    return;
  }
  if (!context.mounted) return;

  if (update == null) {
    if (!silent) {
      _snack(context, 'Tu as déjà la dernière version (${UpdateService.currentLabel}).');
    }
    return;
  }

  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(update: update!),
  );
}

bool _checkedThisLaunch = false;

/// Vérification discrète, une seule fois par lancement de l'application.
void checkForUpdatesOnce(BuildContext context) {
  if (_checkedThisLaunch) return;
  _checkedThisLaunch = true;
  Future.delayed(const Duration(seconds: 3), () {
    if (context.mounted) checkForUpdates(context, silent: true);
  });
}

void _snack(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

class _UpdateDialog extends StatefulWidget {
  final AppUpdate update;
  const _UpdateDialog({required this.update});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _downloading = false;
  double _progress = 0;
  String? _error;

  Future<void> _install() async {
    setState(() {
      _downloading = true;
      _error = null;
    });
    try {
      await UpdateService.downloadAndInstall(
        widget.update,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = 'Échec : $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.update;
    final sizeMb = u.sizeBytes > 0 ? ' · ${(u.sizeBytes / 1048576).toStringAsFixed(0)} Mo' : '';
    return AlertDialog(
      title: const Text('Nouvelle version disponible'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${u.name}$sizeMb'),
            Text(
              'Installée : ${UpdateService.currentLabel}',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            if (u.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(u.notes.trim(), style: const TextStyle(fontSize: 13)),
            ],
            const SizedBox(height: 16),
            if (_downloading) ...[
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              const SizedBox(height: 8),
              Text(
                _progress >= 1
                    ? 'Installation… l\'application va redémarrer.'
                    : 'Téléchargement… ${(_progress * 100).toStringAsFixed(0)} %',
                style: const TextStyle(fontSize: 13),
              ),
            ] else
              const Text(
                'L\'application va se fermer quelques secondes puis se '
                'relancer toute seule. Tes favoris, abonnements et réglages '
                'sont conservés.',
                style: TextStyle(fontSize: 13),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _downloading ? null : () => Navigator.of(context).pop(),
          child: const Text('Plus tard'),
        ),
        FilledButton.icon(
          onPressed: _downloading ? null : _install,
          icon: const Icon(Icons.system_update_alt),
          label: const Text('Mettre à jour'),
        ),
      ],
    );
  }
}
