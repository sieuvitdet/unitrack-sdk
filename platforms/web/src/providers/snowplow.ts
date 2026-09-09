// Lightweight Snowplow provider — gửi self-describing event tới collector
// qua `/com.snowplowanalytics.snowplow/tp2` endpoint. Không depend
// `@snowplow/browser-tracker` để giảm bundle size — chỉ 1 fetch POST đơn
// giản.
//
// Port pattern từ Flutter `unitrack_snowplow` + iOS SnowplowProvider:
// - kind mapping (click → ev_click, screen_viewed → ev_screen,…)
// - Iglu schema URI build: iglu:<vendor>/<name>/jsonschema/<ver>
// - Self-describing JSON event với entity user_context + application_context

import type { AnalyticsProvider, EventName, EventProperties } from '../types';

const PAYLOAD_DATA_SCHEMA = 'iglu:com.snowplowanalytics.snowplow/payload_data/jsonschema/1-0-4';

export interface SnowplowProviderConfig {
  endpoint: string;                       // vd https://ftracking.fpt.vn
  appId: string;
  igluVendor: string;                     // vd vn.fpt.ftel.snowplow
  defaultVersion?: string;                // default '1-0-0'
  /** Map convention kind → Snowplow schema name. Default: kind mặc định SDK. */
  eventNames?: Record<string, string>;
  /** Entity nào được đăng ký. Key = tên ngắn, value = tên ngắn hoặc URI đầy đủ.
   *  Chỉ entity có trong map này mới được gắn — parity iOS SnowplowProvider. */
  entities?: Record<string, string>;
  /** Event bị chặn không gửi lên Snowplow (parity `drop_events` bên native). */
  dropEvents?: string[];
  /** Kind cho từng event nghiệp vụ, khi tên nó không nằm trong bảng mapKind.
   *  Vd `{ add_to_cart: 'result', purchase: 'result' }`.
   *
   *  Mobile phân loại theo NGỮ NGHĨA từng event chứ không dùng một giá trị
   *  chung (đo portal project 8): camera_stream_started → ev_click, còn
   *  camera_stream_ended / camera_playback_ended → ev_result. Map này cho web
   *  làm được điều tương tự mà không phải sửa code. */
  businessEventKinds?: Record<string, string>;
  /** Kind mặc định cho event nghiệp vụ không có trong `businessEventKinds`.
   *  Default 'click'. */
  businessKind?: string;
  /** Event được phép có schema iglu MANG CHÍNH TÊN NÓ, vì đội Data đã publish
   *  schema đó lên registry. Vd FPT Life có `app_background`/`app_foreground`
   *  (đo trên portal project 8). Tên không nằm trong danh sách này và không có
   *  kind sẽ đi theo `businessKind` — không bao giờ tự chế schema mới. */
  ownSchemaEvents?: string[];
  /** Stamp các entity context vào mọi event. */
  userContext?: EventProperties;
  base64Encoding?: boolean;
  /** Chu kỳ flush buffer (ms). Default 3000. */
  flushIntervalMs?: number;
  /** Số event tối đa mỗi POST. Default 10. */
  batchSize?: number;
  /** In payload Snowplow ra console để debug bằng F12. */
  verboseLogging?: boolean;
}

export class SnowplowProvider implements AnalyticsProvider {
  readonly name = 'SnowplowProvider';
  private buffer: any[] = [];
  private flushTimer: ReturnType<typeof setInterval> | null = null;
  private userId: string | null = null;
  private userTraits: EventProperties = {};

  constructor(private cfg: SnowplowProviderConfig) {}

  init(): void {
    Object.assign(this.userTraits, this.cfg.userContext || {});
    this.flushTimer = setInterval(() => this.flush(), this.cfg.flushIntervalMs ?? 3000);
    window.addEventListener('pagehide', () => this.flushBeacon());
    window.addEventListener('online', () => this.flush());
  }

  setUser(userId: string | null, traits: EventProperties): void {
    this.userId = userId;
    this.userTraits = { ...(traits || {}) };
  }

