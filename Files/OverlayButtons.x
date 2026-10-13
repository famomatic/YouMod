#import "Headers.h"

extern BOOL YouModRadioModeActive(void);

static NSString *YouModUpdateSpeedLabel = @"YouModUpdateSpeedLabel";
static NSString *currentSpeedLabel = @"1x";
static float currentPlaybackRate = 1.0;

static NSString *YouModUpdateNotification = @"YouModUpdateNotification";
static NSString *currentQualityLabel = @"Auto";

static NSString *speedLabel(float rate) {
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.minimumFractionDigits = 0;
    formatter.maximumFractionDigits = 2;
    NSString *rateString = [formatter stringFromNumber:[NSNumber numberWithFloat:rate]];
    return [NSString stringWithFormat:@"%@x", rateString];
}

static void didSelectRate(float rate) {
    currentPlaybackRate = rate;
    currentSpeedLabel = speedLabel(rate);
    [[NSNotificationCenter defaultCenter] postNotificationName:YouModUpdateSpeedLabel object:nil];
}

@interface YTMainAppControlsOverlayView ()
- (void)updateQualityButton:(id)arg;
- (void)updateSpeedButton:(id)arg;
// Confirmed present (as selectors) in 21.40.5's string pool but not in
// YouTubeHeader's YTMainAppControlsOverlayView.h - needed to anchor the button-style
// speed stepper under the real previous/pause/next transport buttons.
- (UIButton *)previousButton;
- (UIButton *)nextButton;
- (UIButton *)playPauseButton;
@end

// YouGetCaption (https://github.com/PoomSmart/YouGetCaption)
static void showTranscript(YTFormat3CaptionViewController *cvc) {
    UIView *parent = sbGetNotificationParent();
    MLFormat3Captions *currentCaptions = [cvc valueForKey:@"_currentCaptions"];
    YTIntervalTree *tree = currentCaptions.captions;
    NSMutableString *transcript = [NSMutableString string];
    [tree enumerateAllIntervalsWithBlock:^(YTInterval *interval) {
        MLCaption *caption = (MLCaption *)interval;
        NSArray <MLCaptionSegment *> *segments = caption.segments;
        for (MLCaptionSegment *segment in segments) {
            [transcript appendString:segment.text];
        }
    }];
    if (transcript.length == 0) {
        [SBSkipNotificationView showErrorInView:parent message:LOC(@"NO_CAPTIONS") duration:4.0];
        return;
    }
    YTAlertView *alertView = [%c(YTAlertView) confirmationDialogWithAction:^{
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = transcript;
        [SBSkipNotificationView showSuccessInView:parent message:LOC(@"COPIED_TO_CLIPBOARD") duration:3.0];
    } actionTitle:LOC(@"COPY")];
    alertView.title = nil;
    alertView.subtitle = transcript;
    alertView.shouldDismissOnBackgroundTap = YES;
    [alertView show];
}

#pragma mark - YMOverlayButtonSpec

@implementation YMOverlayButtonSpec
@end

#pragma mark - Registry

// Base of the view-tag range for registered overlay buttons. Chosen to avoid
// colliding with other tagged views in the player overlay (e.g. the seek-bar
// segment markers at 9900).
static const NSInteger YMOverlayButtonBaseTag = 9910;

// Button geometry. The top inset places the row just below YouTube's own
// CC/gear row in the top-right corner of the player overlay.
static const CGFloat YMOverlayButtonSize = 30.0;
static const CGFloat YMOverlayButtonGap = 6.0;
static const CGFloat YMOverlayButtonTopInset = 52.0; // fallback row top when the gear can't be located
static const CGFloat YMOverlayButtonEdgePadding = 12.0; // fallback left/right padding when the gear isn't found
static const CGFloat YMOverlayButtonBottomInset = 60.0; // row bottom-padding for the bottom-anchored corners, clears the scrubber/time labels

static NSMutableArray<YMOverlayButtonSpec *> *gOverlayButtons = nil;
static NSInteger gOverlayButtonNextTag = YMOverlayButtonBaseTag;

void YMRegisterOverlayButton(YMOverlayButtonSpec *spec) {
    if (!spec || spec.identifier.length == 0) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gOverlayButtons = [NSMutableArray array]; });

    // Replace any previous registration with the same identifier (idempotent).
    for (YMOverlayButtonSpec *existing in [gOverlayButtons copy]) {
        if ([existing.identifier isEqualToString:spec.identifier]) {
            spec.viewTag = existing.viewTag;
            [gOverlayButtons removeObject:existing];
        }
    }
    if (spec.viewTag == 0) spec.viewTag = gOverlayButtonNextTag++;
    [gOverlayButtons addObject:spec];
}

NSArray<YMOverlayButtonSpec *> *YMRegisteredOverlayButtons(void) {
    if (!gOverlayButtons) return @[];
    return [gOverlayButtons sortedArrayUsingComparator:^NSComparisonResult(YMOverlayButtonSpec *a, YMOverlayButtonSpec *b) {
        if (a.sortOrder == b.sortOrder) return [a.identifier compare:b.identifier];
        return a.sortOrder < b.sortOrder ? NSOrderedAscending : NSOrderedDescending;
    }];
}

BOOL YMIsOverlayButtonEnabled(NSString *identifier) {
    if (!identifier || identifier.length == 0) return NO;
    if ([identifier isEqualToString:@"download.video"] && !IS_ENABLED(DownloadManager)) return NO;
    if ([identifier isEqualToString:@"sponsorblock.toggle"] && !IS_ENABLED(SBEnabled)) return NO;
    NSArray *savedOrder = [[NSUserDefaults standardUserDefaults] arrayForKey:OverlayButtonOrder];
    if (savedOrder.count > 0) {
        for (NSDictionary *entry in savedOrder) {
            if ([entry[@"id"] isEqualToString:identifier]) {
                return [entry[@"enabled"] boolValue];
            }
        }
        return YES;
    }
    // Fallback migration for legacy keys if custom order is not saved yet
    if ([identifier isEqualToString:@"mute.video"]) return IS_ENABLED(MuteButton);
    if ([identifier isEqualToString:@"speed.video"]) return IS_ENABLED(SpeedButton);
    if ([identifier isEqualToString:@"quality.video"]) return IS_ENABLED(QualityButton);
    if ([identifier isEqualToString:@"share.video"]) return IS_ENABLED(ShareButton);
    if ([identifier isEqualToString:@"loop.video"]) return IS_ENABLED(LoopButton);
    if ([identifier isEqualToString:@"caption.video"]) return IS_ENABLED(CaptionButton);
    if ([identifier isEqualToString:@"download.video"]) return IS_ENABLED(DownloadManager);
    if ([identifier isEqualToString:@"sponsorblock.toggle"]) return IS_ENABLED(SBEnabled) && IS_ENABLED(SBShowButton);
    return YES;
}

