#import "LocalListen.h"
#import "ResearchUI.h"
#import "LocalASR.h"
#import "PageTeleprompter.h"

@interface TIOTextPage : UIViewController
@property(nonatomic,copy) NSString *text;
@end
@implementation TIOTextPage
- (void)viewDidLoad{[super viewDidLoad];self.view.backgroundColor=UIColor.systemBackgroundColor;
    UITextView *v=[[UITextView alloc]initWithFrame:self.view.bounds];v.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    v.editable=NO;v.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];v.text=self.text;v.textContainerInset=UIEdgeInsetsMake(12,12,12,12);[self.view addSubview:v];}
@end

// Plain editor for the one script Script mode follows. Saved when the page closes.
@interface TIOScriptEditor : UIViewController
@property(nonatomic) NSUserDefaults *prefs;
@property(nonatomic) UITextView *text;
@end
@implementation TIOScriptEditor
- (void)viewDidLoad{[super viewDidLoad];self.title=@"Script";self.view.backgroundColor=UIColor.systemBackgroundColor;
    UITextView *v=[[UITextView alloc]initWithFrame:self.view.bounds];v.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    v.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];v.textContainerInset=UIEdgeInsetsMake(12,12,12,12);v.text=[self.prefs stringForKey:TIOLocalListenScriptKey]?:@"";
    v.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;[self.view addSubview:v];self.text=v;}
- (void)viewWillDisappear:(BOOL)animated{[super viewWillDisappear:animated];[self.prefs setObject:self.text.text?:@"" forKey:TIOLocalListenScriptKey];}
@end

