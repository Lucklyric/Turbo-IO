#import "LocalListen.h"
#import "ResearchUI.h"
#import "LocalASR.h"

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
@property(nonatomic) TIOLocalASR *asr;
@property(nonatomic) TIOPhoneMic *mic;
@property(nonatomic,copy) NSString *asrStatus;
@property(nonatomic) NSMutableArray<NSString *> *lines;
@property(nonatomic,copy) NSString *partial;
@end
@implementation TIOLocalListenPanel
- (void)viewDidLoad{
    [super viewDidLoad];self.title=@"Local Listen";TIOStyleResearchTable(self);self.prefs=[[NSUserDefaults alloc]initWithSuiteName:@"io.turboio.official-private-addon"];
    self.tableView.tableHeaderView=TIOResearchHeader(@"EXPERIMENTAL",@"Capture glasses audio on the phone and process it with your own pipeline: translation, a script, or Live Cues. Step 0 only observes, and audio still reaches the official service.",UIColor.systemTealColor);
}
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];[self refresh];__weak typeof(self) weak=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t){[weak refresh];}];}
- (void)viewWillDisappear:(BOOL)animated{[super viewWillDisappear:animated];[self.timer invalidate];self.timer=nil;}
- (void)dealloc{[_mic stop];[_asr stop];}
- (NSString *)engine{return [self.prefs stringForKey:TIOLocalListenASRKey]?:TIOLocalASRAppleKind;}
- (NSString *)language{return [self.prefs stringForKey:TIOLocalListenLanguageKey]?:@"zh-CN";}
- (NSString *)openAIModel{return [self.prefs stringForKey:TIOLocalListenOpenAIModelKey]?:@"gpt-transcribe";}
- (void)toggleMic{
    if(self.mic){[self.mic stop];[self.asr stop];self.mic=nil;self.asr=nil;[self refresh];return;}
    TIOLocalASR *asr=[TIOLocalASR engineOfKind:[self engine]];asr.language=[self language];asr.model=[self openAIModel];
    asr.keyProvider=^NSString *{return TIOLocalListenOpenAIKey();};__weak typeof(self) weak=self;
    asr.onStatus=^(NSString *status){weak.asrStatus=status;[weak refresh];};
    asr.onText=^(NSString *text,BOOL final){typeof(self) s=weak;if(!s)return;
        if(final){s.partial=nil;[s.lines addObject:text];if(s.lines.count>30)[s.lines removeObjectAtIndex:0];}else s.partial=text;[s refresh];};
    TIOPhoneMic *mic=[TIOPhoneMic new];mic.onPCM=^(NSData *pcm){[asr appendPCM16:pcm];};
    self.asr=asr;self.mic=mic;self.lines=self.lines?:[NSMutableArray new];self.asrStatus=@"Starting…";
    [mic startWithCompletion:^(NSString *error){if(error){weak.asrStatus=error;[weak.asr stop];weak.mic=nil;weak.asr=nil;[weak refresh];return;}[asr start];}];
    [self refresh];
}
- (void)pickFrom:(NSArray<NSString *> *)titles values:(NSArray<NSString *> *)values key:(NSString *)key title:(NSString *)title{
    UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:self.mic?@"Applies the next time the test starts.":nil preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSUInteger i=0;i<titles.count;i++)[a addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self.prefs setObject:values[i] forKey:key];[self refresh];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=self.view;a.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2,120,1,1);
    [self presentViewController:a animated:YES completion:nil];
}
- (void)editModel{
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"OpenAI Transcription Model" message:@"For example gpt-transcribe or gpt-4o-mini-transcribe." preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.text=[self openAIModel];f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.autocorrectionType=UITextAutocorrectionTypeNo;}];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSString *m=[a.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(m.length&&m.length<80)[self.prefs setObject:m forKey:TIOLocalListenOpenAIModelKey];[self refresh];}]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)refresh{self.taps=TIOLocalListenTaps();[self.tableView reloadData];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t{return 6;}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s{return @[@"Mode",@"Recognition",@"Transcript",@"Step 0 · Observe",@"Audio Taps",@"Official Live Cues"][s];}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s{
    if(s==0)return @"The mode is saved for the next steps. Nothing is processed locally yet.";
    if(s==1)return @"Apple runs on this phone and streams words as you speak. OpenAI sends each sentence to api.openai.com after a short pause, using the key from Endpoint & API Key. The test uses the phone microphone until glasses audio is decoded.";
    if(s==3)return @"Turn on, then start Live Captions or Live Cues on the glasses and talk for a while. Samples stay on this phone until you share them.";
    return nil;
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s{
    if(s==0)return 3;if(s==1)return 4;if(s==2)return 2;if(s==3)return 5;if(s==4)return MAX(1,self.taps.count);return 1;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip{
    UITableViewCell *c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];TIOStyleResearchCell(c);
    c.textLabel.numberOfLines=0;c.detailTextLabel.numberOfLines=0;
    if(ip.section==0){
        c.textLabel.text=ModeTitles()[ip.row];c.detailTextLabel.text=ModeDetails()[ip.row];
        c.accessoryType=[self.prefs integerForKey:TIOLocalListenModeKey]==ip.row?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
    }else if(ip.section==1){
        BOOL openai=[[self engine] isEqual:TIOLocalASROpenAIKind];
        if(ip.row==0){c.textLabel.text=@"Engine";c.detailTextLabel.text=openai?@"OpenAI · cloud, one sentence at a time":@"Apple · on-device, streaming";}
        if(ip.row==1){c.textLabel.text=@"Language";c.detailTextLabel.text=[[self language] hasPrefix:@"zh"]?@"Chinese (Mandarin)":@"English";}
        if(ip.row==2){c.textLabel.text=@"OpenAI Model";c.detailTextLabel.text=openai?[self openAIModel]:[[self openAIModel] stringByAppendingString:@" · used when the engine is OpenAI"];}
        if(ip.row==3){c.textLabel.text=self.mic?@"Stop Phone Mic Test":@"Start Phone Mic Test";c.textLabel.textColor=self.mic?UIColor.systemRedColor:self.view.tintColor;c.detailTextLabel.text=[NSString stringWithFormat:@"%@\nInput: %@",self.asrStatus?:@"Idle",[TIOPhoneMic inputRoute]];}
    }else if(ip.section==2){
        if(ip.row==0){c.textLabel.text=self.lines.count||self.partial?[[self.lines componentsJoinedByString:@"\n"] stringByAppendingString:self.partial?[@"\n" stringByAppendingString:self.partial]:@""]:@"Nothing yet";c.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];c.selectionStyle=UITableViewCellSelectionStyleNone;}
        if(ip.row==1){c.textLabel.text=@"Clear Transcript";}
    }else if(ip.section==3){
        BOOL on=[self.prefs boolForKey:TIOLocalListenEnabledKey];NSTimeInterval left=TIOLocalListenRecordingRemaining();
        if(ip.row==0){c.textLabel.text=@"Observe Audio & Hints";c.detailTextLabel.text=on?@"On · Official behavior unchanged":@"Off";UISwitch *s=[UISwitch new];s.on=on;[s addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=s;c.selectionStyle=UITableViewCellSelectionStyleNone;}
        if(ip.row==1){c.textLabel.text=left>0?[NSString stringWithFormat:@"Recording… %.0f s left",left]:@"Record 30 s Raw Sample";c.detailTextLabel.text=@"Saves every observed audio packet with timing";}
        if(ip.row==2){c.textLabel.text=@"Share Samples";c.detailTextLabel.text=[NSString stringWithFormat:@"%lu files on this phone",(unsigned long)TIOLocalListenSampleFiles().count];}
        if(ip.row==3){c.textLabel.text=@"View Class Inventory";c.detailTextLabel.text=TIOLocalListenInstalled()?@"Audio, caption and Live Cues classes found at runtime":@"Available after turning on";}
        if(ip.row==4){c.textLabel.text=@"Reset Counters";}
    }else if(ip.section==4){
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
    if(ip.section==1){
        if(ip.row==0)[self pickFrom:@[@"Apple · On-Device",@"OpenAI · Cloud"] values:@[TIOLocalASRAppleKind,TIOLocalASROpenAIKind] key:TIOLocalListenASRKey title:@"Recognition Engine"];
        if(ip.row==1)[self pickFrom:@[@"Chinese (Mandarin)",@"English"] values:@[@"zh-CN",@"en-US"] key:TIOLocalListenLanguageKey title:@"Language"];
        if(ip.row==2)[self editModel];
        if(ip.row==3)[self toggleMic];
        return;
    }
    if(ip.section==2){if(ip.row==1){[self.lines removeAllObjects];self.partial=nil;[self refresh];}return;}
    if(ip.section!=3)return;
    if(ip.row==1&&TIOLocalListenRecordingRemaining()<=0&&!TIOLocalListenRecord(30)){UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Turn On First" message:@"Turn on observation before recording a sample." preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];}
    if(ip.row==2){NSArray *files=TIOLocalListenSampleFiles();if(!files.count)return;UIActivityViewController *share=[[UIActivityViewController alloc]initWithActivityItems:files applicationActivities:nil];share.popoverPresentationController.sourceView=[t cellForRowAtIndexPath:ip];[self presentViewController:share animated:YES completion:nil];}
    if(ip.row==3){TIOTextPage *p=[TIOTextPage new];p.title=@"Class Inventory";p.text=TIOLocalListenInventory();[self.navigationController pushViewController:p animated:YES];}
    if(ip.row==4)TIOLocalListenReset();
    [self refresh];
}
@end

UIViewController *TIOLocalListenController(void){return [[TIOLocalListenPanel alloc]initWithStyle:UITableViewStyleInsetGrouped];}
