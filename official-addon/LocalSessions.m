#import "LocalSessions.h"

NSString *const TIOSessionsSaveKey=@"sessionsSave";
NSString *const TIOSessionsAudioKey=@"sessionsAudio";
static NSURL *Root,*Dir;
static NSFileHandle *Wav,*Text;
static NSDate *Began;
static NSMutableDictionary *Meta;
static unsigned long long AudioBytes;
static NSUInteger Lines;

static dispatch_queue_t Queue(void){static dispatch_queue_t q;static dispatch_once_t once;dispatch_once(&once,^{q=dispatch_queue_create("io.turboio.sessions",DISPATCH_QUEUE_SERIAL);});return q;}
static NSUserDefaults *Prefs(void){static NSUserDefaults *d;static dispatch_once_t once;dispatch_once(&once,^{d=[[NSUserDefaults alloc]initWithSuiteName:@"io.turboio.official-private-addon"];});return d;}
static BOOL On(NSString *key){return [Prefs() objectForKey:key]?[Prefs() boolForKey:key]:YES;}
BOOL TIOSessionsSaving(void){return On(TIOSessionsSaveKey);}
BOOL TIOSessionsSavingAudio(void){return On(TIOSessionsAudioKey);}
void TIOSessionsSetSaving(BOOL on){[Prefs() setBool:on forKey:TIOSessionsSaveKey];}
void TIOSessionsSetSavingAudio(BOOL on){[Prefs() setBool:on forKey:TIOSessionsAudioKey];}
static NSURL *RootURL(void){
    if(!Root)Root=[[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"TurboIOSessions" isDirectory:YES];
    return Root;
}
void TIOSessionsSetRoot(NSURL *root){dispatch_sync(Queue(),^{Root=root;});}
void TIOSessionsFlush(void){dispatch_sync(Queue(),^{});}
static NSDateFormatter *Format(NSString *f){NSDateFormatter *d=[NSDateFormatter new];d.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];d.dateFormat=f;return d;}

