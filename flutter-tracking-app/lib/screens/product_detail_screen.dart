// Product detail — plain UI. Quantity stepper + add to cart. No tracking code.

import 'package:flutter/material.dart';
import '../services/store.dart';
import 'cart_screen.dart';

class ProductDetailScreen extends StatefulWidget {
  static const route = '/product';
  const ProductDetailScreen({super.key});

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  int _qty = 1;
  Product? _p;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _p ??= ModalRoute.of(context)!.settings.arguments as Product;
  }

  @override
  Widget build(BuildContext context) {
    final p = _p!;
    return Scaffold(
      appBar: AppBar(
        title: Text(p.name),
        actions: [
          IconButton(icon: const Icon(Icons.share), onPressed: () {}),
          IconButton(icon: const Icon(Icons.favorite_border), onPressed: () {}),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            height: 180,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Center(child: Text(p.name[0], style: const TextStyle(fontSize: 64))),
          ),
          const SizedBox(height: 20),
          Text(p.name, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(money(p.price),
              style: TextStyle(
                  fontSize: 20, color: Theme.of(context).colorScheme.primary)),
          const SizedBox(height: 8),
          Chip(label: Text(p.category)),
          const SizedBox(height: 20),
          Row(
            children: [
              const Text('Số lượng:'),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () {
                  if (_qty > 1) setState(() => _qty--);
                },
              ),
              Text('$_qty', style: const TextStyle(fontSize: 18)),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => setState(() => _qty++),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Semantics(
            identifier: 'add_to_cart_button',
            button: true,
            child: FilledButton.icon(
              icon: const Icon(Icons.add_shopping_cart),
              label: const Text('Thêm vào giỏ'),
              onPressed: () {
                Cart.instance.add(p, _qty);
                // Capture the navigator now — the SnackBar action may fire
                // after this screen's context is gone, so we must not call
                // Navigator.of(context) from inside the action closure.
                final navigator = Navigator.of(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Đã thêm ${p.name}'),
                    action: SnackBarAction(
                      label: 'Xem giỏ',
                      onPressed: () => navigator.pushNamed(CartScreen.route),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
