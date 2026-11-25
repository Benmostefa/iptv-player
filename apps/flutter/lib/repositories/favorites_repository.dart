import 'package:another_iptv_player/database/database.dart';
import 'package:another_iptv_player/models/content_type.dart';
import 'package:another_iptv_player/models/favorite.dart';
import 'package:another_iptv_player/models/playlist_content_model.dart';
import 'package:another_iptv_player/services/app_state.dart';
import 'package:another_iptv_player/services/service_locator.dart';
import 'package:another_iptv_player/utils/get_playlist_type.dart';
import 'package:another_iptv_player/repositories/m3u_repository.dart';
import 'package:another_iptv_player/services/catalog_index.dart';
import 'package:another_iptv_player/utils/content_grouping.dart';
import 'package:uuid/uuid.dart';

class FavoritesRepository {
  final _database = getIt<AppDatabase>();
  final _uuid = Uuid();

  FavoritesRepository();

  Future<void> addFavorite(ContentItem contentItem) async {
    final playlistId = AppState.currentPlaylist!.id;

    final isAlreadyFavorite = await _database.isFavorite(
      playlistId,
      contentItem.id,
      contentItem.contentType,
      contentItem.season != null ? contentItem.id : null,
    );

    if (isAlreadyFavorite) {
      throw Exception('Bu içerik zaten favorilerde');
    }

    final favorite = Favorite(
      id: _uuid.v4(),
      playlistId: playlistId,
      contentType: contentItem.contentType,
      streamId: contentItem.id,
      m3uItemId: contentItem.m3uItem?.id,
      name: contentItem.name,
      imagePath: contentItem.imagePath,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await _database.insertFavorite(favorite);
  }

  Future<void> removeFavorite(
    String streamId,
    ContentType contentType, {
    String? episodeId,
  }) async {
    final playlistId = AppState.currentPlaylist!.id;

    final favorites = await _database.getFavoritesByPlaylist(playlistId);
    final favorite = favorites.firstWhere(
      (f) =>
          f.streamId == streamId &&
          f.contentType == contentType &&
          f.episodeId == episodeId,
      orElse: () => throw Exception('Favori bulunamadı'),
    );

    await _database.deleteFavorite(favorite.id);
  }

  Future<bool> isFavorite(
    String streamId,
    ContentType contentType, {
    String? episodeId,
  }) async {
    final playlistId = AppState.currentPlaylist!.id;
    return await _database.isFavorite(
      playlistId,
      streamId,
      contentType,
      episodeId,
    );
  }

  Future<List<Favorite>> getAllFavorites() async {
    final playlistId = AppState.currentPlaylist!.id;
    final all = await _database.getAllFavorites();

    // Ceux de l'abonnement actuel d'abord, puis les plus récents.
    all.sort((a, b) {
      final aCur = a.playlistId == playlistId ? 0 : 1;
      final bCur = b.playlistId == playlistId ? 0 : 1;
      if (aCur != bCur) return aCur.compareTo(bCur);
      return b.createdAt.compareTo(a.createdAt);
    });

    // Un seul exemplaire par contenu, même s'il a été ajouté avec
    // plusieurs abonnements ou en plusieurs versions.
    final unique = <Favorite>[];
    for (final f in all) {
      final dup = unique.any((u) =>
          u.contentType == f.contentType &&
          u.episodeId == f.episodeId &&
          (u.streamId == f.streamId || sameName(f.contentType, u.name, f.name)));
      if (!dup) unique.add(f);
    }
    return unique;
  }

  Future<List<Favorite>> getFavoritesByContentType(
    ContentType contentType,
  ) async {
    final all = await getAllFavorites();
    return all.where((f) => f.contentType == contentType).toList();
  }

  Future<List<Favorite>> getLiveStreamFavorites() async {
    return await getFavoritesByContentType(ContentType.liveStream);
  }

  Future<List<Favorite>> getMovieFavorites() async {
    return await getFavoritesByContentType(ContentType.vod);
  }

  Future<List<Favorite>> getSeriesFavorites() async {
    return await getFavoritesByContentType(ContentType.series);
  }

  Future<int> getFavoriteCount() async {
    final playlistId = AppState.currentPlaylist!.id;
    return await _database.getFavoriteCount(playlistId);
  }

  Future<int> getFavoriteCountByContentType(ContentType contentType) async {
    final playlistId = AppState.currentPlaylist!.id;
    return await _database.getFavoriteCountByContentType(
      playlistId,
      contentType,
    );
  }

  // ---------------------------------------------------------------------
  // Favoris globaux : ils ne dépendent plus de l'abonnement (playlist).
  // Un favori enregistré avec un ancien code d'accès est retrouvé dans le
  // nouvel abonnement grâce à son identifiant ou, à défaut, à son titre.
  // ---------------------------------------------------------------------

  static bool sameName(ContentType type, String a, String b) {
    if (type == ContentType.liveStream) {
      return a.trim().toLowerCase() == b.trim().toLowerCase();
    }
    return ContentGrouping.isSameWork(a, b);
  }

  bool _matches(Favorite f, ContentItem item) {
    if (f.contentType != item.contentType || f.episodeId != null) return false;
    final currentId = AppState.currentPlaylist?.id;
    if (f.playlistId == currentId && f.streamId == item.id) return true;
    return sameName(item.contentType, f.name, item.name);
  }

  /// Vrai si ce contenu (ou une autre version du même film) est en favori,
  /// quel que soit l'abonnement avec lequel il a été ajouté.
  Future<bool> isFavoriteItem(ContentItem contentItem) async {
    final all = await _database.getAllFavorites();
    return all.any((f) => _matches(f, contentItem));
  }

  Future<bool> toggleFavorite(ContentItem contentItem) async {
    final all = await _database.getAllFavorites();
    final matches = all.where((f) => _matches(f, contentItem)).toList();

    if (matches.isNotEmpty) {
      for (final f in matches) {
        await _database.deleteFavorite(f.id);
      }
      return false;
    }
    await addFavorite(contentItem);
    return true;
  }

  /// Supprime un favori et ses doublons (autres abonnements / versions).
  Future<void> removeFavoriteEntry(Favorite favorite) async {
    final all = await _database.getAllFavorites();
    for (final f in all) {
      final same = f.id == favorite.id ||
          (f.contentType == favorite.contentType &&
              f.episodeId == favorite.episodeId &&
              (f.streamId == favorite.streamId ||
                  sameName(f.contentType, f.name, favorite.name)));
      if (same) await _database.deleteFavorite(f.id);
    }
  }

  Future<void> updateFavorite(Favorite favorite) async {
    await _database.updateFavorite(favorite);
  }

  Future<void> clearAllFavorites() async {
    final playlistId = AppState.currentPlaylist!.id;
    final favorites = await _database.getFavoritesByPlaylist(playlistId);

    for (final favorite in favorites) {
      await _database.deleteFavorite(favorite.id);
    }
  }

  Future<ContentItem?> getContentItemFromFavorite(Favorite favorite) async {
    final currentId = AppState.currentPlaylist?.id;
    if (favorite.playlistId != currentId &&
        favorite.episodeId == null &&
        isXtreamCode) {
      // Favori ajouté avec un autre abonnement : on vérifie que l'identifiant
      // correspond bien au même contenu, sinon on le cherche par son titre.
      final byId = await _resolveById(favorite, strict: true);
      if (byId != null &&
          sameName(favorite.contentType, byId.name, favorite.name)) {
        return byId;
      }
      final byName = await _resolveByName(favorite);
      if (byName != null) return byName;
    }
    return _resolveById(favorite);
  }

  Future<ContentItem?> _resolveByName(Favorite favorite) async {
    try {
      if (favorite.contentType == ContentType.liveStream) {
        final results = await AppState.xtreamCodeRepository!
            .searchLiveStreams(favorite.name);
        for (final live in results) {
          if (sameName(ContentType.liveStream, live.name, favorite.name)) {
            return ContentItem(
              live.streamId,
              live.name,
              live.streamIcon,
              ContentType.liveStream,
              liveStream: live,
            );
          }
        }
        return null;
      }
      return await CatalogIndex.findByName(
        favorite.name,
        favorite.contentType,
      );
    } catch (_) {
      return null;
    }
  }

  Future<ContentItem?> _resolveById(
    Favorite favorite, {
    bool strict = false,
  }) async {
    try {
      if (isXtreamCode) {
        final repository = AppState.xtreamCodeRepository!;

        switch (favorite.contentType) {
          case ContentType.liveStream:
            final liveStream = await repository.findLiveStreamById(
              favorite.streamId,
            );

            if (liveStream != null) {
              return ContentItem(
                liveStream.streamId,
                liveStream.name,
                liveStream.streamIcon,
                ContentType.liveStream,
                liveStream: liveStream,
              );
            }
            break;

          case ContentType.vod:
            final movie = await _database.findMovieById(
              favorite.streamId,
              AppState.currentPlaylist!.id,
            );

            if (movie != null) {
              return ContentItem(
                favorite.streamId,
                movie.name,
                movie.streamIcon.isNotEmpty
                    ? movie.streamIcon
                    : favorite.imagePath ?? '',
                ContentType.vod,
                containerExtension: movie.containerExtension,
                vodStream: movie,
              );
            }
            break;
          case ContentType.series:
            final series = await repository.getSeries(categoryId: '');
            final seriesStream = series?.firstWhere(
              (serie) => serie.seriesId == favorite.streamId,
            );
            if (seriesStream != null) {
              return ContentItem(
                seriesStream.seriesId,
                seriesStream.name,
                seriesStream.cover ?? '',
                ContentType.series,
                seriesStream: seriesStream,
              );
            }
            break;
        }
      } else if (isM3u) {
        final repository = M3uRepository();

        switch (favorite.contentType) {
          case ContentType.liveStream:
            final m3uItem = await repository.getM3uItemById(
              id: favorite.m3uItemId ?? '',
            );
            if (m3uItem != null) {
              return ContentItem(
                m3uItem.url,
                m3uItem.name ?? 'NO NAME',
                m3uItem.tvgLogo ?? '',
                ContentType.liveStream,
                m3uItem: m3uItem,
              );
            }
            break;

          case ContentType.vod:
            final m3uItem = await repository.getM3uItemById(
              id: favorite.m3uItemId ?? '',
            );

            if (m3uItem != null) {
              return ContentItem(
                m3uItem.url,
                m3uItem.name ?? 'NO NAME',
                m3uItem.tvgLogo ?? '',
                ContentType.vod,
                m3uItem: m3uItem,
              );
            }
            break;

          case ContentType.series:
            final m3uItem = await repository.getM3uItemById(
              id: favorite.m3uItemId ?? '',
            );

            if (m3uItem != null) {
              return ContentItem(
                m3uItem.id,
                m3uItem.name ?? '',
                m3uItem.tvgLogo ?? '',
                ContentType.series,
                m3uItem: m3uItem,
              );
            }
            break;
        }
      }

      if (strict) return null;
      return ContentItem(
        favorite.streamId,
        favorite.name,
        favorite.imagePath ?? '',
        favorite.contentType,
      );
    } catch (e) {
      if (strict) return null;
      return ContentItem(
        favorite.streamId,
        favorite.name,
        favorite.imagePath ?? '',
        favorite.contentType,
      );
    }
  }
}
