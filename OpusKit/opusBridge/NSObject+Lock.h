#import <Foundation/Foundation.h>
#import <pthread.h>

#define SYNCHRONIZED_DEFINE(lock) pthread_mutex_t _SYNCHRONIZED_##lock
#define SYNCHRONIZED_INIT(lock) pthread_mutex_init(&_SYNCHRONIZED_##lock, NULL)
#define SYNCHRONIZED_BEGIN(lock) pthread_mutex_lock(&_SYNCHRONIZED_##lock);
#define SYNCHRONIZED_END(lock) pthread_mutex_unlock(&_SYNCHRONIZED_##lock);

@interface NSObject (Lock)

- (void)lockObject;
- (void)unlockObject;

@end
