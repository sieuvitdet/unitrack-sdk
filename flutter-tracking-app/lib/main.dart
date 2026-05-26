// Mobix UniTrack demo — entry point.
//
// THE ENTIRE TRACKING SETUP IS HERE. The demo screens contain ZERO tracking
// code — they're plain UI. Three declarations at startup capture everything:
//
//   1. Tracking.init()                  → SDK + transport to the Mobix portal
//   2. HttpOverrides.global = ...        → every API call/error, with the
//                                          button+screen that triggered it
//   3. UniTrackTapObserver(child: ...)   → every tap (button name + screen)
//                                          and every screen_view
//
// Add a new screen, new button, new API call → it is tracked automatically.

import 'package:flutter/material.dart';
import 'package:unitrack/unitrack.dart';

import 'services/tracking.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/product_list_screen.dart';
import 'screens/product_detail_screen.dart';
import 'screens/cart_screen.dart';
import 'screens/checkout_screen.dart';
import 'screens/network_screen.dart';
import 'screens/settings_screen.dart';

// Flip to `true` (or run with --dart-define=CRASH_ON_LAUNCH=true) to make the
// app throw ~1s after launch. This lands inside the SDK's 5-second launch
// window, so the resulting `crash` event is flagged crash_on_launch=true.
const bool kCrashOnLaunch =
    bool.fromEnvironment('CRASH_ON_LAUNCH', defaultValue: false);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Bring up the SDK + transport to the portal (also installs the native
  //    auto-capture: lifecycle, memory warnings, crash handler).
  await Tracking.init();

  // Launch-crash test: throw shortly after init so the crash is attributed to
  // app launch. Lets you verify the "on-launch" tag on the portal.
  if (kCrashOnLaunch) {
    Future<void>.delayed(const Duration(seconds: 1), () {
      throw StateError('Intentional crash on launch (test crash_on_launch)');
    });
  }

  // 2. Auto-capture every HTTP request/error, mirroring the triggering tap.
  UniTrack.installHttpAutoCapture();

  // 3. Auto-capture every tap (button name + screen) and every screen_view.
  runApp(const UniTrackTapObserver(child: MobixDemoApp()));
}

class MobixDemoApp extends StatelessWidget {
  const MobixDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mobix Tracking Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF5B8CFF),
        brightness: Brightness.light,
      ),
      // Auto-track every PageRoute as a screen_view, and feed the current
      // screen name to the tap observer.
      navigatorObservers: [UniTrackTapObserver.routeObserver],
      initialRoute: LoginScreen.route,
      routes: {
        LoginScreen.route:        (_) => const LoginScreen(),
        HomeScreen.route:         (_) => const HomeScreen(),
        ProductListScreen.route:  (_) => const ProductListScreen(),
        ProductDetailScreen.route:(_) => const ProductDetailScreen(),
        CartScreen.route:         (_) => const CartScreen(),
        CheckoutScreen.route:     (_) => const CheckoutScreen(),
        NetworkScreen.route:      (_) => const NetworkScreen(),
        SettingsScreen.route:     (_) => const SettingsScreen(),
      },
    );
  }
}
