#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Speech recognition backends for Local Listen. Every backend takes 16 kHz
// mono PCM16, so the audio source (phone mic now, glasses later) is swappable.
FOUNDATION_EXPORT NSString *const TIOLocalASRAppleKind;
FOUNDATION_EXPORT NSString *const TIOLocalASROpenAIKind;
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
