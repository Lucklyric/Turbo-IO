#import "OpenAIResponses.h"

static NSString *Str(id x) { return [x isKindOfClass:NSString.class] ? x : @""; }

BOOL TIOIsOpenAI(NSURL *endpoint) {
    return [endpoint.host.lowercaseString isEqual:@"api.openai.com"];
}

NSURL *TIOResponsesURL(NSURL *endpoint) {
    return TIOIsOpenAI(endpoint) ? [NSURL URLWithString:@"https://api.openai.com/v1/responses"] : endpoint;
}

NSString *TIOOpenAIEffort(void) {
    NSString *e = [[[NSUserDefaults alloc] initWithSuiteName:@"io.turboio.official-private-addon"]
                   stringForKey:@"openaiReasoningEffort"];
    if ([e isEqual:@"off"]) return nil;
    NSArray *valid = @[@"none", @"minimal", @"low", @"medium", @"high", @"xhigh"];
    return [valid containsObject:e] ? e : @"medium";
}

NSDictionary *TIOResponsesBody(NSDictionary *chat, BOOL hostedSearch) {
    NSMutableDictionary *o = [NSMutableDictionary dictionary];
    o[@"model"] = Str(chat[@"model"]);
    o[@"stream"] = [chat[@"stream"] isEqual:@YES] ? @YES : @NO;
    o[@"store"] = @NO;

    NSString *effort = TIOOpenAIEffort();
    NSInteger cap = MAX([chat[@"max_tokens"] integerValue], [chat[@"max_completion_tokens"] integerValue]);
    if (effort) {
        o[@"reasoning"] = @{@"effort": effort};
        cap = MAX(cap, 4096);   // reasoning tokens count against the budget
    }
    o[@"max_output_tokens"] = @(cap > 0 ? cap : 4096);

    NSMutableArray *input = [NSMutableArray array];
    for (NSDictionary *m in chat[@"messages"]) {
        if (![m isKindOfClass:NSDictionary.class]) continue;
        NSString *role = Str(m[@"role"]);
        if ([role isEqual:@"tool"]) {
            [input addObject:@{@"type": @"function_call_output",
                               @"call_id": Str(m[@"tool_call_id"]),
                               @"output": Str(m[@"content"])}];
            continue;
        }
        NSString *content = Str(m[@"content"]);
        NSArray *calls = [m[@"tool_calls"] isKindOfClass:NSArray.class] ? m[@"tool_calls"] : nil;
        if (content.length || !calls.count) [input addObject:@{@"role": role, @"content": content}];
        for (NSDictionary *c in calls) {
            NSDictionary *f = [c[@"function"] isKindOfClass:NSDictionary.class] ? c[@"function"] : @{};
            [input addObject:@{@"type": @"function_call", @"call_id": Str(c[@"id"]),
                               @"name": Str(f[@"name"]), @"arguments": Str(f[@"arguments"])}];
        }
    }
    o[@"input"] = input;

    NSMutableArray *tools = [NSMutableArray array];
    BOOL knowledge = NO;
    for (NSDictionary *t in chat[@"tools"]) {
        NSDictionary *f = [t[@"function"] isKindOfClass:NSDictionary.class] ? t[@"function"] : nil;
        NSString *name = Str(f[@"name"]);
        if (!name.length || [name isEqual:@"web_search"]) continue;   // TinyFish is never used
        if ([name hasPrefix:@"knowledge_query"]) knowledge = YES;
        [tools addObject:@{@"type": @"function", @"name": name,
                           @"description": Str(f[@"description"]),
                           @"parameters": f[@"parameters"] ?: @{}, @"strict": @NO}];
    }
    if (hostedSearch && !knowledge) [tools addObject:@{@"type": @"web_search"}];
    if (tools.count) {
        o[@"tools"] = tools;
        id tc = chat[@"tool_choice"];
        if ([tc isKindOfClass:NSString.class]) {
            o[@"tool_choice"] = tc;
        } else if ([tc isKindOfClass:NSDictionary.class]) {
            NSString *forced = Str(tc[@"function"][@"name"]);
            // Forcing the old web_search function means "search first": require a tool.
            o[@"tool_choice"] = [forced isEqual:@"web_search"] ? @"required"
                                : @{@"type": @"function", @"name": forced};
        }
        if (chat[@"parallel_tool_calls"]) o[@"parallel_tool_calls"] = chat[@"parallel_tool_calls"];
    }
    return o;
}

NSString *TIOResponsesText(id json) {
    if (![json isKindOfClass:NSDictionary.class] || ![json[@"status"] isEqual:@"completed"]) return nil;
    NSMutableString *text = [NSMutableString string];
    for (NSDictionary *item in json[@"output"]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        if ([item[@"type"] isEqual:@"function_call"]) return nil;     // summaries must not call tools
        if (![item[@"type"] isEqual:@"message"]) continue;
        for (NSDictionary *part in item[@"content"]) {
            if ([part isKindOfClass:NSDictionary.class] && [part[@"type"] isEqual:@"output_text"])
                [text appendString:Str(part[@"text"])];
        }
    }
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length && text.length <= 64000 ? [text copy] : nil;
}

