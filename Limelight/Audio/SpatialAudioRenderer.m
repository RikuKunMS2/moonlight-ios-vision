/*
 * SpatialAudioRenderer.m
 *
 * Pure Objective-C Audio Backend for VisionOS/iOS Moonlight
 * No C++ dependencies.
 */

#import "SpatialAudioRenderer.h"
#import "DataManager.h"

#import <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioTypes/CoreAudioTypes.h>
#import <mach/mach.h>
#import <stdatomic.h> // Standard C11 atomics

// =============================================================================
// Part 1: TPCircularBuffer Implementation (Pure C)
// =============================================================================

typedef struct {
    void             *buffer;
    uint32_t          length;
    uint32_t          tail;
    uint32_t          head;
    volatile atomic_int fillCount; // C11 atomic
    bool              atomic;
} TPCircularBuffer;

static bool _reportResult(kern_return_t result, const char *operation) {
    if (result != ERR_SUCCESS) {
        printf("TPCircularBuffer: %s: %s\n", operation, mach_error_string(result));
        return false;
    }
    return true;
}

static bool TPCircularBufferInit(TPCircularBuffer *buffer, uint32_t length) {
    if (length == 0) return false;
    
    int retries = 3;
    while (true) {
        buffer->length = (uint32_t)round_page(length);
        
        vm_address_t bufferAddress;
        kern_return_t result = vm_allocate(mach_task_self(),
                                           &bufferAddress,
                                           buffer->length * 2,
                                           VM_FLAGS_ANYWHERE);
        if (result != ERR_SUCCESS) {
            if (retries-- == 0) return _reportResult(result, "Buffer allocation");
            continue;
        }
        
        result = vm_deallocate(mach_task_self(),
                               bufferAddress + buffer->length,
                               buffer->length);
        if (result != ERR_SUCCESS) {
            if (retries-- == 0) return _reportResult(result, "Buffer deallocation");
            vm_deallocate(mach_task_self(), bufferAddress, buffer->length);
            continue;
        }
        
        vm_address_t virtualAddress = bufferAddress + buffer->length;
        vm_prot_t cur_prot, max_prot;
        result = vm_remap(mach_task_self(),
                          &virtualAddress,
                          buffer->length,
                          0,
                          0,
                          mach_task_self(),
                          bufferAddress,
                          0,
                          &cur_prot,
                          &max_prot,
                          VM_INHERIT_DEFAULT);
        
        if (result != ERR_SUCCESS) {
            if (retries-- == 0) return _reportResult(result, "Remap buffer memory");
            vm_deallocate(mach_task_self(), bufferAddress, buffer->length);
            continue;
        }
        
        if (virtualAddress != bufferAddress + buffer->length) {
            if (retries-- == 0) {
                printf("Couldn't map buffer memory to end of buffer\n");
                return false;
            }
            vm_deallocate(mach_task_self(), virtualAddress, buffer->length);
            vm_deallocate(mach_task_self(), bufferAddress, buffer->length);
            continue;
        }
        
        buffer->buffer = (void*)bufferAddress;
        atomic_init(&buffer->fillCount, 0);
        buffer->head = buffer->tail = 0;
        buffer->atomic = true;
        return true;
    }
    return false;
}

static void TPCircularBufferCleanup(TPCircularBuffer *buffer) {
    if (buffer->buffer) {
        vm_deallocate(mach_task_self(), (vm_address_t)buffer->buffer, buffer->length * 2);
        memset(buffer, 0, sizeof(TPCircularBuffer));
    }
}

static __inline__ __attribute__((always_inline)) void* TPCircularBufferTail(TPCircularBuffer *buffer, uint32_t* availableBytes) {
    *availableBytes = atomic_load(&buffer->fillCount);
    if (*availableBytes == 0) return NULL;
    return (void*)((char*)buffer->buffer + buffer->tail);
}

