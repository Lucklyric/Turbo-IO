#import "TIOTokens.h"

// Candidates this far apart with a similar score are treated as a repeat.
static const NSUInteger kTieDistance = 6;

const NSUInteger TIOMinEvidence = 3;
const NSUInteger TIOQueryTokens = 12;
const NSUInteger TIOLongQueryTokens = 32;
const NSUInteger TIOWindowBack = 8;
const NSUInteger TIOWindowForward = 40;
const NSUInteger TIOLargeStep = 16;
const double TIOMatchThreshold = 0.5;
const double TIOLargeStepThreshold = 0.75;

#pragma mark - Character classes

static NSCharacterSet *AlphaNumeric(void) {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = NSCharacterSet.alphanumericCharacterSet; });
    return set;
}

// Interjections a reader emits. Dropped on both sides, so matching is
// unaffected when the script really contains them; display is never touched.
static BOOL IsFiller(uint32_t c) {
    switch (c) {
        case 0x55EF: case 0x5443: case 0x554A:   // 嗯 呃 啊
        case 0x54E6: case 0x5514: case 0x5450:   // 哦 唔 呐
            return YES;
        default:
            return NO;
    }
}

/// Folded scalars of one grapheme, or an empty array when it carries no
/// letter or digit. NFKC folds full-width forms and composes NFD input.
static NSUInteger FoldGrapheme(NSString *g, uint32_t *out, NSUInteger capacity) {
    NSString *folded = [[g precomposedStringWithCompatibilityMapping] lowercaseString];
    NSData *utf32 = [folded dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const uint32_t *scalars = utf32.bytes;
    NSUInteger count = utf32.length / sizeof(uint32_t), kept = 0;
    for (NSUInteger i = 0; i < count && kept < capacity; i++) {
        uint32_t s = CFSwapInt32LittleToHost(scalars[i]);
        if ([AlphaNumeric() longCharacterIsMember:s] && !IsFiller(s)) out[kept++] = s;
    }
    return kept;
}

NSUInteger TIODisplayUnits(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return 0;
    __block NSUInteger n = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *g, NSRange __unused r, NSRange __unused er, BOOL * __unused stop) {
        uint32_t tmp[4];
        if (FoldGrapheme(g, tmp, 4)) n++;
    }];
    return n;
}

BOOL TIOHasContent(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return NO;
    NSCharacterSet *blank = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    return [text rangeOfCharacterFromSet:blank.invertedSet].location != NSNotFound;
}

#pragma mark - Chinese numerals

static int DigitValue(uint32_t c) {
    switch (c) {
        case 0x96F6: case 0x3007: return 0;      // 零 〇
        case 0x4E00: return 1;                   // 一
        case 0x4E8C: case 0x4E24: return 2;      // 二 两
        case 0x4E09: return 3; case 0x56DB: return 4; case 0x4E94: return 5;
        case 0x516D: return 6; case 0x4E03: return 7; case 0x516B: return 8;
        case 0x4E5D: return 9;
        default: return -1;
    }
}

static unsigned long long UnitValue(uint32_t c) {
    switch (c) {
        case 0x5341: return 10ULL;               // 十
        case 0x767E: return 100ULL;              // 百
        case 0x5343: return 1000ULL;             // 千
        case 0x4E07: return 10000ULL;            // 万
        case 0x4EBF: return 100000000ULL;        // 亿
        default: return 0;
    }
}

static BOOL IsBigUnit(uint32_t c) { return c == 0x4E07 || c == 0x4EBF; }   // 万 亿

/// Value of a segment made of digits and 十百千 only.
static unsigned long long ParsePositional(const TIOToken *t, NSUInteger n) {
    unsigned long long total = 0, number = 0;
    for (NSUInteger i = 0; i < n; i++) {
        int d = DigitValue(t[i].ch);
        if (d >= 0) { number = (unsigned long long)d; continue; }
        unsigned long long u = UnitValue(t[i].ch);
        if (number == 0 && u == 10) number = 1;   // 十五 = 15
        total += number * u;
        number = 0;
    }
    return total + number;
}