NSArray<YMOverlayButtonSpec *> *YMOrderedOverlayButtons(void) {
    if (!gOverlayButtons || gOverlayButtons.count == 0) return @[];

    NSMutableDictionary<NSString *, YMOverlayButtonSpec *> *lookup = [NSMutableDictionary dictionary];
    for (YMOverlayButtonSpec *spec in gOverlayButtons) {
        if (spec.identifier) lookup[spec.identifier] = spec;
    }

    NSArray *savedOrder = [[NSUserDefaults standardUserDefaults] arrayForKey:OverlayButtonOrder];
    NSMutableArray<YMOverlayButtonSpec *> *ordered = [NSMutableArray array];

    if (savedOrder.count > 0) {
        for (NSDictionary *entry in savedOrder) {
            NSString *ident = entry[@"id"];
            BOOL enabled = [entry[@"enabled"] boolValue];
            if (!enabled) continue;
            YMOverlayButtonSpec *spec = lookup[ident];
            if (spec) [ordered addObject:spec];
        }
        // Append any registered specs not present in savedOrder
        for (YMOverlayButtonSpec *spec in YMRegisteredOverlayButtons()) {
            BOOL found = NO;
            for (NSDictionary *entry in savedOrder) {
                if ([entry[@"id"] isEqualToString:spec.identifier]) {
                    found = YES;
                    break;
                }
            }
            if (!found) {
                [ordered addObject:spec];
            }
        }
    } else {
        for (YMOverlayButtonSpec *spec in YMRegisteredOverlayButtons()) {
            if (YMIsOverlayButtonEnabled(spec.identifier)) {
                [ordered addObject:spec];
            }
        }
    }

    return ordered;
}

#pragma mark - Helpers

// The player view controller that owns this controls overlay, reached through the
// overlay's events delegate. Button handlers use it to act on the current video.
static YTPlayerViewController *YMPlayerVCFromOverlay(YTMainAppControlsOverlayView *overlay) {
    YTMainAppVideoPlayerOverlayViewController *mainOverlayController = (YTMainAppVideoPlayerOverlayViewController *)overlay.eventsDelegate;
    return mainOverlayController.parentViewController;
}

// Recursively find the right-most YTQTMButton in the overlay's top region. YouTube
// nests the gear/CC/cast buttons inside a container, so a one-level scan would miss
// them; recursion reaches the nested buttons wherever they sit.
static void YMScanForGearFrame(UIView *view, YTMainAppControlsOverlayView *overlay, CGFloat topRegionMaxY, CGRect *bestFrame) {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:%c(YTQTMButton)]) {
            CGRect f = [sub convertRect:sub.bounds toView:overlay];
            if (CGRectGetMidY(f) <= topRegionMaxY) { // in the top button row
                // The CGRectIsNull check must stay first: CGRectGetMidX(CGRectNull) is
                // infinite, so the > comparison alone would never accept the first match.
                if (CGRectIsNull(*bestFrame) || CGRectGetMidX(f) > CGRectGetMidX(*bestFrame)) *bestFrame = f;
            }
        }
        YMScanForGearFrame(sub, overlay, topRegionMaxY, bestFrame);
    }
}

// Find YouTube's settings/overflow button so we can anchor our row directly beneath it.
// Prefer the overlay's own overflowButton; otherwise take the right-most YTQTMButton in
// the overlay's top region. Returns its frame in the overlay's coordinate space, or
// CGRectNull if not found (the caller then falls back to the screen edge / top inset).
static CGRect YMGearFrameInOverlay(YTMainAppControlsOverlayView *overlay) {
    YTQTMButton *overflow = [overlay valueForKey:@"_overflowButton"];
    if (overflow.window) {
        return [overflow convertRect:overflow.bounds toView:overlay];
    }

    CGFloat topRegionMaxY = overlay.bounds.size.height * 0.25;
    CGRect bestFrame = CGRectNull;
    YMScanForGearFrame(overlay, overlay, topRegionMaxY, &bestFrame);
    return bestFrame;
}

// The font for a text button's label, in YouTube Sans to match native controls,
// with a plain system-font fallback on versions lacking the YouTube Sans style API.
// Fixed size on purpose: the previous version shrank this to fit a fixed 25x25 box,
// but realistic labels ("1080p60", "0.25x", every value the fine-step speed slider
// can land on) don't fit any legible size in a box that small - the fit loop fell
// through to its no-fit-found default, clipped against numberOfLines:2 +
// lineBreakByClipping, and the label rendered as nothing at all. Keeping the font
// fixed and sizing the button to the text (YMOverlayTextButtonWidthForText below)
// fixes this for every text-style overlay button, not just speed.
static const CGFloat YMOverlayTextButtonFontSize = 13.0;

static UIFont *YMOverlayTextButtonFont(void) {
    YTDefaultTypeStyle *typeStyle = [%c(YTTypeStyle) defaultTypeStyle];
    BOOL hasYTFont = [typeStyle respondsToSelector:@selector(ytSansFontOfSize:weight:)];
    return hasYTFont ? [typeStyle ytSansFontOfSize:YMOverlayTextButtonFontSize weight:UIFontWeightSemibold] : [UIFont systemFontOfSize:YMOverlayTextButtonFontSize weight:UIFontWeightSemibold];
}

// How wide a text button needs to be to show `text` in full, at the fixed font
// above, never narrower than the square icon buttons so the row stays aligned.
static CGFloat YMOverlayTextButtonWidthForText(NSString *text) {
    if (text.length == 0) return YMOverlayButtonSize;
    CGRect rect = [text boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, YMOverlayButtonSize)
                                     options:NSStringDrawingUsesLineFragmentOrigin
                                  attributes:@{NSFontAttributeName: YMOverlayTextButtonFont()}
                                     context:nil];
    return MAX(YMOverlayButtonSize, ceil(rect.size.width) + 12.0); // +12 = 6pt horizontal padding per side
}

