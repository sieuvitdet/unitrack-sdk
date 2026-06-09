import 'package:flutter/material.dart';
import 'package:unitrack/unitrack.dart';
import 'package:unitrack_snowplow/unitrack_snowplow.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sp = SnowplowProvider(
    endpoint: 'https://collector.your-app.com',
    appId: 'mobile-app',
    namespace: 'YourApp',
    igluVendor: 'com.your-app',
    defaultVersion: '1-0-0',
  );
  UniTrack.instance.addProvider(sp);
  await UniTrack.instance.initialize('utk_replace_with_your_api_key');
  runApp(MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Snowplow provider')),
      body: Center(
        child: ElevatedButton(
          onPressed: () => sp.trackingClickEvent(
            elementKey: 'demo_button',
            screen: 'HomeScreen',
          ),
          child: const Text('Fire click event'),
        ),
      ),
    ),
  ));
}
