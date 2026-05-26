// Checkout — plain UI. Payment method + confirm. No tracking code.

import 'package:flutter/material.dart';
import '../services/store.dart';
import 'home_screen.dart';

class CheckoutScreen extends StatefulWidget {
  static const route = '/checkout';
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  String _method = 'card';
  bool _processing = false;

  Future<void> _pay() async {
    setState(() => _processing = true);
    await Future.delayed(const Duration(milliseconds: 900));
    final orderId = 'ord-${DateTime.now().millisecondsSinceEpoch}';
    Cart.instance.clear();

    if (mounted) {
      final navigator = Navigator.of(context);
      showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Đặt hàng thành công 🎉'),
          content: Text('Mã đơn: $orderId'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext); // close the dialog first
                navigator.pushNamedAndRemoveUntil(
                    HomeScreen.route, (_) => false);
              },
              child: const Text('Về trang chủ'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Thanh toán')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Phương thức thanh toán',
              style: TextStyle(fontWeight: FontWeight.bold)),
          for (final m in const [
            ['card', 'Thẻ tín dụng', Icons.credit_card],
            ['momo', 'Ví MoMo', Icons.account_balance_wallet],
            ['cod', 'Thanh toán khi nhận', Icons.local_shipping],
          ])
            RadioListTile<String>(
              value: m[0] as String,
              groupValue: _method,
              title: Text(m[1] as String),
              secondary: Icon(m[2] as IconData),
              onChanged: (v) => setState(() => _method = v!),
            ),
          const Divider(),
          ListTile(
            title: const Text('Tổng thanh toán'),
            trailing: Text(money(Cart.instance.total),
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _processing ? null : _pay,
            child: _processing
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Xác nhận đặt hàng'),
          ),
        ],
      ),
    );
  }
}
