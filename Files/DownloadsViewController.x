// Downloads screen: the running/waiting/failed queue on top, finished downloads
// (YMDownloadLibrary) below. Opened from the Downloads tab, the download menu and
// the tab bar's long-press menu.
#import "Headers.h"
#import "DownloadLibrary.h"
#import "DownloadQueue.h"
#import <AVKit/AVKit.h>

typedef NS_ENUM(NSInteger, YMDownloadsSection) {
    YMDownloadsSectionQueue,
    YMDownloadsSectionLibrary,
};

static NSString *YMDownloadsByteCount(unsigned long long bytes) {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

static NSString *YMDownloadsDuration(unsigned long long durationMs) {
    if (durationMs == 0) return nil;
    unsigned long long seconds = durationMs / 1000;
    if (seconds >= 3600) return [NSString stringWithFormat:@"%llu:%02llu:%02llu", seconds / 3600, (seconds / 60) % 60, seconds % 60];
    return [NSString stringWithFormat:@"%llu:%02llu", seconds / 60, seconds % 60];
}

@interface YMDownloadsViewController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray<YMDownloadJob *> *jobs;
@property (nonatomic, copy) NSArray<YMDownloadItem *> *items;
@property (nonatomic, copy) NSString *filter;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *thumbnails;
@property (nonatomic, assign) BOOL showsCloseButton; // presented modally (not in the tab)
@end

@implementation YMDownloadsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LOC(@"DOWNLOADS");
    self.thumbnails = [NSCache new];
    self.tableView.rowHeight = 72;
    if (self.showsCloseButton) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    }

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadData) name:YMDownloadQueueDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadData) name:YMDownloadLibraryDidChangeNotification object:nil];
    [[YMDownloadLibrary sharedLibrary] reload];
    [self reloadData];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)close {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)matchesFilter:(NSString *)title author:(NSString *)author {
    if (self.filter.length == 0) return YES;
    return [title localizedCaseInsensitiveContainsString:self.filter] || [author localizedCaseInsensitiveContainsString:self.filter];
}

- (void)reloadData {
    NSMutableArray *jobs = [NSMutableArray array];
    for (YMDownloadJob *job in [YMDownloadQueue sharedQueue].jobs) {
        if ([self matchesFilter:job.title author:job.author]) [jobs addObject:job];
    }
    NSMutableArray *items = [NSMutableArray array];
    for (YMDownloadItem *item in [YMDownloadLibrary sharedLibrary].items) {
        if ([self matchesFilter:item.title author:item.author]) [items addObject:item];
    }
    self.jobs = jobs;
    self.items = items;
    [self.tableView reloadData];
    [self updateEmptyState];
}

- (void)updateEmptyState {
    if (self.jobs.count || self.items.count) {
        self.tableView.backgroundView = nil;
        return;
    }
    UILabel *label = [UILabel new];
    label.text = LOC(@"DOWNLOADS_EMPTY");
    label.textColor = UIColor.secondaryLabelColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    self.tableView.backgroundView = label;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.filter = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == YMDownloadsSectionQueue ? self.jobs.count : self.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == YMDownloadsSectionQueue) return self.jobs.count ? LOC(@"DOWNLOADS_IN_PROGRESS") : nil;
    return self.items.count ? LOC(@"DOWNLOADS_DONE") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != YMDownloadsSectionLibrary || self.items.count == 0) return nil;
    unsigned long long total = 0;
    for (YMDownloadItem *item in self.items) total += item.fileSize;
    return [NSString stringWithFormat:LOC(@"DOWNLOADS_STORAGE"), (unsigned long)self.items.count, YMDownloadsByteCount(total)];
}

