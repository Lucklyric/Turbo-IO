// Live teleprompter follow controller.
//
// Wraps the stateless matcher with the state a real session needs: the current
// page, a committed cursor that only moves forward, crossover into the next
// page's opening when the reader reaches the end, and generation ids so a late
// ASR result for an old page is ignored. It decides what to SEND, not how to
// send it; BLE transport and ack serialisation live above this.
//
// Pure Foundation, host-testable. Not thread-safe: drive it from one queue.

#import <Foundation/Foundation.h>
#import "PageTeleprompter.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TIOFollowKind) {
    TIOFollowNone,      // nothing to send this update
    TIOFollowHighlight, // move the cursor within the current page
    TIOFollowAdvance,   // the reader has moved into the next page
};

typedef struct {
    TIOFollowKind kind;
    NSUInteger pageIndex;    // page the command refers to
    NSUInteger byteOffset;   // highlight within that page, in UTF-8 bytes
    double confidence;
} TIOFollowCommand;

@interface TIOFollowSession : NSObject

- (instancetype)initWithPages:(NSArray<NSString *> *)pages NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) NSUInteger pageIndex;
@property(nonatomic, readonly) NSUInteger pageCount;
@property(nonatomic, readonly) NSUInteger cursorByteOffset;

/// Feed the latest recognised text (partial or final) for the CURRENT page's
/// utterance. Returns what to send; TIOFollowNone means hold. When the reader
/// crosses into the next page the result is TIOFollowAdvance with that page's
/// index and offset, and the session's own page advances so later updates are
/// matched there.
- (TIOFollowCommand)observe:(nullable NSString *)spoken;

/// Move to a page explicitly (a manual turn, or confirming an advance). Clears
/// the cursor and bumps the generation so in-flight results for the old page
/// are dropped. Out-of-range indices are ignored.
- (void)goToPage:(NSUInteger)pageIndex;

/// Replace the manuscript (an edit landed). Resets to the first page.
- (void)setPages:(NSArray<NSString *> *)pages;

@end

NS_ASSUME_NONNULL_END
