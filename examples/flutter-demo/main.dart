// Flutter example. Minimum integration.

import 'package:flutter/material.dart';
import 'package:unitrack/unitrack.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UniTrack.instance.initialize(
    'YOUR_API_KEY',
    config: const UniTrackConfig(
      endpoint: 'https://ingest.example.com/v1/events',
      samplingRate: 1.0,
    ),
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Add the observer — every PageRoute push is auto-tracked.
      navigatorObservers: [UniTrackNavigatorObserver()],
      initialRoute: '/',
      routes: {
        '/': (_) => const HomeScreen(),
      },
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Demo')),
      body: Center(
        child: ElevatedButton(
          onPressed: () => UniTrack.instance.track(
            'checkout_started',
            properties: {'source': 'home'},
          ),
          child: const Text('Buy now'),
        ),
      ),
    );
  }
}

// Safe JSON parse:
//
//   final user = safeJsonParse<Map<String, dynamic>>('User', body);
