#import "LocalListen.h"
#import "SubtitleHUDCore.h"
#import "ProtocolContext.h"
#import "TIOTokens.h"
#import <objc/message.h>

// Official teleprompter rescue. The official voice tracking sends a highlight (business 20,
// type 8) for every word it matches, but only searches near its cursor, so a reader who skips
// ahead or goes back is lost. When it has been silent while speech keeps arriving, this follows
// the reader instead: near the cursor first, then across the whole script, and sends the same
// type 8 message. Official messages are never blocked or changed. Main thread only.
static NSString *Script,*Did,*ScriptDid,*ScriptDir;
static NSUInteger ScriptGen;
static NSData *ScriptBytes;
static NSMutableData *Tokens;
static NSArray<NSNumber *> *LineStarts;
static NSDictionary *Route;
static NSInteger Width=492,FontSize=18;
static BOOL Voice,Sending;
static NSUInteger Cursor,SentCount,Rescues;
static NSTimeInterval OfficialAt,SentAt;
static NSMutableArray<NSString *> *Heard;
static NSString *Partial;
static NSMutableArray *Log;
static NSTimeInterval Now(void){return NSProcessInfo.processInfo.systemUptime;}
static id Get(id o,NSString *k){@try{return [o valueForKey:k];}@catch(NSException *e){return nil;}}
static NSData *Bytes(id o){if([o isKindOfClass:NSData.class])return o;id b=Get(o,@"data");return [b isKindOfClass:NSData.class]?b:nil;}
static void Note(NSString *s){if(!Log)Log=[NSMutableArray new];[Log addObject:[NSString stringWithFormat:@"%.1f %@",Now(),s]];if(Log.count>40)[Log removeObjectAtIndex:0];}
NSDictionary *TIOTeleFollowDiagnostics(void){return @{@"script":@(ScriptBytes.length),@"scriptMatchesSession":@([ScriptDid isEqual:Did]),@"voice":@(Voice),@"did":@(Did.length>0),@"route":@(Route!=nil),@"cursor":@(Cursor),@"sent":@(SentCount),@"rescues":@(Rescues),@"log":Log?:@[]};}

