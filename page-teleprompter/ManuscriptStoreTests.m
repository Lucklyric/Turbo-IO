#import "ManuscriptStore.h"
#import "PageTeleprompter.h"
#import <assert.h>

static TIOManuscriptStore *FreshStore(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [@"tio-manuscripts-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    return [[TIOManuscriptStore alloc] initWithDirectory:dir];
}

static void TestCreateAndRead(void) {
    TIOManuscriptStore *s = FreshStore();
    NSError *e = nil;
    TIOManuscript *m = [s createWithTitle:@"开幕致辞" text:@"各位来宾大家好。" error:&e];
    assert(m && !e);
    assert([m.title isEqual:@"开幕致辞"]);
    assert(m.revision == 1);
    assert(m.revisions.count == 0);
    assert([[s manuscriptWithIdentifier:m.identifier].text isEqual:m.text]);
    NSLog(@"PASS: create then read back");
}

static void TestTitleFallsBackToFirstLine(void) {
    TIOManuscriptStore *s = FreshStore();
    TIOManuscript *m = [s createWithTitle:nil text:@"\n\n第一行是标题\n正文在这里。" error:nil];
    assert([m.title isEqual:@"第一行是标题"]);
    NSLog(@"PASS: an untitled manuscript takes its first non-empty line");
}

static void TestRejectsEmptyAndOversized(void) {
    TIOManuscriptStore *s = FreshStore();
    NSError *e = nil;
    assert(![s createWithTitle:@"空" text:@"   \n\n  " error:&e]);
    assert(e.code == TIOManuscriptErrorInvalidText);
    e = nil;
    NSString *huge = [@"" stringByPaddingToLength:TIOManuscriptMaxBytes + 10
                                       withString:@"a" startingAtIndex:0];
    assert(![s createWithTitle:@"大" text:huge error:&e]);
    assert(e.code == TIOManuscriptErrorTooLarge);
    NSLog(@"PASS: blank and oversized manuscripts are refused");
}

static void TestUpdateRecordsRevision(void) {
    TIOManuscriptStore *s = FreshStore();
    TIOManuscript *m = [s createWithTitle:@"稿件" text:@"第一版内容。" error:nil];
    TIOManuscript *edited = [s updateIdentifier:m.identifier title:nil
                                           text:@"第二版内容。" error:nil];
    assert(edited.revision == 2);
    assert(edited.revisions.count == 1);
    assert([edited.revisions[0].text isEqual:@"第一版内容。"]);
    assert(edited.revisions[0].number == 1);
    assert([edited.text isEqual:@"第二版内容。"]);
    NSLog(@"PASS: an edit keeps the version it replaced");
}

static void TestNoOpEditRecordsNothing(void) {
    TIOManuscriptStore *s = FreshStore();
    TIOManuscript *m = [s createWithTitle:@"稿件" text:@"内容。" error:nil];
    TIOManuscript *same = [s updateIdentifier:m.identifier title:@"稿件"
                                         text:@"内容。" error:nil];
    assert(same.revision == 1);
    assert(same.revisions.count == 0);
    NSLog(@"PASS: an edit that changes nothing records nothing");
}

static void TestRevisionsAreCapped(void) {
    TIOManuscriptStore *s = FreshStore();
    TIOManuscript *m = [s createWithTitle:@"稿件" text:@"v0" error:nil];
    for (NSUInteger i = 1; i <= TIOManuscriptMaxRevisions + 5; i++)
        m = [s updateIdentifier:m.identifier title:nil
                           text:[NSString stringWithFormat:@"v%lu", (unsigned long)i]
                          error:nil];
    assert(m.revisions.count == TIOManuscriptMaxRevisions);
    // The oldest were dropped, the newest retained.
    NSString *newestKept = [NSString stringWithFormat:@"v%lu",
                            (unsigned long)(TIOManuscriptMaxRevisions + 4)];
    assert([m.revisions.lastObject.text isEqual:newestKept]);
    NSLog(@"PASS: revision history is capped at %lu", (unsigned long)TIOManuscriptMaxRevisions);
}

static void TestRestoreIsItselfUndoable(void) {
    TIOManuscriptStore *s = FreshStore();
    TIOManuscript *m = [s createWithTitle:@"稿件" text:@"原始内容。" error:nil];
    m = [s updateIdentifier:m.identifier title:nil text:@"改坏了。" error:nil];
    TIOManuscript *restored = [s restoreIdentifier:m.identifier toRevision:1 error:nil];
    assert([restored.text isEqual:@"原始内容。"]);
    // The bad edit is still in history, so the rollback can be rolled back.
    BOOL keptBadVersion = NO;
    for (TIOManuscriptRevision *r in restored.revisions)
        if ([r.text isEqual:@"改坏了。"]) keptBadVersion = YES;
    assert(keptBadVersion);
    NSLog(@"PASS: restoring an old revision is itself undoable");
}

static void TestDelete(void) {
    TIOManuscriptStore *s = FreshStore();
    TIOManuscript *m = [s createWithTitle:@"稿件" text:@"内容。" error:nil];
    NSError *e = nil;
    assert([s deleteIdentifier:m.identifier error:&e] && !e);
    assert(![s manuscriptWithIdentifier:m.identifier]);
    assert(![s deleteIdentifier:m.identifier error:&e]);
    assert(e.code == TIOManuscriptErrorNotFound);
    NSLog(@"PASS: delete removes the manuscript and reports a second attempt");
}

static void TestListIsNewestFirst(void) {
    TIOManuscriptStore *s = FreshStore();
    [s createWithTitle:@"一" text:@"A" error:nil];
    TIOManuscript *second = [s createWithTitle:@"二" text:@"B" error:nil];
    [s updateIdentifier:second.identifier title:nil text:@"B2" error:nil];
    NSArray<TIOManuscript *> *all = [s list];
    assert(all.count == 2);
    assert([all[0].title isEqual:@"二"]);
    NSLog(@"PASS: the list puts the most recently edited first");
}

static void TestImportAcceptsTextAndNamesIt(void) {
    TIOManuscriptStore *s = FreshStore();
    NSData *data = [@"讲稿正文。" dataUsingEncoding:NSUTF8StringEncoding];
    TIOManuscript *m = [s importData:data filename:@"/somewhere/年会讲稿.md" error:nil];
    assert([m.title isEqual:@"年会讲稿"]);
    assert([m.text isEqual:@"讲稿正文。"]);
    NSLog(@"PASS: import names the manuscript after the file");
}

static void TestImportRejectsBinary(void) {
    TIOManuscriptStore *s = FreshStore();
    NSError *e = nil;
    unsigned char junk[] = {0xFF, 0xFE, 0x00, 0x01, 0xC0, 0x80};
    NSData *data = [NSData dataWithBytes:junk length:sizeof(junk)];
    assert(![s importData:data filename:@"x.bin" error:&e]);
    assert(e.code == TIOManuscriptErrorNotUTF8);
    NSLog(@"PASS: a non-UTF-8 upload is refused");
}

static void TestIdentifierCannotEscapeTheDirectory(void) {
    TIOManuscriptStore *s = FreshStore();
    NSError *e = nil;
    assert(![s manuscriptWithIdentifier:@"../../etc/passwd"]);
    assert(![s deleteIdentifier:@"../../etc/passwd" error:&e]);
    NSLog(@"PASS: a crafted identifier cannot reach outside the store");
}

static void TestImportedManuscriptPaginatesByMarker(void) {
    // The whole point of import: an authored file with page breaks in it.
    TIOManuscriptStore *s = FreshStore();
    NSString *authored = @"第一页的内容。\n---\n第二页的内容。\n---\n第三页的内容。";
    NSData *data = [authored dataUsingEncoding:NSUTF8StringEncoding];
    TIOManuscript *m = [s importData:data filename:@"讲稿.md" error:nil];
    NSArray *pages = TIOPagePaginate(m.text, 200);
    assert(pages.count == 3);
    assert([pages[1] containsString:@"第二页"]);
    NSLog(@"PASS: an uploaded file's own page breaks drive pagination");
}


#pragma mark - Regressions from the 2026-09-22 review

static NSString *StoreDir(TIOManuscriptStore *s) { return [s valueForKey:@"_directory"]; }

static void TestConcurrentEditsAreNotLost(void) {
    TIOManuscriptStore *s = FreshStore();
    TIOManuscript *m = [s createWithTitle:@"稿件" text:@"v0" error:nil];
    NSString *ident = m.identifier;
    dispatch_apply(40, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
        NSError *e = nil;
        TIOManuscript *r = [s updateIdentifier:ident title:nil
                                          text:[NSString stringWithFormat:@"edit %zu", i]
                                         error:&e];
        assert(r && !e);
    });
    TIOManuscript *final = [s manuscriptWithIdentifier:ident];
    assert(final.revision == 41);      // every successful edit is on disk
    NSLog(@"PASS: 40 concurrent edits all land, revision %lu", (unsigned long)final.revision);
}

