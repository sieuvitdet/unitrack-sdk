// Auto-capture click + screen change cho web.
//
// Click: document-level listener ở capture phase → bắt mọi tap trước khi
// app code stopPropagation. Resolve element_key theo thứ tự ưu tiên:
//   1. `data-track-id` attribute (app-defined, ổn nhất)
//   2. `id`
//   3. `aria-label`
//   4. text content (cắt 40 char)
//   5. tagName + class fallback
//
// Screen: hook history.pushState/replaceState + lắng popstate. Emit
// `screen_viewed` với name = pathname. Đo `load_ms` (gắn kèm screen_viewed) qua
// PerformanceObserver hoặc fallback DOMContentLoaded.

import type { EventName, EventProperties } from './types';

type Emit = (name: EventName, props: EventProperties) => void;

interface AutoCaptureOptions {
  trackTaps: boolean;
  trackScreens: boolean;
  trackLifecycle: boolean;
  clickEvent: string;
  screenStartEvent: string;
  screenEndEvent: string;
}

let installed = false;

export function installAutoCapture(opts: AutoCaptureOptions, emit: Emit): void {
  if (installed) return;
  installed = true;

  if (opts.trackTaps) installClickCapture(opts.clickEvent, emit);
  if (opts.trackScreens) installScreenCapture(opts.screenStartEvent, opts.screenEndEvent, emit);
  if (opts.trackLifecycle) installLifecycleCapture(emit);
}

// ─── Lifecycle ──────────────────────────────────────────────────────────
//
// Parity với native `app_start` / `app_foreground` / `app_background`.
// Web không có process lifecycle nên map:
//   app_start      → lúc install (page load)
//   app_background → visibilitychange → hidden  (tab ẩn / minimize / khoá máy)
//   app_foreground → visibilitychange → visible
//
// `pagehide` KHÔNG dùng để bắn app_background: nó fire khi đóng tab, lúc đó
// event không kịp gửi qua fetch. HttpProvider đã hook pagehide → flushBeacon,
// đó mới là chỗ đúng để lo chuyện tắt tab.

function installLifecycleCapture(emit: Emit): void {
  // Hoãn 1 tick: initialize() gọi installAutoCapture TRƯỚC khi app kịp
  // addProvider(), nên emit đồng bộ ở đây sẽ fan-out vào mảng provider rỗng
  // và mất hẳn event. Cùng lý do initial screen_viewed dùng setTimeout(…, 0).
  setTimeout(() => {
    const nav = performance.getEntriesByType('navigation')[0] as PerformanceNavigationTiming | undefined;
    emit('app_start', {
      screen: currentScreen(),
      // reload / back_forward / navigate — phân biệt cold start thật vs F5.
      nav_type: nav?.type || 'unknown',
      // loadEventEnd = 0 cho tới khi `load` fire xong; script chạy trong <body>
      // thì luôn sớm hơn mốc đó → rơi về domContentLoadedEventEnd, cuối cùng là
      // thời gian đã trôi. Không nhánh nào được trả 0 vì đó là số sai, không
      // phải "chưa đo được".
      start_ms: Math.round(
        nav?.loadEventEnd || nav?.domContentLoadedEventEnd || performance.now(),
      ),
    });
  }, 0);

  let hiddenAt = 0;
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') {
      hiddenAt = Date.now();
      // Ẩn tab = dừng xem màn hiện tại. Không chốt ở đây thì thời gian tab nằm
      // nền bị cộng vào dwell_ms, biến "để quên tab 2 tiếng" thành engagement.
      // Chốt TRƯỚC khi mở cửa sổ bg: lượt xem vừa đóng chỉ chứa thời gian
      // foreground, còn khoảng ẩn sắp tới thuộc về lượt xem kế tiếp (nhánh
      // `visible` mở lại screenEnteredAt). Mở bg trước thì emitScreenEnd đóng
      // luôn cửa sổ vừa mở với 0s và khoảng ẩn không bao giờ được ghi.
      emitScreenEnd(emit, 'app_backgrounded');
      bgWindowAt = monoNow();
      emit('app_background', { screen: currentScreen() });
    } else {
      // Quay lại = mở một lượt xem mới trên cùng màn.
      screenEnteredAt = monoNow();
      closeBgWindow();
      fgWindowAt = monoNow();
      // KHÔNG gắn `background_sec` ở đây. iOS bắn app_foreground với payload
      // rỗng và chỉ đặt background_sec vào `session_ended`; web gắn thêm thì
      // cùng một event name mang schema khác nhau giữa hai nền, enricher phải
      // phân nhánh theo platform. Thời gian ẩn tab vẫn đo được — nó nằm trong
      // `screen_exited.background_sec` (per-screen, giống Android).
      emit('app_foreground', { screen: currentScreen() });
      hiddenAt = 0;
    }
  });
}

