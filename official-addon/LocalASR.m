#import <os/lock.h>
#import "LocalASR.h"
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>

NSString *const TIOLocalASRAppleKind=@"apple";
NSString *const TIOLocalASROpenAIKind=@"openai";
NSString *const TIOLocalASROpenAILiveKind=@"openai-live";
NSString *const TIOLocalASROpenAITranslateKind=@"openai-translate";
NSString *const TIOLocalASROpenAICuesKind=@"openai-cues";
// Development aid: how many events of each type the OpenAI Translate socket delivered.
static NSMutableDictionary<NSString *,NSNumber *> *TranslateEvents;
static os_unfair_lock EventsLock=OS_UNFAIR_LOCK_INIT;
NSDictionary *TIOLocalASRTranslateEvents(void){os_unfair_lock_lock(&EventsLock);NSDictionary *d=[TranslateEvents copy]?:@{};os_unfair_lock_unlock(&EventsLock);return d;}

@implementation TIOSentenceStream{NSMutableString *_buffer;}
- (instancetype)init{if((self=[super init]))_buffer=[NSMutableString new];return self;}
- (NSString *)current{return [_buffer stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];}
- (NSArray<NSString *> *)append:(NSString *)delta{
    [_buffer appendString:delta?:@""];NSMutableArray *done=[NSMutableArray new];
    NSCharacterSet *enders=[NSCharacterSet characterSetWithCharactersInString:@"。！？!?；;\n"];
    for(;;){
        NSUInteger cut=NSNotFound;
        for(NSUInteger i=0;i<_buffer.length;i++){unichar c=[_buffer characterAtIndex:i];
            // A period ends a sentence only once a space follows, so "3.14" stays whole.
            if([enders characterIsMember:c]||(c=='.'&&i+1<_buffer.length&&[NSCharacterSet.whitespaceCharacterSet characterIsMember:[_buffer characterAtIndex:i+1]])){cut=i+1;break;}}
        // Long unpunctuated speech still scrolls: break at 80 characters.
        if(cut==NSNotFound&&_buffer.length>80){NSRange space=[_buffer rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet options:NSBackwardsSearch range:NSMakeRange(40,40)];cut=space.location!=NSNotFound?space.location+1:80;}
        if(cut==NSNotFound)break;
        NSString *s=[[_buffer substringToIndex:cut] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [_buffer deleteCharactersInRange:NSMakeRange(0,cut)];if(s.length)[done addObject:s];
    }
    return done;
}
@end
enum {kFrameBytes=640};   // 20 ms of 16 kHz mono PCM16

NSData *TIOLocalASRWav(NSData *pcm){
    uint32_t dataLen=(uint32_t)pcm.length,riffLen=36+dataLen,fmtLen=16,rate=16000,byteRate=32000;uint16_t format=1,channels=1,align=2,bits=16;
    NSMutableData *w=[NSMutableData dataWithCapacity:44+pcm.length];
    [w appendBytes:"RIFF" length:4];[w appendBytes:&riffLen length:4];[w appendBytes:"WAVEfmt " length:8];[w appendBytes:&fmtLen length:4];
    [w appendBytes:&format length:2];[w appendBytes:&channels length:2];[w appendBytes:&rate length:4];[w appendBytes:&byteRate length:4];
    [w appendBytes:&align length:2];[w appendBytes:&bits length:2];[w appendBytes:"data" length:4];[w appendBytes:&dataLen length:4];[w appendData:pcm];
    return w;
}

#pragma mark - Segmenter

static double RMS(const int16_t *s,NSUInteger n){double sum=0;for(NSUInteger i=0;i<n;i++)sum+=(double)s[i]*s[i];return n?sqrt(sum/n):0;}
@implementation TIOSpeechSegmenter{NSMutableData *_carry,*_segment,*_preroll;double _floor;BOOL _speaking;NSUInteger _silenceMs,_voicedMs;}
- (instancetype)init{if((self=[super init])){_carry=[NSMutableData new];_preroll=[NSMutableData new];_floor=300;}return self;}
- (void)append:(NSData *)pcm{
    [_carry appendData:pcm];NSUInteger offset=0;
    while(_carry.length-offset>=kFrameBytes){[self frame:(const int16_t *)((const uint8_t *)_carry.bytes+offset)];offset+=kFrameBytes;}
    [_carry replaceBytesInRange:NSMakeRange(0,offset) withBytes:NULL length:0];
}
- (void)frame:(const int16_t *)samples{
    // Speech is energy well above a slowly adapting noise floor.
    double rms=RMS(samples,kFrameBytes/2);BOOL voice=rms>MAX(_floor*2.5,400);
    if(!_speaking){
        if(!voice)_floor=_floor*0.95+rms*0.05;
        [_preroll appendBytes:samples length:kFrameBytes];
        if(_preroll.length>kFrameBytes*15)[_preroll replaceBytesInRange:NSMakeRange(0,kFrameBytes) withBytes:NULL length:0];
        if(voice){_speaking=YES;_segment=[_preroll mutableCopy];[_preroll setLength:0];_silenceMs=0;_voicedMs=20;}
        return;
    }
    [_segment appendBytes:samples length:kFrameBytes];
    if(voice){_voicedMs+=20;_silenceMs=0;}else _silenceMs+=20;
    // End a sentence after 0.7 s of silence, and never let one run past 15 s.
    if(_silenceMs>=700||_segment.length>=(NSUInteger)kFrameBytes*50*15)[self flush];
}
- (void)flush{
    if(_speaking&&_voicedMs>=300&&self.onSegment)self.onSegment([_segment copy]);
    _speaking=NO;_segment=nil;_silenceMs=_voicedMs=0;
}
@end

#pragma mark - Backends

@interface TIOLocalASR ()
- (void)status:(NSString *)s;
- (void)emit:(NSString *)text final:(BOOL)final;
- (void)emitTranslation:(NSString *)text final:(BOOL)final;
@end
@interface TIOAppleASR : TIOLocalASR @end
@interface TIOOpenAIASR : TIOLocalASR @end
@interface TIOOpenAILiveASR : TIOLocalASR @end
@interface TIOOpenAITranslateASR : TIOLocalASR @end
@interface TIOOpenAICuesASR : TIOLocalASR @end
@implementation TIOItemTranscript{NSMutableArray<NSString *> *_order;NSMutableDictionary<NSString *,NSMutableString *> *_text;NSMutableSet<NSString *> *_done,*_closed;NSMutableArray<NSString *> *_closedOrder;}
- (instancetype)init{if((self=[super init])){_order=[NSMutableArray new];_text=[NSMutableDictionary new];_done=[NSMutableSet new];_closed=[NSMutableSet new];_closedOrder=[NSMutableArray new];}return self;}
static NSString *Item(NSDictionary *j){return [j[@"item_id"] isKindOfClass:NSString.class]?j[@"item_id"]:@"";}
static NSString *Trim(NSString *s){return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];}
- (BOOL)note:(NSString *)item{
    if([_closed containsObject:item])return NO;
    if(!_text[item]){[_order addObject:item];_text[item]=[NSMutableString new];}
    return YES;
}
- (void)commit:(NSString *)item{[self note:item?:@""];}
- (void)delta:(NSString *)delta item:(NSString *)item{item=item?:@"";if([self note:item]&&![_done containsObject:item])[_text[item] appendString:delta];}
- (NSArray<NSString *> *)complete:(NSString *)text item:(NSString *)item{
    item=item?:@"";if(![self note:item])return @[];
    [_text[item] setString:text];[_done addObject:item];return [self releaseFinished];
}
- (NSArray<NSString *> *)fail:(NSString *)item{item=item?:@"";if(![self note:item])return @[];[_text[item] setString:@""];[_done addObject:item];return [self releaseFinished];}
- (NSArray<NSString *> *)releaseFinished{
    // A first utterance that never finishes holds back at most four later ones.
    NSMutableArray *out=[NSMutableArray new];
    while(_order.count&&([_done containsObject:_order[0]]||_order.count>5)){
        NSString *i=_order[0],*t=Trim(_text[i]);[_order removeObjectAtIndex:0];if(t.length)[out addObject:t];
        [_text removeObjectForKey:i];[_done removeObject:i];[_closed addObject:i];[_closedOrder addObject:i];
        if(_closedOrder.count>64){[_closed removeObject:_closedOrder[0]];[_closedOrder removeObjectAtIndex:0];}
    }
    return out;
}
- (NSString *)partial{NSMutableArray *p=[NSMutableArray new];for(NSString *i in _order){NSString *t=Trim(_text[i]);if(t.length)[p addObject:t];}return [p componentsJoinedByString:@" "];}
@end