@interface TIOLocalListenPanel : UITableViewController
@property(nonatomic) NSUserDefaults *prefs;
@property(nonatomic) NSTimer *timer;
@property(nonatomic) NSArray<NSDictionary *> *taps;
@end
@implementation TIOLocalListenPanel
- (void)viewDidLoad{
    [super viewDidLoad];self.title=@"Local Listen";TIOStyleResearchTable(self);self.prefs=[[NSUserDefaults alloc]initWithSuiteName:@"io.turboio.official-private-addon"];
    self.tableView.tableHeaderView=TIOResearchHeader(@"EXPERIMENTAL",@"Your own captions for the glasses CC: recognition and translation run through your own OpenAI key, and the official service can be sent silence instead of your voice.",UIColor.systemTealColor);
}
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];[self refresh];__weak typeof(self) weak=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t){[weak refresh];}];}
- (void)viewWillDisappear:(BOOL)animated{[super viewWillDisappear:animated];[self.timer invalidate];self.timer=nil;}
- (NSString *)engine{return [self.prefs stringForKey:TIOLocalListenASRKey]?:TIOLocalASRAppleKind;}
- (NSString *)language{return [self.prefs stringForKey:TIOLocalListenLanguageKey]?:@"zh-CN";}
- (NSString *)targetLanguage{return [self.prefs stringForKey:TIOLocalListenTargetLanguageKey]?:@"en";}
- (void)pickMode:(UISegmentedControl *)s{[self.prefs setInteger:s.selectedSegmentIndex==1?1:0 forKey:TIOLocalListenModeKey];[self refresh];}
- (void)toggleSilence:(UISwitch *)sw{[self.prefs setBool:sw.on forKey:TIOLocalListenSilenceCloudKey];[self refresh];}
- (NSString *)openAIModel{return [self.prefs stringForKey:TIOLocalListenOpenAIModelKey]?:@"gpt-transcribe";}
- (void)pickFrom:(NSArray<NSString *> *)titles values:(NSArray<NSString *> *)values key:(NSString *)key title:(NSString *)title{
    UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:@"Applies the next time CC starts." preferredStyle:UIAlertControllerStyleActionSheet];
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
// Each function is one section led by its switch; its settings sit right under it and grey out while it is off.
enum{kCaptions,kSettings,kScript,kTranscript,kObserve,kTaps,kOfficial,kSections};
static void Dim(UITableViewCell *c,BOOL on){
    c.userInteractionEnabled=on;c.textLabel.textColor=on?UIColor.labelColor:UIColor.tertiaryLabelColor;c.detailTextLabel.textColor=on?UIColor.secondaryLabelColor:UIColor.tertiaryLabelColor;
    if([c.accessoryView isKindOfClass:UISwitch.class])((UISwitch *)c.accessoryView).enabled=on;
}
static UISwitch *Switch(UITableViewCell *c,BOOL on,id target,SEL action){UISwitch *sw=[UISwitch new];sw.on=on;[sw addTarget:target action:action forControlEvents:UIControlEventValueChanged];c.accessoryView=sw;c.selectionStyle=UITableViewCellSelectionStyleNone;return sw;}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t{return kSections;}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s{return @[@"Glasses CC · Local Captions",@"Caption Settings",@"Script",@"Transcript",@"Developer · Observe",@"Audio Taps",@"Official Results"][s];}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s{
    if(s==kCaptions)return @"On: when you start CC on the glasses, your own recognition runs on the glasses audio and its captions replace the official ones on the glasses. Off: CC works as shipped.";
    if(s==kSettings)return TIOLocalListenAutoEnabled()?@"When the glasses CC is set to translate, OpenAI Translate is used with the glasses' target language. Otherwise the engine below runs. OpenAI engines use the key from Endpoint & API Key.":@"Turn on Local Captions to change these settings.";
    if(s==kScript)return @"Script mode shows the part of your script still ahead, and moves on as you read it aloud. A line with only --- starts a new page.";
    if(s==kObserve)return @"Development only. Records audio packets and protocol counters on this phone until you share them.";
    return nil;
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s{
    if(s==kCaptions)return 3;if(s==kSettings)return 5;if(s==kScript)return 1;if(s==kTranscript)return 2;if(s==kObserve)return 5;if(s==kTaps)return MAX(1,self.taps.count);return 2;
}
- (NSString *)engineTitle{
    NSString *engine=[self engine],*glasses=TIOLocalScriptMode(self.prefs)?nil:TIOLocalGlassesTargetLanguage();
    if(TIOLocalScriptMode(self.prefs)&&[engine isEqual:TIOLocalASROpenAITranslateKind])return @"OpenAI Live · streaming (Script mode does not translate)";
    if(glasses)return [NSString stringWithFormat:@"Following glasses CC · OpenAI Translate to %@",glasses];
    if([engine isEqual:TIOLocalASROpenAIKind])return @"OpenAI · cloud, one sentence at a time";
    if([engine isEqual:TIOLocalASROpenAILiveKind])return @"OpenAI Live · cloud, streaming";
    if([engine isEqual:TIOLocalASROpenAITranslateKind])return [NSString stringWithFormat:@"OpenAI Translate · cloud, streaming, to %@",[self targetLanguage]];
    return @"Apple · on-device, streaming";
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip{
    UITableViewCell *c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];TIOStyleResearchCell(c);
    c.textLabel.numberOfLines=0;c.detailTextLabel.numberOfLines=0;
    BOOL captions=TIOLocalListenAutoEnabled(),observe=[self.prefs boolForKey:TIOLocalListenEnabledKey];
    if(ip.section==kCaptions){
        if(ip.row==0){c.textLabel.text=@"Local Captions";double peak=TIOLocalListenAutoPeak();
            c.detailTextLabel.text=captions?[NSString stringWithFormat:@"On · %@\nInput level: %@",TIOLocalListenAutoStatus(),peak>1?[NSString stringWithFormat:@"%.0f dBFS",20*log10(peak/32768)]:@"silent"]:@"Off";
            Switch(c,captions,self,@selector(toggleAuto:));}
        if(ip.row==1){c.textLabel.text=@"Show on Glasses";c.detailTextLabel.text=TIOLocalScriptMode(self.prefs)?@"Your script, following your voice":@"What is said, translated when the glasses CC asks for it";
            UISegmentedControl *mode=[[UISegmentedControl alloc]initWithItems:@[@"Translation",@"Script"]];mode.selectedSegmentIndex=TIOLocalScriptMode(self.prefs)?1:0;[mode addTarget:self action:@selector(pickMode:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView=mode;c.selectionStyle=UITableViewCellSelectionStyleNone;Dim(c,captions);mode.enabled=captions;}
        if(ip.row==2){c.textLabel.text=@"On the Glasses";c.detailTextLabel.text=TIOLocalGlassesStatus();c.selectionStyle=UITableViewCellSelectionStyleNone;Dim(c,captions);}
    }else if(ip.section==kSettings){
        BOOL translate=!TIOLocalScriptMode(self.prefs)&&(TIOLocalGlassesTargetLanguage()||[[self engine] isEqual:TIOLocalASROpenAITranslateKind]);
        if(ip.row==0){c.textLabel.text=@"Engine";c.detailTextLabel.text=[self engineTitle];}
        if(ip.row==1){if(translate){c.textLabel.text=@"Translate To";NSString *g=TIOLocalGlassesTargetLanguage();c.detailTextLabel.text=g?[g stringByAppendingString:@" · set on the glasses"]:[[self targetLanguage] isEqual:@"zh"]?@"Chinese":@"English";}
            else{c.textLabel.text=@"Spoken Language";c.detailTextLabel.text=[[self language] hasPrefix:@"zh"]?@"Chinese (Mandarin)":@"English";}}
        if(ip.row==2){c.textLabel.text=@"OpenAI Model";c.detailTextLabel.text=[[self openAIModel] stringByAppendingString:@" · OpenAI Per Sentence only"];}
        if(ip.row==3){BOOL on=TIOLocalListenSilenceCloud();c.textLabel.text=@"Silence Cloud Audio";c.detailTextLabel.text=on?@"The official service receives silence. Only OpenAI hears you.":@"The official service receives your real audio.";Switch(c,on,self,@selector(toggleSilence:));}
        if(ip.row==4){NSString *chosen=[self.prefs stringForKey:TIOLocalListenTriggerKey];c.textLabel.text=@"Audio Source";c.detailTextLabel.text=chosen.length?chosen:@"Automatic · glasses CC audio";}
        Dim(c,captions);
    }else if(ip.section==kScript){
        NSString *script=[self.prefs stringForKey:TIOLocalListenScriptKey]?:@"";NSUInteger pages=TIOPagePaginate(script,40).count;
        c.textLabel.text=@"Edit Script";c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
        c.detailTextLabel.text=script.length?[NSString stringWithFormat:@"%lu pages · %@\n%@",(unsigned long)pages,TIOLocalScriptStatus(),[script substringToIndex:MIN(script.length,(NSUInteger)80)]]:@"Empty. Paste or type your script.";
        Dim(c,captions&&TIOLocalScriptMode(self.prefs));
    }else if(ip.section==kTranscript){
        if(ip.row==0){NSString *text=TIOLocalListenTranscript();c.textLabel.text=text.length?text:@"Nothing yet";c.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];c.selectionStyle=UITableViewCellSelectionStyleNone;}
        if(ip.row==1){c.textLabel.text=@"Clear Transcript";}
    }else if(ip.section==kObserve){
        NSTimeInterval left=TIOLocalListenRecordingRemaining();
        if(ip.row==0){c.textLabel.text=@"Observe Audio & Hints";c.detailTextLabel.text=observe?@"On":@"Off";Switch(c,observe,self,@selector(toggle:));return c;}
        if(ip.row==1){c.textLabel.text=left>0?[NSString stringWithFormat:@"Recording… %.0f s left",left]:@"Record 30 s Raw Sample";c.detailTextLabel.text=@"Saves every observed audio packet with timing";}
        if(ip.row==2){c.textLabel.text=@"Share Samples";c.detailTextLabel.text=[NSString stringWithFormat:@"%lu files on this phone",(unsigned long)TIOLocalListenSampleFiles().count];}
        if(ip.row==3){c.textLabel.text=@"View Class Inventory";c.detailTextLabel.text=@"Audio, caption and Live Cues classes found at runtime";}
        if(ip.row==4){c.textLabel.text=@"Reset Counters";}
        Dim(c,observe);
    }else if(ip.section==kTaps){
        c.selectionStyle=UITableViewCellSelectionStyleNone;
        if(!self.taps.count){c.textLabel.text=@"No calls yet";c.detailTextLabel.text=TIOLocalListenInstalled()?@"Start CC on the glasses.":@"Turn on Local Captions or Observe first.";return c;}
        NSDictionary *tap=self.taps[ip.row];double span=[tap[@"last"] doubleValue]-[tap[@"first"] doubleValue];NSUInteger n=[tap[@"count"] unsignedIntegerValue];
        c.textLabel.text=tap[@"key"];
        NSMutableString *d=[NSMutableString stringWithFormat:@"%lu calls · %.1f/s · %@ thread · %@",(unsigned long)n,span>0?(n-1)/span:0,tap[@"thread"],tap[@"argClass"]];
        if(tap[@"source"])[d appendFormat:@"\nsource: %@ → 16 kHz mono",tap[@"source"]];
        if(tap[@"lastSize"])[d appendFormat:@"\n%@ bytes total · size %@–%@ · %@\nfirst: %@",tap[@"bytes"],tap[@"minSize"],tap[@"maxSize"],tap[@"guess"],tap[@"firstHex"]];
        else [d appendFormat:@"\nlast: %@",tap[@"preview"]];
        c.detailTextLabel.text=d;
    }else{
        c.selectionStyle=UITableViewCellSelectionStyleNone;
        if(ip.row==1){NSDictionary *cap=TIOLocalListenOfficialCaption();c.textLabel.text=cap?@"Last Official Caption":@"No official caption yet";
            NSMutableString *d=[NSMutableString new];[cap[@"fields"] enumerateKeysAndObjectsUsingBlock:^(NSString *k,NSString *v,BOOL *stop){[d appendFormat:@"%@: %@\n",k,v];}];c.detailTextLabel.text=cap?d:@"Appears when the official service returns a caption.";return c;}
        NSDictionary *h=TIOLocalListenHint();
        if(!h){c.textLabel.text=@"No hint yet";c.detailTextLabel.text=@"Start Live Cues and ask a question nearby.";return c;}
        NSDateFormatter *f=[NSDateFormatter new];f.dateFormat=@"HH:mm:ss";c.textLabel.text=[NSString stringWithFormat:@"Hint %@ at %@ · %@",h[@"count"],[f stringFromDate:h[@"time"]],h[@"class"]];
        NSMutableString *d=[NSMutableString new];[h[@"fields"] enumerateKeysAndObjectsUsingBlock:^(NSString *k,NSString *v,BOOL *stop){[d appendFormat:@"%@: %@\n",k,v];}];c.detailTextLabel.text=d;
    }
    return c;
}
- (void)toggleAuto:(UISwitch *)sw{
    if(!TIOLocalListenSetAuto(sw.on)){sw.on=NO;UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Not Available" message:@"The official listener classes were not found in this app version." preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];}
    [self refresh];
}
- (void)pickTrigger{
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Trigger" message:@"Which observed audio call means Live Captions is running." preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"Automatic (caption workflow audio)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self.prefs removeObjectForKey:TIOLocalListenTriggerKey];[self refresh];}]];
    for(NSDictionary *tap in self.taps)if(tap[@"lastSize"]){NSString *key=tap[@"key"];[a addAction:[UIAlertAction actionWithTitle:key style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self.prefs setObject:key forKey:TIOLocalListenTriggerKey];[self refresh];}]];}
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=self.view;a.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2,120,1,1);
    [self presentViewController:a animated:YES completion:nil];
}
- (void)toggle:(UISwitch *)s{
    if(s.on&&!TIOLocalListenInstall()){s.on=NO;UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Not Available" message:@"The official listener classes were not found in this app version." preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];return;}
    if(!s.on&&TIOLocalListenAutoEnabled())TIOLocalListenSetAuto(NO);
    TIOLocalListenSetActive(s.on);[self.prefs setBool:s.on forKey:TIOLocalListenEnabledKey];[self refresh];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip{
    [t deselectRowAtIndexPath:ip animated:YES];
    if(ip.section==kSettings){
        if(ip.row==0&&(TIOLocalScriptMode(self.prefs)||!TIOLocalGlassesTargetLanguage()))[self pickFrom:@[@"Apple · On-Device",@"OpenAI Live · Streaming",@"OpenAI · Per Sentence",@"OpenAI Translate · Streaming"] values:@[TIOLocalASRAppleKind,TIOLocalASROpenAILiveKind,TIOLocalASROpenAIKind,TIOLocalASROpenAITranslateKind] key:TIOLocalListenASRKey title:@"Recognition Engine"];
        BOOL translate=!TIOLocalScriptMode(self.prefs)&&(TIOLocalGlassesTargetLanguage()||[[self engine] isEqual:TIOLocalASROpenAITranslateKind]);
        if(ip.row==1&&translate&&!TIOLocalGlassesTargetLanguage())[self pickFrom:@[@"English",@"Chinese"] values:@[@"en",@"zh"] key:TIOLocalListenTargetLanguageKey title:@"Translate To"];
        else if(ip.row==1&&!translate)[self pickFrom:@[@"Chinese (Mandarin)",@"English"] values:@[@"zh-CN",@"en-US"] key:TIOLocalListenLanguageKey title:@"Spoken Language"];
        if(ip.row==2)[self editModel];
        if(ip.row==4)[self pickTrigger];
        return;
    }
    if(ip.section==kScript){TIOScriptEditor *e=[TIOScriptEditor new];e.prefs=self.prefs;[self.navigationController pushViewController:e animated:YES];return;}
    if(ip.section==kTranscript){if(ip.row==1){TIOLocalListenClearTranscript();[self refresh];}return;}
    if(ip.section!=kObserve)return;
    if(ip.row==1&&TIOLocalListenRecordingRemaining()<=0&&!TIOLocalListenRecord(30)){UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Turn On First" message:@"Turn on observation before recording a sample." preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];}
    if(ip.row==2){NSArray *files=TIOLocalListenSampleFiles();if(!files.count)return;UIActivityViewController *share=[[UIActivityViewController alloc]initWithActivityItems:files applicationActivities:nil];share.popoverPresentationController.sourceView=[t cellForRowAtIndexPath:ip];[self presentViewController:share animated:YES completion:nil];}
    if(ip.row==3){TIOTextPage *p=[TIOTextPage new];p.title=@"Class Inventory";p.text=TIOLocalListenInventory();[self.navigationController pushViewController:p animated:YES];}
    if(ip.row==4)TIOLocalListenReset();
    [self refresh];
}
@end

UIViewController *TIOLocalListenController(void){return [[TIOLocalListenPanel alloc]initWithStyle:UITableViewStyleInsetGrouped];}