#pragma mark - Stream

@implementation TIOResponsesStream {
    NSMutableData *_buf;
    NSMutableArray<NSString *> *_data;
    NSMutableString *_text;
    NSMutableArray<NSDictionary *> *_calls;
    NSUInteger _bytes;
    BOOL _rDone, _rFailed;
}

- (instancetype)init {
    if ((self = [super init])) {
        _buf = [NSMutableData data];
        _data = [NSMutableArray array];
        _text = [NSMutableString string];
        _calls = [NSMutableArray array];
    }
    return self;
}

- (BOOL)done { return _rDone; }
- (BOOL)failed { return _rFailed; }
- (NSString *)answer { return [_text copy]; }
- (NSArray<NSDictionary *> *)calls { return [_calls copy]; }

- (void)fail:(NSString *)message {
    _rFailed = YES;
    if (!_failureMessage && message.length) _failureMessage = [message copy];
}

/// Only the function tools upstream knows how to execute are accepted.
static BOOL ValidCall(NSString *name, NSString *args) {
    if ([name isEqual:@"create_todo"]) return TIOTodoToolTitle(args) != nil;
    if ([name isEqual:@"knowledge_query"]) return TIOKnowledgeArguments(args, NO) != nil;
    if ([name isEqual:@"knowledge_query_status"]) return TIOKnowledgeArguments(args, YES) != nil;
    return NO;
}

- (void)event {
    if (!_data.count) return;
    NSString *raw = [_data componentsJoinedByString:@"\n"];
    [_data removeAllObjects];
    if ([raw isEqual:@"[DONE]"]) return;
    id j = [NSJSONSerialization JSONObjectWithData:[raw dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![j isKindOfClass:NSDictionary.class]) { [self fail:@"模型流式事件格式无效"]; return; }
    NSString *type = Str(j[@"type"]);

    if ([type isEqual:@"response.output_text.delta"]) {
        [_text appendString:Str(j[@"delta"])];
        if (_text.length > 64000) [self fail:@"回答超过长度上限"];
    } else if ([type isEqual:@"response.output_item.done"]) {
        NSDictionary *item = [j[@"item"] isKindOfClass:NSDictionary.class] ? j[@"item"] : @{};
        NSString *itype = Str(item[@"type"]);
        if ([itype isEqual:@"web_search_call"]) {
            _hostedSearches++;
        } else if ([itype isEqual:@"function_call"]) {
            NSString *callID = Str(item[@"call_id"]), *name = Str(item[@"name"]), *args = Str(item[@"arguments"]);
            if (!callID.length || _calls.count >= 2 || !ValidCall(name, args)) {
                [self fail:[NSString stringWithFormat:@"模型调用了不受支持的工具：%@", name]];
                return;
            }
            [_calls addObject:@{@"id": callID, @"type": @"function",
                                @"function": @{@"name": name, @"arguments": args}}];
        }
    } else if ([type isEqual:@"response.completed"]) {
        _rDone = YES;
    } else if ([type isEqual:@"response.incomplete"]) {
        // Truncated by max_output_tokens: keep the text we have, if any.
        if (_text.length && !_calls.count) _rDone = YES;
        else [self fail:@"模型输出未完成（推理占满了输出额度，可调低推理强度）"];
    } else if ([type isEqual:@"response.failed"]) {
        [self fail:Str(j[@"response"][@"error"][@"message"])];
        if (!_failureMessage) [self fail:@"模型请求失败"];
    } else if ([type isEqual:@"error"]) {
        [self fail:Str(j[@"message"])];
        if (!_failureMessage) [self fail:@"模型返回错误"];
    }
}

- (BOOL)append:(NSData *)data {
    if (_rFailed || _rDone) return !_rFailed;
    _bytes += data.length;
    if (_bytes > 4 * 1024 * 1024) { [self fail:@"模型响应超过大小上限"]; return NO; }
    [_buf appendData:data];
    while (!_rFailed && !_rDone) {
        const uint8_t *p = _buf.bytes;
        NSUInteger n = 0;
        while (n < _buf.length && p[n] != '\n') n++;
        if (n == _buf.length) { if (n > 512 * 1024) [self fail:@"模型事件过大"]; break; }
        NSString *line = [[NSString alloc] initWithData:[_buf subdataWithRange:NSMakeRange(0, n)]
                                               encoding:NSUTF8StringEncoding];
        [_buf replaceBytesInRange:NSMakeRange(0, n + 1) withBytes:NULL length:0];
        if (!line) { [self fail:@"模型事件不是 UTF-8"]; break; }
        if ([line hasSuffix:@"\r"]) line = [line substringToIndex:line.length - 1];
        if (!line.length) { [self event]; continue; }
        if ([line hasPrefix:@"data:"]) {
            NSString *v = [line substringFromIndex:5];
            if ([v hasPrefix:@" "]) v = [v substringFromIndex:1];
            [_data addObject:v];
        }
        // "event:" lines are ignored; the type is repeated inside the data.
    }
    return !_rFailed;
}

@end
