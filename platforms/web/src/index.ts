// @unitrack/web — Public entry point.
//
// API parity với Flutter `UniTrack.instance.*` + iOS Swift `UniTrack.*`:
//   - initialize(apiKey, config)
//   - track(name, props)
//   - customTrack(name, { action, data, includeUser })
//   - identify(userId, traits)
//   - reset()
//   - setScreen(name)
//   - currentSessionId(), sessionIndex(), previousSessionId(), rotateSession()
//   - addProvider(provider)
//   - flush()

import type {
  AnalyticsProvider,
  CapturePlugin,
  EventName,
  EventProperties,
  UniTrackConfig,
} from './types';
import { SessionManager } from './session';
import { installAutoCapture, setCurrentScreen, currentScreen, resetScreenOwnership } from './auto-capture';
import { installNetworkInterceptor } from './network-interceptor';
import { configureSalt, sha256 } from './pii-hash';
import { readCrossDomainSession } from './plugins/cross-domain';
import * as Queue from './offline-queue';
import { fetchRemoteConfig, applyFlavor, toSDKConfig, resolveSnowplow } from './remote-config';
import { SnowplowProvider } from './providers/snowplow';
import { HttpProvider } from './providers/http-provider';

export type { UniTrackConfig, AnalyticsProvider, CapturePlugin, EventProperties };
// Plugin đầu vào — import riêng để bundler tree-shake được cái không dùng.
export { webVitalsPlugin } from './plugins/web-vitals';
export { formTrackingPlugin } from './plugins/form-tracking';
export { engagementPlugin } from './plugins/engagement';
export { mediaPlugin } from './plugins/media';
export { streamingPlugin } from './plugins/streaming';
export type { StreamingOptions } from './plugins/streaming';
export { crossDomainPlugin, readCrossDomainSession } from './plugins/cross-domain';
export type { CrossDomainOptions } from './plugins/cross-domain';
export type { WebVitalsOptions } from './plugins/web-vitals';
export type { FormTrackingOptions } from './plugins/form-tracking';
export type { EngagementOptions } from './plugins/engagement';
export type { MediaOptions } from './plugins/media';
export { HttpProvider } from './providers/http-provider';
export { SnowplowProvider } from './providers/snowplow';
export { GA4Provider } from './providers/ga4';
export { SdkBridgeProvider } from './providers/sdk-bridge';
export type { GA4ProviderConfig } from './providers/ga4';
export type { SdkBridgeConfig } from './providers/sdk-bridge';
export type { HttpProviderConfig } from './providers/http-provider';
export type { SnowplowProviderConfig } from './providers/snowplow';
export {
  fetchRemoteConfig,
  applyFlavor,
  toSDKConfig,
} from './remote-config';
export type { RemoteConfig } from './remote-config';
export { sha256, configureSalt } from './pii-hash';
export { resolveSnowplow } from './remote-config';

/** Ép MỌI giá trị trong payload về String.
 *
 * Field cùng tên hiện có kiểu khác nhau tuỳ nguồn phát (`session_index` là
 * number, `foreground_sec` là string, `had_crash` là boolean) — schema strict
 * ở downstream sẽ reject. Chuẩn hoá một kiểu duy nhất tại đây thay vì sửa
 * từng chỗ gọi track().
 *
 * Đặt ở `track()` vì đó là cửa duy nhất mọi event đi qua trước khi fan-out,
 * nên Snowplow lẫn HTTP provider đều nhận cùng payload đã chuẩn hoá.
 */
/** Trait mang PII — hash trước khi rời máy người dùng. Khớp field name mà
 *  user_context của FPT Life dùng (đo thật trên portal project 8). */
const PII_TRAITS = ['user_name', 'phone_number', 'email'];

