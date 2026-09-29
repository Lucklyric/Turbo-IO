#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "LocalSessions.h"
#import "ResearchUI.h"

// Research page for saved glasses sessions: grouped by day, newest first, each shareable as
// a transcript (Markdown) or audio (M4A, WAV if conversion fails). Share copies live in
// Library/Caches/TurboIOSessionsExport and are replaced on the next export.
@interface TIOSessionTextPage : UIViewController
@property(nonatomic,copy) NSString *text;
@end
@implementation TIOSessionTextPage
- (void)viewDidLoad{[super viewDidLoad];self.view.backgroundColor=UIColor.systemBackgroundColor;
    UITextView *v=[[UITextView alloc]initWithFrame:self.view.bounds];v.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    v.editable=NO;v.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];v.text=self.text;v.textContainerInset=UIEdgeInsetsMake(12,12,12,12);[self.view addSubview:v];}
@end

@interface TIOSessionsPanel : UITableViewController
@property(nonatomic) NSArray<NSString *> *days;
@property(nonatomic) NSDictionary<NSString *,NSArray<NSDictionary *> *> *byDay;
@property(nonatomic) unsigned long long bytes;
@property(nonatomic) BOOL busy;
@end
@implementation TIOSessionsPanel
- (void)viewDidLoad{[super viewDidLoad];self.title=@"Glasses Sessions";TIOStyleResearchTable(self);
    self.tableView.tableHeaderView=TIOResearchHeader(@"SESSIONS",@"Every Local Captions session, by day: what was said, translations, hints, and the audio your own engines heard. Kept only on this phone.",UIColor.systemTealColor);
    self.refreshControl=[UIRefreshControl new];[self.refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];}
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];[self refresh];}
- (void)refresh{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSArray *rows=TIOSessionList();unsigned long long bytes=TIOSessionsBytes();NSMutableArray *days=[NSMutableArray new];NSMutableDictionary *by=[NSMutableDictionary new];
        for(NSDictionary *r in rows){NSString *d=r[@"day"];if(!by[d]){by[d]=[NSMutableArray new];[days addObject:d];}[by[d] addObject:r];}
        dispatch_async(dispatch_get_main_queue(),^{self.days=days;self.byDay=by;self.bytes=bytes;[self.refreshControl endRefreshing];[self.tableView reloadData];});
    });
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t{return 1+MAX(1,(NSInteger)self.days.count);}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s{if(s==0)return 3;return self.days.count?(NSInteger)self.byDay[self.days[s-1]].count:1;}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s{
    if(s==0)return @"Saving";if(!self.days.count)return @"Sessions";
    NSDateFormatter *in=[NSDateFormatter new];in.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];in.dateFormat=@"yyyy-MM-dd";NSDate *d=[in dateFromString:self.days[s-1]];
    NSDateFormatter *out=[NSDateFormatter new];out.dateStyle=NSDateFormatterFullStyle;out.doesRelativeDateFormatting=YES;return d?[out stringFromDate:d]:self.days[s-1];
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s{
    return s==0?[NSString stringWithFormat:@"Applies from the next session. Audio is 16 kHz mono, about 115 MB an hour, shared as M4A. Excluded from backup and never uploaded. Using %@.",[NSByteCountFormatter stringFromByteCount:(long long)self.bytes countStyle:NSByteCountFormatterCountStyleFile]]:nil;
}
static NSString *Clock(double seconds){int t=(int)seconds;return t>=3600?[NSString stringWithFormat:@"%d:%02d:%02d",t/3600,t/60%60,t%60]:[NSString stringWithFormat:@"%d:%02d",t/60,t%60];}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip{
    UITableViewCell *c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];TIOStyleResearchCell(c);c.textLabel.numberOfLines=0;c.detailTextLabel.numberOfLines=0;
    if(ip.section==0){
        if(ip.row<2){BOOL audio=ip.row==1,on=audio?TIOSessionsSavingAudio():TIOSessionsSaving();
            c.textLabel.text=audio?@"Include Audio":@"Save Sessions";
            c.detailTextLabel.text=audio?(on?@"Audio and transcript":@"Transcript only"):(on?@"On · each Local Captions session is saved":@"Off · nothing is saved");
            UISwitch *sw=[UISwitch new];sw.on=on;sw.tag=ip.row;[sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=sw;c.selectionStyle=UITableViewCellSelectionStyleNone;
            if(audio&&!TIOSessionsSaving()){sw.enabled=NO;c.textLabel.textColor=UIColor.tertiaryLabelColor;}}
        else{c.textLabel.text=@"Export All Transcripts";c.detailTextLabel.text=@"One Markdown file, grouped by day";c.textLabel.textColor=self.days.count?UIColor.systemBlueColor:UIColor.tertiaryLabelColor;}
        return c;
    }
    if(!self.days.count){c.textLabel.text=@"No sessions yet";c.detailTextLabel.text=@"Turn on Local Captions under Model & Chat, then start CC or Live Cues on the glasses.";c.selectionStyle=UITableViewCellSelectionStyleNone;return c;}
    NSDictionary *r=self.byDay[self.days[ip.section-1]][ip.row];NSDateFormatter *f=[NSDateFormatter new];f.dateFormat=@"HH:mm";
    NSString *length=r[@"end"]?Clock([r[@"end"] timeIntervalSinceDate:r[@"start"]]):[r[@"active"] boolValue]?@"recording now":@"ended early";
    c.textLabel.text=[NSString stringWithFormat:@"%@ · %@ · %@",[f stringFromDate:r[@"start"]],r[@"mode"],length];
    NSMutableString *d=[NSMutableString stringWithFormat:@"%@ lines",r[@"lines"]];if([r[@"audioBytes"] longLongValue]>0)[d appendFormat:@" · audio %@",Clock([r[@"audioBytes"] doubleValue]/32000)];
    if([r[@"preview"] length])[d appendFormat:@"\n%@",[r[@"preview"] length]>100?[[r[@"preview"] substringToIndex:100] stringByAppendingString:@"…"]:r[@"preview"]];
    c.detailTextLabel.text=d;c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return c;
}
- (void)toggle:(UISwitch *)sw{if(sw.tag==0)TIOSessionsSetSaving(sw.on);else TIOSessionsSetSavingAudio(sw.on);[self.tableView reloadData];}
- (NSDictionary *)rowAt:(NSIndexPath *)ip{return ip.section>0&&self.days.count?self.byDay[self.days[ip.section-1]][ip.row]:nil;}
- (void)message:(NSString *)text{UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Glasses Sessions" message:text preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];}
static NSURL *ExportDir(void){
    NSURL *dir=[[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"TurboIOSessionsExport" isDirectory:YES];
    [NSFileManager.defaultManager removeItemAtURL:dir error:nil];[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];return dir;
}
static NSString *Name(NSDictionary *r){NSDateFormatter *f=[NSDateFormatter new];f.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];f.dateFormat=@"yyyy-MM-dd HHmm";return [NSString stringWithFormat:@"%@ %@",[f stringFromDate:r[@"start"]],r[@"mode"]];}
- (void)share:(NSArray<NSURL *> *)files from:(NSIndexPath *)ip{
    if(!files.count){[self message:@"Nothing to share for this session."];return;}
    UIActivityViewController *s=[[UIActivityViewController alloc]initWithActivityItems:files applicationActivities:nil];
    UIView *v=ip?[self.tableView cellForRowAtIndexPath:ip]:nil;s.popoverPresentationController.sourceView=v?:self.view;if(!v)s.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2,100,1,1);
    [self presentViewController:s animated:YES completion:nil];
}
// Builds the share copies off the main thread; audio converts to M4A, falling back to the WAV.
- (void)export:(NSDictionary *)r transcript:(BOOL)text audio:(BOOL)audio from:(NSIndexPath *)ip{
    if(self.busy)return;self.busy=YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSURL *dir=ExportDir();NSMutableArray *files=[NSMutableArray new];NSString *name=Name(r);
        NSURL *t=text?TIOSessionTranscriptFile(r[@"url"]):nil;
        if(t){NSURL *copy=[dir URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"md"]];if([NSFileManager.defaultManager copyItemAtURL:t toURL:copy error:nil])[files addObject:copy];}
        NSURL *wav=audio?TIOSessionAudioFile(r[@"url"]):nil;
        void (^done)(void)=^{dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;[self share:files from:ip];});};
        if(!wav){done();return;}
        AVAssetExportSession *e=[AVAssetExportSession exportSessionWithAsset:[AVURLAsset URLAssetWithURL:wav options:nil] presetName:AVAssetExportPresetAppleM4A];
        NSURL *m4a=[dir URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"m4a"]];e.outputURL=m4a;e.outputFileType=AVFileTypeAppleM4A;
        if(!e){[files addObject:wav];done();return;}
        [e exportAsynchronouslyWithCompletionHandler:^{[files addObject:e.status==AVAssetExportSessionStatusCompleted?m4a:wav];done();}];
    });
}
- (void)exportAll{
    if(self.busy||!self.days.count)return;self.busy=YES;NSArray *days=self.days;NSDictionary *by=self.byDay;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSMutableString *md=[NSMutableString stringWithString:@"# Glasses Sessions\n"];
        for(NSString *day in days.reverseObjectEnumerator){[md appendFormat:@"\n## %@\n",day];
            for(NSDictionary *r in [by[day] reverseObjectEnumerator]){NSURL *t=TIOSessionTranscriptFile(r[@"url"]);NSString *s=t?[NSString stringWithContentsOfURL:t encoding:NSUTF8StringEncoding error:nil]:nil;
                if(s.length)[md appendFormat:@"\n%@",[s hasPrefix:@"# "]?[@"### " stringByAppendingString:[s substringFromIndex:2]]:s];}}
        NSURL *file=[ExportDir() URLByAppendingPathComponent:[NSString stringWithFormat:@"Glasses Sessions %@ to %@.md",days.lastObject,days.firstObject]];
        BOOL ok=[md writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
        dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;if(ok)[self share:@[file] from:[NSIndexPath indexPathForRow:2 inSection:0]];else [self message:@"Couldn't write the export file."];});
    });
}
- (void)confirmDelete:(NSDictionary *)r{
    if([r[@"active"] boolValue]){[self message:@"This session is still recording. End it on the glasses first."];return;}
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Delete Session?" message:[NSString stringWithFormat:@"%@: its transcript and audio are removed from this phone.",Name(r)] preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){if(!TIOSessionDelete(r[@"url"]))[self message:@"Couldn't delete this session."];[self refresh];}]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip{
    [t deselectRowAtIndexPath:ip animated:YES];
    if(ip.section==0){if(ip.row==2)[self exportAll];return;}
    NSDictionary *r=[self rowAt:ip];if(!r)return;BOOL audio=[r[@"audioBytes"] longLongValue]>0;
    UIAlertController *a=[UIAlertController alertControllerWithTitle:Name(r) message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"View Transcript" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSURL *f=TIOSessionTranscriptFile(r[@"url"]);TIOSessionTextPage *p=[TIOSessionTextPage new];p.title=Name(r);p.text=f?[NSString stringWithContentsOfURL:f encoding:NSUTF8StringEncoding error:nil]:@"";[self.navigationController pushViewController:p animated:YES];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"Share Transcript" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self export:r transcript:YES audio:NO from:ip];}]];
    if(audio){[a addAction:[UIAlertAction actionWithTitle:@"Share Audio" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self export:r transcript:NO audio:YES from:ip];}]];
        [a addAction:[UIAlertAction actionWithTitle:@"Share Transcript and Audio" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self export:r transcript:YES audio:YES from:ip];}]];}
    [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){[self confirmDelete:r];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *v=[t cellForRowAtIndexPath:ip];a.popoverPresentationController.sourceView=v?:self.view;
    [self presentViewController:a animated:YES completion:nil];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)t trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip{
    NSDictionary *r=[self rowAt:ip];if(!r)return nil;
    UIContextualAction *del=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(UIContextualAction *x,UIView *v,void (^done)(BOOL)){[self confirmDelete:r];done(NO);}];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}
@end

UIViewController *TIOSessionsController(void){return [[TIOSessionsPanel alloc]initWithStyle:UITableViewStyleInsetGrouped];}
