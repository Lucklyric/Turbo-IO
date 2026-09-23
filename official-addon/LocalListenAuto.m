#import "LocalListen.h"
#import "LocalASR.h"
#import <dlfcn.h>
#import <os/lock.h>

// Follow Live Captions: when the official caption feed starts receiving glasses
// audio, run our own recognizer on the same audio. The official feed keeps
// receiving every packet, so official captions are unaffected.
NSString *const TIOLocalListenAutoKey=@"localListenAuto";
NSString *const TIOLocalListenTriggerKey=@"localListenTrigger";

typedef void *(*OpusCreateFn)(int32_t,int,int *);
typedef int (*OpusDecodeFn)(void *,const unsigned char *,int32_t,int16_t *,int,int);
typedef void (*OpusDestroyFn)(void *);

// Pipeline state below is owned by Q.
static dispatch_queue_t Q;
static dispatch_source_t Watchdog;
static NSUserDefaults *Prefs;
static TIOLocalASR *ASR;
static NSString *Trigger,*Format;
static CFAbsoluteTime LastPacket;
static void *Opus;
static NSUInteger Decoded,Failures;
static BOOL Undecodable;
// Transcript and status are read by the page on the main thread.
static os_unfair_lock TextLock=OS_UNFAIR_LOCK_INIT;
static NSMutableArray<NSString *> *Lines;
static NSString *Partial,*Status=@"Off";

static void SetStatus(NSString *s){os_unfair_lock_lock(&TextLock);Status=[s copy];os_unfair_lock_unlock(&TextLock);}
NSString *TIOLocalListenAutoStatus(void){os_unfair_lock_lock(&TextLock);NSString *s=Status;os_unfair_lock_unlock(&TextLock);return s;}
void TIOLocalListenAppendText(NSString *text,BOOL final){
    os_unfair_lock_lock(&TextLock);if(!Lines)Lines=[NSMutableArray new];
    if(final){Partial=nil;[Lines addObject:[text copy]];if(Lines.count>50)[Lines removeObjectAtIndex:0];}else Partial=[text copy];
    os_unfair_lock_unlock(&TextLock);
}
NSString *TIOLocalListenTranscript(void){
    os_unfair_lock_lock(&TextLock);NSMutableArray *all=[Lines mutableCopy]?:[NSMutableArray new];if(Partial)[all addObject:Partial];os_unfair_lock_unlock(&TextLock);
    return [all componentsJoinedByString:@"\n"];
}
void TIOLocalListenClearTranscript(void){os_unfair_lock_lock(&TextLock);[Lines removeAllObjects];Partial=nil;os_unfair_lock_unlock(&TextLock);}
BOOL TIOLocalListenAutoEnabled(void){return [Prefs boolForKey:TIOLocalListenAutoKey];}