// Visual lines as the glasses wrap them: about 0.53 of the font size per unit of width,
// CJK counting double. Calibrated on the official pageOffset values.
static void Layout(void){
    NSMutableArray *starts=[NSMutableArray arrayWithObject:@0];if(!Script.length){LineStarts=starts;return;}
    NSUInteger limit=MAX((NSUInteger)8,(NSUInteger)(Width/(FontSize*0.53)));
    NSUInteger byte=0,used=0;
    // Greedy word wrap per paragraph, on whitespace-separated pieces.
    NSUInteger pos=0;
    for(NSString *para in [Script componentsSeparatedByString:@"\n"]){
        if(pos)[starts addObject:@(pos)];used=0;byte=pos;
        NSScanner *sc=[NSScanner scannerWithString:para];sc.charactersToBeSkipped=nil;
        while(!sc.isAtEnd){
            NSString *word=@"",*space=@"";[sc scanUpToCharactersFromSet:NSCharacterSet.whitespaceCharacterSet intoString:&word];[sc scanCharactersFromSet:NSCharacterSet.whitespaceCharacterSet intoString:&space];
            __block NSUInteger w=0;[word enumerateSubstringsInRange:NSMakeRange(0,word.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *g,NSRange r,NSRange e,BOOL *s){w+=[g characterAtIndex:0]>=0x2E80?2:1;}];
            if(used&&used+w>limit){[starts addObject:@(byte)];used=0;}
            used+=w+space.length;byte+=[word lengthOfBytesUsingEncoding:NSUTF8StringEncoding]+[space lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        }
        pos+=[para lengthOfBytesUsingEncoding:NSUTF8StringEncoding]+1;
    }
    LineStarts=starts;
}
// The official display starts two visual lines above the highlighted line.
static NSUInteger PageFor(NSUInteger highlight){
    NSUInteger i=0;while(i+1<LineStarts.count&&LineStarts[i+1].unsignedIntegerValue<highlight)i++;
    return LineStarts[i>=2?i-2:0].unsignedIntegerValue;
}
// The official app keeps each script in its teleprompter folder, named by its did.
static void LoadScript(NSString *path){
    NSData *d=[NSData dataWithContentsOfFile:path];NSString *s=d?[[NSString alloc]initWithData:d encoding:NSUTF8StringEncoding]:nil;
    if(!s.length)return;Script=s;ScriptBytes=d;Tokens=[NSMutableData data];TIOTokenise(s,0,Tokens);Cursor=0;ScriptGen++;Layout();
    ScriptDid=path.lastPathComponent;ScriptDir=path.stringByDeletingLastPathComponent;[Heard removeAllObjects];Partial=nil;
    Note([NSString stringWithFormat:@"script %lu bytes, %lu tokens",(unsigned long)d.length,(unsigned long)(Tokens.length/sizeof(TIOToken))]);
}

static NSString *ScriptPath(NSString *did){
    if(ScriptDir){NSString *p=[ScriptDir stringByAppendingPathComponent:did];if([NSFileManager.defaultManager fileExistsAtPath:p])return p;}
    NSString *support=[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES) firstObject];
    for(NSString *user in [NSFileManager.defaultManager contentsOfDirectoryAtPath:support error:nil]){
        if(![user hasPrefix:@"user_"])continue;
        NSString *p=[[[support stringByAppendingPathComponent:user] stringByAppendingPathComponent:@"teleprompter"] stringByAppendingPathComponent:did];
        if([NSFileManager.defaultManager fileExistsAtPath:p])return p;
    }
    return nil;
}
static NSData *Packet(NSUInteger type,NSDictionary *j){
    NSData *d=[NSJSONSerialization dataWithJSONObject:j options:0 error:nil];if(!d)return nil;
    uint8_t h[]={8,1,16,(uint8_t)type,26};NSMutableData *p=[NSMutableData dataWithBytes:h length:5];NSUInteger n=d.length;
    do{uint8_t x=n&127;n>>=7;if(n)x|=128;[p appendBytes:&x length:1];}while(n);[p appendData:d];return p;
}
static BOOL Send(NSUInteger type,NSDictionary *json){
    id plugin=TIOProtocolPlugin();if(!plugin||!Route)return NO;
    NSData *data=Packet(type,json);
    Class td=NSClassFromString(@"FlutterStandardTypedData"),call=NSClassFromString(@"FlutterMethodCall");
    SEL typed=NSSelectorFromString(@"typedDataWithBytes:"),make=NSSelectorFromString(@"methodCallWithMethodName:arguments:"),handle=NSSelectorFromString(@"handleMethodCall:result:");
    if(!data||![td respondsToSelector:typed]||![call respondsToSelector:make]||![plugin respondsToSelector:handle])return NO;
    NSMutableDictionary *a=[Route mutableCopy];a[@"payload"]=((id(*)(id,SEL,id))objc_msgSend)(td,typed,data);
    id c=((id(*)(id,SEL,id,id))objc_msgSend)(call,make,@"rayneonet_sendMessage",a);
    BOOL ok=YES;Sending=YES;@try{((void(*)(id,SEL,id,id))objc_msgSend)(plugin,handle,c,^(id result){});}@catch(NSException *x){ok=NO;}Sending=NO;return ok;
}
// Keep the phone in step: ask the glasses for their state (type 10), as the official app does
// on reconnect. Their reply carries our position, and the official app moves its own cursor and
// display there, so its voice tracking can resume from it. At most every 2 s.
static NSTimeInterval SyncAt;
static void SyncPhone(void){
    if(Now()-SyncAt<2)return;SyncAt=Now();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.3*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if(Send(10,@{@"state":NSNull.null,@"checksum":@"",@"pageOffset":@0,@"highLightOffset":@0,@"action":@1}))Note(@"sync phone");
    });
}
static void SendHighlight(NSUInteger highlight,NSString *why){
    if(!Did.length)return;NSUInteger page=PageFor(highlight);
    if(!Send(8,@{@"did":Did,@"autoSync":@YES,@"highLightOffset":@(highlight),@"pageOffset":@(page),@"action":@1}))return;
    Cursor=highlight;SentAt=Now();SentCount++;Note([NSString stringWithFormat:@"%@ → highlight %lu page %lu",why,(unsigned long)highlight,(unsigned long)page]);
    SyncPhone();
}
// The official highlight ends after the word just read and its trailing space or punctuation.
static NSUInteger Snap(NSUInteger byte){
    const uint8_t *b=ScriptBytes.bytes;NSUInteger n=ScriptBytes.length;
    while(byte<n&&b[byte]&&strchr(" ,.;:!?\"')]",b[byte]))byte++;
    return byte;
}
// Tokens ending at or before the byte (binary search: token ends only grow).
static NSUInteger TokenAt(const TIOToken *t,NSUInteger n,NSUInteger byte){NSUInteger lo=0,hi=n;while(lo<hi){NSUInteger mid=(lo+hi)/2;if(t[mid].byteEnd<=byte)lo=mid+1;else hi=mid;}return lo;}
// Matching runs on its own queue so it never holds up the official app. Only the newest speech
// is matched: updates that arrive while a match runs are merged into one follow-up run, and a
// result is dropped if the official matcher has caught up in the meantime.
static dispatch_queue_t Q;
static NSUserDefaults *Settings(void){static NSUserDefaults *d;static dispatch_once_t once;dispatch_once(&once,^{d=[[NSUserDefaults alloc]initWithSuiteName:@"io.turboio.official-private-addon"];});return d;}
BOOL TIOTeleFollowEnabled(void){return [Settings() objectForKey:@"teleprompterRescue"]?[Settings() boolForKey:@"teleprompterRescue"]:YES;}
void TIOTeleFollowSetEnabled(BOOL on){[Settings() setBool:on forKey:@"teleprompterRescue"];}
static BOOL Busy,Again;
static NSTimeInterval BusyAt;
static void Follow(void){
    NSTimeInterval now=Now();
    // The official matcher is keeping up: leave it alone.
    if(!Voice||!TIOTeleFollowEnabled()||!Tokens.length||![ScriptDid isEqual:Did]||now-OfficialAt<1.2||now-SentAt<0.25)return;
    // A match that has not come back in 2 s is given up, so following never stalls.
    if(Busy&&now-BusyAt<2){Again=YES;return;}
    NSMutableArray *window=[Heard mutableCopy];if(Partial.length)[window addObject:Partial];
    NSString *spoken=[window componentsJoinedByString:@" "];if(!spoken.length)return;
    if(!Q)Q=dispatch_queue_create("io.turboio.tele-follow",DISPATCH_QUEUE_SERIAL);
    NSData *tokens=[Tokens copy];NSUInteger cursor=Cursor;NSTimeInterval official=OfficialAt,started=now;NSUInteger gen=ScriptGen;Busy=YES;BusyAt=now;
    dispatch_async(Q,^{
        const TIOToken *t=tokens.bytes;NSUInteger n=tokens.length/sizeof(TIOToken),anchor=TokenAt(t,n,cursor),end=0;double score=0;BOOL jump=NO;
        // Near the cursor first, forward only.
        TIOPolicyResult r=TIOAlignSpeech(t,n,spoken,anchor);
        if(r.accepted&&r.end>anchor)end=r.end;
        else{
            // Then the whole script: a longer, closer, unambiguous match well away from the cursor.
            NSData *tail=TIOSpeechTail(spoken,32);NSUInteger m=tail.length/sizeof(TIOToken);
            TIOAlignment a=m>=20?TIOAlign(t,n,tail.bytes,m,1,n,anchor):(TIOAlignment){NO,0,0,NO};
            score=a.found?1.0-(double)a.distance/(double)m:0;
            if(a.found&&!a.ambiguous&&score>=0.7&&(a.end>anchor?a.end-anchor:anchor-a.end)>=24){end=a.end;jump=YES;}
        }
        NSUInteger byte=end?t[end-1].byteEnd:0;
        dispatch_async(dispatch_get_main_queue(),^{
            if(BusyAt!=started)return;   // given up earlier; a newer run owns the state
            Busy=NO;
            if(byte&&OfficialAt==official&&gen==ScriptGen){
                NSUInteger h=Snap(byte);
                if(jump){Rescues++;[Heard removeAllObjects];Partial=nil;SendHighlight(h,[NSString stringWithFormat:@"search %.2f",score]);}
                else if(h>Cursor)SendHighlight(h,@"follow");
            }
            if(Again){Again=NO;Follow();}
        });
    });
}
void TIOTeleFollowHeard(NSString *text,BOOL final){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TIOTeleFollowHeard(text,final);});return;}
    if(![text isKindOfClass:NSString.class])return;if(!Heard)Heard=[NSMutableArray new];
    if(final){Partial=nil;if(text.length)[Heard addObject:text];while(Heard.count>3)[Heard removeObjectAtIndex:0];}else Partial=[text copy];
    Follow();
}
// Official business 20 traffic: the script file, layout, mode, and every official highlight.
void TIOTeleFollowObserveCall(NSString *method,NSDictionary *args){
    if(Sending)return;
    if([method isEqual:@"rayneonet_sendFile"]&&[args[@"filePath"] isKindOfClass:NSString.class]&&[args[@"filePath"] containsString:@"/teleprompter/"]){LoadScript(args[@"filePath"]);return;}
    if(![method isEqual:@"rayneonet_sendMessage"]||![args[@"businessId"] isEqual:@20])return;
    NSDictionary *e=TIOSubtitleEnvelope(Bytes(args[@"payload"])),*j=e[@"json"];if(!e)return;
    NSInteger type=[e[@"type"] integerValue];
    if([j[@"did"] isKindOfClass:NSString.class]&&[j[@"did"] length]){
        Did=j[@"did"];
        // A session for a script we have not loaded (after a relaunch, or another script): read it by did.
        if(![ScriptDid isEqual:Did]){NSString *path=ScriptPath(Did);if(path)LoadScript(path);}
    }
    NSMutableDictionary *r=[args mutableCopy];[r removeObjectForKey:@"payload"];Route=r;
    if([j[@"width"] integerValue]>0&&[j[@"size"] integerValue]>0&&([j[@"width"] integerValue]!=Width||[j[@"size"] integerValue]!=FontSize)){Width=[j[@"width"] integerValue];FontSize=[j[@"size"] integerValue];Layout();}
    // scroll 1 is voice tracking.
    if(j[@"scroll"])Voice=[j[@"scroll"] integerValue]==1;
    if(type==8&&[j[@"action"] isEqual:@1]&&j[@"highLightOffset"]){Cursor=[j[@"highLightOffset"] unsignedIntegerValue];OfficialAt=Now();}
    if(type==6){[Heard removeAllObjects];Partial=nil;}
}
