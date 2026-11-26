import 'package:another_iptv_player/services/kids_mode.dart';
import 'package:another_iptv_player/database/database.dart';
import 'package:another_iptv_player/models/category_view_model.dart';
import 'package:another_iptv_player/models/content_type.dart';
import 'package:another_iptv_player/models/playlist_content_model.dart';
import 'package:another_iptv_player/services/app_state.dart';
import 'package:another_iptv_player/services/catalog_index.dart';
import 'package:another_iptv_player/services/service_locator.dart';
import 'package:another_iptv_player/utils/content_grouping.dart';
import 'package:another_iptv_player/utils/navigate_by_content_type.dart';
import 'package:another_iptv_player/utils/responsive_helper.dart';
import 'package:another_iptv_player/widgets/content_card.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Page Films / Séries : une barre de filtres cliquables en haut
/// (Tous, Nouveautés, puis chaque catégorie), qui défile avec la molette,
/// et la grille des affiches en dessous.
class ContentBrowser extends StatefulWidget {
  final List<CategoryViewModel> categories;
  final ContentType contentType;

  const ContentBrowser({
    super.key,
    required this.categories,
    required this.contentType,
  });

  @override
  State<ContentBrowser> createState() => _ContentBrowserState();
}

class _Filter {
  final String id;
  final String label;
  final IconData? icon;
  const _Filter(this.id, this.label, [this.icon]);
}

class _ContentBrowserState extends State<ContentBrowser> {
  static const _all = '__all__';
  static const _new = '__new__';
  static const _newCount = 300;

  final _chipScroll = ScrollController();
  final _gridScroll = ScrollController();

  String _selected = _all;
  bool _loading = true;

  /// Tous les éléments, du plus récent au plus ancien.
  List<ContentItem> _allItems = [];
  final Map<String, Future<List<ContentItem>>> _cache = {};

  List<_Filter> get _filters => [
        const _Filter(_all, 'Tous', Icons.apps),
        const _Filter(_new, 'Nouveautés', Icons.fiber_new),
        for (final c in widget.categories)
          _Filter(c.category.categoryId, c.category.categoryName),
      ];

  @override
  void initState() {
    super.initState();
    for (final c in widget.categories) {
      KidsMode.registerCategory(c.category.categoryId, c.category.categoryName);
    }
    _load();
  }

  @override
  void didUpdateWidget(covariant ContentBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.categories.length != widget.categories.length) {
      _cache.clear();
      _load();
    }
  }

  @override
  void dispose() {
    _chipScroll.dispose();
    _gridScroll.dispose();
    super.dispose();
  }

  static int _idNum(String id) => int.tryParse(id) ?? 0;

  Future<void> _load() async {
    final playlistId = AppState.currentPlaylist?.id;
    if (playlistId == null) return;
    final db = getIt<AppDatabase>();
    final visible = widget.categories.map((c) => c.category.categoryId).toSet();

    List<ContentItem> items;
    if (widget.contentType == ContentType.vod) {
      final movies = [...await db.getVodStreamsByPlaylistId(playlistId)];
      movies.removeWhere((m) => !visible.contains(m.categoryId));
      // Sur les serveurs Xtream, un numéro plus grand = ajouté plus récemment.
      movies.sort((a, b) => _idNum(b.streamId).compareTo(_idNum(a.streamId)));
      items = movies.map(CatalogIndex.movieToItem).toList();
    } else {
      final series = [...await db.getSeriesStreamsByPlaylistId(playlistId)];
      series.removeWhere((s) => !visible.contains(s.categoryId));
      series.sort((a, b) {
        final la = int.tryParse(a.lastModified ?? '') ?? _idNum(a.seriesId);
        final lb = int.tryParse(b.lastModified ?? '') ?? _idNum(b.seriesId);
        return lb.compareTo(la);
      });
      items = series.map(CatalogIndex.seriesToItem).toList();
    }

    if (!mounted) return;
    setState(() {
      _allItems = items;
      _cache.clear();
      _loading = false;
    });
  }

  String? _categoryOf(ContentItem item) => widget.contentType == ContentType.vod
      ? item.vodStream?.categoryId
      : item.seriesStream?.categoryId;

  Future<List<ContentItem>> _itemsFor(String filter) =>
      _cache[filter] ??= _computeItems(filter);

  Future<List<ContentItem>> _computeItems(String filter) async {
    List<ContentItem> raw;
    if (filter == _all) {
      raw = _allItems;
    } else if (filter == _new) {
      raw = _allItems.take(_newCount * 2).toList();
    } else {
      raw = _allItems.where((i) => _categoryOf(i) == filter).toList();
    }

    var result = raw;
    if (raw.isNotEmpty) {
      // Une seule affiche par film / série (calcul en arrière-plan).
      final keys = await compute(
        ContentGrouping.groupKeysFor,
        raw.map((i) => i.name).toList(),
      );
      result = ContentGrouping.groupByKeys(raw, keys);
    }
    if (filter == _new && result.length > _newCount) {
      result = result.take(_newCount).toList();
    }
    return result;
  }

  void _select(String id) {
    if (id == _selected) return;
    setState(() => _selected = id);
    if (_gridScroll.hasClients) _gridScroll.jumpTo(0);
  }

  /// La molette (verticale) fait défiler la barre horizontalement.
  void _onWheel(PointerSignalEvent event) {
    if (event is PointerScrollEvent && _chipScroll.hasClients) {
      final delta = event.scrollDelta.dy != 0
          ? event.scrollDelta.dy
          : event.scrollDelta.dx;
      final pos = _chipScroll.position;
      _chipScroll.jumpTo(
        (pos.pixels + delta).clamp(pos.minScrollExtent, pos.maxScrollExtent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildFilterBar(context),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : FutureBuilder<List<ContentItem>>(
                  key: ValueKey(_selected),
                  future: _itemsFor(_selected),
                  builder: (context, snap) {
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return _buildGrid(context, snap.data!);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildFilterBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filters = _filters;
    return Listener(
      onPointerSignal: _onWheel,
      child: SizedBox(
        height: 56,
        child: Scrollbar(
          controller: _chipScroll,
          thickness: 3,
          child: ListView.separated(
            controller: _chipScroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            itemCount: filters.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final f = filters[i];
              final selected = f.id == _selected;
              return Material(
                color: selected
                    ? scheme.primary
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _select(f.id),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (f.icon != null) ...[
                          Icon(
                            f.icon,
                            size: 18,
                            color: selected
                                ? scheme.onPrimary
                                : scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          f.label,
                          style: TextStyle(
                            fontWeight:
                                selected ? FontWeight.bold : FontWeight.w500,
                            color: selected
                                ? scheme.onPrimary
                                : scheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(BuildContext context, List<ContentItem> items) {
    if (items.isEmpty) {
      return const Center(
        child: Text('Rien dans cette catégorie.',
            style: TextStyle(color: Colors.grey)),
      );
    }
    return Scrollbar(
      controller: _gridScroll,
      interactive: true,
      child: GridView.builder(
        controller: _gridScroll,
        padding: const EdgeInsets.all(12),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: ResponsiveHelper.getCrossAxisCount(context),
          childAspectRatio: 0.65,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) => ContentCard(
          content: items[i],
          width: 150,
          onTap: () => navigateByContentType(context, items[i]),
        ),
      ),
    );
  }
}
