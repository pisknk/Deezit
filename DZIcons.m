#import "DZIcons.h"
#import "DZLog.h"

static NSBundle *tempoBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSBundle.mainBundle URLForResource:@"Tempo_Tempo" withExtension:@"bundle"];
        bundle = url ? [NSBundle bundleWithURL:url] : nil;
        DZLog("icons: %@", bundle ? @"Deezer's Tempo set" : @"Tempo_Tempo.bundle not found, SF Symbols instead");
    });
    return bundle;
}

UIImage *DZTempoImage(NSString *name, NSString *size) {
    NSBundle *b = tempoBundle();
    if (!b || !name.length) return nil;
    UIImage *img = [UIImage imageNamed:[NSString stringWithFormat:@"%@.%@", name, size] inBundle:b compatibleWithTraitCollection:nil];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIImage *resized(UIImage *img, CGFloat point) {
    CGSize s = img.size;
    if (s.height < 1 || fabs(s.height - point) < 0.5) return img;
    CGSize to = CGSizeMake(round(s.width * point / s.height), point);
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:to format:[UIGraphicsImageRendererFormat preferredFormat]];
    UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:(CGRect){CGPointZero, to}];
    }];
    return [out imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

UIImage *DZIcon(NSString *name, NSString *fallback, CGFloat point) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *key = [NSString stringWithFormat:@"%@|%@|%g", name, fallback, point];
    UIImage *img = [cache objectForKey:key];
    if (img) return img;
    img = DZTempoImage(name, point > 0 && point <= 16 ? @"small" : @"medium");
    if (img && point > 0) img = resized(img, point);
    if (!img && fallback.length) {
        // an SF Symbol's point size is about 3/4 of the box Tempo draws in
        img = point > 0 ? [UIImage systemImageNamed:fallback
                                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:round(point * 0.75)
                                                                                                    weight:UIImageSymbolWeightRegular]]
                        : [UIImage systemImageNamed:fallback];
    }
    if (img) [cache setObject:img forKey:key];
    return img;
}
