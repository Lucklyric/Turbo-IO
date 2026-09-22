#import "PageTeleprompter.h"
#import "TIOTokens.h"

const double TIOPageMatchThreshold = 0.5;
NSString *const TIOPageBreakMarker = @"---";

#pragma mark - Pagination

static BOOL IsSentenceEnd(unichar c) {
    switch (c) {
        case 0x3002: case 0xFF01: case 0xFF1F: case 0xFF1B: case 0x2026:   // 。！？；…
        case '.': case '!': case '?': case ';': case '\n':
            return YES;
        default:
            return NO;
    }
}

static BOOL IsTrailingBlank(unichar c) {
    return c == ' ' || c == '\t' || c == 0x3000;
}

/// Cut on author-written breaks. Works on LF-normalised text; a marker line
/// may carry surrounding spaces. Every other line is kept, blank ones included.
static NSArray<NSString *> *SplitOnMarkers(NSString *text) {
    NSMutableArray<NSString *> *sections = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    BOOL sectionHasLine = NO;
    for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
        NSArray<NSString *> *pieces = [rawLine componentsSeparatedByString:@"\f"];
        for (NSUInteger p = 0; p < pieces.count; p++) {
            if (p > 0) {
                [sections addObject:[current copy]];
                current = [NSMutableString string];
                sectionHasLine = NO;
            }
            NSString *line = pieces[p];
            NSString *trimmed = [line stringByTrimmingCharactersInSet:
                                 NSCharacterSet.whitespaceCharacterSet];
            if ([trimmed isEqual:TIOPageBreakMarker]) {
                [sections addObject:[current copy]];
                current = [NSMutableString string];
                sectionHasLine = NO;
                continue;
            }
            if (sectionHasLine) [current appendString:@"\n"];
            [current appendString:line];
            sectionHasLine = YES;
        }
    }
    [sections addObject:[current copy]];
    return sections;
}

/// Sentence-sized units. Enders and the blanks after them stay with the unit.
static NSArray<NSString *> *SentenceUnits(NSString *text) {
    NSMutableArray<NSString *> *units = [NSMutableArray array];
    NSUInteger start = 0, i = 0, length = text.length;
    while (i < length) {
        if (!IsSentenceEnd([text characterAtIndex:i])) { i++; continue; }
        NSUInteger end = i + 1;
        while (end < length) {
            unichar c = [text characterAtIndex:end];
            if (IsSentenceEnd(c) || IsTrailingBlank(c)) end++;
            else break;
        }
        [units addObject:[text substringWithRange:NSMakeRange(start, end - start)]];
        start = i = end;
    }
    if (start < length) [units addObject:[text substringFromIndex:start]];
    return units;
}

/// Fill one marker-delimited section to the budget.
static NSArray<NSString *> *PaginateSection(NSString *text, NSUInteger budget) {
    NSMutableArray<NSString *> *pages = [NSMutableArray array];
    NSMutableString *page = [NSMutableString string];
    __block NSUInteger used = 0;

    for (NSString *unit in SentenceUnits(text)) {
        NSUInteger size = TIODisplayUnits(unit);

        if (size <= budget) {
            if (used && used + size > budget) {
                [pages addObject:[page copy]];
                page = [NSMutableString string];
                used = 0;
            }
            [page appendString:unit];
            used += size;
            continue;
        }

        // Oversized sentence: flush a page that already holds text, otherwise
        // carry its leading punctuation into the first chunk.
        if (used) {
            [pages addObject:[page copy]];
            page = [NSMutableString string];
            used = 0;
        }
        __block NSMutableString *chunk = page;
        [unit enumerateSubstringsInRange:NSMakeRange(0, unit.length)
                                 options:NSStringEnumerationByComposedCharacterSequences
                              usingBlock:^(NSString *g, NSRange __unused r, NSRange __unused er, BOOL * __unused stop) {
            BOOL counts = TIODisplayUnits(g) > 0;
            // Flush lazily, so punctuation after the last unit stays with it.
            if (counts && used == budget) {
                [pages addObject:[chunk copy]];
                chunk = [NSMutableString string];
                used = 0;
            }
            [chunk appendString:g];
            if (counts) used++;
        }];
        page = chunk;
    }
    if (page.length) [pages addObject:[page copy]];
    return pages;
}

NSArray<NSString *> *TIOPagePaginate(NSString *text, NSUInteger budget) {
    if (![text isKindOfClass:NSString.class] || !text.length) return @[];
    NSString *lf = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                    stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];

    NSArray<NSString *> *sections = SplitOnMarkers(lf);
    if (sections.count == 1 && budget == 0) return @[];

    NSMutableArray<NSString *> *pages = [NSMutableArray array];
    for (NSString *section in sections) {
        if (!TIOHasContent(section)) continue;   // blank run between markers
        if (budget == 0) { [pages addObject:section]; continue; }
        [pages addObjectsFromArray:PaginateSection(section, budget)];
    }
    return pages;
}

NSArray<NSNumber *> *TIOPageByteOffsets(NSArray<NSString *> *pages) {
    if (![pages isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:pages.count];
    NSUInteger offset = 0;
    for (NSString *page in pages) {
        if (![page isKindOfClass:NSString.class]) return @[];
        [out addObject:@(offset)];
        offset += [page lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    }
    return out;
}

#pragma mark - Matching

TIOPageMatch TIOPageMatchInPage(NSString *page, NSString *spoken, NSUInteger previous) {
    NSUInteger total = [page isKindOfClass:NSString.class]
        ? [page lengthOfBytesUsingEncoding:NSUTF8StringEncoding] : 0;
    TIOPageMatch hold = {previous < total ? previous : total, 0.0, NO};
    if (!total || ![spoken isKindOfClass:NSString.class] || !spoken.length) return hold;

    NSMutableData *tokens = [NSMutableData data];
    TIOTokenise(page, 0, tokens);
    const TIOToken *view = tokens.bytes;
    NSUInteger n = tokens.length / sizeof(TIOToken);
    if (!n) return hold;

    // Anchor = tokens already read, i.e. those ending at or before the cursor.
    NSUInteger anchor = 0;
    while (anchor < n && view[anchor].byteEnd <= previous) anchor++;

    TIOPolicyResult r = TIOAlignSpeech(view, n, spoken, anchor);
    if (!r.accepted || r.end == 0) return hold;
    NSUInteger offset = view[r.end - 1].byteEnd;
    if (offset < previous) return hold;          // never move backwards
    return (TIOPageMatch){offset, r.score, YES};
}
