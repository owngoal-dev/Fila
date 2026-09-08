// Run with Scripts/test-music-import.sh. Exercise the production KVC boundary
// with old/new runtime shapes; no MusicLibrary framework or database is opened.
#import "../Fila/Services/Music/NativeMusicLibrary.m"

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
        puts("Music import compatibility tests passed");
    }
    return 0;
}
