#import "DZPresets.h"
#import "DZPrefs.h"

@interface DZPreset ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, readwrite) float speed, reverbMix, reverbRoom, reverbDamp;
@end

@implementation DZPreset
+ (instancetype)id:(NSString *)i title:(NSString *)t speed:(float)s mix:(float)m room:(float)r damp:(float)d {
    DZPreset *p = [self new];
    p.identifier = i; p.title = t; p.speed = s; p.reverbMix = m; p.reverbRoom = r; p.reverbDamp = d;
    return p;
}
@end

NSArray<DZPreset *> *DZAllPresets(void) {
    static NSArray *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        all = @[
            [DZPreset id:@"off"           title:@"Off"             speed:1.00f mix:0.00f room:0.75f damp:0.40f],
            [DZPreset id:@"slowed"        title:@"Slowed"          speed:0.85f mix:0.10f room:0.60f damp:0.50f],
            [DZPreset id:@"slowed_reverb" title:@"Slowed + Reverb" speed:0.80f mix:0.35f room:0.82f damp:0.45f],
            [DZPreset id:@"dreamy"        title:@"Dreamy"          speed:0.75f mix:0.55f room:0.92f damp:0.35f],
            [DZPreset id:@"sped_up"       title:@"Sped Up"         speed:1.20f mix:0.00f room:0.60f damp:0.50f],
            [DZPreset id:@"nightcore"     title:@"Nightcore"       speed:1.30f mix:0.08f room:0.50f damp:0.60f],
        ];
    });
    return all;
}

DZPreset *DZPresetWithIdentifier(NSString *identifier) {
    for (DZPreset *p in DZAllPresets()) {
        if ([p.identifier isEqualToString:identifier]) return p;
    }
    return nil;
}

void DZApplyPreset(DZPreset *p) {
    DZPrefSetMany(@{
        kDZPreset: p.identifier,
        kDZSpeed: @(p.speed),
        kDZReverbMix: @(p.reverbMix),
        kDZReverbRoom: @(p.reverbRoom),
        kDZReverbDamp: @(p.reverbDamp),
        kDZEnabled: @(![p.identifier isEqualToString:@"off"]),
    });
}