@implementation TIOLocalASR
+ (instancetype)engineOfKind:(NSString *)kind{
    if([kind isEqual:TIOLocalASRAppleKind])return [TIOAppleASR new];
    if([kind isEqual:TIOLocalASROpenAIKind])return [TIOOpenAIASR new];
    if([kind isEqual:TIOLocalASROpenAILiveKind])return [TIOOpenAILiveASR new];
    if([kind isEqual:TIOLocalASROpenAITranslateKind])return [TIOOpenAITranslateASR new];
    if([kind isEqual:TIOLocalASROpenAICuesKind])return [TIOOpenAICuesASR new];
    return nil;
}
- (instancetype)init{if((self=[super init])){_language=@"zh-CN";_targetLanguage=@"en";}return self;}
- (void)start{}
- (void)appendPCM16:(NSData *)pcm{}
- (void)stop{}
- (void)status:(NSString *)s{void (^b)(NSString *)=self.onStatus;if(b)dispatch_async(dispatch_get_main_queue(),^{b(s);});}
- (void)emit:(NSString *)text final:(BOOL)final{void (^b)(NSString *,BOOL)=self.onText;if(b&&text.length)dispatch_async(dispatch_get_main_queue(),^{b(text,final);});}
- (void)emitTranslation:(NSString *)text final:(BOOL)final{void (^b)(NSString *,BOOL)=self.onTranslation;if(b&&text.length)dispatch_async(dispatch_get_main_queue(),^{b(text,final);});}
@end

