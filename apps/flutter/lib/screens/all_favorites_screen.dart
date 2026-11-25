import 'package:another_iptv_player/controllers/favorites_controller.dart';
import 'package:another_iptv_player/models/favorite.dart';
import 'package:another_iptv_player/models/playlist_content_model.dart';
import 'package:another_iptv_player/repositories/favorites_repository.dart';
import 'package:another_iptv_player/utils/navigate_by_content_type.dart';
import 'package:another_iptv_player/utils/responsive_helper.dart';
import 'package:another_iptv_player/widgets/content_card.dart';
import 'package:another_iptv_player/widgets/watch_history/favorites_section.dart';
import 'package:flutter/material.dart';

/// Tous les favoris, rangés par type (films, séries, chaînes).
/// Les favoris sont communs à tous les abonnements.
class AllFavoritesScreen extends StatefulWidget {
  final FavoritesController controller;

  const AllFavoritesScreen({super.key, required this.controller});

  @override
  State<AllFavoritesScreen> createState() => _AllFavoritesScreenState();
}

class _AllFavoritesScreenState extends State<AllFavoritesScreen> {
  final _repository = FavoritesRepository();
  final Map<String, Future<ContentItem?>> _resolved = {};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<ContentItem?> _resolve(Favorite f) {
    return _resolved.putIfAbsent(
      f.id,
      () => _repository.getContentItemFromFavorite(f),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final tabs = <(String, IconData, List<Favorite>)>[
      ('Films', Icons.movie, c.movieFavorites),
      ('Séries', Icons.tv, c.seriesFavorites),
      ('Chaînes', Icons.live_tv, c.liveStreamFavorites),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mes favoris'),
          bottom: TabBar(
            tabs: [
              for (final t in tabs)
                Tab(icon: Icon(t.$2), text: '${t.$1} (${t.$3.length})'),
            ],
          ),
        ),
        body: TabBarView(
          children: [for (final t in tabs) _buildGrid(context, t.$3)],
        ),
      ),
    );
  }

  Widget _buildGrid(BuildContext context, List<Favorite> favorites) {
    if (favorites.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Aucun favori ici.\nAppuie sur le cœur sur une fiche pour en ajouter.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: ResponsiveHelper.getCrossAxisCount(context),
        childAspectRatio: 0.65,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: favorites.length,
      itemBuilder: (context, index) {
        final favorite = favorites[index];
        return Stack(
          children: [
            Positioned.fill(
              child: FutureBuilder<ContentItem?>(
                future: _resolve(favorite),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    );
                  }
                  final item = snapshot.data ??
                      FavoritesSection.favoriteToContentItem(favorite);
                  return ContentCard(
                    content: item,
                    width: 150,
                    onTap: () => navigateByContentType(context, item),
                  );
                },
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _remove(favorite),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.favorite, color: Colors.red, size: 18),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _remove(Favorite favorite) async {
    final ok = await widget.controller.removeFavoriteEntry(favorite);
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('« ${favorite.name} » retiré des favoris'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }
}
