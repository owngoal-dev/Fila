#import "NativeMusicLibrary.h"
#import <objc/runtime.h>
#include <dlfcn.h>

@protocol MusicLibraryAPI
+ (id)sharedLibrary;
- (NSString *)databasePath;
- (void)performDatabaseTransactionWithBlock:(BOOL (^)(id))block;
- (id)checkoutWriterConnection;
- (void)checkInDatabaseConnection:(id)connection;
- (id)initWithPath:(NSString *)path isUnitTesting:(BOOL)testing;
@end
@protocol MusicConnectionAPI
- (BOOL)isInTransaction;
- (BOOL)pushTransaction;
- (BOOL)popTransactionAndCommit:(BOOL)commit;
- (BOOL)popToRootTransactionAndCommit:(BOOL)commit;
- (id)executeQuery:(NSString *)query withParameters:(NSArray *)parameters;
@end
@protocol MusicResultAPI
- (id)objectForFirstRowAndColumn;
@end
@protocol MusicTrackAPI
+ (id)newWithPersistentID:(int64_t)trackID inLibrary:(id)library;
+ (BOOL)trackWithPersistentID:(int64_t)trackID existsInLibrary:(id)library;
+ (NSSet<NSString *> *)unsettableProperties;
- (id)valueForProperty:(NSString *)property;
+ (NSArray<NSString *> *)extraTablesToInsert;
+ (BOOL)insertValues:(NSDictionary *)values intoTable:(NSString *)table persistentID:(int64_t)trackID connection:(id)connection;
@end

@protocol MusicEditAPI
- (id)initWithLibrary:(id)library writer:(id)writer;
- (BOOL)_setValues:(NSArray *)values forProperties:(NSArray *)properties withEntityClass:(Class)entityClass usingPersistentID:(int64_t)trackID connection:(id)connection error:(NSError **)error;
@end

@interface NativeMusicLibrary ()
- (instancetype)initWithDatabasePath:(NSString *)path testing:(BOOL)testing error:(NSError **)error;
@end

static BOOL Signature(Method method, const char *result, NSArray<NSString *> *arguments, NSError **error) {
    if (!method || method_getNumberOfArguments(method) != arguments.count) {
        if (error) *error = [NSError errorWithDomain:@"MusicLibrary" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"A required MusicLibrary method is missing or has an unsupported argument count."
        }];
        return NO;
    }
    char *type = method_copyReturnType(method);
    BOOL matches = strcmp(type, result) == 0;
    free(type);
    for (unsigned index = 0; matches && index < arguments.count; index++) {
        type = method_copyArgumentType(method, index);
        matches = type && strcmp(type, arguments[index].UTF8String) == 0;
        free(type);
    }
    if (!matches && error) *error = [NSError errorWithDomain:@"MusicLibrary" code:1 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unsupported MusicLibrary signature: %@ (%s).", NSStringFromSelector(method_getName(method)), method_getTypeEncoding(method)]
    }];
    return matches;
}

static void Failure(NSError **error, NSInteger code) {
    if (error) *error = [NSError errorWithDomain:@"MusicLibrary" code:code userInfo:nil];
}

static NSString *Text(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return @"";
}

@implementation NativeMusicLibrary {
    id _library;
    Class _trackClass;
    NSDictionary<NSString *, NSString *> *_properties;
}

- (instancetype)initWithExpectedDatabasePath:(NSString *)path error:(NSError **)error {
    return [self initWithDatabasePath:path testing:NO error:error];
}

