#import "ManualHUD.h"
#import "NewsTeleprompter.h"
#import "ResearchUI.h"
@interface TIOManualHUDPanel:UITableViewController
@property NSTimer *timer;
@property NSString *note;
@property NSTimeInterval started;
@end
@implementation TIOManualHUDPanel
- (void)viewDidLoad{[super viewDidLoad];self.title=@"Manual Always-On · Replace v2";TIOStyleResearchTable(self);self.note=@"First capture an official manual-mode sample and exit, then send the fixed test script. After you see 7392 you can test Replace B. Do not choose smart follow-along.";[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:@"TIONewsTeleChanged" object:nil];[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stopOwned) name:UIApplicationWillResignActiveNotification object:nil];[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stopOwned) name:@"TIOResearchClosed" object:nil];}
- (void)viewWillAppear:(BOOL)a{[super viewWillAppear:a];__weak typeof(self) w=self;if(!self.timer)self.timer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t){[w refresh];}];[self refresh];}
- (void)viewDidDisappear:(BOOL)a{[super viewDidDisappear:a];if(self.isMovingFromParentViewController||self.navigationController.isBeingDismissed||self.tabBarController.isBeingDismissed)[self stopOwned];[self.timer invalidate];self.timer=nil;}
- (void)dealloc{[self.timer invalidate];[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)refresh{NSDictionary *s=TIONewsTeleStatus();if([s[@"manual"] boolValue]&&[s[@"playing"] boolValue]){if(!self.started)self.started=NSProcessInfo.processInfo.systemUptime;}else self.started=0;if(self.isViewLoaded&&self.view.window)[self.tableView reloadData];}
- (void)stopOwned{if([TIONewsTeleStatus()[@"manual"] boolValue])TIONewsTeleControl(6,120);self.note=@"Requested exit of this manual script. Other scripts are unchanged. If the exit receipt times out, exit with the glasses button.";[self refresh];}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s{return 10;}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip{
    NSDictionary *s=TIONewsTeleStatus();UITableViewCell *c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];c.textLabel.numberOfLines=0;c.detailTextLabel.numberOfLines=0;
    NSArray *titles=@[@"Current Test Status",@"Get Manual-Mode Sample in Official App",@"1 · Send 3-Part Fixed Test Script",@"2 · Start Manual Always-On (No Auto-Scroll)",@"Preloaded Paragraph · 7392",@"Preloaded Paragraph · 8642",@"Preloaded Paragraph · 5173",@"Exit This Always-On Test",@"3 · Replace Body B · 9264",@"4 · Replace Body C · 3815"];
    c.textLabel.text=titles[ip.row];c.accessibilityIdentifier=[NSString stringWithFormat:@"manual-hud-%ld",(long)ip.row];BOOL manual=[s[@"manual"] boolValue],pending=[s[@"manualPending"] unsignedIntegerValue]!=0;
    BOOL controllable=manual&&[s[@"playing"] boolValue]&&[s[@"ready"] boolValue]&&!pending&&![s[@"manualBlocked"] boolValue]&&![s[@"replacing"] boolValue]&&![s[@"stopping"] boolValue];
    BOOL enabled=ip.row==1||(ip.row==2&&[s[@"manualAvailable"] boolValue]&&![s[@"active"] boolValue])||(ip.row==3&&manual&&[s[@"ready"] boolValue]&&![s[@"started"] boolValue]&&!pending&&! [s[@"manualBlocked"] boolValue])||(ip.row>=4&&ip.row<=6&&controllable&&[s[@"revision"] unsignedIntegerValue]==0)||(ip.row==7&&manual&&![s[@"stopping"] boolValue])||(ip.row==8&&controllable&&[s[@"revision"] unsignedIntegerValue]==0)||(ip.row==9&&controllable&&[s[@"revision"] unsignedIntegerValue]==1);
    if(ip.row==0){c.detailTextLabel.text=[NSString stringWithFormat:@"%@\n%@\nManual template: %@ · Same-device Teleprompter audio packets: %@\nTime since start receipt: %lds (not proof the lens is on)\nPending control: %@ · Replace round: %@ · Transferring: %@",self.note?:@"",s[@"state"],[s[@"manualAvailable"] boolValue]?@"ready":@"not ready",s[@"audioPackets"],self.started?(long)(NSProcessInfo.processInfo.systemUptime-self.started):0,s[@"manualPending"],s[@"revision"],[s[@"replacing"] boolValue]?@"yes":@"no"];}
    else if(ip.row==2)c.detailTextLabel.text=@"No network, no location, not real Navigation. Creates a new dedicated script without overwriting the original. Start is allowed only after receipt is confirmed.";
    else if(ip.row==3)c.detailTextLabel.text=@"Once you see 7392 you can test replacing; no need to wait 3 minutes. Exit is requested automatically 5 minutes after preparing, or when you leave this page or lock the screen.";
    else if(ip.row>=4&&ip.row<=6)c.detailTextLabel.text=@"Sends UTF-8 byte-boundary offsets. A jump counts as successful only if the check code shows on the lens.";
    else if(ip.row==8)c.detailTextLabel.text=@"Resends a new body under the same test script ID, without exit or restart. Watch for 9264, flicker, the receipt page or stale content. Exit is requested after a 20-second timeout.";
    else if(ip.row==9)c.detailTextLabel.text=@"Tap only after B showed with no issues. The second replacement is 3815. At most twice, no loop, no real Navigation. Exit right away if anything looks wrong.";
    c.textLabel.textColor=enabled?UIColor.labelColor:UIColor.secondaryLabelColor;c.selectionStyle=enabled?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;c.userInteractionEnabled=enabled||ip.row==0;return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip{[t deselectRowAtIndexPath:ip animated:YES];BOOL ok=NO;if(ip.row==1){[self stopOwned];TIOCloseResearch(self);return;}if(ip.row==2)ok=TIOTeleManualPrepare();if(ip.row==3)ok=TIONewsTeleControl(3,120);if(ip.row>=4&&ip.row<=6)ok=TIOTeleManualSeek(ip.row-4);if(ip.row==7){[self stopOwned];return;}if(ip.row==8||ip.row==9)ok=TIOTeleManualReplace();self.note=ok?@"Request sent. Watch the lens too; status replies are saved to the local diagnostics file.":@"Not sent: check the manual sample, current session and pending receipt.";[self refresh];}
@end
UIViewController *TIOManualHUDController(void){return [[TIOManualHUDPanel alloc]initWithStyle:UITableViewStyleInsetGrouped];}