static void TestMismatchedIdentifierIsCorrupt(void) {
    TIOManuscriptStore *s = FreshStore();
    TIOManuscript *a = [s createWithTitle:@"A" text:@"甲" error:nil];
    TIOManuscript *b = [s createWithTitle:@"B" text:@"乙" error:nil];
    NSString *pathA = [StoreDir(s) stringByAppendingPathComponent:
                       [a.identifier stringByAppendingPathExtension:@"json"]];
    NSMutableDictionary *j = [[NSJSONSerialization JSONObjectWithData:
                               [NSData dataWithContentsOfFile:pathA] options:0 error:nil] mutableCopy];
    j[@"id"] = b.identifier;                       // A's file now claims to be B
    [[NSJSONSerialization dataWithJSONObject:j options:0 error:nil] writeToFile:pathA atomically:YES];

    NSError *e = nil;
    assert(![s updateIdentifier:a.identifier title:nil text:@"改" error:&e]);
    assert(e.code == TIOManuscriptErrorCorrupt);
    assert([[s manuscriptWithIdentifier:b.identifier].text isEqual:@"乙"]);   // B untouched
    NSLog(@"PASS: a record whose id disagrees with its file is refused, not redirected");
}

static void TestMalformedRevisionNumbersAreCorrupt(void) {
    TIOManuscriptStore *s = FreshStore();
    TIOManuscript *m = [s createWithTitle:@"稿件" text:@"内容" error:nil];
    NSString *path = [StoreDir(s) stringByAppendingPathComponent:
                      [m.identifier stringByAppendingPathExtension:@"json"]];
    NSDictionary *good = [NSJSONSerialization JSONObjectWithData:
                          [NSData dataWithContentsOfFile:path] options:0 error:nil];
    for (id bad in @[@(-1), @(1.5), @YES, @"2"]) {
        NSMutableDictionary *j = [good mutableCopy];
        j[@"revision"] = bad;
        [[NSJSONSerialization dataWithJSONObject:j options:0 error:nil] writeToFile:path atomically:YES];
        assert(![s manuscriptWithIdentifier:m.identifier]);
    }
    NSLog(@"PASS: negative, fractional, boolean and string revisions are rejected");
}