- (instancetype)initWithDatabasePath:(NSString *)path testing:(BOOL)testing error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    @try {
        // Keep the image loaded: the stored objects and property strings belong to it.
        static void *image;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            image = dlopen("/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", RTLD_NOW);
        });
        Class libraryClass = NSClassFromString(@"ML3MusicLibrary");
        Class connectionClass = NSClassFromString(@"ML3DatabaseConnection");
        Class operationClass = NSClassFromString(@"ML3SetValuesForPropertiesOperation");
        Class resultClass = NSClassFromString(@"ML3DatabaseResult");
        _trackClass = NSClassFromString(@"ML3Track");
        if (!image
            || !Signature(class_getClassMethod(libraryClass, @selector(sharedLibrary)), "@", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(libraryClass, @selector(initWithPath:isUnitTesting:)), "@", @[@"@", @":", @"@", @"B"], error)
            || !Signature(class_getInstanceMethod(libraryClass, @selector(databasePath)), "@", @[@"@", @":"], error)
            || !Signature(class_getClassMethod(_trackClass, @selector(newWithPersistentID:inLibrary:)), "@", @[@"@", @":", @"q", @"@"], error)
            || !Signature(class_getClassMethod(_trackClass, @selector(trackWithPersistentID:existsInLibrary:)), "B", @[@"@", @":", @"q", @"@"], error)
            || !Signature(class_getClassMethod(_trackClass, @selector(unsettableProperties)), "@", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(connectionClass, @selector(isInTransaction)), "B", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(connectionClass, @selector(executeQuery:withParameters:)), "@", @[@"@", @":", @"@", @"@"], error)
            || !Signature(class_getInstanceMethod(resultClass, @selector(objectForFirstRowAndColumn)), "@", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(_trackClass, @selector(valueForProperty:)), "@", @[@"@", @":", @"@"], error)
            || !Signature(class_getInstanceMethod(operationClass, @selector(initWithLibrary:writer:)), "@", @[@"@", @":", @"@", @"@"], error)
            || !Signature(class_getInstanceMethod(operationClass, @selector(_setValues:forProperties:withEntityClass:usingPersistentID:connection:error:)), "B", @[@"@", @":", @"@", @"@", @"#", @"q", @"@", @"^@"], error)
            || !Signature(class_getInstanceMethod(libraryClass, @selector(checkoutWriterConnection)), "@", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(libraryClass, @selector(checkInDatabaseConnection:)), "v", @[@"@", @":", @"@"], error)
            || !Signature(class_getInstanceMethod(connectionClass, @selector(pushTransaction)), "B", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(connectionClass, @selector(popTransactionAndCommit:)), "B", @[@"@", @":", @"B"], error)
            || !Signature(class_getInstanceMethod(connectionClass, @selector(popToRootTransactionAndCommit:)), "B", @[@"@", @":", @"B"], error)
            || !Signature(class_getInstanceMethod(libraryClass, @selector(performDatabaseTransactionWithBlock:)), "v", @[@"@", @":", @"@?"], error)) {
            if (error && !*error) Failure(error, 1);
            return nil;
        }
        _library = testing
            ? [(id<MusicLibraryAPI>)[libraryClass alloc] initWithPath:path isUnitTesting:YES]
            : [(Class<MusicLibraryAPI>)libraryClass sharedLibrary];
        NSString *actual = [(id<MusicLibraryAPI>)_library databasePath];
        if (![actual.stringByResolvingSymlinksInPath isEqualToString:path.stringByResolvingSymlinksInPath]) {
            if (error) *error = [NSError errorWithDomain:@"MusicLibrary" code:1 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"MusicLibrary opened %@ instead of %@.", actual, path]
            }];
            return nil;
        }
        NSMutableDictionary *properties = [NSMutableDictionary dictionary];
        NSMutableSet *editable = [NSMutableSet set];
        NSSet *unsettable = [(Class<MusicTrackAPI>)_trackClass unsettableProperties];
        for (NSString *field in @[@"Title", @"Artist", @"Album", @"AlbumArtist", @"Genre", @"Composer", @"Year", @"TrackNumber", @"DiscNumber", @"Comment"]) {
            NSString *symbol = [@"ML3TrackProperty" stringByAppendingString:field];
            NSString * __unsafe_unretained const *property = (NSString * __unsafe_unretained const *)dlsym(image, symbol.UTF8String);
            if (!property || ![*property isKindOfClass:NSString.class]) {
                if (error) *error = [NSError errorWithDomain:@"MusicLibrary" code:1 userInfo:@{
                    NSLocalizedDescriptionKey: [@"MusicLibrary property is unavailable: " stringByAppendingString:symbol]
                }];
                return nil;
            }
            properties[field] = *property;
            if (![unsettable containsObject:*property]) [editable addObject:field];
        }
        _properties = [properties copy];
        _editableFields = [editable copy];
        return self;
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"MusicLibrary" code:1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"MusicLibrary initialization: %@: %@", exception.name, exception.reason]
        }];
        return nil;
    }
}

