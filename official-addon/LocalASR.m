#import "LocalASR.h"
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>

NSString *const TIOLocalASRAppleKind=@"apple";
NSString *const TIOLocalASROpenAIKind=@"openai";
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
@end
@interface TIOAppleASR : TIOLocalASR @end
@interface TIOOpenAIASR : TIOLocalASR @end
@implementation TIOLocalASR
+ (instancetype)engineOfKind:(NSString *)kind{
    if([kind isEqual:TIOLocalASRAppleKind])return [TIOAppleASR new];
    if([kind isEqual:TIOLocalASROpenAIKind])return [TIOOpenAIASR new];
    return nil;
}
- (instancetype)init{if((self=[super init]))_language=@"zh-CN";return self;}
- (void)start{}
- (void)appendPCM16:(NSData *)pcm{}
- (void)stop{}
- (void)status:(NSString *)s{void (^b)(NSString *)=self.onStatus;if(b)dispatch_async(dispatch_get_main_queue(),^{b(s);});}
- (void)emit:(NSString *)text final:(BOOL)final{void (^b)(NSString *,BOOL)=self.onText;if(b&&text.length)dispatch_async(dispatch_get_main_queue(),^{b(text,final);});}
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
