//
//  AUSpatialMixer.h
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
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioTypes/CoreAudioTypes.h>
#import <Accelerate/Accelerate.h>

#include "TPCircularBuffer.h"
#include "CoreAudioHelpers.h"

@interface AUSpatialMixer : NSObject

@property (nonatomic, readonly) AudioUnit _Nonnull mixer;
@property (nonatomic, readonly) double audioUnitLatency;
@property (nonatomic, readonly) BOOL headTracking;
@property (nonatomic, readonly) BOOL personalizedHRTF;
@property (nonatomic, assign) struct TPCircularBuffer * _Nullable ringBufferPtr;

- (BOOL)setupWithOutputType:(AUSpatialMixerOutputType)outputType inSampleRate:(double)inSampleRate outSampleRate:(double)outSampleRate inChannelCount:(int)inChannelCount;
- (OSStatus)setStreamFormatAndACL:(float)inSampleRate layoutTag:(AudioChannelLayoutTag)inLayoutTag scope:(AudioUnitScope)inScope element:(AudioUnitElement)inElement;
- (OSStatus)setOutputType:(AUSpatialMixerOutputType)outputType;
- (void)processWithOutputABL:(AudioBufferList * _Nullable)outputABL timeStamp:(const AudioTimeStamp * _Nullable)inTimeStamp numberFrames:(float)inNumberFrames;

@end
