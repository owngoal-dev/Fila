// Run with Scripts/test-music-import.sh. Exercise the production KVC boundary
// with old/new runtime shapes; no MusicLibrary framework or database is opened.
#import "../Packages/FilaKit/Sources/CFilaMusicLibrary/NativeMusicLibrary.m"

@interface LegacyImportHints : NSObject
@property(nonatomic) NSUInteger operationCount;
@end
@implementation LegacyImportHints
@end

@interface ModernImportHints : LegacyImportHints
@property(nonatomic) BOOL shouldLibraryAdd;
@property(nonatomic) int artworkSourceType;
@end
@implementation ModernImportHints
@end

@interface RefusingImportHints : NSObject
- (void)setShouldLibraryAdd:(BOOL)value;
@end
@implementation RefusingImportHints
- (void)setShouldLibraryAdd:(BOOL)value {
    [NSException raise:NSInvalidArgumentException format:@"Setter rejected value"];
}
@end

@interface ML3ArtworkTokenSet : NSObject <MusicArtworkTokenAPI>
@property(nonatomic, copy) NSDictionary *tokens;
@end
@implementation ML3ArtworkTokenSet
- (id)initWithEntity:(id)entity artworkType:(int64_t)artworkType {
    self = [super init];
    if (self) _tokens = [entity copy];
    return self;
}
- (NSString *)artworkTokenForSource:(int64_t)source { return self.tokens[@(source)]; }
@end

@interface ExportTrack : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic) BOOL allowsDeletion;
@property(nonatomic) NSUInteger deletionCount;
@end
@implementation ExportTrack
- (NSString *)absoluteFilePath { return self.path; }
- (BOOL)deleteFromLibrary { self.deletionCount++; return self.allowsDeletion; }
@end

@interface ExportLibrary : NativeMusicLibrary
@property(nonatomic) ExportTrack *exportTrack;
@end
@implementation ExportLibrary
- (id<MusicTrackAPI>)track:(int64_t)trackID error:(NSError **)error {
    return (id<MusicTrackAPI>)self.exportTrack;
}
@end

int main(void) {
    @autoreleasepool {
        id legacy = ImportObject(@"LegacyImportHints", @{@"operationCount": @1});
        OptionalImportValue(legacy, @"shouldLibraryAdd", @YES);
        OptionalImportValue(legacy, @"artworkSourceType", @500);
        NSCAssert([legacy operationCount] == 1, @"Required configuration must survive legacy hints");

        ModernImportHints *modern = ImportObject(@"ModernImportHints", @{@"operationCount": @1});
        OptionalImportValue(modern, @"shouldLibraryAdd", @YES);
        OptionalImportValue(modern, @"artworkSourceType", @500);
        NSCAssert(modern.shouldLibraryAdd && modern.artworkSourceType == 500,
                  @"Modern runtimes must receive both hints");

        BOOL rejected = NO;
        @try { ImportObject(@"LegacyImportHints", @{@"requiredButMissing": @1}); }
        @catch (NSException *exception) { rejected = [exception.name isEqual:NSUndefinedKeyException]; }
        NSCAssert(rejected, @"Missing required fields must remain failures");

        rejected = NO;
        @try { OptionalImportValue([RefusingImportHints new], @"shouldLibraryAdd", @YES); }
        @catch (NSException *exception) { rejected = [exception.name isEqual:NSInvalidArgumentException]; }
        NSCAssert(rejected, @"An available setter's failure must not be swallowed");

        NSCAssert([ArtworkSource(@{@0: @"our-cover"}, @"our-cover", 1) isEqual:@0],
                  @"Legacy imports must use their registered source, not source 500");
        NSCAssert([ArtworkSource(@{@500: @"our-cover"}, @"our-cover", 1) isEqual:@500],
                  @"Modern imports must keep their registered source");
        NSCAssert([ArtworkSource(@{@500: @"another-cover", @0: @"our-cover"}, @"our-cover", 1) isEqual:@0],
                  @"Another token at source 500 must not hide our source 0 token");
        NSCAssert(ArtworkSource(@{@500: @"another-cover"}, @"our-cover", 6) == nil,
                  @"An existing album's unrelated cover must not be overwritten");
        NSCAssert(ArtworkSource(@{}, @"our-cover", 6) == nil,
                  @"Legacy albums without a separate token use their representative track");
        ExportLibrary *library = [ExportLibrary new];
        [library setValue:ExportTrack.class forKey:@"trackClass"];
        library.exportTrack = [ExportTrack new];
        library.exportTrack.path = @"/var/mobile/Media/song.m4a";
        NSCAssert([[library localPathForTrackID:1 error:nil] isEqual:library.exportTrack.path],
                  @"Export must use the library's resolved audio path");
        for (NSString *invalid in @[@"", @"relative/song.m4a", @"/var/mobile/Media/song\0.m4a"]) {
            library.exportTrack.path = invalid;
            NSError *error = nil;
            NSCAssert([library localPathForTrackID:1 error:&error] == nil && error != nil,
                      @"Export must reject missing, relative and NUL-containing paths");
        }
        library.exportTrack.allowsDeletion = YES;
        NSCAssert([library deleteTrackID:1 error:nil] && library.exportTrack.deletionCount == 1,
                  @"Deletion must call the resolved single entity once");
        library.exportTrack.allowsDeletion = NO;
        NSError *deletionError = nil;
        NSCAssert(![library deleteTrackID:1 error:&deletionError] && deletionError != nil,
                  @"A refused native deletion must remain a failure");
        library.exportTrack = nil;
        NSCAssert(![library deleteTrackID:1 error:nil], @"A missing entity must not be deleted");
        puts("Music import compatibility tests passed");
    }
    return 0;
}
