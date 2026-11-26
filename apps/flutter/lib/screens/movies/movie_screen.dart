import 'package:another_iptv_player/widgets/kids_guard.dart';
import 'dart:ui';

import 'package:another_iptv_player/l10n/localization_extension.dart';
import 'package:another_iptv_player/models/api_configuration_model.dart';
import 'package:another_iptv_player/models/content_type.dart';
import 'package:another_iptv_player/models/playlist_content_model.dart';
import 'package:another_iptv_player/models/watch_history.dart';
import 'package:another_iptv_player/repositories/favorites_repository.dart';
import 'package:another_iptv_player/screens/actor_search_screen.dart';
import 'package:another_iptv_player/services/catalog_index.dart';
import 'package:another_iptv_player/services/tmdb_service.dart';
import 'package:another_iptv_player/utils/content_grouping.dart';
import 'package:another_iptv_player/utils/title_normalizer.dart';
import 'package:another_iptv_player/utils/rating_utils.dart';
import 'package:another_iptv_player/widgets/tmdb_key_dialog.dart';
import 'package:another_iptv_player/repositories/iptv_repository.dart';
import 'package:another_iptv_player/services/app_state.dart';
import 'package:another_iptv_player/services/watch_history_service.dart';
import 'package:another_iptv_player/utils/get_playlist_type.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../widgets/player_widget.dart';

class MovieScreen extends StatefulWidget {
  final ContentItem contentItem;

  const MovieScreen({super.key, required this.contentItem});

  @override
  State<MovieScreen> createState() => _MovieScreenState();
}

class _MovieScreenState extends State<MovieScreen> {
  late final WatchHistoryService _watchHistoryService;
  late final IptvRepository? _repository;

  WatchHistory? _watchHistory;
  Map<String, dynamic>? _vodInfo;
  bool _isLoadingHistory = true;
  bool _isLoadingVodInfo = true;
  List<ContentItem> _categoryMovies = [];

  // Versions du film (4K / HD / SD / langues) et version choisie.
  List<ContentItem> _versions = [];
  late ContentItem _selected;

  // Favori (commun à tous les abonnements).
  final FavoritesRepository _favoritesRepository = FavoritesRepository();
  bool _isFavorite = false;

  // Infos TMDB (résumé FR, note, acteurs).
  TmdbDetails? _tmdb;
  bool _tmdbConfigured = true;
  bool _tmdbLanguageSet = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.contentItem;
    _versions = widget.contentItem.variants.isNotEmpty
        ? List.of(widget.contentItem.variants)
        : [widget.contentItem];
    _watchHistoryService = WatchHistoryService();

    if (isXtreamCode && AppState.currentPlaylist != null) {
      _repository = IptvRepository(
        ApiConfig(
          baseUrl: AppState.currentPlaylist!.url!,
          username: AppState.currentPlaylist!.username!,
          password: AppState.currentPlaylist!.password!,
        ),
        AppState.currentPlaylist!.id,
      );
    } else {
      _repository = null;
    }

