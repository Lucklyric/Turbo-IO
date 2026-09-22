#import "OpenAIResponses.h"
#import <assert.h>

static NSData *SSE(NSArray<NSDictionary *> *events) {
    NSMutableString *s = [NSMutableString string];
    for (NSDictionary *e in events) {
        NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:e options:0 error:nil]
                                               encoding:NSUTF8StringEncoding];
        [s appendFormat:@"event: %@\ndata: %@\n\n", e[@"type"], json];
    }
    return [s dataUsingEncoding:NSUTF8StringEncoding];
}

static NSDictionary *ChatBody(void) {
    return @{@"model": @"gpt-6-astra", @"stream": @YES, @"max_tokens": @1024,
             @"messages": @[@{@"role": @"system", @"content": @"sys"}, @{@"role": @"user", @"content": @"hi"}],
             @"tools": @[TIOTodoCreateTool(), TIOWebSearchTool()], @"tool_choice": @"auto",
             @"parallel_tool_calls": @NO};
}

static void TestBodyTranslation(void) {
    [[[NSUserDefaults alloc] initWithSuiteName:@"io.turboio.official-private-addon"] setObject:@"medium" forKey:@"openaiReasoningEffort"];
    NSDictionary *o = TIOResponsesBody(ChatBody(), YES);
    assert([o[@"model"] isEqual:@"gpt-6-astra"] && [o[@"stream"] isEqual:@YES] && [o[@"store"] isEqual:@NO]);
    assert([o[@"reasoning"][@"effort"] isEqual:@"medium"]);
    assert([o[@"max_output_tokens"] integerValue] == 4096);
    assert(!o[@"messages"] && !o[@"max_tokens"] && !o[@"reasoning_effort"]);
    assert([o[@"input"] count] == 2 && [o[@"input"][1][@"role"] isEqual:@"user"]);
    NSArray *tools = o[@"tools"];
    BOOL todo = NO, hosted = NO, tinyfish = NO;
    for (NSDictionary *t in tools) {
        if ([t[@"name"] isEqual:@"create_todo"]) todo = YES;
        if ([t[@"type"] isEqual:@"web_search"]) hosted = YES;
        if ([t[@"name"] isEqual:@"web_search"]) tinyfish = YES;
    }
    assert(todo && hosted && !tinyfish);
    NSLog(@"PASS: chat body becomes a Responses body with reasoning, built-in search, no TinyFish");
}

static void TestEffortOff(void) {
    [[[NSUserDefaults alloc] initWithSuiteName:@"io.turboio.official-private-addon"] setObject:@"off" forKey:@"openaiReasoningEffort"];
    NSDictionary *o = TIOResponsesBody(ChatBody(), YES);
    assert(!o[@"reasoning"] && [o[@"max_output_tokens"] integerValue] == 1024);
    [[[NSUserDefaults alloc] initWithSuiteName:@"io.turboio.official-private-addon"] setObject:@"medium" forKey:@"openaiReasoningEffort"];
    NSLog(@"PASS: effort off sends no reasoning and keeps the upstream budget");
}

static void TestToolRoundTrip(void) {
    NSMutableDictionary *chat = [ChatBody() mutableCopy];
    chat[@"messages"] = @[@{@"role": @"user", @"content": @"add todo"},
                          @{@"role": @"assistant", @"content": NSNull.null,
                            @"tool_calls": @[@{@"id": @"call_1", @"type": @"function",
                                               @"function": @{@"name": @"create_todo", @"arguments": @"{\"title\":\"x\"}"}}]},
                          @{@"role": @"tool", @"tool_call_id": @"call_1", @"content": @"{\"status\":\"created\"}"}];
    NSArray *in = TIOResponsesBody(chat, YES)[@"input"];
    assert(in.count == 3);
    assert([in[1][@"type"] isEqual:@"function_call"] && [in[1][@"call_id"] isEqual:@"call_1"] && [in[1][@"name"] isEqual:@"create_todo"]);
    assert([in[2][@"type"] isEqual:@"function_call_output"] && [in[2][@"call_id"] isEqual:@"call_1"]);
    NSLog(@"PASS: tool calls and results become function_call / function_call_output items");
}

static void TestKnowledgeBlocksHostedSearch(void) {
    NSMutableDictionary *chat = [ChatBody() mutableCopy];
    chat[@"tools"] = @[TIOKnowledgeTool(NO)];
    for (NSDictionary *t in TIOResponsesBody(chat, YES)[@"tools"]) assert(![t[@"type"] isEqual:@"web_search"]);
    NSLog(@"PASS: private knowledge requests never get public web search attached");
}

static void TestForcedSearchBecomesRequired(void) {
    NSMutableDictionary *chat = [ChatBody() mutableCopy];
    chat[@"tools"] = @[TIOWebSearchTool()];
    chat[@"tool_choice"] = @{@"type": @"function", @"function": @{@"name": @"web_search"}};
    assert([TIOResponsesBody(chat, YES)[@"tool_choice"] isEqual:@"required"]);
    NSLog(@"PASS: news mode's forced search maps to tool_choice required");
}