@implementation TIOAppleASR{dispatch_queue_t _q;SFSpeechRecognizer *_recognizer;SFSpeechAudioBufferRecognitionRequest *_request;SFSpeechRecognitionTask *_task;AVAudioFormat *_format;CFAbsoluteTime _began;BOOL _running;NSUInteger _generation;}
- (instancetype)init{if((self=[super init]))_q=dispatch_queue_create("io.turboio.asr.apple",DISPATCH_QUEUE_SERIAL);return self;}
- (void)start{
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status){dispatch_async(self->_q,^{
        if(status!=SFSpeechRecognizerAuthorizationStatusAuthorized){[self status:@"Speech recognition permission is off. Allow it in Settings."];return;}
        self->_recognizer=[[SFSpeechRecognizer alloc]initWithLocale:[NSLocale localeWithLocaleIdentifier:self.language]];
        if(!self->_recognizer.supportsOnDeviceRecognition){[self status:[NSString stringWithFormat:@"No on-device model for %@. Add it as a Dictation language in Settings › General › Keyboard.",self.language]];return;}
        self->_format=[[AVAudioFormat alloc]initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:16000 channels:1 interleaved:YES];
        self->_running=YES;[self begin];[self status:@"Listening · Apple on-device"];
    });}];
}
- (void)begin{
    SFSpeechAudioBufferRecognitionRequest *r=[SFSpeechAudioBufferRecognitionRequest new];
    r.shouldReportPartialResults=YES;r.requiresOnDeviceRecognition=YES;r.addsPunctuation=YES;
    NSUInteger generation=++_generation;_request=r;_began=CFAbsoluteTimeGetCurrent();CFAbsoluteTime began=_began;
    __weak typeof(self) weak=self;
    _task=[_recognizer recognitionTaskWithRequest:r resultHandler:^(SFSpeechRecognitionResult *result,NSError *error){
        typeof(self) s=weak;if(!s)return;
        if(result)[s emit:result.bestTranscription.formattedString final:result.isFinal];
        if(!result.isFinal&&!error)return;
        // A task ends on a final result or an error such as long silence. Start the
        // next one, backing off when tasks fail immediately.
        double wait=CFAbsoluteTimeGetCurrent()-began<1?1:0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(wait*NSEC_PER_SEC)),s->_q,^{if(s->_running&&s->_generation==generation)[s begin];});
    }];
}
- (void)appendPCM16:(NSData *)pcm{
    dispatch_async(_q,^{
        if(!self->_running||!self->_request||pcm.length<2)return;
        AVAudioFrameCount n=(AVAudioFrameCount)(pcm.length/2);AVAudioPCMBuffer *b=[[AVAudioPCMBuffer alloc]initWithPCMFormat:self->_format frameCapacity:n];
        b.frameLength=n;memcpy(b.int16ChannelData[0],pcm.bytes,n*2);[self->_request appendAudioPCMBuffer:b];
        // Rotate before the recognizer's per-task limit; the old task still delivers its final text.
        if(CFAbsoluteTimeGetCurrent()-self->_began>50){SFSpeechAudioBufferRecognitionRequest *old=self->_request;[self begin];[old endAudio];}
    });
}
- (void)stop{dispatch_async(_q,^{self->_running=NO;[self->_request endAudio];self->_request=nil;[self status:@"Stopped"];});}
@end

