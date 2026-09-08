#import "NativeMusicLibrary.h"
#import <objc/runtime.h>
#include <dlfcn.h>

@protocol MusicImportAPI
- (id)initWithMultiverseIdentifier:(id)identifier mediaItem:(id)item;
- (id)initWithConfiguration:(id)configuration delegate:(id)delegate;
- (BOOL)start;
- (BOOL)finish;
- (BOOL)cancel;
- (id)addItemsReturningResult:(NSArray *)items;
- (id)removeItemsReturningResult:(NSArray *)items;
@end

@protocol MusicImportResultAPI
- (BOOL)success;
- (NSDictionary *)resultingDatabasePersistentIDs;
@end

@protocol MusicArtworkTokenAPI
- (id)initWithEntity:(id)entity artworkType:(int64_t)artworkType;
- (NSString *)artworkTokenForSource:(int64_t)source;
@end

@protocol MusicLibraryAPI
+ (id)sharedLibrary;
- (NSString *)databasePath;
- (void)notifyEntitiesAddedOrRemoved;
- (BOOL)importOriginalArtworkFromImageData:(NSData *)data
                          withArtworkToken:(NSString *)token
                               artworkType:(int64_t)artworkType
                                sourceType:(int64_t)sourceType
                                 mediaType:(uint32_t)mediaType;
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
- (BOOL)setValue:(id)value forProperty:(NSString *)property;
- (void)populateLocationPropertiesWithPath:(NSString *)path;
- (NSString *)absoluteFilePath;
- (id)multiverseIdentifierLibraryOnly:(BOOL)libraryOnly;
@end

@protocol MusicEditAPI
- (id)initWithLibrary:(id)library writer:(id)writer;
- (BOOL)_setValues:(NSArray *)values
     forProperties:(NSArray *)properties
   withEntityClass:(Class)entityClass
 usingPersistentID:(int64_t)trackID
        connection:(id)connection
             error:(NSError **)error;
@end


