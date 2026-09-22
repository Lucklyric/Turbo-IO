#import "NavigationTeleHUD.h"
#import "NewsTeleprompter.h"
#import "NavigationCore.h"
#include <math.h>
NSString *TIONavTeleKey(NSDictionary *f){
    if(![f isKindOfClass:NSDictionary.class]||![f[@"phase"] isEqual:@"navigating"]||![f[@"mode"] isEqual:@"模拟导航 · 非实际定位"])return nil;
    for(NSString *k in @[@"turn",@"road",@"distance"])if(![f[k] isKindOfClass:NSString.class]||[f[k] lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>240)return nil;
    id segment=f[@"segment"];if(![segment isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)segment)==CFBooleanGetTypeID())return nil;
    double n=[segment doubleValue];if(!isfinite(n)||n<0||n>100000||n!=[segment integerValue])return nil;
    return [[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:@[segment,f[@"turn"],f[@"road"]] options:0 error:nil] encoding:NSUTF8StringEncoding];
}
NSString *TIONavTeleText(NSDictionary *f,NSUInteger sequence){
    if(!TIONavTeleKey(f)||!sequence||sequence>13)return nil;
    return [NSString stringWithFormat:@"高德模拟导航 %02lu\n%@\n%@\n更新时距转向：%@\n仅指令变化时更新，非实时距离\n请以手机地图为准",(unsigned long)sequence,TIONavClip(f[@"turn"],120),TIONavClip(f[@"road"],150),TIONavClip(f[@"distance"],60)];
}
@implementation TIONavTeleHUD {
    BOOL _enabled,_owns,_starting,_waiting;
    NSNumber *_session;
    NSDictionary *_latest;
    NSString *_committed,*_pendingKey,*_note;
    NSTimeInterval _latestAt,_lastSent,_startedAt;
    NSUInteger _frames;
}
- (instancetype)init{if((self=[super init]))_note=@"Always-on guidance off. Get the official manual teleprompter template first.";return self;}
- (NSDictionary *)status{return @{@"version":@"nav-tele-v1",@"enabled":@(_enabled),@"owns":@(_owns),@"waiting":@(_waiting||_starting),@"frames":@(_frames),@"note":_note?:@""};}
- (BOOL)matches:(NSDictionary *)s{return _owns&&[s[@"navigation"] boolValue]&&[s[@"sessionEpoch"] isEqual:_session];}
- (BOOL)enable{
    NSDictionary *s=TIONewsTeleStatus();
    if(_enabled||_owns||[s[@"active"] boolValue]||![s[@"manualAvailable"] boolValue]){_note=@"Can't enable: end the active teleprompter and get the official manual prepare/start/exit templates first";return NO;}
    _enabled=YES;_latest=nil;_committed=_pendingKey=nil;_frames=0;_waiting=_starting=NO;_note=@"Enabled, waiting for AMap simulated route instructions";return YES;
}
- (void)stop:(NSString *)reason{
    NSDictionary *s=TIONewsTeleStatus();BOOL matched=[self matches:s];
    _enabled=NO;_owns=NO;_starting=_waiting=NO;_latest=nil;_session=nil;
    // Never stop another owner even if it is also a navigation/manual session.
    if(matched&&! [s[@"stopping"] boolValue])TIONewsTeleControl(6,120);
    _note=[NSString stringWithFormat:@"%@%@",reason?:@"Always-on guidance stopped",matched?@"; exit requested, confirm the lens has closed":@""];
}
- (void)offer:(NSDictionary *)f at:(NSTimeInterval)now{
    if(!_enabled||!isfinite(now))return;
    if(!TIONavTeleKey(f)){[self stop:@"Route unavailable or not simulated; old guidance stopped"];return;}
    _latest=[f copy];_latestAt=now;
}
- (void)pumpAt:(NSTimeInterval)now{
    if(!_enabled||!isfinite(now))return;
    NSDictionary *s=TIONewsTeleStatus();
    if(_owns&&(![self matches:s]||[s[@"stopping"] boolValue]||[s[@"manualBlocked"] boolValue])){[self stop:@"Teleprompter exited, timed out or failed; re-enable manually"];return;}
    if(!_latest)return;
    if(now-_latestAt>15||now<_latestAt){[self stop:@"AMap instructions not updated for 15 s; old guidance stopped"];return;}
    if(_owns&&now-_startedAt>=300){[self stop:@"5-minute simulation test ended"];return;}
    NSString *key=TIONavTeleKey(_latest);
    if(!_owns){
        if(!TIOTeleNavigationPrepare(TIONavTeleText(_latest,1))){[self stop:@"Navigation script prep failed; no takeover, no retry"];return;}
        s=TIONewsTeleStatus();_session=s[@"sessionEpoch"];_owns=YES;_starting=YES;_pendingKey=key;_lastSent=_startedAt=now;_frames=1;_note=@"Preparing first frame; manual display starts once the script is received";return;
    }
    if(_starting){
        if(![s[@"ready"] boolValue])return;
        if(![s[@"started"] boolValue]){if(!TIONewsTeleControl(3,120))[self stop:@"Navigation teleprompter failed to start"];return;}
        if(![s[@"playing"] boolValue]||[s[@"manualPending"] unsignedIntegerValue])return;
        _starting=NO;_committed=_pendingKey;_pendingKey=nil;_note=@"Always-on guidance started; script swaps show a loading indicator";
    }
    if(_waiting){
        if([s[@"replacing"] boolValue]||![s[@"ready"] boolValue])return;
        _waiting=NO;_committed=_pendingKey;_pendingKey=nil;_note=@"New instruction received; verify the actual lens display";
    }
    if(![s[@"playing"] boolValue]){[self stop:@"Teleprompter paused; navigation display updates stopped"];return;}
    // One second slack relative to the transport's independent 15s guard.
    if([key isEqual:_committed]||now-_lastSent<16)return;
    if(_frames>=13){[self stop:@"13-frame test limit reached; updates stopped"];return;}
    if(!TIOTeleNavigationReplace(TIONavTeleText(_latest,_frames+1))){[self stop:@"Navigation script swap not submitted; updates stopped, no retry loop"];return;}
    _frames++;_lastSent=now;_pendingKey=key;_waiting=YES;_note=@"Turn or segment changed, waiting for the new script receipt; in-flight updates merged";
}
@end
