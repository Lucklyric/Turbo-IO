#import "LocalListen.h"
#import "SubtitleHUDCore.h"
#import <objc/runtime.h>
#import <os/lock.h>

// Official teleprompter observation. Pass-through only: every hooked call reaches the official
// code unchanged. It hands the recognizer text to the rescue matcher (TeleFollow.m) and keeps
// development diagnostics (finished sentences, business 20 messages, rescue log) in a file on
// this phone (Documents/TurboIOLocalListen/teleprompter.json, excluded from backup).
static os_unfair_lock Lock=OS_UNFAIR_LOCK_INIT;
static NSMutableArray *Asr,*Out,*In;
static NSMutableDictionary *Audio,*Counts;
static NSString *Inventory;
static BOOL SavePending;
static NSTimeInterval Start;
static NSTimeInterval T(void){return NSProcessInfo.processInfo.systemUptime-Start;}
static void Push(NSMutableArray *a,id v,NSUInteger cap){[a addObject:v];if(a.count>cap)[a removeObjectAtIndex:0];}
static NSString *Short(id v,NSUInteger n){NSString *s=[v isKindOfClass:NSString.class]?v:[v description];return s.length>n?[s substringToIndex:n]:s?:@"";}
static void Save(void){
    if(SavePending)return;SavePending=YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        os_unfair_lock_lock(&Lock);SavePending=NO;
        NSDictionary *d=@{@"asr":[Asr copy]?:@[],@"out":[Out copy]?:@[],@"in":[In copy]?:@[],@"audio":[Audio copy]?:@{},@"counts":[Counts copy]?:@{},@"inventory":Inventory?:@"",@"follow":TIOTeleFollowDiagnostics()};
        os_unfair_lock_unlock(&Lock);
        NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *dir=[docs URLByAppendingPathComponent:@"TurboIOLocalListen" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [dir setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        NSData *json=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToURL:[dir URLByAppendingPathComponent:@"teleprompter.json"] atomically:YES];
    });
}
static void Count(NSString *k){Counts[k]=@([Counts[k] unsignedIntegerValue]+1);}
static NSData *Bytes(id o){if([o isKindOfClass:NSData.class])return o;@try{id b=[o valueForKey:@"data"];return [b isKindOfClass:NSData.class]?b:nil;}@catch(NSException *e){return nil;}}

static void NoteAsr(NSString *where,id text,BOOL final){
    // Finished sentences only: partials are many and the matcher does not need them on disk.
    os_unfair_lock_lock(&Lock);Count(where);if(!final){os_unfair_lock_unlock(&Lock);return;}
    Push(Asr,@{@"t":@(T()),@"where":where,@"class":text?NSStringFromClass([text class]):@"nil",@"text":Short(text,300),@"final":@(final)},80);
    os_unfair_lock_unlock(&Lock);dispatch_async(dispatch_get_main_queue(),^{Save();});
}
// Hooks, installed only when the method has exactly the expected type shape.
static void HookText(Class cls,NSString *selName,NSString *where){
    Method m=class_getInstanceMethod(cls,NSSelectorFromString(selName));if(!m)return;
    const char *e=method_getTypeEncoding(m);if(!e||strcmp(e,"v28@0:8@16B24"))return;
    SEL sel=method_getName(m);IMP original=method_getImplementation(m);
    method_setImplementation(m,imp_implementationWithBlock(^(id obj,id text,BOOL final){
        @try{NoteAsr(where,text,final);TIOTeleFollowHeard(text,final);}@catch(NSException *x){}
        ((void(*)(id,SEL,id,BOOL))original)(obj,sel,text,final);
    }));
}
void TIOTeleObserveInstall(void){
    static dispatch_once_t once;dispatch_once(&once,^{
        Start=NSProcessInfo.processInfo.systemUptime;Asr=[NSMutableArray new];Out=[NSMutableArray new];In=[NSMutableArray new];Audio=[NSMutableDictionary new];Counts=[NSMutableDictionary new];
        Class bridge=NSClassFromString(@"rayneo_venus_sdk_plugin.AsrResultListenerBridge");
        NSMutableString *inv=[NSMutableString new];
        if(bridge){HookText(bridge,@"onAsrResult:isFinish:",@"AsrResultListenerBridge");[inv appendString:@"AsrResultListenerBridge onAsrResult:isFinish: hooked\n"];}
        Inventory=inv;
    });
}

// Business 20 messages. Outgoing JSON is kept whole except long strings; incoming audio is counted.
static NSDictionary *Trim(NSDictionary *j){
    NSMutableDictionary *r=[NSMutableDictionary new];
    for(NSString *k in j){id v=j[k];r[k]=[v isKindOfClass:NSString.class]&&[v length]>200?[NSString stringWithFormat:@"%@… (%lu chars)",[v substringToIndex:200],(unsigned long)[v length]]:([v isKindOfClass:NSDictionary.class]?Trim(v):v);}
    return r;
}
void TIOTeleObserveCall(NSString *method,NSDictionary *args){
    TIOTeleFollowObserveCall(method,args);
    if([method isEqual:@"rayneonet_sendFile"]){
        NSString *path=[args[@"filePath"] isKindOfClass:NSString.class]?args[@"filePath"]:nil;NSData *file=path?[NSData dataWithContentsOfFile:path]:nil;
        os_unfair_lock_lock(&Lock);Push(Out,@{@"t":@(T()),@"method":method,@"fileBytes":@(file.length)},60);os_unfair_lock_unlock(&Lock);Save();return;
    }
    if(![method isEqual:@"rayneonet_sendMessage"]||![args[@"businessId"] isEqual:@20])return;
    NSDictionary *e=TIOSubtitleEnvelope(Bytes(args[@"payload"]));if(!e)return;
    os_unfair_lock_lock(&Lock);Count([NSString stringWithFormat:@"out type %@",e[@"type"]]);
    Push(Out,@{@"t":@(T()),@"type":e[@"type"]?:@0,@"json":Trim(e[@"json"]?:@{}),@"binaryBytes":e[@"binaryBytes"]?:@0},60);
    os_unfair_lock_unlock(&Lock);Save();
}
void TIOTeleObserveEvent(NSDictionary *event){
    if(![event[@"eventType"] isEqual:@"messageReceived"])return;NSDictionary *m=event[@"message"];
    if(![m isKindOfClass:NSDictionary.class]||![m[@"businessId"] isEqual:@20])return;
    NSDictionary *e=TIOSubtitleEnvelope(Bytes(m[@"payload"]));if(!e)return;
    os_unfair_lock_lock(&Lock);Count([NSString stringWithFormat:@"in type %@",e[@"type"]]);
    if(![e[@"type"] isEqual:@9])Push(In,@{@"t":@(T()),@"type":e[@"type"]?:@0,@"json":Trim(e[@"json"]?:@{}),@"binaryBytes":e[@"binaryBytes"]?:@0},60);
    else{NSMutableDictionary *a=Audio[@"BLE business 20 type 9"]?:[@{@"count":@0,@"bytes":@0,@"first":@(T())} mutableCopy];Audio[@"BLE business 20 type 9"]=a;
        a[@"count"]=@([a[@"count"] unsignedIntegerValue]+1);a[@"bytes"]=@([a[@"bytes"] unsignedLongLongValue]+[e[@"binaryBytes"] unsignedIntegerValue]);a[@"last"]=@(T());}
    os_unfair_lock_unlock(&Lock);Save();
}
