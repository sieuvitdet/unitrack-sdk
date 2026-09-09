// ViewControllerSwizzler.swift
//
// Swizzles UIViewController lifecycle to auto-capture, with NO per-controller code:
//   • viewDidLoad  → record a start timestamp (for load timing)
//   • viewDidAppear → emit `screen_view` (class name / title) AND
//                     `screen_load_completed` (viewDidLoad → first appearance ms)
// Installed once at SDK init.

import UIKit
import ObjectiveC.runtime

enum ViewControllerSwizzler {
    static let installed: Void = {
        swizzle(cls: UIViewController.self,
                from: #selector(UIViewController.viewDidLoad),
                to:   #selector(UIViewController.ut_viewDidLoad))
        swizzle(cls: UIViewController.self,
                from: #selector(UIViewController.viewDidAppear(_:)),
                to:   #selector(UIViewController.ut_viewDidAppear(_:)))
    }()

    static func install() { _ = installed }

    private static func swizzle(cls: AnyClass, from sel1: Selector, to sel2: Selector) {
        guard let m1 = class_getInstanceMethod(cls, sel1),
              let m2 = class_getInstanceMethod(cls, sel2) else { return }

        let added = class_addMethod(cls, sel1,
                                    method_getImplementation(m2),
                                    method_getTypeEncoding(m2))
        if added {
            class_replaceMethod(cls, sel2,
                                method_getImplementation(m1),
                                method_getTypeEncoding(m1))
        } else {
            method_exchangeImplementations(m1, m2)
        }
    }
}

private var utLoadStartKey: UInt8 = 0
private var utLoadReportedKey: UInt8 = 0

private extension UIViewController {
    var ut_loadStart: CFTimeInterval {
        get { (objc_getAssociatedObject(self, &utLoadStartKey) as? CFTimeInterval) ?? 0 }
        set { objc_setAssociatedObject(self, &utLoadStartKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    var ut_loadReported: Bool {
        get { (objc_getAssociatedObject(self, &utLoadReportedKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &utLoadReportedKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    // Framework containers + system/private VCs create noise — skip them.
    var ut_isSkippedContainer: Bool {
        let name = String(describing: type(of: self))
        let skipped: Set<String> = [
            "UINavigationController", "UITabBarController",
            "UISplitViewController", "UIPageViewController",
            "UIInputWindowController", "UICompatibilityInputViewController",
            "UIAlertController",
            // System / framework chrome that isn't a real app screen.
            "UISceneHostingViewController", "_UISceneHostingViewController",
            "UITrackingElementWindowController", "UIEditingOverlayViewController",
            "UIPredictionViewController", "UISystemInputAssistantViewController",
            "HUD",
            // FlutterViewController / RCTRootView used to be string-matched
            // here; they are now handled by ut_yieldToCrossPlatformLayer
            // below so we can ALSO claim the subtree for the right layer
            // (so the cross-platform observer's screen_view isn't dropped
            // by core's same-name cross-layer dedup).
        ]
        if skipped.contains(name) { return true }
        // Private/framework VCs typically start with "_" — not app screens.
        if name.hasPrefix("_") { return true }
        return false
    }

    // If `self` is the host VC of a cross-platform layer (Flutter / RN) AND
    // that layer is registered in this process, claim the subtree and tell
    // the caller to yield — the cross-platform observer will emit screen_view
    // with the real Dart/JS screen name. When no cross-platform layer is
    // registered we fall through to the legacy path (emit the UIKit class
    // name) so a native-only build behaves exactly as today.
    //
    // Class probing is done with NSClassFromString so the SDK does not need
    // to link Flutter or RN headers — the symbols are looked up at runtime
    // only on apps that ship those frameworks.
    func ut_yieldToCrossPlatformLayer() -> Bool {
        if let cls = ViewControllerBoundary.flutterVCClass,
           self.isKind(of: cls),
           LayerRegistry.isActive(.flutter) {
            LayerRegistry.claim(subtree: unitrackSubtreeId(for: self), by: .flutter)
            return true
        }
        if let cls = ViewControllerBoundary.rnRootVCClass,
           self.isKind(of: cls),
           LayerRegistry.isActive(.reactNative) {
            LayerRegistry.claim(subtree: unitrackSubtreeId(for: self), by: .reactNative)
            return true
        }
        return false
    }


    @objc func ut_viewDidLoad() {
        self.ut_viewDidLoad()                 // original (swapped)
        if !ut_isSkippedContainer { ut_loadStart = CACurrentMediaTime() }
    }

    @objc func ut_viewDidAppear(_ animated: Bool) {
        self.ut_viewDidAppear(animated)       // original (swapped)
        // Probe Flutter/RN BEFORE the noise-skip list so a Flutter host VC
        // nested under UINavigationController still gets a chance to claim
        // its subtree (UINavigationController itself is skipped above).
        if ut_yieldToCrossPlatformLayer() { return }
        if ut_isSkippedContainer { return }

        let screen = ut_screenName
        // Manual-priority arbitration cho screen: nếu DEV đã gọi setScreen
        // hoặc track("screen_view", ...) trong window vừa rồi, swizzler giữ
        // im lặng. Defer 50ms để DEV's viewDidAppear handler có cơ hội fire.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if ManualTrackSignal.shouldSkip(.screen) {
                UniTrack.log("[UniTrack] auto screen_view SUPPRESSED — manual signal in window screen=%@", screen)
                return
            }
            // Layer-tagged emit so a sibling Flutter/RN SDK firing the same name
            // a few ms later is dropped by core's cross-layer dedup. Falls back
            // to the legacy untagged path on contexts where the C symbol isn't
            // present (vd version skew with an older core).
            UniTrack.setScreen(screen, layer: .iOSNative)
        }

        // Load time: viewDidLoad → first appearance. Reported once per VC.
        // Event name resolves from UniTrack.screenLoadEventName (set during
        // _initialize from config.screenLoadEvent, in turn from portal
        // `sdk_config.screen_load_event`). Default keeps "screen_load_completed".
        if !ut_loadReported, ut_loadStart > 0 {
            ut_loadReported = true
            let ms = Int((CACurrentMediaTime() - ut_loadStart) * 1000)
            UniTrack.track(UniTrack.screenLoadEventName,
                           properties: ["screen": screen, "load_ms": ms],
                           isAuto: true)
        }
    }
}

// Cached class probes for Flutter / React Native host VCs. NSClassFromString
// returns nil when the framework isn't linked, so on a native-only app these
// stay nil and ut_yieldToCrossPlatformLayer is a single nil check per appear.
enum ViewControllerBoundary {
    static let flutterVCClass: AnyClass? = NSClassFromString("FlutterViewController")
    // RN root may surface as either UIView (RCTRootView) wrapped in a host
    // UIViewController, or directly as RCTRootViewController on RN ≥0.74.
    // We probe the VC class — UIViews don't go through viewDidAppear anyway.
    static let rnRootVCClass: AnyClass? = NSClassFromString("RCTRootViewController")
}

// Shared screen-name resolver (internal — also used by ControlSwizzler for taps).
// Uses the controller's class name as the stable analytics screen name. We
// intentionally do NOT use `title`, which is often a dynamic string (e.g. a
// camera name) and not a stable key. Strip the Swift module prefix so the name
// is consistent — `type(of:)` can yield "MyApp.HomeVC" or "HomeVC".
extension UIViewController {
    var ut_screenName: String {
        let full = String(describing: type(of: self))
        return full.split(separator: ".").last.map(String.init) ?? full
    }
}