// 16 kHz mono PCM16. The header is rewritten from the file length when a session closes,
// and again before export, so a session cut short by a crash still plays.
static NSData *Header(uint32_t n){
    uint8_t h[44];uint32_t v;uint16_t s;
    memcpy(h,"RIFF",4);v=36+n;memcpy(h+4,&v,4);memcpy(h+8,"WAVEfmt ",8);v=16;memcpy(h+16,&v,4);s=1;memcpy(h+20,&s,2);memcpy(h+22,&s,2);
    v=16000;memcpy(h+24,&v,4);v=32000;memcpy(h+28,&v,4);s=2;memcpy(h+32,&s,2);s=16;memcpy(h+34,&s,2);memcpy(h+36,"data",4);memcpy(h+40,&n,4);
    return [NSData dataWithBytes:h length:44];
}
static unsigned long long FileBytes(NSURL *url){return [[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil] fileSize];}
static void FixWav(NSURL *url){
    unsigned long long size=FileBytes(url);if(size<44)return;
    NSFileHandle *h=[NSFileHandle fileHandleForWritingToURL:url error:nil];if(!h)return;
    @try{[h seekToFileOffset:0];[h writeData:Header((uint32_t)MIN(size-44,(unsigned long long)UINT32_MAX-36))];}@catch(NSException *e){}
    [h closeFile];
}
static void WriteMeta(void){
    NSData *json=[NSJSONSerialization dataWithJSONObject:Meta options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToURL:[Dir URLByAppendingPathComponent:@"meta.json"] atomically:YES];
}
static void Close(void){
    if(!Dir)return;
    [Text closeFile];Text=nil;
    if(Wav){[Wav closeFile];Wav=nil;FixWav([Dir URLByAppendingPathComponent:@"audio.wav"]);}
    // Nothing said and under 3 s of audio: not worth keeping.
    if(!Lines&&AudioBytes<3*32000){NSURL *day=Dir.URLByDeletingLastPathComponent;[NSFileManager.defaultManager removeItemAtURL:Dir error:nil];
        if(![[NSFileManager.defaultManager contentsOfDirectoryAtPath:day.path error:nil] count])[NSFileManager.defaultManager removeItemAtURL:day error:nil];}
    else{Meta[@"end"]=@(NSDate.date.timeIntervalSince1970);Meta[@"lines"]=@(Lines);Meta[@"audioSeconds"]=@(AudioBytes/32000.0);WriteMeta();}
    Dir=nil;Meta=nil;
}
void TIOSessionBegin(NSString *mode,NSString *engine){
    if(!TIOSessionsSaving())return;
    BOOL audio=TIOSessionsSavingAudio();NSDate *now=NSDate.date;
    dispatch_async(Queue(),^{
        Close();
        NSFileManager *fm=NSFileManager.defaultManager;NSURL *root=RootURL();
        NSURL *day=[root URLByAppendingPathComponent:[Format(@"yyyy-MM-dd") stringFromDate:now] isDirectory:YES];
        NSString *name=[Format(@"HHmmss") stringFromDate:now];NSURL *dir=[day URLByAppendingPathComponent:name isDirectory:YES];
        for(int i=2;[fm fileExistsAtPath:dir.path];i++)dir=[day URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%d",name,i] isDirectory:YES];
        if(![fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil])return;
        [root setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        NSURL *text=[dir URLByAppendingPathComponent:@"transcript.md"];
        NSString *title=[NSString stringWithFormat:@"# %@ · %@\n\nEngine: %@\n\n",mode,[Format(@"yyyy-MM-dd HH:mm") stringFromDate:now],engine];
        if(![[title dataUsingEncoding:NSUTF8StringEncoding] writeToURL:text atomically:YES])return;
        Text=[NSFileHandle fileHandleForWritingToURL:text error:nil];[Text seekToEndOfFile];
        if(audio){NSURL *wav=[dir URLByAppendingPathComponent:@"audio.wav"];if([Header(0) writeToURL:wav atomically:YES]){Wav=[NSFileHandle fileHandleForWritingToURL:wav error:nil];[Wav seekToEndOfFile];}}
        Dir=dir;Began=now;AudioBytes=0;Lines=0;
        Meta=[@{@"start":@(now.timeIntervalSince1970),@"mode":mode,@"engine":engine} mutableCopy];WriteMeta();
    });
}
void TIOSessionAudio(NSData *pcm){
    if(!pcm.length)return;NSData *copy=[pcm copy];
    dispatch_async(Queue(),^{if(!Wav)return;@try{[Wav writeData:copy];AudioBytes+=copy.length;}@catch(NSException *e){[Wav closeFile];Wav=nil;}});
}
void TIOSessionText(NSString *text){
    NSString *s=[[text stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];if(!s.length)return;
    NSDate *now=NSDate.date;
    dispatch_async(Queue(),^{
        if(!Text)return;int t=(int)MAX(0,[now timeIntervalSinceDate:Began]);
        NSString *at=t>=3600?[NSString stringWithFormat:@"%d:%02d:%02d",t/3600,t/60%60,t%60]:[NSString stringWithFormat:@"%02d:%02d",t/60,t%60];
        @try{[Text writeData:[[NSString stringWithFormat:@"[%@] %@\n",at,s] dataUsingEncoding:NSUTF8StringEncoding]];Lines++;}@catch(NSException *e){[Text closeFile];Text=nil;}
    });
}
void TIOSessionEnd(void){dispatch_async(Queue(),^{Close();});}

static NSString *Path(NSURL *u){return u.URLByStandardizingPath.URLByResolvingSymlinksInPath.path?:@"";}
static BOOL Same(NSURL *a,NSURL *b){return a&&b&&[Path(a) isEqual:Path(b)];}
static NSURL *Active(void){__block NSURL *d;dispatch_sync(Queue(),^{d=Dir;});return d;}
NSArray<NSDictionary *> *TIOSessionList(void){
    NSFileManager *fm=NSFileManager.defaultManager;NSURL *root=RootURL(),*active=Active();NSMutableArray *rows=[NSMutableArray new];
    NSArray *days=[[fm contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){return [b.lastPathComponent compare:a.lastPathComponent];}];
    for(NSURL *day in days){
        NSArray *sessions=[[fm contentsOfDirectoryAtURL:day includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){return [b.lastPathComponent compare:a.lastPathComponent options:NSNumericSearch];}];
        for(NSURL *dir in sessions){
            NSData *json=[NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"meta.json"]];NSDictionary *m=json?[NSJSONSerialization JSONObjectWithData:json options:0 error:nil]:nil;
            if(![m isKindOfClass:NSDictionary.class]||!m[@"start"])continue;
            NSString *text=[NSString stringWithContentsOfURL:[dir URLByAppendingPathComponent:@"transcript.md"] encoding:NSUTF8StringEncoding error:nil]?:@"";
            NSUInteger lines=0;NSString *preview=@"";
            for(NSString *l in [text componentsSeparatedByString:@"\n"])if([l hasPrefix:@"["]){lines++;if(!preview.length){NSRange r=[l rangeOfString:@"] "];preview=r.location!=NSNotFound?[l substringFromIndex:NSMaxRange(r)]:l;}}
            NSMutableDictionary *row=[@{@"url":dir,@"day":day.lastPathComponent,@"start":[NSDate dateWithTimeIntervalSince1970:[m[@"start"] doubleValue]],@"mode":m[@"mode"]?:@"",@"engine":m[@"engine"]?:@"",
                @"lines":@(lines),@"audioBytes":@(MAX(FileBytes([dir URLByAppendingPathComponent:@"audio.wav"]),44ULL)-44),@"preview":preview,@"active":@(Same(dir,active))} mutableCopy];
            if(m[@"end"])row[@"end"]=[NSDate dateWithTimeIntervalSince1970:[m[@"end"] doubleValue]];
            [rows addObject:row];
        }
    }
    return rows;
}
unsigned long long TIOSessionsBytes(void){
    unsigned long long n=0;for(NSURL *u in [NSFileManager.defaultManager enumeratorAtURL:RootURL() includingPropertiesForKeys:@[NSURLFileSizeKey] options:0 errorHandler:nil]){NSNumber *s=nil;[u getResourceValue:&s forKey:NSURLFileSizeKey error:nil];n+=s.unsignedLongLongValue;}
    return n;
}
static BOOL Inside(NSURL *session){return [Path(session) hasPrefix:[Path(RootURL()) stringByAppendingString:@"/"]];}
NSURL *TIOSessionAudioFile(NSURL *session){
    if(!Inside(session))return nil;NSURL *wav=[session URLByAppendingPathComponent:@"audio.wav"];if(FileBytes(wav)<=44)return nil;
    if(!Same(session,Active()))FixWav(wav);return wav;
}
NSURL *TIOSessionTranscriptFile(NSURL *session){
    if(!Inside(session))return nil;NSURL *t=[session URLByAppendingPathComponent:@"transcript.md"];return FileBytes(t)?t:nil;
}
BOOL TIOSessionDelete(NSURL *session){
    if(!Inside(session)||Same(session,Active()))return NO;
    NSFileManager *fm=NSFileManager.defaultManager;NSURL *day=session.URLByDeletingLastPathComponent;
    if(![fm removeItemAtURL:session error:nil])return NO;
    if(![[fm contentsOfDirectoryAtPath:day.path error:nil] count])[fm removeItemAtURL:day error:nil];
    return YES;
}
