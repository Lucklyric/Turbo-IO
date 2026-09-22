// Page-wise teleprompter core: pagination and in-page speech alignment.
// Pure Foundation. No UIKit, no BLE, no I/O, so it builds and tests on the host.
//
// Offsets are UTF-8 byte offsets because the glasses protocol addresses text
// that way (type 8 carries pageOffset and highLightOffset in bytes). Offsets
// always refer to the page strings returned here, never to the imported file:
// markers are removed and line endings are normalised to LF. Input must be
// valid UTF-16 (no lone surrogates); TIOManuscriptStore guarantees that.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A line whose only content is `---` starts a new page, as does a form feed.
/// Markers win over the budget, so a deliberately short page stays short.
FOUNDATION_EXPORT NSString *const TIOPageBreakMarker;

/// Split a manuscript into pages.
///
/// CRLF and CR become LF. Explicit markers are honoured first; each section is
/// then filled to at most `budget` display units (letters and digits of any
/// script, counted per grapheme), breaking after sentence enders and hard
/// cutting on grapheme boundaries when one sentence exceeds a page.
/// Punctuation stays attached to the text it follows. No visible character is
/// ever dropped: joining the pages gives back the normalised text minus the
/// marker lines.
///
/// Returns an empty array for empty input. `budget` 0 pages purely by marker.
FOUNDATION_EXPORT NSArray<NSString *> *TIOPagePaginate(NSString * _Nullable text, NSUInteger budget);

/// UTF-8 byte offset of each page's start within the joined page text.
FOUNDATION_EXPORT NSArray<NSNumber *> *TIOPageByteOffsets(NSArray<NSString *> * _Nullable pages);

typedef struct {
    /// Highlight position within the page, in UTF-8 bytes: the end of the last
    /// grapheme the reader has reached. On a miss, the previous offset clamped
    /// to the page length.
    NSUInteger byteOffset;
    /// 1 - edits / query length. Not a probability.
    double confidence;
    /// NO on too little evidence, a poor score, an ambiguous repeat, or any
    /// result that would move the cursor backwards. Callers hold position.
    BOOL matched;
} TIOPageMatch;

FOUNDATION_EXPORT const double TIOPageMatchThreshold;

/// Stateless single-page alignment. It is safe to call on every ASR partial,
/// but a TIOFollowSession is what a live teleprompter should use: it adds
/// page-end crossover, stale-result rejection and change-only output.
FOUNDATION_EXPORT TIOPageMatch TIOPageMatchInPage(NSString * _Nullable page,
                                                  NSString * _Nullable spoken,
                                                  NSUInteger previousByteOffset);

NS_ASSUME_NONNULL_END