static YTQTMButton *YMCreateOverlayButton(YTMainAppControlsOverlayView *overlay, YMOverlayButtonSpec *spec) {
    YTQTMButton *button;
    UIColor *tint = spec.tintColor ?: [UIColor whiteColor];

    if (spec.title.length > 0) {
        // Text button: a label instead of an icon. customTitleColor is YTQTMButton's
        // own text-colour channel; sizeWithPaddingAndInsets is disabled so the width
        // stays fixed rather than expanding to fit the text.
        button = [%c(YTQTMButton) textButton];
        [button setTitle:spec.title forState:UIControlStateNormal];
        button.customTitleColor = tint;
        button.titleLabel.font = YMOverlayTextButtonFont();
        button.titleLabel.textAlignment = NSTextAlignmentCenter;
        button.sizeWithPaddingAndInsets = NO;
        button.titleLabel.numberOfLines = 1;
        button.titleLabel.adjustsFontSizeToFitWidth = NO;
        button.titleLabel.lineBreakMode = NSLineBreakByClipping;
        button.titleLabel.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
        button.contentEdgeInsets = UIEdgeInsetsZero;
        button.titleEdgeInsets = UIEdgeInsetsZero;
        button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    } else {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
        // Template rendering so YTQTMButton's tint colours the glyph reliably.
        UIImage *icon = [[UIImage systemImageNamed:spec.symbolName withConfiguration:config] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        button = [%c(YTQTMButton) iconButton];
        [button setImage:icon forState:UIControlStateNormal];
        button.tintColor = tint;
        button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    }

    button.exclusiveTouch = YES;
    button.tag = spec.viewTag;
    // The row's frame is assigned authoritatively in layoutSubviews.
    button.frame = CGRectMake(0, 0, YMOverlayButtonSize, YMOverlayButtonSize);
    [button enableNewTouchFeedback];
    [button addTarget:overlay action:@selector(ymOverlayButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [overlay addSubview:button];
    return button;
}

#pragma mark - Persistent speed stepper (button-style, under prev/pause/next)
// The other uYouEnhanced look: small "-"/"+" step buttons directly under the real
// previousButton/nextButton, and a small text readout under playPauseButton - not a
// slider at all. Selectable in Settings against the slider popup further below
// (SpeedControlStyle), since they're alternatives, not both at once.

static const NSInteger YMSpeedStepperMinusTag = 9906;
static const NSInteger YMSpeedStepperPlusTag = 9907;
static const NSInteger YMSpeedStepperTextTag = 9908;
static const CGFloat YMSpeedStepperButtonSize = 28.0; // a little smaller than the main 30pt overlay buttons
static const CGFloat YMSpeedStepperTextMinWidth = 52.0;
static const CGFloat YMSpeedStepperTextHeight = 24.0;
static const CGFloat YMSpeedStepperGapBelowTransport = 4.0;
static const float YMSpeedStepperStep = 0.05;

// Same translucent dark backdrop as the overlay buttons at the top of the player,
// so the stepper stays readable over bright video.
static UIColor *YMSpeedStepperBackgroundColor(void) {
    return [UIColor colorWithWhite:0.0 alpha:0.45];
}

static UIButton *YMCreateSpeedStepperButton(YTMainAppControlsOverlayView *overlay, NSInteger tag, NSString *symbolName, SEL action) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
    UIImage *icon = [[UIImage systemImageNamed:symbolName withConfiguration:config] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = tag;
    [button setImage:icon forState:UIControlStateNormal];
    button.tintColor = [UIColor whiteColor];
    button.backgroundColor = YMSpeedStepperBackgroundColor();
    button.layer.cornerRadius = YMSpeedStepperButtonSize / 2.0;
    button.clipsToBounds = YES;
    button.exclusiveTouch = YES;
    [button addTarget:overlay action:action forControlEvents:UIControlEventTouchUpInside];
    [overlay addSubview:button];
    return button;
}

static UIView *YMOverlayTransportView(UIView *overlay, NSString *ivarKey, NSString *propKey) {
    for (NSString *key in @[ivarKey, propKey]) {
        @try {
            id v = [overlay valueForKey:key];
            if ([v isKindOfClass:[UIView class]] && ((UIView *)v).window) return v;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

// Positions the -/+/text trio under YouTube's own previous/pause/next buttons.
static void YMLayoutSpeedStepper(YTMainAppControlsOverlayView *overlay, BOOL shouldBeVisible) {
    UIButton *minusBtn = (UIButton *)[overlay viewWithTag:YMSpeedStepperMinusTag];
    UIButton *plusBtn = (UIButton *)[overlay viewWithTag:YMSpeedStepperPlusTag];
    YTLabel *textLabel = (YTLabel *)[overlay viewWithTag:YMSpeedStepperTextTag];

    BOOL enabled = IS_ENABLED(ShowSpeedSlider) && INTFORVAL(SpeedControlStyle) == 1;
    if (!enabled || !shouldBeVisible) {
        minusBtn.hidden = YES;
        plusBtn.hidden = YES;
        textLabel.hidden = YES;
        return;
    }
    // The overlay has no previousButton/nextButton/playPauseButton *properties* in 21.40.5 -
    // the respondsToSelector: check that used to be here always failed, which is why the
    // stepper never appeared. The real storage is the ivars _previousButtonView,
    // _nextButtonView (YTTransportControlsButtonView) and _playPauseButton (YTPlaybackButton),
    // the same ones uYouEnhanced reaches with MSHookIvar. Fall back to scanning for those
    // classes, then to fixed positions around the overlay centre, so something always shows.
    UIView *prevView = YMOverlayTransportView(overlay, @"_previousButtonView", @"previousButton");
    UIView *nextView = YMOverlayTransportView(overlay, @"_nextButtonView", @"nextButton");
    UIView *playView = YMOverlayTransportView(overlay, @"_playPauseButton", @"playPauseButton");

    CGRect b = overlay.bounds;
    CGRect prevFrame = CGRectMake(CGRectGetMidX(b) - 100, CGRectGetMidY(b) - 20, 40, 40);
    CGRect nextFrame = CGRectMake(CGRectGetMidX(b) + 60, CGRectGetMidY(b) - 20, 40, 40);
    CGRect playPauseFrame = CGRectMake(CGRectGetMidX(b) - 20, CGRectGetMidY(b) - 20, 40, 40);
    if (prevView.window) prevFrame = [prevView convertRect:prevView.bounds toView:overlay];
    if (nextView.window) nextFrame = [nextView convertRect:nextView.bounds toView:overlay];
    if (playView.window) playPauseFrame = [playView convertRect:playView.bounds toView:overlay];

    if (!minusBtn) minusBtn = YMCreateSpeedStepperButton(overlay, YMSpeedStepperMinusTag, @"minus", @selector(ymSpeedStepperMinusTapped:));
    if (!plusBtn) plusBtn = YMCreateSpeedStepperButton(overlay, YMSpeedStepperPlusTag, @"plus", @selector(ymSpeedStepperPlusTapped:));
    if (!textLabel) {
        textLabel = [%c(YTLabel) new];
        textLabel.tag = YMSpeedStepperTextTag;
        textLabel.textAlignment = NSTextAlignmentCenter;
        textLabel.textColor = [UIColor whiteColor];
        textLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        textLabel.backgroundColor = YMSpeedStepperBackgroundColor();
        textLabel.layer.cornerRadius = YMSpeedStepperTextHeight / 2.0;
        textLabel.clipsToBounds = YES;
        textLabel.userInteractionEnabled = YES;
        [textLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:overlay action:@selector(ymSpeedStepperTextTapped:)]];
        [overlay addSubview:textLabel];
    }

    minusBtn.hidden = NO;
    plusBtn.hidden = NO;
    textLabel.hidden = NO;
    textLabel.text = currentSpeedLabel;

    // One row for all three: centred on a single line below the lowest transport
    // button (play/pause is taller than previous/next, so per-button offsets left
    // the row uneven). Horizontally each piece stays under its own button.
    CGFloat transportBottom = MAX(CGRectGetMaxY(playPauseFrame), MAX(CGRectGetMaxY(prevFrame), CGRectGetMaxY(nextFrame)));
    CGFloat rowCenterY = round(transportBottom + YMSpeedStepperGapBelowTransport + YMSpeedStepperButtonSize / 2.0);
    minusBtn.frame = CGRectMake(round(CGRectGetMidX(prevFrame) - YMSpeedStepperButtonSize / 2.0),
                               rowCenterY - YMSpeedStepperButtonSize / 2.0,
                               YMSpeedStepperButtonSize, YMSpeedStepperButtonSize);
    plusBtn.frame = CGRectMake(round(CGRectGetMidX(nextFrame) - YMSpeedStepperButtonSize / 2.0),
                              rowCenterY - YMSpeedStepperButtonSize / 2.0,
                              YMSpeedStepperButtonSize, YMSpeedStepperButtonSize);
    // Pill sized to the readout, on the same centre line.
    CGFloat textWidth = MAX(YMSpeedStepperTextMinWidth, ceil([textLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, YMSpeedStepperTextHeight)].width) + 16.0);
    textLabel.frame = CGRectMake(round(CGRectGetMidX(playPauseFrame) - textWidth / 2.0),
                                 rowCenterY - YMSpeedStepperTextHeight / 2.0,
                                 textWidth, YMSpeedStepperTextHeight);
    [overlay bringSubviewToFront:minusBtn];
    [overlay bringSubviewToFront:plusBtn];
    [overlay bringSubviewToFront:textLabel];
}

#pragma mark - Custom slider-based speed picker (ported from uYouEnhanced's YouSpeed)
// This is the other uYouEnhanced look: the speed.video overlay button (registered
// below) shows the current rate as text, same as every other overlay button. What
// YouSpeed actually adds is this:
// tapping it replaces YouTube's own preset-only speed picker with a popup holding a
// slider plus minus/plus/preset buttons, gated by ShowSpeedSlider.

static const float YMSpeedMin = 0.25;

@interface YouModSpeedAlertView : YTAlertView
- (void)ymSetupViews:(YTMainAppVideoPlayerOverlayViewController *)delegate sliderLabel:(NSString *)sliderLabel;
@end

// %new methods are defined further below inside the YTMainAppVideoPlayerOverlayViewController
// hook, but the alert's button targets call them directly (not via selector/target-action
// dispatch), so the compiler needs them declared here ahead of that definition.
@interface YTMainAppVideoPlayerOverlayViewController (YouModSpeed)
- (void)ymDidChangePlaybackSpeed:(MDCSlider *)s;
- (void)ymDidPressSpeedMinusButton:(YTQTMButton *)button;
- (void)ymDidPressSpeedPlusButton:(YTQTMButton *)button;
- (void)ymDidPressSpeedPresetButton:(YTQTMButton *)button;
@end

%subclass YouModSpeedAlertView : YTAlertView

%new
- (void)ymSetupViews:(YTMainAppVideoPlayerOverlayViewController *)delegate sliderLabel:(NSString *)sliderLabel {
    CGSize labelSize = CGSizeMake(50, 20);
    CGSize adjustButtonSize = CGSizeMake(30, 30);
    CGSize presetButtonSize = CGSizeMake(50, 30);
    float sliderMax = IS_ENABLED(ExtraSpeed) ? 10.0 : 2.0;
    UIColor *textColor = [UIColor labelColor];
    UIColor *adjustBg = [UIColor colorWithWhite:0.5 alpha:0.2];

    MDCSlider *slider = [%c(MDCSlider) new];
    slider.statefulAPIEnabled = YES;
    slider.thumbHollowAtStart = NO;
    slider.minimumValue = YMSpeedMin;
    slider.maximumValue = sliderMax;
    slider.value = currentPlaybackRate;
    slider.continuous = NO;
    slider.accessibilityLabel = sliderLabel;
    slider.tag = 'slid';
    slider.color = textColor;
    [slider setThumbColor:textColor forState:UIControlStateNormal];
    [slider setTrackFillColor:textColor forState:UIControlStateNormal];
    [slider setTrackBackgroundColor:adjustBg forState:UIControlStateNormal];

    YTLabel *minLabel = [%c(YTLabel) new];
    minLabel.text = speedLabel(YMSpeedMin);
    minLabel.textAlignment = NSTextAlignmentLeft;
    minLabel.textColor = textColor;
    minLabel.tag = 'minl';
    [minLabel yt_setSize:labelSize];

    YTLabel *maxLabel = [%c(YTLabel) new];
    maxLabel.text = speedLabel(sliderMax);
    maxLabel.textAlignment = NSTextAlignmentRight;
    maxLabel.textColor = textColor;
    maxLabel.tag = 'maxl';
    [maxLabel yt_setSize:labelSize];

    YTLabel *currentValueLabel = [%c(YTLabel) new];
    currentValueLabel.text = currentSpeedLabel;
    currentValueLabel.textAlignment = NSTextAlignmentCenter;
    currentValueLabel.textColor = textColor;
    currentValueLabel.tag = 'cvl0';
    [currentValueLabel yt_setSize:labelSize];

    UIImage *minusImage = [[UIImage systemImageNamed:@"minus"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    YTQTMButton *minusButton = [%c(YTQTMButton) buttonWithImage:minusImage accessibilityLabel:@"Decrease playback speed" accessibilityIdentifier:@"playback.speed.minus"];
    minusButton.flatButtonHasOpaqueBackground = YES;
    minusButton.enabledBackgroundColor = adjustBg;
    minusButton.tintColor = textColor;
    minusButton.sizeWithPaddingAndInsets = YES;
    minusButton.tag = 'mbtn';
    [minusButton yt_setSize:adjustButtonSize];
    [minusButton addTarget:delegate action:@selector(ymDidPressSpeedMinusButton:) forControlEvents:UIControlEventTouchUpInside];

    UIImage *plusImage = [[UIImage systemImageNamed:@"plus"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    YTQTMButton *plusButton = [%c(YTQTMButton) buttonWithImage:plusImage accessibilityLabel:@"Increase playback speed" accessibilityIdentifier:@"playback.speed.plus"];
    plusButton.flatButtonHasOpaqueBackground = YES;
    plusButton.enabledBackgroundColor = adjustBg;
    plusButton.tintColor = textColor;
    plusButton.sizeWithPaddingAndInsets = YES;
    plusButton.tag = 'pbtn';
    [plusButton yt_setSize:adjustButtonSize];
    [plusButton addTarget:delegate action:@selector(ymDidPressSpeedPlusButton:) forControlEvents:UIControlEventTouchUpInside];

    struct { NSInteger tag; NSString *title; } presetSpeedConfigs[] = {
        {'s025', @"0.25x"}, {'s050', @"0.5x"}, {'s100', @"1x"}, {'s150', @"1.5x"}, {'s200', @"2x"},
    };
    NSUInteger presetCount = sizeof(presetSpeedConfigs) / sizeof(presetSpeedConfigs[0]);
    NSMutableArray<YTQTMButton *> *presetButtons = [NSMutableArray arrayWithCapacity:presetCount];
    for (NSUInteger i = 0; i < presetCount; i++) {
        YTQTMButton *button = [%c(YTQTMButton) textButton];
        button.flatButtonHasOpaqueBackground = YES;
        button.enabledBackgroundColor = adjustBg;
        button.customTitleColor = textColor;
        button.sizeWithPaddingAndInsets = NO;
        button.tag = presetSpeedConfigs[i].tag;
        [button yt_setSize:presetButtonSize];
        [button setTitle:presetSpeedConfigs[i].title forState:UIControlStateNormal];
        [button addTarget:delegate action:@selector(ymDidPressSpeedPresetButton:) forControlEvents:UIControlEventTouchUpInside];
        [presetButtons addObject:button];
    }

    CGFloat contentWidth = [%c(YTCommonUtils) isIPad] ? 350 : 250;
    UIView *contentView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, contentWidth, 120)];
    [contentView addSubview:slider];
    [contentView addSubview:minLabel];
    [contentView addSubview:maxLabel];
    [contentView addSubview:currentValueLabel];
    [contentView addSubview:minusButton];
    [contentView addSubview:plusButton];
    for (YTQTMButton *button in presetButtons) [contentView addSubview:button];

    CGFloat sliderWidth = contentWidth - 80;
    slider.frame = CGRectMake(0, 0, sliderWidth, adjustButtonSize.height);
    [slider addTarget:delegate action:@selector(ymDidChangePlaybackSpeed:) forControlEvents:UIControlEventValueChanged];

    [slider alignCenterTopToCenterTopOfView:contentView paddingY:0];
    [minLabel alignTopLeadingToBottomLeadingOfView:slider paddingX:0 paddingY:10];
    [maxLabel alignTopTrailingToBottomTrailingOfView:slider paddingX:0 paddingY:10];
    [currentValueLabel alignCenterTopToCenterBottomOfView:slider paddingY:10];
    [minusButton alignCenterTrailingToCenterLeadingOfView:slider paddingX:10];
    [plusButton alignCenterLeadingToCenterTrailingOfView:slider paddingX:10];

    CGFloat padding = (contentWidth - (presetButtonSize.width * presetCount)) / (presetCount - 1);
    CGFloat buttonY = currentValueLabel.frame.origin.y + currentValueLabel.frame.size.height + 15;
    for (NSUInteger i = 0; i < presetButtons.count; i++) {
        [presetButtons[i] yt_setOrigin:CGPointMake(i * (padding + presetButtonSize.width), buttonY)];
    }

    self.customContentView = contentView;
}

%end

static YouModSpeedAlertView *ymSpeedAlert = nil;

%hook YTMainAppVideoPlayerOverlayViewController

- (void)didPressVarispeed:(id)arg1 {
    if (!IS_ENABLED(ShowSpeedSlider) || INTFORVAL(SpeedControlStyle) != 0) {
        %orig;
        return;
    }
    ymSpeedAlert = [%c(YouModSpeedAlertView) infoDialog];
    [ymSpeedAlert ymSetupViews:self sliderLabel:LOC(@"SPEED_BUTTON")];
    ymSpeedAlert.title = LOC(@"SPEED_BUTTON");
    ymSpeedAlert.shouldDismissOnBackgroundTap = YES;
    ymSpeedAlert.customContentViewInsets = UIEdgeInsetsMake(8, 0, 0, 0);
    [ymSpeedAlert addTitle:LOC(@"CHOOSE_FROM_ORIGINAL") withCancelAction:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            %orig;
        });
    }];
    [ymSpeedAlert show];
}

%new
- (void)ymDidChangePlaybackSpeed:(MDCSlider *)s {
    float rate = s.value;
    [(id<YTVarispeedSwitchControllerDelegate>)self.delegate varispeedSwitchController:nil didSelectRate:rate];
    YTLabel *currentValueLabel = [s.superview viewWithTag:'cvl0'];
    currentValueLabel.text = currentSpeedLabel;
}

%new
- (void)ymDidPressSpeedMinusButton:(YTQTMButton *)button {
    MDCSlider *slider = [button.superview viewWithTag:'slid'];
    float newValue = MAX(slider.minimumValue, slider.value - 0.05);
    [slider setValue:newValue animated:YES];
    [self ymDidChangePlaybackSpeed:slider];
}

%new
- (void)ymDidPressSpeedPlusButton:(YTQTMButton *)button {
    MDCSlider *slider = [button.superview viewWithTag:'slid'];
    float newValue = MIN(slider.maximumValue, slider.value + 0.05);
    [slider setValue:newValue animated:YES];
    [self ymDidChangePlaybackSpeed:slider];
}

%new
- (void)ymDidPressSpeedPresetButton:(YTQTMButton *)button {
    MDCSlider *slider = [button.superview viewWithTag:'slid'];
    float newValue = 1.0;
    switch (button.tag) {
        case 's025': newValue = 0.25; break;
        case 's050': newValue = 0.5; break;
        case 's100': newValue = 1.0; break;
        case 's150': newValue = 1.5; break;
        case 's200': newValue = 2.0; break;
    }
    slider.value = newValue;
    [self ymDidChangePlaybackSpeed:slider];
    [ymSpeedAlert dismiss];
    ymSpeedAlert = nil;
}

%end

#pragma mark - YTMainAppControlsOverlayView Hook

static BOOL isRelatedVideosExpanded = NO;

%hook YTMainAppControlsOverlayView

- (void)layoutSubviews {
    %orig;
    NSArray<YMOverlayButtonSpec *> *allRegistered = YMRegisteredOverlayButtons();
    NSArray<YMOverlayButtonSpec *> *specs = YMOrderedOverlayButtons();

    NSMutableSet<NSNumber *> *activeTags = [NSMutableSet set];
    for (YMOverlayButtonSpec *spec in specs) {
        [activeTags addObject:@(spec.viewTag)];
    }
    for (YMOverlayButtonSpec *spec in allRegistered) {
        if (![activeTags containsObject:@(spec.viewTag)]) {
            UIView *btn = [self viewWithTag:spec.viewTag];
            if (btn) [btn removeFromSuperview];
        }
    }

    if (specs.count == 0) {
        YMLayoutSpeedStepper(self, self.isOverlayVisible && !isRelatedVideosExpanded);
        return;
    }

    YTPlayerViewController *player = YMPlayerVCFromOverlay(self);
    YTSingleVideoController *sgvid = player.activeVideo;
    YTSingleVideo *sgvid2 = sgvid.singleVideo;
    BOOL isLive = [sgvid2 isLivePlayback];
    BOOL overlayVisible = self.isOverlayVisible;

    // YTLite-style corner anchoring: 0=top-right(default) 1=top-left 2=bottom-right 3=bottom-left.
    // Only the default top-right corner tracks YouTube's own gear button; the other three are
    // plain edge-anchored since there's no equivalent native landmark in those corners.
    NSInteger corner = [[NSUserDefaults standardUserDefaults] objectForKey:OverlayButtonCorner] ? (NSInteger)[[NSUserDefaults standardUserDefaults] integerForKey:OverlayButtonCorner] : 0;
    BOOL anchorRight = (corner == 0 || corner == 2);
    BOOL anchorBottom = (corner == 2 || corner == 3);
    // growRightward mirrors the row's growth direction: trailing-right rows grow leftward from
    // their anchor, leading-left rows grow rightward from theirs.
    BOOL growRightward = !anchorRight;

    CGFloat anchorCenterX;
    CGFloat rowTop;
    if (corner == 0) {
        CGRect gearFrame = YMGearFrameInOverlay(self);
        BOOL hasGear = !CGRectIsNull(gearFrame);
        anchorCenterX = hasGear ? CGRectGetMidX(gearFrame) : self.bounds.size.width - YMOverlayButtonEdgePadding - YMOverlayButtonSize / 2.0;
        rowTop = hasGear ? CGRectGetMaxY(gearFrame) : YMOverlayButtonTopInset;
    } else {
        anchorCenterX = anchorRight ? (self.bounds.size.width - YMOverlayButtonEdgePadding - YMOverlayButtonSize / 2.0)
                                     : (YMOverlayButtonEdgePadding + YMOverlayButtonSize / 2.0);
        rowTop = anchorBottom ? (self.bounds.size.height - YMOverlayButtonBottomInset - YMOverlayButtonSize)
                               : YMOverlayButtonTopInset;
    }
    // Lets the whole row be nudged left/right/up/down from Settings, since the
    // corner-anchored default spot isn't always where every layout wants it.
    anchorCenterX += FLOAT_FOR_KEY(OverlayButtonOffsetX);
    rowTop += FLOAT_FOR_KEY(OverlayButtonOffsetY);
    CGFloat prevHalfWidth = 0;
    CGFloat growDirection = growRightward ? 1.0 : -1.0;

    for (YMOverlayButtonSpec *spec in specs) {
        BOOL isHiddenOnLive = isLive && ([spec.identifier isEqualToString:@"sponsorblock.toggle"] ||
                                         [spec.identifier isEqualToString:@"loop.video"] ||
                                         [spec.identifier isEqualToString:@"caption.video"]);
        BOOL visible = !isHiddenOnLive && ((spec.isVisible == nil) || spec.isVisible(player));
        YTQTMButton *btn = (YTQTMButton *)[self viewWithTag:spec.viewTag];

        if (!visible) {
            if (btn) [btn removeFromSuperview];
            continue;
        }
        if (!btn) btn = YMCreateOverlayButton(self, spec);

        btn.hidden = !overlayVisible || isRelatedVideosExpanded;

        if (spec.tintProvider) {
            UIColor *dynamic = spec.tintProvider(player);
            if (spec.title.length > 0) btn.customTitleColor = dynamic;
            else btn.tintColor = dynamic;
        }

        CGFloat width = (spec.title.length > 0) ? YMOverlayTextButtonWidthForText(spec.title) : YMOverlayButtonSize;
        CGFloat centerX = (prevHalfWidth == 0) ? anchorCenterX : anchorCenterX + growDirection * (prevHalfWidth + YMOverlayButtonGap + width / 2.0);

        btn.frame = CGRectMake(centerX - width / 2.0, rowTop, width, YMOverlayButtonSize);
        anchorCenterX = centerX;
        prevHalfWidth = width / 2.0;
        [self bringSubviewToFront:btn];
    }

    YMLayoutSpeedStepper(self, overlayVisible && !isRelatedVideosExpanded);
}

- (void)setOverlayVisible:(BOOL)visible {
    %orig;
    for (YMOverlayButtonSpec *spec in YMRegisteredOverlayButtons()) {
        YTQTMButton *btn = (YTQTMButton *)[self viewWithTag:spec.viewTag];
        if (btn) btn.hidden = !visible || isRelatedVideosExpanded;
    }
    YMLayoutSpeedStepper(self, visible && !isRelatedVideosExpanded);
}

%new
- (void)ymOverlayButtonTapped:(YTQTMButton *)sender {
    YMOverlayButtonSpec *matched = nil;
    for (YMOverlayButtonSpec *spec in YMRegisteredOverlayButtons()) {
        if (spec.viewTag == sender.tag) { matched = spec; break; }
    }
    if (!matched || !matched.onTap) return;

    YTPlayerViewController *player = YMPlayerVCFromOverlay(self);
    matched.onTap(player, sender);
}

%new
- (void)ymUpdateOverlayButtons:(id)arg {
    [self setNeedsLayout];
}

- (id)initWithDelegate:(id)delegate {
    self = %orig;
    [self updateSpeedButton:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateSpeedButton:) name:YouModUpdateSpeedLabel object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateQualityButton:) name:YouModUpdateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ymUpdateOverlayButtons:) name:@"YouModUpdateOverlayButtons" object:nil];
    return self;
}

