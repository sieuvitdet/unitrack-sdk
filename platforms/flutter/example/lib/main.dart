// Minimal UniTrack integration sample. Drop your API key + endpoint into
// `initialize()` and run.

import 'package:flutter/material.dart';
import 'package:unitrack/unitrack.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UniTrack.instance.initialize(
    'utk_replace_with_your_api_key',
    config: const UniTrackConfig(
      endpoint: 'https://your-portal.com/event-tracking/v1/events',
      batchSize: 20,
      flushIntervalMs: 5000,
    ),
  );
  UniTrack.installHttpAutoCapture();
  runApp(const UniTrackExampleApp());
}

class UniTrackExampleApp extends StatelessWidget {
  const UniTrackExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UniTrack Example',
      navigatorObservers: [UniTrackNavigatorObserver()],
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _pending = '';

  Future<void> _trackCheckout() async {
    await UniTrack.instance.track('checkout_completed', properties: {
      'order_id': 'demo_${DateTime.now().millisecondsSinceEpoch}',
      'amount':   99.95,
      'currency': 'USD',
    });
    await _refreshPending();
  }

  Future<void> _refreshPending() async {
    final p = await UniTrack.instance.pendingEventCounts();
    setState(() => _pending = p.isEmpty
        ? 'queue empty'
        : p.entries.map((e) => '${e.value} ${e.key}').join(', '));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('UniTrack Example')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: _trackCheckout,
              child: const Text('Track demo event'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _refreshPending,
              child: const Text('Show pending queue'),
            ),
            const SizedBox(height: 16),
            Text('Pending: $_pending'),
          ],
        ),
      ),
    );
  }
}