function stringifyProps(props: EventProperties): Record<string, string> {
  const out: Record<string, string> = {};
  for (const k of Object.keys(props)) {
    const v = props[k];
    // Bỏ hẳn null/undefined: chuỗi "null"/"undefined" là rác, và làm downstream
    // không phân biệt được "không có field" với "có giá trị rỗng".
    if (v == null) continue;
    // Object/mảng phải JSON.stringify — String({}) ra "[object Object]", mất
    // sạch dữ liệu.
    out[k] = typeof v === 'object' ? JSON.stringify(v) : String(v);
  }
  return out;
}

class UniTrackImpl {
  private initialized = false;
  private cfg: Required<UniTrackConfig> = defaultCfg();
  private session: SessionManager | null = null;
  private providers: AnalyticsProvider[] = [];
  private apiKey = '';
  private identifiedUserId: string | null = null;
  private identifiedTraits: EventProperties = {};
  /** Chưa gọi setConsent() thì mặc định theo config (`requireConsent`). */
  private plugins: CapturePlugin[] = [];
  private pluginTeardowns: Array<() => void> = [];
  private consentGranted = true;
  /** Quyết định sampling một lần cho cả phiên, không random từng event —
   * nếu random mỗi lần thì một phiên bị cắt vụn (có click, mất screen_view
   * dẫn tới nó), hành trình vá lại không đọc được. Native cũng vậy. */
  private sessionSampled = true;

  /** Khởi tạo từ file config JSON — parity FPT Life iOS/Android.
   *
   * Mọi thông tin nằm sẵn trong file (apiKey, endpoint, cờ thu thập, cấu hình
   * Snowplow); host chỉ chỉ đường dẫn. Dùng chung schema `RemoteConfig` với
   * `trackingConfig.json` của FPT Life nên một file chạy được cả ba nền.
   *
   *     await UniTrack.initializeFromConfig('/unitrack.config.json');
   *     await UniTrack.initializeFromConfig('/unitrack.config.json', 'beta');
   *
   * `flavor` chọn khối override trong `flavors`, giống EnvManager bên iOS.
   *
   * Provider gắn theo file nên không phải addProvider() tay:
   *  - `snowplow.enabled` → SnowplowProvider
   *  - `endpoint` khác rỗng → HttpProvider
   */
  async initializeFromConfig(url: string, flavor?: string): Promise<void> {
    const raw = await fetchRemoteConfig(url);
    if (!raw) { this.log('config: không tải được', url); return; }
    const file = flavor ? applyFlavor(raw, flavor) : raw;

    const sp = file.snowplow;
    const { endpoint: spEndpoint, appId: spAppId } = resolveSnowplow(file);
    // Đăng ký TRƯỚC initialize(): network-interceptor được cài bên trong
    // initialize() và chốt danh sách exclude ngay lúc đó.
    if (sp?.enabled && spEndpoint) this.providerEndpoints.push(spEndpoint);

    this.initialize(file.apiKey || '', toSDKConfig(file));

    if (sp?.enabled && spEndpoint) {
      this.addProvider(new SnowplowProvider({
        endpoint:       spEndpoint,
        appId:          spAppId || '',
        igluVendor:     sp.iglu_vendor || '',
        defaultVersion: sp.default_version,
        eventNames:     sp.event_names,
        entities:       sp.entities,
        dropEvents:     sp.drop_events,
        businessKind:   sp.business_kind,
        businessEventKinds: sp.business_event_kinds,
        ownSchemaEvents: sp.own_schema_events,
        flushIntervalMs: file.sdk_config?.flushIntervalMs,
        batchSize:      file.sdk_config?.batchSize,
        verboseLogging: this.cfg.verboseLogging,
      }));
    }
    // Core ingest rỗng → chỉ fan-out Snowplow. Giống FPT Life, log ra để không
    // ai tưởng SDK hỏng khi thấy Network trống.
    if (file.endpoint) {
      this.addProvider(new HttpProvider({
        endpoint: file.endpoint,
        apiKey:   file.apiKey || '',
        batchSize:       file.sdk_config?.batchSize,
        flushIntervalMs: file.sdk_config?.flushIntervalMs,
        verboseLogging:  this.cfg.verboseLogging,
      }));
    } else {
      this.log('core ingest endpoint rỗng — fan-out provider only');
    }
  }

