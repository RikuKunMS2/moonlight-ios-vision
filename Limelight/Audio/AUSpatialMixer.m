//
//  AUSpatialMixer.m
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2).
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//  Based on files created by Andy Grundman https://github.com/andygrundman
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

#import "AUSpatialMixer.h"
#import "AllocatedAudioBufferList.h"
#import "DataManager.h"

// lightweight callback debug logging
typedef enum {
    STARVED,
    OK
} CallbackState;

typedef struct {
    CallbackState state;
    int okCounter;
    int starvedCounter;
    int sinceStateChange;
} CallbackHealth;

static CallbackHealth ch = { STARVED, 0, 0, 0 };

// realtime method
static OSStatus inputCallback(void *inRefCon,
                       AudioUnitRenderActionFlags *ioActionFlags,
                       const AudioTimeStamp *inTimestamp,
                       uint32_t inBusNumber,
                       uint32_t inNumberFrames,
                       AudioBufferList *ioData)
{
    AUSpatialMixer *me = (__bridge AUSpatialMixer *)inRefCon;

    static int mixerInputCounter = 0;
    if (mixerInputCounter++ % 200 == 0) {
        DEBUG_TRACE(@"[Audio Debug] AUSpatialMixer inputCallback requested %d frames", inNumberFrames);
    }

    // Clear the buffer
    for (uint32_t i = 0; i < ioData->mNumberBuffers; i++) {
        memset(ioData->mBuffers[i].mData, 0, inNumberFrames * sizeof(float));
    }

    // Pull audio from playthrough buffer
    uint32_t availableBytes;
    float *ringBuffer = (float *)TPCircularBufferTail(me.ringBufferPtr, &availableBytes);

    // Total size of interleaved PCM for all channels
    uint32_t channelCount = ioData->mNumberBuffers;
    uint32_t wantedBytes  = channelCount * inNumberFrames * sizeof(float);

    if (availableBytes < wantedBytes) {
        // not enough data for all channels, so we send back our fully zeroed-out buffer
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;

        ch.starvedCounter++;
        if (ch.state == OK) {
            // Log only once when switching states
            DEBUG_TRACE(@"spatial callback starved after %d OK callbacks: wanted %d, avail %d\n",
                        ch.okCounter, wantedBytes, availableBytes);
            ch.okCounter = 0;
            ch.state = STARVED;
        }
    }
    else {
        // de-interleave ringBuffer PCM data into per-channel buffers
        for (uint32_t channel = 0; channel < channelCount; channel++) {
            float *channelBuffer = (float *)ioData->mBuffers[channel].mData;
            // De-interleave the channels
            for (uint32_t frame = 0; frame < inNumberFrames; frame++) {
                channelBuffer[frame] = ringBuffer[(frame * channelCount) + channel];
            }
        }

        ch.okCounter++;
        if (ch.state == STARVED) {
            // Log only once when switching states
            DEBUG_TRACE(@"spatial callback OK after %d starved callbacks: consumed %d\n",
                        ch.starvedCounter, wantedBytes);
            ch.starvedCounter = 0;
            ch.state = OK;
        }

        TPCircularBufferConsume(me.ringBufferPtr, wantedBytes);
    }

    return noErr;
}

@implementation AUSpatialMixer

