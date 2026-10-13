// Downloads screen, modeled on uYou's download manager: the running/waiting/failed
// queue on top, finished downloads below as YouTube-style rows (16:9 thumbnail with
// duration and resume bar, title, channel, format/size/date), with type filter,
// sorting, search, multi-select and a mini player bar for YMLocalPlayback. Shown as
// the Downloads tab and, full screen, from the download menu.
#import "Headers.h"
#import "DownloadLibrary.h"
#import "DownloadQueue.h"
#import "LocalPlayer.h"

static NSString *const YMDownloadsSortKey = @"YouModDownloadsSort";

typedef NS_ENUM(NSInteger, YMDownloadsSection) {
    YMDownloadsSectionQueue,
    YMDownloadsSectionLibrary,
};

typedef NS_ENUM(NSInteger, YMDownloadsFilter) {
    YMDownloadsFilterAll,
    YMDownloadsFilterVideos,
    YMDownloadsFilterAudio,
};

typedef NS_ENUM(NSInteger, YMDownloadsSort) {
    YMDownloadsSortNewest,
    YMDownloadsSortOldest,
    YMDownloadsSortTitle,
    YMDownloadsSortSize,
    YMDownloadsSortDuration,
};

static NSString *YMDownloadsByteCount(unsigned long long bytes) {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

static UIImage *YMDSymbol(NSString *name, CGFloat size, UIImageSymbolWeight weight) {
    return [UIImage systemImageNamed:name withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:size weight:weight]];
}

static NSString *YMRelativeDate(NSTimeInterval timestamp) {
    if (timestamp <= 0) return nil;
    static NSRelativeDateTimeFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSRelativeDateTimeFormatter new];
        formatter.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
    });
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:timestamp];
    if (fabs(date.timeIntervalSinceNow) < 60) return LOC(@"JUST_NOW");
    return [formatter localizedStringForDate:date relativeToDate:NSDate.date];
}

#pragma mark - Thumbnails

// Local thumbnails are decoded and downsampled off the main thread; remote ones
// (queued jobs) are fetched once. Both are cached by path/URL.
static NSCache<NSString *, UIImage *> *YMThumbnailCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 300;
    });
    return cache;
}

static UIImage *YMDownsample(UIImage *image, CGSize size) {
    if (!image) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat scale = MAX(size.width / image.size.width, size.height / image.size.height);
        CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
        [image drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
    }];
}

static void YMLoadThumbnail(NSURL *url, void (^completion)(UIImage *image)) {
    if (!url) { completion(nil); return; }
    NSString *key = url.absoluteString;
    UIImage *cached = [YMThumbnailCache() objectForKey:key];
    if (cached) { completion(cached); return; }
    void (^decode)(NSData *) = ^(NSData *data) {
        UIImage *image = YMDownsample(data.length ? [UIImage imageWithData:data] : nil, CGSizeMake(320, 180));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image) [YMThumbnailCache() setObject:image forKey:key];
            completion(image);
        });
    };
    if (url.isFileURL) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ decode([NSData dataWithContentsOfURL:url]); });
    } else {
        [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) { decode(data); }] resume];
    }
}

#pragma mark - Cells

static const CGFloat YMRowThumbWidth = 156;

@interface YMDownloadThumbnailView : UIView
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *badge;
@property (nonatomic, strong) UIImageView *typeIcon;
@property (nonatomic, strong) UIView *resumeTrack;
@property (nonatomic, strong) UIView *resumeFill;
@property (nonatomic, assign) CGFloat resumeFraction;
@property (nonatomic, copy) NSString *representedKey;
@end

@implementation YMDownloadThumbnailView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.tertiarySystemFillColor;
        self.layer.cornerRadius = 8;
        self.clipsToBounds = YES;
        self.imageView = [UIImageView new];
        self.imageView.contentMode = UIViewContentModeScaleAspectFill;
        self.imageView.tintColor = UIColor.tertiaryLabelColor;
        [self addSubview:self.imageView];
        self.badge = [UILabel new];
        self.badge.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
        self.badge.textColor = UIColor.whiteColor;
        self.badge.textAlignment = NSTextAlignmentCenter;
        self.badge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
        self.badge.layer.cornerRadius = 4;
        self.badge.clipsToBounds = YES;
        [self addSubview:self.badge];
        self.typeIcon = [[UIImageView alloc] initWithImage:YMDSymbol(@"music.note", 10, UIImageSymbolWeightBold)];
        self.typeIcon.tintColor = UIColor.whiteColor;
        self.typeIcon.contentMode = UIViewContentModeCenter;
        self.typeIcon.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
        self.typeIcon.layer.cornerRadius = 4;
        self.typeIcon.clipsToBounds = YES;
        [self addSubview:self.typeIcon];
        self.resumeTrack = [UIView new];
        self.resumeTrack.backgroundColor = [UIColor colorWithWhite:0.6 alpha:0.6];
        self.resumeFill = [UIView new];
        self.resumeFill.backgroundColor = UIColor.systemRedColor;
        [self addSubview:self.resumeTrack];
        [self.resumeTrack addSubview:self.resumeFill];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    BOOL placeholder = self.imageView.image.isSymbolImage;
    self.imageView.contentMode = placeholder ? UIViewContentModeCenter : UIViewContentModeScaleAspectFill;
    self.imageView.frame = self.bounds;
    CGSize badgeSize = [self.badge sizeThatFits:CGSizeMake(100, 18)];
    badgeSize.width += 8;
    self.badge.frame = CGRectMake(size.width - badgeSize.width - 5, size.height - 18 - 5 - (self.resumeFraction > 0 ? 3 : 0), badgeSize.width, 18);
    self.typeIcon.frame = CGRectMake(5, 5, 18, 18);
    self.resumeTrack.hidden = self.resumeFraction <= 0;
    self.resumeTrack.frame = CGRectMake(0, size.height - 3, size.width, 3);
    self.resumeFill.frame = CGRectMake(0, 0, size.width * MIN(self.resumeFraction, 1), 3);
}

