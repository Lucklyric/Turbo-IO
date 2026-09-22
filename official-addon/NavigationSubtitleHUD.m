#import "NavigationSubtitleHUD.h"
#import "NavigationCore.h"
#include <math.h>
NSString *TIONavSubtitleText(NSDictionary *f){
    if(![f isKindOfClass:NSDictionary.class]||![f[@"phase"] isEqual:@"navigating"]||![f[@"mode"] isEqual:@"模拟导航 · 非实际定位"])return nil;
    NSNumber *s=f[@"segment"];if(![s isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)s)==CFBooleanGetTypeID()||!isfinite(s.doubleValue)||s.doubleValue<0||s.doubleValue>100000||s.doubleValue!=s.integerValue)return nil;
    for(NSString *k in @[@"turn",@"road",@"distance"])if(![f[k] isKindOfClass:NSString.class]||![f[k] length]||[f[k] lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>240)return nil;
    if([f[@"distance"] containsString:@"—"])return nil;
    NSString *(^clean)(NSString *,NSUInteger)=^NSString *(NSString *v,NSUInteger n){return TIONavClip([[v componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "],n);};
    return [NSString stringWithFormat:@"高德模拟导航\n%@  %@\n%@\n以手机地图为准",clean(f[@"turn"],72),clean(f[@"distance"],36),clean(f[@"road"],120)];
}
@implementation TIONavSubtitleHUD {
    BOOL _enabled;
    NSString *_sid,*_latest,*_sent,*_note;
    NSTimeInterval _latestAt,_began,_lastSent;
    NSUInteger _frames;
}
- (instancetype)init{if((self=[super init]))_note=@"Subtitle navigation off";return self;}
- (NSDictionary *)status{return @{@"version":@"nav-subtitle-v1",@"enabled":@(_enabled),@"frames":@(_frames),@"note":_note?:@""};}
- (BOOL)startWithFrame:(NSDictionary *)frame at:(NSTimeInterval)now{
    NSString *text=TIONavSubtitleText(frame);if(_enabled||!text||!isfinite(now))return NO;
    NSString *sid=TIOSubtitleNavigationStart();if(!sid){_note=@"Not started: needs the preview/exit format, idle confirmation and a foreground connection";return NO;}
    _sid=sid;_enabled=YES;_latest=text;_latestAt=_began=now;_sent=nil;_frames=0;_lastSent=0;_note=@"Waiting for the subtitle session receipt";return YES;
}
- (void)offer:(NSDictionary *)frame at:(NSTimeInterval)now{
    if(!_enabled)return;NSString *text=TIONavSubtitleText(frame);
    if(!text||!isfinite(now)){[self stop:@"AMap route error or not simulated; old guidance stopped"];return;}
    _latest=text;_latestAt=now;
}
- (void)pumpAt:(NSTimeInterval)now{
    if(!_enabled)return;
    NSDictionary *s=TIOSubtitleNavigationStatus();
    if(![s[@"sid"] isEqual:_sid]||![s[@"navigation"] boolValue]||![@[@"starting",@"ready"] containsObject:s[@"phase"]]){[self stop:@"Subtitle session exited or unavailable; no automatic restart"];return;}
    if(!isfinite(now)||now<_latestAt||now-_latestAt>15){[self stop:@"Navigation data not updated for 15 s; old guidance stopped"];return;}
    if(now-_began>=240||_frames>=80){[self stop:@"4-minute/80-frame simulation test limit reached"];return;}
    if(![s[@"phase"] isEqual:@"ready"]||[s[@"pending"] boolValue]||[_latest isEqual:_sent]||(_frames&&now-_lastSent<3.2))return;
    if(!TIOSubtitleNavigationText(_sid,_latest)){[self stop:@"Navigation text not submitted; no retry loop"];return;}
    _frames++;_sent=_latest;_lastSent=now;_note=@"Subtitle guidance updated (min 3.2 s); distance is the last submitted value";
}
- (void)stop:(NSString *)reason{
    if(!_enabled)return;NSString *sid=_sid;_enabled=NO;_sid=nil;_latest=nil;
    // Runtime independently checks exact ownership; no stop of a new/foreign SID.
    TIOSubtitleNavigationStop(sid,reason);_note=[NSString stringWithFormat:@"%@; confirm the lens has exited",reason?:@"Subtitle navigation stopped"];
}
@end
