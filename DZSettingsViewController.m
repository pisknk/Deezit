#import "DZSettingsViewController.h"
#import "DZIcons.h"
#import "DZPrefs.h"
#import "DZPresets.h"
#import "DZAudioHook.h"
#import "DZVocalModel.h"
#import "DZDemucsModel.h"
#import "DZAutoMix.h"

#ifndef DEEZIT_VERSION
#define DEEZIT_VERSION "dev"
#endif

// One controller, four pages:
//   Playback Controls (hold the player's Slowed + Reverb button): Slowed +
//     Reverb switch, presets, speed, reverb, reset
//   Karaoke Mode (hold a Karaoke button): Sing - vocals, backing vocals,
//     strength, model
//   AutoMix (hold the player's AutoMix button): AutoMix, Tempo matching
//   Settings (Deezer's Settings → Deezit): app-level things - the Sing model
//     download, the model lab, the player, covers, lyrics
typedef NS_ENUM(NSInteger, DZSection) {
    DZSectionEffect,      // controls
    DZSectionAutoMix,     // controls
    DZSectionSing,       // karaoke: Vocals, Backing vocals, Strength, Model
    DZSectionPresets,     // controls
    DZSectionSpeed,       // controls
    DZSectionReverb,      // controls
    DZSectionReset,       // controls
    DZSectionModel,       // settings: Sing model download
    DZSectionDemucs,      // settings: experimental model lab (MDX-Net) + benchmark
    DZSectionPlayer,      // settings: native ••• menu
    DZSectionLockScreen,  // settings: animated covers (lock screen, player)
    DZSectionLyrics,      // settings: word by word
    DZSectionCount,
};

#pragma mark - slider cell

@interface DZSliderCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, copy) NSString *prefKey;
@property (nonatomic, copy) NSString *(^format)(float value);
@end

@implementation DZSliderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _titleLabel.adjustsFontForContentSizeCategory = YES;

        _valueLabel = [UILabel new];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize
                                                            weight:UIFontWeightRegular];
        _valueLabel.textColor = UIColor.secondaryLabelColor;
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [_valueLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        _slider = [UISlider new];

        UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _valueLabel]];
        top.axis = UILayoutConstraintAxisHorizontal;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[top, _slider]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 6;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:m.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:m.bottomAnchor],
        ]];
    }
    return self;
}

- (void)refreshValueLabel {
    self.valueLabel.text = self.format ? self.format(self.slider.value) : [NSString stringWithFormat:@"%.2f", self.slider.value];
}

@end

#pragma mark - controller

typedef NS_ENUM(NSInteger, DZPage) { DZPageSettings, DZPageControls, DZPageKaraoke, DZPageAutoMix };

@interface DZSettingsViewController ()
@property (nonatomic, copy) NSString *pageTitle;
@property (nonatomic) DZPage page;
@property (nonatomic) BOOL deezerStyle;   // opened from Deezer's own Settings: its colours and header
@end

// Deezer's Settings colours: its own Tempo colour tokens, so the page follows
// Deezer's light or dark theme. Without them, the dark theme's colours (from a
// screenshot) and the page stays dark.
static UIColor *dzRGB(int r, int g, int b) { return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1]; }
#define kDZDeezerBG DZTempoColor(@"backgroundNeutralPrimaryDefault", dzRGB(27, 1, 30))
#define kDZDeezerCard DZTempoColor(@"backgroundNeutralSecondaryDefault", dzRGB(40, 6, 41))
#define kDZDeezerDivider DZTempoColor(@"dividerNeutralPrimaryDefault", dzRGB(68, 34, 69))
#define kDZDeezerText DZTempoColor(@"textNeutralPrimaryDefault", UIColor.whiteColor)
#define kDZDeezerSecondary DZTempoColor(@"textNeutralSecondaryDefault", dzRGB(210, 177, 211))
#define kDZDeezerIcon DZTempoColor(@"iconNeutralPrimaryDefault", dzRGB(210, 177, 211))
#define kDZDeezerAccent DZTempoColor(@"textAccentPrimaryDefault", dzRGB(241, 186, 251))
#define kDZDeezerSwitch DZTempoColor(@"backgroundAccentPrimaryDefault", dzRGB(241, 186, 251))
#define kDZDeezerButton DZTempoColor(@"backgroundNeutralTertiaryDefault", dzRGB(65, 31, 66))