- (void)setImageURL:(NSURL *)url placeholder:(NSString *)symbol {
    NSString *key = url.absoluteString ?: symbol;
    self.representedKey = key;
    self.imageView.image = YMDSymbol(symbol, 22, UIImageSymbolWeightRegular);
    __weak typeof(self) weakSelf = self;
    YMLoadThumbnail(url, ^(UIImage *image) {
        if (!image || ![weakSelf.representedKey isEqualToString:key]) return;
        weakSelf.imageView.image = image;
        [weakSelf setNeedsLayout];
    });
    [self setNeedsLayout];
}

@end

@interface YMDownloadItemCell : UITableViewCell
@property (nonatomic, strong) YMDownloadThumbnailView *thumb;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *channelLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, strong) UIImageView *nowPlaying;
@end

@implementation YMDownloadItemCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.thumb = [YMDownloadThumbnailView new];
        self.titleLabel = [UILabel new];
        self.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        self.titleLabel.numberOfLines = 2;
        self.channelLabel = [UILabel new];
        self.channelLabel.font = [UIFont systemFontOfSize:13];
        self.channelLabel.textColor = UIColor.secondaryLabelColor;
        self.metaLabel = [UILabel new];
        self.metaLabel.font = [UIFont systemFontOfSize:12];
        self.metaLabel.textColor = UIColor.secondaryLabelColor;
        self.metaLabel.numberOfLines = 2;
        self.moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.moreButton setImage:YMDSymbol(@"ellipsis", 15, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
        self.moreButton.tintColor = UIColor.secondaryLabelColor;
        self.moreButton.showsMenuAsPrimaryAction = YES;
        self.moreButton.transform = CGAffineTransformMakeRotation(M_PI_2);
        self.nowPlaying = [[UIImageView alloc] initWithImage:YMDSymbol(@"waveform", 12, UIImageSymbolWeightBold)];
        self.nowPlaying.tintColor = UIColor.systemRedColor;
        for (UIView *view in @[self.thumb, self.titleLabel, self.channelLabel, self.metaLabel, self.moreButton, self.nowPlaying]) {
            [self.contentView addSubview:view];
        }
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    CGFloat inset = 16;
    CGFloat thumbH = round(YMRowThumbWidth * 9 / 16);
    self.thumb.frame = CGRectMake(inset, (bounds.size.height - thumbH) / 2, YMRowThumbWidth, thumbH);
    CGFloat x = CGRectGetMaxX(self.thumb.frame) + 12;
    BOOL editing = self.isEditing;
    self.moreButton.hidden = editing;
    CGFloat right = editing ? bounds.size.width - 8 : bounds.size.width - 36;
    self.moreButton.frame = CGRectMake(bounds.size.width - 38, CGRectGetMinY(self.thumb.frame) - 8, 36, 36);
    CGFloat width = right - x;
    CGFloat y = CGRectGetMinY(self.thumb.frame);
    CGFloat titleX = x;
    if (!self.nowPlaying.hidden) {
        self.nowPlaying.frame = CGRectMake(x, y + 2, 16, 16);
        titleX += 0;
    }
    CGSize titleSize = [self.titleLabel sizeThatFits:CGSizeMake(width, 40)];
    self.titleLabel.frame = CGRectMake(titleX, y, width, MIN(titleSize.height, 38));
    y = CGRectGetMaxY(self.titleLabel.frame) + 3;
    self.channelLabel.frame = CGRectMake(x, y, width, 17);
    y += self.channelLabel.text.length ? 18 : 0;
    CGSize metaSize = [self.metaLabel sizeThatFits:CGSizeMake(width, 32)];
    self.metaLabel.frame = CGRectMake(x, y, width, MIN(metaSize.height, CGRectGetMaxY(self.thumb.frame) - y));
}

@end

@interface YMDownloadJobCell : UITableViewCell
@property (nonatomic, strong) YMDownloadThumbnailView *thumb;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, weak) YMDownloadJob *job;
@end

