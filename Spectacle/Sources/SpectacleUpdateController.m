#import "SpectacleUpdateController.h"

#import <CommonCrypto/CommonDigest.h>

#import "SpectacleUtilities.h"

NSString * const SpectacleUpdateControllerDidChangeStateNotification = @"SpectacleUpdateControllerDidChangeStateNotification";

static NSString * const SpectacleAutoUpdateDefaultsKey = @"AutomaticallyCheckForUpdates";
static NSString * const SpectacleLastUpdateCheckDefaultsKey = @"LastUpdateCheckDate";
static NSString * const SpectacleSkippedVersionDefaultsKey = @"SkippedUpdateVersion";

static NSString * const SpectacleGitHubLatestReleaseAPI = @"https://api.github.com/repos/streetdogg/spectacle/releases/latest";
static NSString * const SpectacleGitHubReleasesPageURL = @"https://github.com/streetdogg/spectacle/releases/latest";

static const NSTimeInterval SpectacleAutomaticCheckInterval = 24 * 60 * 60; // 24 hours
static const NSTimeInterval SpectacleLaunchCheckCooldown = 12 * 60 * 60;    // 12 hours

@interface SpectacleGitHubRelease : NSObject
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *releaseNotes;
@property (nonatomic, strong, nullable) NSURL *htmlURL;
@property (nonatomic, copy, nullable) NSString *zipAssetName;
@property (nonatomic, strong, nullable) NSURL *zipDownloadURL;
@property (nonatomic, strong, nullable) NSURL *checksumDownloadURL;
@end

@implementation SpectacleGitHubRelease
@end

@implementation SpectacleUpdateController
{
  NSTimer *_automaticCheckTimer;
  BOOL _isBusy;
  NSString *_statusMessage;
}

+ (instancetype)sharedController
{
  static SpectacleUpdateController *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [SpectacleUpdateController new];
  });
  return sharedInstance;
}

- (void)dealloc
{
  [_automaticCheckTimer invalidate];
}

#pragma mark - Preferences & State

- (BOOL)automaticallyChecksForUpdates
{
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  if ([defaults objectForKey:SpectacleAutoUpdateDefaultsKey] == nil) {
    return YES;
  }
  return [defaults boolForKey:SpectacleAutoUpdateDefaultsKey];
}

- (void)setAutomaticallyChecksForUpdates:(BOOL)automaticallyChecksForUpdates
{
  [NSUserDefaults.standardUserDefaults setBool:automaticallyChecksForUpdates forKey:SpectacleAutoUpdateDefaultsKey];
  if (automaticallyChecksForUpdates) {
    [self scheduleAutomaticCheckTimer];
  } else {
    [_automaticCheckTimer invalidate];
    _automaticCheckTimer = nil;
  }
  [self notifyStateChanged];
}

- (NSDate *)lastUpdateCheckDate
{
  return [NSUserDefaults.standardUserDefaults objectForKey:SpectacleLastUpdateCheckDefaultsKey];
}

- (void)setLastUpdateCheckDate:(NSDate *)date
{
  [NSUserDefaults.standardUserDefaults setObject:date forKey:SpectacleLastUpdateCheckDefaultsKey];
}

- (BOOL)isBusy
{
  return _isBusy;
}

- (NSString *)statusMessage
{
  return _statusMessage;
}

- (void)updateBusy:(BOOL)busy statusMessage:(NSString *)message
{
  dispatch_block_t work = ^{
    self->_isBusy = busy;
    self->_statusMessage = [message copy];
    [self notifyStateChanged];
  };
  if ([NSThread isMainThread]) {
    work();
  } else {
    dispatch_async(dispatch_get_main_queue(), work);
  }
}

- (void)notifyStateChanged
{
  [[NSNotificationCenter defaultCenter] postNotificationName:SpectacleUpdateControllerDidChangeStateNotification
                                                      object:self];
}

#pragma mark - Automatic Scheduling

- (void)startAutomaticUpdateChecksIfEnabled
{
  if (!self.automaticallyChecksForUpdates) {
    return;
  }
  [self scheduleAutomaticCheckTimer];

  NSDate *lastCheck = self.lastUpdateCheckDate;
  if (!lastCheck || [[NSDate date] timeIntervalSinceDate:lastCheck] >= SpectacleLaunchCheckCooldown) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (self.automaticallyChecksForUpdates) {
        [self checkForUpdatesInitiatedByUser:NO];
      }
    });
  }
}

