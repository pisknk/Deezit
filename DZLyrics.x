// The lyrics screen (Deezer.LyricsViewController): a Karaoke Mode button, and
// the line being sung lit up word by word.
//
// Found in Deezer 11.27.0:
//   - Deezer.LyricsViewController has ObjC-visible sharingButton (bottom
//     right) and lyricsCollectionView; its cells (Deezer.LyricsCollectionViewCell)
//     have lyricsLabel; it overrides viewWillAppear: / viewWillDisappear: /
//     viewDidLayoutSubviews.
//   - Lyrics come from Deezer's GraphQL API (Apollo): query GetLyricsForTrack,
//     fragment LyricsSynchronizedLineFields { lrcTimestamp line lineTranslated
//     milliseconds duration }. Timing is per line only: Deezer has no word
//     timing. Apollo's URLSessionClient is an NSObject with the ObjC
//     URLSession delegate methods, so the reply can be read as it arrives.
//   - +[DZRAudioPlayer sharedAudioPlayer] -playbackElapsedTime / -currentTrack,
//     and DeezerTrack -deezerId.
//
// 1. Karaoke Mode button, bottom left (mirroring Deezer's share button). Tap:
//    lead vocals to 0 % with the backing vocals kept, tap again: back to
//    normal. Long press: the Karaoke Mode sheet with every option. Without a
//    vocal model a tap opens the sheet, which says how to get one.
// 2. Word by word: each line's words get a share of the line's time (by
//    syllables, the last word held a little longer), and the line being sung
//    is masked so sung words are bright and the rest dim, with a soft wipe
//    across the word being sung. It's an estimate of where each word falls;
//    the line timing is Deezer's. Lines are read from the GraphQL reply and
//    kept in Library/Caches/Deezit/lyrics, so lyrics Apollo later serves from
//    its cache still animate. Settings → Lyrics → Word by word turns it off.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "DZLog.h"
#import "DZPrefs.h"
#import "DZSettingsViewController.h"
#import "DZVocalModel.h"
#import "DZDemucsModel.h"
#import "DZQuickActions.h"

// placeholders; %init binds them to Deezer.LyricsViewController and
// Apollo.URLSessionClient (Swift class names can't be written in %hook)
@interface DZLyricsVC : UIViewController
@end
@interface DZApolloClient : NSObject
@end

