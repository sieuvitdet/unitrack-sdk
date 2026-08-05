// @unitrack/snowplow — Snowplow provider cho React Native UniTrack.
//
// Parity với iOS SnowplowProvider:
//   • 6 built-in convention helper (trackingClickEvent / trackingResultEvent /
//     trackingScreenView / trackingCrash / trackingAPI / trackingSession)
//   • 3 entity auto-attach mỗi event (user_context, core_action,
//     application_context) — SDK tự fill data
//   • Schema URI build từ convention vendor + event name + version
//   • Portal-driven config: igluVendor / defaultVersion / eventNames / entities
//
// Setup:
//   import { SnowplowProvider } from '@unitrack/snowplow';
//   UniTrack.addProvider(new SnowplowProvider({
//     endpoint: 'https://ftracking.fpt.vn',
//     appId: 'fli_rn',
//     igluVendor: 'vn.fpt.ftel.snowplow',
//     defaultVersion: '1-0-0',
//     eventNames: { click: 'event_click', result: 'event_result', ... },
//     entities: {
//       user_context:        'iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0',
//       core_action:         'iglu:vn.fpt.ftel.snowplow/core_action/jsonschema/1-0-0',
//       application_context: 'iglu:vn.fpt.ftel.snowplow/application_context/jsonschema/1-0-0',
//     },
//     userContext: { username: 'demo' },
//   }));

import type { AnalyticsProvider, EventProperties } from '@unitrack/react-native';

/** Convention kinds → matches the 6 built-in helpers on iOS/Android. */
export type ConventionKind =
  | 'click'
  | 'result'
  | 'screen_view'
  | 'crash'
  | 'api'
  | 'session';

/** Snowplow tracker flags — defaults all true (Snowplow's recommended setup). */
export interface SnowplowOptions {
  base64Encoding?: boolean;
  platformContext?: boolean;
  applicationContext?: boolean;
  sessionContext?: boolean;
  screenContext?: boolean;
  lifecycleAutotracking?: boolean;
  screenEngagementAutotracking?: boolean;
  exceptionAutotracking?: boolean;
  installAutotracking?: boolean;
}

export interface SnowplowProviderConfig {
  endpoint: string;
  appId: string;
  namespace?: string;
  /** User context bag — merged with `setUser` traits + emitted via user_context entity. */
  userContext?: Record<string, unknown>;
  /** Iglu vendor + version used to build convention schema URIs. */
  igluVendor?: string;
  defaultVersion?: string;
  /** Convention kind → wire event name override (vd: { click: "event_click" }). */
  eventNames?: Partial<Record<ConventionKind | string, string>>;
  /** Entity name → schema URI. SDK auto-fills data for user_context,
   *  core_action, application_context; other names need extraContexts. */
  entities?: Record<string, string>;
  /** Raw event names to drop before hitting the collector. Portal
   *  `snowplow.drop_events` — used for SDK-emitted lifecycle events
   *  (app_foreground / app_background / …) without matching iglu schemas. */
  dropEvents?: string[];
  /** Snapshot of DeviceInfo (platform, app_version, network_type, …) used to
   *  populate the application_context entity. Pass from the app at init time
   *  (RN doesn't have a `UniTrack.applicationContext()` static helper yet). */
  applicationContext?: Record<string, unknown>;
  options?: SnowplowOptions;
}

const DEFAULT_EVENT_NAMES: Record<ConventionKind, string> = {
  click: 'event_click',
  result: 'event_result',
  screen_view: 'event_screen_view',
  crash: 'event_crash',
  api: 'event_api',
  session: 'event_session',
};

/** Self-describing JSON shape Snowplow tracker accepts. */
interface SDJ {
  schema: string;
  data: Record<string, unknown>;
}

export class SnowplowProvider implements AnalyticsProvider {
  private cfg: SnowplowProviderConfig;
  private tracker: any = null;
  private userContext: Record<string, unknown>;

  constructor(cfg: SnowplowProviderConfig) {
    this.cfg = { namespace: 'UniTrack', ...cfg };
    this.userContext = { ...(cfg.userContext ?? {}) };
  }