- (void)scheduleAutomaticCheckTimer
{
  [_automaticCheckTimer invalidate];
  _automaticCheckTimer = [NSTimer scheduledTimerWithTimeInterval:SpectacleAutomaticCheckInterval
                                                          target:self
                                                        selector:@selector(automaticCheckTimerFired:)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (void)automaticCheckTimerFired:(NSTimer *)timer
{
  if (self.automaticallyChecksForUpdates) {
    [self checkForUpdatesInitiatedByUser:NO];
  }
}

#pragma mark - Version Comparison

+ (NSString *)normalizedVersionString:(NSString *)version
{
  NSString *trimmed = [version stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([trimmed hasPrefix:@"v"] || [trimmed hasPrefix:@"V"]) {
    trimmed = [trimmed substringFromIndex:1];
  }
  NSRange dashRange = [trimmed rangeOfString:@"-"];
  if (dashRange.location != NSNotFound) {
    trimmed = [trimmed substringToIndex:dashRange.location];
  }
  return trimmed;
}

+ (BOOL)isVersion:(NSString *)remoteVersion newerThanVersion:(NSString *)localVersion
{
  NSArray<NSString *> *remoteParts = [[self normalizedVersionString:remoteVersion] componentsSeparatedByString:@"."];
  NSArray<NSString *> *localParts = [[self normalizedVersionString:localVersion] componentsSeparatedByString:@"."];
  NSUInteger count = MAX(remoteParts.count, localParts.count);

  for (NSUInteger i = 0; i < count; i++) {
    NSInteger r = i < remoteParts.count ? [remoteParts[i] integerValue] : 0;
    NSInteger l = i < localParts.count ? [localParts[i] integerValue] : 0;
    if (r > l) {
      return YES;
    }
    if (r < l) {
      return NO;
    }
  }
  return NO;
}

#pragma mark - Check for Updates

- (void)checkForUpdatesInitiatedByUser:(BOOL)userInitiated
{
  if (_isBusy) {
    return;
  }

  [self updateBusy:YES statusMessage:NSLocalizedString(@"UpdateStatusChecking", @"Checking for updates status")];

  NSURL *url = [NSURL URLWithString:SpectacleGitHubLatestReleaseAPI];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                     timeoutInterval:20.0];
  [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
  NSString *userAgent = [NSString stringWithFormat:@"Spectacle/%@", SpectacleUtilities.applicationVersion ?: @"1.0"];
  [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];

  __weak typeof(self) weakSelf = self;
  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }

    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    if (error || !data || (httpResponse && httpResponse.statusCode != 200)) {
      [strongSelf updateBusy:NO statusMessage:nil];
      if (userInitiated) {
        NSString *detail = error.localizedDescription
          ?: [NSString stringWithFormat:@"GitHub returned HTTP %ld.", (long)(httpResponse ? httpResponse.statusCode : 0)];
        dispatch_async(dispatch_get_main_queue(), ^{
          [strongSelf presentErrorAlertWithTitle:NSLocalizedString(@"UpdateAlertErrorTitle", @"Update check failed title")
                                         message:detail];
        });
      }
      return;
    }

    NSError *jsonError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    SpectacleGitHubRelease *release = [parsed isKindOfClass:[NSDictionary class]]
      ? [strongSelf parseReleaseDictionary:(NSDictionary *)parsed]
      : nil;

    if (!release || release.version.length == 0) {
      [strongSelf updateBusy:NO statusMessage:nil];
      if (userInitiated) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [strongSelf presentErrorAlertWithTitle:NSLocalizedString(@"UpdateAlertErrorTitle", @"Update check failed title")
                                         message:jsonError.localizedDescription ?: NSLocalizedString(@"UpdateAlertInvalidResponse", @"Invalid GitHub response")];
        });
      }
      return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      [strongSelf setLastUpdateCheckDate:[NSDate date]];
      [strongSelf updateBusy:NO statusMessage:nil];

      NSString *currentVersion = SpectacleUtilities.applicationVersion ?: @"0.0.0";
      BOOL isNewer = [SpectacleUpdateController isVersion:release.version newerThanVersion:currentVersion];

      if (!isNewer) {
        if (userInitiated) {
          [strongSelf presentUpToDateAlertWithCurrentVersion:currentVersion];
        }
        return;
      }

      if (!userInitiated) {
        NSString *skippedVersion = [NSUserDefaults.standardUserDefaults stringForKey:SpectacleSkippedVersionDefaultsKey];
        if ([skippedVersion isEqualToString:release.version]) {
          return;
        }
      }

      [strongSelf presentUpdateAvailableAlertForRelease:release currentVersion:currentVersion];
    });
  }];
  [task resume];
}

