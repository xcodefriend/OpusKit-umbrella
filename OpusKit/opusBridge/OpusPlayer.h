#import <Foundation/Foundation.h>

@interface OpusPlayer : NSObject

@end

@protocol OpusPlayerDelegate <NSObject>
- (void)audioPlayerDidFinishPlaying:(OpusPlayer *)audioPlayer;

@optional
- (void)audioPlayerDidStartPlaying:(OpusPlayer *)audioPlayer;
- (void)audioPlayerDidPause:(OpusPlayer *)audioPlayer;

@end

@interface OpusPlayer ()

@property (nonatomic, weak) id<OpusPlayerDelegate> delegate;

- (instancetype)initWithPath:(NSString *)path;
+ (bool)canPlayFile:(NSString *)path;
+ (NSTimeInterval)durationFile:(NSString *)path;
- (void)play;
- (void)playFromPosition:(NSTimeInterval)position;
- (void)pause;
- (void)stop;
- (NSTimeInterval)currentPositionSync:(bool)sync;
- (NSTimeInterval)duration;
- (void)setCurrentPosition:(NSTimeInterval)position;
- (BOOL)isPaused;
- (BOOL)isEqualToPath:(NSString *)path;

@end