  async initialize(): Promise<void> {
    if (!this.cfg.endpoint) {
      console.warn('[unitrack/snowplow] empty endpoint — provider disabled');
      return;
    }
    let sp: any;
    try {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      sp = require('@snowplow/react-native-tracker');
    } catch (e) {
      console.warn(
        '[unitrack/snowplow] @snowplow/react-native-tracker not installed — provider disabled',
      );
      return;
    }
    const o = this.cfg.options ?? {};
    const flag = (v?: boolean) => (v === undefined ? true : v);
    this.tracker = await sp.createTracker(
      this.cfg.namespace,
      { endpoint: this.cfg.endpoint, method: 'post' },
      {
        trackerConfig: {
          appId: this.cfg.appId,
          base64Encoding: flag(o.base64Encoding),
          platformContext: flag(o.platformContext),
          applicationContext: flag(o.applicationContext),
          sessionContext: flag(o.sessionContext),
          screenContext: flag(o.screenContext),
          lifecycleAutotracking: flag(o.lifecycleAutotracking),
          screenEngagementAutotracking: flag(o.screenEngagementAutotracking),
          exceptionAutotracking: flag(o.exceptionAutotracking),
          installAutotracking: flag(o.installAutotracking),
        },
      },
    );
    const vendor = this.cfg.igluVendor ?? '—';
    const ver = this.cfg.defaultVersion ?? '1-0-0';
    const entKeys = Object.keys(this.cfg.entities ?? {}).sort().join(',');
    console.log(
      `[unitrack/snowplow] tracker ready (${this.cfg.endpoint}, appId=${this.cfg.appId}, vendor=${vendor}, version=${ver}, entities=${entKeys})`,
    );
  }

  // ── Hot-reload setters (called by portal config) ────────────────────────

  updateUserContext(ctx: Record<string, unknown>): void {
    this.userContext = { ...ctx };
  }
  setEventNames(map: Record<string, string>): void {
    this.cfg.eventNames = { ...(this.cfg.eventNames ?? {}), ...map };
  }
  setEntities(map: Record<string, string>): void {
    this.cfg.entities = { ...(this.cfg.entities ?? {}), ...map };
  }

  // ── AnalyticsProvider impl ──────────────────────────────────────────────

  setUser(userId: string | null, traits: EventProperties): void {
    this.tracker?.setUserId(userId ?? null);
    if (userId) this.userContext.user_id = userId;
    for (const [k, v] of Object.entries(traits ?? {})) {
      this.userContext[k] = v as unknown;
    }
  }

  setScreen(name: string): void {
    if (!this.tracker) return;
    const ctxs = this.buildEntities(name, name, undefined, undefined, false);
    this.tracker.trackScreenViewEvent({ name }, ctxs);
  }

  /** Generic catch-all that UniTrack core fans events out to. Routes through
   *  the convention path: `name` is the event_action / wire name, schema URI
   *  is built from vendor + (resolved name) + version. Apps SHOULD prefer the
   *  typed tracking* helpers below — they pre-fill action_name + screen +
   *  element_key into the core_action entity. */
  track(name: string, properties: EventProperties): void {
    // Portal-configured blocklist — drop before URL build so events without
    // a published iglu schema (app_foreground, app_background, …) don't
    // turn into bad rows at the enricher.
    if (this.cfg.dropEvents?.includes(name)) return;
    const schema = this.schemaFor(name);
    if (!schema) return;
    this.trackSelfDescribing(
      schema,
      name,
      properties as Record<string, unknown>,
      undefined,
      false,
    );
  }

  // ── Convention helpers (parity with iOS) ────────────────────────────────

  trackingClickEvent(opts: {
    elementKey?: string;
    label?: string;
    screen?: string;
    data?: Record<string, unknown>;
    extraContexts?: SDJ[];
  }): void {
    const data: Record<string, unknown> = { ...(opts.data ?? {}) };
    if (opts.elementKey) data.element_key = opts.elementKey;
    if (opts.label) data.label = opts.label;
    if (opts.screen) data.screen = opts.screen;
    const name = this.resolveEventName('click', DEFAULT_EVENT_NAMES.click);
    const schema = this.buildSchemaURI(name);
    this.trackSelfDescribing(schema, name, data, opts.extraContexts, false);
  }