// ─── Click ──────────────────────────────────────────────────────────────

function installClickCapture(eventName: string, emit: Emit): void {
  document.addEventListener('click', (ev: MouseEvent) => {
    // Trong Shadow DOM, `event.target` bị "retarget" thành phần tử host —
    // nút thật bên trong không bao giờ lộ ra, nên web component sẽ mất sạch
    // tap hoặc ra key vô nghĩa của host. `composedPath()[0]` mới là phần tử
    // thật sự được bấm, xuyên qua mọi lớp shadow.
    const path = typeof ev.composedPath === 'function' ? ev.composedPath() : [];
    const target = (path[0] as HTMLElement) || (ev.target as HTMLElement | null);
    if (!target || !(target instanceof HTMLElement)) return;
    // Đi lên DOM tree tìm clickable nearest — button/a/[role=button]/
    // [data-track-id] thường là chỗ user thật sự bấm, không phải span text bên trong.
    //
    // Không tìm thấy => user bấm vào chỗ trống (nền section/nav/body). BỎ QUA.
    // Trước đây fallback về `target` khiến 53% click trong session test là rác,
    // với element_key = toàn bộ textContent của container ("UniTrack Demo\n Home\n
    // Products…") — đủ để lệch hẳn heatmap "most-tapped". Parity native:
    // iOS `guard sender as? UIControl else { return }`, Android `findTarget() ?: return`.
    const el = findClickableAncestor(target);
    if (!el) return;
    const key = resolveElementKey(el);
    if (!key) return;

    emit(eventName, {
      element_key: key,
      tag: el.tagName.toLowerCase(),
      screen: currentScreen(),
      href: (el as HTMLAnchorElement).href || undefined,
    });
  }, true);  // capture: true — bắt trước event handlers của app
}

// Web tương đương Android `v.isClickable || v.hasOnClickListeners()`: ngoài thẻ
// tương tác chuẩn còn nhận div/span có onclick hoặc cursor:pointer — nếu chỉ
// nhận button/a sẽ mất tap trên UI dựng bằng div (khá phổ biến ở SPA).
const INTERACTIVE_TAGS = new Set(['button', 'a', 'input', 'select', 'textarea', 'summary', 'label']);
const INTERACTIVE_ROLES = new Set(['button', 'link', 'menuitem', 'tab', 'checkbox', 'radio', 'switch', 'option']);

function findClickableAncestor(el: HTMLElement): HTMLElement | null {
  let node: HTMLElement | null = el;
  // `cursor:pointer` KẾ THỪA xuống con, nên nó không định danh được phần tử —
  // bấm <div class="price"> trong một card pointer sẽ khớp ngay ở div đó và
  // sinh key rác ("2.490.000₫") thay vì quy về card. Vì vậy nó chỉ được GHI
  // NHỚ rồi vẫn leo tiếp; tín hiệu tường minh (data-track-id / thẻ tương tác /
  // role / onclick) ở tổ tiên luôn thắng. Không tìm thấy gì tường minh thì mới
  // rơi về ứng viên pointer ngoài cùng.
  let pointerCandidate: HTMLElement | null = null;
  for (let i = 0; i < 8 && node; i++) {
    if (node.hasAttribute('data-track-id')) return node;
    if (INTERACTIVE_TAGS.has(node.tagName.toLowerCase())) return node;
    const role = node.getAttribute('role');
    if (role && INTERACTIVE_ROLES.has(role)) return node;
    if (typeof node.onclick === 'function') return node;
    // getComputedStyle tốn kém → để cuối, chỉ chạm khi các nhánh rẻ đều trượt.
    try {
      if (getComputedStyle(node).cursor === 'pointer') pointerCandidate = node;
    } catch { /* node detached */ }
    node = parentOf(node);
  }
  return pointerCandidate;
}