@implementation YMDownloadJobCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.thumb = [YMDownloadThumbnailView new];
        self.titleLabel = [UILabel new];
        self.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        self.titleLabel.numberOfLines = 2;
        self.statusLabel = [UILabel new];
        self.statusLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
        self.statusLabel.textColor = UIColor.secondaryLabelColor;
        self.statusLabel.numberOfLines = 2;
        self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        self.progressView.progressTintColor = UIColor.systemRedColor;
        self.progressView.layer.cornerRadius = 2;
        self.progressView.clipsToBounds = YES;
        self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.actionButton.tintColor = UIColor.secondaryLabelColor;
        [self.actionButton addTarget:self action:@selector(actionTapped) forControlEvents:UIControlEventTouchUpInside];
        for (UIView *view in @[self.thumb, self.titleLabel, self.statusLabel, self.progressView, self.actionButton]) {
            [self.contentView addSubview:view];
        }
    }
    return self;
}

- (void)configureWithJob:(YMDownloadJob *)job {
    BOOL newJob = self.job != job;
    self.job = job;
    self.titleLabel.text = job.title;
    BOOL failed = job.state == YMDownloadJobStateFailed;
    BOOL running = job.state == YMDownloadJobStateRunning;
    self.progressView.hidden = !running;
    [self.progressView setProgress:job.progress animated:!newJob];
    NSMutableArray *parts = [NSMutableArray array];
    if (failed) {
        [parts addObject:job.errorMessage ?: LOC(@"DOWNLOAD_FAILED")];
    } else {
        if (job.formatSummary.length) [parts addObject:job.formatSummary];
        if (running && job.status.length) [parts addObject:job.status];
        else if (!running) [parts addObject:LOC(@"QUEUED")];
    }
    self.statusLabel.text = [parts componentsJoinedByString:@" · "];
    self.statusLabel.textColor = failed ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
    [self.actionButton setImage:YMDSymbol(failed ? @"arrow.clockwise" : @"xmark", 15, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    if (newJob) [self.thumb setImageURL:job.thumbnailURL placeholder:job.isVideo ? @"film" : @"music.note"];
    self.thumb.typeIcon.hidden = job.isVideo;
    self.thumb.badge.hidden = job.durationMs == 0;
    self.thumb.badge.text = YMLocalFormatTime(job.durationMs / 1000.0);
    self.thumb.resumeFraction = 0;
    [self setNeedsLayout];
}

- (void)actionTapped {
    YMDownloadJob *job = self.job;
    if (!job) return;
    if (job.state == YMDownloadJobStateFailed) [[YMDownloadQueue sharedQueue] retryJob:job];
    else [[YMDownloadQueue sharedQueue] cancelJob:job];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    CGFloat thumbH = round(YMRowThumbWidth * 9 / 16);
    self.thumb.frame = CGRectMake(16, (bounds.size.height - thumbH) / 2, YMRowThumbWidth, thumbH);
    CGFloat x = CGRectGetMaxX(self.thumb.frame) + 12;
    self.actionButton.frame = CGRectMake(bounds.size.width - 44, (bounds.size.height - 44) / 2, 40, 44);
    CGFloat width = CGRectGetMinX(self.actionButton.frame) - x - 4;
    CGFloat y = CGRectGetMinY(self.thumb.frame);
    CGSize titleSize = [self.titleLabel sizeThatFits:CGSizeMake(width, 40)];
    self.titleLabel.frame = CGRectMake(x, y, width, MIN(titleSize.height, 38));
    y = CGRectGetMaxY(self.titleLabel.frame) + 6;
    if (!self.progressView.hidden) {
        self.progressView.frame = CGRectMake(x, y, width, 4);
        y += 10;
    }
    CGSize statusSize = [self.statusLabel sizeThatFits:CGSizeMake(width, 32)];
    self.statusLabel.frame = CGRectMake(x, y, width, MIN(statusSize.height, 32));
}

@end

#pragma mark - List

@interface YMDownloadsViewController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray<YMDownloadJob *> *jobs;
@property (nonatomic, copy) NSArray<YMDownloadItem *> *items;
@property (nonatomic, copy) NSString *filter;
@property (nonatomic, copy) NSString *jobsSignature;
@property (nonatomic, assign) YMDownloadsFilter typeFilter;
@property (nonatomic, assign) BOOL showsCloseButton; // presented modally (not in the tab)
@property (nonatomic, strong) UISegmentedControl *segments;
@property (nonatomic, strong) UIView *emptyView;
@end

@implementation YMDownloadsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LOC(@"DOWNLOADS");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.backgroundColor = UIColor.systemBackgroundColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = round(YMRowThumbWidth * 9 / 16) + 16;
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    if (@available(iOS 15.0, *)) self.tableView.sectionHeaderTopPadding = 0;
    [self.tableView registerClass:YMDownloadItemCell.class forCellReuseIdentifier:@"item"];
    [self.tableView registerClass:YMDownloadJobCell.class forCellReuseIdentifier:@"job"];

    if (self.showsCloseButton) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    }
    [self updateNavigationItems];

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = LOC(@"SEARCH_DOWNLOADS");
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;

    self.segments = [[UISegmentedControl alloc] initWithItems:@[LOC(@"DOWNLOADS_FILTER_ALL"), LOC(@"DOWNLOADS_FILTER_VIDEOS"), LOC(@"DOWNLOADS_FILTER_AUDIO")]];
    self.segments.selectedSegmentIndex = 0;
    [self.segments addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 48)];
    self.segments.frame = CGRectMake(16, 6, 288, 32);
    self.segments.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:self.segments];
    self.tableView.tableHeaderView = header;

    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(refreshPulled) forControlEvents:UIControlEventValueChanged];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(queueChanged) name:YMDownloadQueueDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(reloadData) name:YMDownloadLibraryDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(playbackChanged) name:YMLocalPlaybackItemDidChangeNotification object:nil];
    [[YMDownloadLibrary sharedLibrary] reload];
    [self reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Resume bars change while the player is open.
    [self.tableView reloadData];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)close {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)refreshPulled {
    [[YMDownloadLibrary sharedLibrary] reload];
    [self reloadData];
    [self.refreshControl endRefreshing];
}

