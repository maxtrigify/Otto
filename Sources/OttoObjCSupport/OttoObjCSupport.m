#import "OttoObjCSupport.h"

NSErrorDomain const OttoObjCExceptionErrorDomain = @"io.openotto.objc-exception";
NSString *const OttoObjCExceptionNameKey = @"OttoObjCExceptionName";

BOOL OttoRunCatchingObjCException(void (NS_NOESCAPE ^block)(void), NSError **error) {
  @try {
    block();
    return YES;
  } @catch (NSException *exception) {
    if (error != NULL) {
      NSMutableDictionary<NSErrorUserInfoKey, id> *info = [NSMutableDictionary dictionary];
      NSString *reason = exception.reason.length > 0 ? exception.reason : exception.name;
      info[NSLocalizedDescriptionKey] = reason;
      info[OttoObjCExceptionNameKey] = exception.name;
      *error = [NSError errorWithDomain:OttoObjCExceptionErrorDomain code:1 userInfo:info];
    }
    return NO;
  }
}
