//
//  AVSync.h
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2).
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//  Based on files created by Andy Grundman https://github.com/andygrundman
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

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

