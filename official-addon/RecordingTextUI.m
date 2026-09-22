#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import "RecordingText.h"
#import "OpenAIResponses.h"
#import "ResearchUI.h"

static NSString *const TextDomain=@"io.turboio.official-private-addon";
static NSUserDefaults *TextPrefs(void){return [[NSUserDefaults alloc]initWithSuiteName:TextDomain];}
static NSURL *TextEndpoint(NSString *s){NSURLComponents *c=[NSURLComponents componentsWithString:s];return [c.scheme.lowercaseString isEqual:@"https"]&&c.host.length&&!c.user&&!c.password&&!c.query&&!c.fragment&&([c.path hasSuffix:@"/chat/completions"]||[c.path hasSuffix:@"/responses"])?c.URL:nil;}
static NSString *TextKey(NSString *endpoint){
    NSDictionary *q=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:TextDomain,(__bridge id)kSecAttrAccount:endpoint,(__bridge id)kSecReturnData:@YES};
    CFTypeRef result=NULL;if(SecItemCopyMatching((__bridge CFDictionaryRef)q,&result)!=errSecSuccess)return @"";
    return [[NSString alloc]initWithData:CFBridgingRelease(result) encoding:NSUTF8StringEncoding]?:@"";
}
static void TextAlert(UIViewController *vc,NSString *message){UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Recordings & Notes" message:message preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[vc presentViewController:a animated:YES completion:nil];}
static NSURL *SaveText(NSString *name,NSString *text){
    // Only independent extension documents; never modify official transcripts.
    NSURL *root=[[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"TurboIOPrivateNotes"];
    NSNumber *link=nil;[root getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];if(link.boolValue)return nil;
    NSURL *dir=[root URLByAppendingPathComponent:NSUUID.UUID.UUIDString];NSError *error=nil;
    if(![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700,NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error])return nil;
    NSURL *file=[dir URLByAppendingPathComponent:name];if(![text writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error])return nil;
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600,NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:file.path error:nil];return file;
}
static void ShareText(UIViewController *vc,NSURL *file){if(!file){TextAlert(vc,@"Couldn't write a separate file. The original record is unchanged.");return;}UIActivityViewController *s=[[UIActivityViewController alloc]initWithActivityItems:@[file] applicationActivities:nil];s.popoverPresentationController.sourceView=vc.view;s.popoverPresentationController.sourceRect=CGRectMake(vc.view.bounds.size.width/2,100,1,1);[vc presentViewController:s animated:YES completion:nil];}

@interface TIORecordingSummaryJob:NSObject<NSURLSessionDataDelegate>
@property(nonatomic) NSURLSession *session;
@property(nonatomic) NSMutableData *received;
@property(nonatomic) NSArray<NSString *> *chunks;
@property(nonatomic) NSMutableArray<NSString *> *answers;
@property(nonatomic) NSString *endpoint,*model,*key;
@property(nonatomic) BOOL disableThinking,ended;
@property(nonatomic,copy) void (^progress)(NSUInteger,NSUInteger);
@property(nonatomic,copy) void (^complete)(NSString *,NSString *);
- (void)start;
- (void)cancel;
@end
@implementation TIORecordingSummaryJob
- (void)finish:(NSString *)error{if(self.ended)return;self.ended=YES;[self.session invalidateAndCancel];self.session=nil;self.key=@"";
    NSString *text=nil;if(!error){NSMutableString *out=[NSMutableString stringWithFormat:@"# Own Model Summary\n\nModel: %@\n\nSource: user-confirmed transcript text; official ASR kept. All %lu segments processed. Summaries below are per segment, not a conclusion for the whole transcript. Action items are suggestions only; no to-dos were created.\n\n",self.model,(unsigned long)self.answers.count];for(NSUInteger i=0;i<self.answers.count;i++)[out appendFormat:@"## Segment %lu\n\n%@\n\n",(unsigned long)i+1,self.answers[i]];text=out;}
    void (^done)(NSString *,NSString *)=self.complete;self.complete=nil;self.progress=nil;if(done)done(text,error);
}
- (void)next{if(self.ended)return;if(self.answers.count==self.chunks.count){[self finish:nil];return;}self.received=[NSMutableData new];
    NSDictionary *body=TIORecordingSummaryPayload(self.model,self.chunks[self.answers.count],self.disableThinking);if(!body){[self finish:@"Invalid text segments or model settings. Nothing more was sent."];return;}
    NSURL *wire=TextEndpoint(self.endpoint);if(TIOIsOpenAI(wire)){body=TIOResponsesBody(body,NO);wire=TIOResponsesURL(wire);}
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:wire];r.HTTPMethod=@"POST";r.timeoutInterval=120;[r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];[r setValue:@"application/json" forHTTPHeaderField:@"Accept"];[r setValue:[@"Bearer " stringByAppendingString:self.key] forHTTPHeaderField:@"Authorization"];r.HTTPBody=[NSJSONSerialization dataWithJSONObject:body options:0 error:nil];if(self.progress)self.progress(self.answers.count+1,self.chunks.count);[[self.session dataTaskWithRequest:r] resume];
}
- (void)start{if(!self.chunks.count||!TextEndpoint(self.endpoint)||!self.key.length){[self finish:@"Set your own Endpoint, Model, and API Key in the Research menu first."];return;}self.answers=[NSMutableArray new];NSURLSessionConfiguration *c=NSURLSessionConfiguration.ephemeralSessionConfiguration;c.HTTPCookieStorage=nil;c.URLCredentialStorage=nil;c.URLCache=nil;c.timeoutIntervalForResource=180;self.session=[NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:NSOperationQueue.mainQueue];[self next];}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t willPerformHTTPRedirection:(NSHTTPURLResponse *)r newRequest:(NSURLRequest *)req completionHandler:(void (^)(NSURLRequest *))cb{cb(nil);[self finish:@"The service returned a redirect. It was not followed, so the API Key was not sent."];}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)r completionHandler:(void (^)(NSURLSessionResponseDisposition))cb{NSInteger code=[r isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)r).statusCode:0;if(code!=200||r.expectedContentLength>2*1024*1024||![r.MIMEType.lowercaseString isEqual:@"application/json"]){cb(NSURLSessionResponseCancel);[self finish:[NSString stringWithFormat:@"The service returned no valid JSON (HTTP %ld). Error body not saved; transcript unchanged.",(long)code]];}else cb(NSURLSessionResponseAllow);}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)d{if(self.ended)return;if(self.received.length+d.length>2*1024*1024){[self finish:@"Model response exceeded the size limit."];return;}[self.received appendData:d];}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error{if(self.ended)return;if(error){[self finish:@"Connection failed or timed out, so the Summary did not finish. The transcript is kept; you can retry."];return;}id reply=[NSJSONSerialization JSONObjectWithData:self.received options:0 error:nil];NSString *answer=TIORecordingSummaryAnswer(reply)?:TIOResponsesText(reply);if(!answer){[self finish:@"The model did not finish, or returned empty or non-text output. The partial Summary was not saved."];return;}[self.answers addObject:answer];[self next];}
- (void)cancel{self.ended=YES;self.complete=nil;self.progress=nil;self.key=@"";[self.session invalidateAndCancel];self.session=nil;}
@end

