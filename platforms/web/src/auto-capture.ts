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
// `screen_viewed` với name = pathname. Đo `screen_load_completed` qua
// PerformanceObserver hoặc fallback DOMContentLoaded.

import type { EventName, EventProperties } from './types';

type Emit = (name: EventName, props: EventProperties) => void;

interface AutoCaptureOptions {
  trackTaps: boolean;
  trackScreens: boolean;
  trackLifecycle: boolean;
  clickEvent: string;
  screenStartEvent: string;
  screenLoadEvent: string;
  screenEndEvent: string;
}

let installed = false;

export function installAutoCapture(opts: AutoCaptureOptions, emit: Emit): void {
  if (installed) return;
  installed = true;

  if (opts.trackTaps) installClickCapture(opts.clickEvent, emit);
  if (opts.trackScreens) installScreenCapture(opts.screenStartEvent, opts.screenLoadEvent, opts.screenEndEvent, emit);
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
      emitScreenEnd(emit, 'app_background');
      bgWindowAt = Date.now();
      emit('app_background', { screen: currentScreen() });
    } else {
      // Quay lại = mở một lượt xem mới trên cùng màn.
      screenEnteredAt = Date.now();
      closeBgWindow();
      fgWindowAt = Date.now();
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
let screenEnteredAt = 0;
/** Tên event kết thúc màn + hàm emit, đặt lúc install để pagehide/background
 * dùng lại được (chúng không đi qua emitScreen). */
let screenEndEvent = '';
let screenEmit: Emit | null = null;

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
    screenFgSec += Math.round((Date.now() - fgWindowAt) / 1000);
    fgWindowAt = 0;
  }
}

/** Chốt cửa sổ bg đang mở vào bộ đếm. Gọi khi tab hiện lại. */
function closeBgWindow(): void {
  if (bgWindowAt > 0) {
    screenBgSec += Math.round((Date.now() - bgWindowAt) / 1000);
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
  fgWindowAt = hidden ? 0 : Date.now();
  bgWindowAt = hidden ? Date.now() : 0;
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
export function emitScreenEnd(emit: Emit, reason: 'screen_change' | 'app_background' | 'page_hide'): void {
  if (!lastScreen || !screenEnteredAt) return;
  // Chốt cửa sổ đang mở trước khi đọc số, nếu không phần thời gian từ lần
  // chuyển trạng thái gần nhất tới giờ bị mất trắng.
  closeFgWindow();
  closeBgWindow();
  emit(screenEndEvent || 'screen_exited', {
    screen: lastScreen,
    dwell_ms: Date.now() - screenEnteredAt,
    // String — parity Iglu schema bên native (Android gửi .toString()).
    foreground_sec: String(screenFgSec),
    background_sec: String(screenBgSec),
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
let screenNameManual = false;

export function setCurrentScreen(name: string): void {
  if (name === lastScreen) return;
  // App tự gọi setScreen() cũng là đổi màn → chốt màn cũ như route change.
  if (screenEmit) emitScreenEnd(screenEmit, 'screen_change');
  lastScreen = name;
  screenNameManual = true;
  screenEnteredAt = Date.now();
  rollScreenCounters();
}

function installScreenCapture(startEvent: string, loadEvent: string, endEvent: string, emit: Emit): void {
  screenEndEvent = endEvent;
  screenEmit = emit;

  // Rời trang hẳn (đóng tab, điều hướng đi) → chốt lượt xem cuối. Nếu không,
  // màn cuối mỗi phiên vĩnh viễn không có dwell_ms — đúng hạn chế mà native
  // đang có (xem PROJECT_HANDBOOK §10).
  window.addEventListener('pagehide', () => emitScreenEnd(emit, 'page_hide'));

  // Initial screen view — DOMContentLoaded đã pass khi script async load → fire ngay.
  const fireInitial = () => emitScreen(startEvent, loadEvent, emit, true);
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
    onRouteChange(startEvent, loadEvent, emit);
    return ret;
  };
  history.replaceState = function (...args) {
    const ret = origReplace.apply(this, args as Parameters<typeof origReplace>);
    onRouteChange(startEvent, loadEvent, emit);
    return ret;
  };
  window.addEventListener('popstate', () => onRouteChange(startEvent, loadEvent, emit));
  // Hashchange cho SPA cũ dùng hash routing (vd `/#/products`).
  window.addEventListener('hashchange', () => onRouteChange(startEvent, loadEvent, emit));
}

let routeChangeAt = 0;

function onRouteChange(startEvent: string, loadEvent: string, emit: Emit): void {
  // URL đổi thật → URL lại là nguồn sự thật, kể cả trước đó app có setScreen().
  screenNameManual = false;
  routeChangeAt = performance.now();
  // Đợi 1 frame để app render xong, sau đó emit screen_viewed +
  // screen_load_completed với load_ms.
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
    emitScreen(startEvent, loadEvent, emit, false);
  };
  requestAnimationFrame(fire);
  setTimeout(fire, 250);
}

function emitScreen(startEvent: string, loadEvent: string, emit: Emit, isInitial: boolean): void {
  const path = window.location.pathname + window.location.search + window.location.hash;
  if (path === lastScreen) return;
  // App đang tự quản tên màn → không ghi đè, kể cả ở lượt initial: nếu app gọi
  // setScreen() trước khi initial screen_view kịp chạy (rất thường gặp — SPA
  // đặt tên màn ngay lúc mount), lượt initial sẽ chốt nhầm màn app vừa mở và
  // xoá mốc vào, khiến dwell_ms của nó = 0.
  if (screenNameManual && routeChangeAt === 0) return;

  // Màn cũ đóng lại trước khi màn mới mở — thứ tự này khiến timeline đọc đúng
  // nhân quả, và `dwell_ms` là thời gian thật sự ở lại màn đó.
  emitScreenEnd(emit, 'screen_change');

  lastScreen = path;
  screenEnteredAt = Date.now();
  rollScreenCounters();
  emit(startEvent, { screen: path, title: document.title });

  if (!isInitial && routeChangeAt > 0) {
    const loadMs = Math.round(performance.now() - routeChangeAt);
    emit(loadEvent, { screen: path, load_ms: loadMs });
    routeChangeAt = 0;
  } else if (isInitial) {
    // Cold start: đo qua navigation timing. `loadEventEnd` = 0 cho tới khi
    // `load` fire xong, mà hàm này chạy sớm hơn → rơi về
    // domContentLoadedEventEnd, cuối cùng là thời gian đã trôi. Trước đây
    // `if (loadMs > 0)` nuốt luôn event ở nhánh này: session d78ef976 có 57
    // screen_viewed nhưng chỉ 6 screen_load_completed vì 50 lần reload đều
    // rơi vào đúng chỗ đó.
    const nav = performance.getEntriesByType('navigation')[0] as PerformanceNavigationTiming | undefined;
    const loadMs = Math.round(
      nav?.loadEventEnd || nav?.domContentLoadedEventEnd || performance.now(),
    );
    emit(loadEvent, { screen: path, load_ms: loadMs });
  }
}