- (UIImage *)thumbnailForItem:(YMDownloadItem *)item {
    NSString *path = item.thumbnailURL.path;
    UIImage *placeholder = [UIImage systemImageNamed:item.isVideo ? @"film" : @"music.note"];
    if (!path) return placeholder;
    UIImage *cached = [self.thumbnails objectForKey:path];
    if (cached) return cached;
    UIImage *full = [UIImage imageWithContentsOfFile:path];
    if (!full) return placeholder;
    CGSize size = CGSizeMake(96, 54);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *thumb = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat scale = MAX(size.width / full.size.width, size.height / full.size.height);
        CGSize drawn = CGSizeMake(full.size.width * scale, full.size.height * scale);
        [[UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, size} cornerRadius:6] addClip];
        [full drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
    }];
    [self.thumbnails setObject:thumb forKey:path];
    return thumb;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 1;
    cell.accessoryView = nil;
    cell.imageView.tintColor = UIColor.secondaryLabelColor;

    if (indexPath.section == YMDownloadsSectionQueue) {
        YMDownloadJob *job = self.jobs[indexPath.row];
        cell.textLabel.text = job.title;
        BOOL failed = job.state == YMDownloadJobStateFailed;
        cell.imageView.image = [UIImage systemImageNamed:failed ? @"exclamationmark.triangle" : (job.state == YMDownloadJobStateRunning ? @"arrow.down.circle" : @"clock")];
        cell.imageView.tintColor = failed ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
        cell.detailTextLabel.text = failed ? job.errorMessage : [NSString stringWithFormat:@"%@ · %@", job.formatSummary ?: @"", job.status ?: @""];
        if (job.state == YMDownloadJobStateRunning) {
            UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
            progress.frame = CGRectMake(0, 0, 56, 4);
            progress.progress = job.progress;
            cell.accessoryView = progress;
        }
        return cell;
    }

    YMDownloadItem *item = self.items[indexPath.row];
    cell.textLabel.text = item.title;
    cell.imageView.image = [self thumbnailForItem:item];
    NSMutableArray *parts = [NSMutableArray array];
    if (item.author.length) [parts addObject:item.author];
    if (item.formatSummary.length) [parts addObject:item.formatSummary];
    else [parts addObject:item.fileURL.pathExtension.uppercaseString ?: @""];
    if (item.fileSize) [parts addObject:YMDownloadsByteCount(item.fileSize)];
    NSString *duration = YMDownloadsDuration(item.durationMs);
    if (duration) [parts addObject:duration];
    cell.detailTextLabel.text = [parts componentsJoinedByString:@" · "];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == YMDownloadsSectionQueue) {
        YMDownloadJob *job = self.jobs[indexPath.row];
        if (job.state == YMDownloadJobStateFailed) [[YMDownloadQueue sharedQueue] retryJob:job];
        return;
    }
    [self playItem:self.items[indexPath.row]];
}

#pragma mark - Actions

- (void)playItem:(YMDownloadItem *)item {
    NSURL *url = item.fileURL;
    if (!url) return;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    if (!asset.isPlayable) {
        // MKV/WebM/Opus and VP9 don't play in AVPlayer - hand them to another app.
        YMDownloadShareFile(url, self);
        return;
    }
    AVPlayerViewController *player = [AVPlayerViewController new];
    player.player = [AVPlayer playerWithURL:url];
    [self presentViewController:player animated:YES completion:^{
        [player.player play];
    }];
}

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

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
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
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:LOC(@"DELETE") handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
        [self confirmDeleteItem:item];
        done(NO);
    }];
    UIContextualAction *share = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:LOC(@"SHARE") handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
        YMDownloadShareFile(item.fileURL, self);
        done(YES);
    }];
    share.backgroundColor = UIColor.systemBlueColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[delete, share]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if (indexPath.section != YMDownloadsSectionLibrary) return nil;
    YMDownloadItem *item = self.items[indexPath.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray *actions = [NSMutableArray array];
        [actions addObject:[UIAction actionWithTitle:LOC(@"PLAY") image:[UIImage systemImageNamed:@"play"] identifier:nil handler:^(UIAction *action) {
            [self playItem:item];
        }]];
        [actions addObject:[UIAction actionWithTitle:LOC(@"SHARE") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *action) {
            YMDownloadShareFile(item.fileURL, self);
        }]];
        if (item.isVideo) {
            [actions addObject:[UIAction actionWithTitle:LOC(@"SAVE_TO_PHOTOS_ACTION") image:[UIImage systemImageNamed:@"photo.on.rectangle"] identifier:nil handler:^(UIAction *action) {
                YMDownloadSaveVideoToPhotos(item.fileURL, self);
            }]];
        }
        if (item.videoID.length) {
            [actions addObject:[UIAction actionWithTitle:LOC(@"OPEN_VIDEO") image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil handler:^(UIAction *action) {
                [self openItemOnYouTube:item];
            }]];
            [actions addObject:[UIAction actionWithTitle:LOC(@"COPY_LINK") image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(UIAction *action) {
                UIPasteboard.generalPasteboard.string = [@"https://youtu.be/" stringByAppendingString:item.videoID];
                YMDownloadShowToast(LOC(@"COPIED_TO_CLIPBOARD"), NO);
            }]];
        }
        UIAction *delete = [UIAction actionWithTitle:LOC(@"DELETE") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *action) {
            [self confirmDeleteItem:item];
        }];
        delete.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:delete];
        return [UIMenu menuWithTitle:@"" children:actions];
    }];
}