- (id)initWithDelegate:(id)delegate autoplaySwitchEnabled:(BOOL)autoplaySwitchEnabled {
    self = %orig;
    [self updateSpeedButton:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateSpeedButton:) name:YouModUpdateSpeedLabel object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateQualityButton:) name:YouModUpdateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ymUpdateOverlayButtons:) name:@"YouModUpdateOverlayButtons" object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:YouModUpdateSpeedLabel object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:YouModUpdateNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"YouModUpdateOverlayButtons" object:nil];
    %orig;
}

%new
- (void)updateSpeedButton:(id)arg {
    for (YMOverlayButtonSpec *spec in YMRegisteredOverlayButtons()) {
        if ([spec.identifier isEqualToString:@"speed.video"]) {
            spec.title = currentSpeedLabel;

            YTQTMButton *btn = (YTQTMButton *)[self viewWithTag:spec.viewTag];
            if (btn) {
                [btn setTitle:currentSpeedLabel forState:UIControlStateNormal];
                // The label's width can change ("1x" -> "1.75x"), which shifts every
                // other button in the row, so re-run the whole row layout rather than
                // just this button's frame.
                [self setNeedsLayout];
            }
            break;
        }
    }

    YTLabel *stepperText = (YTLabel *)[self viewWithTag:YMSpeedStepperTextTag];
    if (stepperText) stepperText.text = currentSpeedLabel;
}

