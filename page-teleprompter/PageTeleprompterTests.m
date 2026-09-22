#import "PageTeleprompter.h"
#import <assert.h>

static BOOL Pages(NSArray *got, NSArray *want) {
    if (![got isEqual:want]) { NSLog(@"  got  %@\n  want %@", got, want); return NO; }
    return YES;
}

static NSUInteger Bytes(NSString *s) {
    return [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
}

static void TestPaginationRespectsSentences(void) {
    NSString *text = @"今天天气很好。我们去公园散步。然后回家吃饭。";
    NSArray *pages = TIOPagePaginate(text, 8);
    assert(pages.count == 3);
    assert([pages[0] isEqual:@"今天天气很好。"]);
    assert([pages[1] isEqual:@"我们去公园散步。"]);
    assert([pages[2] isEqual:@"然后回家吃饭。"]);
    // Pages rejoin into the original manuscript, so offsets stay meaningful.
    assert([[pages componentsJoinedByString:@""] isEqual:text]);
    NSLog(@"PASS: pagination breaks on sentence enders and loses nothing");
}

static void TestPaginationPacksToBudget(void) {
    NSString *text = @"一二三。四五六。七八九。";
    NSArray *pages = TIOPagePaginate(text, 6);
    assert(pages.count == 2);
    assert([pages[0] isEqual:@"一二三。四五六。"]);
    assert([pages[1] isEqual:@"七八九。"]);
    NSLog(@"PASS: pagination fills a page before opening the next");
}

static void TestPaginationHardCutsLongSentence(void) {
    NSString *text = @"这是一个非常长的句子没有任何标点一直写下去";
    NSArray *pages = TIOPagePaginate(text, 5);
    assert(pages.count == 5);
    assert([pages[0] isEqual:@"这是一个非"]);
    assert([[pages componentsJoinedByString:@""] isEqual:text]);
    NSLog(@"PASS: a sentence longer than one page is hard-cut, not dropped");
}

static void TestPaginationEdgeCases(void) {
    assert(TIOPagePaginate(nil, 10).count == 0);
    assert(TIOPagePaginate(@"", 10).count == 0);
    assert(TIOPagePaginate(@"文字", 0).count == 0);
    NSLog(@"PASS: pagination rejects empty text and a zero budget");
}

static void TestExplicitMarkerForcesPageBreak(void) {
    NSString *text = @"开场白很短。\n---\n第二页从这里开始。";
    NSArray *pages = TIOPagePaginate(text, 100);
    assert(pages.count == 2);
    // The marker wins over the budget: page one stays short on purpose.
    assert([pages[0] containsString:@"开场白很短"]);
    assert([pages[1] containsString:@"第二页从这里开始"]);
    // The marker itself never reaches the glasses.
    assert(![pages[0] containsString:@"---"]);
    assert(![pages[1] containsString:@"---"]);
    NSLog(@"PASS: an explicit marker overrides the budget and is stripped");
}

static void TestMarkerSectionStillRespectsBudget(void) {
    // A marked section longer than a page is still filled to the budget.
    NSString *text = @"一二三。四五六。\n---\n七八九。十九八。七六五。";
    NSArray *pages = TIOPagePaginate(text, 6);
    assert(pages.count == 3);
    assert([pages[0] containsString:@"一二三"]);
    assert([pages[1] containsString:@"七八九"]);
    assert([pages[2] containsString:@"七六五"]);
    NSLog(@"PASS: a marked section is sub-paginated when it exceeds the budget");
}

static void TestFormFeedIsAlsoAMarker(void) {
    NSArray *pages = TIOPagePaginate(@"前一页。\f后一页。", 100);
    assert(pages.count == 2);
    NSLog(@"PASS: a form feed breaks the page as well");
}

static void TestMarkerOnlyPaginationIgnoresBudget(void) {
    // budget 0 means page strictly by marker, however long a page becomes.
    NSString *text = @"很长的一页内容写在这里不会被切开。\n---\n第二页。";
    NSArray *pages = TIOPagePaginate(text, 0);
    assert(pages.count == 2);
    assert([pages[0] containsString:@"不会被切开"]);
    NSLog(@"PASS: budget 0 pages purely by marker");
}

static void TestConsecutiveMarkersDoNotMakeBlankPages(void) {
    NSArray *pages = TIOPagePaginate(@"第一页。\n---\n\n---\n第二页。", 100);
    assert(pages.count == 2);
    NSLog(@"PASS: an empty run between markers does not become a page");
}

static void TestThreeDashesInsideALineIsNotAMarker(void) {
    // Only a line that is nothing but the marker counts.
    NSArray *pages = TIOPagePaginate(@"这是 --- 行内的破折号，不分页。", 100);
    assert(pages.count == 1);
    NSLog(@"PASS: the marker must own its line");
}

static void TestByteOffsetsAreCumulative(void) {
    NSArray *pages = @[@"你好", @"world", @"再见"];
    NSArray *offsets = TIOPageByteOffsets(pages);
    assert(offsets.count == 3);
    assert([offsets[0] unsignedIntegerValue] == 0);
    assert([offsets[1] unsignedIntegerValue] == 6);          // 2 CJK chars
    assert([offsets[2] unsignedIntegerValue] == 6 + 5);      // plus ASCII
    NSLog(@"PASS: page offsets accumulate UTF-8 bytes, not characters");
}

static void TestMatchFindsReadingPosition(void) {
    NSString *page = @"第一段落的开头。接下来是中间的内容。最后是结尾部分。";
    TIOPageMatch m = TIOPageMatchInPage(page, @"第一段落的开头", 0);
    assert(m.matched);
    // The highlight sits after what has been read, not at the page start.
    assert(m.byteOffset > 0);
    assert(m.byteOffset <= Bytes(page));
    NSLog(@"PASS: match returns a position past the spoken text");
}

static void TestMatchAdvancesAsSpeechContinues(void) {
    NSString *page = @"第一段落的开头。接下来是中间的内容。最后是结尾部分。";
    TIOPageMatch early = TIOPageMatchInPage(page, @"第一段落的开头", 0);
    assert(early.matched);
    TIOPageMatch later = TIOPageMatchInPage(page, @"接下来是中间的内容", early.byteOffset);
    assert(later.matched);
    assert(later.byteOffset > early.byteOffset);
    NSLog(@"PASS: the highlight moves forward as more is read");
}

static void TestMatchToleratesRecognitionErrors(void) {
    NSString *page = @"我们需要确认这个方案的可行性。";
    // Homophone-style substitutions, the usual failure of Chinese recognition.
    TIOPageMatch m = TIOPageMatchInPage(page, @"我门需要确认这个方安", 0);
    assert(m.matched);
    assert(m.confidence >= TIOPageMatchThreshold);
    NSLog(@"PASS: substitutions still align, confidence %.2f", m.confidence);
}

static void TestMatchRejectsUnrelatedSpeech(void) {
    NSString *page = @"我们需要确认这个方案的可行性。";
    TIOPageMatch m = TIOPageMatchInPage(page, @"完全无关的随便一句闲话", 0);
    assert(!m.matched);
    NSLog(@"PASS: unrelated speech does not move the highlight");
}

static void TestMatchHoldsOnRepeatedPassage(void) {
    // The same clause twice: a confident jump would be a coin flip.
    NSString *page = @"请注意安全。中间隔开一些别的内容在这里。请注意安全。";
    TIOPageMatch m = TIOPageMatchInPage(page, @"请注意安全", 0);
    assert(!m.matched);
    assert(m.byteOffset == 0);   // position held
    NSLog(@"PASS: an ambiguous repeat holds instead of jumping");
}

static void TestMatchIgnoresFillers(void) {
    NSString *page = @"这个方案我们下周再讨论。";
    TIOPageMatch plain = TIOPageMatchInPage(page, @"这个方案我们下周", 0);
    TIOPageMatch filled = TIOPageMatchInPage(page, @"嗯这个方案啊我们下周", 0);
    assert(plain.matched && filled.matched);
    assert(plain.byteOffset == filled.byteOffset);
    NSLog(@"PASS: spoken fillers do not shift the match");
}

static void TestMatchIgnoresPunctuationAndCase(void) {
    NSString *page = @"Please Review The Draft, then send it back.";
    TIOPageMatch m = TIOPageMatchInPage(page, @"please review the draft", 0);
    assert(m.matched);
    NSLog(@"PASS: case and punctuation are normalised away");
}

static void TestMatchEdgeCases(void) {
    assert(!TIOPageMatchInPage(nil, @"文字", 0).matched);
    assert(!TIOPageMatchInPage(@"文字", nil, 0).matched);
    assert(!TIOPageMatchInPage(@"", @"文字", 0).matched);
    assert(!TIOPageMatchInPage(@"，。！", @"文字", 0).matched);
    // An offset past the end must not read out of bounds.
    TIOPageMatch m = TIOPageMatchInPage(@"一些内容在这里", @"一些内容", 9999);
    (void)m;
    NSLog(@"PASS: empty, punctuation-only and out-of-range input stay safe");
}


#pragma mark - Regressions from the 2026-09-22 review

static void TestNonCJKScriptsAreKept(void) {
    assert(Pages(TIOPagePaginate(@"こんにちは", 2), (@[@"こん", @"にち", @"は"])));
    assert(Pages(TIOPagePaginate(@"\U00020000\U00020001", 1), (@[@"\U00020000", @"\U00020001"])));
    assert(Pages(TIOPagePaginate(@"안녕하세요", 5), (@[@"안녕하세요"])));
    NSLog(@"PASS: kana, CJK extension B and Hangul are paginated, not dropped");
}

static void TestLeadingPunctuationKeepsItsPlace(void) {
    assert(Pages(TIOPagePaginate(@".abcde", 2), (@[@".ab", @"cd", @"e"])));
    assert(Pages(TIOPagePaginate(@".abcdef", 2), (@[@".ab", @"cd", @"ef"])));
    NSLog(@"PASS: a leading period is neither lost nor moved to the end");
}

static void TestTrailingPunctuationStaysWithItsText(void) {
    assert(Pages(TIOPagePaginate(@"abcdef。next", 2), (@[@"ab", @"cd", @"ef。", @"ne", @"xt"])));
    NSLog(@"PASS: punctuation after a hard cut stays on the page it ends");
}

static void TestCRLFMarkers(void) {
    assert(Pages(TIOPagePaginate(@"abc\r\n---\r\ndef", 100), (@[@"abc", @"def"])));
    assert(Pages(TIOPagePaginate(@"abc\r---\rdef", 100), (@[@"abc", @"def"])));
    NSLog(@"PASS: CRLF and CR line endings still honour page markers");
}

static void TestLeadingBlankLineKept(void) {
    assert(Pages(TIOPagePaginate(@"\nabc", 100), (@[@"\nabc"])));
    NSLog(@"PASS: a leading blank line survives");
}

static void TestHardCutRespectsGraphemes(void) {
    assert(Pages(TIOPagePaginate(@"éabc", 1), (@[@"é", @"a", @"b", @"c"])));
    assert(Pages(TIOPagePaginate(@"一︀二三", 1), (@[@"一︀", @"二", @"三"])));
    NSLog(@"PASS: combining marks and variation selectors stay on their base");
}

static void TestEmojiOnlySectionKept(void) {
    assert(Pages(TIOPagePaginate(@"😀\n---\nabc", 100), (@[@"😀", @"abc"])));
    NSLog(@"PASS: a section with only emoji is still a page");
}

static void TestUnmarkedTextRejoinsExactly(void) {
    NSString *text = @"第一句话。Second sentence! 第三句？\n\n最后一段……结束。";
    for (NSUInteger budget = 1; budget <= 12; budget++)
        assert([[TIOPagePaginate(text, budget) componentsJoinedByString:@""] isEqual:text]);
    NSLog(@"PASS: unmarked LF text rejoins byte for byte at every budget");
}

static void TestOneCharacterPartialDoesNotJump(void) {
    TIOPageMatch m = TIOPageMatchInPage(@"今天我们讨论新方案", @"新", 0);
    assert(!m.matched && m.byteOffset == 0);
    NSLog(@"PASS: a one-character partial does not move the cursor");
}

static void TestNeverMovesBackward(void) {
    // Two copies: the one at the cursor wins, the earlier one is not taken.
    TIOPageMatch same = TIOPageMatchInPage(@"abcabc", @"abc", 6);
    assert(same.byteOffset == 6);
    // Only copy is behind the cursor: hold, report no match.
    TIOPageMatch behind = TIOPageMatchInPage(@"abcxyz", @"abc", 6);
    assert(!behind.matched && behind.byteOffset == 6);
    NSLog(@"PASS: the cursor never rewinds, even when the text matches behind it");
}

static void TestHoldOffsetIsClamped(void) {
    TIOPageMatch m = TIOPageMatchInPage(@"abc", @"zzz", 9999);
    assert(!m.matched && m.byteOffset == 3);
    NSLog(@"PASS: an out-of-range cursor is clamped to the page on a miss");
}

static void TestExactOffsetAfterInsertion(void) {
    // Reader adds a word the script does not have; cursor must land after 方案.
    NSString *page = @"我们需要确认这个方案的可行性。";
    TIOPageMatch m = TIOPageMatchInPage(page, @"我们需要确认一下这个方案", 0);
    NSUInteger want = [@"我们需要确认这个方案" lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    assert(m.matched && m.byteOffset == want);
    NSLog(@"PASS: an inserted spoken word does not shift the cursor");
}

static void TestExactOffsetAfterDeletion(void) {
    // Reader skips a script word; cursor still lands after 可行性.
    NSString *page = @"我们需要确认这个方案的可行性。";
    TIOPageMatch m = TIOPageMatchInPage(page, @"需要确认这个方案可行性", 0);
    NSUInteger want = [@"我们需要确认这个方案的可行性" lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    assert(m.matched && m.byteOffset == want);
    NSLog(@"PASS: a skipped script word does not shift the cursor");
}

static void TestFullWidthMatchesHalfWidth(void) {
    TIOPageMatch m = TIOPageMatchInPage(@"型号ＡＢＣ１２３已上市", @"型号abc123", 0);
    assert(m.matched && m.confidence == 1.0);
    NSLog(@"PASS: full-width letters and digits match their ASCII forms");
}

static void TestNFDMatchesNFC(void) {
    TIOPageMatch m = TIOPageMatchInPage(@"un café noir", @"un café noir", 0);
    assert(m.matched && m.confidence == 1.0);
    NSLog(@"PASS: decomposed and precomposed accents are the same text");
}

static void TestChineseNumeralsMatchDigits(void) {
    TIOPageMatch a = TIOPageMatchInPage(@"在2026年第三季度完成部署。", @"在二零二六年第三季度", 0);
    TIOPageMatch b = TIOPageMatchInPage(@"增长了35%的用户。", @"增长了百分之三十五的用户", 0);
    TIOPageMatch c = TIOPageMatchInPage(@"预算一百零五万元。", @"预算105万元", 0);
    assert(a.matched && a.confidence == 1.0);
    assert(b.matched && b.confidence == 1.0);
    assert(c.matched && c.confidence == 1.0);
    NSLog(@"PASS: digits, positional numerals and 百分之 align exactly");
}

static void TestUnitOnlyWordsStayWords(void) {
    // 百姓 and 千万 are words, not numbers; both sides keep them as text.
    TIOPageMatch m = TIOPageMatchInPage(@"老百姓千万不要忘记。", @"老百姓千万不要", 0);
    assert(m.matched && m.confidence == 1.0);
    NSLog(@"PASS: unit characters on their own are left as words");
}

int main(void) {
    @autoreleasepool {
        TestPaginationRespectsSentences();
        TestPaginationPacksToBudget();
        TestPaginationHardCutsLongSentence();
        TestPaginationEdgeCases();
        TestExplicitMarkerForcesPageBreak();
        TestMarkerSectionStillRespectsBudget();
        TestFormFeedIsAlsoAMarker();
        TestMarkerOnlyPaginationIgnoresBudget();
        TestConsecutiveMarkersDoNotMakeBlankPages();
        TestThreeDashesInsideALineIsNotAMarker();
        TestByteOffsetsAreCumulative();
        TestMatchFindsReadingPosition();
        TestMatchAdvancesAsSpeechContinues();
        TestMatchToleratesRecognitionErrors();
        TestMatchRejectsUnrelatedSpeech();
        TestMatchHoldsOnRepeatedPassage();
        TestMatchIgnoresFillers();
        TestMatchIgnoresPunctuationAndCase();
        TestMatchEdgeCases();
        TestNonCJKScriptsAreKept();
        TestLeadingPunctuationKeepsItsPlace();
        TestTrailingPunctuationStaysWithItsText();
        TestCRLFMarkers();
        TestLeadingBlankLineKept();
        TestHardCutRespectsGraphemes();
        TestEmojiOnlySectionKept();
        TestUnmarkedTextRejoinsExactly();
        TestOneCharacterPartialDoesNotJump();
        TestNeverMovesBackward();
        TestHoldOffsetIsClamped();
        TestExactOffsetAfterInsertion();
        TestExactOffsetAfterDeletion();
        TestFullWidthMatchesHalfWidth();
        TestNFDMatchesNFC();
        TestChineseNumeralsMatchDigits();
        TestUnitOnlyWordsStayWords();
        NSLog(@"all page-teleprompter tests passed");
    }
    return 0;
}