  trackingResultEvent(opts: {
    action: string;
    status: 'success' | 'fail' | string;
    errorCode?: string;
    data?: Record<string, unknown>;
    extraContexts?: SDJ[];
  }): void {
    const data: Record<string, unknown> = {
      action: opts.action,
      status: opts.status,
      ...(opts.data ?? {}),
    };
    if (opts.errorCode) data.error_code = opts.errorCode;
    const name = this.resolveEventName('result', DEFAULT_EVENT_NAMES.result);
    const schema = this.buildSchemaURI(name);
    this.trackSelfDescribing(schema, name, data, opts.extraContexts, false);
  }

  trackingScreenView(opts: {
    screenName: string;
    fromScreen?: string;
    data?: Record<string, unknown>;
    extraContexts?: SDJ[];
  }): void {
    const data: Record<string, unknown> = {
      screen_name: opts.screenName,
      ...(opts.data ?? {}),
    };
    if (opts.fromScreen) data.from_screen = opts.fromScreen;
    const name = this.resolveEventName('screen_view', DEFAULT_EVENT_NAMES.screen_view);
    const schema = this.buildSchemaURI(name);
    this.trackSelfDescribing(schema, name, data, opts.extraContexts, false);
  }

  trackingCrash(opts: {
    message: string;
    fatal: boolean;
    type?: string;
    stack?: string;
    extraContexts?: SDJ[];
  }): void {
    const data: Record<string, unknown> = {
      message: opts.message,
      is_fatal: opts.fatal,
    };
    if (opts.type) data.exception_name = opts.type;
    if (opts.stack) data.stack = opts.stack;
    const name = this.resolveEventName('crash', DEFAULT_EVENT_NAMES.crash);
    const schema = this.buildSchemaURI(name);
    this.trackSelfDescribing(schema, name, data, opts.extraContexts, false);
  }

  trackingAPI(opts: {
    url: string;
    method: string;
    status: number;
    durationMs: number;
    data?: Record<string, unknown>;
    extraContexts?: SDJ[];
  }): void {
    const data: Record<string, unknown> = {
      url: opts.url,
      method: opts.method,
      status: opts.status,
      duration_ms: opts.durationMs,
      ...(opts.data ?? {}),
    };
    const name = this.resolveEventName('api', DEFAULT_EVENT_NAMES.api);
    const schema = this.buildSchemaURI(name);
    this.trackSelfDescribing(schema, name, data, opts.extraContexts, false);
  }

  trackingSession(opts: {
    action: 'session_started' | 'session_ended' | string;
    data?: Record<string, unknown>;
    extraContexts?: SDJ[];
  }): void {
    const data: Record<string, unknown> = {
      event_action: opts.action,
      ...(opts.data ?? {}),
    };
    const name = this.resolveEventName('session', DEFAULT_EVENT_NAMES.session);
    const schema = this.buildSchemaURI(name);
    this.trackSelfDescribing(schema, name, data, opts.extraContexts, false);
  }

  /** Custom self-describing event with manual schema URI override. */
  trackingCustomEvent(
    eventName: string,
    data: Record<string, unknown>,
    extraContexts?: SDJ[],
  ): void {
    const schema = this.buildSchemaURI(eventName);
    this.trackSelfDescribing(schema, eventName, data, extraContexts, false);
  }

  // ── Internals ───────────────────────────────────────────────────────────

  /** Build the schema URI for a wire event name. Convention vendor + version
   *  come from portal config; fall back to a warn + null URI when vendor
   *  missing (event dropped). */
  private schemaFor(eventName: string): string | null {
    if (!this.cfg.igluVendor) {
      console.warn(
        `[unitrack/snowplow] no iglu_vendor in portal config — "${eventName}" dropped. Set snowplow.iglu_vendor in the portal Config tab.`,
      );
      return null;
    }
    return this.buildSchemaURI(eventName);
  }

