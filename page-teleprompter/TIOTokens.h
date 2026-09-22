// Shared text model for pagination and speech alignment.
//
// Text is tokenised per grapheme (composed character sequence), folded with
// NFKC and lower case, and kept only when it is a letter or digit in any
// script. Each token remembers the UTF-8 byte range of the grapheme it came
// from, so an alignment result maps back to an offset in the original string.
// Pure Foundation, host-testable.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    uint32_t ch;             // folded Unicode scalar
    uint32_t page;           // caller-supplied tag, used by the follow session
    NSUInteger byteStart;    // UTF-8 byte range of the source grapheme
    NSUInteger byteEnd;
} TIOToken;

/// Append the matching tokens of `text` to `out` (an array of TIOToken).
/// Chinese numerals are rewritten to digits and 百分之 is dropped, identically
/// for script and speech, so "2026" matches "二零二六" and "35%" matches
/// "百分之三十五".
FOUNDATION_EXPORT void TIOTokenise(NSString *text, uint32_t page, NSMutableData *out);

/// Tokens of the last part of `spoken`, at most `limit` tokens. Only a bounded
/// tail of the string is examined, so cost does not grow with a long session.
FOUNDATION_EXPORT NSData *TIOSpeechTail(NSString *spoken, NSUInteger limit);

/// Number of graphemes in `text` that are letters or digits. Used as the page
/// budget unit. Punctuation, spaces and emoji are displayed but not counted.
FOUNDATION_EXPORT NSUInteger TIODisplayUnits(NSString *text);

/// YES when `text` has anything other than white space and line breaks.
FOUNDATION_EXPORT BOOL TIOHasContent(NSString *text);

typedef struct {
    BOOL found;
    NSUInteger end;          // candidate end, as an index one past the last token
    NSUInteger distance;     // edits between the whole query and the matched span
    BOOL ambiguous;          // a distant candidate scored about as well
} TIOAlignment;

/// Semi-global alignment: the whole query must be consumed, the page span may
/// start anywhere and have any length. Only ends in [lo, hi] are considered.
/// Among equally good ends the one at or after `anchor` nearest to it wins,
/// otherwise the nearest one before it.
FOUNDATION_EXPORT TIOAlignment TIOAlign(const TIOToken *view, NSUInteger viewCount,
                                        const TIOToken *query, NSUInteger queryCount,
                                        NSUInteger lo, NSUInteger hi,
                                        NSUInteger anchor);

/// Matching policy shared by the stateless matcher and the follow session.
/// Starting values; tune them on recorded ASR traces.
FOUNDATION_EXPORT const NSUInteger TIOMinEvidence;     // tokens needed to move at all
FOUNDATION_EXPORT const NSUInteger TIOQueryTokens;     // normal query length
FOUNDATION_EXPORT const NSUInteger TIOLongQueryTokens;  // retry length on ambiguity
FOUNDATION_EXPORT const NSUInteger TIOWindowBack;
FOUNDATION_EXPORT const NSUInteger TIOWindowForward;
FOUNDATION_EXPORT const NSUInteger TIOLargeStep;       // tokens; bigger jumps need more proof
FOUNDATION_EXPORT const double TIOMatchThreshold;
FOUNDATION_EXPORT const double TIOLargeStepThreshold;

typedef struct {
    BOOL accepted;
    NSUInteger end;          // index into the view, one past the last token
    double score;
} TIOPolicyResult;

/// Align the tail of `spoken` against `view` around `anchor` and apply the
/// evidence, threshold, ambiguity and large-step rules. Direction is left to
/// the caller, which knows what the committed cursor is.
FOUNDATION_EXPORT TIOPolicyResult TIOAlignSpeech(const TIOToken *view, NSUInteger viewCount,
                                                 NSString *spoken, NSUInteger anchor);

NS_ASSUME_NONNULL_END
