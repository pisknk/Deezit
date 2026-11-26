// Deezer's own icons, used for every Deezit icon.
//
// They come from the Tempo design system's asset catalog inside the app
// (Tempo_Tempo.bundle/Assets.car): 258 vector icons named "<name>.small"
// (16 pt) and "<name>.medium" (24 pt), e.g. "heart.medium",
// "microphoneMusicFill.small". They are loaded from Deezer's bundle at
// runtime and never copied into Deezit.

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// The Tempo icon `name` at Tempo's size `size` ("small" or "medium"), as a
// template image. Nil when the app doesn't have it.
UIImage *DZTempoImage(NSString *name, NSString *size);

// Deezer's icon `name` as a template image, `point` tall: "small" for 16 pt
// or less, otherwise "medium", redrawn when `point` is neither. 0 means
// "medium" as it is (24 pt). If the app has no such icon, the SF Symbol
// `fallback` is used instead (nil fallback: nil).
UIImage *DZIcon(NSString *name, NSString *fallback, CGFloat point);

#ifdef __cplusplus
}
#endif