  track(name: EventName, props: EventProperties): void {
    if (this.cfg.dropEvents?.includes(name)) return;

    // Parity iOS/Android: raw name → kind → schema name.
    //   kind quyết định nhóm schema, eventNames[kind] cho phép portal đổi tên.
    //
    // Event nghiệp vụ (add_to_cart, purchase, product_viewed…) KHÔNG có kind.
    // Trước đây nhánh này lấy thẳng raw name làm schema → sinh
    // `iglu:<vendor>/add_to_cart/jsonschema/1-0-0`, mà Iglu registry không hề
    // có schema đó → enricher trả ResolutionError và toàn bộ event thành bad
    // row. Đo trên portal project 8: mobile chỉ dùng ĐÚNG 6 schema, mọi event
    // nghiệp vụ (camera_stream_started, camera_playback_ended…) đều đi qua một
    // trong 6, tên nghiệp vụ nằm ở `event_action`.
    //
    // Web dùng track() generic nên không tự biết event thuộc nhóm nào; định
    // tuyến về `businessKind` (mặc định 'click' — nhóm hành vi người dùng) và
    // để đội Data pivot theo event_action như họ vẫn làm với mobile.
    // Event đã được đội Data publish schema riêng → dùng chính tên nó.
    // Danh sách này do portal khai, KHÔNG suy từ tên event.
    const hasOwnSchema = this.cfg.ownSchemaEvents?.includes(name) === true;
    // Thứ tự quyết định kind:
    //   1. `_kind` do CALLER truyền — tương đương việc mobile gọi thẳng
    //      trackingResultEvent()/trackingClickEvent(). Kind nằm ở chỗ gắn
    //      tracking trong code, không phải ở file config.
    //   2. bảng mapKind — event auto-capture của SDK.
    //   3. businessEventKinds — lối thoát cho app KHÔNG sửa được chỗ gọi
    //      (event bắn từ thư viện bên thứ ba, hoặc muốn đổi phân loại mà
    //      không build lại app).
    //   4. businessKind mặc định.
    const kind = hasOwnSchema
      ? ''
      : ((props._kind as string | undefined)
         ?? this.mapKind(name)
         ?? this.cfg.businessEventKinds?.[name]
         ?? this.cfg.businessKind
         ?? 'click');
    const schemaName = hasOwnSchema
      ? name
      : (this.cfg.eventNames?.[kind] ?? this.defaultEventName(kind, name));
    const schema = `iglu:${this.cfg.igluVendor}/${schemaName}/jsonschema/${this.cfg.defaultVersion || '1-0-0'}`;

    const enriched: EventProperties = { ...props };
    // `_kind` đã bị track() xoá trước khi fan-out; xoá lại ở đây để provider
    // dùng trực tiếp (không qua track()) cũng không rò field nội bộ.
    delete enriched._kind;
    // track() đã gắn event_action trước khi fan-out; giữ lại đây làm chốt
    // chặn cho ai gọi provider trực tiếp, không qua track().
    if (enriched.event_action == null) enriched.event_action = name;
    const sid = (props.session_id as string) || '';
    if (enriched.session_id == null && sid) enriched.session_id = sid;

    // Field theo convention của từng kind — parity iOS (SnowplowProvider.swift
    // trackingSession/trackingResult/trackingAPI). Ba schema này dùng chung cho
    // nhiều event khác nhau, nên `action`/`status` là thứ đội Data pivot; thiếu
    // chúng thì query mobile áp lên web trả rỗng.
    if (kind === 'session' || kind === 'result') {
      // `action` = tên hành vi. Mobile gửi song song với event_action.
      if (enriched.action == null) enriched.action = name;
    }
    if (kind === 'api') {
      // Mobile gọi field này là `status`, web trước đây gửi `status_code`.
      // Giữ cả hai: đổi tên thẳng sẽ phá consumer nào đang đọc status_code.
      if (enriched.status == null && enriched.status_code != null) {
        enriched.status = enriched.status_code;
      }
    }
    if (kind === 'result' && enriched.status == null) enriched.status = 'success';

    const ue_pr = {
      schema: 'iglu:com.snowplowanalytics.snowplow/unstruct_event/jsonschema/1-0-0',
      data: { schema, data: enriched },
    };

    const contexts: any[] = [];
    // user_context — LUÔN gắn khi portal đăng ký entity, kể cả lúc chưa login.
    //
    // Trước đây entity này bị bỏ hẳn nếu chưa có user, nên hàng dữ liệu của
    // khách vãng lai KHÁC cấu trúc hàng của người đã đăng nhập: đội Data phải
    // xử lý hai dạng, và không phân biệt được "chưa login" với "SDK quên gắn
    // entity". Gửi field rỗng thì cấu trúc đồng nhất, và chuỗi rỗng đọc rõ là
    // "chưa đăng nhập".
    const userSchema = this.entityURI('user_context');
    if (userSchema) {
      contexts.push({
        schema: userSchema,
        data: stringifyAll({
          ...this.userTraits,
          // Ba field này luôn có mặt, kể cả rỗng — đặt SAU spread để trait
          // không xoá được chúng, và `??` để trait vẫn ghi đè khi có giá trị.
          // Đúng bộ field user_context của mobile (đo trên portal project 8:
          // user_id / user_name / phone_number, cả ba đều 1080/1080).
          user_id:      this.userId ?? '',
          user_name:    this.userTraits.user_name ?? '',
          phone_number: this.userTraits.phone_number ?? '',
        }),
      });
    }
    // core_action — entity mà đội Data pivot theo action_name/session_id.
    // Trước đây web KHÔNG gửi entity này, nên mọi query mobile đều hụt web.
    const coreSchema = this.entityURI('core_action');
    if (coreSchema) {
      const now = new Date().toISOString();
      const data: Record<string, unknown> = {
        action_name: name,        // raw name, KHÔNG phải kind — parity iOS
        timestamp: now,
        start_time: now,
        is_headless: 'false',     // web luôn có UI
      };
      if (props.screen) data.screen = props.screen;
      if (props.element_key) data.element_key = props.element_key;
      if (sid) data.session_id = sid;
      contexts.push({ schema: coreSchema, data: stringifyAll(data) });
    }
    const appSchema = this.entityURI('application_context');
    if (appSchema) {
      contexts.push({
        schema: appSchema,
        data: stringifyAll({
          app_id: this.cfg.appId,
          platform: 'web',
          user_agent: navigator.userAgent,
          screen_resolution: `${screen.width}x${screen.height}`,
          viewport: `${window.innerWidth}x${window.innerHeight}`,
          language: navigator.language,
          referrer: document.referrer,
        }),
      });
    }

    const payload: Record<string, string> = {
      e: 'ue',                            // unstruct event
      eid: this.uuid(),
      dtm: String(Date.now()),
      tv: 'js-unitrack-0.1',
      p: 'web',
      aid: this.cfg.appId,
      tna: 'unitrack',
      url: window.location.href,
      page: document.title,
      ue_pr: JSON.stringify(ue_pr),
    };
    if (contexts.length) {
      payload.co = JSON.stringify({
        schema: 'iglu:com.snowplowanalytics.snowplow/contexts/jsonschema/1-0-1',
        data: contexts,
      });
    }

    if (this.cfg.verboseLogging) {
      // In ra dạng đã parse (không phải chuỗi JSON lồng) để mở xem trực tiếp
      // trên F12 — ue_pr/co trong payload thật là string, đọc bằng mắt không nổi.
      console.groupCollapsed(`%c[UniTrack→Snowplow]%c ${name} → ${schemaName}`,
        'color:#7c3aed;font-weight:bold', 'color:inherit');
      console.log('schema  :', schema);
      console.log('event   :', ue_pr.data.data);
      console.log('entities:', contexts.map((c) => ({ schema: c.schema, data: c.data })));
      console.log('payload :', payload);
      console.groupEnd();
    }

    this.buffer.push(payload);
    // batchSize từ portal, không hardcode: config đặt 5 mà provider vẫn chờ
    // đủ 10 thì event lẻ phải đợi hết nhịp setInterval mới đi.
    if (this.buffer.length >= (this.cfg.batchSize ?? 10)) this.flush();
  }