static __inline__ __attribute__((always_inline)) void TPCircularBufferConsume(TPCircularBuffer *buffer, uint32_t amount) {
    buffer->tail = (buffer->tail + amount) % buffer->length;
    if (buffer->atomic) {
        atomic_fetch_add(&buffer->fillCount, -(int)amount);
    } else {
        atomic_store(&buffer->fillCount, atomic_load(&buffer->fillCount) - amount);
    }
}

static __inline__ __attribute__((always_inline)) void* TPCircularBufferHead(TPCircularBuffer *buffer, uint32_t* availableBytes) {
    *availableBytes = (buffer->length - atomic_load(&buffer->fillCount));
    if (*availableBytes == 0) return NULL;
    return (void*)((char*)buffer->buffer + buffer->head);
}

static __inline__ __attribute__((always_inline)) void TPCircularBufferProduce(TPCircularBuffer *buffer, uint32_t amount) {
    buffer->head = (buffer->head + amount) % buffer->length;
    if (buffer->atomic) {
        atomic_fetch_add(&buffer->fillCount, (int)amount);
    } else {
        atomic_store(&buffer->fillCount, atomic_load(&buffer->fillCount) + amount);
    }
}

// =============================================================================
// Part 2: CoreAudioHelpers & Logging
// =============================================================================

#ifdef DEBUG
  #define DEBUG_TRACE( s, ... ) NSLog( @"<%@:%d> %@", [[NSString stringWithUTF8String:__FILE__] lastPathComponent], __LINE__,  [NSString stringWithFormat:(s), ##__VA_ARGS__] )
#else
  #define DEBUG_TRACE( s, ... )
#endif

