import 'dart:ui';

import 'package:another_iptv_player/models/content_type.dart';
import 'package:another_iptv_player/models/playlist_content_model.dart';
import 'package:another_iptv_player/services/kids_mode.dart';
import 'package:another_iptv_player/services/tmdb_service.dart';
import 'package:flutter/material.dart';

/// Bouton œil général : active / désactive le mode enfants.
class KidsModeButton extends StatelessWidget {
  final bool onDarkBackground;
  const KidsModeButton({super.key, this.onDarkBackground = false});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: KidsMode.enabled,
      builder: (context, on, _) {
        final button = IconButton(
          tooltip: on
              ? 'Mode enfants activé : affiches -10 ans et horreur floutées'
              : 'Activer le mode enfants (flouter -10 ans et horreur)',
          icon: Icon(
            on ? Icons.visibility_off : Icons.visibility,
            color: on
                ? Colors.amber
                : (onDarkBackground ? Colors.white : null),
          ),
          onPressed: () {
            KidsMode.toggle();
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(
                duration: const Duration(seconds: 2),
                content: Text(
                  KidsMode.enabled.value
                      ? 'Mode enfants activé'
                      : 'Mode enfants désactivé',
                ),
              ));
          },
        );
        if (!onDarkBackground) return button;
        return Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5),
            shape: BoxShape.circle,
          ),
          child: button,
        );
      },
    );
  }
}

/// Floute une affiche si le mode enfants est actif et que le contenu est
/// déconseillé aux moins de 10 ans ou est un film d'horreur.
/// Un petit œil sur l'affiche permet à l'adulte de la voir quand même.
class KidsGuard extends StatefulWidget {
  final ContentItem item;
  final Widget child;
  final bool compact;

  /// Afficher le petit œil individuel (non pour les fonds d'écran).
  final bool showEye;

  const KidsGuard({
    super.key,
    required this.item,
    required this.child,
    this.compact = true,
    this.showEye = true,
  });

  @override
  State<KidsGuard> createState() => _KidsGuardState();
}

class _KidsGuardState extends State<KidsGuard> {
  bool get _applies =>
      widget.item.contentType == ContentType.vod ||
      widget.item.contentType == ContentType.series;

  @override
  Widget build(BuildContext context) {
    if (!_applies) return widget.child;
    return ValueListenableBuilder<bool>(
      valueListenable: KidsMode.enabled,
      builder: (context, on, _) {
        if (!on) return widget.child;
        return ValueListenableBuilder<int>(
          valueListenable: KidsMode.revision,
          builder: (context, _, __) => _buildGuarded(context),
        );
      },
    );
  }

  Widget _buildGuarded(BuildContext context) {
    final item = widget.item;
    var unsafe = KidsMode.heuristicUnsafe(item);
    var pending = false;
    if (!unsafe) {
      final info = KidsMode.cached(item);
      if (info != null) {
        unsafe = info.unsafe;
      } else if (TmdbService.instance.isConfiguredSync) {
        pending = true; // on vérifie : flouté en attendant
        KidsMode.check(item);
      }
    }

    final revealed = KidsMode.isRevealed(item);
    final blurred = (unsafe || pending) && !revealed;
    if (!unsafe && !pending) return widget.child;

    final size = widget.compact ? 16.0 : 22.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (blurred)
          ClipRect(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: widget.child,
            ),
          )
        else
          widget.child,
        if (blurred && widget.showEye)
          Center(
            child: Icon(
              pending ? Icons.hourglass_top : Icons.child_care,
              color: Colors.white70,
              size: widget.compact ? 28 : 48,
            ),
          ),
        // Œil individuel : voir / re-flouter cette affiche.
        if (widget.showEye)
        Positioned(
          left: 6,
          top: widget.compact ? 26 : 6,
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => KidsMode.toggleReveal(item),
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Tooltip(
                  message: revealed ? 'Flouter à nouveau' : 'Voir l\'affiche',
                  child: Icon(
                    revealed ? Icons.visibility_off : Icons.visibility,
                    color: Colors.white,
                    size: size,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
