import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Clé du navigateur principal (utilisée par les boutons de la souris).
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Garde en mémoire les pages fermées avec "Retour" pour pouvoir y revenir
/// avec "Avancer", comme dans un navigateur web.
class MouseNavigationObserver extends NavigatorObserver {
  MouseNavigationObserver._();
  static final MouseNavigationObserver instance = MouseNavigationObserver._();

  final List<WidgetBuilder> _forward = [];
  bool _goingBack = false;
  bool _goingForward = false;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // Une nouvelle page ouverte normalement efface l'historique "Avancer".
    if (!_goingForward && route is PageRoute) _forward.clear();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_goingBack && route is MaterialPageRoute) {
      _forward.add(route.builder);
    }
  }

  Future<void> back() async {
    final nav = appNavigatorKey.currentState;
    if (nav == null) return;
    _goingBack = true;
    try {
      await nav.maybePop();
    } finally {
      _goingBack = false;
    }
  }

  void forward() {
    final nav = appNavigatorKey.currentState;
    if (nav == null || _forward.isEmpty) return;
    final builder = _forward.removeLast();
    _goingForward = true;
    try {
      nav.push(MaterialPageRoute(builder: builder));
    } finally {
      _goingForward = false;
    }
  }
}

/// Écoute les boutons latéraux de la souris (Retour / Avancer).
class MouseNavigationListener extends StatelessWidget {
  final Widget child;
  const MouseNavigationListener({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.kind != PointerDeviceKind.mouse) return;
        if (event.buttons & kBackMouseButton != 0) {
          MouseNavigationObserver.instance.back();
        } else if (event.buttons & kForwardMouseButton != 0) {
          MouseNavigationObserver.instance.forward();
        }
      },
      child: child,
    );
  }
}