  initialize(apiKey: string, config?: UniTrackConfig): void {
    if (this.initialized) {
      this.log('initialize: skip — already initialized');
      return;
    }
    this.initialized = true;
    this.apiKey = apiKey;
    this.cfg = { ...defaultCfg(), ...(config || {}) } as Required<UniTrackConfig>;
    if (this.cfg.piiSalt) configureSalt(this.cfg.piiSalt);

    // Ẩn danh 'full' → session chỉ nằm trong bộ nhớ, không chạm localStorage.
    this.session = new SessionManager(
      this.cfg.sessionTimeoutMs,
      this.cfg.anonymousTracking === 'full',
    );

    // Phiên đóng → `session_ended` mang số liệu của phiên CŨ. Parity iOS
    // (`AppLifecycleObserver.emitSessionBoundariesIfNeeded`). Đặt trước mọi
    // đường có thể xoay phiên (adopt/track/reset) để không bỏ sót lần nào.
    //
    // `reason: 'timeout'` = idle quá `sessionTimeoutMs`; 'manual' = reset()
    // hoặc rotateSession(). iOS chỉ bắn khi timeout, web bắn cả hai vì logout
    // trên web thường xuyên hơn và phiên đó vẫn cần đóng sổ.
    this.session.onRotate = (closed) => {
      // `session_id` của event này là phiên VỪA ĐÓNG, không phải phiên mới.
      // Parity mobile (đo trên portal project 8): session_ended bên đó đặt
      // thẳng phiên đã đóng vào `session_id`, vì event này nói VỀ phiên đó —
      // để nó mang phiên mới thì mọi phép group-by session lại đếm nhầm
      // event kết thúc vào phiên kế tiếp.
      //
      // `ended_session_id` giữ lại cho consumer cũ của web; `previous_session_id`
      // là tên mobile dùng. Cả ba cùng một giá trị — trùng lặp có chủ đích,
      // giống cách core C++ gửi `from`/`from_screen`/`previous_screen_name`.
      this.track('session_ended', {
        session_id:           closed.id,
        ended_session_id:     closed.id,
        previous_session_id:  closed.id,
        session_duration_sec: closed.durationSec,
        screen_count:         closed.screenCount,
        had_error:            closed.hadError,
        had_crash:            closed.hadCrash,
        reason:               closed.reason,
      });
      // Đóng sổ phiên cũ xong thì mở sổ phiên mới. Mobile bắn cặp
      // session_started/session_ended (28/1 trên project 8); web trước đây chỉ
      // có vế đóng, nên không đếm được số phiên bắt đầu và không nối được
      // phiên mới với phiên trước nó.
      this.track('session_started', {
        previous_session_id: closed.id,
        session_index:       this.session?.sessionIndex(),
        entry_source:        closed.reason === 'timeout' ? 'timeout_resume' : 'app_open',
      });
    };

    // Đến từ domain khác có mang `_sp` → nối tiếp session thay vì mở phiên mới.
    // Đọc ngay tại đây để mọi event sau đó đều mang đúng session_id, kể cả
    // app_start bắn sớm nhất.
    if (this.cfg.crossDomainSession) {
      const inbound = readCrossDomainSession();
      if (inbound?.sessionId) {
        this.session.adopt(inbound.sessionId);
        this.log('nối session từ', inbound.sourceId, '→', inbound.sessionId);
      }
    }

    // requireConsent: true → im lặng cho tới khi app gọi setConsent(true).
    this.consentGranted = !this.cfg.requireConsent;

    // Gieo sampling theo session_id để một phiên hoặc vào mẫu trọn vẹn, hoặc
    // không có gì — quyết định giữ nguyên qua reload vì session_id giữ nguyên.
    const rate = this.cfg.samplingRate;
    this.sessionSampled = rate >= 1 ? true
      : rate <= 0 ? false
      : hashUnit(this.session.currentSessionId()) < rate;
    if (!this.sessionSampled) this.log(`session sampled out (rate=${rate})`);

    if (this.cfg.autoCapture) {
      installAutoCapture(
        {
          trackTaps: this.cfg.trackTaps,
          trackScreens: this.cfg.trackScreens,
          trackLifecycle: this.cfg.trackLifecycle,
          clickEvent: this.cfg.clickEvent,
          screenStartEvent: this.cfg.screenStartEvent,
          screenEndEvent: this.cfg.screenEndEvent,
        },
        (name, props) => this.track(name, props as EventProperties),
      );
    }

    installNetworkInterceptor(
      {
        trackNetwork: this.cfg.trackNetwork,
        tracingAllowlistHosts: this.cfg.tracingAllowlistHosts,
        excludeSubstrings: this.computeExcludes(),
        networkEventName: 'network_request',
        errorEventName: 'network_error',
      },
      (name, props) => this.track(name, props as EventProperties),
    );

    // Crash capture
    window.addEventListener('error', (ev) => {
      this.track('crash', {
        message: String(ev.message || ''),
        filename: ev.filename,
        lineno: ev.lineno,
        colno: ev.colno,
        stack: ev.error?.stack,
        type: 'window.onerror',
      });
    });
    window.addEventListener('unhandledrejection', (ev) => {
      this.track('crash', {
        message: String((ev.reason as Error)?.message || ev.reason),
        stack: (ev.reason as Error)?.stack,
        type: 'unhandledrejection',
      });
    });

    // Bring up providers — same iteration order as registered.
    for (const p of this.providers) {
      try { p.init?.(); } catch (e) { this.log('provider init err:', e); }
    }

    // Plugin đầu vào chạy SAU provider: plugin có thể emit ngay lúc install
    // (Web Vitals đọc entry đã buffer), event đó cần provider sẵn sàng để nhận.
    for (const pl of this.plugins) this.installPlugin(pl);

    // Replay queue do provider tự lo (HttpProvider.drainPersisted) — nó giữ
    // nguyên event_id + timestamp gốc, thay vì dựng lại event mới.

    // Phiên mở đầu được SessionManager dựng thẳng trong constructor, không đi
    // qua rotate() nên onRotate ở trên không chạy. Bắn bù ở đây để mọi phiên
    // đều có vế mở, không riêng phiên thứ 2 trở đi.
    if (this.session.freshlyStarted) {
      this.session.freshlyStarted = false;
      const prev = this.session.previousSessionId();
      this.track('session_started', {
        ...(prev ? { previous_session_id: prev } : {}),
        session_index: this.session.sessionIndex(),
        entry_source: prev ? 'timeout_resume' : 'app_open',
      });
    }

    this.log(`initialized — apiKey=${apiKey.slice(0, 8)}… session=${this.session.currentSessionId()}`);
  }

