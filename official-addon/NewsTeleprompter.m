#import "NewsTeleprompter.h"
#import "TodoProtocol.h"
#import "ProtocolContext.h"
#import <objc/message.h>
// Uses the official plugin instance and observed file/prepare contracts. Does
// not create a second Bluetooth client, change the official list, or start ASR.
static __weak id Plugin;
static NSDictionary *Base,*Prepare,*StartTemplate,*FileArgs,*OwnPrepare;
static NSDictionary *ManualTemplate;
static NSInteger ScrollMode=2;
static NSUInteger AudioPackets,ManualPending;
static BOOL ManualBlocked;
static BOOL ManualClosed;
static NSUInteger ManualRequestGeneration;
static NSUInteger TransferGeneration,ManualRevision;
static BOOL Replacing;
static BOOL NavigationOwned;
static NSTimeInterval NavigationReplaceAt;
static NSString *Device,*TemplateID,*Owned,*FilePath,*Note=@"Waiting for official auto-scroll samples (prepare, transfer, exit)";
static BOOL Sending,TemplateClosed,FileValidated,FileSent,FileSubmitted,FileConfirmed,Ready,Playing,Stopping,StartSent;
static NSInteger Speed=120;
static long long Offset;
static NSUInteger Epoch,PrepareReplies;
static NSUInteger ObservedMessages,ObservedFiles;
static NSDictionary *LastShape;
static NSMutableArray *Trace;
static BOOL Capturing;
static BOOL SampleFileOK,SampleReceived,SampleStarted,SampleStopped;
static void RestoreTemplates(void){
    if(Owned)return;NSString *d=TIOProtocolDevice();if(!d)return;
    if(Device&&![Device isEqual:d]){Prepare=nil;StartTemplate=nil;ManualTemplate=nil;FileArgs=nil;TemplateClosed=FileValidated=ManualClosed=NO;Capturing=NO;}
    Plugin=TIOProtocolPlugin();Base=TIOProtocolRoute(20);Device=d;if(Capturing)return;
    NSDictionary *a=TIOProtocolTemplate(@"tele-auto",d),*m=TIOProtocolTemplate(@"tele-manual",d);
    if(a||m){Prepare=(a?:m)[@"prepare"];StartTemplate=a[@"start"]?:StartTemplate;ManualTemplate=m[@"start"]?:ManualTemplate;FileArgs=@{@"deviceId":d};TemplateClosed=FileValidated=YES;if(m)ManualClosed=YES;}
}
static void PersistTemplate(BOOL manual){
    NSDictionary *start=manual?ManualTemplate:StartTemplate;if(!Prepare||!start||!FileValidated||!TemplateClosed||(manual&&!ManualClosed)||!SampleFileOK||!SampleReceived||!SampleStarted||!SampleStopped)return;
    BOOL ok=TIOProtocolSaveTemplate(manual?@"tele-manual":@"tele-auto",Device,@{@"prepare":Prepare,@"start":start,@"fileKeys":FileArgs.allKeys?:@[]});
    if(ok){Capturing=NO;Note=@"Teleprompter config saved. It restores after restart on this device, no need to repeat with an official script";}
}
static void TraceEvent(NSString *kind,NSDictionary *values){if(!Trace)Trace=[NSMutableArray new];NSMutableDictionary *row=[values mutableCopy];row[@"kind"]=kind;row[@"time"]=@([NSDate.date timeIntervalSince1970]);[Trace addObject:row];if(Trace.count>80)[Trace removeObjectAtIndex:0];}
static id Get(id o,NSString *key){@try{return [o valueForKey:key];}@catch(NSException *e){return nil;}}
static NSData *Bytes(id o){if([o isKindOfClass:NSData.class])return o;id d=Get(o,@"data");return [d isKindOfClass:NSData.class]?d:nil;}
static NSString *String(id o){return [o isKindOfClass:NSString.class]?o:@"";}
static unsigned WireType(NSData *data){
    const uint8_t *b=data.bytes;NSUInteger at=0;unsigned type=0;
    while(at<data.length){uint64_t values[2]={0,0};
        for(unsigned n=0;n<2;n++){unsigned shift=0;BOOL done=NO;while(at<data.length&&shift<64){uint8_t v=b[at++];if(shift==63&&(v&254))return 0;values[n]|=(uint64_t)(v&127)<<shift;if(!(v&128)){done=YES;break;}shift+=7;}if(!done)return 0;}
        uint64_t tag=values[0],v=values[1];if(!(tag>>3))return 0;
        if((tag&7)==0){if((tag>>3)==2){if(type||v>UINT_MAX)return 0;type=(unsigned)v;}}
        else if((tag&7)==2){if(v>data.length-at)return 0;at+=(NSUInteger)v;}else return 0;
    }return type;
}
NSString *TIONewsTeleChecksum(NSData *data){uint32_t h=2166136261u;const uint8_t *b=data.bytes;for(NSUInteger i=0;i<data.length;i++)h=(h^b[i])*16777619u;return [NSString stringWithFormat:@"%08x",h];}
static void Changed(void){
    [NSNotificationCenter.defaultCenter postNotificationName:@"TIONewsTeleChanged" object:nil];
    NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    NSDictionary *d=@{@"version":@"manual-hud-v2",@"revision":@(ManualRevision),@"replacing":@(Replacing),@"manualTemplate":@(ManualTemplate!=nil),@"manual":@(Owned&&ScrollMode==3),@"audioPackets":@(AudioPackets),@"manualPending":@(ManualPending),@"manualBlocked":@(ManualBlocked),@"state":Note?:@"",@"messages":@(ObservedMessages),@"files":@(ObservedFiles),@"prepare":@(Prepare!=nil),@"validated":@(FileValidated),@"closed":@(TemplateClosed),@"shape":LastShape?:@{},@"ready":@(Ready),@"playing":@(Playing),@"replies":@(PrepareReplies),@"trace":Trace?:@[]};
    NSString *path=[dir stringByAppendingPathComponent:@"news-tele-diagnostic.json"];[[NSJSONSerialization dataWithJSONObject:d options:0 error:nil] writeToFile:path options:NSDataWritingAtomic error:nil];[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];
}
static NSData *Packet(unsigned type,NSDictionary *j){NSData *data=[NSJSONSerialization dataWithJSONObject:j options:0 error:nil];if(!data||data.length>8192)return nil;uint8_t h[]={8,1,16,type,26};NSMutableData *p=[NSMutableData dataWithBytes:h length:5];NSUInteger n=data.length;do{uint8_t b=n&127;n>>=7;if(n)b|=128;[p appendBytes:&b length:1];}while(n);[p appendData:data];return p;}
static BOOL Call(NSString *method,NSDictionary *args,void(^result)(id)){
    Class cls=NSClassFromString(@"FlutterMethodCall");SEL make=NSSelectorFromString(@"methodCallWithMethodName:arguments:"),handle=NSSelectorFromString(@"handleMethodCall:result:");
    if(!Plugin||![TIOProtocolDevice() isEqual:Device]||![cls respondsToSelector:make]||![Plugin respondsToSelector:handle])return NO;
    id call=((id(*)(id,SEL,id,id))objc_msgSend)(cls,make,method,args);Sending=YES;
    @try{((void(*)(id,SEL,id,id))objc_msgSend)(Plugin,handle,call,result?:^(id r){});}@catch(NSException *e){Sending=NO;return NO;}Sending=NO;return YES;
}
static BOOL Send(unsigned type,NSDictionary *json){
    Class cls=NSClassFromString(@"FlutterStandardTypedData");SEL make=NSSelectorFromString(@"typedDataWithBytes:");NSData *data=Packet(type,json);
    if(!Base||!data||![cls respondsToSelector:make])return NO;NSMutableDictionary *args=[Base mutableCopy];args[@"payload"]=((id(*)(id,SEL,id))objc_msgSend)(cls,make,data);return Call(@"rayneonet_sendMessage",args,nil);
}
static void ClearSession(void){Epoch++;TransferGeneration++;Replacing=NO;NavigationOwned=NO;Owned=nil;OwnPrepare=nil;FilePath=nil;FileSent=FileSubmitted=FileConfirmed=Ready=Playing=Stopping=StartSent=NO;Offset=0;PrepareReplies=0;ManualPending=0;}
static void TransferReady(void){
    Ready=FileSubmitted&&FileConfirmed;
    if(Ready&&Replacing){Replacing=NO;TraceEvent(@"replacementReceipt",@{@"revision":@(ManualRevision),@"bytes":OwnPrepare[@"total"],@"checksum":OwnPrepare[@"checksum"]?:@""});Note=@"Replacement receipts complete. No exit or restart sent. Check the new checksum, flicker, and page exit. Receipts do not confirm a hot update";}
    else Note=Ready?@"File and glasses receipt both confirmed":@"Waiting for file return and glasses code 7 confirmation";
}
static void ManualWait(unsigned type){
    ManualPending=type;NSUInteger epoch=Epoch,request=++ManualRequestGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(epoch!=Epoch||request!=ManualRequestGeneration||ManualPending!=type||!Owned||ScrollMode!=3)return;
        ManualPending=0;ManualBlocked=YES;
        if(type!=6)TIONewsTeleControl(6,Speed);
        Note=type==6?@"Exit receipt timed out, glasses state unknown. Long-press the button to exit. Do not start a new session":@"Manual control receipt timed out, exit requested. Glasses change not confirmed, not resending";Changed();
    });
}
void TIONewsTeleObserveFileResult(NSDictionary *args,id result){
    if(![args[@"deviceId"] isEqual:Device]||(![args[@"taskId"] isEqual:TemplateID]&&![args[@"taskId"] isEqual:Owned]))return;
    if(!Owned&&[args[@"taskId"] isEqual:TemplateID]&&[result isKindOfClass:NSDictionary.class]&&[result[@"success"] isEqual:@YES]){SampleFileOK=YES;PersistTemplate(ManualTemplate!=nil);}
    NSMutableDictionary *safe=[@{@"own":@(Owned&&[args[@"taskId"] isEqual:Owned]),@"dictionary":@([result isKindOfClass:NSDictionary.class]),@"null":@(result==nil||result==NSNull.null)} mutableCopy];
    if([result isKindOfClass:NSDictionary.class])for(NSString *key in @[@"success",@"isSuccess",@"code",@"errorCode",@"status",@"result"]){id v=result[key];if([v isKindOfClass:NSNumber.class])safe[key]=v;}
    TraceEvent(@"fileResult",safe);Changed();
}
NSDictionary *TIONewsTeleStatus(void){RestoreTemplates();return @{@"navigation":@(NavigationOwned&&Owned!=nil),@"sessionEpoch":@(Epoch),@"revision":@(ManualRevision),@"replacing":@(Replacing),@"available":@(Plugin&&Base&&Prepare&&StartTemplate&&FileArgs&&TemplateClosed&&FileValidated),@"manualAvailable":@(Plugin&&Base&&Prepare&&ManualTemplate&&FileArgs&&TemplateClosed&&ManualClosed&&FileValidated),@"manual":@(Owned&&ScrollMode==3),@"manualPending":@(ManualPending),@"manualBlocked":@(ManualBlocked),@"audioPackets":@(AudioPackets),@"active":@(Owned!=nil),@"ready":@(Ready),@"playing":@(Playing),@"started":@(StartSent),@"stopping":@(Stopping),@"state":Note?:@"",@"offset":@(Offset),@"speed":@(Speed),@"prepareReplies":@(PrepareReplies),@"fileSubmitted":@(FileSubmitted)};}
void TIONewsTeleObserveCall(id plugin,NSString *method,NSDictionary *args){
    if(Sending||![args isKindOfClass:NSDictionary.class])return;
    TIOProtocolObserveCall(plugin,method,args);
    if([method isEqual:@"rayneonet_sendFile"]){ObservedFiles++;LastShape=@{@"fileKeys":[args.allKeys sortedArrayUsingSelector:@selector(compare:)],@"deviceMatches":@([args[@"deviceId"] isEqual:Device]),@"taskMatches":@([args[@"taskId"] isEqual:TemplateID])};Changed();}
    if([method isEqual:@"rayneonet_sendFile"]&&TemplateID&&!Owned&&[args[@"deviceId"] isEqual:Device]&&[args[@"taskId"] isEqual:TemplateID]){
        NSString *p=String(args[@"filePath"]);NSString *root=[NSHomeDirectory() stringByAppendingString:@"/"];
        if(![p.stringByStandardizingPath hasPrefix:root])return;
        NSDictionary *attr=[NSFileManager.defaultManager attributesOfItemAtPath:p error:nil];if([attr[NSFileSize] unsignedLongLongValue]>48000||![attr[NSFileType] isEqual:NSFileTypeRegular])return;
        NSData *data=[NSData dataWithContentsOfFile:p];NSString *checksum=String(Prepare[@"checksum"]);
        FileValidated=[p.lastPathComponent isEqual:TemplateID]&&data.length>0&&data.length==[Prepare[@"total"] unsignedLongLongValue]&&(!checksum.length||[checksum.lowercaseString isEqual:TIONewsTeleChecksum(data)]);
        if(FileValidated){FileArgs=[args copy];Plugin=plugin;Note=@"Official transfer bytes and checksum verified, waiting for official exit";}else Note=@"Official script format or checksum mismatch, custom transfer not enabled";Changed();return;
    }
    if(![method isEqual:@"rayneonet_sendMessage"]||![args[@"businessId"] isEqual:@20])return;
    NSDictionary *e=TIOTodoEnvelope(Bytes(args[@"payload"])),*j=e[@"json"];ObservedMessages++;LastShape=@{@"type":e[@"type"]?:@(-1),@"keys":[j.allKeys sortedArrayUsingSelector:@selector(compare:)]?:@[],@"scroll":[j[@"scroll"] isKindOfClass:NSNumber.class]?j[@"scroll"]:@(-1),@"action":[j[@"action"] isKindOfClass:NSNumber.class]?j[@"action"]:@(-1)};Changed();NSString *did=String(j[@"did"]);if(!did.length)return;
    if(Owned&&![did isEqual:Owned]&&([e[@"type"] isEqual:@2]||[e[@"type"] isEqual:@3])){TIONewsTeleControl(6,Speed);Note=@"Official app started another script, News requested exit";Changed();return;}
    if(Owned)return;
    if([e[@"type"] isEqual:@2]&&[j[@"action"] isEqual:@1]&&[@[@1,@2,@3] containsObject:j[@"scroll"]]){
        Capturing=YES;SampleFileOK=SampleReceived=SampleStarted=SampleStopped=NO;Plugin=plugin;Base=[args copy];Device=String(args[@"deviceId"]);TemplateID=did;Prepare=[j copy];StartTemplate=nil;ManualTemplate=nil;ManualClosed=NO;FileArgs=nil;TemplateClosed=FileValidated=NO;Note=@"Learning this teleprompter config, waiting for official transfer, start, and exit";
    }else if([did isEqual:TemplateID]&&[e[@"type"] isEqual:@3]&&[j[@"action"] isEqual:@1]&&[j[@"scroll"] isEqual:@2]&&[j[@"total"] isEqual:Prepare[@"total"]]){StartTemplate=[j copy];Note=@"Captured full auto-scroll start parameters, waiting for exit";
    }else if([did isEqual:TemplateID]&&[e[@"type"] isEqual:@3]&&[j[@"action"] isEqual:@1]&&[j[@"scroll"] isEqual:@3]&&[j[@"total"] isEqual:Prepare[@"total"]]){ManualTemplate=[j copy];Note=@"Captured manual start parameters, waiting for official exit";
    }else if([did isEqual:TemplateID]&&[e[@"type"] isEqual:@6]){TemplateClosed=YES;Note=FileValidated&&(StartTemplate||ManualTemplate)?@"Teleprompter template ready":@"Missing official start or transfer sample";PersistTemplate(NO);}
    Changed();
}
static BOOL PrepareText(NSString *text,NSInteger speed,NSInteger mode){
    NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding];
    if(Owned||![TIONewsTeleStatus()[mode==3?@"manualAvailable":@"available"] boolValue]||!data.length||text.length>12000||data.length>48000||speed<60||speed>360)return NO;
    NSDictionary *saved=Capturing?nil:TIOProtocolTemplate(mode==3?@"tele-manual":@"tele-auto",Device);if(saved){Prepare=saved[@"prepare"];if(mode==3)ManualTemplate=saved[@"start"];else StartTemplate=saved[@"start"];}
    NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon/NewsTeleprompter"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    if([[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] count]>=100){Note=@"News script cache reached 100 files, no new scripts added";Changed();return NO;}
    // The official file's basename is exactly its DID, without an extension.
    // The file transport sends that basename to firmware; adding .txt breaks
    // correlation even when MethodChannel reports success.
    NSString *did=NSUUID.UUID.UUIDString.lowercaseString,*path=[dir stringByAppendingPathComponent:did];
    if(![data writeToFile:path options:NSDataWritingWithoutOverwriting error:nil])return NO;
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600,NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:path error:nil];
    Owned=did;FilePath=path;Speed=speed;ScrollMode=mode;AudioPackets=0;ManualBlocked=NO;ManualPending=0;ManualRevision=0;Replacing=NO;NavigationOwned=NO;TransferGeneration++;NSUInteger epoch=++Epoch;
    NSMutableDictionary *j=[Prepare mutableCopy];j[@"did"]=did;j[@"total"]=@(data.length);j[@"scroll"]=@(mode);j[@"speed"]=@(speed);j[@"pageOffset"]=@0;j[@"highLightOffset"]=@0;if(j[@"checksum"])j[@"checksum"]=TIONewsTeleChecksum(data);
    OwnPrepare=[j copy];
    Note=mode==3?@"Preparing 3-section manual always-on script, waiting for glasses receipt. Display not started":@"Preparing news script, waiting for glasses reply (playback not started)";
    if(!Send(2,j)){ClearSession();Note=@"Prepare send failed, playback not started";Changed();return NO;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(Epoch==epoch&&Owned&&!Ready){TIONewsTeleControl(6,Speed);Note=@"Receipt confirmation timed out, exit requested. Not resent automatically";Changed();}});
    if(mode==3)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(Epoch==epoch&&Owned){TIONewsTeleControl(6,Speed);Note=@"5-minute test limit reached, exit requested. Check the glasses";Changed();}});
    Changed();return YES;
}
BOOL TIONewsTelePrepare(NSString *text,NSInteger speed){return PrepareText(text,speed,2);}
static NSArray *ManualSections(void){return @[@"常亮测试 7392\n第一段：继续直行\n模拟距离 200 米\n这是固定测试，不是真实导航。\n手动模式不应自行滚动。\n请观察三分钟是否仍亮屏。\n\n\n\n\n\n\n",@"常亮测试 8642\n第二段：前方右转\n模拟距离 80 米\n这是手机控制的第二段。\n确认没有自动滚回第一段。\n可以点第三段或返回第一段。\n\n\n\n\n\n\n",@"常亮测试 5173\n第三段：通过人行横道\n模拟距离 20 米\n这是手机控制的第三段。\n仍然是测试，不是道路指引。\n请返回第一段，再测试退出。\n\n\n\n\n\n\n测试尾部，请勿作为导航使用。"] ;}
NSString *TIOTeleManualText(void){return [ManualSections() componentsJoinedByString:@""];}
NSArray<NSNumber *> *TIOTeleManualOffsets(void){NSMutableArray *out=[NSMutableArray new];NSUInteger offset=0;for(NSString *s in ManualSections()){[out addObject:@(offset)];offset+=[s lengthOfBytesUsingEncoding:NSUTF8StringEncoding];}return out;}
BOOL TIOTeleManualPrepare(void){return PrepareText(TIOTeleManualText(),120,3);}
BOOL TIOTeleNavigationPrepare(NSString *text){
    if(![text isKindOfClass:NSString.class]||!text.length||[text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>1200)return NO;
    if(!PrepareText(text,120,3))return NO;
    NavigationOwned=YES;NavigationReplaceAt=NSProcessInfo.processInfo.systemUptime;
    TraceEvent(@"navigationPrepared",@{@"bytes":@([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding])});Changed();return YES;
}
static BOOL ReplaceText(NSString *text,BOOL navigation){
    if(!Owned||ScrollMode!=3||!Ready||!Playing||Stopping||ManualPending||ManualBlocked||Replacing||NavigationOwned!=navigation||ManualRevision>=(navigation?12:2))return NO;
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(navigation&&now-NavigationReplaceAt<15)return NO;
    if(![text isKindOfClass:NSString.class]||!text.length||[text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>1200)return NO;
    NSUInteger next=ManualRevision+1;
    NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding];
    // Retain the original and both replacements, each in a fresh local folder.
    // Firmware correlates the basename with DID; never edit an official file.
    NSString *dir=[[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon/NewsTeleprompter"] stringByAppendingPathComponent:[@"replacement-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if([[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir.stringByDeletingLastPathComponent error:nil] count]>=100){Note=@"Script cache reached 100 files, replacement stopped";Changed();return NO;}
    if(![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:nil])return NO;
    NSString *path=[dir stringByAppendingPathComponent:Owned];
    if(![data writeToFile:path options:NSDataWritingWithoutOverwriting error:nil])return NO;
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600,NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:path error:nil];
    NSMutableDictionary *j=[OwnPrepare mutableCopy];j[@"total"]=@(data.length);j[@"pageOffset"]=@0;j[@"highLightOffset"]=@0;j[@"scroll"]=@3;if(j[@"checksum"])j[@"checksum"]=TIONewsTeleChecksum(data);
    OwnPrepare=j;FilePath=path;ManualRevision=next;Replacing=YES;FileSent=FileSubmitted=FileConfirmed=Ready=NO;PrepareReplies=0;
    NSUInteger generation=++TransferGeneration,epoch=Epoch;
    if(navigation)NavigationReplaceAt=now;
    TraceEvent(@"replacementRequest",@{@"revision":@(next),@"bytes":@(data.length),@"checksum":TIONewsTeleChecksum(data),@"sameOwnedDid":@YES});
    if(!Send(2,j)){ManualBlocked=YES;TIONewsTeleControl(6,Speed);Note=@"Replacement prepare submit failed, exit requested. Not retrying";Changed();return NO;}
    Note=@"Body replacement requested for the same test script, waiting for receipt. No exit or restart sent";Changed();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(epoch==Epoch&&generation==TransferGeneration&&Owned&&Replacing&&!Stopping){ManualBlocked=YES;TIONewsTeleControl(6,Speed);Note=@"Replacement not confirmed in 20 s, exit requested. Check the glasses, not resending";Changed();}});
    return YES;
}
BOOL TIOTeleNavigationReplace(NSString *text){return ReplaceText(text,YES);}
BOOL TIOTeleManualReplace(void){
    NSString *text=ManualRevision==0?@"换稿 B 9264\n前方右转 80 米\n此正文不在原始三段稿里。\n同一稿件ID，新文件内容。\n检查是否闪屏或退回菜单。\n仅测试，不是真实导航。":@"换稿 C 3815\n继续直行 35 米\n第二次更新：距离与指令改变。\n请确认不再显示换稿B。\n没有手动退出或重新开始。\n仅测试，不是真实导航。\n测试结束后请点退出。";
    return ReplaceText(text,NO);
}
BOOL TIOTeleManualSeek(NSUInteger section){
    if(section>=3||!Owned||ScrollMode!=3||!Ready||!Playing||Stopping||ManualPending||ManualBlocked||Replacing||ManualRevision||NavigationOwned)return NO;
    NSUInteger offset=[TIOTeleManualOffsets()[section] unsignedIntegerValue];
    ManualWait(8);if(!Send(8,@{@"action":@1,@"did":Owned,@"pageOffset":@(offset),@"highLightOffset":@(offset),@"autoSync":@NO})){ManualPending=0;ManualBlocked=YES;TIONewsTeleControl(6,Speed);return NO;}
    TraceEvent(@"manualSeek",@{@"section":@(section+1),@"offset":@(offset)});Note=@"Section position submitted, waiting for type 8 reply. Not a confirmation the glasses jumped";Changed();return YES;
}
BOOL TIONewsTeleControl(unsigned type,NSInteger speed){
    if(!Owned||(!Ready&&type!=6)||![@[@3,@4,@5,@6,@7] containsObject:@(type)]||Stopping)return NO;
    if(ScrollMode==3&&type!=6&&(ManualPending||ManualBlocked||Replacing||type==7))return NO;
    NSMutableDictionary *j=[@{@"action":@1,@"did":Owned} mutableCopy];if(type==4){j[@"offset"]=@(Offset);j[@"code"]=@1;j[@"isCompleted"]=@NO;}
    if(type==3){NSDictionary *start=ScrollMode==3?ManualTemplate:StartTemplate;if(StartSent||!start||!OwnPrepare)return NO;j=[start mutableCopy];for(NSString *key in @[@"did",@"total",@"checksum"]){if(OwnPrepare[key])j[key]=OwnPrepare[key];}j[@"scroll"]=@(ScrollMode);j[@"speed"]=@(Speed);j[@"pageOffset"]=@0;j[@"highLightOffset"]=@0;StartSent=YES;}
    if(type==7){if(speed<60||speed>360)return NO;j[@"scroll"]=@2;j[@"speed"]=@(speed);}
    if(type==6){Stopping=YES;Playing=Ready=NO;}if(ScrollMode==3)ManualWait(type);if(!Send(type,j)){ManualPending=0;if(type==6)Stopping=NO;Note=@"Teleprompter control send failed";Changed();return NO;}
    if(type==7)Speed=speed;Note=[NSString stringWithFormat:@"Teleprompter control %u submitted, waiting for glasses reply",type];Changed();return YES;
}
void TIONewsTeleObserveEvent(NSDictionary *event){
    if(![event[@"eventType"] isEqual:@"messageReceived"])return;NSDictionary *m=event[@"message"];
    if(![m[@"deviceId"] isEqual:Device]||![m[@"businessId"] isEqual:@20])return;
    NSDictionary *e=TIOTodoEnvelope(Bytes(m[@"payload"])),*j=e[@"json"];
    // Type 9 carries binary audio. Inspect the small protobuf header without
    // storing/decoding audio; JSON-only envelope parsing must not hide it.
    NSData *raw=Bytes(m[@"payload"]);
    if(!Owned&&Capturing&&[j[@"did"] isEqual:TemplateID]&&[j[@"action"] isEqual:@2]){
        if([e[@"type"] isEqual:@2]&&[j[@"code"] isEqual:@7])SampleReceived=YES;
        if([e[@"type"] isEqual:@3]&&[j[@"code"] isEqual:@1])SampleStarted=YES;
        if([e[@"type"] isEqual:@6]&&[j[@"code"] isEqual:@1]){SampleStopped=YES;TemplateClosed=YES;if(ManualTemplate)ManualClosed=YES;}
        PersistTemplate(ManualTemplate!=nil);
    }
    if(Owned&&ScrollMode==3&&WireType(raw)==9){AudioPackets++;ManualBlocked=YES;TIONewsTeleControl(6,Speed);Note=@"Teleprompter audio packet detected on this device, always-on test exit requested. Audio not saved";Changed();return;}
    NSMutableDictionary *shape=[@{@"type":e[@"type"]?:@(-1),@"own":@(Owned&&[j[@"did"] isEqual:Owned]),@"sample":@(TemplateID&&[j[@"did"] isEqual:TemplateID])} mutableCopy];for(NSString *k in @[@"action",@"code",@"total",@"scroll",@"speed"]){if([j[k] isKindOfClass:NSNumber.class])shape[k]=j[k];}TraceEvent(@"receive",shape);Changed();
    if(!Owned&&ManualTemplate&&[j[@"did"] isEqual:TemplateID]&&[e[@"type"] isEqual:@6]&&[j[@"action"] isEqual:@2]&&[j[@"code"] isEqual:@1]){ManualClosed=YES;PersistTemplate(YES);Note=@"Manual script exit confirmed, config save attempted. No need to resample each time";Changed();}
    if(!Owned||![j[@"did"] isEqual:Owned])return;
    if(ScrollMode==3){for(NSString *key in @[@"action",@"code"]){id n=j[key];if(!n){if([key isEqual:@"code"]&&[j[@"action"] isEqual:@1])continue;return;}if(![n isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)n)==CFBooleanGetTypeID()||[n doubleValue]!=[n integerValue])return;}}
    unsigned type=[e[@"type"] unsignedIntValue];NSInteger action=[j[@"action"] integerValue],code=[j[@"code"] integerValue];
    if(ScrollMode==3&&action==2&&ManualPending==type){ManualPending=0;if(code!=1){ManualBlocked=YES;if(type!=6)TIONewsTeleControl(6,Speed);Note=@"Manual control rejected. Further jumps stopped, confirm exit";Changed();return;}if(type==8){Note=@"Received type 8/code 1 reply. Check the section on the glasses, this does not confirm rendering";TraceEvent(@"manualSeekReply",@{@"code":@(code)});Changed();return;}}
    if(type==2&&action==2&&!Stopping){
        if(Replacing&&j[@"total"]&&![j[@"total"] isEqual:OwnPrepare[@"total"]]){TraceEvent(@"replacementMismatchedTotal",@{@"code":@(code)});Changed();return;}
        PrepareReplies++;if(code!=1&&code!=7){if(Replacing){ManualBlocked=YES;TIONewsTeleControl(6,Speed);}else ClearSession();Note=[NSString stringWithFormat:@"Prepare rejected, code=%ld. Not preempting or retrying, confirm exit if replacement failed",(long)code];Changed();return;}
        if(!FileSent){if(code!=1){Note=@"Completion code arrived before file send, refusing direct playback";TIONewsTeleControl(6,Speed);Changed();return;}FileSent=YES;NSMutableDictionary *a=[FileArgs mutableCopy];a[@"filePath"]=FilePath;a[@"taskId"]=Owned;NSString *did=Owned;
            NSUInteger generation=TransferGeneration;
            BOOL sent=Call(@"rayneonet_sendFile",a,^(id result){dispatch_async(dispatch_get_main_queue(),^{if(![Owned isEqual:did]||Stopping||generation!=TransferGeneration)return;FileSubmitted=[result isKindOfClass:NSDictionary.class]&&[result[@"success"] isEqual:@YES];if(!FileSubmitted){TIONewsTeleControl(6,Speed);Note=@"File return not confirmed, exit requested";}else TransferReady();Changed();});});
            if(!sent){Note=@"File channel submit failed, exit requested";TIONewsTeleControl(6,Speed);}else Note=@"File channel submitted, waiting for glasses receipt";
        }else if(code==7){FileConfirmed=YES;TransferReady();}
    }else if(type==9){TIONewsTeleControl(6,Speed);Note=@"Read-along audio message detected, News teleprompter exit requested";}
    else if(type==6&&(action==1||(action==2&&code==1))){if(action==1)Send(6,@{@"action":@2,@"did":Owned,@"code":@1});ClearSession();Note=@"Teleprompter exited, this news batch is kept on the phone";}
    else if(type==8&&action==1){long long n=[j[@"pageOffset"] longLongValue];if(n>=0)Offset=n;Send(8,@{@"action":@2,@"did":Owned,@"code":@1});}
    else if((type==3||type==4||type==5)&&(action==1||(action==2&&code==1))&&!Stopping){Playing=type!=4;if(action==1)Send(type,@{@"action":@2,@"did":Owned,@"code":@1});Note=Playing?@"Auto-scrolling":@"Teleprompter paused";}
    Changed();
}
