import 'package:dijji/dijji.dart';
import 'package:flutter/material.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Replace with your own ws_* site key. The example one below is the
  // demo site on dijji.com — fine for kicking the tyres locally.
  await Dijji.instance.initialize(
    siteKey: 'ws_a647ba153d0911f1b7',
    config: const DijjiConfig(
      siteKey: 'ws_a647ba153d0911f1b7',
      debug: true,
    ),
  );

  runApp(const DijjiExampleApp());
}

class DijjiExampleApp extends StatelessWidget {
  const DijjiExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dijji Example',
      navigatorKey: Dijji.instance.navigatorKey,
      navigatorObservers: [Dijji.instance.navigatorObserver],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFA882FF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0A0A12),
      ),
      initialRoute: '/',
      routes: {
        '/': (_) => const HomeScreen(),
        '/pricing': (_) => const PricingScreen(),
      },
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dijji · Example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section('Custom events', [
            _Tile(
              'track("button_clicked")',
              () => Dijji.instance.track('button_clicked', properties: {
                'screen': 'home',
                'variant': 'primary',
              }),
            ),
            _Tile(
              'track("signup_completed")',
              () => Dijji.instance.track('signup_completed', properties: {
                'plan': 'pro',
              }),
            ),
          ]),
          _Section('Identity', [
            _Tile(
              'identify("user_42")',
              () => Dijji.instance.identify('user_42', traits: {
                'plan': 'pro',
                'name': 'Rishi',
              }),
            ),
            _Tile(
              'reset() (logout)',
              () async => Dijji.instance.reset(),
            ),
          ]),
          _Section('User properties', [
            _Tile(
              'setUserProperty("plan", "pro")',
              () => Dijji.instance.setUserProperty('plan', 'pro'),
            ),
            _Tile(
              'unsetUserProperty("plan")',
              () => Dijji.instance.unsetUserProperty('plan'),
            ),
          ]),
          _Section('Privacy', [
            _Tile(
              'optOut()',
              () async => Dijji.instance.optOut(),
            ),
            _Tile(
              'optIn()',
              () async => Dijji.instance.optIn(),
            ),
          ]),
          _Section('Navigation (auto screen_view)', [
            _Tile(
              'Push /pricing',
              () => Navigator.pushNamed(context, '/pricing'),
            ),
          ]),
          _Section('Crash test', [
            _Tile(
              'Throw uncaught exception',
              () async {
                Future<void>.delayed(Duration.zero, () {
                  throw StateError('intentional crash test');
                });
              },
            ),
          ]),
          _Section('Diagnostics', [
            _DiagnosticsTile(),
          ]),
        ],
      ),
    );
  }
}

class PricingScreen extends StatelessWidget {
  const PricingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pricing')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'screen_view auto-fired',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                Dijji.instance.track('plan_selected', properties: {
                  'plan': 'pro',
                  'price': 49,
                });
                Navigator.pop(context);
              },
              child: const Text('Select Pro · \$49'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 11,
                letterSpacing: 1.6,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF12121C),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x22FFFFFF)),
      ),
      child: ListTile(
        title: Text(label, style: const TextStyle(fontFamily: 'monospace')),
        trailing: const Icon(Icons.chevron_right, color: Color(0xFF7A7A90)),
        onTap: onTap,
      ),
    );
  }
}

class _DiagnosticsTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF12121C),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x22FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('SDK initialized', '${Dijji.instance.isInitialized}'),
          _kv('visitor_id', Dijji.instance.visitorId),
          _kv('user_id', Dijji.instance.userId ?? '(anonymous)'),
          _kv('opted out', '${Dijji.instance.isOptedOut}'),
          _kv('SDK version', dijjiSdkVersion),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: const TextStyle(color: Color(0xFFB5B5C8))),
            Flexible(
              child: Text(
                v,
                textAlign: TextAlign.end,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
      );
}
