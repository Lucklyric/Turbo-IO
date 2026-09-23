#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
// Local Listen, step 0: observe the official audio and Live Cues callbacks.
// Every hook forwards the original call unchanged.
FOUNDATION_EXPORT NSString *const TIOLocalListenEnabledKey;
FOUNDATION_EXPORT NSString *const TIOLocalListenModeKey;
FOUNDATION_EXPORT void TIOLocalListenConfigure(NSUserDefaults *prefs);
FOUNDATION_EXPORT BOOL TIOLocalListenInstall(void);
FOUNDATION_EXPORT BOOL TIOLocalListenInstalled(void);
FOUNDATION_EXPORT void TIOLocalListenSetActive(BOOL on);
FOUNDATION_EXPORT NSArray<NSDictionary *> *TIOLocalListenTaps(void);
FOUNDATION_EXPORT NSDictionary * _Nullable TIOLocalListenHint(void);
FOUNDATION_EXPORT NSString *TIOLocalListenInventory(void);
FOUNDATION_EXPORT NSString *TIOLocalListenFormatGuess(NSData *packet);
FOUNDATION_EXPORT BOOL TIOLocalListenRecord(NSTimeInterval seconds);
FOUNDATION_EXPORT NSTimeInterval TIOLocalListenRecordingRemaining(void);
FOUNDATION_EXPORT NSArray<NSURL *> *TIOLocalListenSampleFiles(void);
FOUNDATION_EXPORT void TIOLocalListenReset(void);
FOUNDATION_EXPORT NSString *const TIOLocalListenASRKey;
FOUNDATION_EXPORT NSString *const TIOLocalListenLanguageKey;
FOUNDATION_EXPORT NSString *const TIOLocalListenOpenAIModelKey;
// Returns the OpenAI key only when the configured endpoint is api.openai.com.
FOUNDATION_EXPORT void TIOLocalListenSetKeyProvider(NSString *_Nullable (^provider)(void));
FOUNDATION_EXPORT NSString *_Nullable TIOLocalListenOpenAIKey(void);
// Follow Live Captions (LocalListenAuto.m).
FOUNDATION_EXPORT NSString *const TIOLocalListenAutoKey;
FOUNDATION_EXPORT NSString *const TIOLocalListenTriggerKey;
FOUNDATION_EXPORT void TIOLocalListenAutoConfigure(NSUserDefaults *prefs);
FOUNDATION_EXPORT BOOL TIOLocalListenSetAuto(BOOL on);
FOUNDATION_EXPORT BOOL TIOLocalListenAutoEnabled(void);
FOUNDATION_EXPORT BOOL TIOLocalListenIsAutoTrigger(NSString *key,NSString *_Nullable chosen);
FOUNDATION_EXPORT void TIOLocalListenAutoPacket(NSString *key,NSData *packet);
FOUNDATION_EXPORT NSString *TIOLocalListenAutoStatus(void);
FOUNDATION_EXPORT void TIOLocalListenAppendText(NSString *text,BOOL final);
FOUNDATION_EXPORT NSString *TIOLocalListenTranscript(void);
FOUNDATION_EXPORT void TIOLocalListenClearTranscript(void);
FOUNDATION_EXPORT UIViewController *TIOLocalListenController(void);
NS_ASSUME_NONNULL_END