@interface TIORecordingTextPanel:UIViewController<UIDocumentPickerDelegate,UITextViewDelegate>
@property(nonatomic) UITextView *editor;
@property(nonatomic) UILabel *info;
@property(nonatomic) NSString *initialText;
@property(nonatomic) TIORecordingSummaryJob *job;
@property(nonatomic) NSURL *resultFile;
@property(nonatomic) UIButton *runButton,*shareButton,*cancelButton;
@end
@implementation TIORecordingTextPanel
- (void)viewDidLoad{[super viewDidLoad];self.title=@"Transcript Summary";self.view.backgroundColor=UIColor.systemBackgroundColor;
    self.info=[UILabel new];self.info.text=@"Official ASR is kept. Import or paste a full transcript. After you confirm, only the text is uploaded; official content is not overwritten.";self.info.numberOfLines=0;self.info.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.editor=[UITextView new];self.editor.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.editor.text=self.initialText?:@"";
    UIButton *run=[UIButton buttonWithType:UIButtonTypeSystem];[run setTitle:@"Summarize with Own Model" forState:UIControlStateNormal];[run addTarget:self action:@selector(confirm) forControlEvents:UIControlEventTouchUpInside];
    UIButton *share=[UIButton buttonWithType:UIButtonTypeSystem];[share setTitle:@"Share Summary (Markdown)" forState:UIControlStateNormal];[share addTarget:self action:@selector(shareResult) forControlEvents:UIControlEventTouchUpInside];
    UIButton *cancel=[UIButton buttonWithType:UIButtonTypeSystem];[cancel setTitle:@"Cancel Summary" forState:UIControlStateNormal];[cancel addTarget:self action:@selector(cancelJob) forControlEvents:UIControlEventTouchUpInside];
    self.runButton=run;self.shareButton=share;self.cancelButton=cancel;self.editor.delegate=self;[self updateActions];
    self.info.adjustsFontForContentSizeCategory=YES;self.info.textColor=UIColor.secondaryLabelColor;self.editor.adjustsFontForContentSizeCategory=YES;self.editor.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;self.editor.layer.cornerRadius=16;self.editor.textContainerInset=UIEdgeInsetsMake(14,12,14,12);self.editor.accessibilityLabel=@"Full transcript text";
    self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
    run.configuration=UIButtonConfiguration.filledButtonConfiguration;share.configuration=UIButtonConfiguration.tintedButtonConfiguration;cancel.configuration=UIButtonConfiguration.plainButtonConfiguration;
    for(UIButton *b in @[run,share,cancel]){UIButtonConfiguration *config=b.configuration;config.contentInsets=NSDirectionalEdgeInsetsMake(12,16,12,16);b.configuration=config;b.titleLabel.adjustsFontForContentSizeCategory=YES;}
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;[self.view addSubview:scroll];
    UIStackView *stack=[[UIStackView alloc]initWithArrangedSubviews:@[self.info,self.editor,run,share,cancel]];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:stack];
    NSLayoutConstraint *preferredBottom=[scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor];preferredBottom.priority=UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[[scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[scroll.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],[scroll.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],preferredBottom,[stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],[stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],[stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],[stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],[stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],[self.editor.heightAnchor constraintEqualToConstant:260]]];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]initWithTitle:@"Import Text" style:UIBarButtonItemStylePlain target:self action:@selector(importText)];
}
- (void)viewDidDisappear:(BOOL)animated{[super viewDidDisappear:animated];if(!self.presentedViewController)[self cancelJob];}
- (void)updateActions{self.runButton.enabled=!self.job&&[self.editor.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length>0;self.shareButton.enabled=self.resultFile!=nil&&!self.job;self.cancelButton.hidden=self.job==nil;}
- (void)textViewDidChange:(UITextView *)textView{[self updateActions];}
- (void)dealloc{[_job cancel];}
- (void)cancelJob{if(!self.job)return;[self.job cancel];self.job=nil;self.editor.editable=YES;self.info.text=@"Canceled. The recording, transcript, and earlier saved summaries are unchanged.";[self updateActions];}
- (void)importText{if(self.job)return;UIDocumentPickerViewController *p=[[UIDocumentPickerViewController alloc]initForOpeningContentTypes:@[UTTypePlainText,[UTType typeWithFilenameExtension:@"md"]?:UTTypeText] asCopy:YES];p.delegate=self;[self presentViewController:p animated:YES completion:nil];}
- (void)documentPicker:(UIDocumentPickerViewController *)p didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls{NSURL *file=urls.firstObject;if(!file)return;NSNumber *bytes=nil;[file getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];NSString *text=bytes&&bytes.unsignedLongLongValue<=2*1024*1024?[NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil]:nil;if(!TIORecordingTextChunks(text)){TextAlert(self,@"Requires a non-empty UTF-8 TXT/MD file, up to 300,000 characters / 2 MB. Text is never silently truncated.");return;}self.editor.text=text;[self updateActions];self.info.text=@"Local text imported, not uploaded yet. Check that it is the full transcript.";}
- (void)confirm{if(self.job)return;NSArray *chunks=TIORecordingTextChunks(self.editor.text);if(!chunks){TextAlert(self,@"Import or paste the full transcript first (up to 300,000 characters). The clipboard is never read automatically, and on-screen snippets are not treated as the full text.");return;}
    NSUserDefaults *prefs=TextPrefs();NSString *endpoint=[prefs stringForKey:@"endpoint"]?:@"",*model=[prefs stringForKey:@"model"]?:@"";
    if(!TextEndpoint(endpoint)||!TIORecordingSummaryPayload(model,chunks[0],NO)){TextAlert(self,@"Set a valid own-model Endpoint in the Research menu first.");return;}
    NSString *source=[self.editor.text copy];BOOL thinking=[prefs boolForKey:@"deepseekDisableThinking"];
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Send Transcript Text?" message:[NSString stringWithFormat:@"Service: %@\nModel: %@\n%lu characters in %lu segments, processed in order. May incur charges. Only this text is sent: no audio, chat history, or official credentials. The original is kept and a separate Markdown file is created.",TextEndpoint(endpoint).host,model,(unsigned long)source.length,(unsigned long)chunks.count] preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weak=self;[a addAction:[UIAlertAction actionWithTitle:@"Summarize" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){typeof(self) self=weak;if(!self)return;NSString *key=TextKey(endpoint);if(!key.length){TextAlert(self,@"No API Key is set for this service. Nothing was sent.");return;}
        TIORecordingSummaryJob *job=[TIORecordingSummaryJob new];self.job=job;job.endpoint=endpoint;job.model=model;job.key=key;job.chunks=chunks;job.disableThinking=thinking;self.editor.editable=NO;self.resultFile=nil;
        [self updateActions];job.progress=^(NSUInteger i,NSUInteger n){weak.info.text=[NSString stringWithFormat:@"Summarizing segment %lu of %lu… You can cancel. Leaving this page stops it.",(unsigned long)i,(unsigned long)n];};
        job.complete=^(NSString *answer,NSString *error){typeof(self) self=weak;if(!self)return;self.job=nil;self.editor.editable=YES;[self updateActions];if(error){self.info.text=error;return;}
            NSString *document=[answer stringByAppendingFormat:@"\n---\n\n# Input Transcript (Unchanged)\n\n%@\n",source];self.resultFile=SaveText(@"录音整理.md",document);self.info.text=self.resultFile?@"All segments summarized and saved as a local Markdown file (with the input text). Tap Share to AirDrop or Save to Files.":@"Summary finished, but saving locally failed. The content is below; copy it to keep it.";self.editor.text=document;[self updateActions];
        };[job start];}]];[self presentViewController:a animated:YES completion:nil];
}
- (void)shareResult{if(!self.resultFile){TextAlert(self,@"No complete Summary yet. Canceled, timed-out, or truncated runs don't produce a file.");return;}ShareText(self,self.resultFile);}
@end

