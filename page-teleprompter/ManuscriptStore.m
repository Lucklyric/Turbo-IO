#import "ManuscriptStore.h"

const NSUInteger TIOManuscriptMaxBytes = 512 * 1024;
const NSUInteger TIOManuscriptMaxRevisions = 20;
NSErrorDomain const TIOManuscriptErrorDomain = @"TIOManuscript";

// Titles are cut to this many graphemes.
static const NSUInteger kTitleGraphemes = 60;
// A record is current text plus every retained revision plus JSON overhead.
static const unsigned long long kMaxRecordBytes =
    (unsigned long long)(TIOManuscriptMaxRevisions + 2) * TIOManuscriptMaxBytes * 2;

static void Report(NSError **out, TIOManuscriptError code, NSString *why, NSError *underlying) {
    if (!out) return;
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: why} mutableCopy];
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    *out = [NSError errorWithDomain:TIOManuscriptErrorDomain code:code userInfo:info];
}

/// A positive whole number that is not a JSON boolean.
static BOOL IsPositiveInteger(id n) {
    if (![n isKindOfClass:NSNumber.class]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)n) == CFBooleanGetTypeID()) return NO;
    double v = [n doubleValue];
    return v >= 1 && v == floor(v) && v < 9007199254740992.0;
}

static BOOL IsFiniteNumber(id n) {
    if (![n isKindOfClass:NSNumber.class]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)n) == CFBooleanGetTypeID()) return NO;
    return isfinite([n doubleValue]);
}

/// First `limit` graphemes, never splitting one.
static NSString *CutGraphemes(NSString *s, NSUInteger limit) {
    __block NSUInteger count = 0, end = 0;
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length)
                          options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString * __unused g, NSRange r, NSRange __unused er, BOOL *stop) {
        if (count == limit) { *stop = YES; return; }
        count++;
        end = NSMaxRange(r);
    }];
    return [s substringToIndex:end];
}

static NSString *CleanTitle(NSString *title) {
    if (![title isKindOfClass:NSString.class]) return nil;
    NSString *t = [title stringByTrimmingCharactersInSet:
                   NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return t.length ? CutGraphemes(t, kTitleGraphemes) : nil;
}

#pragma mark - Model

@interface TIOManuscriptRevision ()
@property(nonatomic) NSUInteger number;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *text;
@property(nonatomic, copy) NSDate *replacedAt;
@end

@implementation TIOManuscriptRevision
+ (instancetype)fromJSON:(NSDictionary *)j {
    if (![j isKindOfClass:NSDictionary.class]) return nil;
    NSString *title = j[@"title"], *text = j[@"text"];
    if (![title isKindOfClass:NSString.class] || ![text isKindOfClass:NSString.class]) return nil;
    if (!IsPositiveInteger(j[@"number"]) || !IsFiniteNumber(j[@"replacedAt"])) return nil;
    TIOManuscriptRevision *r = [self new];
    r.number = [j[@"number"] unsignedIntegerValue];
    r.title = title;
    r.text = text;
    r.replacedAt = [NSDate dateWithTimeIntervalSince1970:[j[@"replacedAt"] doubleValue]];
    return r;
}
- (NSDictionary *)toJSON {
    return @{@"number": @(self.number), @"title": self.title, @"text": self.text,
             @"replacedAt": @(self.replacedAt.timeIntervalSince1970)};
}
@end

@interface TIOManuscript ()
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *text;
@property(nonatomic, copy) NSDate *createdAt;
@property(nonatomic, copy) NSDate *updatedAt;
@property(nonatomic) NSUInteger revision;
@property(nonatomic, copy) NSArray<TIOManuscriptRevision *> *revisions;
@end

@implementation TIOManuscript
/// Nil when the record is inconsistent in any way; a partly valid record is
/// not silently repaired, so a later save cannot make a loss permanent.
+ (instancetype)fromJSON:(NSDictionary *)j expectedIdentifier:(NSString *)expected {
    if (![j isKindOfClass:NSDictionary.class]) return nil;
    if (![j[@"id"] isEqual:expected]) return nil;
    NSString *title = j[@"title"], *text = j[@"text"];
    if (![title isKindOfClass:NSString.class] || ![text isKindOfClass:NSString.class]) return nil;
    if (!IsFiniteNumber(j[@"createdAt"]) || !IsFiniteNumber(j[@"updatedAt"])) return nil;
    if (!IsPositiveInteger(j[@"revision"])) return nil;
    NSUInteger revision = [j[@"revision"] unsignedIntegerValue];

    id raw = j[@"revisions"];
    if (![raw isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *revisions = [NSMutableArray array];
    NSUInteger last = 0;
    for (id row in (NSArray *)raw) {
        TIOManuscriptRevision *r = [TIOManuscriptRevision fromJSON:row];
        if (!r || r.number <= last || r.number >= revision) return nil;   // strictly increasing
        last = r.number;
        [revisions addObject:r];
    }
    while (revisions.count > TIOManuscriptMaxRevisions) [revisions removeObjectAtIndex:0];

    TIOManuscript *m = [self new];
    m.identifier = expected;
    m.title = title;
    m.text = text;
    m.createdAt = [NSDate dateWithTimeIntervalSince1970:[j[@"createdAt"] doubleValue]];
    m.updatedAt = [NSDate dateWithTimeIntervalSince1970:[j[@"updatedAt"] doubleValue]];
    m.revision = revision;
    m.revisions = revisions;
    return m;
}
- (NSDictionary *)toJSON {
    NSMutableArray *revisions = [NSMutableArray array];
    for (TIOManuscriptRevision *r in self.revisions) [revisions addObject:[r toJSON]];
    return @{@"id": self.identifier, @"title": self.title, @"text": self.text,
             @"createdAt": @(self.createdAt.timeIntervalSince1970),
             @"updatedAt": @(self.updatedAt.timeIntervalSince1970),
             @"revision": @(self.revision), @"revisions": revisions};
}
@end

#pragma mark - Store

@implementation TIOManuscriptStore {
    NSString *_directory;
    dispatch_queue_t _queue;
}

- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) {
        _directory = [directory copy];
        _queue = dispatch_queue_create("tio.manuscript-store", DISPATCH_QUEUE_SERIAL);
        [NSFileManager.defaultManager createDirectoryAtPath:_directory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
    }
    return self;
}

#pragma mark Unlocked helpers — call only on _queue

/// Only canonical UUID strings name a file, so no identifier can form a path
/// component other than `<UUID>.json`.
- (NSString *)pathFor:(NSString *)identifier {
    if (![identifier isKindOfClass:NSString.class]) return nil;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
    if (!uuid || ![uuid.UUIDString isEqual:identifier]) return nil;
    return [_directory stringByAppendingPathComponent:
            [identifier stringByAppendingPathExtension:@"json"]];
}

- (TIOManuscript *)load:(NSString *)identifier error:(NSError **)error {
    NSString *path = [self pathFor:identifier];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!path || ![fm fileExistsAtPath:path]) {
        Report(error, TIOManuscriptErrorNotFound, @"稿件不存在", nil);
        return nil;
    }
    NSError *io = nil;
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:&io];
    if (!attrs || attrs.fileSize > kMaxRecordBytes) {
        Report(error, TIOManuscriptErrorCorrupt, @"稿件文件无法读取或过大", io);
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&io];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&io] : nil;
    TIOManuscript *m = [TIOManuscript fromJSON:json expectedIdentifier:identifier];
    if (!m) Report(error, TIOManuscriptErrorCorrupt, @"稿件文件已损坏", io);
    return m;
}