  /** Gắn plugin đầu vào (Web Vitals, form, scroll…). Gọi trước hoặc sau
   * `initialize()` đều được — trước thì xếp hàng, init xong mới chạy. */
  use(plugin: CapturePlugin): void {
    this.plugins.push(plugin);
    if (this.initialized) this.installPlugin(plugin);
  }

  private installPlugin(plugin: CapturePlugin): void {
    try {
      const teardown = plugin.install((n, p) => this.track(n, p));
      if (typeof teardown === 'function') this.pluginTeardowns.push(teardown);
      this.log('plugin installed:', plugin.name);
    } catch (e) {
      // Plugin hỏng không được kéo sập tracking lõi.
      this.log('plugin install err:', plugin.name, e);
    }
  }

  addProvider(provider: AnalyticsProvider): void {
    this.providers.push(provider);
    if (this.initialized) {
      try { provider.init?.(); } catch (e) { this.log('provider init err:', e); }
    }
  }

  track(name: EventName, properties: EventProperties = {}): void {
    if (!this.initialized || !this.session) {
      this.log('track: SDK not initialized — drop event', name);
      return;
    }
    if (!this.consentGranted) {
      this.log('track: chưa có consent — drop', name);
      return;
    }
    if (!this.passesSampling(name)) {
      this.log('track: sampled out', name);
      return;
    }
    // Nuôi số liệu cho `session_ended`. Đặt TRƯỚC touch(): touch() có thể xoay
    // phiên, và event đang xử lý thuộc về phiên CŨ nên phải được đếm vào đó.
    if (name === this.cfg.screenStartEvent || name === 'screen_viewed') this.session.noteScreen();
    else if (name === 'crash') this.session.noteCrash();
    else if (name === 'network_error') this.session.noteError();

    this.session.touch();
    const enriched: EventProperties = {
      ...properties,
      // `??` chứ không gán đè: session_ended phải mang phiên VỪA ĐÓNG, mà nó
      // được bắn ngay sau khi rotate xong nên currentSessionId() đã là phiên
      // mới. Caller nào tự biết session của mình thì được quyền quyết.
      session_id: properties.session_id ?? this.session.currentSessionId(),
      session_index: properties.session_index ?? this.session.sessionIndex(),
      screen: properties.screen || currentScreen(),
      // Tên nghiệp vụ — thứ đội Data pivot theo, và portal hiển thị ở cột
      // "Event action". Gắn ở ĐÂY chứ không riêng trong SnowplowProvider:
      // đường portal-ingest trước đây không có field này nên 109/112 hàng
      // `provider=unitrack` để trống, trong khi bản mirror Snowplow của cùng
      // event thì có. Cùng một lần track() mà hai đường lệch nhau.
      event_action: properties.event_action ?? name,
      ts: Date.now(),
    };
    // Chốt chặn cuối: app có thể tự nhét user_id vào properties (customTrack,
    // hoặc gọi track trực tiếp). Ẩn danh mà vẫn để lọt thì cờ thành vô nghĩa.
    if (this.cfg.anonymousTracking) {
      delete enriched.user_id;
      delete enriched.user_name;
      delete enriched.email;
    }
    if (this.cfg.verboseLogging) {
      console.log(`[UniTrack] ${name}`, enriched);
    }
    // Chuẩn hoá kiểu NGAY TRƯỚC fan-out: verboseLogging ở trên vẫn in giá trị
    // gốc để debug, còn thứ đi lên mạng luôn là String.
    const wire = stringifyProps(enriched);
    // `_kind` là chỉ dẫn định tuyến schema, chỉ SnowplowProvider hiểu — nó tự
    // xoá trước khi đóng payload. Các provider khác không biết field này và sẽ
    // đẩy nguyên nó đi (đo thật: `"_kind":"result"` nằm trong properties trên
    // portal), nên chỉ Snowplow được nhận.
    const wireNoKind = { ...wire };
    delete (wireNoKind as Record<string, unknown>)._kind;
    // Fan-out tới mọi provider (Snowplow, HTTP, …). Isolate failure.
    for (const p of this.providers) {
      const payload = p.name === 'SnowplowProvider' ? wire : wireNoKind;
      try { p.track(name, payload); } catch (e) { this.log('provider track err:', e); }
    }
  }