- (void)segmentChanged {
    self.typeFilter = self.segments.selectedSegmentIndex;
    [self reloadData];
}

#pragma mark Navigation items

- (YMDownloadsSort)sortMode {
    return [NSUserDefaults.standardUserDefaults integerForKey:YMDownloadsSortKey];
}

- (UIMenu *)sortMenu {
    NSArray *titles = @[LOC(@"SORT_NEWEST"), LOC(@"SORT_OLDEST"), LOC(@"SORT_TITLE"), LOC(@"SORT_SIZE"), LOC(@"SORT_DURATION")];
    NSMutableArray *actions = [NSMutableArray array];
    [titles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger index, BOOL *stop) {
        UIAction *action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *a) {
            [NSUserDefaults.standardUserDefaults setInteger:index forKey:YMDownloadsSortKey];
            [self updateNavigationItems];
            [self reloadData];
        }];
        if ((NSInteger)index == [self sortMode]) action.state = UIMenuElementStateOn;
        [actions addObject:action];
    }];
    return [UIMenu menuWithTitle:LOC(@"SORT") children:actions];
}

- (void)updateNavigationItems {
    if (self.tableView.isEditing) {
        self.navigationItem.rightBarButtonItems = @[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(toggleEditing)]];
        return;
    }
    UIBarButtonItem *sort = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"] menu:[self sortMenu]];
    UIBarButtonItem *select = [[UIBarButtonItem alloc] initWithTitle:LOC(@"SELECT") style:UIBarButtonItemStylePlain target:self action:@selector(toggleEditing)];
    select.enabled = self.items.count > 0;
    self.navigationItem.rightBarButtonItems = @[select, sort];
}

- (void)toggleEditing {
    BOOL editing = !self.tableView.isEditing;
    [self.tableView setEditing:editing animated:YES];
    [self updateNavigationItems];
    [self.navigationController setToolbarHidden:!editing animated:YES];
    [self updateToolbar];
    [self.navigationController.parentViewController.view setNeedsLayout];
}

- (NSArray<YMDownloadItem *> *)selectedItems {
    NSMutableArray *selected = [NSMutableArray array];
    for (NSIndexPath *path in self.tableView.indexPathsForSelectedRows) {
        if (path.section == YMDownloadsSectionLibrary && path.row < (NSInteger)self.items.count) [selected addObject:self.items[path.row]];
    }
    return selected;
}

- (void)updateToolbar {
    NSArray *selected = [self selectedItems];
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(shareSelected)];
    share.enabled = selected.count > 0;
    UIBarButtonItem *all = [[UIBarButtonItem alloc] initWithTitle:selected.count == self.items.count && selected.count ? LOC(@"DESELECT_ALL") : LOC(@"SELECT_ALL") style:UIBarButtonItemStylePlain target:self action:@selector(toggleSelectAll)];
    NSString *deleteTitle = selected.count ? [NSString stringWithFormat:LOC(@"DELETE_COUNT"), (unsigned long)selected.count] : LOC(@"DELETE");
    UIBarButtonItem *delete = [[UIBarButtonItem alloc] initWithTitle:deleteTitle style:UIBarButtonItemStylePlain target:self action:@selector(deleteSelected)];
    delete.tintColor = UIColor.systemRedColor;
    delete.enabled = selected.count > 0;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[all, flex, share, flex, delete];
}

- (void)toggleSelectAll {
    BOOL selectAll = [self selectedItems].count != self.items.count;
    for (NSInteger row = 0; row < (NSInteger)self.items.count; row++) {
        NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:YMDownloadsSectionLibrary];
        if (selectAll) [self.tableView selectRowAtIndexPath:path animated:NO scrollPosition:UITableViewScrollPositionNone];
        else [self.tableView deselectRowAtIndexPath:path animated:NO];
    }
    [self updateToolbar];
}

