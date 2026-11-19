#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DZPreset : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, readonly) float speed;
@property (nonatomic, readonly) float reverbMix;
@property (nonatomic, readonly) float reverbRoom;
@property (nonatomic, readonly) float reverbDamp;
@end

NSArray<DZPreset *> *DZAllPresets(void);
DZPreset * _Nullable DZPresetWithIdentifier(NSString *identifier);
// Applies the preset's values (and enables the effect unless it is "off").
void DZApplyPreset(DZPreset *preset);

NS_ASSUME_NONNULL_END