  customTrack(eventName: EventName, opts: {
    action?: string;
    data?: EventProperties;
    includeUser?: boolean;
  } = {}): void {
    const payload: EventProperties = {
      ...(opts.data || {}),
      event_action: opts.action ?? eventName,
    };
    if (opts.includeUser && this.identifiedUserId) {
      payload.user_id = this.identifiedUserId;
    }
    this.track(eventName, payload);
  }

  // ── Helper theo convention — parity iOS/Android ────────────────────────
  //
  // Mobile không cần khai kind trong config vì app gọi thẳng
  // `trackingResultEvent(action:status:)` / `trackingClickEvent(elementKey:)`
  // ngay tại chỗ gắn tracking. Kind nằm trong CODE, cạnh hành vi nó mô tả.
  //
  // Bốn hàm dưới đem đúng cách đó sang web. Dùng chúng thay cho `track()`
  // generic thì không phải khai `business_event_kinds` cho từng event nữa.

  /** Kết quả một thao tác — thêm giỏ, thanh toán, gửi form, xin quyền.
   *  → `ev_result`, kèm `action` + `status` như mobile. */
  trackResult(action: string, status: string, data: EventProperties = {}): void {
    this.track(action, { ...data, _kind: 'result', action, status });
  }

  /** Hành vi bấm / chọn của người dùng. → `ev_click`. */
  trackClick(action: string, data: EventProperties = {}): void {
    this.track(action, { ...data, _kind: 'click' });
  }