static void CA_LogError(OSStatus error, const char *fmt, ...) {
    char errorString[20];
    *(uint32_t *)(errorString + 1) = CFSwapInt32HostToBig(error);
    if (isprint(errorString[1]) && isprint(errorString[2]) && isprint(errorString[3]) && isprint(errorString[4])) {
        errorString[0] = errorString[5] = '\''; errorString[6] = '\0';
    } else {
        snprintf(errorString, sizeof(errorString), "%d", (int)error);
    }
    char logBuffer[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(logBuffer, sizeof(logBuffer), fmt, args);
    va_end(args);
    Log(LOG_E, @"CoreAudio Error: %s (%s)", logBuffer, errorString);
}

static void CA_FourCC(uint32_t value, char *outFormatIDStr) {
    uint32_t formatID = CFSwapInt32HostToBig(value);
    memcpy(outFormatIDStr, &formatID, 4);
    outFormatIDStr[4] = '\0';
}

static void CA_PrintASBD(const char *description, const AudioStreamBasicDescription *asbd) {
    char formatIDStr[5];
    CA_FourCC(asbd->mFormatID, formatIDStr);
    DEBUG_TRACE(@"%s %7.1fHz %u bit %s [%u ch] %s", description, asbd->mSampleRate, asbd->mBitsPerChannel, formatIDStr, asbd->mChannelsPerFrame, (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? "non-interleaved" : "interleaved");
}

// =============================================================================
// Part 3: AllocatedAudioBufferList (Objective-C Class)
// =============================================================================

@interface AllocatedAudioBufferList : NSObject {
    @public AudioBufferList * bufferList;
}
- (instancetype)initWithChannelCount:(UInt32)count bufferSize:(uint16_t)size;
@end

@implementation AllocatedAudioBufferList

- (instancetype)initWithChannelCount:(UInt32)count bufferSize:(uint16_t)size {
    self = [super init];
    if (self) {
        bufferList = malloc(sizeof(AudioBufferList) + (sizeof(AudioBuffer) * count));
        bufferList->mNumberBuffers = count;
        for (UInt32 c = 0; c < count; ++c) {
            bufferList->mBuffers[c].mNumberChannels = 1;
            bufferList->mBuffers[c].mDataByteSize = size * sizeof(float);
            bufferList->mBuffers[c].mData = malloc(sizeof(float) * size);
        }
    }
    return self;
}

- (void)dealloc {
    if (bufferList) {
        for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) {
            free(bufferList->mBuffers[i].mData);
        }
        free(bufferList);
    }
}
@end

// =============================================================================
// Part 4: AUSpatialMixer (Objective-C Class)
// =============================================================================

@interface AUSpatialMixer : NSObject
- (BOOL)setupWithOutputType:(AUSpatialMixerOutputType)outputType inSampleRate:(double)inSampleRate outSampleRate:(double)outSampleRate inChannelCount:(int)inChannelCount;
- (void)process:(AudioBufferList *)outputABL timeStamp:(const AudioTimeStamp *)inTimeStamp frames:(float)inNumberFrames;
- (void)setRingBufferPtr:(TPCircularBuffer *)buffer;
- (OSStatus)setOutputType:(AUSpatialMixerOutputType)outputType;
@end

@implementation AUSpatialMixer {
    AudioUnit _mixer;
    TPCircularBuffer *_ringBufferPtr;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        AudioComponentDescription desc = {kAudioUnitType_Mixer, kAudioUnitSubType_SpatialMixer, kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        OSStatus status = AudioComponentInstanceNew(comp, &_mixer);
        if (status != noErr) {
            CA_LogError(status, "Failed to create Spatial Mixer");
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    if (_mixer) AudioComponentInstanceDispose(_mixer);
}

- (BOOL)setupWithOutputType:(AUSpatialMixerOutputType)outputType inSampleRate:(double)inSampleRate outSampleRate:(double)outSampleRate inChannelCount:(int)inChannelCount {
    uint32_t numInputs = 1;
    OSStatus status = AudioUnitSetProperty(_mixer, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &numInputs, sizeof(numInputs));
    if (status != noErr) return NO;

    // Output Stereo
    if (![self setStreamFormat:inSampleRate layoutTag:kAudioChannelLayoutTag_Stereo scope:kAudioUnitScope_Output element:0]) return NO;

    // Input Multichannel
    AudioChannelLayoutTag layout;
    switch (inChannelCount) {
        case 6: layout = kAudioChannelLayoutTag_WAVE_5_1_B; break;
        case 8: layout = kAudioChannelLayoutTag_WAVE_7_1; break;
        default: layout = kAudioChannelLayoutTag_Stereo; break;
    }
    if (![self setStreamFormat:inSampleRate layoutTag:layout scope:kAudioUnitScope_Input element:0]) return NO;

    uint32_t renderingAlgorithm = kSpatializationAlgorithm_UseOutputType;
    AudioUnitSetProperty(_mixer, kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input, 0, &renderingAlgorithm, sizeof(renderingAlgorithm));
    
    uint32_t sourceMode = kSpatialMixerSourceMode_AmbienceBed;
    AudioUnitSetProperty(_mixer, kAudioUnitProperty_SpatialMixerSourceMode, kAudioUnitScope_Input, 0, &sourceMode, sizeof(sourceMode));

    [self setOutputType:outputType];

    if (outputType == kSpatialMixerOutputType_Headphones) {
        
#if !TARGET_OS_VISION
        if (@available(iOS 15.0, macOS 12.3, tvOS 15.0, *)) {
            uint32_t ht = 1;
            AudioUnitSetProperty(_mixer, kAudioUnitProperty_SpatialMixerEnableHeadTracking, kAudioUnitScope_Global, 0, &ht, sizeof(uint32_t));
        }
#endif
        
        if (@available(iOS 18.0, visionOS 1.0, macOS 15.0, tvOS 18.0, *)) {
            uint32_t hrtf = kSpatialMixerPersonalizedHRTFMode_Auto;
            AudioUnitSetProperty(_mixer, kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode, kAudioUnitScope_Global, 0, &hrtf, sizeof(uint32_t));
        }
        
        // Bypass In-Head mode (enable spatialization)
        uint32_t inHead = 0;
        AudioUnitSetProperty(_mixer, kAudioUnitProperty_SpatialMixerPointSourceInHeadMode, kAudioUnitScope_Input, 0, &inHead, sizeof(uint32_t));
    }

    uint32_t mfps = 4096;
    AudioUnitSetProperty(_mixer, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &mfps, sizeof(mfps));

    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = mixerInputCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)self;
    AudioUnitSetProperty(_mixer, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callbackStruct, sizeof(callbackStruct));

    AudioUnitInitialize(_mixer);
    return YES;
}

- (void)process:(AudioBufferList *)outputABL timeStamp:(const AudioTimeStamp *)inTimeStamp frames:(float)inNumberFrames {
    AudioUnitRenderActionFlags actionFlags = 0;
    AudioUnitRender(_mixer, &actionFlags, inTimeStamp, 0, inNumberFrames, outputABL);
}

- (void)setRingBufferPtr:(TPCircularBuffer *)buffer {
    _ringBufferPtr = buffer;
}

- (OSStatus)setOutputType:(AUSpatialMixerOutputType)outputType {
    return AudioUnitSetProperty(_mixer, kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global, 0, &outputType, sizeof(outputType));
}

- (BOOL)setStreamFormat:(float)sampleRate layoutTag:(AudioChannelLayoutTag)tag scope:(AudioUnitScope)scope element:(AudioUnitElement)element {
    AVAudioChannelLayout* layout = [AVAudioChannelLayout layoutWithLayoutTag:tag];
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:sampleRate interleaved:NO channelLayout:layout];
    OSStatus status = AudioUnitSetProperty(_mixer, kAudioUnitProperty_StreamFormat, scope, element, [format streamDescription], sizeof(AudioStreamBasicDescription));
    return (status == noErr);
}

static OSStatus mixerInputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimestamp, uint32_t inBusNumber, uint32_t inNumberFrames, AudioBufferList *ioData) {
    AUSpatialMixer *self = (__bridge AUSpatialMixer *)inRefCon;
    
    for (uint32_t i = 0; i < ioData->mNumberBuffers; i++) {
         vDSP_vclr((float *)ioData->mBuffers[i].mData, 1, inNumberFrames * sizeof(float));
    }

    uint32_t availableBytes;
    float *ringBuffer = (float *)TPCircularBufferTail(self->_ringBufferPtr, &availableBytes);
    uint32_t channelCount = ioData->mNumberBuffers;
    uint32_t wantedBytes = channelCount * inNumberFrames * sizeof(float);

    if (availableBytes < wantedBytes) {
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
    } else {
        const float zero = 0.0f;
        for (uint32_t channel = 0; channel < channelCount; channel++) {
            float *channelBuffer = (float *)ioData->mBuffers[channel].mData;
            vDSP_vsadd(ringBuffer + channel, channelCount, &zero, channelBuffer, 1, inNumberFrames);
        }
        TPCircularBufferConsume(self->_ringBufferPtr, wantedBytes);
    }
    return noErr;
}

