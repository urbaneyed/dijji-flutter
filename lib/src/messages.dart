import 'dart:async';

import 'package:flutter/material.dart';

import 'logger.dart';

/// In-app message renderer. Subscribes to the inbox stream and presents
/// banner / bottom_sheet / modal cards via Flutter's [Overlay].
///
/// Mirrors `dijji-messages` on Android and `DijjiMessages` on iOS:
///   - **banner**: top or bottom slide-in strip, auto-dismiss after TTL.
///   - **bottom_sheet**: drag-to-dismiss sheet pinned to the bottom.
///   - **modal**: centred card with a backdrop, dismissed via X or backdrop tap.
///
/// Each message is queued and presented sequentially so two pushes in quick
/// succession don't stack on top of each other. CTA taps fire a callback the
/// host SDK turns into `__dijji_message_clicked` events.
typedef MessageEventCallback = void Function(
  String event, {
  Map<String, Object?>? properties,
});

class MessageRenderer {
  MessageRenderer({
    required GlobalKey<NavigatorState> navigatorKey,
    required MessageEventCallback onMessageEvent,
  })  : _navigatorKey = navigatorKey,
        _onMessageEvent = onMessageEvent;

  final GlobalKey<NavigatorState> _navigatorKey;
  final MessageEventCallback _onMessageEvent;
  final List<Map<String, Object?>> _queue = [];
  bool _showing = false;
  StreamSubscription<List<Map<String, Object?>>>? _sub;

  void attach(Stream<List<Map<String, Object?>>> stream) {
    _sub?.cancel();
    _sub = stream.listen(_enqueueAll);
  }

  void detach() {
    _sub?.cancel();
    _sub = null;
  }

  void _enqueueAll(List<Map<String, Object?>> batch) {
    _queue.addAll(batch);
    _drain();
  }

  Future<void> _drain() async {
    if (_showing) return;
    while (_queue.isNotEmpty) {
      final msg = _queue.removeAt(0);
      _showing = true;
      try {
        await _present(msg);
      } catch (e) {
        DijjiLog.w('message render failed: $e');
      } finally {
        _showing = false;
      }
    }
  }

  Future<void> _present(Map<String, Object?> msg) async {
    final ctx = _navigatorKey.currentState?.overlay?.context;
    if (ctx == null) {
      DijjiLog.d('no overlay context — dropping message ${msg['id']}');
      return;
    }
    final id = (msg['id'] as num?)?.toInt() ?? 0;
    final kind = msg['kind'] as String? ?? '';
    final cfg = (msg['config'] is Map)
        ? Map<String, Object?>.from(msg['config'] as Map)
        : <String, Object?>{};

    _onMessageEvent('__dijji_message_received', properties: {
      'message_id': id,
      'kind': kind,
    });

    switch (kind) {
      case 'in_app_banner':
        await _showBanner(ctx, id, cfg);
        break;
      case 'in_app_bottom_sheet':
        await _showBottomSheet(ctx, id, cfg);
        break;
      case 'in_app_modal':
        await _showModal(ctx, id, cfg);
        break;
      default:
        DijjiLog.d('unknown message kind: $kind');
    }
  }

  // ── Banner — top or bottom strip ────────────────────────────

  Future<void> _showBanner(
    BuildContext ctx,
    int id,
    Map<String, Object?> cfg,
  ) async {
    final ttlMs = (cfg['duration_ms'] as num?)?.toInt() ?? 4000;
    final position = cfg['position'] == 'top' ? 'top' : 'bottom';
    final completer = Completer<void>();
    // Pull the overlay directly off the navigator key. Calling
    // `Overlay.of(ctx, rootOverlay: true)` where `ctx` IS the overlay's own
    // context fires an assertion in Flutter 3.16+ — _drain swallows the
    // throw and the banner silently never renders. Modals weren't affected
    // because showDialog uses the navigator path. Bug surfaced on the byde
    // app on 2026-04-30.
    final overlayState = _navigatorKey.currentState?.overlay;
    if (overlayState == null) {
      DijjiLog.w('banner: navigator overlay not ready');
      return;
    }
    late OverlayEntry entry;
    Timer? timeout;

    void dismiss(String reason) {
      timeout?.cancel();
      if (entry.mounted) entry.remove();
      _onMessageEvent('__dijji_message_dismissed', properties: {
        'message_id': id,
        'kind': 'in_app_banner',
        'reason': reason,
      });
      if (!completer.isCompleted) completer.complete();
    }

    entry = OverlayEntry(builder: (_) {
      return _BannerWidget(
        position: position,
        title: cfg['title'] as String?,
        body: cfg['body'] as String?,
        cta: cfg['cta_text'] as String?,
        accent: _parseColor(cfg['accent']),
        onCta: () {
          _onMessageEvent('__dijji_message_clicked', properties: {
            'message_id': id,
            'kind': 'in_app_banner',
            if (cfg['cta_url'] is String) 'cta_url': cfg['cta_url'],
          });
          dismiss('cta');
        },
        onClose: () => dismiss('manual'),
      );
    });
    overlayState.insert(entry);
    timeout = Timer(Duration(milliseconds: ttlMs), () => dismiss('ttl'));
    return completer.future;
  }

  // ── Bottom sheet ─────────────────────────────────────────────