static NSString *Hex(NSData *d){NSMutableString *s=[NSMutableString new];const uint8_t *b=d.bytes;for(NSUInteger i=0;i<MIN(d.length,8);i++)[s appendFormat:@"%02x",b[i]];return s;}
BOOL TIOLocalListenIsAutoTrigger(NSString *key,NSString *chosen){
    if(chosen.length)return [key isEqual:chosen];
    // Automatic choice: the Timekettle feed only receives audio while captions run.
    return [key.lowercaseString containsString:@"tmk"]&&[key containsString:@"pushAudioData"];
}
static void Stop(NSString *why){
    if(!ASR)return;
    [ASR stop];ASR=nil;Trigger=nil;
    if(Opus){OpusDestroyFn destroy=(OpusDestroyFn)dlsym(RTLD_DEFAULT,"opus_decoder_destroy");if(destroy)destroy(Opus);Opus=NULL;}
    SetStatus(why);
}
static void Start(NSString *key){
    TIOLocalASR *asr=[TIOLocalASR engineOfKind:[Prefs stringForKey:TIOLocalListenASRKey]?:TIOLocalASRAppleKind];if(!asr)return;
    asr.language=[Prefs stringForKey:TIOLocalListenLanguageKey]?:@"zh-CN";asr.model=[Prefs stringForKey:TIOLocalListenOpenAIModelKey]?:@"gpt-transcribe";
    asr.keyProvider=^NSString *{return TIOLocalListenOpenAIKey();};
    asr.onText=^(NSString *text,BOOL final){TIOLocalListenAppendText(text,final);};
    __weak TIOLocalASR *weak=asr;
    asr.onStatus=^(NSString *s){dispatch_async(Q,^{if(ASR&&ASR==weak&&!Undecodable)SetStatus([@"Following Live Captions · " stringByAppendingString:s]);});};
    ASR=asr;Trigger=key;Format=nil;Decoded=Failures=0;Undecodable=NO;
    SetStatus(@"Live Captions detected, starting recognition…");
    [asr start];
}
static void Feed(NSData *d){
    if(Undecodable)return;
    if(!Format){NSString *g=TIOLocalListenFormatGuess(d);Format=[g hasPrefix:@"PCM16"]?@"pcm":([g hasPrefix:@"Ogg"]||[g hasPrefix:@"WAV"])?@"container":@"opus";}
    if([Format isEqual:@"pcm"]){[ASR appendPCM16:d];Decoded++;return;}
    if([Format isEqual:@"container"]){Undecodable=YES;SetStatus(@"Audio arrives in a container format that is not decoded yet. Record a sample on this page.");return;}
    // The app links libopus, so its decoder is already in this process.
    if(!Opus){OpusCreateFn create=(OpusCreateFn)dlsym(RTLD_DEFAULT,"opus_decoder_create");int error=0;Opus=create?create(16000,1,&error):NULL;
        if(!Opus){Undecodable=YES;SetStatus(@"The app's Opus decoder was not found.");return;}}
    static int16_t pcm[5760];OpusDecodeFn decode=(OpusDecodeFn)dlsym(RTLD_DEFAULT,"opus_decode");
    int n=decode?decode(Opus,d.bytes,(int32_t)d.length,pcm,5760,0):-1;
    if(n>0){[ASR appendPCM16:[NSData dataWithBytes:pcm length:(NSUInteger)n*2]];Decoded++;Failures=0;return;}
    if(++Failures>=10&&!Decoded){Undecodable=YES;SetStatus([NSString stringWithFormat:@"Audio is not raw Opus or PCM (%lu-byte packets starting %@). Record a sample on this page so the format can be worked out.",(unsigned long)d.length,Hex(d)]);}
}
void TIOLocalListenAutoPacket(NSString *key,NSData *packet){
    if(!Q||!packet.length)return;
    dispatch_async(Q,^{
        if(![Prefs boolForKey:TIOLocalListenAutoKey]){Stop(@"Off");return;}
        if(!ASR){if(!TIOLocalListenIsAutoTrigger(key,[Prefs stringForKey:TIOLocalListenTriggerKey]))return;Start(key);}
        if(![key isEqual:Trigger])return;
        LastPacket=CFAbsoluteTimeGetCurrent();Feed(packet);
    });
}
void TIOLocalListenAutoConfigure(NSUserDefaults *prefs){
    Prefs=prefs;Q=dispatch_queue_create("io.turboio.locallisten.auto",DISPATCH_QUEUE_SERIAL);
    SetStatus([Prefs boolForKey:TIOLocalListenAutoKey]?@"Waiting for Live Captions":@"Off");
    // Captions ended when the feed has been quiet for 2.5 s.
    Watchdog=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,Q);
    dispatch_source_set_timer(Watchdog,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,NSEC_PER_SEC/4);
    dispatch_source_set_event_handler(Watchdog,^{if(ASR&&CFAbsoluteTimeGetCurrent()-LastPacket>2.5)Stop(@"Waiting for Live Captions · the last session ended");});
    dispatch_resume(Watchdog);
}
BOOL TIOLocalListenSetAuto(BOOL on){
    if(on&&!TIOLocalListenInstall())return NO;
    [Prefs setBool:on forKey:TIOLocalListenAutoKey];
    if(on){TIOLocalListenSetActive(YES);[Prefs setBool:YES forKey:TIOLocalListenEnabledKey];SetStatus(@"Waiting for Live Captions");}
    else dispatch_async(Q,^{Stop(@"Off");SetStatus(@"Off");});
    return YES;
}
