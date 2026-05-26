// @unitrack/snowplow — forwards every UniTrack event to a Snowplow collector.
//
//   import { SnowplowProvider } from '@unitrack/snowplow';
//   UniTrack.addProvider(new SnowplowProvider({
//     endpoint: 'https://collector.example.com',
//     appId: '701',
//     userContext: { username: 'duc' },
//     userContextSchema: 'iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0',
//     schemas: { add_to_cart: 'iglu:com.acme/add_to_cart/jsonschema/1-0-0' },
//   }));
//   await UniTrack.initialize(apiKey);
//
// Events with a matching `schemas` entry → self-describing; others →
// Structured (category 'unitrack'). Optional user-context entity is attached.

import type { AnalyticsProvider, EventProperties } from '@unitrack/react-native';

/** Snowplow tracker flags the developer can toggle (defaults all true). */
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
  userContext?: Record<string, unknown>;
  userContextSchema?: string;
  schemas?: Record<string, string>;
  options?: SnowplowOptions;
}

export class SnowplowProvider implements AnalyticsProvider {
  private cfg: SnowplowProviderConfig;
  private tracker: any = null;

  constructor(cfg: SnowplowProviderConfig) {
    this.cfg = { namespace: 'UniTrack', schemas: {}, ...cfg };
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
      console.warn('[unitrack/snowplow] @snowplow/react-native-tracker not installed');
      return;
    }
    // Developer-supplied flags; default each to true (Snowplow's recommended setup).
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
    console.log(`[unitrack/snowplow] tracker ready (${this.cfg.endpoint})`);
  }

  private contexts() {
    const { userContext, userContextSchema } = this.cfg;
    if (!userContext || !userContextSchema) return [];
    return [{ schema: userContextSchema, data: userContext }];
  }

  track(name: string, properties: EventProperties): void {
    const t = this.tracker;
    if (!t) return;
    const schema = this.cfg.schemas?.[name];
    if (schema) {
      t.trackSelfDescribingEvent({ schema, data: properties }, this.contexts());
    } else {
      t.trackStructuredEvent(
        {
          category: 'unitrack',
          action: name,
          label: (properties.screen ?? properties.screen_name) as string | undefined,
          property: (properties.element_key ?? properties.state) as string | undefined,
        },
        this.contexts(),
      );
    }
  }

  setUser(userId: string | null, traits: EventProperties): void {
    this.tracker?.setUserId(userId ?? null);
    if (Object.keys(traits).length && this.cfg.userContext) {
      this.cfg.userContext = { ...this.cfg.userContext, ...traits };
    }
  }

  setScreen(name: string): void {
    this.tracker?.trackScreenViewEvent({ name }, this.contexts());
  }
}