/// Emit one segment between big units: digit by digit, positionally, or
/// unchanged when it holds no digit at all.
static void EmitSegment(const TIOToken *t, NSUInteger n, NSMutableData *out) {
    if (!n) return;
    BOOL hasDigit = NO, hasUnit = NO;
    for (NSUInteger k = 0; k < n; k++) {
        if (DigitValue(t[k].ch) >= 0) hasDigit = YES; else hasUnit = YES;
    }
    if (!hasDigit) { [out appendBytes:t length:n * sizeof(TIOToken)]; return; }
    if (!hasUnit) {
        for (NSUInteger k = 0; k < n; k++) {             // 二零二六 → 2026
            TIOToken x = t[k];
            x.ch = '0' + (uint32_t)DigitValue(t[k].ch);
            [out appendBytes:&x length:sizeof x];
        }
        return;
    }
    NSString *digits = [NSString stringWithFormat:@"%llu", ParsePositional(t, n)];
    for (NSUInteger k = 0; k < digits.length; k++) {     // 三十五 → 35
        TIOToken x = t[0];
        x.ch = [digits characterAtIndex:k];
        x.byteEnd = t[n - 1].byteEnd;
        [out appendBytes:&x length:sizeof x];
    }
}

/// Rewrite numeral runs in tokens[from..]. 万 and 亿 stay as written, which is
/// how both scripts and Chinese ASR usually express amounts ("105万").
static void NormaliseNumerals(NSMutableData *data, NSUInteger from) {
    NSUInteger count = data.length / sizeof(TIOToken);
    const TIOToken *in = data.bytes;
    NSMutableData *out = [NSMutableData dataWithCapacity:data.length];
    [out appendBytes:in length:from * sizeof(TIOToken)];

    NSUInteger i = from;
    while (i < count) {
        if (i + 2 < count && in[i].ch == 0x767E && in[i + 1].ch == 0x5206 && in[i + 2].ch == 0x4E4B) {
            i += 3;                                          // 百分之
            continue;
        }
        NSUInteger j = i;
        while (j < count && (DigitValue(in[j].ch) >= 0 || UnitValue(in[j].ch))) j++;
        if (j == i) { [out appendBytes:in + i length:sizeof(TIOToken)]; i++; continue; }

        NSUInteger seg = i;
        for (NSUInteger k = i; k < j; k++) {
            if (!IsBigUnit(in[k].ch)) continue;
            EmitSegment(in + seg, k - seg, out);
            [out appendBytes:in + k length:sizeof(TIOToken)];
            seg = k + 1;
        }
        EmitSegment(in + seg, j - seg, out);
        i = j;
    }
    [data setData:out];
}

#pragma mark - Tokenising

void TIOTokenise(NSString *text, uint32_t page, NSMutableData *out) {
    if (![text isKindOfClass:NSString.class] || !text.length) return;
    NSUInteger from = out.length / sizeof(TIOToken);
    __block NSUInteger byte = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *g, NSRange __unused r, NSRange __unused er, BOOL * __unused stop) {
        NSUInteger width = [g lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        uint32_t scalars[8];
        NSUInteger n = FoldGrapheme(g, scalars, 8);
        for (NSUInteger k = 0; k < n; k++) {
            TIOToken t = {scalars[k], page, byte, byte + width};
            [out appendBytes:&t length:sizeof t];
        }
        byte += width;
    }];
    NormaliseNumerals(out, from);
}

NSData *TIOSpeechTail(NSString *spoken, NSUInteger limit) {
    NSMutableData *out = [NSMutableData data];
    if (![spoken isKindOfClass:NSString.class] || !spoken.length || !limit) return out;
    // Look at a bounded suffix, cut on a grapheme boundary.
    NSUInteger window = limit * 4 + 16;
    NSUInteger start = spoken.length > window ? spoken.length - window : 0;
    if (start) start = [spoken rangeOfComposedCharacterSequenceAtIndex:start].location;
    TIOTokenise([spoken substringFromIndex:start], 0, out);
    NSUInteger count = out.length / sizeof(TIOToken);
    if (count > limit) {
        [out replaceBytesInRange:NSMakeRange(0, (count - limit) * sizeof(TIOToken))
                       withBytes:NULL length:0];
    }
    return out;
}

#pragma mark - Alignment

