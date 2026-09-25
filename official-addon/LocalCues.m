#import "LocalListen.h"
#import "SubtitleHUDCore.h"
#import "ProtocolContext.h"
#import <objc/message.h>

// Local Live Cues: hints from our own model shown in the official Live Cues session.
// The official app sends its hints as business 0x17 type 5, mode 4, with the question
// in source_transcript and the hint in target_translation (from its own native log).
// The session ID is the taskId Flutter passes when it starts Live Cues. Main thread only.
static NSString *TaskID,*State=@"Waiting for Live Cues on the glasses";
static NSUInteger Sent,Answered,Starts;
static NSString *LastResult;
static BOOL Sending,Marked;
// Read from the audio thread to decide whether the Cues engine may start.
static _Atomic bool Open;
BOOL TIOLocalCuesOpen(void){return Open;}
static void SetTask(NSString *t){TaskID=t;Open=t!=nil;}
static NSString *const ResearchMark=@"[Research]\n";
static NSMutableDictionary<NSString *,NSNumber *> *Calls;
NSString *TIOLocalCuesStatus(void){return [NSString stringWithFormat:@"%@ · sent %lu, answered %lu",State,(unsigned long)Sent,(unsigned long)Answered];}
// Development snapshot for diagnostics.json: plugin method names only, no arguments.
NSDictionary *TIOLocalCuesDiagnostics(void){return @{@"state":State,@"taskId":TaskID?:@"",@"starts":@(Starts),@"sent":@(Sent),@"answered":@(Answered),@"lastResult":LastResult?:@"",@"calls":Calls?:@{}};}

void TIOLocalCuesObserveCall(id plugin,NSString *method,id args){
    if(Sending||![method isKindOfClass:NSString.class])return;
    if(!Calls)Calls=[NSMutableDictionary new];Calls[method]=@(Calls[method].unsignedIntegerValue+1);
    NSString *m=method.lowercaseString;if(![m containsString:@"proactive"])return;
    if([m containsString:@"stop"]){SetTask(nil);State=@"Live Cues stopped";}
}
// Live Cues is started from the glasses: inbound business 23 type 1 carries the session
// ID the hints must use, type 4 its audio, type 3 the end.
void TIOLocalCuesObserveEvent(NSDictionary *event){
    if(![event[@"eventType"] isEqual:@"messageReceived"])return;NSDictionary *m=event[@"message"];
    if(![m isKindOfClass:NSDictionary.class]||![m[@"businessId"] isEqual:@23])return;
    id p=m[@"payload"];NSData *d=[p isKindOfClass:NSData.class]?p:nil;
    NSDictionary *e=TIOSubtitleEnvelope(d),*j=e[@"json"];NSString *sid=j[@"sid"];
    if(![sid isKindOfClass:NSString.class]||!sid.length)return;
    if([e[@"type"] isEqual:@3]){if([sid isEqual:TaskID]){SetTask(nil);State=@"Live Cues ended on the glasses";}return;}
    if([e[@"type"] isEqual:@1]&&![sid isEqual:TaskID]){Starts++;SetTask(sid);Marked=NO;State=@"Live Cues session from the glasses, our hints go to it";}
}
static BOOL SendJSON(NSDictionary *j){
    id plugin=TIOProtocolPlugin();NSDictionary *route=TIOProtocolRoute(23);
    if(!TaskID||!plugin||!route){State=TaskID?@"Text ready, but no glasses connection captured":@"Text ready, but no Live Cues session";return NO;}
    NSData *data=TIOSubtitlePacket(5,j);
    Class td=NSClassFromString(@"FlutterStandardTypedData"),call=NSClassFromString(@"FlutterMethodCall");
    SEL typed=NSSelectorFromString(@"typedDataWithBytes:"),make=NSSelectorFromString(@"methodCallWithMethodName:arguments:"),handle=NSSelectorFromString(@"handleMethodCall:result:");
    if(!data||![td respondsToSelector:typed]||![call respondsToSelector:make]||![plugin respondsToSelector:handle]){State=@"Glasses send unavailable";return NO;}
    NSMutableDictionary *a=[route mutableCopy];a[@"payload"]=((id(*)(id,SEL,id))objc_msgSend)(td,typed,data);
    id c=((id(*)(id,SEL,id,id))objc_msgSend)(call,make,@"rayneonet_sendMessage",a);
    Sending=YES;Sent++;BOOL ok=YES;
    @try{((void(*)(id,SEL,id,id))objc_msgSend)(plugin,handle,c,[^(id result){NSString *r=[result description];dispatch_async(dispatch_get_main_queue(),^{Answered++;LastResult=[r substringToIndex:MIN(r.length,(NSUInteger)200)];});} copy]);}
    @catch(NSException *x){State=@"Glasses send failed";ok=NO;}
    Sending=NO;return ok;
}
static void Send(NSString *question,NSString *hint){
    NSString *q=question?:@"",*h=hint;if(!Marked){q=[ResearchMark stringByAppendingString:q];Marked=YES;}
    SendJSON(@{@"sid":TaskID?:@"",@"mode":@4,@"status":@1,@"content":@{@"source_transcript":q,@"target_translation":h,@"label":@0,@"keyword_info":NSNull.null}});
}
// The engine pairs each hint with the question it answers.
void TIOLocalCuesAnswer(NSString *question,NSString *hint){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TIOLocalCuesAnswer(question,hint);});return;}
    Send(question,hint);
}