// Reads only the extension-owned final-text archive, never the official Isar/Hive store.
static NSString *CapturedLifelogText(void){
    NSURL *url=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon/final-transcripts.json"]];NSNumber *size=nil,*link=nil;[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];[url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];if(link.boolValue||!size||size.unsignedLongLongValue>32*1024*1024)return nil;
    id rows=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url]?:NSData.data options:0 error:nil];if(![rows isKindOfClass:NSArray.class]||![rows count]||[rows count]>20000)return nil;
    NSMutableString *text=[NSMutableString stringWithString:@"# Always-On Notes: Saved Text\n\nOnly final text received after saving was turned on in the add-on. Not the full history or original audio. Times are when the phone received the text.\n\n"];
    for(id r in rows){if(![r isKindOfClass:NSDictionary.class]||![r[@"text"] isKindOfClass:NSString.class]||![r[@"at"] isKindOfClass:NSString.class])return nil;[text appendFormat:@"## %@\n\n%@\n\n",r[@"at"],r[@"text"]];}return text;
}
@interface TIOLifelogExportsPanel:UITableViewController
@end
@implementation TIOLifelogExportsPanel
- (void)viewDidLoad{[super viewDidLoad];self.title=@"Saved Notes Text";TIOStyleResearchTable(self);}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s{return 2;}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s{return @"Only final text received after saving was turned on in the Profile page. This is not the full official history. For audio saving and sharing, go back to the Profile page.";}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip{UITableViewCell *c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];TIOStyleResearchCell(c);c.textLabel.text=@[@"Export Saved Text (Markdown)",@"Summarize Saved Text with Own Model",@"Original Audio Export (Not Yet Available)"][ip.row];c.detailTextLabel.numberOfLines=0;c.detailTextLabel.text=@[@"Separate local copy · AirDrop / Save to Files",@"Preview the text, then confirm sending",@"Pending: matching official cache files to sessions"][ip.row];if(ip.row==2){c.textLabel.textColor=UIColor.secondaryLabelColor;c.selectionStyle=UITableViewCellSelectionStyleNone;}else c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return c;}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip{[t deselectRowAtIndexPath:ip animated:YES];if(ip.row==2)return;dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSString *text=CapturedLifelogText();NSURL *file=ip.row==0&&text?SaveText(@"全天智记.md",text):nil;dispatch_async(dispatch_get_main_queue(),^{if(!text){TextAlert(self,@"No saved final text yet. Turn on side-channel saving in the Research menu, then use the official Always-On Notes. Older history can't be exported automatically yet.");return;}if(ip.row==0)ShareText(self,file);else {TIORecordingTextPanel *p=[TIORecordingTextPanel new];p.initialText=text;[self.navigationController pushViewController:p animated:YES];}});});}
@end