TIOAlignment TIOAlign(const TIOToken *view, NSUInteger n,
                      const TIOToken *query, NSUInteger m,
                      NSUInteger lo, NSUInteger hi,
                      NSUInteger anchor) {
    TIOAlignment none = {NO, 0, 0, NO};
    if (!view || !query || n == 0 || m == 0) return none;
    if (lo < 1) lo = 1;
    if (hi > n) hi = n;
    if (lo > hi) return none;

    // Enough left context for the span to hold every query token plus slack.
    NSUInteger s0 = lo > 2 * m ? lo - 2 * m : 0;
    NSUInteger cols = hi - s0 + 1;
    NSUInteger *prev = malloc(sizeof(NSUInteger) * cols);
    NSUInteger *cur = malloc(sizeof(NSUInteger) * cols);
    if (!prev || !cur) { free(prev); free(cur); return none; }

    for (NSUInteger j = 0; j < cols; j++) prev[j] = 0;   // free start
    for (NSUInteger i = 1; i <= m; i++) {
        cur[0] = i;
        for (NSUInteger j = 1; j < cols; j++) {
            NSUInteger sub = prev[j - 1] + (query[i - 1].ch == view[s0 + j - 1].ch ? 0 : 1);
            NSUInteger ins = prev[j] + 1;       // spoken token absent from the script
            NSUInteger del = cur[j - 1] + 1;    // script token the reader skipped
            NSUInteger v = sub < ins ? sub : ins;
            cur[j] = del < v ? del : v;
        }
        NSUInteger *swap = prev; prev = cur; cur = swap;
    }

    // prev now holds the last row: distance of the whole query ending at s0+j.
    NSUInteger bestDist = NSUIntegerMax;
    for (NSUInteger e = lo; e <= hi; e++) {
        NSUInteger d = prev[e - s0];
        if (d < bestDist) bestDist = d;
    }
    NSUInteger chosen = 0, behind = 0;
    for (NSUInteger e = lo; e <= hi; e++) {
        if (prev[e - s0] != bestDist) continue;
        if (e >= anchor) { if (!chosen) chosen = e; }
        else behind = e;                        // keeps the nearest one behind
    }
    if (!chosen) chosen = behind;

    // Best competitor that is clearly a different place in the text.
    NSUInteger margin = m >= 8 ? 1 : 0;
    BOOL ambiguous = NO;
    for (NSUInteger e = lo; e <= hi; e++) {
        NSUInteger gap = e > chosen ? e - chosen : chosen - e;
        if (gap >= kTieDistance && prev[e - s0] <= bestDist + margin) { ambiguous = YES; break; }
    }
    free(prev); free(cur);
    return (TIOAlignment){YES, chosen, bestDist, ambiguous};
}

#pragma mark - Policy

TIOPolicyResult TIOAlignSpeech(const TIOToken *view, NSUInteger n,
                               NSString *spoken, NSUInteger anchor) {
    TIOPolicyResult reject = {NO, anchor, 0.0};
    if (!view || n == 0) return reject;
    if (anchor > n) anchor = n;
    NSUInteger lo = anchor > TIOWindowBack ? anchor - TIOWindowBack : 1;
    NSUInteger hi = anchor + TIOWindowForward < n ? anchor + TIOWindowForward : n;

    NSUInteger limits[2] = {TIOQueryTokens, TIOLongQueryTokens};
    for (int attempt = 0; attempt < 2; attempt++) {
        NSData *tail = TIOSpeechTail(spoken, limits[attempt]);
        NSUInteger m = tail.length / sizeof(TIOToken);
        if (m < TIOMinEvidence) return reject;
        if (attempt == 1 && m <= TIOQueryTokens) return reject;   // nothing more to learn

        TIOAlignment a = TIOAlign(view, n, tail.bytes, m, lo, hi, anchor);
        if (!a.found) return reject;
        double score = 1.0 - (double)a.distance / (double)m;
        if (score < TIOMatchThreshold) return reject;
        if (a.ambiguous) continue;                 // retry once with more context

        NSUInteger step = a.end > anchor ? a.end - anchor : 0;
        if (step > TIOLargeStep && (m < 2 * TIOMinEvidence || score < TIOLargeStepThreshold))
            return reject;
        return (TIOPolicyResult){YES, a.end, score};
    }
    return reject;
}