  /** Gọi API. → `ev_api`, `status` là HTTP status. */
  trackApi(url: string, method: string, status: number, durationMs: number,
           data: EventProperties = {}): void {
    this.track('network_request', {
      ...data, _kind: 'api', url, method, status, status_code: status,
      duration_ms: durationMs,
    });
  }

  /** Lỗi / crash. → `ev_crash`. */
  trackCrash(message: string, data: EventProperties = {}): void {
    this.track('crash', { ...data, _kind: 'crash', message });
  }

  async identify(userId: string, traits: EventProperties = {}): Promise<void> {
    // Ẩn danh ở mức nào cũng không được gắn định danh người dùng. Bỏ qua im
    // lặng thay vì ném lỗi: app bật cờ ẩn danh theo consent, code identify()
    // vẫn nằm nguyên chỗ cũ và không nên vỡ.
    if (this.cfg.anonymousTracking) {
      this.log('identify: bỏ qua — đang ẩn danh', this.cfg.anonymousTracking);
      return;
    }
    // Hash PII trước khi cache + forward provider — parity với native side.
    const hashedId = this.cfg.piiSalt ? await sha256(userId) : userId;
    this.identifiedUserId = hashedId;
    this.identifiedTraits = { ...traits };
    // traits đi vào user_context của Snowplow → cũng phải String như payload
    // event, nếu không cùng một schema lại có hai kiểu.
    const wireTraits = stringifyProps(traits);
    // Hash luôn các trait là PII. FPT Life gửi user_id/user_name/phone_number
    // đều SHA-256 (đo trên project 8), nên web để lọt tên thật hay số điện
    // thoại thô là vừa lệch schema vừa rò dữ liệu cá nhân. Chỉ hash khi có
    // salt — không salt thì hash cũng không dedup được với native.
    if (this.cfg.piiSalt) {
      for (const k of PII_TRAITS) {
        const v = wireTraits[k];
        if (v) wireTraits[k] = await sha256(v);
      }
    }
    for (const p of this.providers) {
      try { p.setUser?.(hashedId, wireTraits); } catch (e) { this.log('provider setUser err:', e); }
    }
  }

  reset(): void {
    // App thôi quản tên màn → URL lại là nguồn sự thật cho phiên mới.
    resetScreenOwnership();
    this.identifiedUserId = null;
    this.identifiedTraits = {};
    for (const p of this.providers) {
      try { p.setUser?.(null, {}); } catch (e) { this.log('provider reset err:', e); }
    }
    // Xoay session luôn — parity native. Không xoay thì sau logout, event của
    // người dùng mới vẫn mang session_id của người cũ; trên máy dùng chung
    // (máy tính công cộng, máy demo) hai danh tính dính vào một phiên.
    this.session?.rotate('manual');
    this.log('reset — session rotated to', this.session?.currentSessionId());
  }

  setScreen(name: string): void {
    setCurrentScreen(name);
    for (const p of this.providers) {
      try { p.setScreen?.(name); } catch (e) { this.log('provider setScreen err:', e); }
    }
  }

