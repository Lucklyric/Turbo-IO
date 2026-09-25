#import "LocalListen.h"
#import "SubtitleHUDCore.h"
#import "ProtocolContext.h"
#import <objc/message.h>
#import <os/lock.h>

// Local captions on the glasses: while the official Live Captions session is open,
// our own recognition and translation are written into that same session. Main thread only.
static __weak id Plugin;
static NSDictionary *Route;
static NSString *SID,*Source,*Target,*State=@"Waiting for Live Captions on the glasses";
static BOOL Sending,Pending;
// The first text of each session starts with this line, so our sessions are recognizable on the glasses.
static NSString *const ResearchMark=@"[Research]\n";
static BOOL Marked;
static NSTimeInterval PendingSince;
static NSUInteger Sent,Answered;
static NSString *LastResult;
static NSDictionary *StartJSON;
// Read from the audio thread: official audio is silenced only while a CC session is open.
static _Atomic bool Open;
BOOL TIOLocalGlassesSessionOpen(void){return Open;}
static NSTimeInterval Now(void){return NSProcessInfo.processInfo.systemUptime;}
static id Get(id o,NSString *k){@try{return [o valueForKey:k];}@catch(NSException *e){return nil;}}
static NSData *Bytes(id o){if([o isKindOfClass:NSData.class])return o;id b=Get(o,@"data");return [b isKindOfClass:NSData.class]?b:nil;}
static void RememberSettings(NSDictionary *set);
static NSMutableArray<NSDictionary *> *Outbox;
static NSMutableArray *LastSent;
static NSMutableString *RoundSource,*RoundTarget;
static NSUInteger RoundSentences;
NSString *TIOLocalGlassesStatus(void){return [NSString stringWithFormat:@"%@ · sent %lu, answered %lu",State,(unsigned long)Sent,(unsigned long)Answered];}
// Development snapshot for diagnostics.json, kept on this phone: lastSent holds recent caption text.
NSDictionary *TIOLocalGlassesDiagnostics(void){return @{@"state":State,@"sid":SID?:@"",@"route":@(Route!=nil),@"plugin":@(Plugin!=nil),@"sent":@(Sent),@"answered":@(Answered),@"lastResult":LastResult?:@"",@"startMessage":StartJSON?:@{},@"lastSent":LastSent?:@[]};}
// Live Captions is started from the glasses: an inbound type 1 opens the session and
// type 4 carries its audio, both under the session ID our text must use.
void TIOLocalGlassesObserveEvent(NSDictionary *event){
    if(![event[@"eventType"] isEqual:@"messageReceived"])return;NSDictionary *m=event[@"message"];
    if(![m isKindOfClass:NSDictionary.class]||![m[@"businessId"] isEqual:@19]||![m[@"deviceId"] isKindOfClass:NSString.class])return;
    NSDictionary *e=TIOSubtitleEnvelope(Bytes(m[@"payload"])),*j=e[@"json"];NSString *sid=j[@"sid"];
    if(![sid isKindOfClass:NSString.class]||!sid.length)return;
    if([e[@"type"] isEqual:@3]){if([sid isEqual:SID]){SID=nil;Open=false;State=@"Live Captions ended on the glasses";}return;}
    if(![e[@"type"] isEqual:@1]&&![e[@"type"] isEqual:@4])return;
    if([e[@"type"] isEqual:@1]){StartJSON=j;RememberSettings(j[@"settings"]);}
    if([sid isEqual:SID]&&Route)return;
    id plugin=TIOProtocolPlugin();
    if(!plugin){State=@"Glasses session seen, but no official plugin captured yet";return;}
    Plugin=plugin;Route=@{@"deviceId":m[@"deviceId"],@"businessId":@19};SID=sid;Open=true;Source=Target=nil;[Outbox removeAllObjects];[RoundSource setString:@""];[RoundTarget setString:@""];RoundSentences=0;Marked=NO;Pending=NO;
    State=@"Live Captions session from the glasses, local captions go to it";
}