- (SpectacleGitHubRelease *)parseReleaseDictionary:(NSDictionary *)dict
{
  NSString *tagName = [dict[@"tag_name"] isKindOfClass:[NSString class]] ? dict[@"tag_name"] : nil;
  if (tagName.length == 0) {
    return nil;
  }

  SpectacleGitHubRelease *release = [SpectacleGitHubRelease new];
  release.version = [SpectacleUpdateController normalizedVersionString:tagName];
  release.releaseNotes = [dict[@"body"] isKindOfClass:[NSString class]] ? dict[@"body"] : @"";

  NSString *htmlURLString = [dict[@"html_url"] isKindOfClass:[NSString class]] ? dict[@"html_url"] : SpectacleGitHubReleasesPageURL;
  release.htmlURL = [NSURL URLWithString:htmlURLString];

  NSArray *assets = [dict[@"assets"] isKindOfClass:[NSArray class]] ? dict[@"assets"] : @[];
  NSURL *fallbackZipURL = nil;
  NSString *fallbackZipName = nil;

  for (id item in assets) {
    if (![item isKindOfClass:[NSDictionary class]]) {
      continue;
    }
    NSString *name = [item[@"name"] isKindOfClass:[NSString class]] ? item[@"name"] : nil;
    NSString *downloadString = [item[@"browser_download_url"] isKindOfClass:[NSString class]] ? item[@"browser_download_url"] : nil;
    if (!name || !downloadString) {
      continue;
    }
    NSURL *downloadURL = [NSURL URLWithString:downloadString];
    if (!downloadURL) {
      continue;
    }
    if ([name isEqualToString:@"SHA256SUMS.txt"]) {
      release.checksumDownloadURL = downloadURL;
    } else if ([name hasSuffix:@"arm64.zip"]) {
      release.zipAssetName = name;
      release.zipDownloadURL = downloadURL;
    } else if ([name hasSuffix:@".zip"] && !fallbackZipURL) {
      fallbackZipName = name;
      fallbackZipURL = downloadURL;
    }
  }

  if (!release.zipDownloadURL && fallbackZipURL) {
    release.zipAssetName = fallbackZipName;
    release.zipDownloadURL = fallbackZipURL;
  }

  return release;
}

#pragma mark - Alerts

- (void)activateApplication
{
  if (@available(macOS 14.0, *)) {
    [NSApp activate];
  } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
  }
}

- (void)presentUpToDateAlertWithCurrentVersion:(NSString *)currentVersion
{
  [self activateApplication];
  NSAlert *alert = [NSAlert new];
  alert.alertStyle = NSAlertStyleInformational;
  alert.messageText = NSLocalizedString(@"UpdateAlertUpToDateTitle", @"Up to date alert title");
  alert.informativeText = [NSString stringWithFormat:NSLocalizedString(@"UpdateAlertUpToDateFormat", @"Up to date alert body"), currentVersion];
  [alert addButtonWithTitle:NSLocalizedString(@"ButtonLabelAffirmative", @"OK")];
  [alert runModal];
}

- (void)presentErrorAlertWithTitle:(NSString *)title message:(NSString *)message
{
  [self activateApplication];
  NSAlert *alert = [NSAlert new];
  alert.alertStyle = NSAlertStyleWarning;
  alert.messageText = title;
  alert.informativeText = message ?: @"";
  [alert addButtonWithTitle:NSLocalizedString(@"ButtonLabelAffirmative", @"OK")];
  [alert addButtonWithTitle:NSLocalizedString(@"UpdateButtonViewOnGitHub", @"View on GitHub button")];
  if ([alert runModal] == NSAlertSecondButtonReturn) {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:SpectacleGitHubReleasesPageURL]];
  }
}

