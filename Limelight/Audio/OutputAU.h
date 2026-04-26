//
//  OutputAU.h
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
#import <Accelerate/Accelerate.h>

#include "TPCircularBuffer.h"
#include "AllocatedAudioBufferList.h"
#import "AUSpatialMixer.h"
#import "AudioStats.h"

#include <Limelight.h>

@interface OutputAU : NSObject {
@public
    TPCircularBuffer _ringBuffer;
}

@property (nonatomic, assign) AudioComponentInstance _Nullable outputAU;
@property (nonatomic, strong) AUSpatialMixer * _Nonnull spatialAU;
@property (nonatomic, strong) AVAudioEngine * _Nullable engine;
@property (nonatomic, strong) AVAudioSourceNode * _Nullable sourceNode;

@property (nonatomic, assign) double sampleRateOpus;
@property (nonatomic, assign) double sampleRateHW;
@property (nonatomic, assign) int channelCount;
@property (nonatomic, assign) int samplesPerFrame;
@property (nonatomic, assign) double ioBufferDuration;

#if TARGET_OS_OSX
@property (nonatomic, assign) AudioDeviceID outputDeviceID;
#endif
@property (nonatomic, assign) AudioStreamBasicDescription outputASBD;
@property (nonatomic, assign) BOOL isSpatial;
@property (nonatomic, assign) char * _Nullable outputDeviceName;
@property (nonatomic, assign) int outputChannels;
@property (nonatomic, copy) NSString * _Nullable outputTypeStr;

@property (nonatomic, assign) double outputHardwareLatency;
@property (nonatomic, assign) double totalSoftwareLatency;
@property (nonatomic, assign) double outputSoftwareLatencyMin;
@property (nonatomic, assign) double outputSoftwareLatencyMax;

@property (nonatomic, assign) BOOL needsReinit;

@property (nonatomic, assign) TPCircularBuffer ringBuffer;
@property (nonatomic, strong) AllocatedAudioBufferList * _Nullable spatialBuffer;
@property (nonatomic, assign) double audioPacketDuration;
@property (nonatomic, assign) uint32_t bufferFrameSize;

@property (nonatomic, assign) uint32_t bufferSize;
@property (nonatomic, assign) uint32_t bufferFilledBytes;
@property (nonatomic, assign) uint32_t bitrateSum;
@property (nonatomic, assign) uint32_t opusPackets;
@property (nonatomic, assign) double opusToPCMTime;
@property (nonatomic, assign) double pcmToOutputTime;

- (BOOL)prepareForPlayback:(const OPUS_MULTISTREAM_CONFIGURATION * _Nonnull)opusConfig;
- (BOOL)initAudioUnit;
- (BOOL)initRingBuffer;
- (void)setCallbackWithContext:(void * _Nonnull)context callback:(AURenderCallback _Nonnull)callback;
- (BOOL)start;
- (void)refreshDeviceProperties;
- (void * _Nullable)getAudioBuffer:(int * _Nonnull)size;
- (BOOL)submitAudioWithBytesWritten:(int)bytesWritten opusBytes:(int)opusBytes decodeStartTime:(CFTimeInterval)decodeStartTime;
- (NSString * _Nonnull)getAudioStatsString;
- (BOOL)stop;

- (AUSpatialMixerOutputType)getSpatialMixerOutputType;
- (NSString * _Nonnull)getSMOTString:(AUSpatialMixerOutputType)type;
- (double)getSampleRate;

- (OSStatus)setOutputType:(AUSpatialMixerOutputType)outputType;

@end