- (instancetype)init {
    self = [super init];
    if (self) {
        _headTracking = NO;
        _personalizedHRTF = NO;
        _audioUnitLatency = 0.0;
        
        AudioComponentDescription desc;
        desc.componentType = kAudioUnitType_Mixer;
        desc.componentSubType = kAudioUnitSubType_SpatialMixer;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;
        desc.componentFlags = 0;
        desc.componentFlagsMask = 0;

        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        if (comp == NULL) {
            CA_LogError(-1, "Failed to find AUSpatialMixer component");
            return nil;
        }

        OSStatus status = AudioComponentInstanceNew(comp, &_mixer);
        if (status != noErr) {
            CA_LogError(status, "Failed to instantiate AUSpatialMixer component");
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    if (_mixer) {
        AudioComponentInstanceDispose(_mixer);
        _mixer = NULL;
    }
}

- (BOOL)setupWithOutputType:(AUSpatialMixerOutputType)outputType inSampleRate:(double)inSampleRate outSampleRate:(double)outSampleRate inChannelCount:(int)inChannelCount {
    // Set the number of input elements (buses).
    uint32_t numInputs = 1;
    OSStatus status = AudioUnitSetProperty(_mixer, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &numInputs, sizeof(numInputs));
    if (status != noErr) {
        CA_LogError(status, "Failed to set AUSpatialMixer numInputs to 1");
        return NO;
    }

    // Set up the output stream format and channel layout for stereo.
    status = [self setStreamFormatAndACL:inSampleRate layoutTag:kAudioChannelLayoutTag_Stereo scope:kAudioUnitScope_Output element:0];
    if (status != noErr) {
        CA_LogError(status, "Failed to set AUSpatialMixer output stream format to stereo");
        return NO;
    }

    // Set up the input stream format as multichannel with 5.1 or 7.1 channel layout.
    AudioChannelLayoutTag layout;
    switch (inChannelCount) {
        case 2:
            layout = kAudioChannelLayoutTag_Stereo;
            break;
        case 6:
            layout = kAudioChannelLayoutTag_WAVE_5_1_B; // L R C LFE Rls Rrs
            break;
        case 8:
            layout = kAudioChannelLayoutTag_WAVE_7_1; // L R C LFE Rls Rrs Ls Rs
            break;
        case 12:
            layout = kAudioChannelLayoutTag_Atmos_7_1_4; // L R C LFE Ls Rs Rls Rrs Vhl Vhr Ltr Rtr
            break;
        default:
            CA_LogError(-1, "Unsupported number of channels for spatial audio mixer: %d", inChannelCount);
            return NO;
    }

    status = [self setStreamFormatAndACL:inSampleRate layoutTag:layout scope:kAudioUnitScope_Input element:0];
    if (status != noErr) {
        CA_LogError(status, "Failed to set AUSpatialMixer input stream format to %d channels", inChannelCount);
        return NO;
    }

    uint32_t renderingAlgorithm = kSpatializationAlgorithm_UseOutputType;
    DEBUG_TRACE(@"AUSpatialMixer kAudioUnitProperty_SpatializationAlgorithm set to UseOutputType (%d)", renderingAlgorithm);
    status = AudioUnitSetProperty(_mixer, kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input, 0, &renderingAlgorithm, sizeof(renderingAlgorithm));
    if (status != noErr) {
        CA_LogError(status, "Failed to set AUSpatialMixer spatialization algorithm");
        return NO;
    }

    uint32_t sourceMode = kSpatialMixerSourceMode_AmbienceBed;
    DEBUG_TRACE(@"AUSpatialMixer kAudioUnitProperty_SpatialMixerSourceMode set to AmbienceBed (%d)", sourceMode);
    status = AudioUnitSetProperty(_mixer, kAudioUnitProperty_SpatialMixerSourceMode, kAudioUnitScope_Input, 0, &sourceMode, sizeof(sourceMode));
    if (status != noErr) {
        CA_LogError(status, "Failed to set AUSpatialMixer source mode");
        return NO;
    }

    DEBUG_TRACE(@"AUSpatialMixer setOutputType %d", outputType);
    status = [self setOutputType:outputType];
    if (status != noErr) {
        CA_LogError(status, "Failed to set AUSpatialMixer output type");
        return NO;
    }

#if !TARGET_OS_SIMULATOR && (TARGET_OS_OSX || TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_VISION)

#if TARGET_OS_OSX
    if (@available(macOS 13.0, *))
#elif TARGET_OS_IOS
    if (@available(iOS 18.0, *))
#elif TARGET_OS_TV
    if (@available(tvOS 18.0, *))
#elif TARGET_OS_VISION
    if (@available(visionOS 1.0, *))
#endif
    {
        if (outputType == kSpatialMixerOutputType_Headphones) {
            NSInteger spatialAudioMode = [[NSUserDefaults standardUserDefaults] integerForKey:@"spatialAudioMode"];
            if (spatialAudioMode == 2) {
#if !TARGET_OS_VISION
                uint32_t ht = 1;
                status = AudioUnitSetProperty(_mixer, kAudioUnitProperty_SpatialMixerEnableHeadTracking, kAudioUnitScope_Global, 0, &ht, sizeof(uint32_t));
                if (status != noErr) {
                    CA_LogError(status, "Failed to enable head tracking");
                }
                else {
                    DEBUG_TRACE(@"AUSpatialMixer enabled head-tracking");
                    _headTracking = YES;
                }
#endif
            }
            else {
                DEBUG_TRACE(@"AUSpatialMixer not enabling head-tracking per user setting");
            }

            uint32_t hrtf = kSpatialMixerPersonalizedHRTFMode_Auto;
            status = AudioUnitSetProperty(_mixer, kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode, kAudioUnitScope_Global, 0, &hrtf, sizeof(uint32_t));
            if (status != noErr) {
                CA_LogError(status, "Failed to enable personalized spatial audio");
            }
            else {
                DEBUG_TRACE(@"AUSpatialMixer set personalized HRTF mode to auto");
            }
        }
    }

#endif 

#if TARGET_OS_IOS
    if (@available(iOS 18.0, *))
#elif TARGET_OS_TV
    if (@available(tvOS 18.0, *))
#endif
    {
        AUPreset preset = {
            outputType == kSpatialMixerOutputType_BuiltInSpeakers ? 0 : 1,
            NULL
        };
        status = AudioUnitSetProperty(_mixer, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &preset, sizeof(AUPreset));
        if (status != noErr) {
            CA_LogError(status, "Failed to set AUSpatialMixer factory preset");
        }
    }

    if (@available(iOS 15.0, tvOS 15.0, *)) {
        NSError *error = nil;
        [[AVAudioSession sharedInstance] setSupportsMultichannelContent:YES error:&error];
        if (error != nil) {
            Log(LOG_W, @"Warning: failed to setSupportsMultichannelContent:YES: %@", error.localizedDescription);
        }
        else {
            DEBUG_TRACE(@"AUSpatialMixer setSupportsMultichannelContent:YES");
        }
    }

    uint32_t mfps = 4096;
    status = AudioUnitSetProperty(_mixer, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &mfps, sizeof(mfps));
    if (status != noErr) {
        CA_LogError(status, "Failed to set AUSpatialMixer max frame size");
        return NO;
    }

    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = inputCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)self;
    DEBUG_TRACE(@"AUSpatialMixer set input callback");
    status = AudioUnitSetProperty(_mixer, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callbackStruct, sizeof(callbackStruct));
    if (status != noErr) {
        CA_LogError(status, "Failed to set AUSpatialMixer input callback");
        return NO;
    }

    DEBUG_TRACE(@"AUSpatialMixer initialize");
    status = AudioUnitInitialize(_mixer);
    if (status != noErr) {
        CA_LogError(status, "Failed to initialize AUSpatialMixer");
        return NO;
    }

#if TARGET_OS_OSX
    if (@available(macOS 14.0, *))
#elif TARGET_OS_IOS
    if (@available(iOS 18.0, *))
#elif TARGET_OS_TV
    if (@available(tvOS 18.0, *))
#endif
    {
        if (outputType == kSpatialMixerOutputType_Headphones) {
            uint32_t hrtf = 0;
            uint32_t size = sizeof(hrtf);
            status = AudioUnitGetProperty(_mixer, kAudioUnitProperty_SpatialMixerAnyInputIsUsingPersonalizedHRTF, kAudioUnitScope_Global, 0, &hrtf, &size);
            if (status != noErr) {
                CA_LogError(status, "Failed to get AUSpatialMixer personalized HRTF status");
            }
            else {
                _personalizedHRTF = (hrtf == 1);
                DEBUG_TRACE(@"AUSpatialMixer actual personalized HRTF status: %s", _personalizedHRTF ? "enabled" : "disabled");
            }
        }
    }

    {
        _audioUnitLatency = 0.0;
        uint32_t size = sizeof(_audioUnitLatency);
        status = AudioUnitGetProperty(_mixer, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &_audioUnitLatency, &size);
        if (status != noErr) {
            CA_LogError(status, "Failed to get SpatialAU AudioUnit latency");
            return NO;
        }
        DEBUG_TRACE(@"CoreAudioRenderer SpatialAU AudioUnit latency: %0.2f ms", _audioUnitLatency * 1000.0);
    }

    return YES;
}

- (OSStatus)setStreamFormatAndACL:(float)inSampleRate layoutTag:(AudioChannelLayoutTag)inLayoutTag scope:(AudioUnitScope)inScope element:(AudioUnitElement)inElement {
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate       = inSampleRate;
    asbd.mFormatID         = kAudioFormatLinearPCM;
    asbd.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved;
    asbd.mFramesPerPacket  = 1;
    asbd.mChannelsPerFrame = (inLayoutTag & 0xFFFF);
    asbd.mBitsPerChannel   = 32;
    asbd.mBytesPerPacket   = asbd.mBitsPerChannel / 8;
    asbd.mBytesPerFrame    = asbd.mBitsPerChannel / 8;

    OSStatus status = AudioUnitSetProperty(_mixer, kAudioUnitProperty_StreamFormat, inScope, inElement, &asbd, sizeof(AudioStreamBasicDescription));
    if (status != noErr) {
        CA_LogError(status, "Failed to set AUSpatialMixer StreamFormat scope=%d", inScope);
        return status;
    }

    AudioChannelLayout layout = {0};
    layout.mChannelLayoutTag = inLayoutTag;

    UInt32 layoutSize = offsetof(AudioChannelLayout, mChannelDescriptions);
    status = AudioUnitSetProperty(_mixer, kAudioUnitProperty_AudioChannelLayout, inScope, inElement, &layout, layoutSize);
    if (status != noErr) {
        CA_LogError(status, "Failed to set AUSpatialMixer AudioChannelLayout scope=%d, layout=%u", inScope, inLayoutTag);
        return status;
    }

    return noErr;
}

- (OSStatus)setOutputType:(AUSpatialMixerOutputType)outputType {
    return AudioUnitSetProperty(_mixer, kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global, 0, &outputType, sizeof(outputType));
}

- (void)processWithOutputABL:(AudioBufferList *)outputABL timeStamp:(const AudioTimeStamp *)inTimeStamp numberFrames:(float)inNumberFrames {
    AudioUnitRenderActionFlags actionFlags = 0;
    OSStatus err = AudioUnitRender(_mixer, &actionFlags, inTimeStamp, 0, inNumberFrames, outputABL);
    if (err != noErr) {
        // Handle error if needed
    }
}

@end