- (void)presentUpdateAvailableAlertForRelease:(SpectacleGitHubRelease *)release currentVersion:(NSString *)currentVersion
{
  [self activateApplication];
  NSAlert *alert = [NSAlert new];
  alert.alertStyle = NSAlertStyleInformational;
  alert.messageText = [NSString stringWithFormat:NSLocalizedString(@"UpdateAlertAvailableTitleFormat", @"Update available title"), release.version];
  alert.informativeText = [NSString stringWithFormat:NSLocalizedString(@"UpdateAlertAvailableBodyFormat", @"Update available body"), release.version, currentVersion];

  BOOL canAutoInstall = (release.zipDownloadURL != nil);
  if (canAutoInstall) {
    [alert addButtonWithTitle:NSLocalizedString(@"UpdateButtonInstallAndRelaunch", @"Install & Relaunch button")];
    [alert addButtonWithTitle:NSLocalizedString(@"UpdateButtonLater", @"Later button")];
    [alert addButtonWithTitle:NSLocalizedString(@"UpdateButtonViewOnGitHub", @"View on GitHub button")];
    [alert addButtonWithTitle:NSLocalizedString(@"UpdateButtonSkipVersion", @"Skip This Version button")];
  } else {
    [alert addButtonWithTitle:NSLocalizedString(@"UpdateButtonViewOnGitHub", @"View on GitHub button")];
    [alert addButtonWithTitle:NSLocalizedString(@"UpdateButtonLater", @"Later button")];
  }

  NSModalResponse response = [alert runModal];
  if (canAutoInstall) {
    if (response == NSAlertFirstButtonReturn) {
      [self downloadAndInstallRelease:release];
    } else if (response == NSAlertThirdButtonReturn) {
      if (release.htmlURL) {
        [[NSWorkspace sharedWorkspace] openURL:release.htmlURL];
      }
    } else if (response == NSAlertThirdButtonReturn + 1) {
      [NSUserDefaults.standardUserDefaults setObject:release.version forKey:SpectacleSkippedVersionDefaultsKey];
    }
  } else if (response == NSAlertFirstButtonReturn && release.htmlURL) {
    [[NSWorkspace sharedWorkspace] openURL:release.htmlURL];
  }
}

#pragma mark - Download, Verify & Install

