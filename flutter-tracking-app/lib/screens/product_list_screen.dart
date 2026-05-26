// Product list — plain UI. Category filter + product rows. No tracking code.

import 'package:flutter/material.dart';
import '../services/store.dart';
import 'product_detail_screen.dart';

class ProductListScreen extends StatefulWidget {
  static const route = '/products';
  const ProductListScreen({super.key});

  @override
  State<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends State<ProductListScreen> {
  String _category = 'all';

  List<Product> get _filtered => _category == 'all'
      ? demoProducts
      : demoProducts.where((p) => p.category == _category).toList();

  @override
  Widget build(BuildContext context) {
    final cats = ['all', 'apparel', 'home', 'electronics', 'stationery'];
    return Scaffold(
      appBar: AppBar(title: const Text('Cửa hàng')),
      body: Column(
        children: [
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final c in cats)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(c),
                      selected: _category == c,
                      onSelected: (_) => setState(() => _category = c),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: _filtered.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final p = _filtered[i];
                return Semantics(
                  identifier: 'product_row_${p.id}',
                  child: ListTile(
                    leading: CircleAvatar(child: Text(p.name[0])),
                    title: Text(p.name),
                    subtitle: Text('${p.category} · ${money(p.price)}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pushNamed(
                        context, ProductDetailScreen.route,
                        arguments: p),
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