%new
- (void)updateQualityButton:(id)arg {
    for (YMOverlayButtonSpec *spec in YMRegisteredOverlayButtons()) {
        if ([spec.identifier isEqualToString:@"quality.video"]) {
            spec.title = currentQualityLabel;

            YTQTMButton *btn = (YTQTMButton *)[self viewWithTag:spec.viewTag];
            if (btn) {
                [btn setTitle:currentQualityLabel forState:UIControlStateNormal];
                [self setNeedsLayout];
            }
            break;
        }
    }
}

%new
- (void)ymSpeedStepperMinusTapped:(UIButton *)sender {
    YTPlayerViewController *player = YMPlayerVCFromOverlay(self);
    float newRate = MAX(YMSpeedMin, currentPlaybackRate - YMSpeedStepperStep);
    [player setPlaybackRate:newRate];
}

%new
- (void)ymSpeedStepperPlusTapped:(UIButton *)sender {
    YTPlayerViewController *player = YMPlayerVCFromOverlay(self);
    float sliderMax = IS_ENABLED(ExtraSpeed) ? 10.0 : 2.0;
    float newRate = MIN(sliderMax, currentPlaybackRate + YMSpeedStepperStep);
    [player setPlaybackRate:newRate];
}

%new
- (void)ymSpeedStepperTextTapped:(UITapGestureRecognizer *)gesture {
    YTPlayerViewController *player = YMPlayerVCFromOverlay(self);
    YTMainAppVideoPlayerOverlayViewController *ovcon = [player activeVideoPlayerOverlay];
    [ovcon didPressVarispeed:gesture.view];
}
%end

