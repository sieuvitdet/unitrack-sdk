// UniTrackPlugin.m — Flutter iOS plugin.
//
// Forwards MethodChannel calls to the iOS UniTrack Swift SDK.

#import <Flutter/Flutter.h>
@import UniTrack;

@interface UniTrackPlugin : NSObject <FlutterPlugin>
@end

@implementation UniTrackPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *ch =
        [FlutterMethodChannel methodChannelWithName:@"unitrack"
                                    binaryMessenger:[registrar messenger]];
    UniTrackPlugin *instance = [[UniTrackPlugin alloc] init];
    [registrar addMethodCallDelegate:instance channel:ch];
}

static NSDictionary *dictFromJson(NSString *json) {
    if (!json) return @{};
    NSError *e = nil;
    id obj = [NSJSONSerialization
              JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
              options:0 error:&e];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSDictionary *args = call.arguments;

    if ([@"initialize" isEqualToString:call.method]) {
        NSString *apiKey  = args[@"apiKey"];
        NSDictionary *c   = dictFromJson(args[@"config"]);
        UniTrackConfig *cfg = [[UniTrackConfig alloc] init];
        if (c[@"endpoint"])        cfg.endpoint        = c[@"endpoint"];
        if (c[@"batchSize"])       cfg.batchSize       = [c[@"batchSize"] intValue];
        if (c[@"flushIntervalMs"]) cfg.flushIntervalMs = [c[@"flushIntervalMs"] intValue];
        if (c[@"samplingRate"])    cfg.samplingRate    = [c[@"samplingRate"] doubleValue];
        if (c[@"autoCapture"])     cfg.autoCapture     = [c[@"autoCapture"] boolValue];
        [UniTrack initializeWithApiKey:apiKey config:cfg];
        result(nil);
    }
    else if ([@"identify" isEqualToString:call.method]) {
        [UniTrack identifyWithUserId:args[@"userId"]
                              traits:dictFromJson(args[@"traits"])];
        result(nil);
    }
    else if ([@"reset" isEqualToString:call.method]) {
        [UniTrack reset];
        result(nil);
    }
    else if ([@"track" isEqualToString:call.method]) {
        [UniTrack track:args[@"event"]
             properties:dictFromJson(args[@"props"])];
        result(nil);
    }
    else if ([@"setScreen" isEqualToString:call.method]) {
        [UniTrack setScreen:args[@"name"]];
        result(nil);
    }
    else if ([@"flush" isEqualToString:call.method]) {
        [UniTrack flush];
        result(nil);
    }
    else if ([@"setEnabled" isEqualToString:call.method]) {
        [UniTrack setEnabled:[args[@"enabled"] boolValue]];
        result(nil);
    }
    else {
        result(FlutterMethodNotImplemented);
    }
}

@end
