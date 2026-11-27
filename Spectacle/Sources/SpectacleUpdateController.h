#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const SpectacleUpdateControllerDidChangeStateNotification;

@interface SpectacleUpdateController : NSObject

+ (instancetype)sharedController;

@property (nonatomic, assign) BOOL automaticallyChecksForUpdates;
@property (nonatomic, readonly, strong, nullable) NSDate *lastUpdateCheckDate;
@property (nonatomic, readonly, copy, nullable) NSString *statusMessage;
@property (nonatomic, readonly, assign) BOOL isBusy;

- (void)startAutomaticUpdateChecksIfEnabled;
- (void)checkForUpdatesInitiatedByUser:(BOOL)userInitiated;

+ (BOOL)isVersion:(NSString *)remoteVersion newerThanVersion:(NSString *)localVersion;

@end

NS_ASSUME_NONNULL_END
