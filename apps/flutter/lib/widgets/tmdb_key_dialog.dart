import 'package:another_iptv_player/services/tmdb_service.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Boîte de dialogue pour saisir la clé API TMDB (gratuite).
/// Renvoie true si une clé valide a été enregistrée.
Future<bool> showTmdbKeyDialog(BuildContext context) async {
  final current = await TmdbService.instance.getApiKey();
  if (!context.mounted) return false;
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => _TmdbKeyDialog(initial: current ?? ''),
  );
  return result ?? false;
}

class _TmdbKeyDialog extends StatefulWidget {
  final String initial;
  const _TmdbKeyDialog({required this.initial});

  @override
  State<_TmdbKeyDialog> createState() => _TmdbKeyDialogState();
}

class _TmdbKeyDialogState extends State<_TmdbKeyDialog> {
  late final TextEditingController _controller;
  bool _checking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _controller.text.trim();
    if (key.isEmpty) {
      await TmdbService.instance.setApiKey(null);
      if (mounted) Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    final ok = await TmdbService.instance.testKey(key);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _checking = false;
        _error = 'Clé refusée par TMDB (ou pas de connexion). Vérifie-la.';
      });
      return;
    }
    await TmdbService.instance.setApiKey(key);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Infos films (TMDB)'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Résumés en français, notes, photos des acteurs et recherche '
              'par acteur viennent de The Movie Database (gratuit).\n\n'
              '1. Crée un compte gratuit sur themoviedb.org\n'
              '2. Paramètres → API → demande une clé (usage personnel)\n'
              '3. Colle ici la « Clé d\'API » ou le « Jeton d\'accès en lecture ».',
              style: TextStyle(fontSize: 13),
            ),
            TextButton.icon(
              onPressed: () => launchUrl(
                Uri.parse('https://www.themoviedb.org/settings/api'),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Ouvrir la page TMDB'),
            ),
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                labelText: 'Clé API TMDB',
                errorText: _error,
                errorMaxLines: 2,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _checking ? null : () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _checking ? null : _save,
          child: _checking
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Enregistrer'),
        ),
      ],
    );
  }
}
