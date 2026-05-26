// Home hub — plain UI. Navigation + a manual flush button. No tracking code;
// taps and screen views are captured app-wide from main.dart.

import 'package:flutter/material.dart';
import 'product_list_screen.dart';
import 'cart_screen.dart';
import 'network_screen.dart';
import 'settings_screen.dart';
import 'login_screen.dart';

class HomeScreen extends StatelessWidget {
  static const route = '/home';
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tiles = <_Tile>[
      _Tile('Cửa hàng', Icons.storefront, ProductListScreen.route, 'shop'),
      _Tile('Giỏ hàng', Icons.shopping_cart, CartScreen.route, 'cart'),
      _Tile('Network demo', Icons.cloud_sync, NetworkScreen.route, 'network'),
      _Tile('Cài đặt', Icons.settings, SettingsScreen.route, 'settings'),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mobix Demo'),
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () => Navigator.pushNamedAndRemoveUntil(
                context, LoginScreen.route, (_) => false),
          ),
        ],
      ),
      body: GridView.count(
        crossAxisCount: 2,
        padding: const EdgeInsets.all(16),
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        children: [
          for (final t in tiles)
            InkWell(
              onTap: () => Navigator.pushNamed(context, t.route),
              borderRadius: BorderRadius.circular(16),
              child: Card(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(t.icon, size: 40),
                      const SizedBox(height: 12),
                      Text(t.label,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {},
        icon: const Icon(Icons.local_offer),
        label: const Text('Khuyến mãi'),
      ),
    );
  }
}

class _Tile {
  final String label;
  final IconData icon;
  final String route;
  final String key;
  _Tile(this.label, this.icon, this.route, this.key);
}