%hook YTRelatedVideosViewController
- (void)setExpanded:(BOOL)arg {
    %orig;
    isRelatedVideosExpanded = arg;
    YTRelatedVideosView *relatedview = (YTRelatedVideosView *)self.view;
    YTFullscreenEngagementOverlayView *fullov = (YTFullscreenEngagementOverlayView *)relatedview.superview;
    YTMainAppVideoPlayerOverlayView *mainov = (YTMainAppVideoPlayerOverlayView *)fullov.superview;
    YTMainAppControlsOverlayView *conov = [mainov controlsOverlayView];
    [conov setNeedsLayout];
}
%end

static void YouModShowShareNotification(NSString *message, BOOL success) {
    UIView *parent = sbGetNotificationParent();
    if (success) {
        [SBSkipNotificationView showSuccessInView:parent message:message duration:3.0];
    } else {
        [SBSkipNotificationView showErrorInView:parent message:message duration:4.0];
    }
}

%hook YTPlayerViewController
%new
- (void)YouModShareButton:(UIView *)sourceView {
    if (!self.currentVideoID) {
        YouModShowShareNotification(LOC(@"ERROR_VIDEOID"), NO);
        return;
    } else if (self.isPlayingAd) {
        YouModShowShareNotification(LOC(@"ERROR_ADS"), NO);
        return;
    }

    NSString *videoURL = [NSString stringWithFormat:@"https://youtube.com/watch?v=%@", self.currentVideoID];
    NSInteger seconds = (NSInteger)floor(self.currentVideoMediaTime);
    NSString *timestampURL = [NSString stringWithFormat:@"%@&t=%lds", videoURL, (long)seconds];

    UIViewController *presenter = (UIViewController *)[self activeVideoPlayerOverlay];
    YTDefaultSheetController *sheet = [%c(YTDefaultSheetController) sheetControllerWithParentResponder:presenter];

    YTActionSheetAction *copyURL = [%c(YTActionSheetAction) actionWithTitle:LOC(@"COPY_URL") iconImage:YouModYTIconImage(250, NO, nil) style:0 handler:^(__unused YTActionSheetAction *action) {
        UIPasteboard.generalPasteboard.string = videoURL;
        YouModShowShareNotification(LOC(@"URL_COPIED"), YES);
    }];

    YTActionSheetAction *copyTimestamp = [%c(YTActionSheetAction) actionWithTitle:LOC(@"COPY_URL_TIMESTAMP") iconImage:YouModYTIconImage(250, NO, nil) style:0 handler:^(__unused YTActionSheetAction *action) {
        UIPasteboard.generalPasteboard.string = timestampURL;
        YouModShowShareNotification(LOC(@"URL_TIMESTAMP_COPIED"), YES);
    }];

    [sheet addAction:copyURL];
    [sheet addAction:copyTimestamp];

    [sheet presentFromView:sourceView animated:YES completion:nil];
}
%new
- (void)YouModLoopButton {
    YTMainAppVideoPlayerOverlayViewController *playerOverlay = self.activeVideoPlayerOverlay;
    YTAutoplayAutonavController *autoplayController = [playerOverlay valueForKey:@"_autonavController"];
    BOOL isLoopEnabled = !IS_ENABLED(KeepLoopKey);
    [[NSUserDefaults standardUserDefaults] setBool:isLoopEnabled forKey:KeepLoopKey];
    [autoplayController setLoopMode:isLoopEnabled ? 2 : 0];
    YouModShowShareNotification(LOC(isLoopEnabled ? @"LOOP_ENABLED" : @"LOOP_DISABLED"), YES);
}
- (void)setPlaybackRate:(float)rate {
    didSelectRate(rate);
    %orig;
}
%end