/** Cha của một node, xuyên qua ranh giới Shadow DOM.
 * `parentElement` trả null ở gốc shadow tree — phải nhảy tiếp sang host, nếu
 * không thì nút nằm trong web component không bao giờ tìm được `data-track-id`
 * mà app gắn ở phần tử bọc ngoài. */
function parentOf(node: HTMLElement): HTMLElement | null {
  if (node.parentElement) return node.parentElement;
  const root = node.getRootNode?.();
  if (root && root instanceof ShadowRoot && root.host instanceof HTMLElement) {
    return root.host;
  }
  return null;
}

function resolveElementKey(el: HTMLElement): string | null {
  const t1 = el.getAttribute('data-track-id');
  if (t1) return t1;
  if (el.id) return `#${el.id}`;
  const aria = el.getAttribute('aria-label');
  if (aria) return aria;
  const text = (el.textContent || '').trim();
  if (text) return text.length > 40 ? text.slice(0, 40) + '…' : text;
  const cls = el.className && typeof el.className === 'string'
    ? '.' + el.className.split(/\s+/).filter(Boolean).join('.')
    : '';
  return `${el.tagName.toLowerCase()}${cls}` || null;
}

// ─── Screen ─────────────────────────────────────────────────────────────

let lastScreen = '';
/** Mốc vào màn hiện tại — để tính dwell_ms lúc rời đi. */
/** Đồng hồ đơn điệu (ms). Không bao giờ chạy lùi, không bị chỉnh giờ tác động.
 *  Cùng mẫu với session.ts:227 — ở đó nó đã sửa bug "phiên 33 giây báo thành
 *  2088 giây" đo được trên production 2026-08-22. Mọi mốc dùng để TRỪ ra
 *  khoảng thời gian (dwell màn, cửa sổ fg/bg) phải đi qua đây; `Date.now()`
 *  chỉ dành cho timestamp gửi lên server. */
function monoNow(): number {
  try {
    return performance.now();
  } catch {
    return Date.now();
  }
}

let screenEnteredAt = 0;
/** Tên event kết thúc màn + hàm emit, đặt lúc install để pagehide/background
 * dùng lại được (chúng không đi qua emitScreen). */
let screenEndEvent = '';
let screenEmit: Emit | null = null;
let screenStartEvent = '';

// ─── Per-screen fg/bg counters ──────────────────────────────────────────
//
// Parity Android `AppLifecycleObserver` (semantic Snowplow screen_summary):
//   foreground_sec = giây màn NÀY thực sự hiển thị
//   background_sec = giây màn NÀY nằm dưới nền (tab ẩn trong lúc màn đang mở)
// Cả hai reset mỗi lần vào màn mới, KHÔNG cộng dồn toàn phiên.
//
// `dwell_ms` là tổng thời gian treo trên màn; fg+bg tách tổng đó ra. Không có
// chúng thì "để quên tab 2 tiếng" trông y hệt "đọc 2 tiếng".
let screenFgSec = 0;
let screenBgSec = 0;
/** Mốc mở cửa sổ foreground hiện tại. 0 khi tab đang ẩn. */
let fgWindowAt = 0;
/** Mốc tab ẩn đi. 0 khi tab đang hiện. */
let bgWindowAt = 0;

/** Chốt cửa sổ fg đang mở vào bộ đếm. Gọi khi tab ẩn hoặc khi màn đóng. */
function closeFgWindow(): void {
  if (fgWindowAt > 0) {
    screenFgSec += Math.max(0, Math.round((monoNow() - fgWindowAt) / 1000));
    fgWindowAt = 0;
  }
}

/** Chốt cửa sổ bg đang mở vào bộ đếm. Gọi khi tab hiện lại. */
function closeBgWindow(): void {
  if (bgWindowAt > 0) {
    screenBgSec += Math.max(0, Math.round((monoNow() - bgWindowAt) / 1000));
    bgWindowAt = 0;
  }
}

