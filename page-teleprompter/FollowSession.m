#import "FollowSession.h"
#import "TIOTokens.h"

// When the cursor is within this many tokens of the page end, also match
// against the next page's opening so a crossover is detected.
static const NSUInteger kCrossoverZone = 12;
// The reader must land at least this far into the next page to advance, so a
// stray tail word does not flip the page.
static const NSUInteger kAdvanceMinTokens = 3;

@implementation TIOFollowSession {
    NSArray<NSString *> *_pages;
    NSMutableData *_tokens;      // tokens of the current page, page tag = 0
    NSUInteger _cursor;          // committed byte offset in the current page
    NSUInteger _generation;
}

- (instancetype)initWithPages:(NSArray<NSString *> *)pages {
    if ((self = [super init])) [self setPages:pages];
    return self;
}

- (void)setPages:(NSArray<NSString *> *)pages {
    NSMutableArray *clean = [NSMutableArray array];
    for (id p in pages) if ([p isKindOfClass:NSString.class]) [clean addObject:p];
    _pages = [clean copy];
    _pageIndex = 0;
    _cursor = 0;
    _generation++;
    [self loadCurrentPage];
}

- (void)loadCurrentPage {
    _tokens = [NSMutableData data];
    if (_pageIndex < _pages.count) TIOTokenise(_pages[_pageIndex], 0, _tokens);
}

- (NSUInteger)pageCount { return _pages.count; }
- (NSUInteger)cursorByteOffset { return _cursor; }

- (void)goToPage:(NSUInteger)pageIndex {
    if (pageIndex >= _pages.count) return;
    _pageIndex = pageIndex;
    _cursor = 0;
    _generation++;
    [self loadCurrentPage];
}

/// Anchor token index for a byte cursor: tokens ending at or before it.
static NSUInteger AnchorFor(const TIOToken *view, NSUInteger n, NSUInteger cursor) {
    NSUInteger a = 0;
    while (a < n && view[a].byteEnd <= cursor) a++;
    return a;
}

- (TIOFollowCommand)observe:(NSString *)spoken {
    TIOFollowCommand none = {TIOFollowNone, _pageIndex, _cursor, 0.0};
    if (_pageIndex >= _pages.count) return none;
    if (![spoken isKindOfClass:NSString.class] || !spoken.length) return none;

    const TIOToken *view = _tokens.bytes;
    NSUInteger n = _tokens.length / sizeof(TIOToken);
    if (!n) return none;

    NSUInteger anchor = AnchorFor(view, n, _cursor);

    // Crossover: near the end, try the current page's tail joined with the next
    // page's opening, as one view. A match landing in the next-page part is an
    // advance.
    BOOL nearEnd = anchor + kCrossoverZone >= n;
    if (nearEnd && _pageIndex + 1 < _pages.count) {
        NSMutableData *joined = [_tokens mutableCopy];
        NSUInteger before = joined.length / sizeof(TIOToken);
        NSMutableData *nextTokens = [NSMutableData data];
        TIOTokenise(_pages[_pageIndex + 1], 1, nextTokens);   // page tag 1 = next
        [joined appendData:nextTokens];

        const TIOToken *jv = joined.bytes;
        NSUInteger jn = joined.length / sizeof(TIOToken);
        TIOPolicyResult r = TIOAlignSpeech(jv, jn, spoken, anchor);
        if (r.accepted && r.end > 0 && jv[r.end - 1].page == 1) {
            NSUInteger into = r.end - before;    // tokens consumed on the next page
            if (into >= kAdvanceMinTokens) {
                _pageIndex++;
                _cursor = jv[r.end - 1].byteEnd;
                _generation++;
                [self loadCurrentPage];
                return (TIOFollowCommand){TIOFollowAdvance, _pageIndex, _cursor, r.score};
            }
        }
    }

    // Ordinary in-page move.
    TIOPolicyResult r = TIOAlignSpeech(view, n, spoken, anchor);
    if (!r.accepted || r.end == 0) return none;
    NSUInteger offset = view[r.end - 1].byteEnd;
    if (offset <= _cursor) return none;          // forward only, and no-op suppressed
    _cursor = offset;
    return (TIOFollowCommand){TIOFollowHighlight, _pageIndex, _cursor, r.score};
}

@end
