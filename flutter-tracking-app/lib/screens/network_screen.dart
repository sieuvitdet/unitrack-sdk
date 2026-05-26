// Network demo — plain UI. Real HTTP calls. No tracking code here: the global
// HttpOverrides installed in main.dart records every request/error and mirrors
// the button + screen that triggered it. The "GET 404" button shows how an API
// failure is attributed back to the button on this screen.

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class NetworkScreen extends StatefulWidget {
  static const route = '/network';
  const NetworkScreen({super.key});

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  String _log = 'Bấm nút để thực hiện request.\n';

  void _append(String s) => setState(() => _log += '$s\n');

  Future<void> _get200() async {
    try {
      final r = await http
          .get(Uri.parse('https://jsonplaceholder.typicode.com/todos/1'));
      _append('GET /todos/1 -> ${r.statusCode} (${r.bodyBytes.length}b)');
    } catch (e) {
      _append('error: $e');
    }
  }

  Future<void> _post() async {
    try {
      final r = await http.post(
        Uri.parse('https://jsonplaceholder.typicode.com/posts'),
        headers: {'Content-Type': 'application/json'},
        body: '{"title":"mobix","body":"demo","userId":1}',
      );
      _append('POST /posts -> ${r.statusCode}');
    } catch (e) {
      _append('error: $e');
    }
  }

  Future<void> _get404() async {
    try {
      final r = await http
          .get(Uri.parse('https://jsonplaceholder.typicode.com/nope-404'));
      _append('GET /nope-404 -> ${r.statusCode}');
    } catch (e) {
      _append('error: $e');
    }
  }

  Future<void> _badHost() async {
    try {
      final r = await http
          .get(Uri.parse('https://this-host-does-not-exist.mobix.invalid/x'));
      _append('GET bad host -> ${r.statusCode}');
    } catch (e) {
      _append('network error (tracked): $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Network demo')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                Semantics(
                  identifier: 'net_get_200',
                  button: true,
                  child: FilledButton(
                      onPressed: _get200, child: const Text('GET 200')),
                ),
                Semantics(
                  identifier: 'net_post',
                  button: true,
                  child: FilledButton(
                      onPressed: _post, child: const Text('POST')),
                ),
                Semantics(
                  identifier: 'net_get_404',
                  button: true,
                  child: FilledButton.tonal(
                      onPressed: _get404, child: const Text('GET 404')),
                ),
                Semantics(
                  identifier: 'net_bad_host',
                  button: true,
                  child: FilledButton.tonal(
                      onPressed: _badHost, child: const Text('Bad host')),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0b0e14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: Text(_log,
                      style: const TextStyle(
                          color: Color(0xFF27d796),
                          fontFamily: 'monospace',
                          fontSize: 12)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