@implementation TIOOpenAIASR{dispatch_queue_t _q;TIOSpeechSegmenter *_segmenter;NSMutableArray<NSData *> *_pending;BOOL _busy,_running;NSURLSession *_session;}
- (instancetype)init{if((self=[super init])){_q=dispatch_queue_create("io.turboio.asr.openai",DISPATCH_QUEUE_SERIAL);_pending=[NSMutableArray new];}return self;}
- (void)start{
    dispatch_async(_q,^{
        NSString *key=self.keyProvider?self.keyProvider():nil;
        if(!key.length){[self status:@"Set an api.openai.com endpoint and key in Endpoint & API Key first."];return;}
        self->_session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        self->_segmenter=[TIOSpeechSegmenter new];__weak typeof(self) weak=self;
        self->_segmenter.onSegment=^(NSData *pcm){[weak enqueue:pcm];};
        self->_running=YES;[self status:[NSString stringWithFormat:@"Listening · OpenAI %@, sent one sentence at a time",self.model?:@"gpt-transcribe"]];
    });
}
- (void)appendPCM16:(NSData *)pcm{dispatch_async(_q,^{if(self->_running)[self->_segmenter append:pcm];});}
- (void)stop{dispatch_async(_q,^{[self->_segmenter flush];self->_running=NO;[self status:@"Stopped"];});}
- (void)enqueue:(NSData *)pcm{
    // Runs on _q (the segmenter is only driven from _q). Drop the oldest if the network falls behind.
    [_pending addObject:pcm];if(_pending.count>6)[_pending removeObjectAtIndex:0];[self next];
}
- (void)next{
    if(_busy||!_pending.count)return;
    NSString *key=self.keyProvider?self.keyProvider():nil;if(!key.length){[_pending removeAllObjects];[self status:@"OpenAI key missing."];return;}
    NSData *pcm=_pending.firstObject;[_pending removeObjectAtIndex:0];_busy=YES;
    NSString *boundary=[@"tio-" stringByAppendingString:NSUUID.UUID.UUIDString];NSMutableData *body=[NSMutableData new];
    void (^field)(NSString *,NSString *)=^(NSString *name,NSString *value){[body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n",boundary,name,value] dataUsingEncoding:NSUTF8StringEncoding]];};
    field(@"model",self.model.length?self.model:@"gpt-transcribe");field(@"response_format",@"json");
    if([self.language hasPrefix:@"zh"])field(@"prompt",@"以下是普通话，请使用简体中文。");
    [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n",boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:TIOLocalASRWav(pcm)];[body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n",boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.openai.com/v1/audio/transcriptions"]];
    r.HTTPMethod=@"POST";r.timeoutInterval=30;r.HTTPBody=body;
    [r setValue:[@"multipart/form-data; boundary=" stringByAppendingString:boundary] forHTTPHeaderField:@"Content-Type"];[r setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    [[_session dataTaskWithRequest:r completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){dispatch_async(self->_q,^{
        self->_busy=NO;NSInteger code=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
        id j=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        if(code==200&&[j isKindOfClass:NSDictionary.class]&&[j[@"text"] isKindOfClass:NSString.class])[self emit:[j[@"text"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] final:YES];
        else{NSString *m=[j isKindOfClass:NSDictionary.class]&&[j[@"error"] isKindOfClass:NSDictionary.class]?j[@"error"][@"message"]:error.localizedDescription;[self status:[NSString stringWithFormat:@"OpenAI HTTP %ld: %@",(long)code,[m isKindOfClass:NSString.class]?m:@"no details"]];}
        [self next];
    });}] resume];
}
@end

#pragma mark - OpenAI Realtime transcription

@implementation TIOResampler24k{double _phase;int16_t _previous;}
- (NSData *)process:(NSData *)pcm{
    // Source index 0 is the last sample of the previous chunk, so output stays continuous.
    NSUInteger n=pcm.length/2;if(!n)return [NSData data];const int16_t *in=pcm.bytes;
    NSMutableData *out=[NSMutableData dataWithCapacity:(n*3/2+2)*2];double pos=_phase;
    while(pos<=(double)n-1e-9){
        NSUInteger i=(NSUInteger)pos;double f=pos-i;int16_t a=i?in[i-1]:_previous,b=in[i];
        int16_t v=(int16_t)lround(a+(b-a)*f);[out appendBytes:&v length:2];pos+=2.0/3.0;
    }
    _phase=pos-n;_previous=in[n-1];return out;
}
@end

@implementation TIOOpenAILiveASR{dispatch_queue_t _q;NSURLSession *_session;NSURLSessionWebSocketTask *_socket;TIOResampler24k *_resampler;NSMutableData *_outgoing;TIOItemTranscript *_items;NSUInteger _inflight,_dropped;BOOL _running;TIOSpeechSegmenter *_pauses;}
- (instancetype)init{if((self=[super init])){_q=dispatch_queue_create("io.turboio.asr.openai-live",DISPATCH_QUEUE_SERIAL);_outgoing=[NSMutableData new];_resampler=[TIOResampler24k new];}return self;}
- (NSString *)liveModel{return [self.model containsString:@"live"]||[self.model containsString:@"realtime"]?self.model:@"gpt-live-transcribe";}
- (void)send:(NSDictionary *)event{
    NSString *text=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:event options:0 error:nil] encoding:NSUTF8StringEncoding];
    [_socket sendMessage:[[NSURLSessionWebSocketMessage alloc]initWithString:text] completionHandler:^(NSError *error){if(error)[self status:[@"OpenAI Live send failed: " stringByAppendingString:error.localizedDescription]];}];
}
- (void)sendAudio:(NSDictionary *)event{
    // On _q. When the connection falls behind, skip audio instead of queueing it, so text stays live.
    if(_inflight>=30){if(!(_dropped++%50))[self status:@"Network is slow, skipping audio to stay live"];return;}
    _inflight++;NSString *text=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:event options:0 error:nil] encoding:NSUTF8StringEncoding];
    dispatch_queue_t q=_q;__weak typeof(self) weak=self;
    [_socket sendMessage:[[NSURLSessionWebSocketMessage alloc]initWithString:text] completionHandler:^(NSError *error){dispatch_async(q,^{typeof(self) s=weak;if(s)s->_inflight--;});}];
}
- (void)start{
    dispatch_async(_q,^{
        NSString *key=self.keyProvider?self.keyProvider():nil;
        if(!key.length){[self status:@"Set an api.openai.com endpoint and key in Endpoint & API Key first."];return;}
        NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"wss://api.openai.com/v1/realtime?intent=transcription"]];
        [r setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
        self->_session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        self->_socket=[self->_session webSocketTaskWithRequest:r];[self->_socket resume];self->_running=YES;self->_items=[TIOItemTranscript new];self->_inflight=0;
        NSMutableDictionary *transcription=[@{@"model":[self liveModel],@"languages":@[@"zh",@"en"]} mutableCopy];
        if([self.language hasPrefix:@"zh"])transcription[@"prompt"]=@"以下是普通话，请使用简体中文。";
        [self send:@{@"type":@"session.update",@"session":@{@"type":@"transcription",@"audio":@{@"input":@{
            @"format":@{@"type":@"audio/pcm",@"rate":@24000},@"transcription":transcription,
            @"turn_detection":NSNull.null}}}}];
        // gpt-live-transcribe rejects server turn detection, so commit at local pauses.
        self->_pauses=[TIOSpeechSegmenter new];__weak typeof(self) weakSelf=self;
        self->_pauses.onSegment=^(NSData *pcm){[weakSelf commit];};
        [self status:@"Connecting · OpenAI Live"];[self receive];
    });
}
- (void)receive{
    NSURLSessionWebSocketTask *socket=_socket;__weak typeof(self) weak=self;
    [socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message,NSError *error){
        typeof(self) s=weak;if(!s)return;
        dispatch_async(s->_q,^{
            if(socket!=s->_socket)return;
            if(error){if(s->_running)[s status:[@"OpenAI Live disconnected: " stringByAppendingString:error.localizedDescription]];s->_running=NO;return;}
            [s handle:message.string];[s receive];
        });
    }];
}
- (void)handle:(NSString *)text{
    id j=text?[NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]:nil;if(![j isKindOfClass:NSDictionary.class])return;
    NSString *type=j[@"type"];
    if([type hasSuffix:@"session.updated"])[self status:[NSString stringWithFormat:@"Listening · OpenAI Live %@, streaming",[self liveModel]]];
    else if([type isEqual:@"input_audio_buffer.committed"])[_items commit:Item(j)];
    else if([type isEqual:@"conversation.item.input_audio_transcription.delta"]&&[j[@"delta"] isKindOfClass:NSString.class]){[_items delta:j[@"delta"] item:Item(j)];[self emit:_items.partial final:NO];}
    else if([type isEqual:@"conversation.item.input_audio_transcription.completed"]&&[j[@"transcript"] isKindOfClass:NSString.class]){for(NSString *f in [_items complete:j[@"transcript"] item:Item(j)])[self emit:f final:YES];[self emit:_items.partial final:NO];}
    else if([type isEqual:@"conversation.item.input_audio_transcription.failed"]){for(NSString *f in [_items fail:Item(j)])[self emit:f final:YES];[self emit:_items.partial final:NO];}
    else if([type isEqual:@"error"]){id m=[j[@"error"] isKindOfClass:NSDictionary.class]?j[@"error"][@"message"]:nil;[self status:[@"OpenAI Live error: " stringByAppendingString:[m isKindOfClass:NSString.class]?m:@"no details"]];}
}
- (void)commit{
    // Runs on _q: the segmenter is only driven from appendPCM16 below.
    if(self->_outgoing.length){[self send:@{@"type":@"input_audio_buffer.append",@"audio":[self->_outgoing base64EncodedStringWithOptions:0]}];[self->_outgoing setLength:0];}
    [self send:@{@"type":@"input_audio_buffer.commit"}];
}
- (void)appendPCM16:(NSData *)pcm{
    dispatch_async(_q,^{
        if(!self->_running)return;
        [self->_outgoing appendData:[self->_resampler process:pcm]];[self->_pauses append:pcm];
        // Send about 100 ms of 24 kHz audio per event.
        if(self->_outgoing.length>=4800){[self sendAudio:@{@"type":@"input_audio_buffer.append",@"audio":[self->_outgoing base64EncodedStringWithOptions:0]}];[self->_outgoing setLength:0];}
    });
}
- (void)stop{
    dispatch_async(_q,^{
        if(!self->_running)return;self->_running=NO;
        if(self->_outgoing.length)[self send:@{@"type":@"input_audio_buffer.append",@"audio":[self->_outgoing base64EncodedStringWithOptions:0]}];[self->_outgoing setLength:0];
        [self send:@{@"type":@"input_audio_buffer.commit"}];
        // Leave a moment for the last transcript before closing.
        NSURLSessionWebSocketTask *socket=self->_socket;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),self->_q,^{[socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];if(self->_socket==socket)self->_socket=nil;});
        [self status:@"Stopped"];
    });
}
@end

