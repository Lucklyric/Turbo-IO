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
FOUNDATION_EXPORT BOOL TIOLocalListenCaptionRunning(void);
FOUNDATION_EXPORT NSArray<NSString *> *TIOLocalListenAutoLog(void);
FOUNDATION_EXPORT double TIOLocalListenAutoPeak(void);
FOUNDATION_EXPORT NSString *const TIOLocalListenAgoraKey;
FOUNDATION_EXPORT void TIOLocalListenSaveRaw(void);
FOUNDATION_EXPORT void TIOLocalListenObserveEvent(NSDictionary *event);
FOUNDATION_EXPORT void TIOLocalListenAutoWorkflowStopped(void);
FOUNDATION_EXPORT NSDictionary *_Nullable TIOLocalListenOfficialCaption(void);
FOUNDATION_EXPORT void TIOLocalListenAppendText(NSString *text,BOOL final);
FOUNDATION_EXPORT NSString *TIOLocalListenTranscript(void);
FOUNDATION_EXPORT void TIOLocalListenClearTranscript(void);
// Privacy: audio pushed to the official cloud is replaced with silence (on unless turned off).
FOUNDATION_EXPORT NSString *const TIOLocalListenSilenceCloudKey;
FOUNDATION_EXPORT NSString *const TIOLocalListenTargetLanguageKey;
FOUNDATION_EXPORT BOOL TIOLocalListenSilenceCloud(void);
// Local captions on the glasses (LocalGlasses.m).
FOUNDATION_EXPORT void TIOLocalGlassesObserveCall(id plugin,NSString *method,NSDictionary *args);
FOUNDATION_EXPORT void TIOLocalGlassesSource(NSString *text,BOOL final);
FOUNDATION_EXPORT void TIOLocalGlassesTarget(NSString *text,BOOL final);
// ISO-639-1 target from the glasses CC settings, or nil when CC is not translating.
FOUNDATION_EXPORT NSString *_Nullable TIOLocalGlassesTargetLanguage(void);
FOUNDATION_EXPORT void TIOLocalGlassesReset(void);
FOUNDATION_EXPORT void TIOLocalGlassesShowText(NSString *text);
// Script mode (LocalScript.m): TIOLocalListenModeKey 1 = Script, otherwise Translation.
FOUNDATION_EXPORT NSString *const TIOLocalListenScriptKey;
FOUNDATION_EXPORT BOOL TIOLocalScriptMode(NSUserDefaults *prefs);
FOUNDATION_EXPORT void TIOLocalScriptStart(NSString *script);
FOUNDATION_EXPORT void TIOLocalScriptHeard(NSString *text,BOOL final);
FOUNDATION_EXPORT NSString *TIOLocalScriptStatus(void);
FOUNDATION_EXPORT NSString *TIOLocalGlassesStatus(void);
FOUNDATION_EXPORT void TIOLocalGlassesObserveEvent(NSDictionary *event);
FOUNDATION_EXPORT NSDictionary *TIOLocalGlassesDiagnostics(void);
FOUNDATION_EXPORT UIViewController *TIOLocalListenController(void);
NS_ASSUME_NONNULL_END
