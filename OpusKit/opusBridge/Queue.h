#import <Foundation/Foundation.h>

typedef enum {
    QueuePriorityLow,
    QueuePriorityDefault,
    QueuePriorityHigh
} QueuePriority;

@interface Queue : NSObject

+ (Queue *)mainQueue;
+ (Queue *)concurrentDefaultQueue;
+ (Queue *)concurrentBackgroundQueue;

- (instancetype)init;
- (instancetype)initWithName:(NSString *)name;
- (instancetype)initWithPriority:(QueuePriority)priority;

- (void)dispatch:(dispatch_block_t)block;
- (void)dispatch:(dispatch_block_t)block synchronous:(bool)synchronous;
- (void)dispatchAfter:(NSTimeInterval)seconds block:(dispatch_block_t)block;

- (dispatch_queue_t)nativeQueue;

@end