- (void)shareSelected {
    NSMutableArray *urls = [NSMutableArray array];
    for (YMDownloadItem *item in [self selectedItems]) if (item.fileURL) [urls addObject:item.fileURL];
    if (!urls.count) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = self.toolbarItems[2];
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)deleteSelected {
    NSArray *selected = [self selectedItems];
    if (!selected.count) return;
    NSString *title = [NSString stringWithFormat:LOC(@"DELETE_DOWNLOADS_CONFIRM"), (unsigned long)selected.count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"DELETE") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        for (YMDownloadItem *item in selected) [[YMDownloadLibrary sharedLibrary] removeItem:item];
        [self toggleEditing];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.barButtonItem = self.toolbarItems.lastObject;
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Data

- (BOOL)matchesFilter:(NSString *)title author:(NSString *)author {
    if (self.filter.length == 0) return YES;
    return [title localizedCaseInsensitiveContainsString:self.filter] || [author localizedCaseInsensitiveContainsString:self.filter];
}

- (NSString *)signatureForJobs:(NSArray<YMDownloadJob *> *)jobs {
    NSMutableString *signature = [NSMutableString string];
    for (YMDownloadJob *job in jobs) [signature appendFormat:@"%p:%ld;", job, (long)job.state];
    return signature;
}

- (NSArray<YMDownloadJob *> *)filteredJobs {
    NSMutableArray *jobs = [NSMutableArray array];
    for (YMDownloadJob *job in [YMDownloadQueue sharedQueue].jobs) {
        if (self.typeFilter == YMDownloadsFilterVideos && !job.isVideo) continue;
        if (self.typeFilter == YMDownloadsFilterAudio && job.isVideo) continue;
        if ([self matchesFilter:job.title author:job.author]) [jobs addObject:job];
    }
    return jobs;
}

- (void)reloadData {
    self.jobs = [self filteredJobs];
    self.jobsSignature = [self signatureForJobs:self.jobs];

    NSMutableArray *items = [NSMutableArray array];
    for (YMDownloadItem *item in [YMDownloadLibrary sharedLibrary].items) {
        if (self.typeFilter == YMDownloadsFilterVideos && !item.isVideo) continue;
        if (self.typeFilter == YMDownloadsFilterAudio && item.isVideo) continue;
        if ([self matchesFilter:item.title author:item.author]) [items addObject:item];
    }
    switch ([self sortMode]) {
        case YMDownloadsSortOldest:
            [items sortUsingComparator:^NSComparisonResult(YMDownloadItem *a, YMDownloadItem *b) { return [@(a.createdAt) compare:@(b.createdAt)]; }];
            break;
        case YMDownloadsSortTitle:
            [items sortUsingComparator:^NSComparisonResult(YMDownloadItem *a, YMDownloadItem *b) { return [a.title ?: @"" localizedStandardCompare:b.title ?: @""]; }];
            break;
        case YMDownloadsSortSize:
            [items sortUsingComparator:^NSComparisonResult(YMDownloadItem *a, YMDownloadItem *b) { return [@(b.fileSize) compare:@(a.fileSize)]; }];
            break;
        case YMDownloadsSortDuration:
            [items sortUsingComparator:^NSComparisonResult(YMDownloadItem *a, YMDownloadItem *b) { return [@(b.durationMs) compare:@(a.durationMs)]; }];
            break;
        default:
            break; // the library is newest first
    }
    self.items = items;
    [self.tableView reloadData];
    [self updateEmptyState];
    if (!self.tableView.isEditing) [self updateNavigationItems];
    else [self updateToolbar];
}

// Progress ticks only refresh the visible job rows, so swipes and taps on the list
// aren't interrupted several times a second.
- (void)queueChanged {
    NSArray *jobs = [self filteredJobs];
    NSString *signature = [self signatureForJobs:jobs];
    if (![signature isEqualToString:self.jobsSignature]) {
        [self reloadData];
        return;
    }
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        if (path.section != YMDownloadsSectionQueue || path.row >= (NSInteger)self.jobs.count) continue;
        YMDownloadJobCell *cell = (YMDownloadJobCell *)[self.tableView cellForRowAtIndexPath:path];
        if ([cell isKindOfClass:YMDownloadJobCell.class]) [cell configureWithJob:self.jobs[path.row]];
    }
}

- (void)playbackChanged {
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        if (path.section != YMDownloadsSectionLibrary) continue;
        YMDownloadItemCell *cell = (YMDownloadItemCell *)[self.tableView cellForRowAtIndexPath:path];
        if ([cell isKindOfClass:YMDownloadItemCell.class]) [self configureItemCell:cell item:self.items[path.row]];
    }
}

