#import "LocalListen.h"
#import "FollowSession.h"
#import "PageTeleprompter.h"

// Script mode: follow your own script while you speak and show the part still ahead
// on the glasses CC display. Main thread only.
NSString *const TIOLocalListenScriptKey=@"localListenScript";
static TIOFollowSession *Session;
static NSArray<NSString *> *Pages;
static NSMutableArray<NSString *> *Heard;
static NSString *State=@"No script loaded",*Hint;
static NSUInteger HintEpoch;

NSString *TIOLocalScriptStatus(void){return State;}
BOOL TIOLocalScriptMode(NSUserDefaults *prefs){return [prefs integerForKey:TIOLocalListenModeKey]==1;}
static NSString *After(NSString *page,NSUInteger bytes){
    NSData *d=[page dataUsingEncoding:NSUTF8StringEncoding];if(bytes>=d.length)return @"";
    NSString *s=[[NSString alloc]initWithData:[d subdataWithRange:NSMakeRange(bytes,d.length-bytes)] encoding:NSUTF8StringEncoding];
    return [s?:@"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static void Show(void){
    NSUInteger i=Session.pageIndex;if(i>=Pages.count)return;
    // What is still ahead on this page, then the next page, as far as four short lines allow.
    NSMutableString *text=[After(Pages[i],Session.cursorByteOffset) mutableCopy];
    if(i+1<Pages.count)[text appendFormat:@"%@%@",text.length?@"\n":@"",Pages[i+1]];
    // The hint counts toward the same 160 characters, so the script gives way to it.
    NSString *hint=Hint.length?[NSString stringWithFormat:@" [Hint: %@]",Hint]:@"";
    NSUInteger room=hint.length<160?160-hint.length:0;
    if(text.length>room)[text setString:[text substringToIndex:room]];
    State=[NSString stringWithFormat:@"Page %lu of %lu",(unsigned long)i+1,(unsigned long)Pages.count];
    NSString *shown=[(text.length?text:@"End of script") stringByAppendingString:hint];
    TIOLocalGlassesShowText(shown);
}
void TIOLocalScriptStart(NSString *script){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TIOLocalScriptStart(script);});return;}
    Pages=TIOPagePaginate(script,40);Heard=[NSMutableArray new];Hint=nil;HintEpoch++;
    if(!Pages.count){Session=nil;State=@"No script loaded";return;}
    Session=[[TIOFollowSession alloc]initWithPages:Pages];Show();
}
void TIOLocalScriptHeard(NSString *text,BOOL final){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TIOLocalScriptHeard(text,final);});return;}
    if(!Session)return;
    // The matcher sees the last two finished sentences plus the one in progress.
    NSMutableArray *window=[Heard mutableCopy];if(!final)[window addObject:text];
    if(final){[Heard addObject:text];while(Heard.count>2)[Heard removeObjectAtIndex:0];window=[Heard mutableCopy];}
    TIOFollowCommand c=[Session observe:[window componentsJoinedByString:@" "]];
    if(c.kind==TIOFollowAdvance)[Heard removeAllObjects];
    if(c.kind!=TIOFollowNone)Show();
}
// A hint from the parallel Cues engine shows under the script for 15 s.
void TIOLocalScriptHint(NSString *hint){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TIOLocalScriptHint(hint);});return;}
    if(!Session)return;Hint=[hint copy];NSUInteger epoch=++HintEpoch;Show();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(epoch==HintEpoch){Hint=nil;Show();}});
}
