#import "NSObject+Lock.h"
#import <objc/runtime.h>

static const char *lockPropertyKey = "ObjectLock::lock";

@interface ObjectLockImpl : NSObject {
    SYNCHRONIZED_DEFINE(objectLock);
}

- (void)Lock;
- (void)unLock;

@end

@implementation ObjectLockImpl

- (id)init
{
    self = [super init];
    if (self != nil) {
        SYNCHRONIZED_INIT(objectLock);
    }
    return self;
}

- (void)Lock {
    SYNCHRONIZED_BEGIN(objectLock);
}

- (void)unLock
{
    SYNCHRONIZED_END(objectLock);
}

@end

@implementation NSObject (Lock)

- (void)lockObject
{
    ObjectLockImpl *lock = (ObjectLockImpl *)objc_getAssociatedObject(self, lockPropertyKey);
    if (lock == nil)
    {
        @synchronized(self)
        {
            lock = [[ObjectLockImpl alloc] init];
            objc_setAssociatedObject(self, lockPropertyKey, lock, OBJC_ASSOCIATION_RETAIN);
        }
    }
    
    [lock Lock];
}

- (void)unlockObject
{
    ObjectLockImpl *lock = (ObjectLockImpl *)objc_getAssociatedObject(self, lockPropertyKey);
    if (lock == nil)
    {
        @synchronized(self)
        {
            lock = [[ObjectLockImpl alloc] init];
            objc_setAssociatedObject(self, lockPropertyKey, lock, OBJC_ASSOCIATION_RETAIN);
        }
    }
    
    [lock unLock];
}

@end
