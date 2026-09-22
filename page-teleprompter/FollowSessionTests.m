#import "FollowSession.h"
#import "PageTeleprompter.h"
#import <assert.h>

static void TestHighlightAdvancesWithinPage(void) {
    TIOFollowSession *s = [[TIOFollowSession alloc] initWithPages:@[@"我们今天讨论新方案的可行性问题。"]];
    TIOFollowCommand a = [s observe:@"我们今天讨论新方案"];
    assert(a.kind == TIOFollowHighlight && a.pageIndex == 0);
    TIOFollowCommand b = [s observe:@"我们今天讨论新方案的可行性"];
    assert(b.kind == TIOFollowHighlight && b.byteOffset > a.byteOffset);
    NSLog(@"PASS: the highlight moves forward within a page");
}

static void TestNoCommandOnRepeatedPartial(void) {
    TIOFollowSession *s = [[TIOFollowSession alloc] initWithPages:@[@"我们今天讨论新方案的可行性问题。"]];
    [s observe:@"我们今天讨论新方案"];
    NSUInteger cursor = s.cursorByteOffset;
    TIOFollowCommand again = [s observe:@"我们今天讨论新方案"];
    assert(again.kind == TIOFollowNone);
    assert(s.cursorByteOffset == cursor);
    NSLog(@"PASS: an unchanged partial produces no command");
}

static void TestCrossoverAdvancesPage(void) {
    NSArray *pages = @[@"第一页讲的是背景和动机部分。", @"第二页开始讲具体的方法和步骤。"];
    TIOFollowSession *s = [[TIOFollowSession alloc] initWithPages:pages];
    [s observe:@"第一页讲的是背景和动机部分"];
    assert(s.pageIndex == 0);
    // Reader runs past the end into page 2.
    TIOFollowCommand c = [s observe:@"背景和动机部分第二页开始讲具体"];
    assert(c.kind == TIOFollowAdvance);
    assert(c.pageIndex == 1);
    assert(s.pageIndex == 1);
    NSLog(@"PASS: reading into the next page advances and re-homes the session");
}

static void TestNoFalseAdvanceMidPage(void) {
    NSArray *pages = @[@"这是第一页的内容有好几句话在里面。", @"这是完全不同的第二页内容。"];
    TIOFollowSession *s = [[TIOFollowSession alloc] initWithPages:pages];
    TIOFollowCommand c = [s observe:@"这是第一页的内容"];
    assert(c.kind == TIOFollowHighlight && s.pageIndex == 0);
    NSLog(@"PASS: a mid-page match does not flip the page");
}

static void TestManualGoToPageResets(void) {
    NSArray *pages = @[@"第一页内容在这里。", @"第二页内容在这里。", @"第三页内容在这里。"];
    TIOFollowSession *s = [[TIOFollowSession alloc] initWithPages:pages];
    [s observe:@"第一页内容"];
    [s goToPage:2];
    assert(s.pageIndex == 2 && s.cursorByteOffset == 0);
    TIOFollowCommand c = [s observe:@"第三页内容"];
    assert(c.kind == TIOFollowHighlight && c.pageIndex == 2);
    NSLog(@"PASS: a manual page turn resets the cursor and matches the new page");
}

static void TestStaleOldPageSpeechDoesNotMatchNewPage(void) {
    NSArray *pages = @[@"苹果香蕉橙子葡萄西瓜。", @"完全无关的另外一段文字内容。"];
    TIOFollowSession *s = [[TIOFollowSession alloc] initWithPages:pages];
    [s goToPage:1];
    // A late result for page 1's speech arrives; it must not move page 2.
    TIOFollowCommand c = [s observe:@"苹果香蕉橙子葡萄"];
    assert(c.kind == TIOFollowNone && s.pageIndex == 1 && s.cursorByteOffset == 0);
    NSLog(@"PASS: speech from the previous page does not drive the new page");
}

static void TestEditReplacesPages(void) {
    TIOFollowSession *s = [[TIOFollowSession alloc] initWithPages:@[@"旧的内容在这里。"]];
    [s observe:@"旧的内容"];
    [s setPages:@[@"新的第一页。", @"新的第二页。"]];
    assert(s.pageIndex == 0 && s.cursorByteOffset == 0 && s.pageCount == 2);
    TIOFollowCommand c = [s observe:@"新的第一页"];
    assert(c.kind == TIOFollowHighlight);
    NSLog(@"PASS: replacing the manuscript resets to the first new page");
}

static void TestEmptyAndOutOfRange(void) {
    TIOFollowSession *s = [[TIOFollowSession alloc] initWithPages:@[]];
    assert([s observe:@"任何内容"].kind == TIOFollowNone);
    [s goToPage:5];   // no crash, no change
    assert(s.pageIndex == 0);
    TIOFollowSession *t = [[TIOFollowSession alloc] initWithPages:@[@"一页内容。"]];
    assert([t observe:nil].kind == TIOFollowNone);
    assert([t observe:@""].kind == TIOFollowNone);
    NSLog(@"PASS: empty pages, nil speech and bad indices are safe");
}

static void TestConfidenceReported(void) {
    TIOFollowSession *s = [[TIOFollowSession alloc] initWithPages:@[@"精确匹配这段文字内容。"]];
    TIOFollowCommand c = [s observe:@"精确匹配这段文字"];
    assert(c.kind == TIOFollowHighlight && c.confidence > 0.9);
    NSLog(@"PASS: the command carries the match confidence %.2f", c.confidence);
}

int main(void) {
    @autoreleasepool {
        TestHighlightAdvancesWithinPage();
        TestNoCommandOnRepeatedPartial();
        TestCrossoverAdvancesPage();
        TestNoFalseAdvanceMidPage();
        TestManualGoToPageResets();
        TestStaleOldPageSpeechDoesNotMatchNewPage();
        TestEditReplacesPages();
        TestEmptyAndOutOfRange();
        TestConfidenceReported();
        NSLog(@"all follow-session tests passed");
    }
    return 0;
}