@end

void YMPresentDownloadsViewController(UIViewController *presenter) {
    presenter = presenter ?: YouModTopViewController(nil);
    if (!presenter) return;
    UINavigationController *shown = [presenter isKindOfClass:UINavigationController.class] ? (UINavigationController *)presenter : presenter.navigationController;
    if ([shown.viewControllers.firstObject isKindOfClass:YMDownloadsViewController.class]) return;
    YMDownloadsViewController *downloads = [YMDownloadsViewController new];
    downloads.showsCloseButton = YES;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:downloads];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:nav animated:YES completion:nil];
}

// Root of the Downloads tab. YouTube switches tabs by swapping the view controllers
// of its own (bar-less) navigation controller, so the screen gets a navigation
// controller of its own - for the title, search field and pushes - hosted as a
// child. The pivot bar is drawn over the tab content, so its height is added to the
// bottom safe area.
@interface YMDownloadsTabRootViewController : UIViewController
@property (nonatomic, strong) UINavigationController *contentNavigationController;
@end

@implementation YMDownloadsTabRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.contentNavigationController = [[UINavigationController alloc] initWithRootViewController:[YMDownloadsViewController new]];
    [self addChildViewController:self.contentNavigationController];
    self.contentNavigationController.view.frame = self.view.bounds;
    self.contentNavigationController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.contentNavigationController.view];
    [self.contentNavigationController didMoveToParentViewController:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat overlap = 0;
    UIView *pivotBar = YMDownloadsTabPivotBarView();
    if (pivotBar.window && pivotBar.window == self.view.window && !pivotBar.hidden && pivotBar.alpha > 0.01) {
        CGRect barFrame = [pivotBar convertRect:pivotBar.bounds toView:self.view];
        overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(barFrame));
        overlap = MAX(0, overlap - self.view.safeAreaInsets.bottom);
    }
    UIEdgeInsets insets = self.contentNavigationController.additionalSafeAreaInsets;
    if (fabs(insets.bottom - overlap) > 0.5) {
        insets.bottom = overlap;
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
    UITableViewController *list = (UITableViewController *)nav.viewControllers.firstObject;
    if ([list isKindOfClass:UITableViewController.class]) {
        UIScrollView *scroll = list.tableView;
        [scroll setContentOffset:CGPointMake(0, -scroll.adjustedContentInset.top) animated:YES];
    }
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return self.contentNavigationController.preferredStatusBarStyle;
}

@end

UIViewController *YMDownloadsTabViewController(void) {
    static YMDownloadsTabRootViewController *tab;
    if (!tab) tab = [YMDownloadsTabRootViewController new];
    return tab;
}

void YMDownloadsTabReturnToTop(UIViewController *tab) {
    if ([tab isKindOfClass:YMDownloadsTabRootViewController.class]) [(YMDownloadsTabRootViewController *)tab ym_returnToTop];
}
