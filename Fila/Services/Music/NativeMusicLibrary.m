#import "NativeMusicLibrary.h"
#import <objc/runtime.h>
#include <dlfcn.h>

@protocol MusicImportAPI
- (id)initWithMultiverseIdentifier:(id)identifier mediaItem:(id)item;
- (id)initWithLibrary:(id)library connection:(id)connection configuration:(id)configuration;
- (BOOL)begin;
- (BOOL)finish;
- (BOOL)addTrack:(id)track persistentID:(NSNumber **)identifier;
@end

@protocol MusicLibraryAPI
+ (id)sharedLibrary;
- (NSString *)databasePath;
- (void)notifyEntitiesAddedOrRemoved;
- (id)checkoutWriterConnection;
- (void)checkInDatabaseConnection:(id)connection;
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
+ (id)newWithDictionary:(NSDictionary *)values inLibrary:(id)library;
- (int64_t)persistentID;
+ (id)newWithPersistentID:(int64_t)trackID inLibrary:(id)library;
+ (BOOL)trackWithPersistentID:(int64_t)trackID existsInLibrary:(id)library;
+ (NSSet<NSString *> *)unsettableProperties;
- (id)valueForProperty:(NSString *)property;
@end

@protocol MusicEditAPI
- (id)initWithLibrary:(id)library writer:(id)writer;
- (BOOL)_setValues:(NSArray *)values forProperties:(NSArray *)properties withEntityClass:(Class)entityClass usingPersistentID:(int64_t)trackID connection:(id)connection error:(NSError **)error;
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

// A private importer that refuses says nothing about which step refused, and
// the code alone has never been enough to tell them apart in a log. The step
// name is diagnostic and never shown: the user-facing sentence is fixed.
static void FailedStep(NSError **error, NSInteger code, NSString *step) {
    if (error) {
        *error = [NSError errorWithDomain:@"MusicLibrary" code:code userInfo:@{
            NSLocalizedDescriptionKey: [@"import failed at " stringByAppendingString:step]
        }];
    }
}

static NSString *Text(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return @"";
}

// This is fixed internal metadata, never caller-supplied KVC keys. Exceptions
// for an unavailable class or setter stay inside the Objective-C boundary.
static id ImportObject(NSString *className, NSDictionary *values) {
    id object = [NSClassFromString(className) new];
    if (!object) [NSException raise:NSInvalidArgumentException format:@"Missing %@", className];
    [object setValuesForKeysWithDictionary:values];
    return object;
}

@implementation NativeMusicLibrary {
    id _library;
    Class _trackClass;
    NSDictionary<NSString *, NSString *> *_properties;
}

- (instancetype)initWithExpectedDatabasePath:(NSString *)path error:(NSError **)error {
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
            || !Signature(class_getInstanceMethod(connectionClass, @selector(popToRootTransactionAndCommit:)), "B", @[@"@", @":", @"B"], error)) {
            if (error && !*error) Failure(error, 1);
            return nil;
        }
        _library = [(Class<MusicLibraryAPI>)libraryClass sharedLibrary];
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