@implementation DZSettingsViewController

+ (UIViewController *)deezerSettingsPage {
    DZSettingsViewController *vc = [[DZSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.page = DZPageSettings;
    vc.pageTitle = @"Deezit";
    vc.deezerStyle = YES;
    return vc;
}

- (void)applyDeezerStyle {
    if (!DZTempoColorsAvailable()) self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.backgroundColor = kDZDeezerBG;
    self.tableView.separatorColor = kDZDeezerDivider;
    self.tableView.tintColor = kDZDeezerAccent;
    self.view.tintColor = kDZDeezerAccent;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}

// Deezer's Settings draws its own header (a round button and a centred
// title) with the navigation bar hidden; do the same when it's hidden here.
- (void)updateDeezerHeader {
    if (!self.deezerStyle) return;
    BOOL ownHeader = !self.navigationController || self.navigationController.navigationBarHidden;
    if (!ownHeader) {
        self.tableView.tableHeaderView = nil;
        return;
    }
    if (self.tableView.tableHeaderView) return;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 72)];
    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    BOOL pushed = self.navigationController.viewControllers.count > 1 && self.navigationController.topViewController == self;
    [back setImage:pushed ? DZIcon(@"chevronLeft", @"chevron.left", 0) : DZIcon(@"cross", @"xmark", 0) forState:UIControlStateNormal];
    back.tintColor = kDZDeezerText;
    back.backgroundColor = kDZDeezerButton;
    back.layer.cornerRadius = 22;
    back.frame = CGRectMake(16, 14, 44, 44);
    back.accessibilityLabel = pushed ? @"Back" : @"Close";
    [back addTarget:self action:@selector(back) forControlEvents:UIControlEventTouchUpInside];
    UILabel *title = [UILabel new];
    title.text = self.pageTitle ?: @"Deezit";
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = kDZDeezerText;
    title.textAlignment = NSTextAlignmentCenter;
    title.frame = CGRectMake(70, 14, header.bounds.size.width - 140, 44);
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:back];
    [header addSubview:title];
    self.tableView.tableHeaderView = header;
}

- (void)back {
    UINavigationController *nav = self.navigationController;
    if (nav.viewControllers.count > 1 && nav.topViewController == self) [nav popViewControllerAnimated:YES];
    else [(nav ?: (UIViewController *)self) dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateDeezerHeader];
}

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    if (!self.deezerStyle) return;
    cell.backgroundColor = kDZDeezerCard;
    if ([cell.contentConfiguration isKindOfClass:[UIListContentConfiguration class]]) {
        UIListContentConfiguration *cfg = (UIListContentConfiguration *)cell.contentConfiguration;
        cfg.imageProperties.tintColor = kDZDeezerIcon;
        cfg.textProperties.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        // rows that are buttons (Download, Delete…) keep their own colour
        if ([cfg.textProperties.color isEqual:UIColor.labelColor]) cfg.textProperties.color = kDZDeezerText;
        cfg.secondaryTextProperties.color = kDZDeezerSecondary;
        cell.contentConfiguration = cfg;
    }
    if ([cell isKindOfClass:[DZSliderCell class]]) {
        ((DZSliderCell *)cell).titleLabel.textColor = kDZDeezerText;
        ((DZSliderCell *)cell).valueLabel.textColor = kDZDeezerSecondary;
    }
    if ([cell.accessoryView isKindOfClass:[UISwitch class]]) ((UISwitch *)cell.accessoryView).onTintColor = kDZDeezerSwitch;
}

- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if (!self.deezerStyle || ![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
    NSString *title = [self tableView:tv titleForHeaderInSection:section];
    if (!title) return;
    UIListContentConfiguration *cfg = [UIListContentConfiguration groupedHeaderConfiguration];
    cfg.text = title;
    cfg.textProperties.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    cfg.textProperties.color = kDZDeezerSecondary;
    cfg.textProperties.transform = UIListContentTextTransformNone;
    cfg.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(16, 0, 8, 0);
    ((UITableViewHeaderFooterView *)view).contentConfiguration = cfg;
}

- (void)tableView:(UITableView *)tv willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if (!self.deezerStyle || ![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
    NSString *text = [self tableView:tv titleForFooterInSection:section];
    if (!text) return;
    UIListContentConfiguration *cfg = [UIListContentConfiguration groupedFooterConfiguration];
    cfg.text = text;
    cfg.textProperties.color = [kDZDeezerSecondary colorWithAlphaComponent:0.75];
    ((UITableViewHeaderFooterView *)view).contentConfiguration = cfg;
}

+ (UIViewController *)presentableController {
    DZSettingsViewController *vc = [[DZSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = YES;
    return nav;
}

+ (UIViewController *)playbackControlsController {
    return [self sheetWithPage:DZPageControls title:@"Playback Controls"];
}

+ (UIViewController *)karaokeController {
    return [self sheetWithPage:DZPageKaraoke title:@"Karaoke Mode"];
}

+ (UIViewController *)autoMixController {
    return [self sheetWithPage:DZPageAutoMix title:@"AutoMix"];
}

+ (UIViewController *)sheetWithPage:(DZPage)page title:(NSString *)title {
    DZSettingsViewController *vc = [[DZSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.page = page;
    vc.pageTitle = title;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = nav.sheetPresentationController;
    sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
    sheet.prefersGrabberVisible = YES;
    // dragging the sliders must not drag the sheet
    sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
    return nav;
}

- (BOOL)isControls {
    return self.page == DZPageControls;
}

// Sing works with either model: Spleeter (Settings -> Sing) or MDX-Net (model lab).
static BOOL singReady(void) {
    return DZVocalModelGetState() == DZVocalModelReady || DZLabModelInstalled(kDZLabMDX);
}

// Which model Sing uses (same choice as the separator makes).
static NSInteger singModelInUse(void) {
    if (!DZLabModelInstalled(kDZLabMDX)) return 0;
    if (DZVocalModelGetState() != DZVocalModelReady) return 1;
    return DZPrefFloat(kDZSingModel) >= 0.5f ? 1 : 0;
}

- (BOOL)shows:(NSInteger)section {
    switch (section) {
        case DZSectionSing:
            return self.page == DZPageKaraoke;
        case DZSectionEffect:
        case DZSectionPresets:
        case DZSectionSpeed:
        case DZSectionReverb:
        case DZSectionReset:
            return [self isControls];
        case DZSectionAutoMix:
            return self.page == DZPageAutoMix;
        case DZSectionModel:
        case DZSectionDemucs:
        case DZSectionPlayer:
        case DZSectionLockScreen:
        case DZSectionLyrics:
            return self.page == DZPageSettings;
    }
    return NO;
}

// The sections this page shows, in order. Hidden ones aren't in the table at
// all: an empty section still leaves its header and footer space (the empty
// stretch in the sheets). Table section indexes map to DZSection through this.
- (NSArray<NSNumber *> *)visibleSections {
    NSMutableArray<NSNumber *> *v = [NSMutableArray array];
    for (NSInteger s = 0; s < DZSectionCount; s++)
        if ([self shows:s]) [v addObject:@(s)];
    return v;
}

- (NSInteger)kindAt:(NSInteger)index {
    NSArray<NSNumber *> *v = [self visibleSections];
    return index >= 0 && index < (NSInteger)v.count ? v[index].integerValue : -1;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.pageTitle ?: @"Deezit";
    if (self.deezerStyle) [self applyDeezerStyle];
    if (!self.deezerStyle || self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                          target:self
                                                          action:@selector(done)];
    }
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"basic"];
    [self.tableView registerClass:[DZSliderCell class] forCellReuseIdentifier:@"slider"];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(prefsChanged)
                                                 name:DZPrefsChangedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(modelChanged)
                                                 name:DZVocalModelChangedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(demucsChanged)
                                                 name:DZDemucsChangedNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)done {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

// `kinds` are DZSection values; the ones this page doesn't show are skipped.
- (void)reload:(NSIndexSet *)kinds {
    NSArray<NSNumber *> *v = [self visibleSections];
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSet];
    [kinds enumerateIndexesUsingBlock:^(NSUInteger k, BOOL *stop) {
        NSUInteger i = [v indexOfObject:@(k)];
        if (i != NSNotFound) [sections addIndex:i];
    }];
    if (!sections.count || !self.isViewLoaded) return;
    [UIView performWithoutAnimation:^{
        [self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (void)prefsChanged {
    // Sliders update their own labels while dragging; only reload rows that
    // other controls can change (switch + preset checkmarks) to keep the
    // slider being dragged from being reset under the finger.
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSetWithIndex:DZSectionPresets];
    [sections addIndex:DZSectionEffect];
    [sections addIndex:DZSectionAutoMix];
    [self reload:sections];
}

- (void)modelChanged {
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSetWithIndex:DZSectionModel];
    [sections addIndex:DZSectionSing];
    [self reload:sections];
}

- (void)demucsChanged {
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSetWithIndex:DZSectionDemucs];
    [sections addIndex:DZSectionSing];
    [self reload:sections];
}

- (void)reloadSliders {
    NSMutableIndexSet *s = [NSMutableIndexSet indexSetWithIndex:DZSectionSpeed];
    [s addIndex:DZSectionReverb];
    [s addIndex:DZSectionSing];
    [self reload:s];
}

#pragma mark table data

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return (NSInteger)[self visibleSections].count; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    section = [self kindAt:section];
    if (section < 0) return 0;
    switch (section) {
        case DZSectionEffect: return 1;
        case DZSectionAutoMix: return 2;   // AutoMix, Tempo matching
        case DZSectionSing:                                    // Vocals, Backing vocals, Strength, + Model with both
            return !singReady() ? 1 : (DZLabModelInstalled(kDZLabMDX) && DZVocalModelGetState() == DZVocalModelReady ? 4 : 3);
        case DZSectionPresets: return (NSInteger)DZAllPresets().count;
        case DZSectionSpeed: return 1;
        case DZSectionReverb: return 3;
        case DZSectionReset: return 1;
        case DZSectionModel: return DZVocalModelGetState() == DZVocalModelCompiling ? 1 : 2;
        case DZSectionDemucs: {
            DZDemucsState st = DZDemucsGetState();
            if (st == DZDemucsPreparing) return 1;
            if (st != DZDemucsReady) return 2;                          // status, download / cancel
            return DZDemucsBenchmarkResult() ? 4 : 3;                   // + benchmark, + result
        }
        case DZSectionPlayer: return 1;
        case DZSectionLockScreen: return 2;
        case DZSectionLyrics: return 1;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    section = [self kindAt:section];
    if (section < 0) return nil;
    switch (section) {
        case DZSectionSing: return @"Sing";
        case DZSectionPresets: return @"Presets";
        case DZSectionSpeed: return @"Speed";
        case DZSectionReverb: return @"Reverb";
        case DZSectionModel: return @"Sing";
        case DZSectionDemucs: return @"Model lab (experimental)";
        case DZSectionPlayer: return @"Player";
        case DZSectionLockScreen: return @"Animated covers";
        case DZSectionLyrics: return @"Lyrics";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    section = [self kindAt:section];
    if (section < 0) return nil;
    switch (section) {
        case DZSectionAutoMix:
            return @"Blends each song into the next on the beat, like a DJ.";
        case DZSectionSing:
            return singReady() ? nil : @"Download a vocal model first: Settings → Deezit → Sing.";
        case DZSectionSpeed:
            return @"Slower is deeper, like a record.";
        case DZSectionModel:
            return @"Removes vocals on this iPhone; no audio leaves it.";
        case DZSectionDemucs:
            return @"A cleaner vocal model, picked in Karaoke Mode.";
        case DZSectionLockScreen:
            return @"Apple Music's moving album covers, when there is one.";
        case DZSectionPlayer:
            return @"Opens the player's ••• options as an iOS menu.";
        case DZSectionReset:
        case DZSectionLyrics:
            return @"Deezit " DEEZIT_VERSION;
    }
    return nil;
}

- (UITableViewCell *)basicCell:(UITableView *)tv at:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"basic" forIndexPath:ip];
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryNone;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    switch ([self kindAt:ip.section]) {
        case DZSectionEffect: {
            UITableViewCell *c = [self basicCell:tv at:ip];
            UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
            cfg.text = @"Slowed + Reverb";
            cfg.image = DZIcon(@"gauge", @"waveform", 0);
            c.contentConfiguration = cfg;
            UISwitch *sw = [UISwitch new];
            sw.on = DZPrefBool(kDZEnabled);
            [sw addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            return c;
        }
        case DZSectionAutoMix: {
            UITableViewCell *c = [self basicCell:tv at:ip];
            UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
            BOOL tempo = ip.row == 1;
            cfg.text = tempo ? @"Tempo matching" : @"AutoMix";
            cfg.image = tempo ? DZIcon(@"stopwatch", @"metronome", 0) : DZIcon(@"noteDouble", @"arrow.triangle.merge", 0);
            c.contentConfiguration = cfg;
            UISwitch *sw = [UISwitch new];
            sw.on = DZPrefBool(tempo ? kDZAutoMixTempo : kDZAutoMix);
            [sw addTarget:self action:tempo ? @selector(toggleAutoMixTempo:) : @selector(toggleAutoMix:)
                forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            return c;
        }
        case DZSectionSing: {
            if (!singReady()) {
                UITableViewCell *c = [self basicCell:tv at:ip];
                UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
                cfg.text = @"Vocals";
                cfg.secondaryText = @"Vocal model not downloaded";
                cfg.secondaryTextProperties.color = UIColor.secondaryLabelColor;
                cfg.image = DZIcon(@"microphoneMusic", @"music.mic", 0);
                c.contentConfiguration = cfg;
                return c;
            }
            if (ip.row == 3) {
                UITableViewCell *c = [self basicCell:tv at:ip];
                UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
                cfg.text = @"Model";
                c.contentConfiguration = cfg;
                UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Spleeter", @"MDX-Net"]];
                seg.selectedSegmentIndex = singModelInUse();
                [seg addTarget:self action:@selector(singModelChanged:) forControlEvents:UIControlEventValueChanged];
                [seg sizeToFit];
                c.accessoryView = seg;
                return c;
            }
            if (ip.row == 2) {
                UITableViewCell *c = [self basicCell:tv at:ip];
                UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
                cfg.text = @"Strength";
                c.contentConfiguration = cfg;
                UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Gentle", @"Normal", @"Strong"]];
                seg.selectedSegmentIndex = MIN(MAX((NSInteger)lroundf(DZPrefFloat(kDZSingStrength)), 0), 2);
                [seg addTarget:self action:@selector(strengthChanged:) forControlEvents:UIControlEventValueChanged];
                [seg sizeToFit];
                c.accessoryView = seg;
                return c;
            }
            if (ip.row == 1) {
                return [self sliderCell:tv at:ip title:@"Backing vocals" key:kDZBackingVocals min:0 max:1
                                 format:^NSString *(float v) {
                                     return v <= 0.005f ? @"removed" : [NSString stringWithFormat:@"%d%% kept", (int)lroundf(v * 100)];
                                 }];
            }
            return [self sliderCell:tv at:ip title:@"Vocals" key:kDZVocals min:0 max:1
                             format:^NSString *(float v) {
                                 return v >= 0.995f ? @"100% (off)" : [NSString stringWithFormat:@"%d%%", (int)lroundf(v * 100)];
                             }];
        }
        case DZSectionPresets: {
            UITableViewCell *c = [self basicCell:tv at:ip];
            DZPreset *p = DZAllPresets()[ip.row];
            UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
            cfg.text = p.title;
            cfg.secondaryText = [NSString stringWithFormat:@"%.2f× · reverb %d%%", p.speed, (int)lroundf(p.reverbMix * 100)];
            cfg.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            c.contentConfiguration = cfg;
            c.accessoryType = [DZPrefString(kDZPreset) isEqualToString:p.identifier]
                ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            return c;
        }
        case DZSectionSpeed:
            return [self sliderCell:tv at:ip title:@"Speed" key:kDZSpeed
                                min:kDZSpeedMin max:kDZSpeedMax
                             format:^NSString *(float v) { return [NSString stringWithFormat:@"%.2f×", v]; }];
        case DZSectionReverb: {
            NSString *(^pct)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%d%%", (int)lroundf(v * 100)]; };
            NSArray *titles = @[@"Mix", @"Room size", @"Damping"];
            NSArray *keys = @[kDZReverbMix, kDZReverbRoom, kDZReverbDamp];
            return [self sliderCell:tv at:ip title:titles[ip.row] key:keys[ip.row] min:0 max:1 format:pct];
        }
        case DZSectionReset: {
            UITableViewCell *c = [self basicCell:tv at:ip];
            UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
            cfg.text = @"Reset to defaults";
            cfg.textProperties.color = UIColor.systemRedColor;
            c.contentConfiguration = cfg;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            return c;
        }
        case DZSectionModel: {
            UITableViewCell *c = [self basicCell:tv at:ip];
            UIListContentConfiguration *cfg = [UIListContentConfiguration valueCellConfiguration];
            DZVocalModelState state = DZVocalModelGetState();
            if (ip.row == 0) {
                cfg.text = @"Vocal model";
                cfg.secondaryText = DZVocalModelStatusText();
                cfg.image = DZIcon(@"microphoneMusic", @"music.mic", 0);
            } else {
                switch (state) {
                    case DZVocalModelNotInstalled:
                    case DZVocalModelFailed:
                        cfg = [UIListContentConfiguration cellConfiguration];
                        cfg.text = state == DZVocalModelFailed ? @"Try again" : @"Download";
                        cfg.textProperties.color = c.tintColor;
                        break;
                    case DZVocalModelDownloading:
                        cfg = [UIListContentConfiguration cellConfiguration];
                        cfg.text = @"Cancel download";
                        cfg.textProperties.color = c.tintColor;
                        break;
                    case DZVocalModelReady:
                        cfg = [UIListContentConfiguration cellConfiguration];
                        cfg.text = @"Delete model";
                        cfg.textProperties.color = UIColor.systemRedColor;
                        break;
                    case DZVocalModelCompiling:
                        break;
                }
                c.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            c.contentConfiguration = cfg;
            return c;
        }
        case DZSectionDemucs: {
            UITableViewCell *c = [self basicCell:tv at:ip];
            DZDemucsState st = DZDemucsGetState();
            UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
            if (ip.row == 0) {
                cfg = [UIListContentConfiguration valueCellConfiguration];
                cfg.text = @"MDX-Net";
                cfg.secondaryText = DZDemucsStatusText();
                cfg.image = DZIcon(@"waveformPath", @"waveform.badge.magnifyingglass", 0);
            } else if (ip.row == 1) {
                cfg.text = st == DZDemucsDownloading ? @"Cancel download"
                         : st == DZDemucsReady ? @"Delete model"
                         : st == DZDemucsFailed ? @"Try again" : @"Download";
                cfg.textProperties.color = st == DZDemucsReady ? UIColor.systemRedColor : c.tintColor;
                c.selectionStyle = UITableViewCellSelectionStyleDefault;
            } else if (ip.row == 2) {
                BOOL running = DZDemucsBenchmarkRunning();
                cfg.text = running ? @"Running benchmark…" : @"Run benchmark";
                cfg.textProperties.color = running ? UIColor.secondaryLabelColor : c.tintColor;
                c.selectionStyle = running ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
            } else {
                cfg = [UIListContentConfiguration subtitleCellConfiguration];
                cfg.text = @"Last benchmark";
                // the headline only; the whole result is in the debug log
                cfg.secondaryText = [DZDemucsBenchmarkResult() componentsSeparatedByString:@"\n"].firstObject;
                cfg.secondaryTextProperties.numberOfLines = 0;
                cfg.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
            }
            c.contentConfiguration = cfg;
            return c;
        }
        case DZSectionLockScreen: {
            UITableViewCell *c = [self basicCell:tv at:ip];
            UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
            BOOL player = ip.row == 1;
            cfg.text = player ? @"Player" : @"Lock screen";
            cfg.image = player ? DZIcon(@"playCircle", @"play.rectangle", 0) : DZIcon(@"lock", @"lock.rectangle.stack", 0);
            c.contentConfiguration = cfg;
            UISwitch *sw = [UISwitch new];
            sw.on = DZPrefBool(player ? kDZPlayerArtwork : kDZLockArtwork);
            [sw addTarget:self action:player ? @selector(togglePlayerArtwork:) : @selector(toggleLockArtwork:)
                forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            return c;
        }
        case DZSectionPlayer: {
            UITableViewCell *c = [self basicCell:tv at:ip];
            UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
            cfg.text = @"Native ••• menu";
            cfg.image = DZIcon(@"dotsHorizontal", @"ellipsis.circle", 0);
            c.contentConfiguration = cfg;
            UISwitch *sw = [UISwitch new];
            sw.on = DZPrefBool(kDZNativeMenu);
            [sw addTarget:self action:@selector(toggleNativeMenu:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            return c;
        }
        case DZSectionLyrics: {
            UITableViewCell *c = [self basicCell:tv at:ip];
            UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
            cfg.text = @"Word by word";
            cfg.image = DZIcon(@"text", @"text.quote", 0);
            c.contentConfiguration = cfg;
            UISwitch *sw = [UISwitch new];
            sw.on = DZPrefBool(kDZWordLyrics);
            [sw addTarget:self action:@selector(toggleWordLyrics:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            return c;
        }
    }
    return [UITableViewCell new];
}

- (DZSliderCell *)sliderCell:(UITableView *)tv at:(NSIndexPath *)ip title:(NSString *)title key:(NSString *)key
                         min:(float)min max:(float)max format:(NSString *(^)(float))format {
    DZSliderCell *c = [tv dequeueReusableCellWithIdentifier:@"slider" forIndexPath:ip];
    c.titleLabel.text = title;
    c.prefKey = key;
    c.format = format;
    c.slider.minimumValue = min;
    c.slider.maximumValue = max;
    c.slider.value = DZPrefFloat(key);
    [c.slider removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [c.slider addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
    [c refreshValueLabel];
    return c;
}

#pragma mark actions

- (void)toggleEnabled:(UISwitch *)sw {
    DZPrefSet(kDZEnabled, @(sw.on));
}

- (void)toggleAutoMix:(UISwitch *)sw {
    DZPrefSet(kDZAutoMix, @(sw.on));
}

- (void)toggleAutoMixTempo:(UISwitch *)sw {
    DZPrefSet(kDZAutoMixTempo, @(sw.on));
}

- (void)strengthChanged:(UISegmentedControl *)seg {
    DZPrefSet(kDZSingStrength, @(seg.selectedSegmentIndex));
}

- (void)singModelChanged:(UISegmentedControl *)seg {
    DZPrefSet(kDZSingModel, @(seg.selectedSegmentIndex));
    if (seg.selectedSegmentIndex == 1) DZLabModelGet(kDZLabMDX);   // start loading it now
}

- (void)toggleLockArtwork:(UISwitch *)sw {
    DZPrefSet(kDZLockArtwork, @(sw.on));
}

- (void)togglePlayerArtwork:(UISwitch *)sw {
    DZPrefSet(kDZPlayerArtwork, @(sw.on));
}

- (void)toggleNativeMenu:(UISwitch *)sw {
    DZPrefSet(kDZNativeMenu, @(sw.on));
}

- (void)toggleWordLyrics:(UISwitch *)sw {
    DZPrefSet(kDZWordLyrics, @(sw.on));
}

- (void)sliderMoved:(UISlider *)slider {
    DZSliderCell *cell = (DZSliderCell *)slider.superview;
    while (cell && ![cell isKindOfClass:[DZSliderCell class]]) cell = (DZSliderCell *)cell.superview;
    if (!cell.prefKey) return;
    float v = slider.value;
    if ([cell.prefKey isEqualToString:kDZSpeed]) {
        // light detent at 1.00x so "normal speed" is easy to hit
        if (fabsf(v - 1.0f) < 0.015f) { v = 1.0f; slider.value = v; }
    }
    if ([cell.prefKey isEqualToString:kDZVocals]) {
        // snap to 100% so "off" is easy to hit; vocals aren't part of the presets
        if (v > 0.98f) { v = 1.0f; slider.value = v; }
        [cell refreshValueLabel];
        DZPrefSet(kDZVocals, @(v));
        return;
    }
    if ([cell.prefKey isEqualToString:kDZBackingVocals]) {
        // snap to the ends; not part of the presets either
        if (v < 0.02f) v = 0;
        if (v > 0.98f) v = 1;
        slider.value = v;
        [cell refreshValueLabel];
        DZPrefSet(kDZBackingVocals, @(v));
        return;
    }
    [cell refreshValueLabel];
    DZPrefSetMany(@{ cell.prefKey: @(v), kDZPreset: @"custom" });
}

- (void)confirmDeleteModel {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Delete the vocal model?"
                                                                message:@"Sing stops working until it's downloaded again."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) { DZVocalModelDelete(); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSInteger kind = [self kindAt:ip.section];
    if (kind == DZSectionPresets) {
        DZApplyPreset(DZAllPresets()[ip.row]);
        [self reloadSliders];
    } else if (kind == DZSectionReset) {
        DZPrefsResetAudio();
        [self reloadSliders];
    } else if (kind == DZSectionModel && ip.row == 1) {
        switch (DZVocalModelGetState()) {
            case DZVocalModelNotInstalled:
            case DZVocalModelFailed: DZVocalModelDownload(); break;
            case DZVocalModelDownloading: DZVocalModelCancel(); break;
            case DZVocalModelReady: [self confirmDeleteModel]; break;
            case DZVocalModelCompiling: break;
        }
    } else if (kind == DZSectionDemucs && ip.row == 1) {
        switch (DZDemucsGetState()) {
            case DZDemucsNotInstalled:
            case DZDemucsFailed: DZDemucsDownload(); break;
            case DZDemucsDownloading: DZDemucsCancel(); break;
            case DZDemucsReady: DZDemucsDelete(); break;
            case DZDemucsPreparing: break;
        }
    } else if (kind == DZSectionDemucs && ip.row == 2) {
        DZDemucsRunBenchmark();
    }
}

@end