void TIOLocalGlassesObserveCall(id plugin,NSString *method,NSDictionary *args){
    if(Sending||![method isEqual:@"rayneonet_sendMessage"]||![args[@"businessId"] isEqual:@19])return;
    NSDictionary *e=TIOSubtitleEnvelope(Bytes(args[@"payload"])),*j=e[@"json"];NSString *sid=j[@"sid"];
    if(![sid isKindOfClass:NSString.class]||!sid.length)return;
    // The phone answers the glasses' start with type 2, whose final_settings (the languages
    // chosen in the app) override the ones the glasses asked for.
    if([e[@"type"] isEqual:@2]&&[j[@"final_settings"] isKindOfClass:NSDictionary.class]){RememberSettings(j[@"final_settings"]);return;}
    if([e[@"type"] isEqual:@1]||([e[@"type"] isEqual:@7]&&[j[@"config"] isKindOfClass:NSDictionary.class]&&[j[@"config"][@"is_display"] isEqual:@YES])){
        NSMutableDictionary *r=[args mutableCopy];[r removeObjectForKey:@"payload"];
        Plugin=plugin;Route=r;SID=sid;Open=true;Source=Target=nil;[Outbox removeAllObjects];[RoundSource setString:@""];[RoundTarget setString:@""];RoundSentences=0;Marked=NO;Pending=NO;State=@"Live Captions session open, local captions go to the glasses";
    }else if([sid isEqual:SID]&&[e[@"type"] isEqual:@3]){SID=nil;Open=false;State=@"Live Captions session ended";}
}
static void Flush(void);
// Outgoing messages. A newer partial replaces a queued partial; finished sentences are never dropped.
static void Enqueue(NSDictionary *j,BOOL final){
    if(!SID)return;if(!Outbox)Outbox=[NSMutableArray new];
    if(!final&&[Outbox.lastObject[@"partial"] boolValue])[Outbox removeLastObject];
    [Outbox addObject:@{@"json":j,@"partial":@(!final)}];Flush();
}
static void Send(NSDictionary *j){
    // Development aid: the last messages sent, kept on this phone for diagnostics.json.
    if(!LastSent)LastSent=[NSMutableArray new];[LastSent addObject:j];if(LastSent.count>10)[LastSent removeObjectAtIndex:0];
    NSData *data=TIOSubtitlePacket(5,j);id plugin=Plugin;
    Class td=NSClassFromString(@"FlutterStandardTypedData"),call=NSClassFromString(@"FlutterMethodCall");
    SEL typed=NSSelectorFromString(@"typedDataWithBytes:"),make=NSSelectorFromString(@"methodCallWithMethodName:arguments:"),handle=NSSelectorFromString(@"handleMethodCall:result:");
    if(!data||!plugin||![td respondsToSelector:typed]||![call respondsToSelector:make]||![plugin respondsToSelector:handle]){State=@"Glasses send unavailable";return;}
    NSMutableDictionary *args=[Route mutableCopy];args[@"payload"]=((id(*)(id,SEL,id))objc_msgSend)(td,typed,data);
    id c=((id(*)(id,SEL,id,id))objc_msgSend)(call,make,@"rayneonet_sendMessage",args);
    Pending=YES;PendingSince=Now();Sending=YES;Sent++;
    @try{((void(*)(id,SEL,id,id))objc_msgSend)(plugin,handle,c,[^(id result){NSString *r=[[result description] substringToIndex:MIN([result description].length,(NSUInteger)200)];dispatch_async(dispatch_get_main_queue(),^{Answered++;LastResult=r?:@"nil";Pending=NO;Flush();});} copy]);}
    @catch(NSException *x){Pending=NO;State=@"Glasses send failed";}
    Sending=NO;
}
static void Flush(void){
    // One message in flight at a time.
    if(Pending&&Now()-PendingSince<2)return;
    if(!Outbox.count||!SID||!Route)return;
    NSDictionary *next=Outbox.firstObject;[Outbox removeObjectAtIndex:0];Send(next[@"json"]);
}
// Official caption layout (from the official app's own log): mode 1. A round grows in
// place, original sentences run together and each translated sentence ends with a
// newline. status 0 updates the round, status 1 closes it. label 1 means no
// translation yet. The glasses choose to show original, translation or both.
static BOOL Translating(void){return TIOLocalGlassesTargetLanguage()!=nil;}
static void Emit(BOOL close){
    if(!RoundSource)RoundSource=[NSMutableString new];if(!RoundTarget)RoundTarget=[NSMutableString new];
    NSMutableString *src=[RoundSource mutableCopy];if(Source.length)[src appendFormat:@"%@%@",src.length?@" ":@"",Source];
    NSMutableString *tgt=[RoundTarget mutableCopy];if(Target.length)[tgt appendString:Target];
    if(!src.length&&!tgt.length)return;
    if(close)[src appendString:@"\n"];
    NSNumber *label=tgt.length?@0:@1;
    // A newline inside the original hides the text before it, so the original gets a space.
    if(!Marked){if(Translating())[tgt insertString:ResearchMark atIndex:0];else [src insertString:@"[Research] " atIndex:0];if(close)Marked=YES;}
    Enqueue(@{@"sid":SID,@"mode":@1,@"status":close?@1:@0,@"content":@{@"source_transcript":src,@"target_translation":tgt,@"label":label,@"keyword_info":@""}},close);
    if(close){[RoundSource setString:@""];[RoundTarget setString:@""];RoundSentences=0;}
}
// A round closes after three sentences, like the official rounds of two to four.
void TIOLocalGlassesSource(NSString *text,BOOL final){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TIOLocalGlassesSource(text,final);});return;}
    if(!SID)return;
    if(final){if(!RoundSource)RoundSource=[NSMutableString new];[RoundSource appendFormat:@"%@%@",RoundSource.length?@" ":@"",text];Source=nil;
        if(!Translating()&&++RoundSentences>=3){Emit(YES);return;}}
    else Source=[text copy];
    Emit(NO);
}
void TIOLocalGlassesTarget(NSString *text,BOOL final){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TIOLocalGlassesTarget(text,final);});return;}
    if(!SID)return;
    if(final){if(!RoundTarget)RoundTarget=[NSMutableString new];[RoundTarget appendFormat:@"%@\n",text];Target=nil;
        // Close once the original has caught up, so the round's two texts match. If the
        // original stalls, close anyway after five sentences so the display keeps moving.
        // A forced close leaves the unfinished original out; it continues in the next round.
        ++RoundSentences;if(RoundSentences>=3&&!Source.length){Emit(YES);return;}
        if(RoundSentences>=5){NSString *partial=Source;Source=nil;Emit(YES);Source=partial;if(Source.length)Emit(NO);return;}}
    else Target=[text copy];
    Emit(NO);
}
// Hints from the parallel Cues engine get a round of their own, bracketed so their start
// and end are clear: the current round closes, the hint round follows, and the transcript
// continues in a fresh round (text added to a round after a hint stops showing).
void TIOLocalGlassesHint(NSString *hint){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TIOLocalGlassesHint(hint);});return;}
    if(!SID||!hint.length)return;
    if(!RoundSource)RoundSource=[NSMutableString new];if(!RoundTarget)RoundTarget=[NSMutableString new];
    NSString *source=Source,*target=Target;Source=Target=nil;
    if(RoundSource.length||RoundTarget.length)Emit(YES);
    NSString *line=[NSString stringWithFormat:@"[Hint: %@]",hint];
    [RoundSource setString:line];if(Translating())[RoundTarget setString:[line stringByAppendingString:@"\n"]];
    Emit(YES);
    Source=source;Target=target;if(Source.length||Target.length)Emit(NO);
}
// Script mode: one block of plain text, overwritten in place (mode 3 / status 0, verified on hardware).
void TIOLocalGlassesShowText(NSString *text){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TIOLocalGlassesShowText(text);});return;}
    if(!SID)return;NSString *shown=Marked?text:[ResearchMark stringByAppendingString:text];Marked=YES;
    Enqueue(@{@"sid":SID,@"mode":@3,@"status":@0,@"content":@{@"source_transcript":shown}},NO);
}
void TIOLocalGlassesReset(void){dispatch_async(dispatch_get_main_queue(),^{Source=Target=nil;[Outbox removeAllObjects];[RoundSource setString:@""];[RoundTarget setString:@""];RoundSentences=0;});}
// The CC settings name the target language, if any: first from the glasses' type 1 start,
// then from the phone's type 2 reply, which carries the languages chosen in the app.
static os_unfair_lock SettingsLock=OS_UNFAIR_LOCK_INIT;
static NSString *GlassesTarget;
NSString *TIOLocalGlassesTargetLanguage(void){os_unfair_lock_lock(&SettingsLock);NSString *t=GlassesTarget;os_unfair_lock_unlock(&SettingsLock);return t;}
static void RememberSettings(NSDictionary *set){
    if(![set isKindOfClass:NSDictionary.class])set=nil;
    NSString *src=[set[@"source_language"] isKindOfClass:NSString.class]?set[@"source_language"]:nil,*dst=[set[@"target_language"] isKindOfClass:NSString.class]?set[@"target_language"]:nil;
    // OpenAI takes ISO-639-1: zh-CN becomes zh. Same language on both sides means no translation.
    NSString *t=dst.length>=2?[dst substringToIndex:2].lowercaseString:nil;if(t&&src.length>=2&&[[src substringToIndex:2].lowercaseString isEqual:t])t=nil;
    os_unfair_lock_lock(&SettingsLock);GlassesTarget=t;os_unfair_lock_unlock(&SettingsLock);
}