- (id<MusicTrackAPI>)track:(int64_t)trackID error:(NSError **)error {
    if (![(Class<MusicTrackAPI>)_trackClass trackWithPersistentID:trackID existsInLibrary:_library]) {
        Failure(error, 1);
        return nil;
    }
    id<MusicTrackAPI> track = [(Class<MusicTrackAPI>)_trackClass newWithPersistentID:trackID inLibrary:_library];
    if (!track) Failure(error, 1);
    return track;
}

- (NSDictionary<NSString *, NSString *> *)valuesForTrackID:(int64_t)trackID error:(NSError **)error {
    @try {
        id<MusicTrackAPI> track = [self track:trackID error:error];
        if (!track) return nil;
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSString *field in _properties) values[field] = Text([track valueForProperty:_properties[field]]);
        return values;
    } @catch (NSException *exception) {
        Failure(error, 1);
        return nil;
    }
}

- (BOOL)setValue:(id)value forField:(NSString *)field trackID:(int64_t)trackID expected:(NSString *)expected error:(NSError **)error {
    @try {
        NSString *property = _properties[field];
        if (!property || ![_editableFields containsObject:field]) { Failure(error, 1); return NO; }
        // Only these directly stored fields have a transaction-scoped read.
        // Identifiers are fixed here; user values are never SQL fragments.
        NSDictionary *columns = @{
            @"Title": @"item_extra.title", @"Year": @"item_extra.year",
            @"Comment": @"item_extra.comment", @"TrackNumber": @"item.track_number",
            @"DiscNumber": @"item.disc_number"
        };
        NSString *column = columns[field];
        if (!column) { Failure(error, 1); return NO; }
        NSString *query = [NSString stringWithFormat:@"SELECT COALESCE(CAST(%@ AS TEXT), '') FROM item JOIN item_extra USING(item_pid) WHERE item.item_pid = ?", column];
        id<MusicConnectionAPI> connection = [(id<MusicLibraryAPI>)_library checkoutWriterConnection];
        @try {
            if (![connection pushTransaction]) { Failure(error, 3); return NO; }
            id<MusicResultAPI> result = [connection executeQuery:query withParameters:@[@(trackID)]];
            id current = [result objectForFirstRowAndColumn];
            if (![current isKindOfClass:NSString.class]) { Failure(error, 1); return NO; }
            if (![current isEqualToString:expected]) { Failure(error, 2); return NO; }
            // ML3Track's setter forwards to the system service even when given
            // a connection. This native operation keeps the comparison, field
            // update and revision bookkeeping in our one transaction.
            id<MusicEditAPI> operation = [(id<MusicEditAPI>)[NSClassFromString(@"ML3SetValuesForPropertiesOperation") alloc] initWithLibrary:_library writer:nil];
            if (![operation _setValues:@[value] forProperties:@[property] withEntityClass:_trackClass usingPersistentID:trackID connection:connection error:error]) {
                if (error && !*error) Failure(error, 3);
                return NO;
            }
            BOOL committed = [connection popTransactionAndCommit:YES];
            if (!committed) Failure(error, 3);
            return committed;
        } @finally {
            // Roll back on stale values, native failures and exceptions before
            // returning the checked-out writer to its pool.
            @try {
                if ([connection isInTransaction]) [connection popToRootTransactionAndCommit:NO];
            } @finally {
                if (connection) [(id<MusicLibraryAPI>)_library checkInDatabaseConnection:connection];
            }
        }
    } @catch (NSException *exception) {
#if DEBUG
        if (error) *error = [NSError errorWithDomain:@"MusicLibrary" code:3 userInfo:@{
            @"NativeException": exception.reason ?: exception.name
        }];
#else
        Failure(error, 3);
#endif
        return NO;
    }
}

