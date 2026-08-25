// ViewControllerSwizzler.swift
//
// Swizzles UIViewController lifecycle to auto-capture, with NO per-controller code:
//   • viewDidLoad   → record a start timestamp (for load timing)
//   • viewWillAppear → re-arm that timestamp for a VC that is being shown
//                      AGAIN (kept in memory, so viewDidLoad never re-runs)
//   • viewDidAppear → emit `screen_view` (class name / title) AND
//                     `screen_load_completed` (start → appearance ms)
// Installed once at SDK init.

import UIKit
import ObjectiveC.runtime

enum ViewControllerSwizzler {
    /// Cửa sổ chờ trước khi chốt một VC là "màn thật". VC bị VC khác appear
    /// đè lên trong khoảng này được coi là container trung gian và bị bỏ.
    /// Chỉnh được từ portal `sdk_config.screen_settle_ms` (0 = tắt lọc).
    static var settleWindow: TimeInterval = 0.05
    /// Bộ đếm appear toàn cục. Closure so seq của mình với giá trị hiện tại
    /// để biết có VC nào appear sau mình không. Chỉ chạm trên main thread
    /// (viewDidAppear + main-queue closure) nên không cần khoá.
    static var appearSeq: UInt64 = 0

    static let installed: Void = {
        swizzle(cls: UIViewController.self,
                from: #selector(UIViewController.viewDidLoad),
                to:   #selector(UIViewController.ut_viewDidLoad))
        swizzle(cls: UIViewController.self,
                from: #selector(UIViewController.viewWillAppear(_:)),
                to:   #selector(UIViewController.ut_viewWillAppear(_:)))
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

    @objc func ut_viewWillAppear(_ animated: Bool) {
        self.ut_viewWillAppear(animated)      // original (swapped)
        guard !ut_isSkippedContainer else { return }
        // Mốc load cho lần hiện LẠI. VC được giữ trong bộ nhớ (đẩy vào
        // back-stack, tab bị ẩn) không chạy lại viewDidLoad, nên nếu vẫn trừ
        // từ mốc cũ thì load_ms cộng luôn quãng VC nằm chờ: session 6fda62c3
        // có CameraHomeViewController báo load=85764 vì người dùng rời đi 85
        // giây rồi quay lại. Con số đó không đo cost dựng gì cả.
        //
        // Lần đầu KHÔNG đụng tới: viewWillAppear chạy ngay sau viewDidLoad
        // nên ghi đè sẽ nuốt mất chính phần dựng view mà event này cần đo.
        if ut_loadReported { ut_loadStart = CACurrentMediaTime() }
    }

    @objc func ut_viewDidAppear(_ animated: Bool) {
        self.ut_viewDidAppear(animated)       // original (swapped)
        // Probe Flutter/RN BEFORE the noise-skip list so a Flutter host VC
        // nested under UINavigationController still gets a chance to claim
        // its subtree (UINavigationController itself is skipped above).
        if ut_yieldToCrossPlatformLayer() { return }
        if ut_isSkippedContainer { return }

        let screen = ut_screenName
        // Settle-window arbitration. VC nào bị một VC khác appear đè lên trong
        // cửa sổ này là container trung gian (tab bar host, pager, nav wrapper)
        // — nó chưa từng hiện ra cho người dùng thấy, nên không bắn gì cả.
        // Phân biệt bằng HÀNH VI thay vì blocklist tên class: SDK dùng chung
        // cho nhiều app, không nên biết tên VC của app nào.
        //
        // Cửa sổ này vốn đã tồn tại cho manual-priority arbitration (nhường
        // DEV's viewDidAppear handler gọi setScreen trước). Giờ nó gánh thêm
        // việc lọc container — không thêm timer mới.
        ViewControllerSwizzler.appearSeq &+= 1
        let mySeq = ViewControllerSwizzler.appearSeq
        // load_ms chốt tại đây (thời điểm appear thật), nhưng chỉ GỬI sau khi
        // qua cửa sổ — nếu đo trong closure sẽ cộng oan 50ms vào mọi màn.
        // Không gate bằng ut_loadReported nữa: VC được giữ lại rồi hiện lại
        // là một lần vào màn THẬT (có screen_end trước đó) nên đáng được đo,
        // với mốc đã reset ở viewWillAppear. Việc chống trùng do dup guard
        // của setScreen đảm nhiệm — xem `sameScreen` bên dưới.
        let loadMs: Int? = ut_loadStart > 0
            ? Int((CACurrentMediaTime() - ut_loadStart) * 1000)
            : nil

        DispatchQueue.main.asyncAfter(deadline: .now() + ViewControllerSwizzler.settleWindow) { [weak self] in
            // Có VC khác appear sau mình → mình chỉ là container trung gian.
            guard ViewControllerSwizzler.appearSeq == mySeq else {
                UniTrack.log("[UniTrack] auto screen_view SKIPPED — container superseded within settle window screen=%@", screen)
                return
            }
            if ManualTrackSignal.shouldSkip(.screen) {
                UniTrack.log("[UniTrack] auto screen_view SUPPRESSED — manual signal in window screen=%@", screen)
                return
            }
            // Layer-tagged emit so a sibling Flutter/RN SDK firing the same name
            // a few ms later is dropped by core's cross-layer dedup. Falls back
            // to the legacy untagged path on contexts where the C symbol isn't
            // present (vd version skew with an older core).
            let sameScreen = UniTrack.setScreen(screen, layer: .iOSNative)

            // Load time: viewDidLoad → first appearance. Reported once per lần
            // VÀO MÀN, không phải mỗi VC instance.
            //
            // App hay dựng lại VC cho cùng một màn (vd FPT Life tạo tab "all"
            // lúc layout rồi tạo LẠI khi API items về, 1.4s sau). Đó là hai
            // instance nên cờ ut_loadReported per-instance không chặn được,
            // nhưng người dùng chỉ thấy MỘT màn liên tục — không có screen_end
            // ở giữa. Lần dựng thứ hai đo thời gian thay VC, không đo trải
            // nghiệm của ai, nên bỏ.
            //
            // Dùng lại kết quả dup guard của setScreen thay vì tự so tên: chỉ
            // một nguồn sự thật cho "màn có đổi không".
            //
            // Phải bắn SAU setScreen trong cùng closure: Snowplow gắn entity
            // `screen` theo ScreenView gần nhất, nên nếu bắn sớm hơn thì
            // screen_name trong payload lệch một nhịp so với entity.
            // Event name resolves from UniTrack.screenLoadEventName (set during
            // _initialize from config.screenLoadEvent, in turn from portal
            // `sdk_config.screen_load_event`). Default keeps "screen_load_completed".
            guard !sameScreen else {
                UniTrack.log("[UniTrack] screen_load_completed SKIPPED — VC dựng lại cho màn đang mở screen=%@", screen)
                return
            }
            guard let self = self, let ms = loadMs else { return }
            // Đánh dấu VC đã hiện ít nhất một lần → viewWillAppear lần sau
            // biết phải reset mốc thay vì giữ mốc viewDidLoad cũ.
            self.ut_loadReported = true
            // is_cached heuristic: sub-100ms load = cache hit (view already
            // decoded, no cold render). Above the threshold = fresh render.
            var props: [String: Any] = [
                "screen":        screen,
                "screen_name":   screen,
                "load_time_ms":  String(ms),
                "is_cached":     ms < 100 ? "true" : "false",
            ]
            if let prev = UniTrack.previousScreenName(), !prev.isEmpty {
                props["previous_screen_name"] = prev
            }
            UniTrack.track(UniTrack.screenLoadEventName,
                           properties: props, isAuto: true)
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
