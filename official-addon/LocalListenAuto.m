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
static TIOLocalASR *ASR,*Hints,*Src;
NSString *const TIOLocalListenHintsKey=@"localListenHints";
static NSString *Trigger,*Format;
static CFAbsoluteTime LastPacket;
static void *Opus;
static NSUInteger Decoded,Failures;
static BOOL Undecodable;
// Development aids: the last 15 s of fed audio (saved as WAV when a session ends),
// the loudest recent level, and a short log of engine status messages.
static NSMutableData *Recent;
static double Peak;
static NSMutableArray<NSString *> *Log;
// Transcript and status are read by the page on the main thread.
static os_unfair_lock TextLock=OS_UNFAIR_LOCK_INIT;
static NSMutableArray<NSString *> *Lines;
static NSString *Partial,*Status=@"Off";

static void SetStatus(NSString *s){
    os_unfair_lock_lock(&TextLock);Status=[s copy];if(!Log)Log=[NSMutableArray new];
    NSDateFormatter *f=[NSDateFormatter new];f.dateFormat=@"HH:mm:ss";[Log addObject:[NSString stringWithFormat:@"%@ %@",[f stringFromDate:NSDate.date],s]];if(Log.count>20)[Log removeObjectAtIndex:0];
    os_unfair_lock_unlock(&TextLock);
}
NSArray<NSString *> *TIOLocalListenAutoLog(void){os_unfair_lock_lock(&TextLock);NSArray *l=[Log copy]?:@[];os_unfair_lock_unlock(&TextLock);return l;}
double TIOLocalListenAutoPeak(void){return Peak;}
static void Remember(NSData *pcm){
    if(!Recent)Recent=[NSMutableData new];[Recent appendData:pcm];
    if(Recent.length>15*32000)[Recent replaceBytesInRange:NSMakeRange(0,Recent.length-15*32000) withBytes:NULL length:0];
    const int16_t *s=pcm.bytes;int16_t m=0;for(NSUInteger i=0;i<pcm.length/2;i++){int16_t v=(int16_t)(s[i]<0?-s[i]:s[i]);if(v>m)m=v;}
    Peak=MAX(Peak*0.98,(double)m);
}
static void SaveRecent(void){
    if(!Recent.length)return;
    NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir=[docs URLByAppendingPathComponent:@"TurboIOLocalListen" isDirectory:YES];[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [TIOLocalASRWav(Recent) writeToURL:[dir URLByAppendingPathComponent:@"last-session.wav"] atomically:YES];[Recent setLength:0];
}
NSString *TIOLocalListenAutoStatus(void){os_unfair_lock_lock(&TextLock);NSString *s=Status;os_unfair_lock_unlock(&TextLock);return s;}
NSString *const TIOLocalListenTranscriptKey=@"localListenTranscript";
void TIOLocalListenAppendText(NSString *text,BOOL final){
    if([Prefs objectForKey:TIOLocalListenTranscriptKey]&&![Prefs boolForKey:TIOLocalListenTranscriptKey])return;
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
// Our engines run only inside an official session on the glasses: CC for Translation and
// Script, Live Cues for Cues. The voice assistant shares the same audio feeds.
static BOOL SessionOpen(void){return [Prefs integerForKey:TIOLocalListenModeKey]==2?TIOLocalCuesOpen():TIOLocalGlassesSessionOpen();}
BOOL TIOLocalListenIsAutoTrigger(NSString *key,NSString *chosen){
    if(!SessionOpen())return NO;
    // Prefix match keeps a trigger chosen before per-track keys working.
    // Cues always listens to the Live Cues recorder audio, whatever caption source is chosen.
    if([Prefs integerForKey:TIOLocalListenModeKey]==2)return [key hasPrefix:@"RayNeoAudioRecorderAdapter · notifyRecordData"];
    if(chosen.length)return [key hasPrefix:chosen];
    // Automatic choice: recorder audio while RayNeo's caption translation workflow runs,
    // or the Timekettle feed, which only receives audio while captions run.
    if([key hasPrefix:TIOLocalListenAgoraKey])return YES;
    if([key hasPrefix:@"RayNeoAudioRecorderAdapter · notifyRecordData"])return TIOLocalListenCaptionRunning();
    return [key.lowercaseString containsString:@"tmk"]&&[key containsString:@"pushAudioData"];
}
static void Stop(NSString *why){
    if(!ASR)return;
    [ASR stop];ASR=nil;[Hints stop];Hints=nil;[Src stop];Src=nil;Trigger=nil;SaveRecent();TIOLocalListenSaveRaw();
    if(Opus){OpusDestroyFn destroy=(OpusDestroyFn)dlsym(RTLD_DEFAULT,"opus_decoder_destroy");if(destroy)destroy(Opus);Opus=NULL;}
    SetStatus(why);
}
static void Start(NSString *key){
    // Glasses CC set to translate: use OpenAI Translate to the language chosen on the glasses.
    // Script mode only needs recognition: never translate, and fall back from the translate engine.
    BOOL script=TIOLocalScriptMode(Prefs),cues=[Prefs integerForKey:TIOLocalListenModeKey]==2;
    NSString *glassesTarget=script||cues?nil:TIOLocalGlassesTargetLanguage();
    NSString *kind=cues?TIOLocalASROpenAICuesKind:glassesTarget?TIOLocalASROpenAITranslateKind:[Prefs stringForKey:TIOLocalListenASRKey]?:TIOLocalASRAppleKind;
    if(script&&[kind isEqual:TIOLocalASROpenAITranslateKind])kind=TIOLocalASROpenAILiveKind;
    TIOLocalASR *asr=[TIOLocalASR engineOfKind:kind];if(!asr)return;
    asr.language=[Prefs stringForKey:TIOLocalListenLanguageKey]?:@"zh-CN";asr.model=[Prefs stringForKey:TIOLocalListenOpenAIModelKey]?:@"gpt-transcribe";
    asr.keyProvider=^NSString *{return TIOLocalListenOpenAIKey();};
    asr.targetLanguage=glassesTarget?:[Prefs stringForKey:TIOLocalListenTargetLanguageKey]?:@"en";
    asr.onText=^(NSString *text,BOOL final){if(glassesTarget)return;TIOLocalListenAppendText(text,final);if(script)TIOLocalScriptHeard(text,final);else if(!cues)TIOLocalGlassesSource(text,final);};
    asr.onTranslation=^(NSString *text,BOOL final){if(final)TIOLocalListenAppendText([@"→ " stringByAppendingString:text],YES);if(!cues)TIOLocalGlassesTarget(text,final);};
    if(cues)asr.onHint=^(NSString *question,NSString *hint){TIOLocalListenAppendText([@"→ " stringByAppendingString:hint],YES);TIOLocalCuesAnswer(question,hint);};
    TIOLocalGlassesReset();
    if(script)TIOLocalScriptStart([Prefs stringForKey:TIOLocalListenScriptKey]?:@"");
    __weak TIOLocalASR *weak=asr;
    asr.onStatus=^(NSString *s){dispatch_async(Q,^{if(ASR&&ASR==weak&&!Undecodable)SetStatus([@"Following Live Captions · " stringByAppendingString:s]);});};
    SetStatus([@"Engine: " stringByAppendingString:glassesTarget?[NSString stringWithFormat:@"%@ to %@ (glasses CC setting)",kind,glassesTarget]:kind]);
    // OpenAI Translate sends its source transcript only now and then, so while translating
    // the original comes from OpenAI Live on the same audio and Translate gives the translation.
    if(glassesTarget){
        TIOLocalASR *o=[TIOLocalASR engineOfKind:TIOLocalASROpenAILiveKind];o.keyProvider=asr.keyProvider;o.language=asr.language;o.model=asr.model;
        __weak TIOLocalASR *weakO=o;
        o.onStatus=^(NSString *s){dispatch_async(Q,^{if(Src&&Src==weakO&&!Undecodable)SetStatus([@"Original · " stringByAppendingString:s]);});};
        o.onText=^(NSString *text,BOOL final){TIOLocalListenAppendText(text,final);TIOLocalGlassesSource(text,final);};
        Src=o;[o start];
    }
    // Hints: a second engine hears the same audio; its answers join the caption rounds.
    if(!cues&&[Prefs boolForKey:TIOLocalListenHintsKey]){
        TIOLocalASR *h=[TIOLocalASR engineOfKind:TIOLocalASROpenAICuesKind];h.keyProvider=asr.keyProvider;
        __weak TIOLocalASR *weakH=h;
        h.onStatus=^(NSString *s){dispatch_async(Q,^{if(Hints&&Hints==weakH)SetStatus([@"Hints · " stringByAppendingString:s]);});};
        h.onText=^(NSString *text,BOOL final){if(final)dispatch_async(Q,^{if(Hints&&Hints==weakH)SetStatus([NSString stringWithFormat:@"Hints · heard %lu characters",(unsigned long)text.length]);});};
        h.onTranslation=^(NSString *text,BOOL final){TIOLocalListenAppendText([NSString stringWithFormat:@"[Hint: %@]",text],YES);if(script)TIOLocalScriptHint(text);else TIOLocalGlassesHint(text);};
        Hints=h;[h start];
    }
    ASR=asr;Trigger=key;Format=[key hasPrefix:TIOLocalListenAgoraKey]?@"pcm":nil;Decoded=Failures=0;Undecodable=NO;
    SetStatus(@"Live Captions detected, starting recognition…");
    [asr start];
}
static void Feed(NSData *d){
    if(Undecodable)return;
    if(!Format){NSString *g=TIOLocalListenFormatGuess(d);Format=[g hasPrefix:@"PCM16"]?@"pcm":([g hasPrefix:@"Ogg"]||[g hasPrefix:@"WAV"])?@"container":@"opus";}
    if([Format isEqual:@"pcm"]){[ASR appendPCM16:d];[Src appendPCM16:d];[Hints appendPCM16:d];Remember(d);Decoded++;return;}
    if([Format isEqual:@"container"]){Undecodable=YES;SetStatus(@"Audio arrives in a container format that is not decoded yet. Record a sample on this page.");return;}
    // The app links libopus, so its decoder is already in this process.
    if(!Opus){OpusCreateFn create=(OpusCreateFn)dlsym(RTLD_DEFAULT,"opus_decoder_create");int error=0;Opus=create?create(16000,1,&error):NULL;
        if(!Opus){Undecodable=YES;SetStatus(@"The app's Opus decoder was not found.");return;}}
    static int16_t pcm[5760];OpusDecodeFn decode=(OpusDecodeFn)dlsym(RTLD_DEFAULT,"opus_decode");
    int n=decode?decode(Opus,d.bytes,(int32_t)d.length,pcm,5760,0):-1;
    if(n>0){NSData *out=[NSData dataWithBytes:pcm length:(NSUInteger)n*2];[ASR appendPCM16:out];[Src appendPCM16:out];[Hints appendPCM16:out];Remember(out);Decoded++;Failures=0;return;}
    if(++Failures>=10&&!Decoded){Undecodable=YES;SetStatus([NSString stringWithFormat:@"Audio is not raw Opus or PCM (%lu-byte packets starting %@). Record a sample on this page so the format can be worked out.",(unsigned long)d.length,Hex(d)]);}
}
void TIOLocalListenAutoPacket(NSString *key,NSData *packet){
    if(!Q||!packet.length)return;
    dispatch_async(Q,^{
        if(![Prefs boolForKey:TIOLocalListenAutoKey]){Stop(@"Off");return;}
        if(ASR&&!SessionOpen()){Stop(@"Waiting for Live Captions · the last session ended");return;}
        if(!ASR){if(!TIOLocalListenIsAutoTrigger(key,[Prefs stringForKey:TIOLocalListenTriggerKey]))return;Start(key);}
        if(![key isEqual:Trigger])return;
        LastPacket=CFAbsoluteTimeGetCurrent();Feed(packet);
    });
}
void TIOLocalListenAutoWorkflowStopped(void){if(Q)dispatch_async(Q,^{Stop(@"Waiting for Live Captions · the last session ended");});}
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