- (void)downloadAndInstallRelease:(SpectacleGitHubRelease *)release
{
  NSString *targetAppPath = NSBundle.mainBundle.bundlePath;
  NSString *parentDir = [targetAppPath stringByDeletingLastPathComponent];
  if (![targetAppPath hasSuffix:@".app"] || ![[NSFileManager defaultManager] isWritableFileAtPath:parentDir]) {
    [self presentErrorAlertWithTitle:NSLocalizedString(@"UpdateAlertCannotReplaceTitle", @"Cannot replace app title")
                             message:NSLocalizedString(@"UpdateAlertCannotReplaceBody", @"Cannot replace app body")];
    return;
  }

  [self updateBusy:YES statusMessage:[NSString stringWithFormat:NSLocalizedString(@"UpdateStatusDownloadingFormat", @"Downloading status"), release.version]];

  NSString *tempRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"SpectacleUpdate-%@", [NSUUID UUID].UUIDString]];
  NSError *dirError = nil;
  if (![[NSFileManager defaultManager] createDirectoryAtPath:tempRoot withIntermediateDirectories:YES attributes:nil error:&dirError]) {
    [self updateBusy:NO statusMessage:nil];
    [self presentErrorAlertWithTitle:NSLocalizedString(@"UpdateAlertInstallFailedTitle", @"Install failed title")
                             message:dirError.localizedDescription];
    return;
  }

  __weak typeof(self) weakSelf = self;
  NSURLSessionDownloadTask *zipTask = [[NSURLSession sharedSession] downloadTaskWithURL:release.zipDownloadURL
                                                                      completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    if (error || !location) {
      [[NSFileManager defaultManager] removeItemAtPath:tempRoot error:nil];
      [strongSelf updateBusy:NO statusMessage:nil];
      dispatch_async(dispatch_get_main_queue(), ^{
        [strongSelf presentErrorAlertWithTitle:NSLocalizedString(@"UpdateAlertInstallFailedTitle", @"Install failed title")
                                       message:error.localizedDescription ?: NSLocalizedString(@"UpdateAlertDownloadFailed", @"Download failed")];
      });
      return;
    }

    NSString *zipPath = [tempRoot stringByAppendingPathComponent:(release.zipAssetName ?: @"Spectacle.zip")];
    NSError *moveError = nil;
    if (![[NSFileManager defaultManager] moveItemAtPath:location.path toPath:zipPath error:&moveError]) {
      [[NSFileManager defaultManager] removeItemAtPath:tempRoot error:nil];
      [strongSelf updateBusy:NO statusMessage:nil];
      dispatch_async(dispatch_get_main_queue(), ^{
        [strongSelf presentErrorAlertWithTitle:NSLocalizedString(@"UpdateAlertInstallFailedTitle", @"Install failed title")
                                       message:moveError.localizedDescription];
      });
      return;
    }

    if (release.checksumDownloadURL) {
      [strongSelf verifyChecksumForZipAtPath:zipPath
                                   assetName:release.zipAssetName
                                 checksumURL:release.checksumDownloadURL
                                  completion:^(BOOL valid, NSString *failureReason) {
        if (!valid) {
          [[NSFileManager defaultManager] removeItemAtPath:tempRoot error:nil];
          [strongSelf updateBusy:NO statusMessage:nil];
          dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf presentErrorAlertWithTitle:NSLocalizedString(@"UpdateAlertChecksumFailedTitle", @"Checksum failed title")
                                           message:failureReason ?: NSLocalizedString(@"UpdateAlertChecksumFailedBody", @"Checksum mismatch")];
          });
          return;
        }
        [strongSelf extractAndInstallZipAtPath:zipPath tempRoot:tempRoot targetAppPath:targetAppPath];
      }];
    } else {
      [strongSelf extractAndInstallZipAtPath:zipPath tempRoot:tempRoot targetAppPath:targetAppPath];
    }
  }];
  [zipTask resume];
}

- (void)verifyChecksumForZipAtPath:(NSString *)zipPath
                         assetName:(NSString *)assetName
                       checksumURL:(NSURL *)checksumURL
                        completion:(void (^)(BOOL valid, NSString * _Nullable failureReason))completion
{
  [self updateBusy:YES statusMessage:NSLocalizedString(@"UpdateStatusVerifying", @"Verifying download status")];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:checksumURL
                                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    if (error || !data) {
      completion(NO, error.localizedDescription ?: NSLocalizedString(@"UpdateAlertChecksumFailedBody", @"Checksum mismatch"));
      return;
    }
    NSString *checksumText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *expectedHash = [self expectedSHA256InText:checksumText forAssetName:assetName];
    if (expectedHash.length != 64) {
      completion(NO, NSLocalizedString(@"UpdateAlertChecksumMissing", @"Checksum entry missing"));
      return;
    }
    NSString *actualHash = [self sha256HexForFileAtPath:zipPath];
    if (!actualHash || [actualHash caseInsensitiveCompare:expectedHash] != NSOrderedSame) {
      completion(NO, NSLocalizedString(@"UpdateAlertChecksumFailedBody", @"Checksum mismatch"));
      return;
    }
    completion(YES, nil);
  }];
  [task resume];
}

- (NSString *)expectedSHA256InText:(NSString *)text forAssetName:(NSString *)assetName
{
  if (!text || !assetName) {
    return nil;
  }
  NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
  for (NSString *line in lines) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (trimmed.length < 66) {
      continue;
    }
    if ([trimmed hasSuffix:assetName]) {
      NSArray<NSString *> *parts = [trimmed componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if (parts.count >= 2 && parts.firstObject.length == 64) {
        return parts.firstObject;
      }
    }
  }
  return nil;
}

