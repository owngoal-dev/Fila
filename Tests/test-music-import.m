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
        puts("Music import compatibility tests passed");
    }
    return 0;
}
