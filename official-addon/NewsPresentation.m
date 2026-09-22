#import "NewsPresentation.h"
unsigned TIONewsPlaybackCommand(NSDictionary *s){if(![s[@"ready"] boolValue]||[s[@"stopping"] boolValue])return 0;return [s[@"playing"] boolValue]?4:([s[@"started"] boolValue]?5:3);}
NSDictionary *TIONewsPresentation(NSDictionary *s,BOOL busy,NSUInteger characters){
    NSString *title,*detail;BOOL available=[s[@"available"] boolValue],active=[s[@"active"] boolValue];
    if([s[@"stopping"] boolValue]){title=@"Exiting Glasses Reading";detail=@"Waiting for glasses confirmation. Do not send again.";}
    else if(active){title=[s[@"playing"] boolValue]?@"Reading on Glasses":([s[@"ready"] boolValue]?@"Script Ready":@"Sending Script");detail=s[@"state"]?:@"Waiting for glasses confirmation";}
    else if(!available){title=@"Set Up Glasses Teleprompter First";detail=@"1  In the official app, open a short script and choose auto-scroll.\n2  Prepare and start it, confirm the glasses scroll, then exit the teleprompter.\n3  Return to this News page and send content.\n\nAfter a full app restart, set up again. You can still read news on the phone before setup.";}
    else {title=@"Teleprompter Ready";detail=@"You can send this news batch. Setup status does not guarantee a live Bluetooth connection.";}
    return @{@"title":title,@"detail":detail,@"needsPreparation":@(!available&&!active),@"canFetch":@(!busy&&!active),@"canSend":@(available&&!active&&!busy&&characters>0),@"canPlay":@(!busy&&TIONewsPlaybackCommand(s)!=0),@"canStop":@(active&&!([s[@"stopping"] boolValue])),@"canTest":@(available&&!active&&!busy)};
}