  /** Tên ngắn hoặc URI đầy đủ → URI iglu. Parity `normalizeEntityURI` bên iOS.
   *  Trả null khi portal không đăng ký entity đó. */
  private entityURI(name: string): string | null {
    const raw = this.cfg.entities?.[name];
    if (!raw) return null;
    const s = raw.trim();
    if (!s) return null;
    if (s.startsWith('iglu:')) return s;
    if (s.includes('/')) return `iglu:${s}`;
    if (!this.cfg.igluVendor) return null;
    return `iglu:${this.cfg.igluVendor}/${s}/jsonschema/${this.cfg.defaultVersion || '1-0-0'}`;
  }

  /** Tên schema mặc định cho từng kind khi portal không override.
   *  Parity `defaultEventNameFor` bên iOS. */
  private defaultEventName(kind: string, _raw: string): string {
    switch (kind) {
      case 'click':       return 'event_click';
      case 'result':      return 'event_result';
      case 'screen_view': return 'event_screen_view';
      case 'screen_end':  return 'screen_end';
      case 'crash':       return 'event_crash';
      case 'api':         return 'event_api';
      case 'session':     return 'event_session';
      // Không bao giờ tới đây: mọi kind đều nằm trong 7 nhánh trên, và event
      // không có kind đã được định tuyến về businessKind ở track(). Giữ
      // 'event_click' làm chốt chặn thay vì `raw` để một kind mới thêm sai
      // cũng không sinh được schema lạ.
      default:            return 'event_click';
    }
  }