static id kv(id o, NSString *key) {
    if (!o || ![o respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try { return [o valueForKey:key]; } @catch (NSException *e) { return nil; }
}

static NSString *idString(id v) {
    if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return nil;
}

#pragma mark - timed lines

@interface DZTimedLine : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) double start, duration;   // s
@end
@implementation DZTimedLine
@end

static NSObject *lyricsLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSMutableDictionary<NSString *, NSArray<DZTimedLine *> *> *sLines;   // Deezer track ID -> lines
static NSArray<DZTimedLine *> *sLastLines;                                  // the latest reply, any track

static NSURL *lyricsDir(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [[caches URLByAppendingPathComponent:@"Deezit"] URLByAppendingPathComponent:@"lyrics" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *safeID(NSString *tid) {
    return [[tid componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
}

static NSArray<DZTimedLine *> *linesFromJSON(id arr) {
    if (![arr isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in arr) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        id text = d[@"line"] ?: d[@"t"], ms = d[@"milliseconds"] ?: d[@"s"], dur = d[@"duration"] ?: d[@"d"];
        if (![text isKindOfClass:[NSString class]] || ![ms isKindOfClass:[NSNumber class]]) continue;
        DZTimedLine *l = [DZTimedLine new];
        l.text = text;
        l.start = [ms doubleValue] / 1000.0;
        l.duration = [dur isKindOfClass:[NSNumber class]] ? [dur doubleValue] / 1000.0 : 0;
        [out addObject:l];
    }
    [out sortUsingComparator:^NSComparisonResult(DZTimedLine *a, DZTimedLine *b) {
        return a.start < b.start ? NSOrderedAscending : (a.start > b.start ? NSOrderedDescending : NSOrderedSame);
    }];
    return out.count ? out : nil;
}

static void saveLines(NSString *tid, NSArray<DZTimedLine *> *lines) {
    @synchronized (lyricsLock()) {
        if (!sLines) sLines = [NSMutableDictionary dictionary];
        if (tid) sLines[tid] = lines;
        sLastLines = lines;
    }
    if (!tid.length || !safeID(tid).length) return;
    NSMutableArray *plain = [NSMutableArray array];
    for (DZTimedLine *l in lines)
        [plain addObject:@{ @"t": l.text, @"s": @(llround(l.start * 1000)), @"d": @(llround(l.duration * 1000)) }];
    NSData *data = [NSJSONSerialization dataWithJSONObject:plain options:0 error:nil];
    [data writeToURL:[lyricsDir() URLByAppendingPathComponent:[safeID(tid) stringByAppendingPathExtension:@"json"]] atomically:YES];
}

static NSArray<DZTimedLine *> *linesFor(NSString *tid) {
    if (!tid) return nil;
    @synchronized (lyricsLock()) {
        if (!sLines) sLines = [NSMutableDictionary dictionary];
        id cached = sLines[tid];
        if (cached) return cached == (id)[NSNull null] ? nil : cached;
    }
    NSData *data = safeID(tid).length
        ? [NSData dataWithContentsOfURL:[lyricsDir() URLByAppendingPathComponent:[safeID(tid) stringByAppendingPathExtension:@"json"]]] : nil;
    NSArray *lines = data ? linesFromJSON([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
    @synchronized (lyricsLock()) { sLines[tid] = lines ?: (id)[NSNull null]; }
    return lines;
}

// Somewhere in Apollo's reply: data.track.lyrics.synchronizedLines
static id findKey(id json, NSString *key, int depth) {
    if (depth > 8) return nil;
    if ([json isKindOfClass:[NSDictionary class]]) {
        if (json[key]) return json[key];
        for (id v in [json allValues]) {
            id r = findKey(v, key, depth + 1);
            if (r) return r;
        }
    } else if ([json isKindOfClass:[NSArray class]]) {
        for (id v in json) {
            id r = findKey(v, key, depth + 1);
            if (r) return r;
        }
    }
    return nil;
}

#pragma mark - reading Apollo's reply

static void *kTaskDataKey = &kTaskDataKey;   // task -> NSMutableData (lyrics) or NSNull (anything else)
static void *kTaskIDKey = &kTaskIDKey;       // task -> track ID from the query's variables

// The track ID, when this task is a GetLyricsForTrack query.
static NSString *lyricsQueryTrackID(NSURLSessionTask *task) {
    NSURLRequest *r = task.originalRequest ?: task.currentRequest;
    NSString *s = nil;
    NSData *body = r.HTTPBody;
    if (body.length && body.length < 512 * 1024) s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (![s containsString:@"GetLyricsForTrack"]) {
        s = r.URL.absoluteString.stringByRemovingPercentEncoding;   // persisted queries go as a GET
        if (![s containsString:@"GetLyricsForTrack"]) return nil;
    }
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"\"(?:trackId|id)\"\\s*:\\s*\"?([0-9]+)" options:0 error:nil];
    });
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    return m ? [s substringWithRange:[m rangeAtIndex:1]] : @"";
}

static void noteTaskData(NSURLSessionTask *task, NSData *data) {
    if (!task || !data.length) return;
    id box = objc_getAssociatedObject(task, kTaskDataKey);
    if (box == [NSNull null]) return;
    if (!box) {
        NSString *tid = lyricsQueryTrackID(task);
        if (!tid) {
            objc_setAssociatedObject(task, kTaskDataKey, [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        box = [NSMutableData data];
        objc_setAssociatedObject(task, kTaskDataKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(task, kTaskIDKey, tid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if ([box isKindOfClass:[NSMutableData class]] && [box length] < 4 * 1024 * 1024) [box appendData:data];
}

static void finishTask(NSURLSessionTask *task, NSError *error) {
    id box = task ? objc_getAssociatedObject(task, kTaskDataKey) : nil;
    if (![box isKindOfClass:[NSMutableData class]]) return;
    NSString *tid = objc_getAssociatedObject(task, kTaskIDKey);
    objc_setAssociatedObject(task, kTaskDataKey, [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (error) return;
    id json = [NSJSONSerialization JSONObjectWithData:box options:0 error:nil];
    NSArray<DZTimedLine *> *lines = linesFromJSON(findKey(json, @"synchronizedLines", 0));
    if (!lines) {
        DZLog("lyrics: track %@ has no timed lines", tid.length ? tid : @"?");
        return;
    }
    saveLines(tid.length ? tid : nil, lines);
    DZLog("lyrics: %lu timed lines for track %@", (unsigned long)lines.count, tid.length ? tid : @"?");
}

#pragma mark - word by word

static double syllables(NSString *word) {
    int groups = 0;
    BOOL inVowel = NO;
    for (NSUInteger i = 0; i < word.length; i++) {
        unichar c = [word characterAtIndex:i];
        BOOL v = [@"aeiouyAEIOUYàáâäèéêëìíîïòóôöùúûüÿœæ" rangeOfString:[NSString stringWithCharacters:&c length:1]].location != NSNotFound;
        if (v && !inVowel) groups++;
        inVowel = v;
    }
    return MAX(1, groups);
}

static NSString *normalized(NSString *s) {
    NSArray *parts = [s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "].lowercaseString;
}

@interface DZWordAnimator : NSObject
@property (nonatomic, weak) UIViewController *vc;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, weak) UILabel *label;
@property (nonatomic, copy) NSString *geometryKey;
@property (nonatomic, strong) CALayer *mask;
@property (nonatomic, strong) NSArray<CAGradientLayer *> *words;
@property (nonatomic, strong) NSArray<NSNumber *> *starts, *ends;   // share of the line, 0 ... 1
@end

@implementation DZWordAnimator

- (void)start {
    if (self.link) return;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    self.link.preferredFrameRateRange = CAFrameRateRangeMake(20, 30, 30);
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)stop {
    [self.link invalidate];
    self.link = nil;
    [self clear];
}

- (void)clear {
    UILabel *l = self.label;
    if (l && l.layer.mask == self.mask) l.layer.mask = nil;
    self.label = nil;
    self.mask = nil;
    self.geometryKey = nil;
}

// Where each word of `label` is drawn (TextKit, laid out like the label), and
// its share of the line's time.
- (BOOL)prepareFor:(UILabel *)label {
    NSString *text = label.text ?: @"";
    CGSize size = label.bounds.size;
    NSString *key = [NSString stringWithFormat:@"%@|%.0fx%.0f", text, size.width, size.height];
    if (label == self.label && [key isEqualToString:self.geometryKey]) return YES;
    [self clear];
    if (!text.length || size.width < 10 || !label.font) return NO;

    NSMutableAttributedString *as = label.attributedText.length ? [label.attributedText mutableCopy]
        : [[NSMutableAttributedString alloc] initWithString:text attributes:@{ NSFontAttributeName: label.font }];
    if (![as attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL]) {
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.alignment = label.textAlignment;
        [as addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, as.length)];
    }
    NSTextStorage *storage = [[NSTextStorage alloc] initWithAttributedString:as];
    NSLayoutManager *lm = [NSLayoutManager new];
    [storage addLayoutManager:lm];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:CGSizeMake(size.width, CGFLOAT_MAX)];
    tc.lineFragmentPadding = 0;
    tc.maximumNumberOfLines = label.numberOfLines;
    tc.lineBreakMode = label.lineBreakMode;
    [lm addTextContainer:tc];
    [lm ensureLayoutForTextContainer:tc];
    CGRect used = [lm usedRectForTextContainer:tc];
    CGFloat dy = (size.height - used.size.height) / 2 - used.origin.y;

    NSMutableArray<NSValue *> *rects = [NSMutableArray array];
    NSMutableArray<NSNumber *> *weights = [NSMutableArray array];
    [storage.string enumerateSubstringsInRange:NSMakeRange(0, storage.length) options:NSStringEnumerationByWords
                                    usingBlock:^(NSString *w, NSRange r, NSRange er, BOOL *stop) {
        NSRange g = [lm glyphRangeForCharacterRange:r actualCharacterRange:NULL];
        CGRect rect = [lm boundingRectForGlyphRange:g inTextContainer:tc];
        if (CGRectIsEmpty(rect)) return;
        // reach over the word's trailing punctuation and the space before the next
        [rects addObject:[NSValue valueWithCGRect:CGRectOffset(CGRectInset(rect, -4, -6), 0, dy)]];
        [weights addObject:@(syllables(w))];
    }];
    if (!rects.count) return NO;
    weights[weights.count - 1] = @(weights.lastObject.doubleValue * 1.6);   // the last word is usually held
    double total = 0;
    for (NSNumber *w in weights) total += w.doubleValue;

    CALayer *mask = [CALayer layer];
    mask.frame = label.bounds;
    CALayer *base = [CALayer layer];
    base.frame = label.bounds;
    base.backgroundColor = [UIColor colorWithWhite:1 alpha:0.42].CGColor;   // words not sung yet
    [mask addSublayer:base];
    NSMutableArray *layers = [NSMutableArray array], *starts = [NSMutableArray array], *ends = [NSMutableArray array];
    double acc = 0;
    for (NSUInteger i = 0; i < rects.count; i++) {
        CAGradientLayer *g = [CAGradientLayer layer];
        g.frame = rects[i].CGRectValue;
        g.startPoint = CGPointMake(0, 0.5);
        g.endPoint = CGPointMake(1, 0.5);
        g.colors = @[(id)UIColor.whiteColor.CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
        g.locations = @[@0, @0];
        [mask addSublayer:g];
        [layers addObject:g];
        [starts addObject:@(acc / total)];
        acc += weights[i].doubleValue;
        [ends addObject:@(acc / total)];
    }
    self.words = layers;
    self.starts = starts;
    self.ends = ends;
    self.mask = mask;
    self.label = label;
    self.geometryKey = key;
    label.layer.mask = mask;
    return YES;
}

- (void)showProgress:(double)p {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    const double soft = 0.35;
    for (NSUInteger i = 0; i < self.words.count; i++) {
        double s = self.starts[i].doubleValue, e = self.ends[i].doubleValue;
        double f = e > s ? (p - s) / (e - s) : (p >= e ? 1 : 0);
        f = MAX(0, MIN(1, f));
        // a soft edge sweeping left to right across the word
        double a = f * (1 + soft) - soft, b = a + soft;
        self.words[i].locations = @[@(MAX(0, MIN(1, a))), @(MAX(0, MIN(1, b)))];
        self.words[i].colors = f >= 1 ? @[(id)UIColor.whiteColor.CGColor, (id)UIColor.whiteColor.CGColor]
                                      : @[(id)UIColor.whiteColor.CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
    }
    [CATransaction commit];
}

- (void)tick {
    UIViewController *vc = self.vc;
    if (!vc) { [self stop]; return; }
    if (!vc.view.window || !DZPrefBool(kDZWordLyrics)) { [self clear]; return; }

    Class playerClass = objc_getClass("DZRAudioPlayer");
    SEL shared = NSSelectorFromString(@"sharedAudioPlayer");
    id player = [playerClass respondsToSelector:shared] ? ((id (*)(id, SEL))objc_msgSend)(playerClass, shared) : nil;
    SEL elapsedSel = NSSelectorFromString(@"playbackElapsedTime");
    if (![player respondsToSelector:elapsedSel]) { [self clear]; return; }
    double t = ((double (*)(id, SEL))objc_msgSend)(player, elapsedSel);
    NSString *tid = idString(kv(kv(player, @"currentTrack"), @"deezerId"));
    NSArray<DZTimedLine *> *lines = linesFor(tid);
    if (!lines) {
        @synchronized (lyricsLock()) { lines = sLastLines; }
    }
    if (!lines.count) { [self clear]; return; }

    NSInteger lo = 0, hi = (NSInteger)lines.count - 1, idx = -1;
    while (lo <= hi) {
        NSInteger mid = (lo + hi) / 2;
        if (lines[mid].start <= t) { idx = mid; lo = mid + 1; } else hi = mid - 1;
    }
    if (idx < 0) { [self clear]; return; }
    DZTimedLine *line = lines[idx];
    double end = line.duration > 0.05 ? line.start + line.duration
               : (idx + 1 < (NSInteger)lines.count ? lines[idx + 1].start : line.start + 5);
    if (t > end + 0.5) { [self clear]; return; }   // between lines

    // the cell showing that line (nearest the previous one, then the middle)
    UICollectionView *cv = kv(vc, @"lyricsCollectionView");
    if (![cv isKindOfClass:[UICollectionView class]]) { [self clear]; return; }
    NSString *want = normalized(line.text);
    if (!want.length) { [self clear]; return; }
    UILabel *best = nil;
    CGFloat bestDist = CGFLOAT_MAX, mid = cv.contentOffset.y + cv.bounds.size.height * 0.45;
    for (UICollectionViewCell *cell in cv.visibleCells) {
        UILabel *l = kv(cell, @"lyricsLabel");
        if (![l isKindOfClass:[UILabel class]] || ![normalized(l.text ?: @"") isEqualToString:want]) continue;
        CGFloat d = l == self.label ? -1 : fabs(cell.center.y - mid);
        if (d < bestDist) { bestDist = d; best = l; }
    }
    if (!best || ![self prepareFor:best]) { [self clear]; return; }
    [self showProgress:MAX(0, MIN(1, (t - line.start) / MAX(0.2, end - line.start)))];
}

@end

static void *kAnimatorKey = &kAnimatorKey;

#pragma mark - Karaoke Mode button

// A pill, "🎤 Karaoke Mode", when the lyrics open, that shrinks to a round
// icon button after a few seconds. Off: translucent with a white icon; on:
// white with a dark icon. Tap: karaoke on / off; touch and hold: the sheet.
@interface DZKaraokeButton : UIControl
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic) BOOL expanded;
@end

@implementation DZKaraokeButton

static const CGFloat kDZPillH = 44, kDZPillPadL = 14, kDZPillPadR = 18, kDZPillGap = 7;

+ (instancetype)buttonForHost:(UIViewController *)host {
    DZKaraokeButton *b = [[self alloc] initWithFrame:CGRectMake(0, 0, kDZPillH, kDZPillH)];
    b.host = host;
    b.clipsToBounds = YES;
    b.icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"music.mic"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold]]];
    b.icon.contentMode = UIViewContentModeCenter;
    b.label = [UILabel new];
    b.label.text = @"Karaoke Mode";
    b.label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [b.label sizeToFit];
    for (UIView *v in @[b.icon, b.label]) {
        v.userInteractionEnabled = NO;
        [b addSubview:v];
    }
    b.isAccessibilityElement = YES;
    b.accessibilityLabel = @"Karaoke Mode";
    b.accessibilityTraits = UIAccessibilityTraitButton;
    b.accessibilityHint = @"Removes the lead vocals. Touch and hold for options.";
    [b addTarget:b action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [b addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:b action:@selector(held:)]];
    [[NSNotificationCenter defaultCenter] addObserver:b selector:@selector(refresh) name:DZPrefsChangedNotification object:nil];
    [b refresh];
    return b;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (CGFloat)preferredWidth {
    if (!self.expanded) return kDZPillH;
    return kDZPillPadL + 22 + kDZPillGap + self.label.bounds.size.width + kDZPillPadR;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height;
    self.layer.cornerRadius = h / 2;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    CGFloat iconX = self.expanded ? kDZPillPadL + 11 : self.bounds.size.width / 2;
    self.icon.center = CGPointMake(iconX, h / 2);
    self.icon.bounds = CGRectMake(0, 0, 24, 24);
    CGRect lf = self.label.frame;
    lf.origin = CGPointMake(kDZPillPadL + 22 + kDZPillGap, (h - lf.size.height) / 2);
    self.label.frame = lf;
    self.label.alpha = self.expanded ? 1 : 0;
}

- (void)refresh {
    BOOL on = DZKaraokeIsOn();
    UIColor *fg = on ? [UIColor colorWithRed:27 / 255.0 green:1 / 255.0 blue:30 / 255.0 alpha:1] : UIColor.whiteColor;
    self.backgroundColor = on ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.16];
    self.icon.tintColor = fg;
    self.label.textColor = fg;
    self.accessibilityValue = on ? @"On" : @"Off";
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.15 animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.94, 0.94) : CGAffineTransformIdentity;
    }];
}

- (void)tapped {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    if (!DZSingReady()) {
        DZPresentSheet(self.host, DZSheetKaraoke);   // says how to get a vocal model
        return;
    }
    DZKaraokeToggle();
    [self refresh];
}

- (void)held:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    DZPresentSheet(self.host, DZSheetKaraoke);
}

@end

static void *kKaraokeButtonKey = &kKaraokeButtonKey;

// Bottom left, mirroring Deezer's share button (same height and margin).
static void layoutKaraokeButton(UIViewController *vc) {
    UIView *share = kv(vc, @"sharingButton");
    if (![share isKindOfClass:[UIView class]] || !share.superview) return;
    DZKaraokeButton *b = objc_getAssociatedObject(vc, kKaraokeButtonKey);
    if (!b) {
        b = [DZKaraokeButton buttonForHost:vc];
        objc_setAssociatedObject(vc, kKaraokeButtonKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DZLog("lyrics: Karaoke Mode button added");
    }
    UIView *container = share.superview;
    if (b.superview != container) {
        [b removeFromSuperview];
        [container addSubview:b];
    }
    CGRect f = share.frame;
    CGFloat gap = container.bounds.size.width - CGRectGetMaxX(f);
    gap = MAX(12, gap - (kDZPillH - MIN(kDZPillH, f.size.width)) / 2);
    b.frame = CGRectMake(gap, CGRectGetMidY(f) - kDZPillH / 2, [b preferredWidth], kDZPillH);
    b.hidden = share.hidden;
    b.alpha = share.alpha;
}

// The lyrics just opened: show the pill, then shrink it to the icon.
static void showKaraokePill(UIViewController *vc) {
    DZKaraokeButton *b = objc_getAssociatedObject(vc, kKaraokeButtonKey);
    if (!b) return;
    b.expanded = YES;
    layoutKaraokeButton(vc);
    [b setNeedsLayout];
    [b layoutIfNeeded];
    __weak DZKaraokeButton *weakB = b;
    __weak UIViewController *weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DZKaraokeButton *bb = weakB;
        UIViewController *v = weakVC;
        if (!bb || !v || !bb.expanded) return;
        [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            bb.expanded = NO;
            layoutKaraokeButton(v);
            [bb setNeedsLayout];
            [bb layoutIfNeeded];
        } completion:nil];
    });
}

#pragma mark - hooks

%group DZLyricsScreenHooks

%hook DZLyricsVC

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    DZWordAnimator *a = objc_getAssociatedObject(self, kAnimatorKey);
    if (!a) {
        a = [DZWordAnimator new];
        a.vc = self;
        objc_setAssociatedObject(self, kAnimatorKey, a, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [a start];
    if (objc_getAssociatedObject(self, kKaraokeButtonKey)) showKaraokePill(self);   // opened again
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    [(DZWordAnimator *)objc_getAssociatedObject(self, kAnimatorKey) stop];
}

- (void)viewDidLayoutSubviews {
    %orig;
    BOOL first = objc_getAssociatedObject(self, kKaraokeButtonKey) == nil;
    layoutKaraokeButton(self);
    if (first && objc_getAssociatedObject(self, kKaraokeButtonKey)) showKaraokePill(self);
}

%end

%end

%group DZApolloHooks

%hook DZApolloClient

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    @try { noteTaskData(task, data); } @catch (NSException *e) {}
    %orig;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    @try { finishTask(task, error); } @catch (NSException *e) {}
    %orig;
}

%end

%end

static BOOL ownsMethod(Class c, SEL s) {
    if (!c) return NO;
    unsigned int n = 0;
    Method *list = class_copyMethodList(c, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n && !found; i++) found = method_getName(list[i]) == s;
    free(list);
    return found;
}

void DZLyricsInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class lyrics = NSClassFromString(@"Deezer.LyricsViewController") ?: objc_getClass("_TtC6Deezer20LyricsViewController");
        if (ownsMethod(lyrics, @selector(viewWillAppear:)) && ownsMethod(lyrics, @selector(viewWillDisappear:)) &&
            ownsMethod(lyrics, @selector(viewDidLayoutSubviews))) {
            %init(DZLyricsScreenHooks, DZLyricsVC = lyrics);
        } else {
            DZLog("lyrics: Deezer.LyricsViewController not as expected, no Karaoke Mode button / word by word");
            return;
        }
        Class apollo = NSClassFromString(@"Apollo.URLSessionClient") ?: objc_getClass("_TtC6Apollo16URLSessionClient");
        if (ownsMethod(apollo, @selector(URLSession:dataTask:didReceiveData:)) &&
            ownsMethod(apollo, @selector(URLSession:task:didCompleteWithError:))) {
            %init(DZApolloHooks, DZApolloClient = apollo);
            DZLog("lyrics: Karaoke Mode button and word-by-word lyrics ready");
        } else {
            DZLog("lyrics: Apollo's URLSessionClient not as expected, no line timing: word by word off");
        }
    });
}