static void TestStreamText(void) {
    TIOResponsesStream *p = [TIOResponsesStream new];
    assert([p append:SSE(@[@{@"type": @"response.created"},
                           @{@"type": @"response.output_item.done", @"item": @{@"type": @"web_search_call"}},
                           @{@"type": @"response.output_text.delta", @"delta": @"你好"},
                           @{@"type": @"response.output_text.delta", @"delta": @"，世界"},
                           @{@"type": @"response.completed"}])]);
    assert(p.done && !p.failed && [p.answer isEqual:@"你好，世界"] && p.hostedSearches == 1 && p.calls.count == 0);
    NSLog(@"PASS: streamed text assembles and built-in searches are counted");
}

static void TestStreamSplitAcrossChunks(void) {
    NSData *all = SSE(@[@{@"type": @"response.output_text.delta", @"delta": @"abc"}, @{@"type": @"response.completed"}]);
    TIOResponsesStream *p = [TIOResponsesStream new];
    for (NSUInteger i = 0; i < all.length; i += 7)
        assert([p append:[all subdataWithRange:NSMakeRange(i, MIN(7, all.length - i))]]);
    assert(p.done && [p.answer isEqual:@"abc"]);
    NSLog(@"PASS: events split across network chunks still parse");
}

static void TestStreamFunctionCall(void) {
    TIOResponsesStream *p = [TIOResponsesStream new];
    assert([p append:SSE(@[@{@"type": @"response.output_item.done",
                             @"item": @{@"type": @"function_call", @"call_id": @"c9", @"name": @"create_todo",
                                        @"arguments": @"{\"title\":\"买牛奶\"}"}},
                           @{@"type": @"response.completed"}])]);
    assert(p.done && p.calls.count == 1 && [p.calls[0][@"function"][@"name"] isEqual:@"create_todo"]);
    NSLog(@"PASS: function calls surface in the app's tool-call shape");
}

static void TestUnknownToolRejected(void) {
    TIOResponsesStream *p = [TIOResponsesStream new];
    assert(![p append:SSE(@[@{@"type": @"response.output_item.done",
                              @"item": @{@"type": @"function_call", @"call_id": @"c1", @"name": @"delete_all", @"arguments": @"{}"}}])]);
    assert(p.failed && [p.failureMessage containsString:@"delete_all"]);
    NSLog(@"PASS: a tool the app cannot execute fails loudly");
}

static void TestFailureMessage(void) {
    TIOResponsesStream *p = [TIOResponsesStream new];
    assert(![p append:SSE(@[@{@"type": @"response.failed", @"response": @{@"error": @{@"message": @"quota exceeded"}}}])]);
    assert([p.failureMessage isEqual:@"quota exceeded"]);
    NSLog(@"PASS: provider failure message is kept for display");
}

static void TestIncompleteKeepsText(void) {
    TIOResponsesStream *p = [TIOResponsesStream new];
    assert([p append:SSE(@[@{@"type": @"response.output_text.delta", @"delta": @"partial"}, @{@"type": @"response.incomplete"}])]);
    assert(p.done && [p.answer isEqual:@"partial"]);
    TIOResponsesStream *q = [TIOResponsesStream new];
    assert(![q append:SSE(@[@{@"type": @"response.incomplete"}])] && q.failureMessage.length);
    NSLog(@"PASS: truncated output keeps its text; empty truncation explains itself");
}

static void TestNonStreamingText(void) {
    NSDictionary *reply = @{@"status": @"completed", @"output": @[
        @{@"type": @"reasoning"},
        @{@"type": @"message", @"content": @[@{@"type": @"output_text", @"text": @"## 摘要"}]}]};
    assert([TIOResponsesText(reply) isEqual:@"## 摘要"]);
    assert(!TIOResponsesText(@{@"status": @"incomplete", @"output": @[]}));
    NSLog(@"PASS: non-streaming summary text is extracted, incomplete rejected");
}

static void TestRouting(void) {
    assert(TIOIsOpenAI([NSURL URLWithString:@"https://api.openai.com/v1/chat/completions"]));
    assert(!TIOIsOpenAI([NSURL URLWithString:@"https://api.deepseek.com/chat/completions"]));
    assert([TIOResponsesURL([NSURL URLWithString:@"https://api.openai.com/v1/chat/completions"]).absoluteString
            isEqual:@"https://api.openai.com/v1/responses"]);
    NSLog(@"PASS: only api.openai.com is routed to /v1/responses");
}

int main(void) {
    @autoreleasepool {
        TestBodyTranslation(); TestEffortOff(); TestToolRoundTrip(); TestKnowledgeBlocksHostedSearch();
        TestForcedSearchBecomesRequired(); TestStreamText(); TestStreamSplitAcrossChunks();
        TestStreamFunctionCall(); TestUnknownToolRejected(); TestFailureMessage();
        TestIncompleteKeepsText(); TestNonStreamingText(); TestRouting();
        NSLog(@"all openai-responses tests passed");
    }
    return 0;
}
