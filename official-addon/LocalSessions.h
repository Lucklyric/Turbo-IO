#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Glasses sessions (LocalSessions.m): every Local Captions session (Translation, Script, Cues)
// is kept on this phone as Documents/TurboIOSessions/<yyyy-MM-dd>/<HHmmss>/ with
// transcript.md (final lines with offsets), audio.wav (16 kHz mono) and meta.json.
// Excluded from backup. All writes run on one serial queue, so callers never block.
FOUNDATION_EXPORT NSString *const TIOSessionsSaveKey;
FOUNDATION_EXPORT NSString *const TIOSessionsAudioKey;
FOUNDATION_EXPORT BOOL TIOSessionsSaving(void);
FOUNDATION_EXPORT BOOL TIOSessionsSavingAudio(void);
FOUNDATION_EXPORT void TIOSessionsSetSaving(BOOL on);
FOUNDATION_EXPORT void TIOSessionsSetSavingAudio(BOOL on);
FOUNDATION_EXPORT void TIOSessionBegin(NSString *mode,NSString *engine);
FOUNDATION_EXPORT void TIOSessionAudio(NSData *pcm16k);
FOUNDATION_EXPORT void TIOSessionText(NSString *text);
FOUNDATION_EXPORT void TIOSessionEnd(void);
// Newest first. Keys: url, day, start, end (absent while running or after a crash), mode,
// engine, lines, audioBytes, preview, active.
FOUNDATION_EXPORT NSArray<NSDictionary *> *TIOSessionList(void);
FOUNDATION_EXPORT unsigned long long TIOSessionsBytes(void);
FOUNDATION_EXPORT NSURL *_Nullable TIOSessionAudioFile(NSURL *session);
FOUNDATION_EXPORT NSURL *_Nullable TIOSessionTranscriptFile(NSURL *session);
FOUNDATION_EXPORT BOOL TIOSessionDelete(NSURL *session);
// Tests: point the store at another folder and wait for pending writes.
FOUNDATION_EXPORT void TIOSessionsSetRoot(NSURL *root);
FOUNDATION_EXPORT void TIOSessionsFlush(void);
NS_ASSUME_NONNULL_END