+ (BOOL)checkEditingAtSnapshotPath:(NSString *)path error:(NSError **)error {
    @try {
        NSString *live = @"/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb";
        // This entry point is called only with the self-test's private snapshot.
        if ([path.stringByResolvingSymlinksInPath isEqualToString:live.stringByResolvingSymlinksInPath]) {
            Failure(error, 1);
            return NO;
        }
        NativeMusicLibrary *test = [[self alloc] initWithDatabasePath:path testing:YES error:error];
        if (!test) return NO;
        const int64_t trackID = 9007199254740993LL;
        __block BOOL inserted = NO;
        [(id<MusicLibraryAPI>)test->_library performDatabaseTransactionWithBlock:^BOOL(id connection) {
            Class<MusicTrackAPI> tracks = (Class<MusicTrackAPI>)test->_trackClass;
            inserted = [tracks insertValues:@{@"media_type": @1} intoTable:@"item" persistentID:trackID connection:connection]
                && [tracks insertValues:@{@"title": @"Fila fixture"} intoTable:@"item_extra" persistentID:trackID connection:connection];
            for (NSString *table in [tracks extraTablesToInsert]) {
                if (![table isEqualToString:@"item_extra"]) {
                    NSDictionary *values = [table isEqualToString:@"item_store"] ? @{@"sync_id": @1, @"sync_in_my_library": @1} : @{};
                    inserted = inserted && [tracks insertValues:values intoTable:table persistentID:trackID connection:connection];
                }
            }
            return inserted;
        }];
        if (!inserted) {
            if (error) *error = [NSError errorWithDomain:@"MusicFixture" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"The native music service refused insertion into the isolated snapshot."
            }];
            return NO;
        }
        NSError *conflict = nil;
        BOOL staleWrite = [test setValue:@"Must not replace" forField:@"Title" trackID:trackID expected:@"An older title" error:&conflict];
        if (staleWrite || ![conflict.domain isEqualToString:@"MusicLibrary"] || conflict.code != 2) {
            if (error) *error = [NSError errorWithDomain:@"MusicFixture" code:4 userInfo:@{
                NSLocalizedDescriptionKey: @"The transaction did not reject an outdated song value."
            }];
            return NO;
        }
        NSMutableArray<NSString *> *failures = [NSMutableArray array];
        for (NSString *field in [test.editableFields.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
            NSDictionary *before = [test valuesForTrackID:trackID error:error];
            if (!before) return NO;
            BOOL numeric = [@[@"Year", @"TrackNumber", @"DiscNumber"] containsObject:field];
            id value = numeric ? ([field isEqualToString:@"Year"] ? @2026 : @1) : [@"Fila test " stringByAppendingString:field];
            if (![test setValue:value forField:field trackID:trackID expected:before[field] error:error]) {
                NSDictionary *observed = [test valuesForTrackID:trackID error:nil];
                [failures addObject:[NSString stringWithFormat:@"%@ (before=%@, after=%@)", field, before[field], observed[field]]];
                continue;
            }
            NSDictionary *after = [test valuesForTrackID:trackID error:error];
            if (![after[field] isEqualToString:Text(value)]) [failures addObject:field];
        }
        if (failures.count) {
            if (error) *error = [NSError errorWithDomain:@"MusicFixture" code:2 userInfo:@{
                NSLocalizedDescriptionKey: [@"Native fixture fields failed: " stringByAppendingString:[failures componentsJoinedByString:@", "]]
            }];
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"MusicFixture" code:3 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Fixture exception %@: %@", exception.name, exception.reason]
        }];
        return NO;
    }
}

@end
