//
//  CuplivoISHExecutor.h
//  Runner
//
//  One-shot command execution inside the embedded iSH guest with captured
//  stdout/stderr, exit code and timeout enforcement.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CuplivoISHExecutor : NSObject

/// Execute `/bin/sh -c <command>` in the guest. Runs serialized on a
/// dedicated queue; completion is invoked on that queue with a result map:
///   exitCode: NSNumber (guest exit code, -1 on failure/timeout)
///   stdout:   NSString
///   stderr:   NSString
///   timedOut: NSNumber(BOOL)
///   cancelled: NSNumber(BOOL)
///   stdoutTruncated/stderrTruncated: NSNumber(BOOL)
/// On infrastructure failure an additional `error` key carries the reason.
/// The kernel must already be booted.
+ (void)executeCommand:(NSString *)command
              requestId:(NSString *)requestId
                   cwd:(nullable NSString *)cwd
               timeout:(NSTimeInterval)timeout
            completion:(void (^)(NSDictionary<NSString *, id> *result))completion;

/// Mark one queued or running request cancelled. Running guest processes are
/// terminated through the iSH task tree; queued requests return a cancelled
/// result without starting a guest task.
+ (BOOL)cancelRequest:(NSString *)requestId;

/// Cancel every queued or running request. Used during native teardown.
+ (void)cancelAll;

@end

NS_ASSUME_NONNULL_END