%hook YTAutoplayAutonavController
- (id)initWithParentResponder:(id)arg {
    self = %orig;
    if (self && IS_ENABLED(KeepLoopKey)) {
        [self setLoopMode:2];
    }
    return self;
}
- (void)setLoopMode:(NSInteger)arg {
    NSInteger set = IS_ENABLED(KeepLoopKey) ? 2 : arg;
    %orig(set);
}
%end

static NSString *getCompactQualityLabel(MLFormat *format) {
    NSString *qualityLabel = [format qualityLabel];
    BOOL shouldShowFPS = [format FPS] > 30;
    if ([qualityLabel hasPrefix:@"2160p"])
        qualityLabel = [qualityLabel stringByReplacingOccurrencesOfString:@"2160p" withString:@"4K"];
    else if ([qualityLabel hasPrefix:@"1440p"])
        qualityLabel = [qualityLabel stringByReplacingOccurrencesOfString:@"1440p" withString:@"2K"];
    else if ([qualityLabel hasPrefix:@"1080p"])
        qualityLabel = [qualityLabel stringByReplacingOccurrencesOfString:@"1080p" withString:@"FHD"];
    else if ([qualityLabel hasPrefix:@"720p"])
        qualityLabel = [qualityLabel stringByReplacingOccurrencesOfString:@"720p" withString:@"HD"];
    else if (shouldShowFPS)
        qualityLabel = [qualityLabel stringByReplacingOccurrencesOfString:@"p" withString:@""];
    if ([qualityLabel hasSuffix:@" HDR"])
        qualityLabel = [qualityLabel stringByReplacingOccurrencesOfString:@" HDR" withString:@"\nHDR"];
    return qualityLabel;
}