- (BOOL)save:(TIOManuscript *)m error:(NSError **)error {
    NSString *path = [self pathFor:m.identifier];
    NSError *io = nil;
    NSData *data = path ? [NSJSONSerialization dataWithJSONObject:[m toJSON] options:0 error:&io]
                        : nil;
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:&io]) {
        Report(error, TIOManuscriptErrorWriteFailed, @"无法写入稿件文件", io);
        return NO;
    }
    return YES;
}

- (BOOL)validate:(NSString *)text error:(NSError **)error {
    if (![text isKindOfClass:NSString.class] ||
        ![text stringByTrimmingCharactersInSet:
          NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
        Report(error, TIOManuscriptErrorInvalidText, @"稿件内容为空", nil);
        return NO;
    }
    // canBeConvertedToEncoding: reports YES for lone surrogates; a strict
    // conversion is the only reliable check.
    if (![text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO]) {
        Report(error, TIOManuscriptErrorNotUTF8, @"稿件包含无法编码为 UTF-8 的字符", nil);
        return NO;
    }
    if ([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > TIOManuscriptMaxBytes) {
        Report(error, TIOManuscriptErrorTooLarge, @"稿件超过大小上限", nil);
        return NO;
    }
    return YES;
}

- (NSString *)titleFromText:(NSString *)text {
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *t = CleanTitle(line);
        if (t) return t;
    }
    return @"未命名稿件";
}

- (TIOManuscript *)create:(NSString *)title text:(NSString *)text error:(NSError **)error {
    if (![self validate:text error:error]) return nil;
    TIOManuscript *m = [TIOManuscript new];
    m.identifier = NSUUID.UUID.UUIDString;
    m.title = CleanTitle(title) ?: [self titleFromText:text];
    m.text = text;
    m.createdAt = m.updatedAt = NSDate.date;
    m.revision = 1;
    m.revisions = @[];
    return [self save:m error:error] ? m : nil;
}

- (TIOManuscript *)update:(NSString *)identifier title:(NSString *)title
                     text:(NSString *)text error:(NSError **)error {
    TIOManuscript *m = [self load:identifier error:error];
    if (!m) return nil;
    NSString *newText = [text isKindOfClass:NSString.class] ? [text copy] : m.text;
    NSString *newTitle = CleanTitle(title) ?: m.title;
    if ([newText isEqual:m.text] && [newTitle isEqual:m.title]) return m;
    if (![self validate:newText error:error]) return nil;

    TIOManuscriptRevision *previous = [TIOManuscriptRevision new];
    previous.number = m.revision;
    previous.title = m.title;
    previous.text = m.text;
    previous.replacedAt = NSDate.date;

    NSMutableArray *history = [m.revisions mutableCopy];
    [history addObject:previous];
    while (history.count > TIOManuscriptMaxRevisions) [history removeObjectAtIndex:0];

    TIOManuscript *next = [TIOManuscript new];
    next.identifier = m.identifier;
    next.createdAt = m.createdAt;
    next.title = newTitle;
    next.text = newText;
    next.updatedAt = NSDate.date;
    next.revision = m.revision + 1;
    next.revisions = history;
    return [self save:next error:error] ? next : nil;
}

#pragma mark Public API — each call is one transaction on _queue

- (NSArray<TIOManuscript *> *)list {
    __block NSArray *result;
    dispatch_sync(_queue, ^{
        NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:self->_directory
                                                                           error:nil];
        NSMutableArray<TIOManuscript *> *out = [NSMutableArray array];
        for (NSString *name in names) {
            if (![name.pathExtension isEqual:@"json"]) continue;
            TIOManuscript *m = [self load:name.stringByDeletingPathExtension error:nil];
            if (m) [out addObject:m];
        }
        [out sortUsingComparator:^NSComparisonResult(TIOManuscript *a, TIOManuscript *b) {
            return [b.updatedAt compare:a.updatedAt];
        }];
        result = out;
    });
    return result;
}