@end

// =============================================================================
// Part 5: OutputAU (Objective-C Class)
// =============================================================================

@interface OutputAU : NSObject
- (BOOL)prepareForPlayback:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig;
- (void)start;
- (void)stop;
- (void *)getAudioBuffer:(int *)size;
- (BOOL)submitAudio:(int)bytesWritten opusBytes:(int)opusBytes;
- (void)setNeedsReinit:(BOOL)needsReinit;
- (NSString *)getAudioStatsString;
@end

@implementation OutputAU {
    AudioComponentInstance _outputAU;
    AUSpatialMixer *_spatialAU;
    TPCircularBuffer _ringBuffer;
    AllocatedAudioBufferList *_spatialBuffer;
    
    double _sampleRateOpus;
    int _channelCount;
    int _samplesPerFrame;
    BOOL _isSpatial;
    BOOL _needsReinit;
    
    uint32_t _bitrateSum;
    uint32_t _opusPackets;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent comp = AudioComponentFindNext(nil, &desc);
        AudioComponentInstanceNew(comp, &_outputAU);
        memset(&_ringBuffer, 0, sizeof(TPCircularBuffer));
        _spatialAU = [[AUSpatialMixer alloc] init];
    }
    return self;
}

- (void)dealloc {
    if (_outputAU) AudioComponentInstanceDispose(_outputAU);
    TPCircularBufferCleanup(&_ringBuffer);
}