- (void)updateEmptyState {
    BOOL empty = self.jobs.count == 0 && self.items.count == 0;
    if (!empty) {
        self.tableView.backgroundView = nil;
        return;
    }
    UIView *container = [UIView new];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *icon = [[UIImageView alloc] initWithImage:YMDSymbol(self.filter.length ? @"magnifyingglass" : @"arrow.down.circle", 52, UIImageSymbolWeightLight)];
    icon.tintColor = UIColor.tertiaryLabelColor;
    UILabel *title = [UILabel new];
    title.text = self.filter.length ? LOC(@"DOWNLOADS_NO_RESULTS") : LOC(@"DOWNLOADS_EMPTY_TITLE");
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    UILabel *message = [UILabel new];
    message.text = self.filter.length ? nil : LOC(@"DOWNLOADS_EMPTY");
    message.font = [UIFont systemFontOfSize:14];
    message.textColor = UIColor.secondaryLabelColor;
    message.textAlignment = NSTextAlignmentCenter;
    message.numberOfLines = 0;
    [stack addArrangedSubview:icon];
    [stack setCustomSpacing:14 afterView:icon];
    [stack addArrangedSubview:title];
    if (message.text.length) [stack addArrangedSubview:message];
    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-20],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:container.widthAnchor constant:-64],
    ]];
    self.tableView.backgroundView = container;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.filter = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self reloadData];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == YMDownloadsSectionQueue ? self.jobs.count : self.items.count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = nil;
    if (section == YMDownloadsSectionQueue && self.jobs.count) title = [NSString stringWithFormat:@"%@ · %lu", LOC(@"DOWNLOADS_IN_PROGRESS"), (unsigned long)self.jobs.count];
    if (section == YMDownloadsSectionLibrary && self.items.count && self.jobs.count) title = LOC(@"DOWNLOADS_DONE");
    if (!title) return nil;
    UITableViewHeaderFooterView *header = [tableView dequeueReusableHeaderFooterViewWithIdentifier:@"header"] ?: [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:@"header"];
    UIListContentConfiguration *config = [UIListContentConfiguration plainHeaderConfiguration];
    config.text = title;
    config.textProperties.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    config.textProperties.color = UIColor.labelColor;
    header.contentConfiguration = config;
    UIBackgroundConfiguration *background = [UIBackgroundConfiguration clearConfiguration];
    background.backgroundColor = UIColor.systemBackgroundColor;
    header.backgroundConfiguration = background;
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section == YMDownloadsSectionQueue) return self.jobs.count ? 36 : 0;
    return self.items.count && self.jobs.count ? 36 : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != YMDownloadsSectionLibrary || self.items.count == 0) return nil;
    unsigned long long total = 0;
    for (YMDownloadItem *item in self.items) total += item.fileSize;
    NSString *summary = [NSString stringWithFormat:LOC(@"DOWNLOADS_STORAGE"), (unsigned long)self.items.count, YMDownloadsByteCount(total)];
    NSDictionary *values = [[NSURL fileURLWithPath:NSHomeDirectory()] resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey] error:nil];
    NSNumber *free = values[NSURLVolumeAvailableCapacityForImportantUsageKey];
    if (free) summary = [summary stringByAppendingFormat:@" · %@", [NSString stringWithFormat:LOC(@"DOWNLOADS_FREE_SPACE"), YMDownloadsByteCount(free.unsignedLongLongValue)]];
    return summary;
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
        footer.textLabel.textAlignment = NSTextAlignmentCenter;
        UIBackgroundConfiguration *background = [UIBackgroundConfiguration clearConfiguration];
        footer.backgroundConfiguration = background;
    }
}

- (void)configureItemCell:(YMDownloadItemCell *)cell item:(YMDownloadItem *)item {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    BOOL current = playback.currentItem == item;
    cell.titleLabel.text = item.title;
    cell.titleLabel.textColor = current ? UIColor.systemRedColor : UIColor.labelColor;
    cell.channelLabel.text = item.author;
    NSMutableArray *parts = [NSMutableArray array];
    if (item.formatSummary.length) [parts addObject:item.formatSummary];
    else if (item.fileURL.pathExtension.length) [parts addObject:item.fileURL.pathExtension.uppercaseString];
    if (item.fileSize) [parts addObject:YMDownloadsByteCount(item.fileSize)];
    NSString *date = YMRelativeDate(item.createdAt);
    if (date) [parts addObject:date];
    cell.metaLabel.text = [parts componentsJoinedByString:@" · "];
    cell.nowPlaying.hidden = YES;

    [cell.thumb setImageURL:item.thumbnailURL placeholder:item.isVideo ? @"film" : @"music.note"];
    cell.thumb.typeIcon.hidden = item.isVideo;
    cell.thumb.badge.hidden = item.durationMs == 0;
    cell.thumb.badge.text = YMLocalFormatTime(item.durationMs / 1000.0);
    NSTimeInterval resume = [[YMDownloadLibrary sharedLibrary] resumePositionForItem:item];
    cell.thumb.resumeFraction = item.durationMs > 0 ? resume / (item.durationMs / 1000.0) : 0;

    cell.moreButton.menu = [UIMenu menuWithTitle:@"" children:[self actionsForItem:item]];
    [cell setNeedsLayout];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == YMDownloadsSectionQueue) {
        YMDownloadJobCell *cell = [tableView dequeueReusableCellWithIdentifier:@"job" forIndexPath:indexPath];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        [cell configureWithJob:self.jobs[indexPath.row]];
        return cell;
    }
    YMDownloadItemCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item" forIndexPath:indexPath];
    [self configureItemCell:cell item:self.items[indexPath.row]];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (BOOL)tableView:(UITableView *)tableView shouldBeginMultipleSelectionInteractionAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == YMDownloadsSectionLibrary;
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing && indexPath.section == YMDownloadsSectionQueue) return nil;
    return indexPath;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) {
        [self updateToolbar];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == YMDownloadsSectionQueue) {
        YMDownloadJob *job = self.jobs[indexPath.row];
        if (job.state == YMDownloadJobStateFailed) [[YMDownloadQueue sharedQueue] retryJob:job];
        return;
    }
    YMLocalPlayerOpen(self, self.items, indexPath.row);
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) [self updateToolbar];
}

