#import <Foundation/Foundation.h>
#import <Limelight.h>

@interface CoreAudioRenderer : NSObject

- (instancetype)initWithConfig:(const OPUS_MULTISTREAM_CONFIGURATION*)opusConfig;

- (void)start;
- (void)stop;
- (void *)getAudioBuffer:(int *)size;
- (BOOL)submitAudio:(int)bytesWritten opusBytes:(int)opusBytes decodeStartTime:(CFTimeInterval)decodeStartTime;
- (NSString *)getAudioStatsString;
- (void)handleRouteChange:(NSNotification *)notification;

@end
