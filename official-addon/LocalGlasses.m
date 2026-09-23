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
static NSTimeInterval PendingSince;
static NSUInteger Sent,Answered;
static NSString *LastResult;
static NSDictionary *StartJSON;
static NSTimeInterval Now(void){return NSProcessInfo.processInfo.systemUptime;}
static id Get(id o,NSString *k){@try{return [o valueForKey:k];}@catch(NSException *e){return nil;}}
static NSData *Bytes(id o){if([o isKindOfClass:NSData.class])return o;id b=Get(o,@"data");return [b isKindOfClass:NSData.class]?b:nil;}
static void RememberSettings(NSDictionary *j);
static NSMutableArray<NSDictionary *> *Outbox;
static NSMutableString *RoundSource,*RoundTarget;
static NSUInteger RoundSentences;
NSString *TIOLocalGlassesStatus(void){return [NSString stringWithFormat:@"%@ · sent %lu, answered %lu",State,(unsigned long)Sent,(unsigned long)Answered];}
// Development snapshot for diagnostics.json: no caption text.
NSDictionary *TIOLocalGlassesDiagnostics(void){return @{@"state":State,@"sid":SID?:@"",@"route":@(Route!=nil),@"plugin":@(Plugin!=nil),@"sent":@(Sent),@"answered":@(Answered),@"lastResult":LastResult?:@"",@"startMessage":StartJSON?:@{}};}
// Live Captions is started from the glasses: an inbound type 1 opens the session and
// type 4 carries its audio, both under the session ID our text must use.
void TIOLocalGlassesObserveEvent(NSDictionary *event){
    if(![event[@"eventType"] isEqual:@"messageReceived"])return;NSDictionary *m=event[@"message"];
    if(![m isKindOfClass:NSDictionary.class]||![m[@"businessId"] isEqual:@19]||![m[@"deviceId"] isKindOfClass:NSString.class])return;
    NSDictionary *e=TIOSubtitleEnvelope(Bytes(m[@"payload"])),*j=e[@"json"];NSString *sid=j[@"sid"];
    if(![sid isKindOfClass:NSString.class]||!sid.length)return;
    if([e[@"type"] isEqual:@3]){if([sid isEqual:SID]){SID=nil;State=@"Live Captions ended on the glasses";}return;}
    if(![e[@"type"] isEqual:@1]&&![e[@"type"] isEqual:@4])return;
    if([e[@"type"] isEqual:@1]){StartJSON=j;RememberSettings(j);}
    if([sid isEqual:SID]&&Route)return;
    id plugin=TIOProtocolPlugin();
    if(!plugin){State=@"Glasses session seen, but no official plugin captured yet";return;}
    Plugin=plugin;Route=@{@"deviceId":m[@"deviceId"],@"businessId":@19};SID=sid;Source=Target=nil;[Outbox removeAllObjects];[RoundSource setString:@""];[RoundTarget setString:@""];RoundSentences=0;Pending=NO;
    State=@"Live Captions session from the glasses, local captions go to it";
}

void TIOLocalGlassesObserveCall(id plugin,NSString *method,NSDictionary *args){
    if(Sending||![method isEqual:@"rayneonet_sendMessage"]||![args[@"businessId"] isEqual:@19])return;
    NSDictionary *e=TIOSubtitleEnvelope(Bytes(args[@"payload"])),*j=e[@"json"];NSString *sid=j[@"sid"];
    if(![sid isKindOfClass:NSString.class]||!sid.length)return;
    if([e[@"type"] isEqual:@1]||([e[@"type"] isEqual:@7]&&[j[@"config"] isKindOfClass:NSDictionary.class]&&[j[@"config"][@"is_display"] isEqual:@YES])){
        NSMutableDictionary *r=[args mutableCopy];[r removeObjectForKey:@"payload"];
        Plugin=plugin;Route=r;SID=sid;Source=Target=nil;[Outbox removeAllObjects];[RoundSource setString:@""];[RoundTarget setString:@""];RoundSentences=0;Pending=NO;State=@"Live Captions session open, local captions go to the glasses";
    }else if([sid isEqual:SID]&&[e[@"type"] isEqual:@3]){SID=nil;State=@"Live Captions session ended";}
}
static void Flush(void);
// Outgoing messages. A newer partial replaces a queued partial; finished sentences are never dropped.
static void Enqueue(NSDictionary *j,BOOL final){
    if(!SID)return;if(!Outbox)Outbox=[NSMutableArray new];
    if(!final&&[Outbox.lastObject[@"partial"] boolValue])[Outbox removeLastObject];
    [Outbox addObject:@{@"json":j,@"partial":@(!final)}];Flush();
}
static void Send(NSDictionary *j){
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
    Enqueue(@{@"sid":SID,@"mode":@1,@"status":close?@1:@0,@"content":@{@"source_transcript":src,@"target_translation":tgt,@"label":tgt.length?@0:@1,@"keyword_info":@""}},close);
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
        // Close only once the original has caught up, so the round's two texts match.
        if(++RoundSentences>=3&&!Source.length){Emit(YES);return;}}
    else Target=[text copy];
    Emit(NO);
}
// Script mode: one block of plain text, overwritten in place (mode 3 / status 0, verified on hardware).
void TIOLocalGlassesShowText(NSString *text){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TIOLocalGlassesShowText(text);});return;}
    if(!SID)return;Enqueue(@{@"sid":SID,@"mode":@3,@"status":@0,@"content":@{@"source_transcript":text}},NO);
}
void TIOLocalGlassesReset(void){dispatch_async(dispatch_get_main_queue(),^{Source=Target=nil;[Outbox removeAllObjects];[RoundSource setString:@""];[RoundTarget setString:@""];RoundSentences=0;});}
// The glasses CC settings (type 1 start message) name the target language, if any.
static os_unfair_lock SettingsLock=OS_UNFAIR_LOCK_INIT;
static NSString *GlassesTarget;
NSString *TIOLocalGlassesTargetLanguage(void){os_unfair_lock_lock(&SettingsLock);NSString *t=GlassesTarget;os_unfair_lock_unlock(&SettingsLock);return t;}
static void RememberSettings(NSDictionary *j){
    NSDictionary *set=[j[@"settings"] isKindOfClass:NSDictionary.class]?j[@"settings"]:nil;
    NSString *src=[set[@"source_language"] isKindOfClass:NSString.class]?set[@"source_language"]:nil,*dst=[set[@"target_language"] isKindOfClass:NSString.class]?set[@"target_language"]:nil;
    // OpenAI takes ISO-639-1: zh-CN becomes zh. Same language on both sides means no translation.
    NSString *t=dst.length>=2?[dst substringToIndex:2].lowercaseString:nil;if(t&&src.length>=2&&[[src substringToIndex:2].lowercaseString isEqual:t])t=nil;
    os_unfair_lock_lock(&SettingsLock);GlassesTarget=t;os_unfair_lock_unlock(&SettingsLock);
}
