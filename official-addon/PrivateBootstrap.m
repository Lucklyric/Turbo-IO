#import "PrivateBootstrap.h"
#import "Core.h"
NSDictionary *TIOPrivateBootstrapConfig(NSData *data){
    if(!data.length||data.length>16384)return nil;
    id j=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![j isKindOfClass:NSDictionary.class]||![j[@"schema"] isEqual:@1])return nil;
    for(NSString *k in @[@"endpoint",@"model",@"modelKey"]){id v=j[k];if(![v isKindOfClass:NSString.class]||![v length]||[v length]>4096)return nil;}
    if(!TIOValidateEndpoint(j[@"endpoint"])||!TIOChatRequest(j[@"model"],@"test"))return nil;
    if([j[@"modelKey"] rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location!=NSNotFound)return nil;
    NSMutableDictionary *out=[NSMutableDictionary new];
    for(NSString *k in @[@"endpoint",@"model",@"modelKey"])out[k]=j[k];
    for(NSString *k in @[@"deepseekDisableThinking",@"voiceExitCommands"]){if(![j[k] isKindOfClass:NSNumber.class])return nil;out[k]=@([j[k] boolValue]);}
    return out;
}