    _loadWatchHistory();
    _loadVodInfo();
    _loadCategoryMovies();
    _loadVersions();
    _loadFavorite();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_tmdbLanguageSet) {
      _tmdbLanguageSet = true;
      TmdbService.instance.language =
          Localizations.localeOf(context).languageCode;
    }
  }

  Future<void> _loadFavorite() async {
    try {
      final fav = await _favoritesRepository.isFavoriteItem(widget.contentItem);
      if (mounted) setState(() => _isFavorite = fav);
    } catch (_) {}
  }

  Future<void> _toggleFavorite() async {
    try {
      final result = await _favoritesRepository.toggleFavorite(widget.contentItem);
      if (!mounted) return;
      setState(() => _isFavorite = result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result
                ? context.loc.added_to_favorites
                : context.loc.removed_from_favorites,
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      debugPrint('Favorite error: $e');
    }
  }

  /// Cherche les autres versions du même film dans tout le catalogue.
  Future<void> _loadVersions() async {
    if (!isXtreamCode) return;
    try {
      final found = await CatalogIndex.movieVersions(widget.contentItem.name);
      final byId = <String, ContentItem>{
        for (final v in _versions) v.id: v,
      };
      for (final v in found) {
        byId.putIfAbsent(v.id, () => v);
      }
      if (!mounted) return;
      setState(() {
        _versions = ContentGrouping.sortVersions(byId.values.toList());
      });
    } catch (e) {
      debugPrint('Error loading versions: $e');
    }
  }

  /// Lit un champ de get_vod_info (dans "info" ou à la racine).
  dynamic _infoField(String key) {
    final info = _vodInfo;
    if (info == null) return null;
    final nested = info['info'];
    if (nested is Map && nested[key] != null && nested[key] != '') {
      return nested[key];
    }
    return info[key];
  }

  Future<void> _loadTmdb() async {
    final configured = await TmdbService.instance.isConfigured;
    if (!mounted) return;
    if (!configured) {
      setState(() => _tmdbConfigured = false);
      return;
    }
    final parsed = TitleNormalizer.parse(widget.contentItem.name);
    final tmdbId = _infoField('tmdb_id')?.toString();
    String? year = parsed.year;
    final release = _infoField('releasedate') ?? _infoField('release_date');
    if (year == null && release is String && release.length >= 4) {
      year = release.substring(0, 4);
    }
    final details = await TmdbService.instance.getMovie(
      tmdbId: tmdbId,
      title: parsed.title,
      year: year,
    );
    if (!mounted) return;
    setState(() {
      _tmdbConfigured = true;
      _tmdb = details;
    });
  }

  Future<void> _loadCategoryMovies() async {
    try {
      if (isXtreamCode && _repository != null) {
        final vod = widget.contentItem.vodStream;
        final categoryId = vod?.categoryId;

        if (categoryId != null) {
          final movies = await _repository!.getMovies(categoryId: categoryId);
          if (movies != null && mounted) {
            setState(() {
              _categoryMovies = ContentGrouping.groupMovies(movies
                  .map((x) => ContentItem(
                        x.streamId,
                        x.name,
                        x.streamIcon,
                        ContentType.vod,
                        vodStream: x,
                        containerExtension: x.containerExtension,
                      ))
                  .toList());
            });
          }
        }
      } else if (isM3u) {
        final m3uItem = widget.contentItem.m3uItem;
        final categoryId = m3uItem?.categoryId;

        if (categoryId != null) {
          final items = await AppState.m3uRepository!.getM3uItemsByCategoryId(
            categoryId: categoryId,
            contentType: ContentType.vod,
          );
          if (items != null && mounted) {
            setState(() {
              _categoryMovies = items
                  .map((x) => ContentItem(
                        x.id,
                        x.name ?? 'NO NAME',
                        x.tvgLogo ?? '',
                        ContentType.vod,
                        m3uItem: x,
                      ))
                  .toList();
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Error loading category movies: $e');
    }
  }

  Future<void> _loadWatchHistory() async {
    final playlist = AppState.currentPlaylist;
    if (playlist == null) {
      if (!mounted) return;
      setState(() {
        _watchHistory = null;
        _isLoadingHistory = false;
      });
      return;
    }

    if (mounted) {
      setState(() {
        _isLoadingHistory = true;
      });
    }

    try {
      final streamId = isXtreamCode
          ? widget.contentItem.id
          : widget.contentItem.m3uItem?.id ?? widget.contentItem.id;

      final history =
          await _watchHistoryService.getWatchHistory(playlist.id, streamId);

      if (!mounted) return;
      setState(() {
        _watchHistory = history;
        _isLoadingHistory = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _watchHistory = null;
        _isLoadingHistory = false;
      });
    }
  }

  Future<void> _loadVodInfo() async {
    await _loadVodInfoFromProvider();
    await _loadTmdb();
  }

  Future<void> _loadVodInfoFromProvider() async {
    if (!isXtreamCode || _repository == null) {
      if (!mounted) return;
      setState(() {
        _vodInfo = null;
        _isLoadingVodInfo = false;
      });
      return;
    }

    try {
      final info = await _repository!.getVodInfo(widget.contentItem.id);

      if (!mounted) return;
      setState(() {
        _vodInfo = info;
        _isLoadingVodInfo = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _vodInfo = null;
        _isLoadingVodInfo = false;
      });
    }
  }

  double? get _progress {
    final history = _watchHistory;
    if (history?.watchDuration == null || history?.totalDuration == null) {
      return null;
    }

    final total = history!.totalDuration!.inMilliseconds;
    if (total <= 0) return null;

    final value = history.watchDuration!.inMilliseconds / total;
    if (value <= 0) return null;

    return (value.clamp(0.0, 1.0)) as double;
  }

  String? get _posterUrl {
    if (_vodInfo != null) {
      final cover = _infoField('cover_big') ?? _infoField('movie_image') ??
          _infoField('cover');
      if (cover is String && cover.isNotEmpty) return cover;
    }
    if (_tmdb?.posterUrl != null) return _tmdb!.posterUrl;
    if (widget.contentItem.coverPath?.isNotEmpty == true) {
      return widget.contentItem.coverPath;
    }
    if (widget.contentItem.imagePath.isNotEmpty) {
      return widget.contentItem.imagePath;
    }
    return widget.contentItem.vodStream?.streamIcon;
  }

  String? get _backdropUrl {
    if (_tmdb?.backdropUrl != null) return _tmdb!.backdropUrl;
    if (_vodInfo != null) {
      final backdrop = _infoField('backdrop_path');
      if (backdrop is List && backdrop.isNotEmpty) {
        return backdrop.first.toString();
      } else if (backdrop is String && backdrop.isNotEmpty) {
        return backdrop;
      }
    }
    return null;
  }

  String? get _plotSummary {
    final tmdbOverview = _tmdb?.overview?.trim();
    if (tmdbOverview != null && tmdbOverview.isNotEmpty) return tmdbOverview;
    if (_vodInfo != null) {
      final plot = _infoField('plot') ?? _infoField('description');
      if (plot is String && plot.isNotEmpty) {
        return plot;
      }
    }
    return widget.contentItem.description?.trim();
  }

  String? get _directorInfo {
    if (_tmdb != null && _tmdb!.directors.isNotEmpty) {
      return _tmdb!.directors.join(', ');
    }
    if (_vodInfo != null) {
      final director = _infoField('director');
      if (director is String && director.isNotEmpty) {
        return director;
      }
    }
    return null;
  }

  String? get _castInfo {
    if (_vodInfo != null) {
      final cast = _infoField('cast') ?? _infoField('actors');
      if (cast is String && cast.isNotEmpty) {
        return cast;
      }
    }
    return null;
  }

  int? get _duration {
    if (_vodInfo != null) {
      final duration = _infoField('duration_secs') ?? _infoField('duration');
      if (duration is int) {
        return duration;
      }
      if (duration is String) {
        final secs = int.tryParse(duration);
        if (secs != null) return secs;
        final parts = duration.split(':').map(int.tryParse).toList();
        if (parts.length == 3 && !parts.contains(null)) {
          return parts[0]! * 3600 + parts[1]! * 60 + parts[2]!;
        }
      }
    }
    if (_tmdb?.runtimeMinutes != null && _tmdb!.runtimeMinutes! > 0) {
      return _tmdb!.runtimeMinutes! * 60;
    }
    return widget.contentItem.duration?.inSeconds;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5),
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        actions: const [KidsModeButton(onDarkBackground: true)],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. BACKDROP LAYER
          _buildBackdrop(),

          // 2. CONTENT LAYER
          LayoutBuilder(
            builder: (context, constraints) {
              final isDesktop = constraints.maxWidth > 700;
              final topPadding =
                  MediaQuery.of(context).padding.top + kToolbarHeight + 20;

              return SingleChildScrollView(
                padding: EdgeInsets.only(
                  top: isDesktop ? topPadding : topPadding + 100,
                  bottom: 100,
                  left: 16,
                  right: 16,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: isDesktop
                        ? _buildDesktopLayout(context)
                        : _buildMobileLayout(context),
                  ),
                ),
              );
            },
          ),

          // 3. PLAY BUTTON (Fixed at bottom)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16 + MediaQuery.of(context).padding.bottom,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: _buildPlayButton(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackdrop() {
    final url = _backdropUrl ?? _posterUrl;
    if (url == null) return Container(color: Colors.black);

    return Stack(
      fit: StackFit.expand,
      children: [
        KidsGuard(
          item: widget.contentItem,
          showEye: false,
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => Container(color: Colors.black),
          ),
        ),
        // Blur if using poster or just to dim backdrop
        BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: _backdropUrl != null ? 5 : 15,
            sigmaY: _backdropUrl != null ? 5 : 15,
          ),
          child: Container(color: Colors.black.withOpacity(0.5)),
        ),
        // Gradient overlay
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black.withOpacity(0.2),
                Theme.of(context).scaffoldBackgroundColor.withOpacity(0.8),
                Theme.of(context).scaffoldBackgroundColor,
              ],
              stops: const [0.0, 0.4, 0.8, 1.0],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMobileLayout(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildPoster(height: 300),
        const SizedBox(height: 24),
        _buildTitle(context, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        if (_buildRatingSection(context) != null) ...[
          _buildRatingSection(context)!,
          const SizedBox(height: 16),
        ],
        _buildActionRow(context, WrapAlignment.center),
        const SizedBox(height: 16),
        if (_buildInfoChips(context) != null) ...[
          _buildInfoChips(context)!,
          const SizedBox(height: 24),
        ],
        if (_buildVersionsSection(context) != null) ...[
          _buildVersionsSection(context)!,
          const SizedBox(height: 24),
        ],
        if (_buildDescriptionSection(context) != null) ...[
          _buildDescriptionSection(context)!,
          const SizedBox(height: 24),
        ],
        if (_buildCastSection(context) != null) ...[
          _buildCastSection(context)!,
          const SizedBox(height: 24),
        ],
        if (_buildExtraDetails(context) != null) ...[
          _buildExtraDetails(context)!,
          const SizedBox(height: 24),
        ],
        if (!_tmdbConfigured) ...[
          _buildTmdbHint(context),
          const SizedBox(height: 24),
        ],
      ],
    );
  }

  Widget _buildDesktopLayout(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPoster(height: 450),
        const SizedBox(width: 32),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTitle(context, textAlign: TextAlign.start),
              const SizedBox(height: 16),
              if (_buildRatingSection(context) != null) ...[
                _buildRatingSection(context)!,
                const SizedBox(height: 16),
              ],
              _buildActionRow(context, WrapAlignment.start),
              const SizedBox(height: 16),
              if (_buildInfoChips(context) != null) ...[
                _buildInfoChips(context)!,
                const SizedBox(height: 24),
              ],
              if (_buildVersionsSection(context) != null) ...[
                _buildVersionsSection(context)!,
                const SizedBox(height: 24),
              ],
              if (_buildDescriptionSection(context) != null) ...[
                _buildDescriptionSection(context)!,
                const SizedBox(height: 24),
              ],
              if (_buildCastSection(context) != null) ...[
                _buildCastSection(context)!,
                const SizedBox(height: 24),
              ],
              if (_buildExtraDetails(context) != null) ...[
                _buildExtraDetails(context)!,
                const SizedBox(height: 24),
              ],
              if (!_tmdbConfigured) ...[
                _buildTmdbHint(context),
                const SizedBox(height: 24),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPoster({required double height}) {
    final url = _posterUrl;
    if (url == null) return const SizedBox.shrink();

    return Container(
      height: height,
      width: height * 0.66, // Standard poster ratio
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: KidsGuard(
          item: widget.contentItem,
          compact: false,
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            placeholder: (context, url) => Container(
              color: Colors.grey.shade900,
              child: const Center(child: CircularProgressIndicator()),
            ),
            errorWidget: (context, url, error) => Container(
              color: Colors.grey.shade900,
              child: const Icon(Icons.movie, size: 50, color: Colors.grey),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitle(BuildContext context, {required TextAlign textAlign}) {
    final clean = _tmdb?.title ?? TitleNormalizer.parse(widget.contentItem.name).title;
    return Text(
      clean,
      textAlign: textAlign,
      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            shadows: [
              Shadow(
                blurRadius: 10,
                color: Colors.black.withOpacity(0.5),
                offset: const Offset(0, 2),
              ),
            ],
          ),
    );
  }

  Widget? _buildRatingSection(BuildContext context) {
    // Note principale = la même que sur l'affiche (fournisseur), sur 10.
    final main = providerRating(widget.contentItem);
    final tmdb = _tmdb;
    final hasTmdb = tmdb != null && tmdb.voteCount > 0;
    if (main == null && !hasTmdb) return null;

    final children = <Widget>[];
    if (main != null) {
      children.addAll([
        Icon(Icons.star_rounded, color: Colors.amber.shade500, size: 28),
        const SizedBox(width: 8),
        Text(
          '${formatRating(main)}/10',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
        ),
      ]);
    }
    if (hasTmdb) {
      final t = tmdb!;
      if (children.isNotEmpty) children.add(const SizedBox(width: 16));
      children.add(
        InkWell(
          onTap: () => launchUrl(
            Uri.parse(t.pageUrl),
            mode: LaunchMode.externalApplication,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (main == null) ...[
                Icon(Icons.star_rounded, color: Colors.amber.shade500, size: 28),
                const SizedBox(width: 8),
              ],
              Text(
                main == null
                    ? '${t.voteAverage.toStringAsFixed(1)}/10  TMDB · ${t.voteCount} votes'
                    : 'TMDB ${t.voteAverage.toStringAsFixed(1)} · ${t.voteCount} votes',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: main == null ? 18 : 13,
                  fontWeight: main == null ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [Row(mainAxisSize: MainAxisSize.min, children: children)],
    );
  }

  Widget? _buildInfoChips(BuildContext context) {
    final chips = <Widget>[];

    // Süre
    if (_duration != null && _duration! > 0) {
      final durationTime = Duration(seconds: _duration!);
      chips.add(
        _InfoChip(
          icon: Icons.access_time,
          label: _formatDuration(durationTime),
        ),
      );
    }

    // Tür/Genre
    dynamic genre = widget.contentItem.vodStream?.genre;
    if (genre is! String || genre.trim().isEmpty) genre = _infoField('genre');
    if ((genre is! String || genre.trim().isEmpty) &&
        _tmdb != null &&
        _tmdb!.genres.isNotEmpty) {
      genre = _tmdb!.genres.join(', ');
    }
    if (genre is String && genre.trim().isNotEmpty) {
      chips.add(
        _InfoChip(
          icon: Icons.local_movies,
          label: genre.trim(),
        ),
      );
    }

    // Format
    final format = (_selected.containerExtension ??
            _selected.vodStream?.containerExtension)
        ?.trim();
    if (format != null && format.isNotEmpty) {
      chips.add(
        _InfoChip(
          icon: Icons.sd_card,
          label: format.toUpperCase(),
        ),
      );
    }

    // Yayın Yılı / Released
    {
      final releaseDate = _infoField('releasedate') ??
          _infoField('releaseDate') ??
          _infoField('release_date') ??
          _infoField('year') ??
          _tmdb?.releaseDate;
      if (releaseDate is String && releaseDate.trim().isNotEmpty) {
        chips.add(
          _InfoChip(
            icon: Icons.calendar_today,
            label: releaseDate.trim(),
          ),
        );
      }
    }

    if (chips.isEmpty) {
      return null;
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center, // Center for mobile
      children: chips,
    );
  }

  Widget? _buildDescriptionSection(BuildContext context) {
    final description = _plotSummary?.trim();
    if (description == null || description.isEmpty) {
      return null;
    }

    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.loc.description,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: Colors.white70,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Colors.white,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  Widget? _buildExtraDetails(BuildContext context) {
    final entries = <_DetailEntry>[];

    // Yönetmen
    final director = _directorInfo;
    if (director != null && director.isNotEmpty) {
      entries.add(
        _DetailEntry(
          icon: Icons.person,
          title: context.loc.director,
          value: director,
        ),
      );
    }

    // Oyuncular
    final cast = _castInfo;
    if (cast != null && cast.isNotEmpty && (_tmdb?.cast.isEmpty ?? true)) {
      entries.add(
        _DetailEntry(
          icon: Icons.people,
          title: context.loc.cast,
          value: cast,
        ),
      );
    }

    // Eklenme Tarihi
    final vod = widget.contentItem.vodStream;
    if (vod?.createdAt != null) {
      final locale = Localizations.localeOf(context).toLanguageTag();
      entries.add(
        _DetailEntry(
          icon: Icons.calendar_today,
          title: context.loc.creation_date,
          value: DateFormat.yMMMMd(locale).format(vod!.createdAt!),
        ),
      );
    }

    if (entries.isEmpty) {
      return null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.loc.info,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: Colors.white70,
              ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: entries
              .map((e) => _DetailCard(
                    icon: e.icon,
                    title: e.title,
                    value: e.value,
                  ))
              .toList(),
        ),
      ],
    );
  }

  /// Choix de la version : 4K, Full HD, HD, SD, langue...
  Widget? _buildVersionsSection(BuildContext context) {
    if (_versions.length < 2) return null;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Choisir la version (${_versions.length})',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: Colors.white70,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _versions.map((v) {
            final parsed = TitleNormalizer.parse(v.name);
            final ext = (v.containerExtension ?? v.vodStream?.containerExtension ?? '')
                .trim()
                .toUpperCase();
            var label = parsed.versionLabel;
            if (label.isEmpty) label = 'Standard';
            if (ext.isNotEmpty) label = '$label · $ext';
            final selected = v.id == _selected.id;
            return Tooltip(
              message: v.name,
              child: ChoiceChip(
                label: Text(label),
                selected: selected,
                avatar: parsed.qualityRank >= 4
                    ? const Icon(Icons.four_k, size: 18)
                    : null,
                onSelected: (_) => setState(() => _selected = v),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  /// Acteurs avec photo ; un appui ouvre leurs films disponibles.
  Widget? _buildCastSection(BuildContext context) {
    final cast = _tmdb?.cast ?? const <TmdbPerson>[];
    if (cast.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.loc.cast,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: Colors.white70,
              ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cast.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final p = cast[i];
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ActorFilmographyScreen(
                      personId: p.id,
                      name: p.name,
                      photoUrl: p.photoUrl,
                    ),
                  ),
                ),
                child: SizedBox(
                  width: 84,
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 36,
                        backgroundColor: Colors.grey.shade800,
                        backgroundImage: p.photoUrl != null
                            ? CachedNetworkImageProvider(p.photoUrl!)
                            : null,
                        child: p.photoUrl == null
                            ? const Icon(Icons.person, color: Colors.white54)
                            : null,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        p.name,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (p.role != null && p.role!.isNotEmpty)
                        Text(
                          p.role!,
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTmdbHint(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () async {
        final ok = await showTmdbKeyDialog(context);
        if (ok) _loadTmdb();
      },
      icon: const Icon(Icons.info_outline),
      label: const Text('Résumé FR, note et acteurs : ajouter une clé TMDB'),
      style: OutlinedButton.styleFrom(foregroundColor: Colors.white70),
    );
  }

  /// Boutons à côté des infos : favori + bande-annonce.
  Widget _buildActionRow(BuildContext context, WrapAlignment alignment) {
    final trailer = _buildTrailerButton(context);
    return Wrap(
      alignment: alignment,
      spacing: 12,
      runSpacing: 8,
      children: [
        FilledButton.tonalIcon(
          onPressed: _toggleFavorite,
          icon: Icon(
            _isFavorite ? Icons.favorite : Icons.favorite_border,
            color: _isFavorite ? Colors.red : Colors.white,
          ),
          label: Text(_isFavorite ? 'Dans mes favoris' : 'Ajouter aux favoris'),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white.withOpacity(0.12),
            foregroundColor: Colors.white,
          ),
        ),
        if (trailer != null) trailer,
      ],
    );
  }

  Widget? _buildTrailerButton(BuildContext context) {
    final vod = widget.contentItem.vodStream;
    if (vod == null || widget.contentItem.name.isEmpty) {
      return null;
    }

    return FilledButton.tonalIcon(
      onPressed: () => _openTrailer(context),
      icon: const Icon(Icons.ondemand_video),
      label: Text(context.loc.trailer),
      style: FilledButton.styleFrom(
        backgroundColor: Colors.red.withOpacity(0.2),
        foregroundColor: Colors.white,
      ),
    );
  }

  Widget _buildPlayButton(BuildContext context) {
    final theme = Theme.of(context);
    final progress = _progress;
    final hasProgress = !_isLoadingHistory &&
        progress != null &&
        progress > 0.01 &&
        progress < 0.98 &&
        _watchHistory?.totalDuration != null;

    final label = hasProgress
        ? context.loc.continue_watching
        : context.loc.start_watching;

    final children = <Widget>[];

    if (_isLoadingHistory) {
      children.add(const LinearProgressIndicator());
      children.add(const SizedBox(height: 16));
    } else if (hasProgress) {
      children.add(
        LinearProgressIndicator(
          value: progress,
          minHeight: 4,
          backgroundColor: Colors.white24,
          valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
          borderRadius: BorderRadius.circular(2),
        ),
      );
      children.add(const SizedBox(height: 8));
      children.add(
        Text(
          '${_formatDuration(_watchHistory!.watchDuration!)} / '
          '${_formatDuration(_watchHistory!.totalDuration!)}',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium?.copyWith(
            color: Colors.white70,
          ),
        ),
      );
      children.add(const SizedBox(height: 12));
    }

    children.add(
      ElevatedButton.icon(
        onPressed: _openPlayer,
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          backgroundColor: theme.colorScheme.primary,
          foregroundColor: theme.colorScheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 8,
          shadowColor: theme.colorScheme.primary.withOpacity(0.5),
        ),
        icon: const Icon(Icons.play_arrow_rounded, size: 32),
        label: Text(
          label,
          style: theme.textTheme.titleLarge?.copyWith(
            color: theme.colorScheme.onPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    final buffer = StringBuffer();
    if (hours > 0) {
      buffer.write(hours.toString().padLeft(2, '0'));
      buffer.write(':');
    }

    buffer.write(minutes.toString().padLeft(2, '0'));
    buffer.write(':');
    buffer.write(seconds.toString().padLeft(2, '0'));

    return buffer.toString();
  }

  Future<void> _openTrailer(BuildContext context) async {
    final vod = widget.contentItem.vodStream;
    if (vod == null) {
      return;
    }

    final providerTrailer = vod.youtubeTrailer;
    final trailerKey = (providerTrailer != null && providerTrailer.isNotEmpty)
        ? providerTrailer
        : _tmdb?.trailerKey;
    final languageCode = Localizations.localeOf(context).languageCode;

    final String urlString;
    if (trailerKey != null && trailerKey.isNotEmpty) {
      urlString = 'https://www.youtube.com/watch?v=$trailerKey';
    } else {
      final query = Uri.encodeQueryComponent(
        '${widget.contentItem.name} trailer $languageCode',
      );
      urlString = 'https://www.youtube.com/results?search_query=$query';
    }

    final uri = Uri.parse(urlString);
    final launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );

    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.loc.error_occurred_title)),
      );
    }
  }

  void _openPlayer() {
    // Dans la file de lecture, le film est remplacé par la version choisie.
    var replaced = false;
    final queue = _categoryMovies.map((m) {
      if (!replaced &&
          (m.id == _selected.id ||
              m.id == widget.contentItem.id ||
              ContentGrouping.isSameWork(m.name, _selected.name))) {
        replaced = true;
        return _selected;
      }
      return m;
    }).toList();

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => _MoviePlayerPage(
          contentItem: _selected,
          queue: replaced ? queue : [_selected],
        ),
      ),
    );
  }
}

class _DetailEntry {
  final IconData icon;
  final String title;
  final String value;

  _DetailEntry({
    required this.icon,
    required this.title,
    required this.value,
  });
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: Colors.white70,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w500,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;

  const _DetailCard({
    required this.icon,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 20),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MoviePlayerPage extends StatefulWidget {
  final ContentItem contentItem;
  final List<ContentItem> queue;

  const _MoviePlayerPage({required this.contentItem, required this.queue});

  @override
  State<_MoviePlayerPage> createState() => _MoviePlayerPageState();
}

class _MoviePlayerPageState extends State<_MoviePlayerPage> {
  @override
  void initState() {
    super.initState();
    _hideSystemUI();
  }

  @override
  void dispose() {
    _showSystemUI();
    super.dispose();
  }

  void _hideSystemUI() {
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: [],
    );
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );
  }

  void _showSystemUI() {
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SizedBox.expand(
          child: PlayerWidget(
            contentItem: widget.contentItem,
            queue: widget.queue,
          ),
        ),
      ),
    );
  }
}