#pragma mark - OpenAI Realtime translation

// One WebSocket returns both the source transcript and the translation while the
// speaker is still talking. Translated audio is ignored.
@implementation TIOOpenAITranslateASR{dispatch_queue_t _q;NSURLSession *_session;NSURLSessionWebSocketTask *_socket;TIOResampler24k *_resampler;NSMutableData *_outgoing;TIOSentenceStream *_source,*_target;NSUInteger _inflight,_dropped;BOOL _running;}
- (instancetype)init{if((self=[super init])){_q=dispatch_queue_create("io.turboio.asr.openai-translate",DISPATCH_QUEUE_SERIAL);_outgoing=[NSMutableData new];_resampler=[TIOResampler24k new];_source=[TIOSentenceStream new];_target=[TIOSentenceStream new];}return self;}
- (void)send:(NSDictionary *)event{
    NSString *text=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:event options:0 error:nil] encoding:NSUTF8StringEncoding];
    [_socket sendMessage:[[NSURLSessionWebSocketMessage alloc]initWithString:text] completionHandler:^(NSError *error){if(error)[self status:[@"OpenAI Translate send failed: " stringByAppendingString:error.localizedDescription]];}];
}
- (void)sendAudio:(NSDictionary *)event{
    // On _q. When the connection falls behind, skip audio instead of queueing it, so text stays live.
    if(_inflight>=30){if(!(_dropped++%50))[self status:@"Network is slow, skipping audio to stay live"];return;}
    _inflight++;NSString *text=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:event options:0 error:nil] encoding:NSUTF8StringEncoding];
    dispatch_queue_t q=_q;__weak typeof(self) weak=self;
    [_socket sendMessage:[[NSURLSessionWebSocketMessage alloc]initWithString:text] completionHandler:^(NSError *error){dispatch_async(q,^{typeof(self) s=weak;if(s)s->_inflight--;});}];
}
- (void)start{
    dispatch_async(_q,^{
        NSString *key=self.keyProvider?self.keyProvider():nil;
        if(!key.length){[self status:@"Set an api.openai.com endpoint and key in Endpoint & API Key first."];return;}
        NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate"]];
        [r setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
        self->_session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        self->_socket=[self->_session webSocketTaskWithRequest:r];[self->_socket resume];self->_running=YES;self->_inflight=0;
        [self send:@{@"type":@"session.update",@"session":@{@"audio":@{@"input":@{@"transcription":@{@"model":@"gpt-realtime-whisper"}},@"output":@{@"language":self.targetLanguage?:@"en"}}}}];
        [self status:@"Connecting · OpenAI Translate"];[self receive];
    });
}
- (void)receive{
    NSURLSessionWebSocketTask *socket=_socket;__weak typeof(self) weak=self;
    [socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message,NSError *error){
        typeof(self) s=weak;if(!s)return;
        dispatch_async(s->_q,^{
            if(socket!=s->_socket)return;
            if(error){if(s->_running)[s status:[@"OpenAI Translate disconnected: " stringByAppendingString:error.localizedDescription]];s->_running=NO;return;}
            [s handle:message.string];[s receive];
        });
    }];
}
- (void)handle:(NSString *)text{
    id j=text?[NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]:nil;if(![j isKindOfClass:NSDictionary.class])return;
    NSString *type=j[@"type"],*delta=[j[@"delta"] isKindOfClass:NSString.class]?j[@"delta"]:nil;
    if(type){os_unfair_lock_lock(&EventsLock);if(!TranslateEvents)TranslateEvents=[NSMutableDictionary new];TranslateEvents[type]=@(TranslateEvents[type].unsignedIntegerValue+1);os_unfair_lock_unlock(&EventsLock);}
    if([type isEqual:@"session.updated"])[self status:[NSString stringWithFormat:@"Listening · OpenAI Translate to %@",self.targetLanguage]];
    else if([type isEqual:@"session.input_transcript.delta"]&&delta){for(NSString *s in [_source append:delta])[self emit:s final:YES];[self emit:_source.current final:NO];}
    else if([type isEqual:@"session.output_transcript.delta"]&&delta){for(NSString *s in [_target append:delta])[self emitTranslation:s final:YES];[self emitTranslation:_target.current final:NO];}
    else if([type isEqual:@"error"]){id m=[j[@"error"] isKindOfClass:NSDictionary.class]?j[@"error"][@"message"]:nil;[self status:[@"OpenAI Translate error: " stringByAppendingString:[m isKindOfClass:NSString.class]?m:@"no details"]];}
}
- (void)appendPCM16:(NSData *)pcm{
    dispatch_async(_q,^{
        if(!self->_running)return;
        [self->_outgoing appendData:[self->_resampler process:pcm]];
        // 200 ms of 24 kHz PCM16 per event, as the translation guide recommends.
        if(self->_outgoing.length>=9600){[self sendAudio:@{@"type":@"session.input_audio_buffer.append",@"audio":[self->_outgoing base64EncodedStringWithOptions:0]}];[self->_outgoing setLength:0];}
    });
}
- (void)stop{
    dispatch_async(_q,^{
        if(!self->_running)return;self->_running=NO;
        NSURLSessionWebSocketTask *socket=self->_socket;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),self->_q,^{[socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];if(self->_socket==socket)self->_socket=nil;});
        [self status:@"Stopped"];
    });
}
@end

