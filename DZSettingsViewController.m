#import "DZSettingsViewController.h"
#import "DZPrefs.h"
#import "DZPresets.h"
#import "DZAudioHook.h"

typedef NS_ENUM(NSInteger, DZSection) {
    DZSectionEffect,
    DZSectionSing,
    DZSectionPresets,
    DZSectionSpeed,
    DZSectionReverb,
    DZSectionLockScreen,
    DZSectionReset,
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
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)done {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)prefsChanged {
    // Sliders update their own labels while dragging; only reload rows that
    // other controls can change (switch + preset checkmarks) to keep the
    // slider being dragged from being reset under the finger.
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSetWithIndex:DZSectionPresets];
    [sections addIndex:DZSectionEffect];
    [UIView performWithoutAnimation:^{
        [self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (void)reloadSliders {
    [UIView performWithoutAnimation:^{
        NSMutableIndexSet *s = [NSMutableIndexSet indexSetWithIndex:DZSectionSpeed];
        [s addIndex:DZSectionReverb];
        [s addIndex:DZSectionSing];
        [self.tableView reloadSections:s withRowAnimation:UITableViewRowAnimationNone];
    }];
}

#pragma mark table data

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return DZSectionCount; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case DZSectionEffect: return 1;
        case DZSectionSing: return 1;
        case DZSectionPresets: return (NSInteger)DZAllPresets().count;
        case DZSectionSpeed: return 1;
        case DZSectionReverb: return 3;
        case DZSectionLockScreen: return self.pageTitle ? 0 : 1;   // not in the Playback Controls sheet
        case DZSectionReset: return 1;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case DZSectionSing: return @"Sing";
        case DZSectionPresets: return @"Presets";
        case DZSectionSpeed: return @"Speed";
        case DZSectionReverb: return @"Reverb";
        case DZSectionLockScreen: return self.pageTitle ? nil : @"Lock Screen";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case DZSectionEffect:
            return [NSString stringWithFormat:@"Audio hook: %@", DZAudioBackendDescription()];
        case DZSectionSing:
            return @"Turns down the voice in the centre of the mix; bass, drums and anything panned to the sides stay. "
                   @"Works with or without Slowed + Reverb. Best on studio tracks with a centred lead vocal.";
        case DZSectionSpeed:
            return @"Pitch follows speed, like a turntable: slower is deeper.";
        case DZSectionLockScreen:
            return self.pageTitle ? nil
                : @"Plays Apple Music's motion cover of the album on the lock screen, when it has one. Needs iOS 26; paused in Low Power Mode.";
        case DZSectionReset: {
#ifndef DEEZIT_VERSION
#define DEEZIT_VERSION "dev"
#endif
            return @"Deezit " DEEZIT_VERSION " · github.com/pisknk/Deezit";
        }
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    switch (ip.section) {
        case DZSectionEffect: {
            UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"basic" forIndexPath:ip];
            UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
            cfg.text = @"Slowed + Reverb";
            cfg.image = [UIImage systemImageNamed:@"waveform"];
            c.contentConfiguration = cfg;
            UISwitch *sw = [UISwitch new];
            sw.on = DZPrefBool(kDZEnabled);
            [sw addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            return c;
        }
        case DZSectionPresets: {
            UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"basic" forIndexPath:ip];
            DZPreset *p = DZAllPresets()[ip.row];
            UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
            cfg.text = p.title;
            cfg.secondaryText = [NSString stringWithFormat:@"%.2f× · reverb %d%%", p.speed, (int)lroundf(p.reverbMix * 100)];
            cfg.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            c.contentConfiguration = cfg;
            c.accessoryView = nil;
            c.accessoryType = [DZPrefString(kDZPreset) isEqualToString:p.identifier]
                ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            return c;
        }
        case DZSectionSing:
            return [self sliderCell:tv at:ip title:@"Vocals" key:kDZVocals min:0 max:1
                             format:^NSString *(float v) {
                                 return v >= 0.995f ? @"100% (off)" : [NSString stringWithFormat:@"%d%%", (int)lroundf(v * 100)];
                             }];
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
        case DZSectionLockScreen: {
            UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"basic" forIndexPath:ip];
            UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
            cfg.text = @"Animated album covers";
            cfg.image = [UIImage systemImageNamed:@"lock.rectangle.stack"];
            c.contentConfiguration = cfg;
            UISwitch *sw = [UISwitch new];
            sw.on = DZPrefBool(kDZLockArtwork);
            [sw addTarget:self action:@selector(toggleLockArtwork:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            c.accessoryType = UITableViewCellAccessoryNone;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            return c;
        }
        case DZSectionReset: {
            UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"basic" forIndexPath:ip];
            UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
            cfg.text = @"Reset to defaults";
            cfg.textProperties.color = UIColor.systemRedColor;
            c.contentConfiguration = cfg;
            c.accessoryView = nil;
            c.accessoryType = UITableViewCellAccessoryNone;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
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
    [cell refreshValueLabel];
    DZPrefSetMany(@{ cell.prefKey: @(v), kDZPreset: @"custom" });
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == DZSectionPresets) {
        DZApplyPreset(DZAllPresets()[ip.row]);
        [self reloadSliders];
    } else if (ip.section == DZSectionReset) {
        DZPrefsResetAudio();
        [self reloadSliders];
    }
}

@end
