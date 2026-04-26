//
//  CoreAudioRenderer.h
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2).
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//  Based on files created by Andy Grundman https://github.com/andygrundman
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

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
