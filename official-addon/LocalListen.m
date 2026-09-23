#import "LocalListen.h"
#import <objc/runtime.h>
#import <os/lock.h>

NSString *const TIOLocalListenEnabledKey=@"localListenObserve";
NSString *const TIOLocalListenModeKey=@"localListenMode";

// Step 0 only observes. Each hook records what it sees, then calls the
// original implementation with the original arguments.
static os_unfair_lock Lock=OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *,NSMutableDictionary *> *Taps;
static NSMutableArray<NSString *> *TapOrder;
static NSDictionary *LastHint;
static NSUInteger HintCount;
static NSString *Inventory=@"Not scanned yet.";
static BOOL Installed;
static volatile BOOL Active;
static NSUserDefaults *Prefs;
static dispatch_queue_t DumpQueue;
static NSFileHandle *Dump;
static NSURL *DumpURL;
static CFAbsoluteTime DumpStart,DumpUntil;

static NSURL *SampleDirectory(void){
    NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [docs URLByAppendingPathComponent:@"TurboIOLocalListen" isDirectory:YES];
}
static NSString *Hex(NSData *d,NSUInteger limit){
    NSMutableString *s=[NSMutableString new];const uint8_t *b=d.bytes;
    for(NSUInteger i=0;i<MIN(d.length,limit);i++)[s appendFormat:@"%02x",b[i]];
    return s;
}
static NSData *Bytes(id arg){
    if([arg isKindOfClass:NSData.class])return arg;
    // FlutterStandardTypedData and similar wrappers expose their bytes as -data.
    if([arg respondsToSelector:@selector(data)]){id d=[arg performSelector:@selector(data)];if([d isKindOfClass:NSData.class])return d;}
    return nil;
}
NSString *TIOLocalListenFormatGuess(NSData *packet){
    if(!packet.length)return @"empty";
    const uint8_t *b=packet.bytes;
    if(packet.length>=4&&!memcmp(b,"OggS",4))return @"Ogg container";
    if(packet.length>=4&&!memcmp(b,"RIFF",4))return @"WAV (RIFF)";
    // 16 kHz mono PCM16 arrives in 10/20/40/60 ms blocks: 320/640/1280/1920 bytes.
    for(NSNumber *n in @[@320,@640,@1280,@1920,@3200])if(packet.length==n.unsignedIntegerValue)return [NSString stringWithFormat:@"PCM16 candidate (%lu ms at 16 kHz)",(unsigned long)(packet.length/32)];
    if(packet.length<400)return [NSString stringWithFormat:@"Opus-like frame (TOC 0x%02x)",b[0]];
    return @"unknown";
}
static NSString *Preview(id arg){
    if([arg isKindOfClass:NSString.class]){NSString *s=arg;return s.length>160?[@"…" stringByAppendingString:[s substringFromIndex:s.length-160]]:s;}
    NSData *d=Bytes(arg);if(d)return [NSString stringWithFormat:@"%lu bytes %@",(unsigned long)d.length,Hex(d,8)];
    return arg?NSStringFromClass([arg class]):@"nil";
}
static void WriteFrame(NSUInteger index,NSData *d,CFAbsoluteTime now){
    dispatch_async(DumpQueue,^{
        if(!Dump)return;
        if(now>DumpUntil){[Dump closeFile];Dump=nil;return;}
        // Frame: uint8 tap index, float64 seconds since start, uint32 length, bytes.
        uint8_t tap=(uint8_t)MIN(index,255);double t=now-DumpStart;uint32_t len=(uint32_t)d.length;
        NSMutableData *frame=[NSMutableData dataWithCapacity:13+d.length];
        [frame appendBytes:&tap length:1];[frame appendBytes:&t length:8];[frame appendBytes:&len length:4];[frame appendData:d];
        @try{[Dump writeData:frame];}@catch(NSException *e){[Dump closeFile];Dump=nil;}
    });
}
static void Observe(NSString *key,id arg){
    if(!Active)return;
    NSData *d=Bytes(arg);CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();NSUInteger index=0;
    os_unfair_lock_lock(&Lock);
    NSMutableDictionary *t=Taps[key];
    if(!t){t=[@{@"key":key,@"count":@0,@"bytes":@0,@"first":@(now),@"argClass":arg?NSStringFromClass([arg class]):@"nil"} mutableCopy];Taps[key]=t;[TapOrder addObject:key];}
    index=[TapOrder indexOfObject:key];
    t[@"count"]=@([t[@"count"] unsignedIntegerValue]+1);t[@"last"]=@(now);t[@"preview"]=Preview(arg);t[@"thread"]=NSThread.isMainThread?@"main":@"background";
    if(d){
        t[@"bytes"]=@([t[@"bytes"] unsignedLongLongValue]+d.length);t[@"lastSize"]=@(d.length);
        NSNumber *min=t[@"minSize"];t[@"minSize"]=@(min?MIN(min.unsignedIntegerValue,d.length):d.length);t[@"maxSize"]=@(MAX([t[@"maxSize"] unsignedIntegerValue],d.length));
        if(!t[@"firstHex"]){t[@"firstHex"]=Hex(d,16);t[@"guess"]=TIOLocalListenFormatGuess(d);}
    }
    os_unfair_lock_unlock(&Lock);
    if(d&&Dump)WriteFrame(index,d,now);
}
static void ObserveHint(NSString *key,id arg){
    Observe(key,arg);if(!Active||!arg)return;
    // The wrapper's field names are not known yet, so record every readable property.
    NSMutableDictionary *fields=[NSMutableDictionary new];
    for(Class c=[arg class];c&&c!=NSObject.class;c=class_getSuperclass(c)){
        unsigned n=0;objc_property_t *props=class_copyPropertyList(c,&n);
        for(unsigned i=0;i<n;i++){NSString *name=@(property_getName(props[i]));if(fields[name])continue;
            @try{id v=[arg valueForKey:name];NSString *s=[v description]?:@"nil";fields[name]=s.length>400?[s substringToIndex:400]:s;}@catch(NSException *e){fields[name]=@"(unreadable)";}}
        free(props);
    }
    os_unfair_lock_lock(&Lock);HintCount++;LastHint=@{@"time":NSDate.date,@"class":NSStringFromClass([arg class]),@"fields":fields,@"count":@(HintCount)};os_unfair_lock_unlock(&Lock);
}
static NSString *Shape(Method m){
    const char *e=method_getTypeEncoding(m);if(!e)return @"";
    NSMutableString *s=[NSMutableString new];
    for(const char *p=e;*p;p++)if(!(*p>='0'&&*p<='9'))[s appendFormat:@"%c",*p];
    return s;
}
static void Hook(Class cls,Method m,NSString *key,BOOL hint){
    SEL sel=method_getName(m);IMP original=method_getImplementation(m);
    IMP imp=imp_implementationWithBlock(^(id obj,id arg){
        @try{if(hint)ObserveHint(key,arg);else Observe(key,arg);}@catch(NSException *e){}
        ((void(*)(id,SEL,id))original)(obj,sel,arg);
    });
    method_setImplementation(m,imp);
}
void TIOLocalListenConfigure(NSUserDefaults *prefs){
    Prefs=prefs;Taps=[NSMutableDictionary new];TapOrder=[NSMutableArray new];DumpQueue=dispatch_queue_create("io.turboio.locallisten.dump",DISPATCH_QUEUE_SERIAL);
    Active=[Prefs boolForKey:TIOLocalListenEnabledKey];
    if(Active&&!TIOLocalListenInstall()){Active=NO;[Prefs setBool:NO forKey:TIOLocalListenEnabledKey];}
}
BOOL TIOLocalListenInstalled(void){return Installed;}
BOOL TIOLocalListenInstall(void){
    if(Installed){Active=YES;return YES;}
    Class anchor=NSClassFromString(@"rayneo_venus_sdk_plugin.AiResultListenerBridge");const char *image=anchor?class_getImageName(anchor):NULL;if(!image)return NO;
    NSArray *targets=@[@"pushAudioData:",@"pushAudioDataForTranslation:",@"onProactiveHint:"];
    NSArray *words=@[@"proactive",@"caption",@"tmk",@"translat",@"airt",@"airuntime",@"opus",@"recorder"];
    NSMutableString *inv=[NSMutableString new];NSUInteger hooked=0;
    unsigned count=0;const char **names=objc_copyClassNamesForImage(image,&count);
    for(unsigned i=0;i<count;i++){
        NSString *name=@(names[i]),*lower=name.lowercaseString;BOOL candidate=NO;for(NSString *w in words)if([lower containsString:w]){candidate=YES;break;}
        BOOL listener=[lower containsString:@"proactiveairesultlistener"];
        Class cls=objc_getClass(names[i]);if(!cls)continue;
        unsigned mc=0;Method *methods=class_copyMethodList(cls,&mc);BOOL listed=NO;
        for(unsigned j=0;j<mc;j++){
            NSString *sel=NSStringFromSelector(method_getName(methods[j]));BOOL target=[targets containsObject:sel];
            BOOL objectArg=[Shape(methods[j]) isEqual:@"v@:@"];BOOL hook=objectArg&&(target||(listener&&[sel hasPrefix:@"on"]));
            if(candidate||target){if(!listed){[inv appendFormat:@"\n%@\n",name];listed=YES;}[inv appendFormat:@"  -%@ %s%@\n",sel,method_getTypeEncoding(methods[j])?:"?",hook?@"  [observed]":@""];}
            if(hook){Hook(cls,methods[j],[NSString stringWithFormat:@"%@ · %@",[name componentsSeparatedByString:@"."].lastObject,sel],[sel isEqual:@"onProactiveHint:"]);hooked++;}
        }
        free(methods);
    }
    free(names);
    Inventory=[NSString stringWithFormat:@"Scanned %u classes, observing %lu methods.\n%@",count,(unsigned long)hooked,inv];
    Installed=YES;Active=YES;return YES;
}
NSArray<NSDictionary *> *TIOLocalListenTaps(void){
    os_unfair_lock_lock(&Lock);NSMutableArray *out=[NSMutableArray new];for(NSString *k in TapOrder)[out addObject:[Taps[k] copy]];os_unfair_lock_unlock(&Lock);return out;
}
NSDictionary *TIOLocalListenHint(void){os_unfair_lock_lock(&Lock);NSDictionary *h=LastHint;os_unfair_lock_unlock(&Lock);return h;}
NSString *TIOLocalListenInventory(void){return Inventory;}
void TIOLocalListenReset(void){os_unfair_lock_lock(&Lock);[Taps removeAllObjects];[TapOrder removeAllObjects];LastHint=nil;HintCount=0;os_unfair_lock_unlock(&Lock);}
BOOL TIOLocalListenRecord(NSTimeInterval seconds){
    if(!Installed||!Active)return NO;
    NSURL *dir=SampleDirectory();[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSDateFormatter *f=[NSDateFormatter new];f.dateFormat=@"yyyyMMdd-HHmmss";NSString *stamp=[f stringFromDate:NSDate.date];
    NSURL *url=[dir URLByAppendingPathComponent:[NSString stringWithFormat:@"sample-%@.bin",stamp]];
    if(![NSFileManager.defaultManager createFileAtPath:url.path contents:[@"TIOLL1\n" dataUsingEncoding:NSUTF8StringEncoding] attributes:nil])return NO;
    NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:url.path];if(!h)return NO;[h seekToEndOfFile];
    CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    dispatch_sync(DumpQueue,^{[Dump closeFile];Dump=h;DumpURL=url;DumpStart=now;DumpUntil=now+seconds;});
    // Sidecar: tap index map and the class inventory, written when the window closes.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((seconds+1)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        NSDictionary *meta=@{@"format":@"uint8 tap, float64 seconds, uint32 length, bytes",@"taps":TIOLocalListenTaps(),@"inventory":Inventory};
        NSData *json=[NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToURL:[url.URLByDeletingPathExtension URLByAppendingPathExtension:@"json"] atomically:YES];
        dispatch_async(DumpQueue,^{if(Dump==h){[Dump closeFile];Dump=nil;}});
    });
    return YES;
}
NSTimeInterval TIOLocalListenRecordingRemaining(void){__block NSTimeInterval left=0;dispatch_sync(DumpQueue,^{if(Dump)left=MAX(0,DumpUntil-CFAbsoluteTimeGetCurrent());});return left;}
NSArray<NSURL *> *TIOLocalListenSampleFiles(void){
    NSArray *all=[NSFileManager.defaultManager contentsOfDirectoryAtURL:SampleDirectory() includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]?:@[];
    return [all sortedArrayUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){return [b.lastPathComponent compare:a.lastPathComponent];}];
}
void TIOLocalListenSetActive(BOOL on){Active=on&&Installed;}
