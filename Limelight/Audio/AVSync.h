#pragma once

#import <AVFoundation/AVFoundation.h>

#include <Limelight.h>

@interface AVSync : NSObject

+ (instancetype)sharedInstance;

- (void)setVideoPts:(uint32_t)pts;
- (void)setAudioPtsAndCurrentTime:(CMTime)pts currentTime:(CMTime)currentTime;
- (double)getAVSyncOffsets:(double *)audioDelay;
- (double)getAudioDelay;

@end