%hook YTVideoQualitySwitchOriginalController

- (void)singleVideo:(id)singleVideo didSelectVideoFormat:(MLFormat *)format {
    currentQualityLabel = getCompactQualityLabel(format);
    [[NSNotificationCenter defaultCenter] postNotificationName:YouModUpdateNotification object:nil];
    %orig;
}

%end

%hook YTVideoQualitySwitchRedesignedController

- (void)singleVideo:(id)singleVideo didSelectVideoFormat:(MLFormat *)format {
    currentQualityLabel = getCompactQualityLabel(format);
    [[NSNotificationCenter defaultCenter] postNotificationName:YouModUpdateNotification object:nil];
    %orig;
}

%end

%ctor {
    YMRegisterDefaults();
    YMOverlayButtonSpec *mute = [[YMOverlayButtonSpec alloc] init];
    mute.identifier = @"mute.video";
    mute.symbolName = IS_ENABLED(KeepMutedKey) ? @"speaker.slash" : @"speaker.wave.2";
    mute.settingsSymbolName = @"speaker.wave.2";
    mute.displayName = LOC(@"MUTE_BUTTON");
    mute.tintColor = [UIColor whiteColor];
    mute.sortOrder = 300;
    mute.isVisible = ^BOOL(YTPlayerViewController *player) {
        return YMIsOverlayButtonEnabled(@"mute.video");
    };
    mute.onTap = ^(YTPlayerViewController *player, YTQTMButton *button) {
        YTSingleVideoController *sgvid = player.activeVideo;
        BOOL muteStatus = ![sgvid isMuted];
        [[NSUserDefaults standardUserDefaults] setBool:muteStatus forKey:KeepMutedKey];
        [sgvid setMuted:muteStatus];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
        UIImage *newIcon = [UIImage systemImageNamed:muteStatus ? @"speaker.slash" : @"speaker.wave.2" withConfiguration:config];
        [button setImage:newIcon forState:UIControlStateNormal];
    };
    YMRegisterOverlayButton(mute);
    YMOverlayButtonSpec *speed = [[YMOverlayButtonSpec alloc] init];
    speed.identifier = @"speed.video";
    speed.title = currentSpeedLabel;
    speed.settingsSymbolName = @"speedometer";
    speed.displayName = LOC(@"SPEED_BUTTON");
    speed.sortOrder = 400;
    speed.isVisible = ^BOOL(YTPlayerViewController *player) {
        return YMIsOverlayButtonEnabled(@"speed.video");
    };
    speed.onTap = ^(YTPlayerViewController *player, YTQTMButton *button) {
        YTMainAppVideoPlayerOverlayViewController *ovcon = [player activeVideoPlayerOverlay];
        YTMainAppVideoPlayerOverlayView *ovview = [ovcon videoPlayerOverlayView];
        YTMainAppControlsOverlayView *conview = [ovview controlsOverlayView];
        [ovcon didPressVarispeed:button];
        [conview updateSpeedButton:nil];
    };
    YMRegisterOverlayButton(speed);
    YMOverlayButtonSpec *quality = [[YMOverlayButtonSpec alloc] init];
    quality.identifier = @"quality.video";
    quality.title = currentQualityLabel;
    quality.settingsSymbolName = @"slider.horizontal.3";
    quality.displayName = LOC(@"QUALITY_BUTTON");
    quality.sortOrder = 500;
    quality.isVisible = ^BOOL(YTPlayerViewController *player) {
        return YMIsOverlayButtonEnabled(@"quality.video");
    };
    quality.onTap = ^(YTPlayerViewController *player, YTQTMButton *button) {
        YTMainAppVideoPlayerOverlayViewController *ovcon = [player activeVideoPlayerOverlay];
        YTMainAppVideoPlayerOverlayView *ovview = [ovcon videoPlayerOverlayView];
        YTMainAppControlsOverlayView *conview = [ovview controlsOverlayView];
        [ovcon didPressVideoQuality:button];
        [conview updateQualityButton:nil];
    };
    YMRegisterOverlayButton(quality);
    YMOverlayButtonSpec *share = [[YMOverlayButtonSpec alloc] init];
    share.identifier = @"share.video";
    share.symbolName = @"arrowshape.turn.up.right";
    share.settingsSymbolName = @"arrowshape.turn.up.right";
    share.displayName = LOC(@"SHARE_BUTTON");
    share.tintColor = [UIColor whiteColor];
    share.sortOrder = 600;
    share.isVisible = ^BOOL(YTPlayerViewController *player) {
        return YMIsOverlayButtonEnabled(@"share.video");
    };
    share.onTap = ^(YTPlayerViewController *player, YTQTMButton *button) {
        [player YouModShareButton:button];
    };
    YMRegisterOverlayButton(share);
    YMOverlayButtonSpec *loop = [[YMOverlayButtonSpec alloc] init];
    loop.identifier = @"loop.video";
    loop.symbolName = IS_ENABLED(KeepLoopKey) ? @"repeat.1" : @"repeat";
    loop.settingsSymbolName = @"repeat";
    loop.displayName = LOC(@"LOOP_BUTTON");
    loop.tintColor = [UIColor whiteColor];
    loop.sortOrder = 700;
    loop.isVisible = ^BOOL(YTPlayerViewController *player) {
        return YMIsOverlayButtonEnabled(@"loop.video");
    };
    loop.onTap = ^(YTPlayerViewController *player, YTQTMButton *button) {
        [player YouModLoopButton];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
        UIImage *newIcon = [UIImage systemImageNamed:IS_ENABLED(KeepLoopKey) ? @"repeat.1" : @"repeat" withConfiguration:config];
        [button setImage:newIcon forState:UIControlStateNormal];
    };
    YMRegisterOverlayButton(loop);
    YMOverlayButtonSpec *caption = [[YMOverlayButtonSpec alloc] init];
    caption.identifier = @"caption.video";
    caption.symbolName = @"captions.bubble";
    caption.settingsSymbolName = @"captions.bubble";
    caption.displayName = LOC(@"CAPTION_BUTTON");
    caption.tintColor = [UIColor whiteColor];
    caption.sortOrder = 800;
    caption.isVisible = ^BOOL(YTPlayerViewController *player) {
        return YMIsOverlayButtonEnabled(@"caption.video");
    };
    caption.onTap = ^(YTPlayerViewController *player, YTQTMButton *button) {
        YTMainAppVideoPlayerOverlayViewController *c = [player activeVideoPlayerOverlay];
        YTFormat3CaptionViewController *cvc = [c valueForKey:@"_captionOverlayViewController"];
        showTranscript(cvc);
    };
    YMRegisterOverlayButton(caption);
    %init;
}
