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
///   - **survey**: multi-step bottom sheet, /t/survey ingestion.
///
/// Each message is queued and presented sequentially so two pushes in quick
/// succession don't stack on top of each other. CTA taps fire a callback the
/// host SDK turns into `__dijji_message_clicked` events.
typedef MessageEventCallback = void Function(
  String event, {
  Map<String, Object?>? properties,
});

/// Survey transport callback — host SDK supplies the actual HTTP impl
/// (Transport.postSurvey). MessageRenderer stays free of HTTP knowledge.
/// Body shape: { action, site, survey_id?, response_id?, question_id?,
/// question_type?, value?, visitor_id?, ... }. Returns server JSON.
typedef SurveyPostCallback = Future<Map<String, Object?>?> Function(
  Map<String, Object?> body,
);

class MessageRenderer {
  MessageRenderer({
    required GlobalKey<NavigatorState> navigatorKey,
    required MessageEventCallback onMessageEvent,
    SurveyPostCallback? onSurveyPost,
    String? siteKey,
    String? visitorId,
  })  : _navigatorKey = navigatorKey,
        _onMessageEvent = onMessageEvent,
        _onSurveyPost = onSurveyPost,
        _siteKey = siteKey,
        _visitorId = visitorId;

  final GlobalKey<NavigatorState> _navigatorKey;
  final MessageEventCallback _onMessageEvent;
  final SurveyPostCallback? _onSurveyPost;
  final String? _siteKey;
  final String? _visitorId;
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
      case 'in_app_hero':
        await _showHero(ctx, id, cfg);
        break;
      case 'in_app_nps':
        await _showNps(ctx, id, cfg);
        break;
      case 'in_app_reactions':
        await _showReactions(ctx, id, cfg);
        break;
      case 'in_app_countdown':
        await _showCountdown(ctx, id, cfg);
        break;
      case 'in_app_survey':
        await _showSurvey(ctx, id, cfg);
        break;
      default:
        DijjiLog.d('unknown message kind: $kind');
    }
  }

  // ── Survey — multi-step bottom sheet ────────────────────────

  Future<void> _showSurvey(
    BuildContext ctx,
    int id,
    Map<String, Object?> cfg,
  ) async {
    final surveyId = cfg['survey_id'];
    final questionsRaw = cfg['questions'];
    if (surveyId == null || questionsRaw is! List || questionsRaw.isEmpty) {
      DijjiLog.d('survey config malformed (no questions)');
      return;
    }
    final questions = questionsRaw
        .whereType<Map>()
        .map<Map<String, Object?>>(Map<String, Object?>.from)
        .toList();
    final endScreen = cfg['end_screen'] is Map
        ? Map<String, Object?>.from(cfg['end_screen'] as Map)
        : <String, Object?>{};

    // START — get a response_id from the server. If it fails (e.g.
    // already_completed / 409), bail without rendering the sheet.
    int? responseId;
    if (_onSurveyPost != null) {
      final res = await _onSurveyPost!({
        'action': 'start',
        'site': _siteKey,
        'survey_id': surveyId,
        'visitor_id': _visitorId,
        'platform': 'flutter',
      });
      if (res == null || res['ok'] != true) {
        DijjiLog.d('survey start rejected: ${res?['error']}');
        return;
      }
      final rid = res['response_id'];
      if (rid is int) {
        responseId = rid;
      } else if (rid is String) {
        responseId = int.tryParse(rid);
      }
    }

    var dismissReason = 'manual';
    await showModalBottomSheet<void>(
      context: ctx,
      isDismissible: true,
      enableDrag: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SurveyWidget(
        surveyId: surveyId is int ? surveyId : int.tryParse('$surveyId') ?? 0,
        responseId: responseId ?? 0,
        questions: questions,
        endScreen: endScreen,
        siteKey: _siteKey,
        onSurveyPost: _onSurveyPost,
        onCompleted: () {
          dismissReason = 'completed';
        },
      ),
    );
    _onMessageEvent('__dijji_message_dismissed', properties: {
      'message_id': id,
      'kind': 'in_app_survey',
      'reason': dismissReason,
    });
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
        imageUrl: cfg['image_url'] as String?,
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
        imageUrl: cfg['image_url'] as String?,
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
        imageUrl: cfg['image_url'] as String?,
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

  // ── Hero — full-bleed takeover with hero image ───────────────

  Future<void> _showHero(
    BuildContext ctx,
    int id,
    Map<String, Object?> cfg,
  ) async {
    var dismissReason = 'manual';
    await showGeneralDialog<void>(
      context: ctx,
      barrierDismissible: true,
      barrierLabel: 'dismiss',
      barrierColor: const Color(0xCC000000),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (dlgCtx, anim, _, __) {
        final scale = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(scale),
            child: _HeroWidget(
              title: cfg['title'] as String?,
              body: cfg['body'] as String?,
              cta: cfg['cta_text'] as String?,
              secondaryCta: cfg['secondary_cta_text'] as String?,
              imageUrl: cfg['image_url'] as String?,
              accent: _parseColor(cfg['accent']),
              onCta: () {
                dismissReason = 'cta';
                _onMessageEvent('__dijji_message_clicked', properties: {
                  'message_id': id,
                  'kind': 'in_app_hero',
                  if (cfg['cta_url'] is String) 'cta_url': cfg['cta_url'],
                });
                Navigator.of(dlgCtx, rootNavigator: true).pop();
              },
              onSecondary: () {
                dismissReason = 'secondary';
                _onMessageEvent('__dijji_message_clicked', properties: {
                  'message_id': id,
                  'kind': 'in_app_hero',
                  'choice': 'secondary',
                });
                Navigator.of(dlgCtx, rootNavigator: true).pop();
              },
              onClose: () => Navigator.of(dlgCtx, rootNavigator: true).pop(),
            ),
          ),
        );
      },
    );
    _onMessageEvent('__dijji_message_dismissed', properties: {
      'message_id': id,
      'kind': 'in_app_hero',
      'reason': dismissReason,
    });
  }

  // ── NPS — 0–10 score with low/high labels ────────────────────

  Future<void> _showNps(
    BuildContext ctx,
    int id,
    Map<String, Object?> cfg,
  ) async {
    var dismissReason = 'manual';
    int? submittedScore;
    await showModalBottomSheet<void>(
      context: ctx,
      isDismissible: true,
      enableDrag: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => _NpsWidget(
        question: cfg['question'] as String?,
        lowLabel: cfg['low_label'] as String?,
        highLabel: cfg['high_label'] as String?,
        thanks: cfg['thanks'] as String?,
        accent: _parseColor(cfg['accent']),
        onSubmit: (score) {
          submittedScore = score;
          dismissReason = 'submitted';
          _onMessageEvent('__dijji_nps_submitted', properties: {
            'message_id': id,
            'score': score,
          });
          // Sheet auto-closes itself after the thank-you flash; we just record.
        },
        onClose: () => Navigator.of(sheetCtx, rootNavigator: true).pop(),
      ),
    );
    _onMessageEvent('__dijji_message_dismissed', properties: {
      'message_id': id,
      'kind': 'in_app_nps',
      'reason': dismissReason,
      if (submittedScore != null) 'score': submittedScore,
    });
  }

  // ── Reaction bar — emoji feedback ────────────────────────────

  Future<void> _showReactions(
    BuildContext ctx,
    int id,
    Map<String, Object?> cfg,
  ) async {
    var dismissReason = 'manual';
    String? choice;
    int? choiceIdx;
    final rawEmojis = cfg['emojis'];
    final emojis = <String>[];
    if (rawEmojis is List) {
      for (final e in rawEmojis) {
        if (e is String && e.isNotEmpty) emojis.add(e);
      }
    }
    if (emojis.isEmpty) {
      emojis.addAll(['😍', '🙂', '😐', '😕']);
    }
    await showModalBottomSheet<void>(
      context: ctx,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => _ReactionsWidget(
        question: cfg['question'] as String?,
        thanks: cfg['thanks'] as String?,
        emojis: emojis,
        accent: _parseColor(cfg['accent']),
        onPick: (emoji, idx) {
          choice = emoji;
          choiceIdx = idx;
          dismissReason = 'submitted';
          _onMessageEvent('__dijji_reaction_submitted', properties: {
            'message_id': id,
            'reaction': emoji,
            'index': idx,
          });
        },
        onClose: () => Navigator.of(sheetCtx, rootNavigator: true).pop(),
      ),
    );
    _onMessageEvent('__dijji_message_dismissed', properties: {
      'message_id': id,
      'kind': 'in_app_reactions',
      'reason': dismissReason,
      if (choice != null) 'reaction': choice,
      if (choiceIdx != null) 'index': choiceIdx,
    });
  }

  // ── Countdown — live ticker urgency modal ────────────────────

  Future<void> _showCountdown(
    BuildContext ctx,
    int id,
    Map<String, Object?> cfg,
  ) async {
    var dismissReason = 'manual';
    final deadline = _parseDeadline(cfg['deadline']);
    if (deadline == null) {
      DijjiLog.w('countdown: missing or unparseable deadline — dropping');
      return;
    }
    await showDialog<void>(
      context: ctx,
      barrierDismissible: true,
      builder: (dlgCtx) => _CountdownWidget(
        title: cfg['title'] as String?,
        body: cfg['body'] as String?,
        cta: cfg['cta_text'] as String?,
        endedText: cfg['ended_text'] as String?,
        imageUrl: cfg['image_url'] as String?,
        deadline: deadline,
        accent: _parseColor(cfg['accent']),
        onCta: () {
          dismissReason = 'cta';
          _onMessageEvent('__dijji_message_clicked', properties: {
            'message_id': id,
            'kind': 'in_app_countdown',
            if (cfg['cta_url'] is String) 'cta_url': cfg['cta_url'],
          });
          Navigator.of(dlgCtx, rootNavigator: true).pop();
        },
        onClose: () => Navigator.of(dlgCtx, rootNavigator: true).pop(),
      ),
    );
    _onMessageEvent('__dijji_message_dismissed', properties: {
      'message_id': id,
      'kind': 'in_app_countdown',
      'reason': dismissReason,
    });
  }

  /// Resolves a deadline config value into a UTC DateTime. Accepts:
  ///  - ISO-8601 strings (`2026-05-01T18:00:00Z`)
  ///  - Relative offsets (`+24 hours`, `+30 minutes`, `+3 days`)
  ///  - Unix timestamps in seconds (number)
  /// Returns null when the value can't be parsed — caller drops the message
  /// rather than rendering a broken timer.
  DateTime? _parseDeadline(Object? raw) {
    if (raw == null) return null;
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch(raw.toInt() * 1000,
          isUtc: true);
    }
    if (raw is! String || raw.isEmpty) return null;
    final s = raw.trim();
    if (s.startsWith('+')) {
      final m = RegExp(r'^\+\s*(\d+)\s*(second|minute|hour|day|week)s?$',
              caseSensitive: false)
          .firstMatch(s);
      if (m == null) return null;
      final n = int.tryParse(m.group(1) ?? '0') ?? 0;
      switch (m.group(2)!.toLowerCase()) {
        case 'second':
          return DateTime.now().toUtc().add(Duration(seconds: n));
        case 'minute':
          return DateTime.now().toUtc().add(Duration(minutes: n));
        case 'hour':
          return DateTime.now().toUtc().add(Duration(hours: n));
        case 'day':
          return DateTime.now().toUtc().add(Duration(days: n));
        case 'week':
          return DateTime.now().toUtc().add(Duration(days: 7 * n));
      }
    }
    return DateTime.tryParse(s)?.toUtc();
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
    required this.imageUrl,
    required this.accent,
    required this.onCta,
    required this.onClose,
  });

  final String position;
  final String? title;
  final String? body;
  final String? cta;
  final String? imageUrl;
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
                if (widget.imageUrl != null && widget.imageUrl!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        widget.imageUrl!,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
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
    required this.imageUrl,
    required this.accent,
    required this.onCta,
  });

  final String? title;
  final String? body;
  final String? cta;
  final String? imageUrl;
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
            if (imageUrl != null && imageUrl!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Image.network(
                      imageUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
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
    required this.imageUrl,
    required this.accent,
    required this.onCta,
  });

  final String? title;
  final String? body;
  final String? cta;
  final String? imageUrl;
  final Color? accent;
  final VoidCallback onCta;

  @override
  Widget build(BuildContext context) {
    final acc = accent ?? const Color(0xFFA882FF);
    return Dialog(
      backgroundColor: const Color(0xFF12121C),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (imageUrl != null && imageUrl!.isNotEmpty)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(
                imageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          Padding(
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
                      style: const TextStyle(
                          color: Color(0xFFB5B5C8), height: 1.5),
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
        ],
      ),
    );
  }
}

