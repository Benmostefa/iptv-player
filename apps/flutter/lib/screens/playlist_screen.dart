import 'package:another_iptv_player/l10n/localization_extension.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../controllers/playlist_controller.dart';
import '../../models/playlist_model.dart';
import '../../widgets/playlist_card.dart';
import '../../widgets/playlist_states.dart';
import 'playlist_type_screen.dart';
import 'package:another_iptv_player/services/app_state.dart';
import 'package:another_iptv_player/services/catalog_index.dart';
import 'package:another_iptv_player/widgets/subscription_account_card.dart';

class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key});

  @override
  PlaylistScreenState createState() => PlaylistScreenState();
}

class PlaylistScreenState extends State<PlaylistScreen> {
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => PlaylistController(),
      child: _PlaylistScreenBody(),
    );
  }
}

class _PlaylistScreenBody extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializePlaylistsIfNeeded(context);
    });

    return Scaffold(
      appBar: _buildAppBar(context),
      body: Consumer<PlaylistController>(
        builder: (context, controller, child) =>
            _buildBodyFromState(context, controller),
      ),
      floatingActionButton: _buildFloatingActionButton(context),
    );
  }

  void _initializePlaylistsIfNeeded(BuildContext context) {
    final controller = context.read<PlaylistController>();
    if (!controller.isLoading &&
        controller.playlists.isEmpty &&
        controller.error == null) {
      controller.loadPlaylists(context);
    }
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      title: Text(
        context.loc.my_playlists,
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildBodyFromState(
    BuildContext context,
    PlaylistController controller,
  ) {
    if (controller.isLoading) {
      return const PlaylistLoadingState();
    }

    if (controller.error != null) {
      return PlaylistErrorState(
        error: controller.error!,
        onRetry: () => controller.loadPlaylists(context),
      );
    }

    if (controller.playlists.isEmpty) {
      return PlaylistEmptyState(
        onCreatePlaylist: () => _navigateToCreatePlaylist(context),
      );
    }

    return _buildPlaylistList(context, controller);
  }

  Widget _buildPlaylistList(
    BuildContext context,
    PlaylistController controller,
  ) {
    return RefreshIndicator(
      onRefresh: () => controller.loadPlaylists(context),
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: controller.playlists.length,
        itemBuilder: (context, index) {
          return PlaylistCard(
            playlist: controller.playlists[index],
            onTap: () =>
                controller.openPlaylist(context, controller.playlists[index]),
            onDelete: () => _showDeleteDialog(
              context,
              controller,
              controller.playlists[index],
            ),
            onEdit: () => _showEditDialog(
              context,
              controller,
              controller.playlists[index],
            ),
          );
        },
      ),
    );
  }

  Widget _buildFloatingActionButton(BuildContext context) {
    return FloatingActionButton(
      onPressed: () => _navigateToCreatePlaylist(context),
      tooltip: context.loc.create_new_playlist,
      child: const Icon(Icons.add, color: Colors.white),
    );
  }

  void _navigateToCreatePlaylist(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const PlaylistTypeScreen()),
    );
  }

  void _showDeleteDialog(
    BuildContext context,
    PlaylistController controller,
    Playlist playlist,
  ) {
    showDialog(
      context: context,
      builder: (context) => _DeletePlaylistDialog(
        playlist: playlist,
        onDelete: () async {
          final success = await controller.deletePlaylist(playlist.id);
          if (success && context.mounted) {
            _showSuccessSnackBar(context, playlist.name);
          }
        },
      ),
    );
  }

  Future<void> _showEditDialog(
    BuildContext context,
    PlaylistController controller,
    Playlist playlist,
  ) async {
    if (playlist.type == PlaylistType.xtream) {
      // Nouveau mois : seulement le nouveau code, vérifié chez le fournisseur.
      final updated = await showRenewSubscriptionDialog(context, playlist);
      if (updated != null && context.mounted) {
        await controller.loadPlaylists(context);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Nouveau code enregistré : favoris et historique conservés'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
      return;
    }
    showDialog(
      context: context,
      builder: (dialogContext) => _EditPlaylistDialog(
        playlist: playlist,
        onSave: (updated) async {
          final success = await controller.updatePlaylist(updated);
          if (success) {
            if (AppState.currentPlaylist?.id == updated.id) {
              AppState.currentPlaylist = updated;
            }
            CatalogIndex.invalidate();
          }
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  success
                      ? 'Abonnement mis à jour : favoris et historique conservés'
                      : (controller.error ?? 'Mise à jour impossible'),
                ),
                backgroundColor: success ? Colors.green : Colors.red,
              ),
            );
          }
        },
      ),
    );
  }

  void _showSuccessSnackBar(BuildContext context, String playlistName) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.loc.playlist_deleted(playlistName)),
        backgroundColor: Colors.green,
      ),
    );
  }
}

class _DeletePlaylistDialog extends StatelessWidget {
  final Playlist playlist;
  final VoidCallback onDelete;

  const _DeletePlaylistDialog({required this.playlist, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.loc.playlist_delete_confirmation_title),
      content: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              style: Theme.of(context).textTheme.bodyMedium,
              text: context.loc.playlist_delete_confirmation_message(
                playlist.name,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.loc.cancel),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.pop(context);
            onDelete();
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
          child: Text(context.loc.delete),
        ),
      ],
    );
  }
}

/// Permet de changer le code d'accès (url / identifiant / mot de passe)
/// d'un abonnement sans le recréer : favoris et historique sont conservés.
class _EditPlaylistDialog extends StatefulWidget {
  final Playlist playlist;
  final Future<void> Function(Playlist updated) onSave;

  const _EditPlaylistDialog({required this.playlist, required this.onSave});

  @override
  State<_EditPlaylistDialog> createState() => _EditPlaylistDialogState();
}

class _EditPlaylistDialogState extends State<_EditPlaylistDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _username;
  late final TextEditingController _password;
  bool _obscure = true;
  bool _saving = false;

  bool get _isXtream => widget.playlist.type == PlaylistType.xtream;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.playlist.name);
    _url = TextEditingController(text: widget.playlist.url ?? '');
    _username = TextEditingController(text: widget.playlist.username ?? '');
    _password = TextEditingController(text: widget.playlist.password ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _url.text.trim().isEmpty) return;
    setState(() => _saving = true);
    var url = _url.text.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    final updated = Playlist(
      id: widget.playlist.id,
      name: _name.text.trim(),
      type: widget.playlist.type,
      url: url,
      username: _isXtream ? _username.text.trim() : widget.playlist.username,
      password: _isXtream ? _password.text.trim() : widget.playlist.password,
      createdAt: widget.playlist.createdAt,
    );
    await widget.onSave(updated);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Modifier l'abonnement"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Mets ici ton nouveau code d'accès quand tu renouvelles ton "
              'abonnement : tes favoris et ton historique sont conservés.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Nom'),
            ),
            TextField(
              controller: _url,
              decoration: InputDecoration(
                labelText: _isXtream ? 'URL du serveur' : 'URL de la playlist',
              ),
              keyboardType: TextInputType.url,
            ),
            if (_isXtream) ...[
              TextField(
                controller: _username,
                decoration: const InputDecoration(labelText: 'Identifiant'),
              ),
              TextField(
                controller: _password,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Mot de passe',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
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