- (NSString *)sha256HexForFileAtPath:(NSString *)path
{
  NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
  if (!stream) {
    return nil;
  }
  [stream open];

  CC_SHA256_CTX ctx;
  CC_SHA256_Init(&ctx);
  uint8_t buffer[32768];
  NSInteger bytesRead = 0;
  while ((bytesRead = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
    CC_SHA256_Update(&ctx, buffer, (CC_LONG)bytesRead);
  }
  [stream close];

  if (bytesRead < 0) {
    return nil;
  }

  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &ctx);

  NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
    [hex appendFormat:@"%02x", digest[i]];
  }
  return hex;
}

- (void)extractAndInstallZipAtPath:(NSString *)zipPath
                          tempRoot:(NSString *)tempRoot
                     targetAppPath:(NSString *)targetAppPath
{
  [self updateBusy:YES statusMessage:NSLocalizedString(@"UpdateStatusInstalling", @"Installing update status")];

  NSString *extractDir = [tempRoot stringByAppendingPathComponent:@"extracted"];
  NSError *error = nil;
  if (![[NSFileManager defaultManager] createDirectoryAtPath:extractDir withIntermediateDirectories:YES attributes:nil error:&error]) {
    [[NSFileManager defaultManager] removeItemAtPath:tempRoot error:nil];
    [self updateBusy:NO statusMessage:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self presentErrorAlertWithTitle:NSLocalizedString(@"UpdateAlertInstallFailedTitle", @"Install failed title")
                               message:error.localizedDescription];
    });
    return;
  }

  NSTask *ditto = [NSTask new];
  ditto.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ditto"];
  ditto.arguments = @[@"-x", @"-k", zipPath, extractDir];
  if (![ditto launchAndReturnError:&error]) {
    [[NSFileManager defaultManager] removeItemAtPath:tempRoot error:nil];
    [self updateBusy:NO statusMessage:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self presentErrorAlertWithTitle:NSLocalizedString(@"UpdateAlertInstallFailedTitle", @"Install failed title")
                               message:error.localizedDescription];
    });
    return;
  }
  [ditto waitUntilExit];

  NSString *stagedAppPath = [extractDir stringByAppendingPathComponent:@"Spectacle.app"];
  if (ditto.terminationStatus != 0 || ![[NSFileManager defaultManager] fileExistsAtPath:stagedAppPath]) {
    [[NSFileManager defaultManager] removeItemAtPath:tempRoot error:nil];
    [self updateBusy:NO statusMessage:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self presentErrorAlertWithTitle:NSLocalizedString(@"UpdateAlertInstallFailedTitle", @"Install failed title")
                               message:NSLocalizedString(@"UpdateAlertExtractFailed", @"Extract failed")];
    });
    return;
  }

  // Launch detached helper script that waits for Spectacle to exit, swaps the bundle, and relaunches.
  NSString *script =
    @"PID=\"$1\"; TARGET=\"$2\"; STAGED=\"$3\"; TMPDIR=\"$4\"; "
    @"while kill -0 \"$PID\" 2>/dev/null; do sleep 0.2; done; "
    @"BACKUP=\"${TARGET}.backup.$$\"; "
    @"if mv \"$TARGET\" \"$BACKUP\"; then "
    @"  if mv \"$STAGED\" \"$TARGET\"; then "
    @"    rm -rf \"$BACKUP\"; "
    @"  else "
    @"    mv \"$BACKUP\" \"$TARGET\"; "
    @"  fi; "
    @"fi; "
    @"rm -rf \"$TMPDIR\"; "
    @"open -n \"$TARGET\"";

  NSTask *installer = [NSTask new];
  installer.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
  installer.arguments = @[
    @"-c",
    script,
    @"spectacle-updater",
    [NSString stringWithFormat:@"%d", NSProcessInfo.processInfo.processIdentifier],
    targetAppPath,
    stagedAppPath,
    tempRoot,
  ];
  if (![installer launchAndReturnError:&error]) {
    [[NSFileManager defaultManager] removeItemAtPath:tempRoot error:nil];
    [self updateBusy:NO statusMessage:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self presentErrorAlertWithTitle:NSLocalizedString(@"UpdateAlertInstallFailedTitle", @"Install failed title")
                               message:error.localizedDescription];
    });
    return;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    [NSApp terminate:nil];
  });
}

@end