/** Vào màn mới → đếm lại từ đầu. Parity Android `rollScreenCounters()`. */
function rollScreenCounters(): void {
  screenFgSec = 0;
  screenBgSec = 0;
  // Đúng một cửa sổ luôn mở, theo trạng thái tab lúc vào màn. Nếu để cả hai = 0
  // khi tab đang ẩn (SPA điều hướng dưới nền, hoặc tab mở ở background) thì
  // không cửa sổ nào chạy và toàn bộ thời gian màn đó biến mất khỏi cả fg lẫn
  // bg — dwell_ms > 0 mà fg+bg = 0.
  const hidden = isHidden();
  fgWindowAt = hidden ? 0 : monoNow();
  bgWindowAt = hidden ? monoNow() : 0;
}

function isHidden(): boolean {
  try { return document.visibilityState === 'hidden'; } catch { return false; }
}

/** Bắn `screen_exited` cho màn đang mở, kèm dwell_ms.
 *
 * Parity native: core C++ bắn `screen_end` + `dwell_ms` khi `set_screen` đổi.
 * Web trước đây khai báo `screenEndEvent` ở 4 file mà không chỗ nào emit, nên
 * không tính được thời gian ở lại màn.
 *
 * `reason` phân biệt vì sao màn đóng — đổi route, ẩn tab, hay rời trang. Nếu
 * gộp một loại thì không tách được "đọc xong rồi đi tiếp" với "bỏ ngang". */
export function emitScreenEnd(emit: Emit, reason: 'screen_change' | 'app_backgrounded' | 'page_hide'): void {
  if (!lastScreen || !screenEnteredAt) return;
  // Chốt cửa sổ đang mở trước khi đọc số, nếu không phần thời gian từ lần
  // chuyển trạng thái gần nhất tới giờ bị mất trắng.
  closeFgWindow();
  closeBgWindow();
  const dwellMs = Math.max(0, monoNow() - screenEnteredAt);
  emit(screenEndEvent || 'screen_exited', {
    screen: lastScreen,
    // screen_name — trùng giá trị `screen`, KHÔNG thừa: đây là field name mà
    // Iglu schema vn.fpt.ftel.snowplow/screen_end khai, còn `screen` là tên
    // legacy portal đọc. Core C++ (tracker.cpp:214) gửi cả hai vì đúng lý do
    // này; web thiếu nó nên query mobile áp lên web là hụt.
    screen_name: lastScreen,
    dwell_ms: dwellMs,
    // String — parity Iglu schema bên native (Android gửi .toString()).
    foreground_sec: String(screenFgSec),
    background_sec: String(screenBgSec),
    // Màn cuối của một lượt dùng hay không. Parity mobile: đổi route thì
    // "false" (core C++ tracker.cpp:217 hardcode false), còn app xuống nền /
    // rời trang thì "true" (AppLifecycleObserver iOS:126, Android:150).
    is_exit_screen: reason === 'screen_change' ? 'false' : 'true',
    reason,
  });
  // Không xoá lastScreen — màn vẫn là màn đó, chỉ là đã đóng một lượt xem.
  // Xoá mốc để lượt sau không bắn trùng khi chưa vào lại màn nào.
  screenEnteredAt = 0;
  // Số đã bắn đi rồi → về 0, nếu không lượt xem kế tiếp bắt đầu với số của
  // lượt vừa đóng và cùng khoảng thời gian bị đếm hai lần. Đóng màn ở đây là
  // chỗ DUY NHẤT một lượt xem kết thúc, nên reset đúng chỗ này thay vì trông
  // chờ rollScreenCounters() — đường ẩn tab không đi qua hàm đó.
  screenFgSec = 0;
  screenBgSec = 0;
}

export function currentScreen(): string {
  // Default: pathname. App có thể override qua UniTrack.setScreen.
  if (lastScreen) return lastScreen;
  try {
    return window.location.pathname || '/';
  } catch {
    return '/';
  }
}

