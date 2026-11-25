import 'package:another_iptv_player/database/database.dart';
import 'package:another_iptv_player/models/content_type.dart';
import 'package:another_iptv_player/models/playlist_content_model.dart';
import 'package:another_iptv_player/models/series.dart';
import 'package:another_iptv_player/models/vod_streams.dart';
import 'package:another_iptv_player/services/app_state.dart';
import 'package:another_iptv_player/services/service_locator.dart';
import 'package:another_iptv_player/utils/content_grouping.dart';
import 'package:another_iptv_player/utils/get_playlist_type.dart';
import 'package:another_iptv_player/utils/title_normalizer.dart';
import 'package:flutter/foundation.dart';

class _Entry<T> {
  final T item;
  final String? year;
  _Entry(this.item, this.year);
}

/// Index en mémoire de tout le catalogue films / séries de la playlist
/// courante, par titre normalisé. Sert à retrouver toutes les versions d'un
/// film, les favoris d'un ancien abonnement et les films d'un acteur.
class CatalogIndex {
  CatalogIndex._();

  static String? _playlistId;
  static Map<String, List<_Entry<VodStream>>> _movies = {};
  static Map<String, List<_Entry<SeriesStream>>> _series = {};
  static Future<void>? _loading;

  static void invalidate() {
    _playlistId = null;
    _movies = {};
    _series = {};
    _loading = null;
  }

  static Future<void> ensureLoaded() {
    final playlist = AppState.currentPlaylist;
    if (playlist == null || !isXtreamCode) return Future.value();
    if (_playlistId == playlist.id && _loading != null) return _loading!;
    _playlistId = playlist.id;
    _loading = _load(playlist.id);
    return _loading!;
  }

  static Future<void> _load(String playlistId) async {
    try {
      final db = getIt<AppDatabase>();
      final movies = await db.getVodStreamsByPlaylistId(playlistId);
      final series = await db.getSeriesStreamsByPlaylistId(playlistId);

      // L'analyse des titres se fait hors du thread de l'interface.
      final movieKeys = await compute(_parseAll, movies.map((m) => m.name).toList());
      final seriesKeys = await compute(_parseAll, series.map((s) => s.name).toList());

      final movieMap = <String, List<_Entry<VodStream>>>{};
      for (var i = 0; i < movies.length; i++) {
        final k = movieKeys[i];
        movieMap.putIfAbsent(k[0], () => []).add(_Entry(movies[i], k[1].isEmpty ? null : k[1]));
      }
      final seriesMap = <String, List<_Entry<SeriesStream>>>{};
      for (var i = 0; i < series.length; i++) {
        final k = seriesKeys[i];
        seriesMap.putIfAbsent(k[0], () => []).add(_Entry(series[i], k[1].isEmpty ? null : k[1]));
      }

      if (_playlistId == playlistId) {
        _movies = movieMap;
        _series = seriesMap;
      }
    } catch (e) {
      debugPrint('CatalogIndex load error: $e');
    }
  }

  static List<List<String>> _parseAll(List<String> names) {
    return names.map((n) {
      final p = TitleNormalizer.parse(n);
      return [p.key, p.year ?? ''];
    }).toList();
  }

  static bool _yearMatches(String? a, String? b) {
    if (a == null || b == null) return true;
    final ya = int.tryParse(a);
    final yb = int.tryParse(b);
    if (ya == null || yb == null) return a == b;
    return (ya - yb).abs() <= 1; // tolère un an d'écart (sortie FR / US)
  }

  static ContentItem movieToItem(VodStream x) => ContentItem(
        x.streamId,
        x.name,
        x.streamIcon,
        ContentType.vod,
        containerExtension: x.containerExtension,
        vodStream: x,
      );

  static ContentItem seriesToItem(SeriesStream x) => ContentItem(
        x.seriesId,
        x.name,
        x.cover ?? '',
        ContentType.series,
        seriesStream: x,
      );

  /// Toutes les versions disponibles d'un film (meilleure qualité d'abord).
  static Future<List<ContentItem>> movieVersions(String rawName) async {
    await ensureLoaded();
    final p = TitleNormalizer.parse(rawName);
    final entries = _movies[p.key] ?? const [];
    final items = entries
        .where((e) => _yearMatches(p.year, e.year))
        .map((e) => movieToItem(e.item))
        .toList();
    return ContentGrouping.sortVersions(items);
  }

  /// Cherche un film par titre (et titre original) + année facultative.
  static Future<List<ContentItem>> findMovies(
    List<String> titles, {
    String? year,
  }) async {
    await ensureLoaded();
    final seen = <String>{};
    final out = <ContentItem>[];
    for (final t in titles) {
      final key = TitleNormalizer.normalizeKey(t);
      for (final e in _movies[key] ?? const <_Entry<VodStream>>[]) {
        if (_yearMatches(year, e.year) && seen.add(e.item.streamId)) {
          out.add(movieToItem(e.item));
        }
      }
    }
    return out;
  }

  /// Cherche une série par titre (et titre original).
  static Future<List<ContentItem>> findSeries(List<String> titles) async {
    await ensureLoaded();
    final seen = <String>{};
    final out = <ContentItem>[];
    for (final t in titles) {
      final key = TitleNormalizer.normalizeKey(t);
      for (final e in _series[key] ?? const <_Entry<SeriesStream>>[]) {
        if (seen.add(e.item.seriesId)) out.add(seriesToItem(e.item));
      }
    }
    return out;
  }

  /// Retrouve un élément du catalogue courant à partir de son nom
  /// (utilisé pour les favoris enregistrés avec un autre abonnement).
  static Future<ContentItem?> findByName(
    String rawName,
    ContentType type,
  ) async {
    await ensureLoaded();
    final p = TitleNormalizer.parse(rawName);
    if (type == ContentType.vod) {
      final versions = await movieVersions(rawName);
      if (versions.isEmpty) return null;
      final main = versions.first;
      main.variants = versions;
      return main;
    }
    if (type == ContentType.series) {
      final entries = _series[p.key] ?? const <_Entry<SeriesStream>>[];
      for (final e in entries) {
        if (_yearMatches(p.year, e.year)) return seriesToItem(e.item);
      }
    }
    return null;
  }
}
