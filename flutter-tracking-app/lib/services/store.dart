// Tiny in-memory product catalog + cart shared across the shopping flow.

/// Format a VND amount like 199.000đ.
String money(double v) =>
    '${v.toStringAsFixed(0).replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => '.')}đ';


class Product {
  final String id;
  final String name;
  final double price;
  final String category;
  const Product(this.id, this.name, this.price, this.category);
}

const demoProducts = <Product>[
  Product('p-1', 'Áo thun Mobix', 199000, 'apparel'),
  Product('p-2', 'Bình giữ nhiệt', 349000, 'home'),
  Product('p-3', 'Tai nghe không dây', 899000, 'electronics'),
  Product('p-4', 'Sổ tay da', 159000, 'stationery'),
  Product('p-5', 'Sạc dự phòng 20k', 459000, 'electronics'),
  Product('p-6', 'Ly cà phê sứ', 129000, 'home'),
];

/// Dead-simple global cart. Maps product id -> quantity.
class Cart {
  Cart._();
  static final Cart instance = Cart._();

  final Map<String, int> _items = {};

  Map<String, int> get items => Map.unmodifiable(_items);
  int get count => _items.values.fold(0, (a, b) => a + b);

  double get total {
    double t = 0;
    _items.forEach((id, qty) {
      final p = demoProducts.firstWhere((p) => p.id == id);
      t += p.price * qty;
    });
    return t;
  }

  void add(Product p, [int qty = 1]) =>
      _items.update(p.id, (v) => v + qty, ifAbsent: () => qty);

  void remove(String id) => _items.remove(id);

  void clear() => _items.clear();
}