static BOOL Signature(Method method, const char *result, NSArray<NSString *> *arguments, NSError **error) {
    if (!method || method_getNumberOfArguments(method) != arguments.count) {
        if (error) *error = [NSError errorWithDomain:@"MusicLibrary" code:1 userInfo:@{
            NSLocalizedDescriptionKey:
                @"A required MusicLibrary method is missing or has an unsupported argument count."
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
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unsupported MusicLibrary signature: %@ (%s).",
                                    NSStringFromSelector(method_getName(method)),
                                    method_getTypeEncoding(method)]
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

// These hints were added after the original client importer. Older systems
// already add local items and choose their own artwork source. Required
// metadata still goes through ImportObject and must never be silently skipped.
static void OptionalImportValue(id object, NSString *key, id value) {
    NSString *setter = [NSString stringWithFormat:@"set%@%@:",
                        [key substringToIndex:1].uppercaseString, [key substringFromIndex:1]];
    if ([object respondsToSelector:NSSelectorFromString(setter)]) {
        [object setValue:value forKey:key];
    }
}

// The legacy importer registers source 0; newer importers honor our source 500
// hint. Resolve the token actually registered, rather than assuming that a
// supported setter implies the service used it.
static NSNumber *ArtworkSource(id entity, NSString *token, int64_t artworkType) {
    id<MusicArtworkTokenAPI> tokens = [(id<MusicArtworkTokenAPI>)[NSClassFromString(@"ML3ArtworkTokenSet") alloc]
                                     initWithEntity:entity artworkType:artworkType];
    for (NSNumber *source in @[@500, @0]) {
        if ([[tokens artworkTokenForSource:source.longLongValue] isEqualToString:token]) return source;
    }
    return nil;
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
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"MusicLibrary opened %@ instead of %@.", actual, path]
            }];
            return nil;
        }
        NSMutableDictionary *properties = [NSMutableDictionary dictionary];
        NSMutableSet *editable = [NSMutableSet set];
        NSSet *unsettable = [(Class<MusicTrackAPI>)_trackClass unsettableProperties];
        for (NSString *field in @[@"Title", @"Artist", @"Album", @"AlbumArtist", @"Genre", @"Composer",
                                  @"Year", @"TrackNumber", @"DiscNumber", @"Comment"]) {
            NSString *symbol = [@"ML3TrackProperty" stringByAppendingString:field];
            NSString * __unsafe_unretained const *property =
                (NSString * __unsafe_unretained const *)dlsym(image, symbol.UTF8String);
            if (!property || ![*property isKindOfClass:NSString.class]) {
                if (error) *error = [NSError errorWithDomain:@"MusicLibrary" code:1 userInfo:@{
                    NSLocalizedDescriptionKey:
                        [@"MusicLibrary property is unavailable: " stringByAppendingString:symbol]
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
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"MusicLibrary initialization: %@: %@",
                                        exception.name,
                                        exception.reason]
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

- (BOOL)setValue:(id)value
        forField:(NSString *)field
         trackID:(int64_t)trackID
        expected:(NSString *)expected
           error:(NSError **)error {
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
        NSString *query = [NSString stringWithFormat:
            @"SELECT COALESCE(CAST(%@ AS TEXT), '') FROM item JOIN item_extra USING(item_pid) WHERE item.item_pid = ?",
            column];
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
            id<MusicEditAPI> operation =
                [(id<MusicEditAPI>)[NSClassFromString(@"ML3SetValuesForPropertiesOperation") alloc]
                    initWithLibrary:_library
                    writer:nil];
            if (![operation _setValues:@[value]
                         forProperties:@[property]
                       withEntityClass:_trackClass
                     usingPersistentID:trackID
                            connection:connection
                                 error:error]) {
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


- (NSNumber *)importFileAtPath:(NSString *)path
                      metadata:(NSDictionary<NSString *, id> *)metadata
                         error:(NSError **)error {
    id<MusicImportAPI> importer = nil;
    NSNumber *identifier = nil;
    BOOL attemptedAdd = NO;
    BOOL finished = NO;
    @try {
        Class sessionClass = NSClassFromString(@"ML3ClientImportSession");
        Class itemClass = NSClassFromString(@"ML3ClientImportItem");
        Class resultClass = NSClassFromString(@"ML3ClientImportResult");
        if (!Signature(class_getInstanceMethod(sessionClass, @selector(initWithConfiguration:delegate:)), "@", @[@"@", @":", @"@", @"@"], error)
            || !Signature(class_getInstanceMethod(sessionClass, @selector(start)), "B", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(sessionClass, @selector(finish)), "B", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(sessionClass, @selector(cancel)), "B", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(sessionClass, @selector(addItemsReturningResult:)), "@", @[@"@", @":", @"@"], error)
            || !Signature(class_getInstanceMethod(itemClass, @selector(initWithMultiverseIdentifier:mediaItem:)), "@", @[@"@", @":", @"@", @"@"], error)
            || !Signature(class_getInstanceMethod(resultClass, @selector(success)), "B", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(resultClass, @selector(resultingDatabasePersistentIDs)), "@", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(_trackClass, @selector(populateLocationPropertiesWithPath:)), "v", @[@"@", @":", @"@"], error)
            || !Signature(class_getInstanceMethod(_trackClass, @selector(setValue:forProperty:)), "B", @[@"@", @":", @"@", @"@"], error)
            || !Signature(class_getInstanceMethod(_trackClass, @selector(absoluteFilePath)), "@", @[@"@", @":"], error)
            || (metadata[@"Artwork"] && !Signature(class_getInstanceMethod(NSClassFromString(@"ML3ArtworkTokenSet"), @selector(initWithEntity:artworkType:)), "@", @[@"@", @":", @"@", @"q"], error))
            || (metadata[@"Artwork"] && !Signature(class_getInstanceMethod(NSClassFromString(@"ML3ArtworkTokenSet"), @selector(artworkTokenForSource:)), "@", @[@"@", @":", @"q"], error))
            || (metadata[@"Artwork"] && !Signature(class_getClassMethod(NSClassFromString(@"ML3Album"), @selector(newWithPersistentID:inLibrary:)), "@", @[@"@", @":", @"q", @"@"], error))
            || (metadata[@"Artwork"] && !Signature(class_getInstanceMethod([_library class], @selector(importOriginalArtworkFromImageData:withArtworkToken:artworkType:sourceType:mediaType:)), "B", @[@"@", @":", @"@", @"@", @"q", @"q", @"I"], error))) return nil;

        NSString *__unsafe_unretained *albumProperty = metadata[@"Artwork"]
            ? (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, "ML3TrackPropertyAlbumPersistentID") : NULL;
        if (metadata[@"Artwork"] && !albumProperty) { FailedStep(error, 1, @"album property"); return nil; }
        NSString *__unsafe_unretained *membershipProperty =
            (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, "ML3TrackPropertyIsInMyLibrary");
        NSString *__unsafe_unretained *dateAddedProperty =
            (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, "ML3TrackPropertyDateAdded");
        if (!membershipProperty || !dateAddedProperty) { FailedStep(error, 1, @"library membership properties"); return nil; }

        id configuration = ImportObject(@"ML3ClientImportSessionConfiguration", @{
            @"operationCount": @1,
            @"libraryPath": [(id<MusicLibraryAPI>)_library databasePath]
        });
        OptionalImportValue(configuration, @"shouldLibraryAdd", @YES);
        NSMutableDictionary *artistValues = [@{@"name": metadata[@"Artist"] ?: @""} mutableCopy];
        if (metadata[@"SortArtist"]) artistValues[@"sortName"] = metadata[@"SortArtist"];
        id artist = ImportObject(@"MIPArtist", artistValues);
        NSMutableDictionary *albumArtistValues =
            [@{@"name": metadata[@"AlbumArtist"] ?: metadata[@"Artist"] ?: @""} mutableCopy];
        if (metadata[@"SortAlbumArtist"]) albumArtistValues[@"sortName"] = metadata[@"SortAlbumArtist"];
        id albumArtist = ImportObject(@"MIPArtist", albumArtistValues);
        NSMutableDictionary *albumValues = [@{@"name": metadata[@"Album"] ?: @"", @"artist": albumArtist} mutableCopy];
        NSDictionary *albumFields = @{
            @"SortAlbum": @"sortName", @"TrackCount": @"numTracks",
            @"DiscCount": @"numDiscs", @"Compilation": @"compilation"
        };
        for (NSString *key in albumFields) if (metadata[key]) albumValues[albumFields[key]] = metadata[key];
        // Give both entities the same unique token; resolve the source chosen
        // by the importer before publishing the original artwork.
        NSString *artworkToken = metadata[@"Artwork"] ? NSUUID.UUID.UUIDString : nil;
        if (artworkToken) albumValues[@"artworkId"] = artworkToken;
        id album = ImportObject(@"MIPAlbum", albumValues);
        if (artworkToken) OptionalImportValue(album, @"artworkSourceType", @500);
        NSMutableDictionary *songValues = [@{@"artist": artist, @"album": album} mutableCopy];
        NSDictionary *songFields = @{
            @"Lyrics": @"lyrics", @"TrackNumber": @"trackNumber", @"DiscNumber": @"discNumber"
        };
        for (NSString *key in songFields) if (metadata[key]) songValues[songFields[key]] = metadata[key];
        if (metadata[@"Composer"]) {
            NSMutableDictionary *composer = [@{@"name": metadata[@"Composer"]} mutableCopy];
            if (metadata[@"SortComposer"]) composer[@"sortName"] = metadata[@"SortComposer"];
            songValues[@"composer"] = ImportObject(@"MIPArtist", composer);
        }
        if (metadata[@"Genre"]) songValues[@"genre"] = ImportObject(@"MIPGenre", @{@"name": metadata[@"Genre"]});
        id song = ImportObject(@"MIPSong", songValues);
        NSMutableDictionary *mediaValues = [@{
            @"title": metadata[@"Title"], @"duration": metadata[@"TotalTime"],
            @"mediaType": @1, @"isInUsersLibrary": @YES, @"song": song
        } mutableCopy];
        NSDictionary *mediaFields = @{
            @"SortTitle": @"sortTitle", @"Year": @"year", @"Comment": @"comment",
            @"Copyright": @"copyright", @"ReleaseDateTime": @"releaseDateTime"
        };
        for (NSString *key in mediaFields) if (metadata[key]) mediaValues[mediaFields[key]] = metadata[key];
        if (artworkToken) mediaValues[@"artworkId"] = artworkToken;
        id media = ImportObject(@"MIPMediaItem", mediaValues);
        if (artworkToken) OptionalImportValue(media, @"artworkSourceType", @500);
        id identity = ImportObject(@"MIPMultiverseIdentifier", @{
            @"mediaType": @1, @"mediaObjectType": @6, @"name": NSUUID.UUID.UUIDString
        });
        id item = [(id<MusicImportAPI>)[itemClass alloc] initWithMultiverseIdentifier:identity mediaItem:media];
        importer = [(id<MusicImportAPI>)[sessionClass alloc] initWithConfiguration:configuration delegate:nil];
        if (!item || !importer) { FailedStep(error, 3, @"client session creation"); return nil; }
        // The client owns the XPC conversation. Its service-side counterpart
        // cannot run against checkoutWriterConnection's distant connection.
        if (![importer start]) { FailedStep(error, 3, @"client session start"); return nil; }
        attemptedAdd = YES;
        id<MusicImportResultAPI> result = [importer addItemsReturningResult:@[item]];
        if (![result success]) { FailedStep(error, 3, @"client add items"); return nil; }
        NSDictionary *identifiers = [result resultingDatabasePersistentIDs];
        if (identifiers.count == 1 && [identifiers.allValues.firstObject isKindOfClass:NSNumber.class]) {
            identifier = identifiers.allValues.firstObject;
        }
        if (!identifier || identifier.longLongValue == 0) { FailedStep(error, 3, @"client persistent id"); return nil; }
        if (![importer finish]) { FailedStep(error, 3, @"client session finish"); return nil; }
        finished = YES;
        id<MusicTrackAPI> track = [self track:identifier.longLongValue error:error];
        // Let MusicLibrary resolve the asset's base location and file metadata.
        // No private table names or hand-built location identifiers are needed.
        if (!track) return nil;
        // The client importer does not persist the MIPSong lyrics body. Use
        // the track's native property writer and verify the saved text.
        if (metadata[@"Lyrics"]) {
            NSString *__unsafe_unretained *symbol =
                (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, "ML3TrackPropertyLyrics");
            NSString *property = symbol ? *symbol : nil;
            if (!property || ![track setValue:metadata[@"Lyrics"] forProperty:property]
                || ![[track valueForProperty:property] isEqual:metadata[@"Lyrics"]]) {
                FailedStep(error, 3, @"save lyrics");
                return nil;
            }
        }
        [track populateLocationPropertiesWithPath:path];
        NSString *attachedPath = [track absoluteFilePath];
        if (![attachedPath.stringByResolvingSymlinksInPath isEqualToString:path.stringByResolvingSymlinksInPath]) {
            FailedStep(error, 3, @"verify local audio location");
            return nil;
        }
        if (artworkToken) {
            // populateArtworkCacheWithArtworkData: only looks up source 500,
            // even on iOS 18 where the client importer registers source 0.
            NSNumber *source = ArtworkSource(track, artworkToken, 1);
            if (!source) { FailedStep(error, 3, @"resolve cover artwork token"); return nil; }
            if (![(id<MusicLibraryAPI>)_library importOriginalArtworkFromImageData:metadata[@"Artwork"]
                withArtworkToken:artworkToken artworkType:1 sourceType:source.longLongValue mediaType:1]) {
                FailedStep(error, 3, @"import cover artwork");
                return nil;
            }
            int64_t albumID = [[track valueForProperty:*albumProperty] longLongValue];
            id album = albumID ? [(Class<MusicTrackAPI>)NSClassFromString(@"ML3Album") newWithPersistentID:albumID inLibrary:_library] : nil;
            NSNumber *albumSource = albumID ? ArtworkSource(album, artworkToken, 6) : nil;
            // Older importers only register track artwork; albums use their
            // representative track. Cache a separate album image only when
            // the importer actually attached our token to that album.
            if (albumSource && ![(id<MusicLibraryAPI>)_library importOriginalArtworkFromImageData:metadata[@"Artwork"]
                withArtworkToken:artworkToken artworkType:6 sourceType:albumSource.longLongValue mediaType:1]) {
                FailedStep(error, 3, @"import album artwork");
                return nil;
            }
        }
        // Older client importers accept isInUsersLibrary but leave membership
        // false. Publish the complete local song through native property writes,
        // including the date used by Music's Recently Added view.
        if (![[track valueForProperty:*dateAddedProperty] doubleValue]
            && ![track setValue:@(NSDate.timeIntervalSinceReferenceDate) forProperty:*dateAddedProperty]) {
            FailedStep(error, 3, @"save date added");
            return nil;
        }
        if (![[track valueForProperty:*membershipProperty] boolValue]
            && ![track setValue:@YES forProperty:*membershipProperty]) {
            FailedStep(error, 3, @"add to music library");
            return nil;
        }
        id<MusicTrackAPI> saved = [self track:identifier.longLongValue error:error];
        if (!saved || ![[saved valueForProperty:*membershipProperty] boolValue]
            || [[saved valueForProperty:*dateAddedProperty] doubleValue] <= 0) {
            FailedStep(error, 3, @"verify music library membership");
            return nil;
        }
        [(id<MusicLibraryAPI>)_library notifyEntitiesAddedOrRemoved];
        return identifier;
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"MusicLibrary" code:3 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"MusicLibrary import: %@: %@",
                                        exception.name,
                                        exception.reason]
        }];
        return nil;
    } @finally {
        if (!finished) {
            @try { [importer cancel]; } @catch (NSException *exception) { }
        }
        // A disconnected client cannot prove whether the service committed.
        // Never delete audio which may already be referenced by a library row.
        if (attemptedAdd && error && *error) {
            NSMutableDictionary *info = [(*error).userInfo mutableCopy];
            info[@"PreserveImportedFile"] = @YES;
            *error = [NSError errorWithDomain:(*error).domain code:(*error).code userInfo:info];
        }
    }
}

- (BOOL)deleteTrackID:(int64_t)trackID error:(NSError **)error {
    id<MusicImportAPI> session = nil;
    BOOL finished = NO;
    @try {
        Class sessionClass = NSClassFromString(@"ML3ClientImportSession");
        Class itemClass = NSClassFromString(@"ML3ClientImportItem");
        Class resultClass = NSClassFromString(@"ML3ClientImportResult");
        if (!Signature(class_getInstanceMethod(sessionClass, @selector(initWithConfiguration:delegate:)), "@", @[@"@", @":", @"@", @"@"], error)
            || !Signature(class_getInstanceMethod(sessionClass, @selector(start)), "B", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(sessionClass, @selector(finish)), "B", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(sessionClass, @selector(cancel)), "B", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(sessionClass, @selector(removeItemsReturningResult:)), "@", @[@"@", @":", @"@"], error)
            || !Signature(class_getInstanceMethod(itemClass, @selector(initWithMultiverseIdentifier:mediaItem:)), "@", @[@"@", @":", @"@", @"@"], error)
            || !Signature(class_getInstanceMethod(resultClass, @selector(success)), "B", @[@"@", @":"], error)
            || !Signature(class_getInstanceMethod(_trackClass, @selector(multiverseIdentifierLibraryOnly:)), "@", @[@"@", @":", @"B"], error)) return NO;
        id<MusicTrackAPI> track = [self track:trackID error:error];
        if (!track) return NO;
        // Match this library's persistent ID, never a title or shared store ID.
        id identity = [track multiverseIdentifierLibraryOnly:YES];
        if (!identity) { FailedStep(error, 3, @"delete identity"); return NO; }
        id item = [(id<MusicImportAPI>)[itemClass alloc] initWithMultiverseIdentifier:identity mediaItem:nil];
        id configuration = ImportObject(@"ML3ClientImportSessionConfiguration", @{
            @"operationCount": @1, @"libraryPath": [(id<MusicLibraryAPI>)_library databasePath]
        });
        session = [(id<MusicImportAPI>)[sessionClass alloc] initWithConfiguration:configuration delegate:nil];
        if (!item || ![session start]) { FailedStep(error, 3, @"delete session start"); return NO; }
        id<MusicImportResultAPI> result = [session removeItemsReturningResult:@[item]];
        if (![result success]) { FailedStep(error, 3, @"delete item"); return NO; }
        if (![session finish]) { FailedStep(error, 3, @"delete session finish"); return NO; }
        finished = YES;
        [(id<MusicLibraryAPI>)_library notifyEntitiesAddedOrRemoved];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"MusicLibrary" code:3 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"MusicLibrary delete: %@: %@",
                                        exception.name,
                                        exception.reason]
        }];
        return NO;
    } @finally {
        if (!finished) {
            @try { [session cancel]; } @catch (NSException *exception) { }
        }
    }
}

@end
