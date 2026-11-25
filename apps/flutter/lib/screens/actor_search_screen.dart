import 'dart:async';

import 'package:another_iptv_player/models/playlist_content_model.dart';
import 'package:another_iptv_player/services/catalog_index.dart';
import 'package:another_iptv_player/services/tmdb_service.dart';
import 'package:another_iptv_player/utils/content_grouping.dart';
import 'package:another_iptv_player/utils/get_playlist_type.dart';
import 'package:another_iptv_player/utils/navigate_by_content_type.dart';
import 'package:another_iptv_player/utils/responsive_helper.dart';
import 'package:another_iptv_player/widgets/content_card.dart';
import 'package:another_iptv_player/widgets/tmdb_key_dialog.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Recherche un acteur / une actrice (ou un réalisateur) puis affiche
/// ses films et séries disponibles dans l'abonnement.
class ActorSearchScreen extends StatefulWidget {
  const ActorSearchScreen({super.key});

  @override
  State<ActorSearchScreen> createState() => _ActorSearchScreenState();
}

class _ActorSearchScreenState extends State<ActorSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  bool? _configured;
  List<TmdbPerson> _results = [];

  @override
  void initState() {
    super.initState();
    _checkConfig();
    CatalogIndex.ensureLoaded(); // prépare l'index pendant la saisie
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    TmdbService.instance.language =
        Localizations.localeOf(context).languageCode;
  }

  Future<void> _checkConfig() async {
    final ok = await TmdbService.instance.isConfigured;
    if (mounted) setState(() => _configured = ok);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(value));
  }

  Future<void> _search(String value) async {
    if (value.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() => _loading = true);
    final people = await TmdbService.instance.searchPeople(value);
    if (!mounted) return;
    setState(() {
      _results = people;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Nom d\'un acteur, d\'une actrice…',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
          onSubmitted: _search,
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_configured == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_configured == false) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_search, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              const Text(
                'La recherche par acteur utilise TMDB.\n'
                'Ajoute ta clé gratuite pour l\'activer.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  await showTmdbKeyDialog(context);
                  _checkConfig();
                },
                child: const Text('Ajouter ma clé TMDB'),
              ),
            ],
          ),
        ),
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_results.isEmpty) {
      return const Center(
        child: Icon(Icons.person_search, size: 64, color: Colors.grey),
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final p = _results[i];
        return ListTile(
          leading: _Avatar(url: p.photoUrl, radius: 24),
          title: Text(p.name),
          subtitle: p.department != null ? Text(_department(p.department!)) : null,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ActorFilmographyScreen(
                personId: p.id,
                name: p.name,
                photoUrl: p.photoUrl,
              ),
            ),
          ),
        );
      },
    );
  }

  String _department(String d) {
    switch (d) {
      case 'Acting':
        return 'Acteur / actrice';
      case 'Directing':
        return 'Réalisation';
      case 'Writing':
        return 'Scénario';
      default:
        return d;
    }
  }
}

/// Films et séries d'une personne qui sont disponibles dans l'abonnement.
class ActorFilmographyScreen extends StatefulWidget {
  final int personId;
  final String name;
  final String? photoUrl;

  const ActorFilmographyScreen({
    super.key,
    required this.personId,
    required this.name,
    this.photoUrl,
  });

  @override
  State<ActorFilmographyScreen> createState() => _ActorFilmographyScreenState();
}

class _ActorFilmographyScreenState extends State<ActorFilmographyScreen> {
  bool _loading = true;
  List<ContentItem> _movies = [];
  List<ContentItem> _series = [];
  int _totalCredits = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final credits = await TmdbService.instance.getPersonCredits(widget.personId);
    final movies = <ContentItem>[];
    final series = <ContentItem>[];

    if (isXtreamCode) {
      await CatalogIndex.ensureLoaded();
      for (final c in credits) {
        final titles = [c.title, if (c.originalTitle != null) c.originalTitle!];
        if (c.isTv) {
          final found = await CatalogIndex.findSeries(titles);
          if (found.isNotEmpty) series.add(found.first);
        } else {
          final found = await CatalogIndex.findMovies(titles, year: c.year);
          if (found.isNotEmpty) {
            movies.addAll(ContentGrouping.groupMovies(found).take(1));
          }
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _totalCredits = credits.length;
      _movies = movies;
      _series = series;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            _Avatar(url: widget.photoUrl, radius: 18),
            const SizedBox(width: 12),
            Expanded(child: Text(widget.name, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_movies.isEmpty && _series.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _totalCredits == 0
                ? 'Aucune filmographie trouvée.'
                : 'Aucun des $_totalCredits films / séries de ${widget.name} '
                    'n\'est dans ton abonnement.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        if (_movies.isNotEmpty) ..._section(context, 'Films (${_movies.length})', _movies),
        if (_series.isNotEmpty) ..._section(context, 'Séries (${_series.length})', _series),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  List<Widget> _section(BuildContext context, String title, List<ContentItem> items) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: ResponsiveHelper.getCrossAxisCount(context),
            childAspectRatio: 0.65,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => ContentCard(
              content: items[i],
              width: 150,
              onTap: () => navigateByContentType(context, items[i]),
            ),
            childCount: items.length,
          ),
        ),
      ),
    ];
  }
}

class _Avatar extends StatelessWidget {
  final String? url;
  final double radius;
  const _Avatar({required this.url, required this.radius});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors.grey.shade800,
      backgroundImage: url != null ? CachedNetworkImageProvider(url!) : null,
      child: url == null ? Icon(Icons.person, size: radius) : null,
    );
  }
}
