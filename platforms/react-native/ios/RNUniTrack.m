// RNUniTrack.m — React Native iOS native module bridge.
//
// Forwards JS calls to the iOS UniTrack Swift SDK linked alongside.

#import <React/RCTBridgeModule.h>
@import UniTrack;

@interface RNUniTrack : NSObject <RCTBridgeModule>
@end

@implementation RNUniTrack

RCT_EXPORT_MODULE(UniTrack);

+ (BOOL)requiresMainQueueSetup { return NO; }

static NSDictionary *parseJson(NSString *json) {
    if (!json || json.length == 0) return @{};
    NSError *e = nil;
    id obj = [NSJSONSerialization
              JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
              options:0 error:&e];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
}

RCT_EXPORT_METHOD(initialize:(NSString *)apiKey
                  config:(NSString *)configJson
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    NSDictionary *c = parseJson(configJson);
    UniTrackConfig *cfg = [[UniTrackConfig alloc] init];
    if (c[@"endpoint"])        cfg.endpoint        = c[@"endpoint"];
    if (c[@"batchSize"])       cfg.batchSize       = [c[@"batchSize"] intValue];
    if (c[@"flushIntervalMs"]) cfg.flushIntervalMs = [c[@"flushIntervalMs"] intValue];
    if (c[@"samplingRate"])    cfg.samplingRate    = [c[@"samplingRate"] doubleValue];
    if (c[@"autoCapture"])     cfg.autoCapture     = [c[@"autoCapture"] boolValue];

    [UniTrack initializeWithApiKey:apiKey config:cfg];
    resolve(nil);
}

RCT_EXPORT_METHOD(identify:(NSString *)userId
                  traits:(NSString *)traitsJson
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    [UniTrack identifyWithUserId:userId traits:parseJson(traitsJson)];
    resolve(nil);
}

RCT_EXPORT_METHOD(reset:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    [UniTrack reset];
    resolve(nil);
}

RCT_EXPORT_METHOD(track:(NSString *)event
                  props:(NSString *)propsJson
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    [UniTrack track:event properties:parseJson(propsJson)];
    resolve(nil);
}

RCT_EXPORT_METHOD(setScreen:(NSString *)name
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    [UniTrack setScreen:name];
    resolve(nil);
}

RCT_EXPORT_METHOD(flush:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    [UniTrack flush];
    resolve(nil);
}

RCT_EXPORT_METHOD(setEnabled:(BOOL)enabled
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    [UniTrack setEnabled:enabled];
    resolve(nil);
}

@end
