#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Speech recognition backends for Local Listen. Every backend takes 16 kHz
// mono PCM16, so the audio source (phone mic now, glasses later) is swappable.
FOUNDATION_EXPORT NSString *const TIOLocalASRAppleKind;
FOUNDATION_EXPORT NSString *const TIOLocalASROpenAIKind;
FOUNDATION_EXPORT NSString *const TIOLocalASROpenAILiveKind;
FOUNDATION_EXPORT NSString *const TIOLocalASROpenAITranslateKind;
// Live Cues: Realtime model hears the conversation and answers questions as text.
// onText carries the heard question, onTranslation the hint.
FOUNDATION_EXPORT NSString *const TIOLocalASROpenAICuesKind;
FOUNDATION_EXPORT NSDictionary *TIOLocalASRTranslateEvents(void);
// Splits an append-only text stream into finished sentences and the current tail.
@interface TIOSentenceStream : NSObject
- (NSArray<NSString *> *)append:(NSString *)delta;   // sentences completed by this delta
@property(nonatomic,readonly) NSString *current;
@end
// Live transcript kept per utterance (OpenAI item_id), so overlapping utterances never mix.
// Finished utterances are released in the order they were heard. Exposed for tests.
@interface TIOItemTranscript : NSObject
- (void)commit:(NSString *)item;                                          // utterance order
- (void)delta:(NSString *)delta item:(NSString *)item;
- (NSArray<NSString *> *)complete:(NSString *)text item:(NSString *)item; // finals now released
- (NSArray<NSString *> *)fail:(NSString *)item;
@property(nonatomic,readonly) NSString *partial;                          // unreleased text, in order
@end
// Linear 16 kHz to 24 kHz resampler that keeps state across chunks. Exposed for tests.
@interface TIOResampler24k : NSObject
- (NSData *)process:(NSData *)pcm16k;
@end
FOUNDATION_EXPORT NSData *TIOLocalASRWav(NSData *pcm16k);
// Energy-based speech segmenter used by the OpenAI backend. Exposed for tests.
@interface TIOSpeechSegmenter : NSObject
@property(nonatomic,copy,nullable) void (^onSegment)(NSData *pcm16k);
- (void)append:(NSData *)pcm16k;
- (void)flush;
@end
@interface TIOLocalASR : NSObject
+ (nullable instancetype)engineOfKind:(NSString *)kind;
@property(nonatomic,copy) NSString *language;                 // BCP-47, e.g. zh-CN
@property(nonatomic,copy,nullable) NSString *model;           // OpenAI only
@property(nonatomic,copy,nullable) NSString *_Nullable (^keyProvider)(void);
@property(nonatomic,copy,nullable) void (^onText)(NSString *text,BOOL final);
@property(nonatomic,copy,nullable) void (^onStatus)(NSString *status);
// Translate engine only: ISO-639-1 output language and the translated text stream.
@property(nonatomic,copy) NSString *targetLanguage;
@property(nonatomic,copy,nullable) void (^onTranslation)(NSString *text,BOOL final);
// Cues engine only: a hint with the exact question it answers. Without it, hints go to onTranslation.
@property(nonatomic,copy,nullable) void (^onHint)(NSString *question,NSString *hint);
- (void)start;
- (void)appendPCM16:(NSData *)pcm16k;                         // any thread
- (void)stop;
@end
#if TARGET_OS_IPHONE
// Phone microphone source for testing before the glasses audio is decoded.
@interface TIOPhoneMic : NSObject
@property(nonatomic,copy,nullable) void (^onPCM)(NSData *pcm16k);
- (void)startWithCompletion:(void (^)(NSString *_Nullable error))completion;
- (void)stop;
+ (NSString *)inputRoute;
@end
#endif
NS_ASSUME_NONNULL_END