// ── Hero — full-bleed takeover with hero image ───────────────

class _HeroWidget extends StatelessWidget {
  const _HeroWidget({
    required this.title,
    required this.body,
    required this.cta,
    required this.secondaryCta,
    required this.imageUrl,
    required this.accent,
    required this.onCta,
    required this.onSecondary,
    required this.onClose,
  });

  final String? title;
  final String? body;
  final String? cta;
  final String? secondaryCta;
  final String? imageUrl;
  final Color? accent;
  final VoidCallback onCta;
  final VoidCallback onSecondary;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final acc = accent ?? const Color(0xFFA882FF);
    final mq = MediaQuery.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: mq.size.height * 0.86,
        ),
        child: Material(
          color: const Color(0xFF12121C),
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (imageUrl != null && imageUrl!.isNotEmpty)
                    AspectRatio(
                      aspectRatio: 4 / 3,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.network(
                            imageUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: acc.withOpacity(0.18),
                            ),
                          ),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  const Color(0xFF12121C).withOpacity(0.85),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (title != null && title!.isNotEmpty)
                          Text(
                            title!,
                            style: const TextStyle(
                              color: Color(0xFFF5F5FA),
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        if (body != null && body!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 10, bottom: 22),
                            child: Text(
                              body!,
                              style: const TextStyle(
                                color: Color(0xFFB5B5C8),
                                height: 1.5,
                                fontSize: 14.5,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        if (cta != null && cta!.isNotEmpty)
                          ElevatedButton(
                            onPressed: onCta,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: acc,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              textStyle: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                              ),
                            ),
                            child: Text(cta!),
                          ),
                        if (secondaryCta != null && secondaryCta!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: TextButton(
                              onPressed: onSecondary,
                              style: TextButton.styleFrom(
                                foregroundColor: const Color(0xFF7A7A90),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                              ),
                              child: Text(secondaryCta!),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Material(
                  color: Colors.black.withOpacity(0.35),
                  shape: const CircleBorder(),
                  child: IconButton(
                    onPressed: onClose,
                    icon:
                        const Icon(Icons.close, color: Colors.white, size: 18),
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── NPS widget — 0-10 score buttons ────────────────────────────

class _NpsWidget extends StatefulWidget {
  const _NpsWidget({
    required this.question,
    required this.lowLabel,
    required this.highLabel,
    required this.thanks,
    required this.accent,
    required this.onSubmit,
    required this.onClose,
  });

  final String? question;
  final String? lowLabel;
  final String? highLabel;
  final String? thanks;
  final Color? accent;
  final void Function(int score) onSubmit;
  final VoidCallback onClose;

  @override
  State<_NpsWidget> createState() => _NpsWidgetState();
}

class _NpsWidgetState extends State<_NpsWidget> {
  int? _selected;
  bool _submitted = false;

  void _pick(int score) {
    if (_submitted) return;
    setState(() {
      _selected = score;
      _submitted = true;
    });
    widget.onSubmit(score);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) widget.onClose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final acc = widget.accent ?? const Color(0xFFA882FF);
    final mq = MediaQuery.of(context);
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        padding: EdgeInsets.fromLTRB(20, 18, 20, 20 + mq.viewInsets.bottom),
        decoration: BoxDecoration(
          color: const Color(0xFF12121C),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0x22FFFFFF)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                height: 4,
                width: 36,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF4A4A5C),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            if (_submitted)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Column(
                  children: [
                    Icon(Icons.check_circle, color: acc, size: 36),
                    const SizedBox(height: 12),
                    Text(
                      widget.thanks?.isNotEmpty == true
                          ? widget.thanks!
                          : 'Thanks for the feedback!',
                      style: const TextStyle(
                        color: Color(0xFFF5F5FA),
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else ...[
              if (widget.question != null && widget.question!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Text(
                    widget.question!,
                    style: const TextStyle(
                      color: Color(0xFFF5F5FA),
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              LayoutBuilder(builder: (ctx, c) {
                final cellW = ((c.maxWidth - 10 * 4) / 11).clamp(22.0, 40.0);
                return Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  runSpacing: 4,
                  children: List.generate(11, (i) {
                    final picked = _selected == i;
                    final color = i <= 6
                        ? const Color(0xFFE57373)
                        : i <= 8
                            ? const Color(0xFFFFB74D)
                            : const Color(0xFF66BB6A);
                    return SizedBox(
                      width: cellW,
                      height: cellW,
                      child: Material(
                        color: picked
                            ? color.withOpacity(0.85)
                            : color.withOpacity(0.12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide(
                              color: color.withOpacity(0.45), width: 1),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _pick(i),
                          child: Center(
                            child: Text(
                              '$i',
                              style: TextStyle(
                                color: picked
                                    ? Colors.white
                                    : const Color(0xFFF5F5FA),
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                );
              }),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        widget.lowLabel ?? 'Not likely',
                        style: const TextStyle(
                          color: Color(0xFF7A7A90),
                          fontSize: 11,
                        ),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        widget.highLabel ?? 'Extremely likely',
                        style: const TextStyle(
                          color: Color(0xFF7A7A90),
                          fontSize: 11,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Reaction bar — emoji feedback ──────────────────────────────

class _ReactionsWidget extends StatefulWidget {
  const _ReactionsWidget({
    required this.question,
    required this.thanks,
    required this.emojis,
    required this.accent,
    required this.onPick,
    required this.onClose,
  });

  final String? question;
  final String? thanks;
  final List<String> emojis;
  final Color? accent;
  final void Function(String emoji, int idx) onPick;
  final VoidCallback onClose;

  @override
  State<_ReactionsWidget> createState() => _ReactionsWidgetState();
}

class _ReactionsWidgetState extends State<_ReactionsWidget> {
  int? _picked;

  void _select(int idx) {
    if (_picked != null) return;
    setState(() => _picked = idx);
    widget.onPick(widget.emojis[idx], idx);
    Future.delayed(const Duration(milliseconds: 1100), () {
      if (mounted) widget.onClose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final acc = widget.accent ?? const Color(0xFFA882FF);
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
        decoration: BoxDecoration(
          color: const Color(0xFF12121C),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0x22FFFFFF)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                height: 4,
                width: 36,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF4A4A5C),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            if (_picked != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    Text(
                      widget.emojis[_picked!],
                      style: const TextStyle(fontSize: 56),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      widget.thanks?.isNotEmpty == true
                          ? widget.thanks!
                          : 'Thanks 🙏',
                      style: TextStyle(
                        color: acc,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else ...[
              if (widget.question != null && widget.question!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    widget.question!,
                    style: const TextStyle(
                      color: Color(0xFFF5F5FA),
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(widget.emojis.length, (i) {
                  return InkWell(
                    onTap: () => _select(i),
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(
                        widget.emojis[i],
                        style: const TextStyle(fontSize: 38),
                      ),
                    ),
                  );
                }),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Countdown widget — live ticker ─────────────────────────────

class _CountdownWidget extends StatefulWidget {
  const _CountdownWidget({
    required this.title,
    required this.body,
    required this.cta,
    required this.endedText,
    required this.imageUrl,
    required this.deadline,
    required this.accent,
    required this.onCta,
    required this.onClose,
  });

  final String? title;
  final String? body;
  final String? cta;
  final String? endedText;
  final String? imageUrl;
  final DateTime deadline;
  final Color? accent;
  final VoidCallback onCta;
  final VoidCallback onClose;

  @override
  State<_CountdownWidget> createState() => _CountdownWidgetState();
}

class _CountdownWidgetState extends State<_CountdownWidget> {
  Timer? _ticker;
  late Duration _remaining;

  @override
  void initState() {
    super.initState();
    _remaining = widget.deadline.difference(DateTime.now().toUtc());
    if (_remaining.isNegative) _remaining = Duration.zero;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _remaining = widget.deadline.difference(DateTime.now().toUtc());
        if (_remaining.isNegative) {
          _remaining = Duration.zero;
          _ticker?.cancel();
        }
      });
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final acc = widget.accent ?? const Color(0xFFA882FF);
    final ended = _remaining == Duration.zero;
    final days = _remaining.inDays;
    final hours = _remaining.inHours.remainder(24);
    final mins = _remaining.inMinutes.remainder(60);
    final secs = _remaining.inSeconds.remainder(60);
    return Dialog(
      backgroundColor: const Color(0xFF12121C),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.imageUrl != null && widget.imageUrl!.isNotEmpty)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(
                widget.imageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.title != null && widget.title!.isNotEmpty)
                  Text(
                    widget.title!,
                    style: const TextStyle(
                      color: Color(0xFFF5F5FA),
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                const SizedBox(height: 16),
                if (ended)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      widget.endedText?.isNotEmpty == true
                          ? widget.endedText!
                          : "Time's up.",
                      style: const TextStyle(
                        color: Color(0xFFE57373),
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (days > 0) ...[
                        _CountdownCell(value: '$days', label: 'd', accent: acc),
                        const _CountdownColon(),
                      ],
                      _CountdownCell(
                          value: _two(hours), label: 'h', accent: acc),
                      const _CountdownColon(),
                      _CountdownCell(
                          value: _two(mins), label: 'm', accent: acc),
                      const _CountdownColon(),
                      _CountdownCell(
                          value: _two(secs), label: 's', accent: acc),
                    ],
                  ),
                if (widget.body != null && widget.body!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      widget.body!,
                      style: const TextStyle(
                        color: Color(0xFFB5B5C8),
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (widget.cta != null && widget.cta!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 22),
                    child: ElevatedButton(
                      onPressed: ended ? null : widget.onCta,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: acc,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: const Color(0xFF2A2A38),
                        disabledForegroundColor: const Color(0xFF7A7A90),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text(widget.cta!),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CountdownCell extends StatelessWidget {
  const _CountdownCell(
      {required this.value, required this.label, required this.accent});
  final String value;
  final String label;
  final Color accent;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: accent.withOpacity(0.4), width: 1),
            ),
            child: Text(
              value,
              style: TextStyle(
                color: accent,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF7A7A90),
              fontSize: 10,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _CountdownColon extends StatelessWidget {
  const _CountdownColon();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 2, vertical: 12),
      child: Text(
        ':',
        style: TextStyle(
          color: Color(0xFF4A4A5C),
          fontSize: 22,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Survey ─────────────────────────────────────────────────────
//
// Multi-step bottom sheet. Each question is its own step; the bar at
// the top shows progress. Posts answer-by-answer to /t/survey via
// the parent SurveyPostCallback so the SDK keeps HTTP isolated.
// End-screen variants: thanks / cta / share / nothing.

class _SurveyWidget extends StatefulWidget {
  const _SurveyWidget({
    required this.surveyId,
    required this.responseId,
    required this.questions,
    required this.endScreen,
    required this.siteKey,
    required this.onSurveyPost,
    required this.onCompleted,
  });

  final int surveyId;
  final int responseId;
  final List<Map<String, Object?>> questions;
  final Map<String, Object?> endScreen;
  final String? siteKey;
  final SurveyPostCallback? onSurveyPost;
  final VoidCallback onCompleted;

  @override
  State<_SurveyWidget> createState() => _SurveyWidgetState();
}

class _SurveyWidgetState extends State<_SurveyWidget> {
  int _step = 0;
  final Map<String, dynamic> _answers = {};
  bool _completed = false;

  static const _accent = Color(0xFF7C3AED);

  bool _hasAnswer(Map<String, Object?> q) {
    final v = _answers[q['id']];
    if (v == null) return false;
    if (v is String) return v.trim().isNotEmpty;
    if (v is List) return v.isNotEmpty;
    return true;
  }

  bool get _canAdvance {
    if (_step >= widget.questions.length) return true;
    final q = widget.questions[_step];
    if (q['required'] != true) return true;
    return _hasAnswer(q);
  }

  Future<void> _submitAnswerAndAdvance() async {
    if (_step >= widget.questions.length) return;
    final q = widget.questions[_step];
    final qid = q['id'] as String?;
    final qtype = q['type'] as String?;
    final raw = _answers[qid];
    if (qid != null && qtype != null && widget.onSurveyPost != null) {
      Object? value;
      if (raw is List) {
        value = raw;
      } else if (raw == null) {
        value = '';
      } else {
        value = raw.toString();
      }
      // Fire and forget — UI shouldn't block on per-answer round-trips.
      // Failures get logged at Transport level; the response row exists
      // server-side so completion still correlates correctly.
      unawaited(widget.onSurveyPost!({
        'action': 'answer',
        'site': widget.siteKey,
        'response_id': widget.responseId,
        'question_id': qid,
        'question_type': qtype,
        'value': value,
      }));
    }
    setState(() => _step++);
    if (_step >= widget.questions.length) {
      // Mark complete on server.
      if (widget.onSurveyPost != null) {
        unawaited(widget.onSurveyPost!({
          'action': 'complete',
          'site': widget.siteKey,
          'response_id': widget.responseId,
          'end_screen_seen': 1,
        }));
      }
      setState(() => _completed = true);
      widget.onCompleted();
      // Auto-close thanks-only after 2.5s; CTA / share keep the sheet open.
      final endType = widget.endScreen['type'] as String? ?? 'thanks';
      if (endType == 'thanks' || endType == 'nothing') {
        Future.delayed(const Duration(milliseconds: 2500), () {
          if (mounted) Navigator.of(context, rootNavigator: true).pop();
        });
      }
    }
  }

  Widget _buildProgressBar() {
    final total = widget.questions.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: List.generate(total, (i) {
          Color c;
          if (i < _step) {
            c = _accent;
          } else if (i == _step) {
            c = _accent.withValues(alpha: 0.6);
          } else {
            c = const Color(0xFFE2E8F0);
          }
          return Expanded(
            child: Container(
              height: 3,
              margin: EdgeInsets.only(right: i == total - 1 ? 0 : 4),
              decoration: BoxDecoration(
                color: c,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildQuestionBody(Map<String, Object?> q) {
    final type = q['type'] as String? ?? '';
    final qid = q['id'] as String? ?? '';

    if (type == 'rating') {
      final ratingMaxAny = q['rating_max'];
      final rmax = ratingMaxAny is int ? ratingMaxAny : int.tryParse('$ratingMaxAny') ?? 5;
      final start = rmax == 10 ? 0 : 1;
      final selected = _answers[qid] as int?;
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (int v = start; v <= rmax; v++)
            _RatingButton(
              value: v,
              selected: selected == v,
              onTap: () => setState(() => _answers[qid] = v),
            ),
        ],
      );
    }

    if (type == 'radio') {
      final choices = (q['choices'] as List?)?.cast<String>() ?? const [];
      final selected = _answers[qid] as String?;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in choices)
            _ChoiceTile(
              label: c,
              selected: selected == c,
              multi: false,
              onTap: () => setState(() => _answers[qid] = c),
            ),
        ],
      );
    }

    if (type == 'checkbox') {
      final choices = (q['choices'] as List?)?.cast<String>() ?? const [];
      final picked = (_answers[qid] as List<String>?) ?? <String>[];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in choices)
            _ChoiceTile(
              label: c,
              selected: picked.contains(c),
              multi: true,
              onTap: () => setState(() {
                final cur = List<String>.from(picked);
                if (cur.contains(c)) {
                  cur.remove(c);
                } else {
                  cur.add(c);
                }
                _answers[qid] = cur;
              }),
            ),
        ],
      );
    }

    if (type == 'yesno') {
      final selected = _answers[qid] as int?;
      return Row(
        children: [
          Expanded(
            child: _YesNoButton(
              label: 'Yes',
              selected: selected == 1,
              onTap: () => setState(() => _answers[qid] = 1),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _YesNoButton(
              label: 'No',
              selected: selected == 0,
              onTap: () => setState(() => _answers[qid] = 0),
            ),
          ),
        ],
      );
    }

    // text
    return TextField(
      maxLines: 4,
      maxLength: 2000,
      decoration: const InputDecoration(
        hintText: 'Tell us...',
        border: OutlineInputBorder(),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: _accent, width: 1.5),
        ),
      ),
      onChanged: (v) => setState(() => _answers[qid] = v),
      controller: TextEditingController(text: (_answers[qid] as String?) ?? '')
        ..selection = TextSelection.collapsed(
          offset: ((_answers[qid] as String?) ?? '').length,
        ),
    );
  }

  Widget _buildEnd() {
    final endType = widget.endScreen['type'] as String? ?? 'thanks';
    final thanksText = widget.endScreen['thanks_text'] as String? ?? 'Thanks for your feedback!';
    final ctaText = widget.endScreen['cta_text'] as String? ?? 'Learn more';
    final ctaUrl = widget.endScreen['cta_url'] as String?;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Text(
            thanksText,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
            textAlign: TextAlign.center,
          ),
          if (endType == 'cta' && ctaUrl != null && ctaUrl.isNotEmpty) ...[
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              ),
              child: Text(ctaText, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Container(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.85),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: EdgeInsets.fromLTRB(22, 12, 22, 22 + media.viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: const Color(0xFFE2E8F0),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (!_completed) _buildProgressBar(),
          Flexible(
            child: SingleChildScrollView(
              child: Builder(builder: (_) {
                if (_completed) return _buildEnd();
                final q = widget.questions[_step];
                final required = q['required'] == true;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text.rich(
                      TextSpan(
                        text: q['label'] as String? ?? '',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF0F172A),
                          height: 1.4,
                        ),
                        children: required
                            ? const [
                                TextSpan(
                                  text: ' *',
                                  style: TextStyle(color: Color(0xFFEF4444)),
                                ),
                              ]
                            : null,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildQuestionBody(q),
                  ],
                );
              }),
            ),
          ),
          if (!_completed) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (_step > 0)
                  TextButton(
                    onPressed: () => setState(() => _step--),
                    child: const Text('Back'),
                  )
                else
                  const SizedBox.shrink(),
                ElevatedButton(
                  onPressed: _canAdvance ? _submitAnswerAndAdvance : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  ),
                  child: Text(
                    _step == widget.questions.length - 1 ? 'Submit' : 'Next',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RatingButton extends StatelessWidget {
  const _RatingButton({required this.value, required this.selected, required this.onTap});
  final int value;
  final bool selected;
  final VoidCallback onTap;

  static const _accent = Color(0xFF7C3AED);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? _accent : const Color(0xFFF8FAFC),
          border: Border.all(color: selected ? _accent : const Color(0xFFE2E8F0)),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          '$value',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : const Color(0xFF0F172A),
          ),
        ),
      ),
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.selected,
    required this.multi,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final bool multi;
  final VoidCallback onTap;

  static const _accent = Color(0xFF7C3AED);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? _accent : const Color(0xFFF8FAFC),
            border: Border.all(color: selected ? _accent : const Color(0xFFE2E8F0)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                multi
                    ? (selected ? Icons.check_box : Icons.check_box_outline_blank)
                    : (selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                size: 20,
                color: selected ? Colors.white : const Color(0xFF94A3B8),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: selected ? Colors.white : const Color(0xFF0F172A),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _YesNoButton extends StatelessWidget {
  const _YesNoButton({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  static const _accent = Color(0xFF7C3AED);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected ? _accent : const Color(0xFFF8FAFC),
          border: Border.all(color: selected ? _accent : const Color(0xFFE2E8F0)),
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : const Color(0xFF0F172A),
          ),
        ),
      ),
    );
  }
}
