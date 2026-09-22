// Manuscript library for the page-wise teleprompter: import, edit, delete, and
// a revision trail so an edit made before going on stage can be undone.
//
// Pure Foundation over a plain directory of JSON files, one per manuscript, so
// it builds and tests on the host and needs no database.
//
// Concurrency contract: every public method runs on one private serial queue,
// so read-modify-write operations are transactions within one store instance.
// Use exactly one store instance per directory; two instances on the same
// directory are not coordinated. The directory must be app-private.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Largest manuscript accepted, in UTF-8 bytes. Well beyond a spoken hour.
FOUNDATION_EXPORT const NSUInteger TIOManuscriptMaxBytes;
/// Revisions retained per manuscript. Older ones are dropped on write.
FOUNDATION_EXPORT const NSUInteger TIOManuscriptMaxRevisions;

FOUNDATION_EXPORT NSErrorDomain const TIOManuscriptErrorDomain;
typedef NS_ERROR_ENUM(TIOManuscriptErrorDomain, TIOManuscriptError) {
    TIOManuscriptErrorInvalidText = 1,
    TIOManuscriptErrorTooLarge,
    TIOManuscriptErrorNotFound,
    TIOManuscriptErrorNotUTF8,
    TIOManuscriptErrorWriteFailed,
    /// The record exists but is unreadable or inconsistent. It is left on disk.
    TIOManuscriptErrorCorrupt,
};

/// One superseded version of a manuscript.
@interface TIOManuscriptRevision : NSObject
@property(nonatomic, readonly) NSUInteger number;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, copy) NSString *text;
@property(nonatomic, readonly, copy) NSDate *replacedAt;
@end

@interface TIOManuscript : NSObject
@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, copy) NSString *text;
@property(nonatomic, readonly, copy) NSDate *createdAt;
@property(nonatomic, readonly, copy) NSDate *updatedAt;
/// Increments on every accepted edit. 1 for a freshly created manuscript.
@property(nonatomic, readonly) NSUInteger revision;
@property(nonatomic, readonly, copy) NSArray<TIOManuscriptRevision *> *revisions;
@end

@interface TIOManuscriptStore : NSObject

/// Manuscripts are stored as JSON files named by canonical UUID under
/// `directory`, which is created on demand.
- (instancetype)initWithDirectory:(NSString *)directory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Most recently updated first.
- (NSArray<TIOManuscript *> *)list;
- (nullable TIOManuscript *)manuscriptWithIdentifier:(NSString *)identifier;

- (nullable TIOManuscript *)createWithTitle:(nullable NSString *)title
                                       text:(NSString *)text
                                      error:(NSError **)error;

/// Passing nil for a field leaves it unchanged. An edit that changes nothing
/// returns the manuscript untouched and records no revision.
- (nullable TIOManuscript *)updateIdentifier:(NSString *)identifier
                                       title:(nullable NSString *)title
                                        text:(nullable NSString *)text
                                       error:(NSError **)error;

- (BOOL)deleteIdentifier:(NSString *)identifier error:(NSError **)error;

/// Roll the current content back to a retained revision. The version being
/// replaced is itself recorded, so a rollback is undoable.
- (nullable TIOManuscript *)restoreIdentifier:(NSString *)identifier
                                   toRevision:(NSUInteger)number
                                        error:(NSError **)error;

/// Import an uploaded file. The title comes from `filename` when none is given.
/// Rejects anything that is not valid UTF-8 text.
- (nullable TIOManuscript *)importData:(NSData *)data
                              filename:(nullable NSString *)filename
                                 error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