  /** Parity `kindForRawEvent` bên iOS — nhiều raw name gộp về 1 schema parent.
   *  Trả `null` khi không nhận ra: đó là event nghiệp vụ do app tự đặt tên,
   *  KHÔNG được suy ra schema từ tên nó. */
  private mapKind(name: string): string | null {
    switch (name) {
      case 'click':
      case 'tap':
        return 'click';
      // screen_exited có schema RIÊNG (screen_end) vì mang dwell_ms,
      // foreground_sec — gộp chung với screen_view làm hỏng schema bên mobile.
      case 'screen_exited':
        return 'screen_end';
      case 'screen_viewed':
      case 'screen_view':
        return 'screen_view';
      case 'network_request':
      case 'network_error':
        return 'api';
      case 'crash':
      case 'application_error':
        return 'crash';
      case 'session_started':
      case 'session_ended':
      case 'session_start':
      case 'session_end':
        return 'session';
      default:
        return null;
    }
  }

  async flush(): Promise<void> {
    if (!this.buffer.length || !navigator.onLine) return;
    const batch = this.buffer.splice(0, this.buffer.length);
    if (this.cfg.verboseLogging) {
      console.log(`%c[UniTrack→Snowplow] POST ${batch.length} event`,
        'color:#0891b2;font-weight:bold', { schema: PAYLOAD_DATA_SCHEMA, data: batch });
    }
    try {
      await fetch(`${this.cfg.endpoint}/com.snowplowanalytics.snowplow/tp2`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          schema: PAYLOAD_DATA_SCHEMA,
          data: batch,
        }),
      });
    } catch {
      // Retry: đẩy lại buffer.
      this.buffer.unshift(...batch);
    }
  }

  flushBeacon(): void {
    if (!this.buffer.length) return;
    if (typeof navigator.sendBeacon !== 'function') return;
    const batch = this.buffer.splice(0, this.buffer.length);
    try {
      const body = JSON.stringify({
        schema: PAYLOAD_DATA_SCHEMA,
        data: batch,
      });
      navigator.sendBeacon(
        `${this.cfg.endpoint}/com.snowplowanalytics.snowplow/tp2`,
        new Blob([body], { type: 'application/json' }),
      );
    } catch {
      this.buffer.unshift(...batch);
    }
  }

  private uuid(): string {
    if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) {
      return crypto.randomUUID();
    }
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      const v = c === 'x' ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    });
  }

  destroy(): void {
    if (this.flushTimer) clearInterval(this.flushTimer);
  }
}

/** Ép mọi value về string — schema Iglu của FPT khai field kiểu string,
 *  number/bool lọt qua sẽ thành schema violation. Parity `stringifyAll` iOS. */
function stringifyAll(o: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(o)) {
    if (v == null) continue;
    out[k] = typeof v === 'string' ? v : JSON.stringify(v);
  }
  return out;
}
