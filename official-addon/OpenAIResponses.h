// OpenAI Responses API adapter for the Turbo IO addon.
//
// Upstream speaks Chat Completions. For api.openai.com this adapter translates
// the app's chat-format request into a Responses request at the wire boundary
// and parses Responses streaming events back into the answer + tool-call shape
// the app already handles. The app's tool rules (one write per turn, no write
// after search, knowledge not mixed with public search) stay in upstream code.
//
// Only OpenAI's own services are used: TinyFish web_search is never sent;
// OpenAI's built-in {"type":"web_search"} tool is attached instead.

#import <Foundation/Foundation.h>
#import "WebSearch.h"

NS_ASSUME_NONNULL_BEGIN

/// YES for api.openai.com endpoints; those always go through /v1/responses.
FOUNDATION_EXPORT BOOL TIOIsOpenAI(NSURL * _Nullable endpoint);
/// https://api.openai.com/v1/responses for an OpenAI endpoint, else the input.
FOUNDATION_EXPORT NSURL *TIOResponsesURL(NSURL *endpoint);
/// Reasoning effort from the addon preferences: nil when set to "off".
FOUNDATION_EXPORT NSString * _Nullable TIOOpenAIEffort(void);
/// Translate a Chat Completions body into a Responses body. `hostedSearch`
/// attaches OpenAI's built-in web_search unless a knowledge tool is present
/// (upstream forbids mixing private knowledge with public search).
FOUNDATION_EXPORT NSDictionary *TIOResponsesBody(NSDictionary *chat, BOOL hostedSearch);
/// Text of a non-streaming Responses reply, nil unless completed with text only.
FOUNDATION_EXPORT NSString * _Nullable TIOResponsesText(id _Nullable json);

/// Streaming parser with the same interface as TIOWebStream.
@interface TIOResponsesStream : TIOWebStream
/// Built-in web searches the model ran during this response.
@property(nonatomic, readonly) NSUInteger hostedSearches;
/// Provider message when the stream failed, for display.
@property(nonatomic, readonly, nullable) NSString *failureMessage;
@end

NS_ASSUME_NONNULL_END
