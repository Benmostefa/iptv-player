import 'dart:convert';

import 'package:another_iptv_player/models/playlist_model.dart';
import 'package:another_iptv_player/services/app_state.dart';
import 'package:another_iptv_player/services/catalog_index.dart';
import 'package:another_iptv_player/services/playlist_service.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// État d'un compte Xtream, lu en direct chez le fournisseur.
class XtreamAccountStatus {
  final bool ok;
  final String? error;
  final String? status;
  final DateTime? expires;
  final int? activeConnections;
  final int? maxConnections;

  XtreamAccountStatus({
    required this.ok,
    this.error,
    this.status,
    this.expires,
    this.activeConnections,
    this.maxConnections,
  });
}

String _cleanUrl(String url) {
  var u = url.trim();
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'http://$u';
  return u;
}

/// Interroge le fournisseur (player_api.php) sans rien enregistrer.
Future<XtreamAccountStatus> checkXtreamAccount(
  String url,
  String username,
  String password,
) async {
  try {
    final uri = Uri.parse('${_cleanUrl(url)}/player_api.php').replace(
      queryParameters: {'username': username, 'password': password},
    );
    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      return XtreamAccountStatus(
        ok: false,
        error: 'Le serveur a répondu ${res.statusCode}',
      );
    }
    final data = json.decode(utf8.decode(res.bodyBytes));
    final info = data is Map ? data['user_info'] : null;
    if (info is! Map || '${info['auth']}' != '1') {
      return XtreamAccountStatus(
        ok: false,
        error: 'Code refusé par le fournisseur (identifiant ou mot de passe faux).',
      );
    }
    final exp = int.tryParse('${info['exp_date']}');
    return XtreamAccountStatus(
      ok: true,
      status: '${info['status'] ?? ''}',
      expires: exp != null && exp > 0
          ? DateTime.fromMillisecondsSinceEpoch(exp * 1000)
          : null,
      activeConnections: int.tryParse('${info['active_cons']}'),
      maxConnections: int.tryParse('${info['max_connections']}'),
    );
  } catch (e) {
    return XtreamAccountStatus(
      ok: false,
      error: 'Pas de réponse du serveur. Vérifie ta connexion internet.',
    );
  }
}

/// Extrait serveur / identifiant / mot de passe d'un lien envoyé par le
/// fournisseur (lien M3U "get.php?username=..&password=.." ou lien de flux).
({String? url, String? username, String? password}) parseProviderLink(
  String text,
) {
  final t = text.trim();
  final uri = Uri.tryParse(t);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return (url: null, username: null, password: null);
  }
  final base = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
  final user = uri.queryParameters['username'];
  final pass = uri.queryParameters['password'];
  if (user != null && pass != null) {
    return (url: base, username: user, password: pass);
  }
  // Format /live/USER/PASS/123.ts ou /movie/USER/PASS/...
  final seg = uri.pathSegments;
  if (seg.length >= 3 && ['live', 'movie', 'series'].contains(seg[0])) {
    return (url: base, username: seg[1], password: seg[2]);
  }
  return (url: base, username: null, password: null);
}

/// Fenêtre "Nouveau code" : on garde le même abonnement (favoris, historique,
/// réglages) et on remplace seulement les identifiants.
/// Renvoie l'abonnement mis à jour, ou null si annulé.
Future<Playlist?> showRenewSubscriptionDialog(
  BuildContext context,
  Playlist playlist,
) {
  return showDialog<Playlist>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _RenewDialog(playlist: playlist),
  );
}

class _RenewDialog extends StatefulWidget {
  final Playlist playlist;
  const _RenewDialog({required this.playlist});

  @override
  State<_RenewDialog> createState() => _RenewDialogState();
}

