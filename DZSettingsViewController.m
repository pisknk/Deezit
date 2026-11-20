#import "DZSettingsViewController.h"
#import "DZPrefs.h"
#import "DZPresets.h"
#import "DZAudioHook.h"
#import "DZVocalModel.h"
#import "DZDemucsModel.h"

#ifndef DEEZIT_VERSION
#define DEEZIT_VERSION "dev"
#endif

// One controller, two pages:
//   Playback Controls (player ••• menu): everything that shapes the sound -
//     Slowed + Reverb switch, Sing (vocals), presets, speed, reverb, reset
//   Settings (three-finger hold): app-level things - the Sing model download
//     and the lock-screen covers
typedef NS_ENUM(NSInteger, DZSection) {
    DZSectionEffect,      // controls
    DZSectionSing,        // controls: Vocals slider
    DZSectionPresets,     // controls
    DZSectionSpeed,       // controls
    DZSectionReverb,      // controls
    DZSectionReset,       // controls
    DZSectionModel,       // settings: Sing model download
    DZSectionDemucs,      // settings: experimental model lab (MDX-Net) + benchmark
    DZSectionLockScreen,  // settings
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

@interface DZSettingsViewController ()
@property (nonatomic, copy) NSString *pageTitle;
@end

@implementation DZSettingsViewController

+ (UIViewController *)presentableController {
    DZSettingsViewController *vc = [[DZSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = YES;
    return nav;
}

+ (UIViewController *)playbackControlsController {
    DZSettingsViewController *vc = [[DZSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.pageTitle = @"Playback Controls";
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
    return self.pageTitle != nil;
}

- (BOOL)shows:(NSInteger)section {
    switch (section) {
        case DZSectionEffect:
        case DZSectionSing:
        case DZSectionPresets:
        case DZSectionSpeed:
        case DZSectionReverb:
        case DZSectionReset:
            return [self isControls];
        case DZSectionModel:
        case DZSectionDemucs:
        case DZSectionLockScreen:
            return ![self isControls];
    }
    return NO;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.pageTitle ?: @"Deezit";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(done)];
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

- (void)reload:(NSIndexSet *)sections {
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
    [self reload:sections];
}

- (void)modelChanged {
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSetWithIndex:DZSectionModel];
    [sections addIndex:DZSectionSing];
    [self reload:sections];
}

- (void)demucsChanged {
    [self reload:[NSIndexSet indexSetWithIndex:DZSectionDemucs]];
}

- (void)reloadSliders {
    NSMutableIndexSet *s = [NSMutableIndexSet indexSetWithIndex:DZSectionSpeed];
    [s addIndex:DZSectionReverb];
    [s addIndex:DZSectionSing];
    [self reload:s];
}

#pragma mark table data

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return DZSectionCount; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (![self shows:section]) return 0;
    switch (section) {
        case DZSectionEffect: return 1;
        case DZSectionSing: return DZVocalModelGetState() == DZVocalModelReady ? 3 : 1;   // Vocals, Backing vocals, Strength
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
        case DZSectionLockScreen: return 1;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (![self shows:section]) return nil;
    switch (section) {
        case DZSectionSing: return @"Sing";
        case DZSectionPresets: return @"Presets";
        case DZSectionSpeed: return @"Speed";
        case DZSectionReverb: return @"Reverb";
        case DZSectionModel: return @"Sing";
        case DZSectionDemucs: return @"Model lab (experimental)";
        case DZSectionLockScreen: return @"Lock Screen";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (![self shows:section]) return nil;
    switch (section) {
        case DZSectionEffect:
            return [NSString stringWithFormat:@"Audio hook: %@", DZAudioBackendDescription()];
        case DZSectionSing:
            return DZVocalModelGetState() == DZVocalModelReady
                ? @"Takes the singing out with an on-device AI model. Backing vocals keeps the harmonies spread left and right "
                  @"and removes only the centred lead. Strength: Gentle only removes what the model is sure is voice "
                  @"(instruments like violins and claps stay, a little voice may remain); Strong removes more, instruments "
                  @"included. Changes are heard after about 3 seconds."
                : @"Needs the vocal model: open Deezit Settings (three-finger hold) → Sing → Download.";
        case DZSectionSpeed:
            return @"Pitch follows speed, like a turntable: slower is deeper.";
        case DZSectionReset:
            return @"Deezit " DEEZIT_VERSION " · github.com/pisknk/Deezit";
        case DZSectionModel:
            return @"Sing removes vocals with Spleeter (2-stems, by Deezer Research, MIT licence), running on the iPhone's "
                   @"Neural Engine. The model is downloaded once from the Deezit GitHub releases; audio never leaves the phone. "
                   @"Turn it up or down with Playback Controls → Sing → Vocals.";
        case DZSectionDemucs:
            return @"Candidate Sing models, benchmarked on this iPhone: UVR MDX-Net vocal models 9482 (by Anjok07) and Voc FT "
                   @"(by Kimberley Jensen), MIT licence, Core ML conversion by gyoom; about 50 MB for both. The benchmark times each "
                   @"one and shows how much runs on the Neural Engine, which Sing needs to keep working with the screen locked. "
                   @"Playback keeps using Spleeter. A bigger model is skipped when there isn't enough memory for it. Takes a minute or two. "
                   @"If Deezer closes during it, reopen this page: the result then shows the step it reached and how much memory was left.";
        case DZSectionLockScreen:
            return @"Plays Apple Music's motion cover of the album on the lock screen, when it has one. Needs iOS 26; paused in Low Power Mode.\n\n"
                   @"Deezit " DEEZIT_VERSION " · github.com/pisknk/Deezit";
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
    switch (ip.section) {
        case DZSectionEffect: {
            UITableViewCell *c = [self basicCell:tv at:ip];
            UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
            cfg.text = @"Slowed + Reverb";
            cfg.image = [UIImage systemImageNamed:@"waveform"];
            c.contentConfiguration = cfg;
            UISwitch *sw = [UISwitch new];
            sw.on = DZPrefBool(kDZEnabled);
            [sw addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            return c;
        }
        case DZSectionSing: {
            if (DZVocalModelGetState() != DZVocalModelReady) {
                UITableViewCell *c = [self basicCell:tv at:ip];
                UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
                cfg.text = @"Vocals";
                cfg.secondaryText = @"Vocal model not downloaded";
                cfg.secondaryTextProperties.color = UIColor.secondaryLabelColor;
                cfg.image = [UIImage systemImageNamed:@"music.mic"];
                c.contentConfiguration = cfg;
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
                cfg.image = [UIImage systemImageNamed:@"music.mic"];
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
                cfg.image = [UIImage systemImageNamed:@"waveform.badge.magnifyingglass"];
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
                cfg.secondaryText = DZDemucsBenchmarkResult();
                cfg.secondaryTextProperties.numberOfLines = 0;
                cfg.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
            }
            c.contentConfiguration = cfg;
            return c;
        }
        case DZSectionLockScreen: {
            UITableViewCell *c = [self basicCell:tv at:ip];
            UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
            cfg.text = @"Animated album covers";
            cfg.image = [UIImage systemImageNamed:@"lock.rectangle.stack"];
            c.contentConfiguration = cfg;
            UISwitch *sw = [UISwitch new];
            sw.on = DZPrefBool(kDZLockArtwork);
            [sw addTarget:self action:@selector(toggleLockArtwork:) forControlEvents:UIControlEventValueChanged];
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

- (void)strengthChanged:(UISegmentedControl *)seg {
    DZPrefSet(kDZSingStrength, @(seg.selectedSegmentIndex));
}

- (void)toggleLockArtwork:(UISwitch *)sw {
    DZPrefSet(kDZLockArtwork, @(sw.on));
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
    if (ip.section == DZSectionPresets) {
        DZApplyPreset(DZAllPresets()[ip.row]);
        [self reloadSliders];
    } else if (ip.section == DZSectionReset) {
        DZPrefsResetAudio();
        [self reloadSliders];
    } else if (ip.section == DZSectionModel && ip.row == 1) {
        switch (DZVocalModelGetState()) {
            case DZVocalModelNotInstalled:
            case DZVocalModelFailed: DZVocalModelDownload(); break;
            case DZVocalModelDownloading: DZVocalModelCancel(); break;
            case DZVocalModelReady: [self confirmDeleteModel]; break;
            case DZVocalModelCompiling: break;
        }
    } else if (ip.section == DZSectionDemucs && ip.row == 1) {
        switch (DZDemucsGetState()) {
            case DZDemucsNotInstalled:
            case DZDemucsFailed: DZDemucsDownload(); break;
            case DZDemucsDownloading: DZDemucsCancel(); break;
            case DZDemucsReady: DZDemucsDelete(); break;
            case DZDemucsPreparing: break;
        }
    } else if (ip.section == DZSectionDemucs && ip.row == 2) {
        DZDemucsRunBenchmark();
    }
}

@end
