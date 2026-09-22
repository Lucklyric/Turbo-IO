#import "NewsReader.h"
#import "NewsTeleprompter.h"
#import "NewsPresentation.h"
#import "ResearchUI.h"
#import <UIKit/UIKit.h>
static TIONewsFetch Fetch;
@interface TIONewsReader:UITableViewController
@property(nonatomic) BOOL enabled,busy,autoStart,showDetails,refreshQueued;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSInteger speed;
@property(nonatomic) NSString *topic,*text,*status;
@property(nonatomic) NSTimer *refresh;
@property(nonatomic,copy) TIONewsCancel cancelFetch;
@end
static TIONewsReader *Reader;
void TIONewsConfigure(TIONewsFetch fetch){Fetch=[fetch copy];}
@implementation TIONewsReader
- (instancetype)init{if((self=[super initWithStyle:UITableViewStyleInsetGrouped])){_topic=TIONewsTopic([NSUserDefaults.standardUserDefaults stringForKey:@"io.turboio.news.topic"])?:@"AI";_status=@"Off · OpenAI web search fetches news, Teleprompter auto-scrolls it";_text=@"";_speed=120;[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(teleChanged) name:@"TIONewsTeleChanged" object:nil];}return self;}
- (void)viewDidLoad{[super viewDidLoad];self.title=@"News Reader";TIOStyleResearchTable(self);}
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];[self.tableView reloadData];}
- (void)teleChanged{NSDictionary *s=TIONewsTeleStatus();if(_autoStart&&[s[@"ready"] boolValue]){_autoStart=NO;TIONewsTeleControl(3,_speed);}if(_autoStart&&![s[@"active"] boolValue]){_autoStart=NO;_status=s[@"state"];}if(!_refreshQueued){_refreshQueued=YES;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{self.refreshQueued=NO;if(self.isViewLoaded&&self.view.window)[self.tableView reloadData];});}}
- (void)stop{_enabled=NO;_busy=NO;_autoStart=NO;++_generation;if(_cancelFetch)_cancelFetch();_cancelFetch=nil;[_refresh invalidate];_refresh=nil;TIONewsTeleControl(6,_speed);_status=@"News updates stopped. Any teleprompter session was asked to exit, text kept";[self.tableView reloadData];}
- (void)toggle:(UISwitch *)sender{if(sender.on){_enabled=YES;[self fetch];}else [self stop];}
- (void)fetch{
    __weak typeof(self) timerOwner=self;
    // Enabling automatic updates during a manually-started reading must still
    // schedule the next cycle; never show an enabled switch without a timer.
    if(_enabled&&!_refresh)_refresh=[NSTimer scheduledTimerWithTimeInterval:600 repeats:YES block:^(NSTimer *t){if(![TIONewsTeleStatus()[@"active"] boolValue])[timerOwner fetch];}];
    if(_busy)return;if([TIONewsTeleStatus()[@"active"] boolValue]){_status=_enabled?@"Auto-update is on. News is fetched next cycle after the current script exits":@"Exit the current news teleprompter before updating";[self.tableView reloadData];return;}
    if(!Fetch){[self stop];_status=@"News service not configured";return;}_busy=YES;NSUInteger token=++_generation;_status=@"Fetching news via OpenAI web search…";[self.tableView reloadData];__weak typeof(self) weak=self;
    _cancelFetch=Fetch(TIONewsPrompt(_topic,NSDate.date),^(NSString *text,NSString *error){typeof(self) self=weak;if(!self||token!=self.generation)return;self.busy=NO;self.cancelFetch=nil;
        if(error){self.status=error;[self.tableView reloadData];return;}
        if(!TIONewsPages(text).count){self.status=@"News is empty or over 12,000 characters, not sent";[self.tableView reloadData];return;}
        self.text=[text stringByReplacingOccurrencesOfString:@"正在联网搜索…" withString:@""];if([TIONewsTeleStatus()[@"available"] boolValue]){self.status=@"News fetched, sending to Teleprompter";[self prepare];}else{self.status=@"News fetched. View the full text now and send after completing setup above.";[self.tableView reloadData];}
    });
}
- (void)prepare{
    if(!_text.length){_status=@"Fetch news first, or use the synthetic test script";[self.tableView reloadData];return;}
    NSString *body=TIONewsManuscript(_text);
    if(_busy||![TIONewsPresentation(TIONewsTeleStatus(),_busy,_text.length)[@"canSend"] boolValue])return;
    _autoStart=YES;
    if(!TIONewsTelePrepare(body,_speed)){_autoStart=NO;_status=@"Text is readable on the phone. Teleprompter not ready, check the channel status";}
    else _status=@"Transfer requested. Auto-scroll starts after confirmation";[self.tableView reloadData];
}
- (NSArray *)rows{BOOL needs=[TIONewsPresentation(TIONewsTeleStatus(),_busy,_text.length)[@"needsPreparation"] boolValue];return @[needs?@[@8,@10]:@[@8],@[@1,@2,@7],@[@3,@4,@5,@6],@[@0],_showDetails?@[@11,@12,@9]:@[@11]];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t{return self.rows.count;}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s{return [self.rows[s] count];}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s{return @[@"Glasses Setup",@"Topic & Content",@"Playback",@"Auto Reading",@"Experimental Tools"][s];}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s{if(s==1)return @"When ready, fetched news is sent automatically. Otherwise the full text stays on the phone. Subtitles and the microphone are not started.";if(s==3)return @"When on, an update is attempted every 10 minutes. The script is not replaced until the current one exits. Refresh is not guaranteed while the app is suspended. Closing Research only closes the screen. To stop, tap \"Exit and Stop\".";return nil;}
- (BOOL)enabledRow:(NSInteger)row{NSDictionary *p=TIONewsPresentation(TIONewsTeleStatus(),_busy,_text.length);if(row==2)return [p[@"canFetch"] boolValue];if(row==3)return [p[@"canSend"] boolValue];if(row==4)return [p[@"canPlay"] boolValue];if(row==5)return [p[@"canStop"] boolValue]||_busy||_enabled;if(row==7)return _text.length>0;if(row==9)return [p[@"canTest"] boolValue];return YES;}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip{
    NSInteger row=[self.rows[ip.section][ip.row] integerValue];NSDictionary *s=TIONewsTeleStatus(),*p=TIONewsPresentation(s,_busy,_text.length);UITableViewCell *c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];c.detailTextLabel.numberOfLines=0;c.textLabel.numberOfLines=0;c.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];c.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];c.textLabel.adjustsFontForContentSizeCategory=c.detailTextLabel.adjustsFontForContentSizeCategory=YES;c.detailTextLabel.textColor=UIColor.secondaryLabelColor;c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;c.contentView.directionalLayoutMargins=NSDirectionalEdgeInsetsMake(14,16,14,16);c.accessibilityIdentifier=[NSString stringWithFormat:@"news-action-%ld",(long)row];
    c.textLabel.text=@[@"Auto Update & Send",[@"Topic · " stringByAppendingString:_topic],_busy?@"Fetching…":([s[@"available"] boolValue]?@"Fetch & Send News":@"Fetch News"),@"Send Batch to Glasses",[s[@"playing"] boolValue]?@"Pause Reading":@"Start / Resume Reading",@"Exit and Stop",@"Scroll Speed",@"Full Text & Sources",p[@"title"],@"Synthetic Test (Offline)",@"Set Up in Official App",_showDetails?@"Hide Experimental Tools":@"Show Experimental Tools",@"Protocol Details"][row];
    if(row==0){UISwitch *v=[UISwitch new];v.on=_enabled;v.enabled=!_busy||_enabled;v.accessibilityLabel=@"News auto update and send";[v addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=v;c.detailTextLabel.text=@"Manual fetch does not turn this on";}
    if(row==2){c.detailTextLabel.text=_status;c.imageView.image=[UIImage systemImageNamed:@"arrow.clockwise"];}
    if(row==3){c.detailTextLabel.text=[p[@"canSend"] boolValue]?@"Starts after receipt is confirmed":@"Needs news, a ready Teleprompter, and no script playing";c.imageView.image=[UIImage systemImageNamed:@"paperplane"];}
    if(row==4)c.imageView.image=[UIImage systemImageNamed:[s[@"playing"] boolValue]?@"pause.circle":@"play.circle"];
    if(row==5)c.imageView.image=[UIImage systemImageNamed:@"stop.circle"];
    if(row==6)c.detailTextLabel.text=[NSString stringWithFormat:@"%ld%@ · Tap to adjust",(long)_speed,_speed>240?@" (experimental)":@""];
    if(row==7)c.detailTextLabel.text=_text.length?[NSString stringWithFormat:@"%lu chars · Source links stay on phone",(unsigned long)_text.length]:@"No news yet, fetch first";
    if(row==8){c.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];c.detailTextLabel.text=p[@"detail"];c.accessoryType=UITableViewCellAccessoryNone;c.selectionStyle=UITableViewCellSelectionStyleNone;if([p[@"needsPreparation"] boolValue])c.backgroundColor=[UIColor.systemOrangeColor colorWithAlphaComponent:0.10];}
    if(row==12){c.detailTextLabel.text=[NSString stringWithFormat:@"%@\nReady to transfer: %@ · Receipt replies: %@ · Byte offset: %@",s[@"state"],[s[@"available"] boolValue]?@"Yes":@"No",s[@"prepareReplies"],s[@"offset"]];c.accessoryType=UITableViewCellAccessoryNone;}
    BOOL enabled=[self enabledRow:row];c.textLabel.textColor=enabled?UIColor.labelColor:UIColor.tertiaryLabelColor;c.imageView.tintColor=enabled?UIColor.systemIndigoColor:UIColor.tertiaryLabelColor;if(!enabled){c.accessoryType=UITableViewCellAccessoryNone;c.selectionStyle=UITableViewCellSelectionStyleNone;c.accessibilityTraits|=UIAccessibilityTraitNotEnabled;}return c;
}
- (void)editTopic{UIAlertController *a=[UIAlertController alertControllerWithTitle:@"News Topic" message:@"Enter a public news topic only. Do not enter personal info or API keys." preferredStyle:UIAlertControllerStyleAlert];[a addTextFieldWithConfigurationHandler:^(UITextField *f){f.text=self.topic;}];[a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSString *s=TIONewsTopic(a.textFields.firstObject.text);if(!s)return;[self stop];self.topic=s;self.text=@"";[NSUserDefaults.standardUserDefaults setObject:s forKey:@"io.turboio.news.topic"];[self.tableView reloadData];}]];[self presentViewController:a animated:YES completion:nil];}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip{
    [t deselectRowAtIndexPath:ip animated:YES];
    NSIndexPath *visualIP=ip;NSInteger row=[self.rows[ip.section][ip.row] integerValue];if(![self enabledRow:row])return;ip=[NSIndexPath indexPathForRow:row inSection:0];
    if(row==10){TIOCloseResearch(self);return;}
    if(row==11){_showDetails=!_showDetails;[self.tableView reloadData];return;}
    if(ip.row==1)[self editTopic];if(ip.row==2)[self fetch];if(ip.row==3)[self prepare];
    if(ip.row==4){_autoStart=NO;unsigned command=TIONewsPlaybackCommand(TIONewsTeleStatus());if(command)TIONewsTeleControl(command,_speed);}
    if(ip.row==5)[self stop];
    if(ip.row==6){UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Auto-Scroll Speed" message:@"300 and 360 are experimental. If text skips, switch back to 240. The unit is unconfirmed. When not playing, this sets the next batch speed." preferredStyle:UIAlertControllerStyleActionSheet];for(NSNumber *n in @[@60,@90,@120,@180,@240,@300,@360]){NSString *label=n.integerValue>240?[NSString stringWithFormat:@"%@ (experimental)",n]:n.stringValue;[a addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){self.speed=n.integerValue;TIONewsTeleControl(7,self.speed);[self.tableView reloadData];}]];}[a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=[t cellForRowAtIndexPath:visualIP];[self presentViewController:a animated:YES completion:nil];}
    if(ip.row==7){UIViewController *v=[UIViewController new];v.title=@"Full Text & Sources";UITextView *text=[UITextView new];text.editable=NO;text.dataDetectorTypes=UIDataDetectorTypeLink;text.text=_text;text.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];text.adjustsFontForContentSizeCategory=YES;text.backgroundColor=UIColor.systemBackgroundColor;text.textContainerInset=UIEdgeInsetsMake(20,18,24,18);v.view=text;[self.navigationController pushViewController:v animated:YES];}
    if(ip.row==8)[self.tableView reloadData];
    if(ip.row==9){if(_busy||[TIONewsTeleStatus()[@"active"] boolValue])return;_text=[NSString stringWithFormat:@"新闻提词器测试 %@\n这是一份合成测试稿，不是实时新闻。\n第一段：验证中文完整显示，以及匀速滚动。\n第二段：验证暂停、继续与退出。\n第三段：本次没有启动实时字幕或智能跟读，不采集语音。\n测试结束，校验码 7392。",[NSUUID.UUID.UUIDString substringToIndex:4]];[self prepare];}
}
@end
void TIOOpenNewsReader(id parent){if(!Reader)Reader=[TIONewsReader new];if([parent isKindOfClass:UIViewController.class])[[(UIViewController *)parent navigationController] pushViewController:Reader animated:YES];}
id TIONewsReaderController(void){if(!Reader)Reader=[TIONewsReader new];return Reader;}