#pragma mark Item actions

- (void)confirmDeleteItem:(YMDownloadItem *)item {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"DELETE_DOWNLOAD") message:item.title preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"DELETE") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[YMDownloadLibrary sharedLibrary] removeItem:item];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openItemOnYouTube:(YMDownloadItem *)item {
    NSURL *url = [NSURL URLWithString:[@"youtube://" stringByAppendingString:item.videoID]];
    void (^open)(void) = ^{ [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil]; };
    if (self.showsCloseButton) [self.navigationController dismissViewControllerAnimated:YES completion:open];
    else open();
}

- (NSArray<UIMenuElement *> *)actionsForItem:(YMDownloadItem *)item {
    __weak typeof(self) weakSelf = self;
    NSMutableArray *actions = [NSMutableArray array];
    [actions addObject:[UIAction actionWithTitle:LOC(@"PLAY") image:[UIImage systemImageNamed:@"play"] identifier:nil handler:^(UIAction *action) {
        NSUInteger index = [weakSelf.items indexOfObject:item];
        if (index != NSNotFound) YMLocalPlayerOpen(weakSelf, weakSelf.items, index);
    }]];
    [actions addObject:[UIAction actionWithTitle:LOC(@"SHARE") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *action) {
        YMDownloadShareFile(item.fileURL, weakSelf);
    }]];
    if (item.isVideo) {
        [actions addObject:[UIAction actionWithTitle:LOC(@"SAVE_TO_PHOTOS_ACTION") image:[UIImage systemImageNamed:@"photo.on.rectangle"] identifier:nil handler:^(UIAction *action) {
            YMDownloadSaveVideoToPhotos(item.fileURL, weakSelf);
        }]];
    }
    if (item.videoID.length) {
        [actions addObject:[UIAction actionWithTitle:LOC(@"OPEN_VIDEO") image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil handler:^(UIAction *action) {
            [weakSelf openItemOnYouTube:item];
        }]];
        [actions addObject:[UIAction actionWithTitle:LOC(@"COPY_LINK") image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(UIAction *action) {
            UIPasteboard.generalPasteboard.string = [@"https://youtu.be/" stringByAppendingString:item.videoID];
            YMDownloadShowToast(LOC(@"COPIED_TO_CLIPBOARD"), NO);
        }]];
    }
    UIAction *delete = [UIAction actionWithTitle:LOC(@"DELETE") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *action) {
        [weakSelf confirmDeleteItem:item];
    }];
    delete.attributes = UIMenuElementAttributesDestructive;
    [actions addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[delete]]];
    return actions;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) return nil;
    if (indexPath.section == YMDownloadsSectionQueue) {
        YMDownloadJob *job = self.jobs[indexPath.row];
        if (job.state == YMDownloadJobStateFailed) {
            UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:LOC(@"REMOVE") handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
                [[YMDownloadQueue sharedQueue] removeJob:job];
                done(YES);
            }];
            UIContextualAction *retry = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:LOC(@"RETRY") handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
                [[YMDownloadQueue sharedQueue] retryJob:job];
                done(YES);
            }];
            retry.backgroundColor = UIColor.systemBlueColor;
            return [UISwipeActionsConfiguration configurationWithActions:@[remove, retry]];
        }
        UIContextualAction *cancel = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:LOC(@"CANCEL") handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
            [[YMDownloadQueue sharedQueue] cancelJob:job];
            done(YES);
        }];
        return [UISwipeActionsConfiguration configurationWithActions:@[cancel]];
    }

    YMDownloadItem *item = self.items[indexPath.row];
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:nil handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
        [self confirmDeleteItem:item];
        done(NO);
    }];
    delete.image = [UIImage systemImageNamed:@"trash"];
    UIContextualAction *share = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:nil handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
        YMDownloadShareFile(item.fileURL, self);
        done(YES);
    }];
    share.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
    share.backgroundColor = UIColor.systemBlueColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[delete, share]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if (tableView.isEditing || indexPath.section != YMDownloadsSectionLibrary) return nil;
    YMDownloadItem *item = self.items[indexPath.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        return [UIMenu menuWithTitle:item.title ?: @"" children:[self actionsForItem:item]];
    }];
}

- (void)scrollToTop {
    UIScrollView *scroll = self.tableView;
    [scroll setContentOffset:CGPointMake(0, -scroll.adjustedContentInset.top) animated:YES];
}

@end

#pragma mark - Container (navigation + mini player)