- (NSNumber *)importFileAtPath:(NSString *)path metadata:(NSDictionary<NSString *, id> *)metadata error:(NSError **)error {
    NSNumber *committedIdentifier = nil;
    @try {
        Class sessionClass = NSClassFromString(@"ML3ClientImportServiceSession");
        Class itemClass = NSClassFromString(@"ML3ClientImportItem");
        Class baseClass = NSClassFromString(@"ML3BaseLocation");
        if (!Signature(class_getInstanceMethod(sessionClass, @selector(initWithLibrary:connection:configuration:)), "@", @[@"@", @":", @"@", @"@", @"@"], error)
            || !Signature(class_getInstanceMethod(sessionClass, @selector(begin)), "B", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(sessionClass, @selector(finish)), "B", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(sessionClass, @selector(addTrack:persistentID:)), "B", @[@"@", @":", @"@", @"^@"], error)
            || !Signature(class_getInstanceMethod(itemClass, @selector(initWithMultiverseIdentifier:mediaItem:)), "@", @[@"@", @":", @"@", @"@"], error)
            || !Signature(class_getClassMethod(baseClass, @selector(newWithDictionary:inLibrary:)), "@", @[@"@", @":", @"@", @"@"], error)) return nil;

        // MusicLibrary's importer owns artist/album
        // entities, sort orders and all schema-dependent insertion details.
        id configuration = ImportObject(@"ML3ClientImportSessionConfiguration", @{
            @"operationCount": @1, @"libraryPath": [(id<MusicLibraryAPI>)_library databasePath]
        });
        id artist = ImportObject(@"MIPArtist", @{@"name": metadata[@"Artist"] ?: @""});
        id albumArtist = ImportObject(@"MIPArtist", @{@"name": metadata[@"AlbumArtist"] ?: metadata[@"Artist"] ?: @""});
        id album = ImportObject(@"MIPAlbum", @{@"name": metadata[@"Album"] ?: @"", @"artist": albumArtist});
        id song = ImportObject(@"MIPSong", @{@"artist": artist, @"album": album});
        id media = ImportObject(@"MIPMediaItem", @{
            @"title": metadata[@"Title"], @"duration": metadata[@"TotalTime"],
            @"mediaType": @1, @"isInUsersLibrary": @YES, @"hasLocalAsset": @YES, @"song": song
        });
        id identity = ImportObject(@"MIPMultiverseIdentifier", @{
            @"mediaType": @1, @"mediaObjectType": @6, @"name": NSUUID.UUID.UUIDString
        });
        id item = [(id<MusicImportAPI>)[itemClass alloc] initWithMultiverseIdentifier:identity mediaItem:media];
        // A base location is relative to the device's Media folder. The native
        // constructor reuses that location across imports. It may remain empty
        // after a failed import, but no track or file is published by it.
        id<MusicTrackAPI> base = [(Class<MusicTrackAPI>)baseClass newWithDictionary:@{@"path": @"iTunes_Control/Music/F00"} inLibrary:_library];
        if (!item || !base) { FailedStep(error, 3, item ? @"base location" : @"import item"); return nil; }
        id<MusicConnectionAPI> connection = [(id<MusicLibraryAPI>)_library checkoutWriterConnection];
        @try {
            if (![connection pushTransaction]) { FailedStep(error, 3, @"push transaction"); return nil; }
            id<MusicImportAPI> importer = [(id<MusicImportAPI>)[sessionClass alloc] initWithLibrary:_library connection:connection configuration:configuration];
            NSNumber *identifier = nil;
            if (![importer begin]) { FailedStep(error, 3, @"begin"); return nil; }
            if (![importer addTrack:item persistentID:&identifier]) { FailedStep(error, 3, @"add track"); return nil; }
            if (![importer finish]) { FailedStep(error, 3, @"finish"); return nil; }
            if (!identifier) { FailedStep(error, 3, @"no persistent id"); return nil; }
            // The importer owns metadata; this connection-scoped native edit
            // attaches the already copied asset before committing. ML3Track's
            // convenience setters dispatch to a different writer and cannot
            // see the uncommitted track, even when passed this connection.
            id<MusicEditAPI> operation = [(id<MusicEditAPI>)[NSClassFromString(@"ML3SetValuesForPropertiesOperation") alloc] initWithLibrary:_library writer:nil];
            NSArray *values = @[@YES, @([base persistentID]), path.lastPathComponent, @1];
            if (![operation _setValues:values forProperties:@[@"in_my_library", @"base_location_id", @"item_extra.location", @"media_type"] withEntityClass:_trackClass usingPersistentID:identifier.longLongValue connection:connection error:error]) {
                if (error && !*error) FailedStep(error, 3, @"set values");
                return nil;
            }
            // A private API accepting a call is not proof it stored the fields.
            id<MusicResultAPI> result = [connection executeQuery:@"SELECT COUNT(*) FROM item JOIN item_extra USING(item_pid) WHERE item_pid = ? AND in_my_library = 1 AND (media_type & 1) != 0 AND base_location_id = ? AND location = ?" withParameters:@[identifier, @([base persistentID]), path.lastPathComponent]];
            if ([[result objectForFirstRowAndColumn] longLongValue] != 1) {
                FailedStep(error, 3, @"row not stored");
                return nil;
            }
            if (![connection popTransactionAndCommit:YES]) {
                FailedStep(error, 3, @"commit");
                return nil;
            }
            committedIdentifier = identifier;
        } @finally {
            @try {
                if ([connection isInTransaction]) [connection popToRootTransactionAndCommit:NO];
            } @finally {
                if (connection) [(id<MusicLibraryAPI>)_library checkInDatabaseConnection:connection];
            }
        }
        [(id<MusicLibraryAPI>)_library notifyEntitiesAddedOrRemoved];
    } @catch (NSException *exception) {
        if (!committedIdentifier && error) {
            *error = [NSError errorWithDomain:@"MusicLibrary" code:3 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"MusicLibrary import: %@: %@", exception.name, exception.reason]
            }];
        }
    }
    // Once committed, even a notification/connection-cleanup exception must
    // preserve the file now referenced by the library.
    return committedIdentifier;
}

@end