/** App tự đặt tên màn (setScreen) → từ đó URL không còn là nguồn sự thật.
 * Nếu vẫn để auto-capture ghi đè theo location, hai nguồn đá nhau: tên do app
 * đặt bị chốt nhầm ngay lần route-change kế tiếp và dwell_ms tính sai. */
/** Tên màn mà app đặt bằng setScreen() gần nhất; rỗng nếu app chưa từng gọi
 *  hoặc đã trả quyền. */
let manualScreenName = '';
/** URL (pathname+search+hash) tại thời điểm app gọi setScreen() gần nhất. */
let manualScreenPath = '';

/** Auto-capture có được ghi đè tên màn hiện tại không?
 *
 *  Neo vào DANH TÍNH màn, không phải thời gian. Hai cách sai đã thử:
 *    • cờ boolean chỉ hạ ở reset() → kẹt vĩnh viễn, app gọi setScreen() một
 *      lần (mở modal) rồi điều hướng URL thuần là mất trắng mọi event màn.
 *    • cửa sổ thời gian → rAF bị hoãn tới 680ms khi tab không focus, và
 *      render() của app có thể chạy TRƯỚC onRouteChange tuỳ thứ tự đăng ký
 *      listener. Đo trên Chrome: setScreen ở 33775ms, callback ở 34455ms.
 *
 *  Quy tắc: app đang giữ đúng màn này thì auto-capture im. App chuyển sang
 *  điều hướng URL thuần → `lastScreen` do auto-capture đặt, khác
 *  `manualScreenName`, quyền tự động trả về. */
function appOwnsScreenName(path: string): boolean {
  // `manualScreenPath` là URL tại thời điểm app gọi setScreen(). Trùng path
  // hiện tại → app đã đặt tên cho ĐÚNG màn này, auto-capture im. Path đã đổi
  // mà app không setScreen() lần nào nữa → app thôi quản, quyền trả về URL.
  //
  // Neo vào `lastScreen` thì hỏng: auto-capture bị chặn nên lastScreen không
  // bao giờ đổi, điều kiện mãi đúng và cờ kẹt y như bản boolean.
  return manualScreenName !== '' && manualScreenPath === path;
}

/** Trả quyền đặt tên màn về cho URL ngay lập tức. Gọi từ reset(): phiên mới,
 *  app chưa setScreen() lần nào. */
export function resetScreenOwnership(): void {
  manualScreenName = '';
  manualScreenPath = '';
}

export function setCurrentScreen(name: string): void {
  if (name === lastScreen) return;
  const previous = lastScreen;
  // App tự gọi setScreen() cũng là đổi màn → chốt màn cũ như route change.
  if (screenEmit) emitScreenEnd(screenEmit, 'screen_change');
  lastScreen = name;
  manualScreenName = name;
  manualScreenPath = currentPath();
  screenEnteredAt = monoNow();
  rollScreenCounters();
  // Và mở màn mới. Thiếu vế này thì setScreen() chỉ đóng màn cũ mà không bao
  // giờ báo đã vào màn nào — app SPA tự đặt tên màn sẽ có screen_exited mà
  // không có screen_viewed tương ứng, đúng cái đội Data thấy lệch so với
  // mobile (core C++ tracker.cpp:210-231 bắn cả cặp trong set_screen).
  if (screenEmit) {
    // load_ms: khoảng từ lúc URL đổi tới lúc app báo đã vào màn. Mốc do
    // onRouteChange đặt; app gọi setScreen() ngoài route change (mở modal,
    // đổi tab nội bộ) thì không có mốc và bỏ hẳn field.
    const loadMs = routeChangeAt > 0
      ? Math.round(performance.now() - routeChangeAt) : undefined;
    routeChangeAt = 0;
    screenEmit(screenStartEvent || 'screen_viewed', {
      screen: name,
      screen_name: name,
      ...(previous ? {
        from: previous,
        from_screen: previous,
        previous_screen_name: previous,
      } : {}),
      ...(loadMs !== undefined ? { load_ms: loadMs } : {}),
    });
  }
}