// Hosts the Downloads navigation controller and the mini player bar. In the tab,
// YouTube switches tabs by swapping the view controllers of its own (bar-less)
// navigation controller, so the screen needs a navigation controller of its own -
// for the title, search field and toolbar - hosted as a child; the pivot bar is
// drawn over the tab content, so its height joins the bottom safe area.
@interface YMDownloadsContainerViewController : UIViewController
@property (nonatomic, strong) UINavigationController *contentNavigationController;
@property (nonatomic, strong) YMDownloadsViewController *listViewController;
@property (nonatomic, strong) YMLocalMiniPlayerBar *miniBar;
@property (nonatomic, assign) BOOL inTab;
@end

@implementation YMDownloadsContainerViewController

- (instancetype)initInTab:(BOOL)inTab {
    if ((self = [super init])) {
        _inTab = inTab;
        _listViewController = [YMDownloadsViewController new];
        _listViewController.showsCloseButton = !inTab;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.contentNavigationController = [[UINavigationController alloc] initWithRootViewController:self.listViewController];
    [self addChildViewController:self.contentNavigationController];
    self.contentNavigationController.view.frame = self.view.bounds;
    self.contentNavigationController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.contentNavigationController.view];
    [self.contentNavigationController didMoveToParentViewController:self];

    self.miniBar = [YMLocalMiniPlayerBar new];
    __weak typeof(self) weakSelf = self;
    self.miniBar.openHandler = ^{ YMLocalPlayerPresent(weakSelf); };
    self.miniBar.hidden = YES;
    [self.view addSubview:self.miniBar];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playbackItemChanged) name:YMLocalPlaybackItemDidChangeNotification object:nil];
    [self playbackItemChanged];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)miniBarVisible {
    return [YMLocalPlayback sharedPlayback].currentItem != nil;
}

- (void)playbackItemChanged {
    BOOL visible = [self miniBarVisible];
    if (visible == !self.miniBar.hidden) { [self.view setNeedsLayout]; return; }
    if (visible) {
        self.miniBar.hidden = NO;
        self.miniBar.alpha = 0;
    }
    [self.view setNeedsLayout];
    [UIView animateWithDuration:0.25 animations:^{
        self.miniBar.alpha = visible ? 1 : 0;
        [self.view layoutIfNeeded];
    } completion:^(BOOL finished) {
        if (![self miniBarVisible]) self.miniBar.hidden = YES;
    }];
}

- (CGFloat)pivotBarOverlap {
    if (!self.inTab) return 0;
    UIView *pivotBar = YMDownloadsTabPivotBarView();
    if (!pivotBar.window || pivotBar.window != self.view.window || pivotBar.hidden || pivotBar.alpha < 0.01) return 0;
    CGRect barFrame = [pivotBar convertRect:pivotBar.bounds toView:self.view];
    CGFloat overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(barFrame));
    return MAX(0, overlap - self.view.safeAreaInsets.bottom);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat overlap = [self pivotBarOverlap];
    BOOL barVisible = [self miniBarVisible];
    CGFloat barHeight = YMLocalMiniPlayerBarHeight();
    CGFloat bottom = self.view.safeAreaInsets.bottom + overlap;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    // Keep the bar above the list's toolbar while selecting.
    CGFloat toolbar = self.contentNavigationController.isToolbarHidden ? 0 : self.contentNavigationController.toolbar.bounds.size.height;
    CGFloat barY = self.view.bounds.size.height - bottom - toolbar - barHeight - 8;
    self.miniBar.frame = CGRectMake(safe.left + 8, barVisible ? barY : self.view.bounds.size.height, self.view.bounds.size.width - safe.left - safe.right - 16, barHeight);

    UIEdgeInsets insets = self.contentNavigationController.additionalSafeAreaInsets;
    CGFloat wanted = overlap + (barVisible ? barHeight + 12 : 0);
    if (fabs(insets.bottom - wanted) > 0.5) {
        insets.bottom = wanted;
        self.contentNavigationController.additionalSafeAreaInsets = insets;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.view setNeedsLayout];
}

// Re-tapping the selected tab returns to the list and scrolls it to the top.
- (void)ym_returnToTop {
    UINavigationController *nav = self.contentNavigationController;
    if (nav.viewControllers.count > 1) {
        [nav popToRootViewControllerAnimated:YES];
        return;
    }
    [self.listViewController scrollToTop];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return self.contentNavigationController.preferredStatusBarStyle;
}

@end

void YMPresentDownloadsViewController(UIViewController *presenter) {
    presenter = presenter ?: YouModTopViewController(nil);
    if (!presenter) return;
    for (UIViewController *vc = presenter; vc; vc = vc.parentViewController) {
        if ([vc isKindOfClass:YMDownloadsContainerViewController.class] && !((YMDownloadsContainerViewController *)vc).inTab) return;
    }
    YMDownloadsContainerViewController *container = [[YMDownloadsContainerViewController alloc] initInTab:NO];
    container.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:container animated:YES completion:nil];
}

UIViewController *YMDownloadsTabViewController(void) {
    static YMDownloadsContainerViewController *tab;
    if (!tab) tab = [[YMDownloadsContainerViewController alloc] initInTab:YES];
    return tab;
}

void YMDownloadsTabReturnToTop(UIViewController *tab) {
    if ([tab isKindOfClass:YMDownloadsContainerViewController.class]) [(YMDownloadsContainerViewController *)tab ym_returnToTop];
}