- (BOOL)prepareForPlayback:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig {
    _sampleRateOpus = opusConfig->sampleRate;
    _channelCount = opusConfig->channelCount;
    _samplesPerFrame = opusConfig->samplesPerFrame;

    AudioUnitInitialize(_outputAU);
    
    int packetsToBuffer = 50 / (_samplesPerFrame / (_sampleRateOpus / 1000.0));
    TPCircularBufferInit(&_ringBuffer, packetsToBuffer * _channelCount * _samplesPerFrame * sizeof(float));
    [_spatialAU setRingBufferPtr:&_ringBuffer];

    _spatialBuffer = [[AllocatedAudioBufferList alloc] initWithChannelCount:2 bufferSize:4096];

    _isSpatial = (_channelCount > 2);
    AUSpatialMixerOutputType outputType = [self getSpatialMixerOutputType];
    if (outputType == kSpatialMixerOutputType_ExternalSpeakers) _isSpatial = NO;

    AudioStreamBasicDescription streamDesc = {0};
    streamDesc.mSampleRate = _sampleRateOpus;
    streamDesc.mFormatID = kAudioFormatLinearPCM;
    streamDesc.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    streamDesc.mFramesPerPacket = 1;
    streamDesc.mChannelsPerFrame = (uint32_t)_channelCount;
    streamDesc.mBitsPerChannel = 32;
    streamDesc.mBytesPerPacket = 4 * _channelCount;
    streamDesc.mBytesPerFrame = streamDesc.mBytesPerPacket;

    if (_isSpatial) {
        streamDesc.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
        streamDesc.mBytesPerPacket = 4;
        streamDesc.mBytesPerFrame = 4;
        
        [_spatialAU setupWithOutputType:outputType inSampleRate:_sampleRateOpus outSampleRate:[AVAudioSession sharedInstance].sampleRate inChannelCount:_channelCount];
        [self setCallback:renderCallbackSpatial];
    } else {
        [self setCallback:renderCallbackDirect];
        
        AudioChannelLayoutTag layout = (_channelCount == 6) ? kAudioChannelLayoutTag_WAVE_5_1_B : (_channelCount == 8 ? kAudioChannelLayoutTag_WAVE_7_1 : kAudioChannelLayoutTag_Stereo);
        AVAudioChannelLayout* outLayout = [AVAudioChannelLayout layoutWithLayoutTag:layout];
        AudioUnitSetProperty(_outputAU, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, 0, [outLayout layout], sizeof(AudioChannelLayout));
    }

    return (AudioUnitSetProperty(_outputAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamDesc, sizeof(streamDesc)) == noErr);
}

- (void)setCallback:(AURenderCallback)callback {
    AURenderCallbackStruct renderCallback;
    renderCallback.inputProc = callback;
    renderCallback.inputProcRefCon = (__bridge void *)self;
    AudioUnitSetProperty(_outputAU, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Output, 0, &renderCallback, sizeof(renderCallback));
}

- (void *)getAudioBuffer:(int *)size {
    uint32_t bytesFree;
    void *ptr = TPCircularBufferHead(&_ringBuffer, &bytesFree);
    int bytesPerFrame = _channelCount * sizeof(float);
    *size = MIN(*size, (int)(bytesFree / bytesPerFrame) * bytesPerFrame);
    return ptr;
}

- (BOOL)submitAudio:(int)bytesWritten opusBytes:(int)opusBytes {
    if (_needsReinit) return NO;
    TPCircularBufferProduce(&_ringBuffer, bytesWritten);
    _bitrateSum += opusBytes;
    _opusPackets++;
    return YES;
}

- (void)start { AudioOutputUnitStart(_outputAU); }
- (void)stop { AudioOutputUnitStop(_outputAU); }
- (void)setNeedsReinit:(BOOL)val { _needsReinit = val; }