function installScreenCapture(startEvent: string, endEvent: string, emit: Emit): void {
  screenStartEvent = startEvent;
  screenEndEvent = endEvent;
  screenEmit = emit;

  // Rời trang hẳn (đóng tab, điều hướng đi) → chốt lượt xem cuối. Nếu không,
  // màn cuối mỗi phiên vĩnh viễn không có dwell_ms — đúng hạn chế mà native
  // đang có (xem PROJECT_HANDBOOK §10).
  window.addEventListener('pagehide', () => emitScreenEnd(emit, 'page_hide'));

  // Initial screen view — DOMContentLoaded đã pass khi script async load → fire ngay.
  const fireInitial = () => emitScreen(startEvent, emit, true);
  if (document.readyState === 'complete' || document.readyState === 'interactive') {
    setTimeout(fireInitial, 0);
  } else {
    document.addEventListener('DOMContentLoaded', fireInitial, { once: true });
  }

  // Hook pushState + replaceState để SPA route change được bắt.
  // Native popstate event không fire khi pushState — phải tự monkey-patch.
  const origPush = history.pushState;
  const origReplace = history.replaceState;
  history.pushState = function (...args) {
    const ret = origPush.apply(this, args as Parameters<typeof origPush>);
    onRouteChange(startEvent, emit);
    return ret;
  };
  history.replaceState = function (...args) {
    const ret = origReplace.apply(this, args as Parameters<typeof origReplace>);
    onRouteChange(startEvent, emit);
    return ret;
  };
  window.addEventListener('popstate', () => onRouteChange(startEvent, emit));
  // Hashchange cho SPA cũ dùng hash routing (vd `/#/products`).
  window.addEventListener('hashchange', () => onRouteChange(startEvent, emit));
}

let routeChangeAt = 0;

function onRouteChange(startEvent: string, emit: Emit): void {
  // KHÔNG hạ quyền đặt tên màn ở đây.
  //
  // Trước đây có dòng `screenNameManual = false` ngay chỗ này với lý do "URL
  // đổi thật → URL lại là nguồn sự thật". Nhưng SPA nào tự đặt tên màn thì
  // route change nào nó cũng gọi setScreen(), nên cờ vừa bị hạ lại được bật
  // lên — và giữa hai thời điểm đó, callback rAF/250ms của chính hàm này chạy,
  // thấy quyền đang thuộc URL nên ghi đè tên màn của app bằng full path.
  //
  // Đo trên Chrome thật (showcase.html, một lần đổi hash):
  //   setScreen(/products) → screen_exited /  + screen_viewed /products   ← đúng
  //   rAF fire            → screen_exited /products
  //                       + screen_viewed /…/showcase.html#/products      ← thừa
  // Trên portal thành 14 screen_end cho 4 màn thật, kèm HAI bộ tên song song.
  //
  // Quyền hết hạn theo thời gian (appOwnsScreenName), nên app dùng setScreen()
  // một lần rồi thôi vẫn không chặn auto-capture ở các lượt sau.
  routeChangeAt = performance.now();
  // Đợi 1 frame để app render xong, sau đó emit screen_viewed kèm load_ms.
  //
  // rAF bị đóng băng hoàn toàn ở tab ẩn — SPA điều hướng dưới nền (mở link
  // bằng chuột giữa, chuyển tab rồi router chạy tiếp) sẽ không bao giờ bắn
  // screen_viewed lẫn screen_exited: cả màn đó biến mất khỏi dữ liệu. Nên
  // chạy kèm một setTimeout làm phao: setTimeout vẫn chạy khi ẩn (có bị bóp
  // xuống ~1 lần/giây nhưng vẫn chạy). Ai tới trước thì thắng, `done` chặn
  // lượt sau để không bắn đôi khi tab hiện lại giữa chừng.
  let done = false;
  const fire = () => {
    if (done) return;
    done = true;
    emitScreen(startEvent, emit, false);
  };
  // KHÔNG chạy ngay ở frame kế: app SPA gọi setScreen() bên trong render(),
  // mà render() có thể chạy TRƯỚC hoặc SAU listener này tuỳ thứ tự đăng ký.
  // Chạy sớm quá thì lượt đổi màn ĐẦU TIÊN sau khi tải trang bị auto-capture
  // chiếm mất (đo trên Chrome: 4 event, hai bộ tên song song, các lượt sau
  // thì đúng vì lúc đó manualScreenPath đã có). Một frame đủ để render() xong.
  requestAnimationFrame(() => requestAnimationFrame(fire));
  setTimeout(fire, 250);
}

