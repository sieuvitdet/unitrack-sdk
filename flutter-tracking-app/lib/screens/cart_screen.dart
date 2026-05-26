// Cart — plain UI. No tracking code.

import 'package:flutter/material.dart';
import '../services/store.dart';
import 'checkout_screen.dart';

class CartScreen extends StatefulWidget {
  static const route = '/cart';
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final cart = Cart.instance;

  @override
  Widget build(BuildContext context) {
    final entries = cart.items.entries.toList();
    return Scaffold(
      appBar: AppBar(title: Text('Giỏ hàng (${cart.count})')),
      body: entries.isEmpty
          ? const Center(child: Text('Giỏ hàng trống'))
          : ListView(
              children: [
                for (final e in entries)
                  _row(demoProducts.firstWhere((p) => p.id == e.key), e.value),
              ],
            ),
      bottomNavigationBar: entries.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Tổng cộng'),
                          Text(money(cart.total),
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    Semantics(
                      identifier: 'begin_checkout_button',
                      button: true,
                      child: FilledButton(
                        onPressed: () => Navigator.pushNamed(
                            context, CheckoutScreen.route),
                        child: const Text('Thanh toán'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _row(Product p, int qty) => ListTile(
        title: Text(p.name),
        subtitle: Text('${money(p.price)} × $qty'),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: () => setState(() => cart.remove(p.id)),
        ),
      );
}
