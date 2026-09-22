#import "WebSearch.h"
#include <assert.h>
static NSString *Event(NSDictionary *d,id reason){NSDictionary *j=@{@"choices":@[@{@"delta":d,@"finish_reason":reason?:NSNull.null}]};return [NSString stringWithFormat:@"data: %@\r\n\r\n",[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:j options:0 error:nil] encoding:NSUTF8StringEncoding]];}
static BOOL Parse(NSString *s){TIOWebStream *p=[TIOWebStream new];BOOL ok=[p append:[s dataUsingEncoding:NSUTF8StringEncoding]];return ok&&p.done;}
int main(void){@autoreleasepool{
    NSString *a=Event(@{@"tool_calls":@[@{@"index":@0,@"id":@"call_1",@"type":@"function",@"function":@{@"name":@"create_todo",@"arguments":@"{\"title\":"}}]},nil);
    NSString *b=Event(@{@"tool_calls":@[@{@"index":@0,@"function":@{@"arguments":@"\"天气新闻\"}"}}]},@"tool_calls");
    NSData *bytes=[[a stringByAppendingString:b] dataUsingEncoding:NSUTF8StringEncoding];
    for(NSUInteger step=1;step<bytes.length;step++){TIOWebStream *p=[TIOWebStream new];for(NSUInteger n=0;n<bytes.length;n+=step)assert([p append:[bytes subdataWithRange:NSMakeRange(n,MIN(step,bytes.length-n))]]);assert(p.done&&!p.failed&&p.calls.count==1&&!p.answer.length);assert([p.calls[0][@"function"][@"arguments"] isEqual:@"{\"title\":\"天气新闻\"}"]);}
    assert(Parse(Event(@{@"content":@"你好"},@"stop")));
    assert(!Parse(Event(@{@"content":@"截断"},@"length")));
    assert(!Parse(@"data: [DONE]\n\n"));
    assert(!Parse(Event(@{},@"tool_calls")));
    assert(!Parse([a stringByAppendingString:Event(@{},@"stop")]));
    assert(!Parse([[a stringByAppendingString:b] stringByReplacingOccurrencesOfString:@"create_todo" withString:@"web_search"]));
    assert(!Parse(Event(@{@"tool_calls":@[@{@"index":@2}]},nil)));
    assert(!Parse(Event(@{@"tool_calls":@[@{@"index":@0,@"function":NSNull.null}]},nil)));
    assert(!Parse(@"data: {\"error\":{\"message\":\"private\"}}\n\n"));
    TIOWebChatRequest *req=[TIOWebChatRequest new];__block BOOL called=NO;req.update=^(NSString *t,BOOL d,NSString *e){called=YES;};[req cancel];assert(!called&&req.update==nil);
    NSLog(@"PASS: search SSE byte boundaries, tool allowlist, finish guards, cancel.");
}return 0;}
