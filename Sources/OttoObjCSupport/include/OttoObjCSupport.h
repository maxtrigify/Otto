#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain used when an Objective-C exception is converted into an NSError.
FOUNDATION_EXPORT NSErrorDomain const OttoObjCExceptionErrorDomain;

/// User-info key carrying the original `NSException.name`.
FOUNDATION_EXPORT NSString *const OttoObjCExceptionNameKey;

/// Runs `block` and converts any Objective-C exception it raises into `error`.
///
/// Swift cannot catch Objective-C exceptions. Frameworks such as AVFoundation raise them for
/// invalid audio graphs (for example when no output device is attached), and an uncaught one
/// terminates the process. Returns YES when the block completed normally.
FOUNDATION_EXPORT BOOL OttoRunCatchingObjCException(
    void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