- (TIOManuscript *)manuscriptWithIdentifier:(NSString *)identifier {
    __block TIOManuscript *m;
    dispatch_sync(_queue, ^{ m = [self load:identifier error:nil]; });
    return m;
}

- (TIOManuscript *)createWithTitle:(NSString *)title text:(NSString *)text error:(NSError **)error {
    __block TIOManuscript *m; __block NSError *e = nil;
    NSString *t = [title copy], *x = [text copy];
    dispatch_sync(_queue, ^{ m = [self create:t text:x error:&e]; });
    if (error && e) *error = e;
    return m;
}

- (TIOManuscript *)updateIdentifier:(NSString *)identifier title:(NSString *)title
                               text:(NSString *)text error:(NSError **)error {
    __block TIOManuscript *m; __block NSError *e = nil;
    NSString *t = [title copy], *x = [text copy];
    dispatch_sync(_queue, ^{ m = [self update:identifier title:t text:x error:&e]; });
    if (error && e) *error = e;
    return m;
}

- (BOOL)deleteIdentifier:(NSString *)identifier error:(NSError **)error {
    __block BOOL ok = NO; __block NSError *e = nil;
    dispatch_sync(_queue, ^{
        NSString *path = [self pathFor:identifier];
        if (!path || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
            Report(&e, TIOManuscriptErrorNotFound, @"稿件不存在", nil);
            return;
        }
        NSError *io = nil;
        ok = [NSFileManager.defaultManager removeItemAtPath:path error:&io];
        if (!ok) Report(&e, TIOManuscriptErrorWriteFailed, @"删除失败", io);
    });
    if (error && e) *error = e;
    return ok;
}

- (TIOManuscript *)restoreIdentifier:(NSString *)identifier toRevision:(NSUInteger)number
                               error:(NSError **)error {
    __block TIOManuscript *m; __block NSError *e = nil;
    dispatch_sync(_queue, ^{
        TIOManuscript *current = [self load:identifier error:&e];
        if (!current) return;
        for (TIOManuscriptRevision *r in current.revisions) {
            if (r.number != number) continue;
            // Same transaction, so nothing can change between lookup and write.
            m = [self update:identifier title:r.title text:r.text error:&e];
            return;
        }
        Report(&e, TIOManuscriptErrorNotFound, @"该修订已不在保留范围内", nil);
    });
    if (error && e) *error = e;
    return m;
}

- (TIOManuscript *)importData:(NSData *)data filename:(NSString *)filename error:(NSError **)error {
    if (![data isKindOfClass:NSData.class] || !data.length) {
        Report(error, TIOManuscriptErrorInvalidText, @"文件为空", nil);
        return nil;
    }
    if (data.length > TIOManuscriptMaxBytes) {
        Report(error, TIOManuscriptErrorTooLarge, @"文件超过大小上限", nil);
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        Report(error, TIOManuscriptErrorNotUTF8, @"文件不是 UTF-8 文本", nil);
        return nil;
    }
    NSString *title = nil;
    if ([filename isKindOfClass:NSString.class] && filename.length)
        title = filename.lastPathComponent.stringByDeletingPathExtension;
    return [self createWithTitle:title text:text error:error];
}
@end
