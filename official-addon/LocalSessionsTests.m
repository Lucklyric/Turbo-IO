#import "LocalSessions.h"
#import <assert.h>
int main(void){@autoreleasepool{
    NSURL *root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    TIOSessionsSetRoot(root);TIOSessionsSetSaving(YES);TIOSessionsSetSavingAudio(YES);
    // A session with text and 4 s of audio is kept, with a playable WAV header.
    TIOSessionBegin(@"Translation",@"openai-translate");
    NSMutableData *pcm=[NSMutableData dataWithLength:4*32000];TIOSessionAudio(pcm);
    TIOSessionText(@"hello\nworld");TIOSessionText(@"→ 你好");TIOSessionText(@"   ");
    TIOSessionsFlush();
    NSArray *rows=TIOSessionList();assert(rows.count==1);assert([rows[0][@"active"] boolValue]);assert(!TIOSessionDelete(rows[0][@"url"]));
    TIOSessionEnd();TIOSessionsFlush();
    rows=TIOSessionList();NSDictionary *s=rows[0];
    assert(![s[@"active"] boolValue]&&s[@"end"]);assert([s[@"lines"] integerValue]==2);assert([s[@"preview"] isEqual:@"hello world"]);assert([s[@"audioBytes"] integerValue]==4*32000);
    NSData *wav=[NSData dataWithContentsOfURL:TIOSessionAudioFile(s[@"url"])];uint32_t n;[wav getBytes:&n range:NSMakeRange(40,4)];assert(n==4*32000);
    NSString *text=[NSString stringWithContentsOfURL:TIOSessionTranscriptFile(s[@"url"]) encoding:NSUTF8StringEncoding error:nil];
    assert([text hasPrefix:@"# Translation · "]);assert([text containsString:@"[00:00] hello world\n[00:00] → 你好\n"]);
    // A session with nothing said and under 3 s of audio is dropped.
    TIOSessionBegin(@"Script",@"openai-live");TIOSessionAudio([NSMutableData dataWithLength:32000]);TIOSessionEnd();TIOSessionsFlush();
    assert(TIOSessionList().count==1);
    // Audio off: transcript only. Saving off: nothing.
    TIOSessionsSetSavingAudio(NO);TIOSessionBegin(@"Cues",@"openai-cues");TIOSessionText(@"q");TIOSessionEnd();TIOSessionsFlush();
    rows=TIOSessionList();assert(rows.count==2);assert(!TIOSessionAudioFile(rows[0][@"url"])&&TIOSessionTranscriptFile(rows[0][@"url"]));
    TIOSessionsSetSaving(NO);TIOSessionBegin(@"Cues",@"x");TIOSessionText(@"q");TIOSessionEnd();TIOSessionsFlush();assert(TIOSessionList().count==2);
    // Paths outside the store are refused; delete removes an emptied day folder.
    assert(!TIOSessionDelete([NSURL fileURLWithPath:@"/tmp"]));assert(!TIOSessionAudioFile([NSURL fileURLWithPath:@"/tmp"]));
    for(NSDictionary *r in TIOSessionList())assert(TIOSessionDelete(r[@"url"]));
    assert(![[NSFileManager.defaultManager contentsOfDirectoryAtPath:root.path error:nil] count]);
    [[[NSUserDefaults alloc]initWithSuiteName:@"io.turboio.official-private-addon"] removeObjectForKey:TIOSessionsSaveKey];
    [[[NSUserDefaults alloc]initWithSuiteName:@"io.turboio.official-private-addon"] removeObjectForKey:TIOSessionsAudioKey];
    [NSFileManager.defaultManager removeItemAtURL:root error:nil];
    NSLog(@"PASS: glasses sessions saved by date, empty ones dropped, export files and delete guarded");
}return 0;}