- (AUSpatialMixerOutputType)getSpatialMixerOutputType {
    NSString* pType = [AVAudioSession sharedInstance].currentRoute.outputs.firstObject.portType;
    if ([pType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) return kSpatialMixerOutputType_BuiltInSpeakers;
    if ([pType isEqualToString:AVAudioSessionPortHeadphones] || [pType isEqualToString:AVAudioSessionPortBluetoothA2DP]) return kSpatialMixerOutputType_Headphones;
    return kSpatialMixerOutputType_ExternalSpeakers;
}

- (NSString *)getAudioStatsString {
    uint32_t freeBytes;
    TPCircularBufferTail(&_ringBuffer, &freeBytes);
    uint32_t pcmBytes = _ringBuffer.length - freeBytes;
    return [NSString stringWithFormat:@"Stream: %dch | Buffer: %.0f%%", _channelCount, (double)(pcmBytes * 100.0 / _ringBuffer.length)];
}

static OSStatus renderCallbackSpatial(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, uint32_t inBusNumber, uint32_t inNumberFrames, AudioBufferList *ioData) {
    OutputAU *self = (__bridge OutputAU *)inRefCon;
    AudioBufferList *spatialBuffer = self->_spatialBuffer->bufferList;
    
    for (uint32_t i = 0; i < spatialBuffer->mNumberBuffers; i++) spatialBuffer->mBuffers[i].mDataByteSize = inNumberFrames * sizeof(float);
    
    [self->_spatialAU process:spatialBuffer timeStamp:inTimeStamp frames:inNumberFrames];
    
    for (uint32_t i = 0; i < spatialBuffer->mNumberBuffers; i++) {
        vDSP_mmov((const float *)spatialBuffer->mBuffers[i].mData, (float *)ioData->mBuffers[i].mData, 1, inNumberFrames * sizeof(float), 1, 1);
    }
    return noErr;
}

static OSStatus renderCallbackDirect(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, uint32_t inBusNumber, uint32_t inNumberFrames, AudioBufferList *ioData) {
    OutputAU *self = (__bridge OutputAU *)inRefCon;
    int bytesToCopy = ioData->mBuffers[0].mDataByteSize;
    float *targetBuffer = (float *)ioData->mBuffers[0].mData;
    uint32_t availableBytes;
    float *buffer = (float *)TPCircularBufferTail(&self->_ringBuffer, &availableBytes);
    
    if ((int)availableBytes < bytesToCopy) {
        vDSP_vclr(targetBuffer, 1, bytesToCopy);
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
    } else {
        vDSP_mmov(buffer, targetBuffer, 1, MIN(bytesToCopy, (int)availableBytes), 1, 1);
        TPCircularBufferConsume(&self->_ringBuffer, MIN(bytesToCopy, (int)availableBytes));
    }
    return noErr;
}

@end

// =============================================================================
// Part 6: SpatialAudioRenderer Wrapper
// =============================================================================

@implementation SpatialAudioRenderer {
    OutputAU *_outputAU;
}

-(instancetype)initWithConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig {
    self = [super init];
    if (self) {
        _outputAU = [[OutputAU alloc] init];
        if (![_outputAU prepareForPlayback:opusConfig]) return nil;
        
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleRouteChange:) name:AVAudioSessionRouteChangeNotification object:nil];
    }
    return self;
}

-(void)start {
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    [_outputAU start];
}

-(void)stop {
    [_outputAU stop];
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
}

-(void *)getAudioBuffer:(int *)size {
    return [_outputAU getAudioBuffer:size];
}

-(BOOL)submitAudio:(int)bytesWritten opusBytes:(int)opusBytes decodeStartTime:(CFTimeInterval)decodeStartTime {
    return [_outputAU submitAudio:bytesWritten opusBytes:opusBytes];
}

-(NSString *)getAudioStatsString {
    return [_outputAU getAudioStatsString];
}

-(void)handleRouteChange:(NSNotification *)notification {
    [_outputAU setNeedsReinit:YES];
}

@end