static void TestModelIsASnapshot(void) {
    TIOManuscriptStore *s = FreshStore();
    NSMutableString *text = [@"initial" mutableCopy];
    TIOManuscript *m = [s createWithTitle:@"稿件" text:text error:nil];
    [text setString:@"mutated"];
    assert([m.text isEqual:@"initial"]);
    assert([[s manuscriptWithIdentifier:m.identifier].text isEqual:@"initial"]);
    NSLog(@"PASS: mutating the caller's string does not change the stored model");
}

static void TestTitleCutsOnGraphemeBoundary(void) {
    TIOManuscriptStore *s = FreshStore();
    NSString *line = [[@"" stringByPaddingToLength:59 withString:@"a" startingAtIndex:0]
                      stringByAppendingString:@"😀tail"];
    NSError *e = nil;
    TIOManuscript *m = [s createWithTitle:nil text:[line stringByAppendingString:@"\n正文"] error:&e];
    assert(m && !e);
    assert([m.title hasSuffix:@"😀"]);
    NSLog(@"PASS: an emoji at the title limit is kept whole, not split");
}

static void TestLoneSurrogateIsRefused(void) {
    TIOManuscriptStore *s = FreshStore();
    unichar bad[] = {'a', 0xD800, 'b'};
    NSError *e = nil;
    assert(![s createWithTitle:@"x" text:[NSString stringWithCharacters:bad length:3] error:&e]);
    assert(e.code == TIOManuscriptErrorNotUTF8);
    NSLog(@"PASS: text that cannot be encoded as UTF-8 is refused before storage");
}

static void TestDroppedRevisionCannotBeRestored(void) {
    TIOManuscriptStore *s = FreshStore();
    TIOManuscript *m = [s createWithTitle:@"稿件" text:@"v0" error:nil];
    for (NSUInteger i = 1; i <= TIOManuscriptMaxRevisions + 3; i++)
        m = [s updateIdentifier:m.identifier title:nil
                           text:[NSString stringWithFormat:@"v%lu", (unsigned long)i] error:nil];
    assert(m.revisions.firstObject.number == 4);          // 1..3 were dropped
    NSError *e = nil;
    assert(![s restoreIdentifier:m.identifier toRevision:2 error:&e]);
    assert(e.code == TIOManuscriptErrorNotFound);
    assert([s restoreIdentifier:m.identifier toRevision:4 error:nil]);
    NSLog(@"PASS: the oldest revisions are the ones dropped, and cannot be restored");
}

int main(void) {
    @autoreleasepool {
        TestCreateAndRead();
        TestTitleFallsBackToFirstLine();
        TestRejectsEmptyAndOversized();
        TestUpdateRecordsRevision();
        TestNoOpEditRecordsNothing();
        TestRevisionsAreCapped();
        TestRestoreIsItselfUndoable();
        TestDelete();
        TestListIsNewestFirst();
        TestImportAcceptsTextAndNamesIt();
        TestImportRejectsBinary();
        TestIdentifierCannotEscapeTheDirectory();
        TestImportedManuscriptPaginatesByMarker();
        TestConcurrentEditsAreNotLost();
        TestMismatchedIdentifierIsCorrupt();
        TestMalformedRevisionNumbersAreCorrupt();
        TestModelIsASnapshot();
        TestTitleCutsOnGraphemeBoundary();
        TestLoneSurrogateIsRefused();
        TestDroppedRevisionCannotBeRestored();
        NSLog(@"all manuscript-store tests passed");
    }
    return 0;
}
