import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:unitrack/unitrack.dart';
import 'package:unitrack_firebase/unitrack_firebase.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  UniTrack.instance.addProvider(FirebaseProvider());
  await UniTrack.instance.initialize('utk_replace_with_your_api_key');
  runApp(MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Firebase provider')),
      body: Center(
        child: ElevatedButton(
          onPressed: () => UniTrack.instance.track('demo_event', properties: {
            'source': 'example_app',
          }),
          child: const Text('Fire demo event'),
        ),
      ),
    ),
  ));
}