  Future<void> _showBottomSheet(
    BuildContext ctx,
    int id,
    Map<String, Object?> cfg,
  ) async {
    var dismissReason = 'manual';
    await showModalBottomSheet<void>(
      context: ctx,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SheetWidget(
        title: cfg['title'] as String?,
        body: cfg['body'] as String?,
        cta: cfg['cta_text'] as String?,
        accent: _parseColor(cfg['accent']),
        onCta: () {
          dismissReason = 'cta';
          _onMessageEvent('__dijji_message_clicked', properties: {
            'message_id': id,
            'kind': 'in_app_bottom_sheet',
            if (cfg['cta_url'] is String) 'cta_url': cfg['cta_url'],
          });
          Navigator.of(ctx, rootNavigator: true).pop();
        },
      ),
    );
    _onMessageEvent('__dijji_message_dismissed', properties: {
      'message_id': id,
      'kind': 'in_app_bottom_sheet',
      'reason': dismissReason,
    });
  }

  // ── Modal — centre card with backdrop ────────────────────────

  Future<void> _showModal(
    BuildContext ctx,
    int id,
    Map<String, Object?> cfg,
  ) async {
    var dismissReason = 'manual';
    await showDialog<void>(
      context: ctx,
      barrierDismissible: true,
      builder: (_) => _ModalWidget(
        title: cfg['title'] as String?,
        body: cfg['body'] as String?,
        cta: cfg['cta_text'] as String?,
        accent: _parseColor(cfg['accent']),
        onCta: () {
          dismissReason = 'cta';
          _onMessageEvent('__dijji_message_clicked', properties: {
            'message_id': id,
            'kind': 'in_app_modal',
            if (cfg['cta_url'] is String) 'cta_url': cfg['cta_url'],
          });
          Navigator.of(ctx, rootNavigator: true).pop();
        },
      ),
    );
    _onMessageEvent('__dijji_message_dismissed', properties: {
      'message_id': id,
      'kind': 'in_app_modal',
      'reason': dismissReason,
    });
  }

  Color? _parseColor(Object? raw) {
    if (raw is! String) return null;
    final hex = raw.replaceAll('#', '');
    if (hex.length == 6) return Color(int.parse('ff$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}

// ── Widgets ──────────────────────────────────────────────────────

class _BannerWidget extends StatefulWidget {
  const _BannerWidget({
    required this.position,
    required this.title,
    required this.body,
    required this.cta,
    required this.accent,
    required this.onCta,
    required this.onClose,
  });

  final String position;
  final String? title;
  final String? body;
  final String? cta;
  final Color? accent;
  final VoidCallback onCta;
  final VoidCallback onClose;

  @override
  State<_BannerWidget> createState() => _BannerWidgetState();
}

class _BannerWidgetState extends State<_BannerWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _slide = Tween<Offset>(
      begin: Offset(0, widget.position == 'top' ? -1 : 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final accent = widget.accent ?? const Color(0xFFA882FF);
    return Positioned(
      left: 12,
      right: 12,
      top: widget.position == 'top' ? mq.padding.top + 12 : null,
      bottom: widget.position == 'bottom' ? mq.padding.bottom + 12 : null,
      child: SlideTransition(
        position: _slide,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A28),
              borderRadius: BorderRadius.circular(14),
              border: Border(left: BorderSide(color: accent, width: 3)),
              boxShadow: const [
                BoxShadow(blurRadius: 20, color: Color(0x55000000)),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.title != null && widget.title!.isNotEmpty)
                        Text(
                          widget.title!,
                          style: const TextStyle(
                            color: Color(0xFFF5F5FA),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (widget.body != null && widget.body!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            widget.body!,
                            style: const TextStyle(color: Color(0xFFB5B5C8)),
                          ),
                        ),
                    ],
                  ),
                ),
                if (widget.cta != null && widget.cta!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: TextButton(
                      onPressed: widget.onCta,
                      style: TextButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(widget.cta!),
                    ),
                  ),
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close,
                      color: Color(0xFF7A7A90), size: 18),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetWidget extends StatelessWidget {
  const _SheetWidget({
    required this.title,
    required this.body,
    required this.cta,
    required this.accent,
    required this.onCta,
  });

  final String? title;
  final String? body;
  final String? cta;
  final Color? accent;
  final VoidCallback onCta;

  @override
  Widget build(BuildContext context) {
    final acc = accent ?? const Color(0xFFA882FF);
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF12121C),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0x22FFFFFF)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 4,
              width: 36,
              alignment: Alignment.center,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF4A4A5C),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (title != null && title!.isNotEmpty)
              Text(
                title!,
                style: const TextStyle(
                  color: Color(0xFFF5F5FA),
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            if (body != null && body!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 18),
                child: Text(
                  body!,
                  style:
                      const TextStyle(color: Color(0xFFB5B5C8), height: 1.45),
                ),
              ),
            if (cta != null && cta!.isNotEmpty)
              ElevatedButton(
                onPressed: onCta,
                style: ElevatedButton.styleFrom(
                  backgroundColor: acc,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(cta!),
              ),
          ],
        ),
      ),
    );
  }
}

class _ModalWidget extends StatelessWidget {
  const _ModalWidget({
    required this.title,
    required this.body,
    required this.cta,
    required this.accent,
    required this.onCta,
  });

  final String? title;
  final String? body;
  final String? cta;
  final Color? accent;
  final VoidCallback onCta;

  @override
  Widget build(BuildContext context) {
    final acc = accent ?? const Color(0xFFA882FF);
    return Dialog(
      backgroundColor: const Color(0xFF12121C),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null && title!.isNotEmpty)
              Text(
                title!,
                style: const TextStyle(
                  color: Color(0xFFF5F5FA),
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            if (body != null && body!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 24),
                child: Text(
                  body!,
                  style: const TextStyle(color: Color(0xFFB5B5C8), height: 1.5),
                  textAlign: TextAlign.center,
                ),
              ),
            if (cta != null && cta!.isNotEmpty)
              ElevatedButton(
                onPressed: onCta,
                style: ElevatedButton.styleFrom(
                  backgroundColor: acc,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(cta!),
              ),
          ],
        ),
      ),
    );
  }
}
