#import "LocalListen.h"
#import "ResearchUI.h"

static NSArray<NSString *> *ModeTitles(void){return @[@"Translate",@"Script",@"Live Cues"];}
static NSArray<NSString *> *ModeDetails(void){return @[
    @"Planned: on-device speech recognition, Apple Translation, glasses captions",
    @"Planned: on-device speech recognition follows your own paged script",
    @"Planned: on-device speech recognition, your own model suggests answers"];}

@interface TIOTextPage : UIViewController
@property(nonatomic,copy) NSString *text;
@end
@implementation TIOTextPage
- (void)viewDidLoad{[super viewDidLoad];self.view.backgroundColor=UIColor.systemBackgroundColor;
    UITextView *v=[[UITextView alloc]initWithFrame:self.view.bounds];v.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    v.editable=NO;v.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];v.text=self.text;v.textContainerInset=UIEdgeInsetsMake(12,12,12,12);[self.view addSubview:v];}
@end

@interface TIOLocalListenPanel : UITableViewController
@property(nonatomic) NSUserDefaults *prefs;
@property(nonatomic) NSTimer *timer;
@property(nonatomic) NSArray<NSDictionary *> *taps;
@end
@implementation TIOLocalListenPanel
- (void)viewDidLoad{
    [super viewDidLoad];self.title=@"Local Listen";TIOStyleResearchTable(self);self.prefs=[[NSUserDefaults alloc]initWithSuiteName:@"io.turboio.official-private-addon"];
    self.tableView.tableHeaderView=TIOResearchHeader(@"EXPERIMENTAL",@"Capture glasses audio on the phone and process it with your own pipeline: translation, a script, or Live Cues. Step 0 only observes, and audio still reaches the official service.",UIColor.systemTealColor);
}
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];[self refresh];__weak typeof(self) weak=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t){[weak refresh];}];}
- (void)viewWillDisappear:(BOOL)animated{[super viewWillDisappear:animated];[self.timer invalidate];self.timer=nil;}
- (void)refresh{self.taps=TIOLocalListenTaps();[self.tableView reloadData];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t{return 4;}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s{return @[@"Mode",@"Step 0 · Observe",@"Audio Taps",@"Official Live Cues"][s];}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s{
    if(s==0)return @"The mode is saved for the next steps. Nothing is processed locally yet.";
    if(s==1)return @"Turn on, then start Live Captions or Live Cues on the glasses and talk for a while. Samples stay on this phone until you share them.";
    return nil;
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s{
    if(s==0)return 3;if(s==1)return 5;if(s==2)return MAX(1,self.taps.count);return 1;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip{
    UITableViewCell *c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];TIOStyleResearchCell(c);
    c.textLabel.numberOfLines=0;c.detailTextLabel.numberOfLines=0;
    if(ip.section==0){
        c.textLabel.text=ModeTitles()[ip.row];c.detailTextLabel.text=ModeDetails()[ip.row];
        c.accessoryType=[self.prefs integerForKey:TIOLocalListenModeKey]==ip.row?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
    }else if(ip.section==1){
        BOOL on=[self.prefs boolForKey:TIOLocalListenEnabledKey];NSTimeInterval left=TIOLocalListenRecordingRemaining();
        if(ip.row==0){c.textLabel.text=@"Observe Audio & Hints";c.detailTextLabel.text=on?@"On · Official behavior unchanged":@"Off";UISwitch *s=[UISwitch new];s.on=on;[s addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=s;c.selectionStyle=UITableViewCellSelectionStyleNone;}
        if(ip.row==1){c.textLabel.text=left>0?[NSString stringWithFormat:@"Recording… %.0f s left",left]:@"Record 30 s Raw Sample";c.detailTextLabel.text=@"Saves every observed audio packet with timing";}
        if(ip.row==2){c.textLabel.text=@"Share Samples";c.detailTextLabel.text=[NSString stringWithFormat:@"%lu files on this phone",(unsigned long)TIOLocalListenSampleFiles().count];}
        if(ip.row==3){c.textLabel.text=@"View Class Inventory";c.detailTextLabel.text=TIOLocalListenInstalled()?@"Audio, caption and Live Cues classes found at runtime":@"Available after turning on";}
        if(ip.row==4){c.textLabel.text=@"Reset Counters";}
    }else if(ip.section==2){
        if(!self.taps.count){c.textLabel.text=@"No calls yet";c.detailTextLabel.text=TIOLocalListenInstalled()?@"Start Live Captions or Live Cues on the glasses.":@"Turn on observation first.";c.selectionStyle=UITableViewCellSelectionStyleNone;return c;}
        NSDictionary *tap=self.taps[ip.row];double span=[tap[@"last"] doubleValue]-[tap[@"first"] doubleValue];NSUInteger n=[tap[@"count"] unsignedIntegerValue];
        c.textLabel.text=tap[@"key"];
        NSMutableString *d=[NSMutableString stringWithFormat:@"%lu calls · %.1f/s · %@ thread · %@",(unsigned long)n,span>0?(n-1)/span:0,tap[@"thread"],tap[@"argClass"]];
        if(tap[@"lastSize"])[d appendFormat:@"\n%@ bytes total · size %@–%@ · %@\nfirst: %@",tap[@"bytes"],tap[@"minSize"],tap[@"maxSize"],tap[@"guess"],tap[@"firstHex"]];
        else [d appendFormat:@"\nlast: %@",tap[@"preview"]];
        c.detailTextLabel.text=d;c.selectionStyle=UITableViewCellSelectionStyleNone;
    }else{
        NSDictionary *h=TIOLocalListenHint();c.selectionStyle=UITableViewCellSelectionStyleNone;
        if(!h){c.textLabel.text=@"No hint yet";c.detailTextLabel.text=@"Start Live Cues and ask a question nearby.";return c;}
        NSDateFormatter *f=[NSDateFormatter new];f.dateFormat=@"HH:mm:ss";c.textLabel.text=[NSString stringWithFormat:@"Hint %@ at %@ · %@",h[@"count"],[f stringFromDate:h[@"time"]],h[@"class"]];
        NSMutableString *d=[NSMutableString new];[h[@"fields"] enumerateKeysAndObjectsUsingBlock:^(NSString *k,NSString *v,BOOL *stop){[d appendFormat:@"%@: %@\n",k,v];}];c.detailTextLabel.text=d;
    }
    return c;
}
- (void)toggle:(UISwitch *)s{
    if(s.on&&!TIOLocalListenInstall()){s.on=NO;UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Not Available" message:@"The official listener classes were not found in this app version." preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];return;}
    TIOLocalListenSetActive(s.on);[self.prefs setBool:s.on forKey:TIOLocalListenEnabledKey];[self refresh];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip{
    [t deselectRowAtIndexPath:ip animated:YES];
    if(ip.section==0){[self.prefs setInteger:ip.row forKey:TIOLocalListenModeKey];[self refresh];return;}
    if(ip.section!=1)return;
    if(ip.row==1&&TIOLocalListenRecordingRemaining()<=0&&!TIOLocalListenRecord(30)){UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Turn On First" message:@"Turn on observation before recording a sample." preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];}
    if(ip.row==2){NSArray *files=TIOLocalListenSampleFiles();if(!files.count)return;UIActivityViewController *share=[[UIActivityViewController alloc]initWithActivityItems:files applicationActivities:nil];share.popoverPresentationController.sourceView=[t cellForRowAtIndexPath:ip];[self presentViewController:share animated:YES completion:nil];}
    if(ip.row==3){TIOTextPage *p=[TIOTextPage new];p.title=@"Class Inventory";p.text=TIOLocalListenInventory();[self.navigationController pushViewController:p animated:YES];}
    if(ip.row==4)TIOLocalListenReset();
    [self refresh];
}
@end

UIViewController *TIOLocalListenController(void){return [[TIOLocalListenPanel alloc]initWithStyle:UITableViewStyleInsetGrouped];}
