#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C owns the private API calls so its exceptions never unwind Swift.
@interface NativeMusicLibrary : NSObject
@property (nonatomic, readonly) NSSet<NSString *> *editableFields;
- (nullable instancetype)initWithExpectedDatabasePath:(NSString *)path error:(NSError **)error;
- (nullable NSDictionary<NSString *, NSString *> *)valuesForTrackID:(int64_t)trackID error:(NSError **)error;
- (BOOL)setValue:(id)value forField:(NSString *)field trackID:(int64_t)trackID expected:(NSString *)expected error:(NSError **)error;
- (nullable NSNumber *)importFileAtPath:(NSString *)path metadata:(NSDictionary<NSString *, id> *)metadata error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