@implementation TIOOpenAICuesASR{dispatch_queue_t _q;NSURLSession *_session;NSURLSessionWebSocketTask *_socket;TIOResampler24k *_resampler;NSMutableData *_outgoing;TIOItemTranscript *_items;NSMutableDictionary<NSString *,NSString *> *_asked,*_parent,*_waiting;NSString *_lastAsked;NSUInteger _inflight,_dropped;BOOL _running;}
- (instancetype)init{if((self=[super init])){_q=dispatch_queue_create("io.turboio.asr.openai-cues",DISPATCH_QUEUE_SERIAL);_outgoing=[NSMutableData new];_resampler=[TIOResampler24k new];}return self;}
- (NSString *)realtimeModel{return [self.model hasPrefix:@"gpt-realtime"]?self.model:@"gpt-realtime-2.1-mini";}
- (void)send:(NSDictionary *)event{
    NSString *text=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:event options:0 error:nil] encoding:NSUTF8StringEncoding];
    [_socket sendMessage:[[NSURLSessionWebSocketMessage alloc]initWithString:text] completionHandler:^(NSError *error){if(error)[self status:[@"OpenAI Cues send failed: " stringByAppendingString:error.localizedDescription]];}];
}
- (void)sendAudio:(NSDictionary *)event{
    // On _q. When the connection falls behind, skip audio instead of queueing it, so text stays live.
    if(_inflight>=30){if(!(_dropped++%50))[self status:@"Network is slow, skipping audio to stay live"];return;}
    _inflight++;NSString *text=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:event options:0 error:nil] encoding:NSUTF8StringEncoding];
    dispatch_queue_t q=_q;__weak typeof(self) weak=self;
    [_socket sendMessage:[[NSURLSessionWebSocketMessage alloc]initWithString:text] completionHandler:^(NSError *error){dispatch_async(q,^{typeof(self) s=weak;if(s)s->_inflight--;});}];
}
// A hint answers the user turn its reply follows (previous_item_id). Its transcript can land
// after the hint, so the hint waits up to 3 s for it.
- (void)hint:(NSString *)hint question:(NSString *)question{
    void (^b)(NSString *,NSString *)=self.onHint;
    if(b)dispatch_async(dispatch_get_main_queue(),^{b(question?:@"",hint);});else [self emitTranslation:hint final:YES];
}
- (void)asked:(NSString *)text item:(NSString *)item{
    _lastAsked=text;if(!item.length)return;_asked[item]=text;if(_asked.count>32)[_asked removeAllObjects];
    NSString *h=_waiting[item];if(h){[_waiting removeObjectForKey:item];[self hint:h question:text];}
}
- (void)start{
    dispatch_async(_q,^{
        NSString *key=self.keyProvider?self.keyProvider():nil;
        if(!key.length){[self status:@"Set an api.openai.com endpoint and key in Endpoint & API Key first."];return;}
        NSString *url=[@"wss://api.openai.com/v1/realtime?model=" stringByAppendingString:[self realtimeModel]];
        NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        [r setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
        self->_session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        self->_socket=[self->_session webSocketTaskWithRequest:r];[self->_socket resume];self->_running=YES;self->_inflight=0;self->_items=[TIOItemTranscript new];self->_asked=[NSMutableDictionary new];self->_parent=[NSMutableDictionary new];self->_waiting=[NSMutableDictionary new];self->_lastAsked=nil;
        NSString *instructions=@"You are Live Cues on smart glasses. You silently listen to a conversation the wearer is part of. "
            "Reply with a hint only when the last turn contains an explicit, complete question that asks for information or an answer, for example a what, why, how, when, who, which or is/does question. "
            "The hint is the answer the wearer could give: at most 25 words, plain text, in the language of the question. "
            "Reply exactly NONE for everything else: statements, opinions, greetings, small talk, rhetorical questions, requests, unfinished sentences, or when you are unsure. "
            "Never explain terms that were not asked about. Never greet, never ask questions, never describe yourself.";
        [self send:@{@"type":@"session.update",@"session":@{@"type":@"realtime",@"output_modalities":@[@"text"],@"instructions":instructions,
            @"audio":@{@"input":@{@"format":@{@"type":@"audio/pcm",@"rate":@24000},@"transcription":@{@"model":@"gpt-4o-transcribe"},@"turn_detection":@{@"type":@"semantic_vad"}}}}}];
        [self status:@"Connecting · OpenAI Cues"];[self receive];
    });
}
- (void)receive{
    NSURLSessionWebSocketTask *socket=_socket;__weak typeof(self) weak=self;
    [socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message,NSError *error){
        typeof(self) s=weak;if(!s)return;
        dispatch_async(s->_q,^{
            if(socket!=s->_socket)return;
            if(error){if(s->_running)[s status:[@"OpenAI Cues disconnected: " stringByAppendingString:error.localizedDescription]];s->_running=NO;return;}
            [s handle:message.string];[s receive];
        });
    }];
}
- (void)handle:(NSString *)text{
    id j=text?[NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]:nil;if(![j isKindOfClass:NSDictionary.class])return;
    NSString *type=j[@"type"];
    if([type isEqual:@"session.updated"])[self status:[NSString stringWithFormat:@"Listening · OpenAI Cues (%@, text only)",[self realtimeModel]]];
    else if([type isEqual:@"input_audio_buffer.committed"])[_items commit:Item(j)];
    else if(([type isEqual:@"conversation.item.added"]||[type isEqual:@"conversation.item.created"])&&[j[@"item"] isKindOfClass:NSDictionary.class]&&[j[@"item"][@"role"] isEqual:@"assistant"]&&[j[@"item"][@"id"] isKindOfClass:NSString.class]&&[j[@"previous_item_id"] isKindOfClass:NSString.class]){
        _parent[j[@"item"][@"id"]]=j[@"previous_item_id"];if(_parent.count>32)[_parent removeAllObjects];}
    else if([type isEqual:@"conversation.item.input_audio_transcription.delta"]&&[j[@"delta"] isKindOfClass:NSString.class]){[_items delta:j[@"delta"] item:Item(j)];[self emit:_items.partial final:NO];}
    else if([type isEqual:@"conversation.item.input_audio_transcription.completed"]&&[j[@"transcript"] isKindOfClass:NSString.class]){
        NSString *q=[j[@"transcript"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        for(NSString *f in [_items complete:j[@"transcript"] item:Item(j)])[self emit:f final:YES];[self emit:_items.partial final:NO];
        [self asked:q item:Item(j)];}
    else if([type isEqual:@"conversation.item.input_audio_transcription.failed"]){for(NSString *f in [_items fail:Item(j)])[self emit:f final:YES];[self emit:_items.partial final:NO];}
    else if([type isEqual:@"response.output_text.done"]&&[j[@"text"] isKindOfClass:NSString.class]){
        NSString *hint=[j[@"text"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        // A newline would hide earlier caption text on the glasses.
        hint=[[hint componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
        if(!hint.length||[hint.uppercaseString hasPrefix:@"NONE"]){[self status:@"no hint for that turn"];return;}
        NSString *user=_parent[Item(j)];
        if(!user.length)[self hint:hint question:_lastAsked];
        else if(_asked[user])[self hint:hint question:_asked[user]];
        else{_waiting[user]=hint;__weak typeof(self) weak=self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),_q,^{typeof(self) s=weak;if(!s)return;NSString *h=s->_waiting[user];if(!h)return;[s->_waiting removeObjectForKey:user];[s hint:h question:s->_lastAsked];});}
    }
    else if([type isEqual:@"error"]){id m=[j[@"error"] isKindOfClass:NSDictionary.class]?j[@"error"][@"message"]:nil;[self status:[@"OpenAI Cues error: " stringByAppendingString:[m isKindOfClass:NSString.class]?m:@"no details"]];}
}
- (void)appendPCM16:(NSData *)pcm{
    dispatch_async(_q,^{
        if(!self->_running)return;
        [self->_outgoing appendData:[self->_resampler process:pcm]];
        if(self->_outgoing.length>=9600){[self sendAudio:@{@"type":@"input_audio_buffer.append",@"audio":[self->_outgoing base64EncodedStringWithOptions:0]}];[self->_outgoing setLength:0];}
    });
}
- (void)stop{
    dispatch_async(_q,^{
        if(!self->_running)return;self->_running=NO;
        [self->_socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];self->_socket=nil;
        [self->_session invalidateAndCancel];self->_session=nil;
        [self status:@"Stopped"];
    });
}
@end

#pragma mark - Phone microphone

#if TARGET_OS_IPHONE
@implementation TIOPhoneMic{AVAudioEngine *_engine;AVAudioConverter *_converter;AVAudioFormat *_output;NSString *_savedCategory,*_savedMode;AVAudioSessionCategoryOptions _savedOptions;}
+ (NSString *)inputRoute{AVAudioSessionPortDescription *p=AVAudioSession.sharedInstance.currentRoute.inputs.firstObject;return p?[NSString stringWithFormat:@"%@ (%@)",p.portName,p.portType]:@"No input";}
- (void)startWithCompletion:(void (^)(NSString *))completion{
    void (^go)(BOOL)=^(BOOL granted){dispatch_async(dispatch_get_main_queue(),^{completion(granted?[self begin]:@"Microphone permission is off.");});};
    if(@available(iOS 17,*))[AVAudioApplication requestRecordPermissionWithCompletionHandler:go];
    else [AVAudioSession.sharedInstance requestRecordPermission:go];
}
- (NSString *)begin{
    // Save the official app's session setup so stop can put it back.
    AVAudioSession *s=AVAudioSession.sharedInstance;_savedCategory=s.category;_savedMode=s.mode;_savedOptions=s.categoryOptions;NSError *error=nil;
    if(![s setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers|AVAudioSessionCategoryOptionDefaultToSpeaker error:&error]||![s setActive:YES error:&error])return error.localizedDescription?:@"Audio session failed.";
    _engine=[AVAudioEngine new];AVAudioInputNode *input=_engine.inputNode;AVAudioFormat *format=[input outputFormatForBus:0];
    if(format.sampleRate<=0){_engine=nil;return @"No microphone input available.";}
    _output=[[AVAudioFormat alloc]initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:16000 channels:1 interleaved:YES];
    _converter=[[AVAudioConverter alloc]initFromFormat:format toFormat:_output];
    __weak typeof(self) weak=self;
    [input installTapOnBus:0 bufferSize:4096 format:format block:^(AVAudioPCMBuffer *buffer,AVAudioTime *when){[weak convert:buffer];}];
    [_engine prepare];
    if(![_engine startAndReturnError:&error]){[input removeTapOnBus:0];_engine=nil;return error.localizedDescription?:@"Microphone failed to start.";}
    return nil;
}
- (void)convert:(AVAudioPCMBuffer *)buffer{
    AVAudioConverter *converter=_converter;if(!converter)return;
    AVAudioFrameCount capacity=(AVAudioFrameCount)(buffer.frameLength*16000.0/buffer.format.sampleRate)+32;
    AVAudioPCMBuffer *out=[[AVAudioPCMBuffer alloc]initWithPCMFormat:_output frameCapacity:capacity];__block BOOL fed=NO;
    [converter convertToBuffer:out error:nil withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount n,AVAudioConverterInputStatus *status){
        if(fed){*status=AVAudioConverterInputStatus_NoDataNow;return nil;}fed=YES;*status=AVAudioConverterInputStatus_HaveData;return buffer;}];
    void (^sink)(NSData *)=self.onPCM;
    if(out.frameLength&&sink)sink([NSData dataWithBytes:out.int16ChannelData[0] length:out.frameLength*2]);
}
- (void)stop{
    [_engine.inputNode removeTapOnBus:0];[_engine stop];_engine=nil;_converter=nil;
    if(_savedCategory)[AVAudioSession.sharedInstance setCategory:_savedCategory mode:_savedMode options:_savedOptions error:nil];
    _savedCategory=nil;
}
@end
#endif