function currentPath(): string {
  try {
    return window.location.pathname + window.location.search + window.location.hash;
  } catch { return ''; }
}

function emitScreen(startEvent: string, emit: Emit, isInitial: boolean): void {
  const path = currentPath();
  if (path === lastScreen) return;
  // App đang tự quản tên màn → KHÔNG ghi đè, kể cả khi route vừa đổi.
  //
  // Trước đây guard này còn kèm `routeChangeAt === 0`, nên mọi hashchange đều
  // lọt qua: SPA gọi setScreen('#/products') trong render(), còn hàm này chốt
  // lại bằng full path ('/…/showcase.html#/products'). Hai tên khác nhau cho
  // CÙNG một màn → mỗi lần đổi route sinh 3 cặp view/end thay vì 1 (đo trên
  // portal session 93e91277: 14 screen_end cho 4 màn thật).
  //
  // App đã nhận trách nhiệm đặt tên màn thì nó cũng gọi setScreen() ở mọi
  // route change — auto-capture không cần chen vào nữa.
  // Mốc routeChangeAt để nguyên: setCurrentScreen() sẽ đọc nó để tính
  // load_ms rồi tự xoá. Xoá ở đây là mất số đo.
  if (appOwnsScreenName(path)) return;

  // Màn cũ đóng lại trước khi màn mới mở — thứ tự này khiến timeline đọc đúng
  // nhân quả, và `dwell_ms` là thời gian thật sự ở lại màn đó.
  // Chụp tên màn cũ TRƯỚC khi emitScreenEnd, vì hàm đó không đổi lastScreen
  // nhưng dòng gán ngay dưới thì có — đọc sau là ra màn đang VÀO.
  const previous = lastScreen;
  emitScreenEnd(emit, 'screen_change');

  lastScreen = path;
  screenEnteredAt = monoNow();
  rollScreenCounters();

  // load_ms đi KÈM screen_view, không còn event `screen_load_completed`
  // riêng. Web chỉ dùng đúng 2 schema màn hình: screen_view + screen_end.
  // Một event ít hơn cho mỗi lần chuyển màn, và đội Data đọc load_ms ngay
  // trên hàng screen_view thay vì phải join hai event theo screen + thời gian.
  let loadMs: number | undefined;
  if (!isInitial && routeChangeAt > 0) {
    loadMs = Math.round(performance.now() - routeChangeAt);
    routeChangeAt = 0;
  } else if (isInitial) {
    // Cold start: đo qua navigation timing. `loadEventEnd` = 0 cho tới khi
    // `load` fire xong, mà hàm này chạy sớm hơn → rơi về
    // domContentLoadedEventEnd, cuối cùng là thời gian đã trôi.
    const nav = performance.getEntriesByType('navigation')[0] as PerformanceNavigationTiming | undefined;
    loadMs = Math.round(
      nav?.loadEventEnd || nav?.domContentLoadedEventEnd || performance.now(),
    );
  }

  emit(startEvent, {
    screen: path,
    // screen_name — field name Iglu schema khai, `screen` là tên legacy.
    // Core C++ gửi cả hai (tracker.cpp:225).
    screen_name: path,
    title: document.title,
    // Màn đi tới từ đâu. Core C++ gửi 3 tên cho cùng một giá trị
    // (tracker.cpp:228-230): `from` + `from_screen` legacy, còn
    // `previous_screen_name` là tên schema. Web thiếu cả ba nên không dựng
    // được luồng chuyển màn như mobile. Lượt vào đầu tiên không có màn trước
    // → bỏ hẳn field thay vì gửi chuỗi rỗng.
    ...(previous ? {
      from: previous,
      from_screen: previous,
      previous_screen_name: previous,
    } : {}),
    ...(loadMs !== undefined ? { load_ms: loadMs } : {}),
  });
}
