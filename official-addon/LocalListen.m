#import "LocalListen.h"
#import <objc/runtime.h>
#import <os/lock.h>

NSString *const TIOLocalListenEnabledKey=@"localListenObserve";
NSString *const TIOLocalListenModeKey=@"localListenMode";
NSString *const TIOLocalListenASRKey=@"localListenASR";
NSString *const TIOLocalListenLanguageKey=@"localListenLanguage";
NSString *const TIOLocalListenOpenAIModelKey=@"localListenOpenAIModel";
static NSString *(^KeyProvider)(void);
void TIOLocalListenSetKeyProvider(NSString *(^provider)(void)){KeyProvider=[provider copy];}
NSString *TIOLocalListenOpenAIKey(void){return KeyProvider?KeyProvider():nil;}

// Step 0 only observes. Each hook records what it sees, then calls the
// original implementation with the original arguments.
static os_unfair_lock Lock=OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *,NSMutableDictionary *> *Taps;
static NSMutableArray<NSString *> *TapOrder;
static NSDictionary *LastHint,*LastCaption;
static volatile BOOL CaptionRunning;
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
    if(d)TIOLocalListenAutoPacket(key,d);
}
static NSDictionary *Fields(id arg);
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
static void ObserveCaption(NSString *key,id arg){
    Observe(key,arg);if(!Active||!arg)return;NSDictionary *fields=Fields(arg);
    os_unfair_lock_lock(&Lock);LastCaption=@{@"time":NSDate.date,@"fields":fields};os_unfair_lock_unlock(&Lock);
}
static NSDictionary *Fields(id arg){
    NSMutableDictionary *fields=[NSMutableDictionary new];
    for(Class c=[arg class];c&&c!=NSObject.class;c=class_getSuperclass(c)){
        unsigned n=0;objc_property_t *props=class_copyPropertyList(c,&n);
        for(unsigned i=0;i<n;i++){NSString *name=@(property_getName(props[i]));if(fields[name])continue;
            @try{id v=[arg valueForKey:name];NSString *s=[v description]?:@"nil";fields[name]=s.length>400?[s substringToIndex:400]:s;}@catch(NSException *e){fields[name]=@"(unreadable)";}}
        free(props);
    }
    return fields;
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
// Audio with trailing BOOL flags (VPU, VAD) and BOOL-returning workflow controls.
static void HookDataFlag(Class cls,Method m,NSString *key){
    SEL sel=method_getName(m);IMP original=method_getImplementation(m);
    method_setImplementation(m,imp_implementationWithBlock(^(id obj,id data,BOOL a){@try{Observe(key,data);}@catch(NSException *e){}((void(*)(id,SEL,id,BOOL))original)(obj,sel,data,a);}));
}
static void HookDataFlags(Class cls,Method m,NSString *key){
    SEL sel=method_getName(m);IMP original=method_getImplementation(m);
    method_setImplementation(m,imp_implementationWithBlock(^(id obj,id data,BOOL a,BOOL b){@try{Observe(key,data);}@catch(NSException *e){}((void(*)(id,SEL,id,BOOL,BOOL))original)(obj,sel,data,a,b);}));
}
static void HookWorkflow(Class cls,Method m,NSString *key,BOOL running){
    SEL sel=method_getName(m);IMP original=method_getImplementation(m);
    method_setImplementation(m,imp_implementationWithBlock(^BOOL(id obj){
        BOOL ok=((BOOL(*)(id,SEL))original)(obj,sel);
        if(Active){CaptionRunning=running&&ok;Observe(key,@(ok));if(!running)TIOLocalListenAutoWorkflowStopped();}
        return ok;
    }));
}
BOOL TIOLocalListenCaptionRunning(void){return CaptionRunning;}
NSString *const TIOLocalListenAgoraKey=@"AgoraRtcEngineKit · pushExternalAudioFrameRawData";
// The last 15 s of untouched Agora input, for working out the channel layout offline.
static NSMutableData *RawRecent;static NSString *RawFormat;
// Raw glasses messages: every BLE event the official app hands to Flutter, counted by
// business ID and protobuf message type; type 9 payloads (audio) are kept for analysis.
static NSMutableData *BleRecent;
static unsigned MessageType(NSData *data){
    // Field 2 of the envelope header is the message type (varint).
    const uint8_t *b=data.bytes;NSUInteger at=0;
    while(at<data.length){
        uint64_t tag=0;unsigned shift=0;while(at<data.length&&shift<64){uint8_t v=b[at++];tag|=(uint64_t)(v&127)<<shift;if(!(v&128))break;shift+=7;}
        unsigned wire=tag&7,field=(unsigned)(tag>>3);if(!field)return 0;
        if(wire==0){uint64_t v=0;shift=0;while(at<data.length&&shift<64){uint8_t x=b[at++];v|=(uint64_t)(x&127)<<shift;if(!(x&128))break;shift+=7;}if(field==2)return (unsigned)v;}
        else if(wire==2){uint64_t len=0;shift=0;while(at<data.length&&shift<64){uint8_t x=b[at++];len|=(uint64_t)(x&127)<<shift;if(!(x&128))break;shift+=7;}if(len>data.length-at)return 0;at+=(NSUInteger)len;}
        else if(wire==5)at+=4;else if(wire==1)at+=8;else return 0;
    }
    return 0;
}
void TIOLocalListenObserveEvent(NSDictionary *event){
    if(!Active||![event[@"eventType"] isEqual:@"messageReceived"])return;NSDictionary *m=event[@"message"];
    NSData *payload=[m[@"payload"] isKindOfClass:NSData.class]?m[@"payload"]:nil;if(!payload.length)return;
    unsigned type=MessageType(payload);
    Observe([NSString stringWithFormat:@"BLE business %@ · type %u",m[@"businessId"]?:@"?",type],payload);
    if(type==9){os_unfair_lock_lock(&Lock);if(!BleRecent)BleRecent=[NSMutableData new];
        if(BleRecent.length<4*1024*1024){uint32_t len=(uint32_t)payload.length;[BleRecent appendBytes:&len length:4];[BleRecent appendData:payload];}
        os_unfair_lock_unlock(&Lock);}
}
void TIOLocalListenSaveRaw(void){
    os_unfair_lock_lock(&Lock);NSData *raw=[RawRecent copy];NSString *format=RawFormat;[RawRecent setLength:0];os_unfair_lock_unlock(&Lock);
    os_unfair_lock_lock(&Lock);NSData *ble=[BleRecent copy];[BleRecent setLength:0];os_unfair_lock_unlock(&Lock);
    if(ble.length){NSURL *dir=SampleDirectory();[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];[ble writeToURL:[dir URLByAppendingPathComponent:@"last-ble-audio.bin"] atomically:YES];}
    if(!raw.length)return;NSURL *dir=SampleDirectory();[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [raw writeToURL:[dir URLByAppendingPathComponent:@"last-raw.bin"] atomically:YES];
    [[format dataUsingEncoding:NSUTF8StringEncoding] writeToURL:[dir URLByAppendingPathComponent:@"last-raw.txt"] atomically:YES];
}
// Interleaved PCM16 frames at any rate to 16 kHz mono, taking the loudest channel:
// on the glasses feed one channel is silent, so averaging would only halve the level.
static NSData *To16kMono(const int16_t *in,NSInteger frames,NSInteger rate,NSInteger channels){
    if(frames<=0)return nil;
    NSInteger pick=0;double best=-1;for(NSInteger c=0;c<channels;c++){double e=0;for(NSInteger i=0;i<frames;i++){double v=in[i*channels+c];e+=v*v;}if(e>best){best=e;pick=c;}}
    NSInteger outFrames=(NSInteger)((double)frames*16000/rate);if(outFrames<=0)return nil;
    NSMutableData *out=[NSMutableData dataWithLength:(NSUInteger)outFrames*2];int16_t *o=out.mutableBytes;
    for(NSInteger k=0;k<outFrames;k++){
        double pos=(double)k*rate/16000;NSInteger i=(NSInteger)pos;double f=pos-i;NSInteger j=MIN(i+1,frames-1);
        double a=in[i*channels+pick],b=in[j*channels+pick];
        o[k]=(int16_t)lround(a+(b-a)*f);
    }
    return out;
}
// Timekettle captions stream glasses audio to the cloud through Agora's ObjC API,
// so this is the one audio call Swift code cannot bypass.
static BOOL HookAgora(NSMutableString *inv){
    Class cls=NSClassFromString(@"AgoraRtcEngineKit");SEL sel=NSSelectorFromString(@"pushExternalAudioFrameRawData:samples:sampleRate:channels:trackId:timestamp:");
    Method m=cls?class_getInstanceMethod(cls,sel):NULL;if(!m||![Shape(m) isEqual:@"i@:^vqqqqd"])return NO;
    IMP original=method_getImplementation(m);
    method_setImplementation(m,imp_implementationWithBlock(^int(id obj,void *data,NSInteger samples,NSInteger rate,NSInteger channels,NSInteger track,NSTimeInterval ts){
        // Measured on device: `samples` counts all channels (640 = 320 stereo frames = 20 ms
        // at 16 kHz, 50 calls a second). Reading samples × channels ran past the buffer.
        if(Active&&data&&samples>0&&samples%channels==0&&samples<=96000&&channels>=1&&channels<=2&&rate>=8000&&rate<=48000){
            NSString *key=[NSString stringWithFormat:@"%@ · track %ld",TIOLocalListenAgoraKey,(long)track];
            os_unfair_lock_lock(&Lock);if(!RawRecent)RawRecent=[NSMutableData new];
            int64_t header[4]={track,samples,channels,(int64_t)(ts*1000)};[RawRecent appendBytes:header length:sizeof header];[RawRecent appendBytes:data length:(NSUInteger)(samples*2)];
            NSUInteger cap=(NSUInteger)(15*rate*channels*2*2);if(RawRecent.length>cap)RawRecent=[NSMutableData new];
            RawFormat=[NSString stringWithFormat:@"rate=%ld channels=%ld samples_per_call=%ld frame=int64 track,samples,channels,timestamp_ms then samples int16 interleaved",(long)rate,(long)channels,(long)samples];os_unfair_lock_unlock(&Lock);
            @try{NSData *pcm=To16kMono(data,samples/channels,rate,channels);if(pcm){Observe(key,pcm);
                os_unfair_lock_lock(&Lock);Taps[key][@"source"]=[NSString stringWithFormat:@"%ld Hz, %ld ch, %ld frames per call, ts %.0f ms",(long)rate,(long)channels,(long)(samples/channels),ts*1000];os_unfair_lock_unlock(&Lock);}}@catch(NSException *e){}
        }
        return ((int(*)(id,SEL,void *,NSInteger,NSInteger,NSInteger,NSInteger,NSTimeInterval))original)(obj,sel,data,samples,rate,channels,track,ts);
    }));
    [inv appendFormat:@"\nAgoraRtcEngineKit\n  -%@ %s  [observed]\n",NSStringFromSelector(sel),method_getTypeEncoding(m)];
    return YES;
}
NSDictionary *TIOLocalListenOfficialCaption(void){os_unfair_lock_lock(&Lock);NSDictionary *c=LastCaption;os_unfair_lock_unlock(&Lock);return c;}
void TIOLocalListenConfigure(NSUserDefaults *prefs){
    Prefs=prefs;Taps=[NSMutableDictionary new];TapOrder=[NSMutableArray new];DumpQueue=dispatch_queue_create("io.turboio.locallisten.dump",DISPATCH_QUEUE_SERIAL);
    TIOLocalListenAutoConfigure(prefs);
    Active=[Prefs boolForKey:TIOLocalListenEnabledKey]||[Prefs boolForKey:TIOLocalListenAutoKey];
    if(Active&&!TIOLocalListenInstall()){Active=NO;[Prefs setBool:NO forKey:TIOLocalListenEnabledKey];[Prefs setBool:NO forKey:TIOLocalListenAutoKey];}
}
BOOL TIOLocalListenInstalled(void){return Installed;}
// A snapshot for pulling off the device during development: status, taps and the
// class inventory. No audio and no transcript text.
static void WriteDiagnostics(void){
    if(!Installed)return;
    NSDictionary *hint=TIOLocalListenHint();
    NSDictionary *d=@{@"time":@(NSDate.date.timeIntervalSince1970),@"active":@(Active),@"auto":@([Prefs boolForKey:TIOLocalListenAutoKey]),@"autoStatus":TIOLocalListenAutoStatus(),@"autoLog":TIOLocalListenAutoLog(),@"peak":@(TIOLocalListenAutoPeak()),@"transcriptLength":@(TIOLocalListenTranscript().length),
        @"trigger":[Prefs stringForKey:TIOLocalListenTriggerKey]?:@"automatic",@"captionRunning":@(CaptionRunning),@"officialCaptionFields":[TIOLocalListenOfficialCaption()[@"fields"] allKeys]?:@[],@"taps":TIOLocalListenTaps(),@"hintCount":hint[@"count"]?:@0,@"hintFields":[hint[@"fields"] allKeys]?:@[],@"inventory":Inventory};
    NSData *json=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil];NSURL *dir=SampleDirectory();
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [json writeToURL:[dir URLByAppendingPathComponent:@"diagnostics.json"] atomically:YES];
}
BOOL TIOLocalListenInstall(void){
    if(Installed){Active=YES;return YES;}
    Class anchor=NSClassFromString(@"rayneo_venus_sdk_plugin.AiResultListenerBridge");const char *image=anchor?class_getImageName(anchor):NULL;if(!image)return NO;
    NSArray *targets=@[@"pushAudioData:",@"pushAudioDataForTranslation:",@"onProactiveHint:"];
    NSArray *words=@[@"proactive",@"caption",@"tmk",@"translat",@"airt",@"airuntime",@"opus",@"recorder"];
    // Skip SDK noise that matches the words but never carries glasses audio.
    NSArray *noise=@[@"bugly",@"fluttersound"];
    NSMutableString *inv=[NSMutableString new];NSUInteger hooked=0;
    unsigned count=0;const char **names=objc_copyClassNamesForImage(image,&count);
    for(unsigned i=0;i<count;i++){
        NSString *name=@(names[i]),*lower=name.lowercaseString;BOOL candidate=NO;for(NSString *w in words)if([lower containsString:w]){candidate=YES;break;}for(NSString *w in noise)if([lower containsString:w])candidate=NO;
        BOOL listener=[lower containsString:@"proactiveairesultlistener"];
        Class cls=objc_getClass(names[i]);if(!cls)continue;
        unsigned mc=0;Method *methods=class_copyMethodList(cls,&mc);BOOL listed=NO;
        for(unsigned j=0;j<mc;j++){
            NSString *sel=NSStringFromSelector(method_getName(methods[j]));BOOL target=[targets containsObject:sel];
            NSString *shape=Shape(methods[j]);BOOL objectArg=[shape isEqual:@"v@:@"];BOOL hook=objectArg&&(target||(listener&&[sel hasPrefix:@"on"]));
            // RayNeo's own caption translation: recorder audio, workflow start/stop, and results.
            NSString *tag=[NSString stringWithFormat:@"%@ · %@",[name componentsSeparatedByString:@"."].lastObject,sel];
            BOOL special=YES;
            if([name isEqual:@"RayNeoAudioRecorderAdapter"]&&[sel isEqual:@"notifyRecordData:"]&&objectArg)Hook(cls,methods[j],tag,NO);
            else if([name isEqual:@"RayNeoAudioRecorderAdapter"]&&[sel isEqual:@"notifyRecordData:withVpu:"]&&[shape isEqual:@"v@:@B"])HookDataFlag(cls,methods[j],tag);
            else if([name isEqual:@"RayNeoAudioRecorderAdapter"]&&[sel isEqual:@"notifyRecordData:withVpu:withVad:"]&&[shape isEqual:@"v@:@BB"])HookDataFlags(cls,methods[j],tag);
            else if([name isEqual:@"RayNeoTranslateControllerWrapper"]&&[@[@"startWorkflow",@"stopWorkflow"] containsObject:sel]&&[shape isEqual:@"B@:"])HookWorkflow(cls,methods[j],tag,[sel isEqual:@"startWorkflow"]);
            else if([name isEqual:@"TranslateResultListenerImpl"]&&[sel isEqual:@"onTranslateResponse:"]&&objectArg){Method m=methods[j];SEL s=method_getName(m);IMP o=method_getImplementation(m);method_setImplementation(m,imp_implementationWithBlock(^(id obj,id arg){@try{ObserveCaption(tag,arg);}@catch(NSException *e){}((void(*)(id,SEL,id))o)(obj,s,arg);}));}
            else special=NO;
            if(special){hooked++;if(!listed){[inv appendFormat:@"\n%@\n",name];listed=YES;}[inv appendFormat:@"  -%@ %s  [observed]\n",sel,method_getTypeEncoding(methods[j])?:"?"];continue;}
            if(candidate||target){if(!listed){[inv appendFormat:@"\n%@\n",name];listed=YES;}[inv appendFormat:@"  -%@ %s%@\n",sel,method_getTypeEncoding(methods[j])?:"?",hook?@"  [observed]":@""];}
            if(hook){Hook(cls,methods[j],[NSString stringWithFormat:@"%@ · %@",[name componentsSeparatedByString:@"."].lastObject,sel],[sel isEqual:@"onProactiveHint:"]);hooked++;}
        }
        free(methods);
    }
    free(names);
    if(HookAgora(inv))hooked++;
    Inventory=[NSString stringWithFormat:@"Scanned %u classes, observing %lu methods.\n%@",count,(unsigned long)hooked,inv];
    Installed=YES;Active=YES;
    static dispatch_source_t timer;timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),2*NSEC_PER_SEC,NSEC_PER_SEC/2);dispatch_source_set_event_handler(timer,^{WriteDiagnostics();});dispatch_resume(timer);
    return YES;
}
NSArray<NSDictionary *> *TIOLocalListenTaps(void){
    os_unfair_lock_lock(&Lock);NSMutableArray *out=[NSMutableArray new];for(NSString *k in TapOrder)[out addObject:[Taps[k] copy]];os_unfair_lock_unlock(&Lock);return out;
}
NSDictionary *TIOLocalListenHint(void){os_unfair_lock_lock(&Lock);NSDictionary *h=LastHint;os_unfair_lock_unlock(&Lock);return h;}
NSString *TIOLocalListenInventory(void){return Inventory;}
void TIOLocalListenReset(void){os_unfair_lock_lock(&Lock);[Taps removeAllObjects];[TapOrder removeAllObjects];LastHint=nil;LastCaption=nil;HintCount=0;os_unfair_lock_unlock(&Lock);}
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
