//
//  SpatialAudioRenderer.h
//  Moonlight
//
//  Created by Luma on 11/23/25.
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//

#pragma once

#import <Foundation/Foundation.h>
#include <Limelight.h>

NS_ASSUME_NONNULL_BEGIN

@interface SpatialAudioRenderer : NSObject

- (instancetype)initWithConfig:(const OPUS_MULTISTREAM_CONFIGURATION*)opusConfig;
- (void)start;
- (void)stop;
- (void *)getAudioBuffer:(int *)size;
- (BOOL)submitAudio:(int)bytesWritten opusBytes:(int)opusBytes decodeStartTime:(CFTimeInterval)decodeStartTime;
- (NSString *)getAudioStatsString;
- (void)handleRouteChange:(NSNotification *)notification;

@end

NS_ASSUME_NONNULL_END