class _RenewDialogState extends State<_RenewDialog> {
  final _link = TextEditingController();
  late final TextEditingController _user;
  final _pass = TextEditingController();
  late final TextEditingController _url;
  bool _checking = false;
  bool _showServer = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _user = TextEditingController(text: widget.playlist.username ?? '');
    _url = TextEditingController(text: widget.playlist.url ?? '');
  }

  @override
  void dispose() {
    _link.dispose();
    _user.dispose();
    _pass.dispose();
    _url.dispose();
    super.dispose();
  }

  void _onLinkChanged(String text) {
    final parsed = parseProviderLink(text);
    setState(() {
      if (parsed.username != null) _user.text = parsed.username!;
      if (parsed.password != null) _pass.text = parsed.password!;
      if (parsed.url != null &&
          _cleanUrl(parsed.url!) != _cleanUrl(_url.text)) {
        _url.text = parsed.url!;
        _showServer = true; // le serveur a changé : on le montre
      }
    });
  }

  Future<void> _save() async {
    final user = _user.text.trim();
    final pass = _pass.text.trim();
    final url = _cleanUrl(_url.text);
    if (user.isEmpty || pass.isEmpty) {
      setState(() => _error = 'Mets l\'identifiant et le mot de passe reçus.');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });

    final status = await checkXtreamAccount(url, user, pass);
    if (!mounted) return;
    if (!status.ok) {
      setState(() {
        _checking = false;
        _error = status.error;
      });
      return;
    }

    final updated = Playlist(
      id: widget.playlist.id,
      name: widget.playlist.name,
      type: widget.playlist.type,
      url: url,
      username: user,
      password: pass,
      createdAt: widget.playlist.createdAt,
    );
    await PlaylistService.updatePlaylist(updated);
    if (AppState.currentPlaylist?.id == updated.id) {
      AppState.currentPlaylist = updated;
    }
    CatalogIndex.invalidate();
    if (mounted) Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nouveau code d\'abonnement'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Abonnement « ${widget.playlist.name} » : entre juste le code reçu '
              'pour ce mois. Favoris, historique et réglages sont conservés.',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _link,
              onChanged: _onLinkChanged,
              decoration: const InputDecoration(
                labelText: 'Lien reçu (facultatif)',
                hintText: 'Colle ici le lien M3U si on t\'en a envoyé un',
                prefixIcon: Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _user,
              decoration: const InputDecoration(
                labelText: 'Identifiant (username)',
                prefixIcon: Icon(Icons.person),
              ),
            ),
            TextField(
              controller: _pass,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Mot de passe / code',
                prefixIcon: Icon(Icons.key),
              ),
              onSubmitted: (_) => _save(),
            ),
            if (_showServer)
              TextField(
                controller: _url,
                decoration: const InputDecoration(
                  labelText: 'Adresse du serveur',
                  prefixIcon: Icon(Icons.dns),
                ),
              )
            else
              TextButton(
                onPressed: () => setState(() => _showServer = true),
                child: const Text('Le serveur a changé aussi ?'),
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
          onPressed: _checking ? null : () => Navigator.of(context).pop(),
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
              : const Text('OK'),
        ),
      ],
    );
  }
}

/// Carte "Mon abonnement" : état, date d'expiration, appareils connectés
/// en ce moment et bouton pour entrer le nouveau code.
class SubscriptionAccountCard extends StatefulWidget {
  final Playlist playlist;

  /// Appelé après un renouvellement réussi.
  final void Function(Playlist updated)? onRenewed;

  const SubscriptionAccountCard({
    super.key,
    required this.playlist,
    this.onRenewed,
  });

  @override
  State<SubscriptionAccountCard> createState() =>
      _SubscriptionAccountCardState();
}

class _SubscriptionAccountCardState extends State<SubscriptionAccountCard> {
  XtreamAccountStatus? _status;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final p = AppState.currentPlaylist?.id == widget.playlist.id
        ? AppState.currentPlaylist!
        : widget.playlist;
    setState(() => _loading = true);
    final s = await checkXtreamAccount(
      p.url ?? '',
      p.username ?? '',
      p.password ?? '',
    );
    if (mounted) {
      setState(() {
        _status = s;
        _loading = false;
      });
    }
  }

  Future<void> _renew() async {
    final p = AppState.currentPlaylist?.id == widget.playlist.id
        ? AppState.currentPlaylist!
        : widget.playlist;
    final updated = await showRenewSubscriptionDialog(context, p);
    if (updated == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Nouveau code enregistré ✔'),
        backgroundColor: Colors.green,
      ),
    );
    widget.onRenewed?.call(updated);
    _refresh();
  }

  String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final theme = Theme.of(context);

    Widget body;
    if (_loading) {
      body = const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    } else if (s == null || !s.ok) {
      body = ListTile(
        leading: const Icon(Icons.error_outline, color: Colors.orange),
        title: const Text('Abonnement expiré ou code refusé'),
        subtitle: Text(s?.error ?? ''),
      );
    } else {
      final active = s.activeConnections ?? 0;
      final max = s.maxConnections;
      final daysLeft = s.expires?.difference(DateTime.now()).inDays;
      final others = active > 0;
      body = Column(
        children: [
          ListTile(
            leading: Icon(
              Icons.verified,
              color: s.status?.toLowerCase() == 'active'
                  ? Colors.green
                  : Colors.orange,
            ),
            title: Text(
              s.status?.toLowerCase() == 'active'
                  ? 'Abonnement actif'
                  : 'Statut : ${s.status}',
            ),
            subtitle: s.expires == null
                ? null
                : Text(
                    'Expire le ${_date(s.expires!)}'
                    '${daysLeft != null && daysLeft >= 0 ? ' (dans $daysLeft jours)' : ''}',
                  ),
          ),
          ListTile(
            leading: Icon(
              Icons.devices,
              color: others ? Colors.orange : Colors.green,
            ),
            title: Text(
              'Appareils connectés en ce moment : $active'
              '${max != null ? ' / $max autorisé${max > 1 ? 's' : ''}' : ''}',
            ),
            subtitle: Text(
              others
                  ? 'Si tu ne regardes rien sur un autre appareil, quelqu\'un '
                      'd\'autre utilise ton code en ce moment.'
                  : 'Personne n\'utilise ton code en ce moment.',
            ),
            trailing: IconButton(
              tooltip: 'Actualiser',
              icon: const Icon(Icons.refresh),
              onPressed: _refresh,
            ),
          ),
        ],
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                'Mon abonnement · ${widget.playlist.name}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            body,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.icon(
                onPressed: _renew,
                icon: const Icon(Icons.autorenew),
                label: const Text('Nouveau mois : entrer le nouveau code'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