  /** Bật/tắt thu thập khi user trả lời banner cookie.
   *
   * `false` → mọi event bị chặn ngay tại `track()`, không vào buffer, không
   * xuống IndexedDB. Gọi `setConsent(true)` sau đó thì thu thập tiếp từ thời
   * điểm đó — event trong lúc bị từ chối đã bỏ hẳn, không hồi lại. */
  setConsent(granted: boolean): void {
    this.consentGranted = granted;
    this.log('consent →', granted);
    if (!granted) this.reset();   // từ chối = xoá danh tính + xoay session
  }

  hasConsent(): boolean { return this.consentGranted; }

  /** Phiên này có nằm trong mẫu không. Crash luôn được gửi bất kể sampling
   * (parity native) — mất crash là mất đúng thứ cần nhất. */
  private passesSampling(name: EventName): boolean {
    if (name === 'crash') return true;
    return this.sessionSampled;
  }

  /** Định danh đang gắn (đã hash) + traits. Rỗng khi chưa login.
   *  Dùng để UI kiểm chứng đúng thứ SDK sẽ gửi trong user_context. */
  currentUser(): { userId: string; traits: EventProperties } {
    return { userId: this.identifiedUserId || '', traits: { ...this.identifiedTraits } };
  }

  currentSessionId(): string { return this.session?.currentSessionId() || ''; }
  sessionIndex(): number { return this.session?.sessionIndex() || 0; }
  previousSessionId(): string { return this.session?.previousSessionId() || ''; }
  rotateSession(): void { this.session?.rotate('manual'); }

  async flush(): Promise<void> {
    for (const p of this.providers) {
      const anyP = p as { flush?: () => Promise<void> | void };
      if (typeof anyP.flush === 'function') {
        try { await anyP.flush(); } catch (e) { this.log('provider flush err:', e); }
      }
    }
  }

  async pendingEventCount(): Promise<number> {
    return Queue.pendingCount();
  }

  /** Host mà network-interceptor KHÔNG được track. Thiếu một host ở đây là
   *  vòng lặp vô hạn: flush → fetch → interceptor emit network_request →
   *  vào buffer → flush tiếp. Với FPT Life `endpoint` rỗng (chỉ fan-out
   *  Snowplow) nên trước đây danh sách này rỗng và collector Snowplow tự
   *  nuôi chính nó mỗi `flushIntervalMs`. */
  private computeExcludes(): string[] {
    const excludes: string[] = [];
    for (const url of [this.cfg.endpoint, ...this.providerEndpoints]) {
      if (!url) continue;
      try {
        excludes.push(new URL(url, window.location.href).host);
      } catch { /* ignore */ }
    }
    return excludes;
  }

  /** Endpoint của mọi provider đã gắn — nguồn cho computeExcludes(). */
  private providerEndpoints: string[] = [];

  private log(...args: unknown[]): void {
    if (this.cfg.verboseLogging) console.log('[UniTrack]', ...args);
  }
}

/** Chuỗi → số trong [0,1). Dùng FNV-1a: quyết định sampling phải TẤT ĐỊNH
 * theo session_id, không phải Math.random() — cùng phiên phải luôn ra cùng
 * kết quả kể cả sau reload, nếu không thì reload xong lại đổi phe. */
function hashUnit(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h / 0x100000000;
}

function defaultCfg(): Required<UniTrackConfig> {
  return {
    endpoint: '',
    autoCapture: true,
    trackScreens: true,
    trackTaps: true,
    trackNetwork: true,
    trackLifecycle: true,
    samplingRate: 1,        // mặc định lấy hết — giảm là lựa chọn có chủ đích
    requireConsent: false,  // mặc định thu thập ngay; app cần GDPR thì bật
    anonymousTracking: undefined as unknown as 'session' | 'full',
    crossDomainSession: true,
    batchSize: 10,
    flushIntervalMs: 3000,
    sessionTimeoutMs: 30 * 60 * 1000,
    piiSalt: '',
    tracingAllowlistHosts: [],
    screenStartEvent: 'screen_viewed',
    screenEndEvent: 'screen_exited',
    clickEvent: 'click',
    verboseLogging: true,
  };
}

export const UniTrack = new UniTrackImpl();
export default UniTrack;