  private buildSchemaURI(eventName: string): string {
    const vendor = this.cfg.igluVendor ?? 'unknown';
    const ver = this.cfg.defaultVersion ?? '1-0-0';
    return `iglu:${vendor}/${eventName}/jsonschema/${ver}`;
  }

  /** Resolve convention kind → wire event name. Portal-supplied value wins;
   *  fallback to the SDK default. */
  private resolveEventName(kind: ConventionKind, fallback: string): string {
    const fromPortal = this.cfg.eventNames?.[kind];
    return fromPortal && fromPortal.length > 0 ? fromPortal : fallback;
  }

  /** Normalize an entity URI. Accepts:
   *   • full URI (iglu:.../foo/jsonschema/1-0-0) → unchanged
   *   • short name ("user_context") → iglu:<vendor>/user_context/jsonschema/<ver>
   *   • partial (vendor/foo/jsonschema/ver) → prefixed with iglu:
   *  Returns null when the input is empty (entity disabled by operator). */
  private normalizeEntityURI(input: string): string | null {
    if (!input || input.length === 0) return null;
    if (input.startsWith('iglu:')) return input;
    if (input.includes('/jsonschema/')) return `iglu:${input}`;
    // Short name → use convention vendor + default version.
    return this.buildSchemaURI(input);
  }

  /** Build the entity list attached to one event:
   *   1. user_context        — from userContext bag
   *   2. core_action         — from event meta
   *   3. application_context — from cfg.applicationContext snapshot
   *   4. extraContexts       — anything the caller passed (campaign, …) */
  private buildEntities(
    eventName: string,
    screen: string | undefined,
    elementKey: string | undefined,
    extra: SDJ[] | undefined,
    skipGlobalContexts: boolean,
  ): SDJ[] {
    const out: SDJ[] = [];
    if (!skipGlobalContexts) {
      const entMap = this.cfg.entities ?? {};
      const userSchema = entMap.user_context && this.normalizeEntityURI(entMap.user_context);
      if (userSchema && Object.keys(this.userContext).length > 0) {
        out.push({ schema: userSchema, data: this.userContext });
      }
      const coreSchema = entMap.core_action && this.normalizeEntityURI(entMap.core_action);
      if (coreSchema) {
        const now = new Date().toISOString();
        const data: Record<string, unknown> = {
          action_name: eventName,
          timestamp: now,
          start_time: now,
        };
        if (screen) data.screen = screen;
        if (elementKey) data.element_key = elementKey;
        out.push({ schema: coreSchema, data });
      }
      const appSchema = entMap.application_context && this.normalizeEntityURI(entMap.application_context);
      const appBag = this.cfg.applicationContext;
      if (appSchema && appBag && Object.keys(appBag).length > 0) {
        out.push({ schema: appSchema, data: appBag });
      }
    }
    if (extra && extra.length > 0) out.push(...extra);
    return out;
  }

  /** Fire one self-describing event under `schema` with the configured
   *  auto-entities + caller's extras. */
  private trackSelfDescribing(
    schema: string,
    eventName: string,
    data: Record<string, unknown>,
    extraContexts: SDJ[] | undefined,
    skipGlobalContexts: boolean,
  ): void {
    const t = this.tracker;
    if (!t) {
      console.warn(`[unitrack/snowplow] SKIP "${eventName}" — tracker not initialized`);
      return;
    }
    // Strip internal _-prefixed keys (vd: _skip_firebase markers from the
    // bridge layer that don't belong on the wire).
    const cleaned: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(data)) {
      if (!k.startsWith('_')) cleaned[k] = v;
    }
    const screen = (cleaned.screen ?? cleaned.screen_name) as string | undefined;
    const elementKey = (cleaned.element_key ?? cleaned.element) as string | undefined;
    const ctxs = this.buildEntities(eventName, screen, elementKey, extraContexts, skipGlobalContexts);
    t.trackSelfDescribingEvent({ schema, data: cleaned }, ctxs);
  }
}
