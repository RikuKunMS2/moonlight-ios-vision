#import "OutputAU.h"
#import "CoreAudioHelpers.h"
#import "AudioStats.h"
#import "DataManager.h"
#import "TemporarySettings.h"

#include <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_OSX
#import <IOKit/audio/IOAudioTypes.h>
#endif



#define kMaxBufferSize 4096
#define kBufferSizeFactor 1 // buffer will be 5ms * this
#define BUFFER_DURATION_MS 50

@implementation OutputAU


- (instancetype)init {
    self = [super init];
    if (self) {
        _spatialBuffer = [[AllocatedAudioBufferList alloc] initWithChannelCount:2 bufferSize:kMaxBufferSize];
        _bitrateSum = 0;
        _opusPackets = 0;
        _opusToPCMTime = 0.0;
        _pcmToOutputTime = 0.0;

#if TARGET_OS_OSX
        _spatialAU = [[AUSpatialMixer alloc] init];

        AudioComponentDescription description;
        description.componentType = kAudioUnitType_Output;
        description.componentSubType = kAudioUnitSubType_HALOutput;
        description.componentManufacturer = kAudioUnitManufacturer_Apple;
        description.componentFlags = 0;
        description.componentFlagsMask = 0;

        AudioComponent comp = AudioComponentFindNext(NULL, &description);
        if (!comp) return self;

        OSStatus status = AudioComponentInstanceNew(comp, &_outputAU);
        if (status != noErr) {
            CA_LogError(status, "Failed to create an instance of HALOutput");
        }
#else
        // Defer _engine initialization to prepareForPlayback
#endif
    }
    return self;
}

- (void)dealloc
{
#if TARGET_OS_OSX
    if (_outputAU) {
        AudioComponentInstanceDispose(_outputAU);
    }
#else
    if (_engine) {
        [_engine stop];
        _engine = nil;
    }
#endif
}

#if TARGET_OS_OSX
// Warning: realtime callback function
static OSStatus renderCallbackSpatial(void * __nullable inRefCon,
                               AudioUnitRenderActionFlags * __nullable ioActionFlags,
                               const AudioTimeStamp       * __nullable inTimeStamp,
                               uint32_t                       inBusNumber,
                               uint32_t                       inNumberFrames,
                               AudioBufferList            * __nullable ioData)
{
    OutputAU *me = (__bridge OutputAU *)(inRefCon);
    AudioBufferList *spatialBuffer = [me.spatialBuffer get];

    // Set the byte size with the output audio buffer list.
    for (uint32_t i = 0; i < spatialBuffer->mNumberBuffers; i++) {
        spatialBuffer->mBuffers[i].mDataByteSize = inNumberFrames * sizeof(float);
    }

    // Process the input frames with the audio unit spatial mixer.
    [me.spatialAU processWithOutputABL:spatialBuffer timeStamp:inTimeStamp numberFrames:inNumberFrames];

    static int spatialRenderCounter = 0;
    if (spatialRenderCounter++ % 200 == 0) {
        DEBUG_TRACE(@"[Audio Debug] renderCallbackSpatial called for %d frames", inNumberFrames);
    }

    // Copy the temporary buffer to the output.
    for (uint32_t i = 0; i < spatialBuffer->mNumberBuffers; i++) {
        memcpy(ioData->mBuffers[i].mData, spatialBuffer->mBuffers[i].mData, inNumberFrames * sizeof(float));
    }

    return noErr;
}

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

// Warning: realtime callback function
static OSStatus renderCallbackDirect(void * __nullable inRefCon,
                              AudioUnitRenderActionFlags * __nullable ioActionFlags,
                              const AudioTimeStamp       * __nullable inTimeStamp,
                              uint32_t                       inBusNumber,
                              uint32_t                       inNumberFrames,
                              AudioBufferList            * __nullable ioData)
{
    OutputAU *me = (__bridge OutputAU *)(inRefCon);
    int bytesToCopy = ioData->mBuffers[0].mDataByteSize;
    float *targetBuffer = (float *)ioData->mBuffers[0].mData;

    // Pull audio from playthrough buffer
    uint32_t availableBytes;
    float *buffer = (float *)TPCircularBufferTail(&me->_ringBuffer, &availableBytes);

    if ((int)availableBytes < bytesToCopy) {
        // write silence if not enough buffered data is available
        memset(targetBuffer, 0, bytesToCopy);
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;

        ch.starvedCounter++;
        if (ch.state == OK) {
            // Log only once when switching states
            DEBUG_TRACE(@"direct callback starved after %d OK callbacks: wanted %d, avail %d\n",
                        ch.okCounter, bytesToCopy, availableBytes);
            ch.okCounter = 0;
            ch.state = STARVED;
        }
    }
    else {
        memcpy(targetBuffer, buffer, MIN(bytesToCopy, (int)availableBytes));
        TPCircularBufferConsume(&me->_ringBuffer, MIN(bytesToCopy, (int)availableBytes));

        ch.okCounter++;
        if (ch.state == STARVED) {
            // Log only once when switching states
            DEBUG_TRACE(@"direct callback OK after %d starved callbacks: consumed %d\n",
                        ch.starvedCounter, MIN(bytesToCopy, (int)availableBytes));
            ch.starvedCounter = 0;
            ch.state = OK;
        }
    }

    return noErr;
}
#endif

- (BOOL)prepareForPlayback:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
{
    _sampleRateOpus  = opusConfig->sampleRate;
    _channelCount    = opusConfig->channelCount;
    _samplesPerFrame = opusConfig->samplesPerFrame;

    _audioPacketDuration = (_samplesPerFrame / (_sampleRateOpus / 1000.0)) / 1000.0; // 5ms

#if TARGET_OS_OSX
    OSStatus status = noErr;
    _sampleRateHW    = [self getSampleRate];

    if (![self initAudioUnit]) {
        DEBUG_TRACE(@"initAudioUnit failed");
        return NO;
    }

    if (![self initRingBuffer]) {
        DEBUG_TRACE(@"initRingBuffer failed");
        return NO;
    }

    AVAudioSession *session = [AVAudioSession sharedInstance];
    int physicalOutputChannels = (int)[session maximumOutputNumberOfChannels];

    AUSpatialMixerOutputType outputType = [self getSpatialMixerOutputType];

    Log(LOG_I, @"OutputAU preparing, input: opus %d channels, %d spf, %.3f packet size -> output: %d channels, %.0f khz, %f IOBuffer, %@",
        _channelCount, _samplesPerFrame, _audioPacketDuration,
        physicalOutputChannels, _sampleRateHW, _ioBufferDuration, [self getSMOTString:outputType]);

    _isSpatial = NO;
    if (_channelCount > 2) {
        if (outputType != kSpatialMixerOutputType_ExternalSpeakers) {
            _isSpatial = YES;
        }
    }

    // check if user has chosen to disable spatial audio
    int spatialAudioMode = (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"spatialAudioMode"];
    if (spatialAudioMode == 0) { // 0 == stereo (disabled)
        _isSpatial = NO;
        Log(LOG_I, @"OutputAU user has disabled spatial audio");
    }

    // indicate the format our callback will provide samples in
    AudioStreamBasicDescription streamDesc;
    memset(&streamDesc, 0, sizeof(AudioStreamBasicDescription));
    streamDesc.mSampleRate       = _sampleRateOpus;
    streamDesc.mFormatID         = kAudioFormatLinearPCM;
    streamDesc.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    streamDesc.mFramesPerPacket  = 1;
    streamDesc.mChannelsPerFrame = (uint32_t)_channelCount;
    streamDesc.mBitsPerChannel   = 32;
    streamDesc.mBytesPerPacket   = 4 * _channelCount;
    streamDesc.mBytesPerFrame    = streamDesc.mBytesPerPacket;

    if (_isSpatial) {
        if (![_spatialAU setupWithOutputType:outputType inSampleRate:_sampleRateOpus outSampleRate:_sampleRateHW inChannelCount:_channelCount]) {
            DEBUG_TRACE(@"_spatialAU.setup failed");
            return NO;
        }

        [self setCallbackWithContext:(__bridge void *)self callback:renderCallbackSpatial];

        // Let AVAudioFormat handle the complexities of non-interleaved stereo
        AVAudioChannelLayout* outLayout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_Stereo];
        AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                                 sampleRate:_sampleRateOpus
                                                                interleaved:NO
                                                              channelLayout:outLayout];

        const AudioStreamBasicDescription* asbd = [format streamDescription];
        CA_PrintASBD("OutputAU spatial stream description:", asbd);

        status = AudioUnitSetProperty(_outputAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, asbd, sizeof(AudioStreamBasicDescription));
        if (status != noErr) {
            CA_LogError(status, "Failed to set output stream format");
            return NO;
        }
        
        // Also set the AudioChannelLayout on the hardware output unit
        const AudioChannelLayout* outLayout2 = [outLayout layout];
        UInt32 layoutSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (outLayout2->mNumberChannelDescriptions * sizeof(AudioChannelDescription));
        status = AudioUnitSetProperty(_outputAU, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, 0, outLayout2, layoutSize);
        if (status != noErr) {
            CA_LogError(status, "Failed to set OutputAU AudioChannelLayout for spatial mode");
            return NO;
        }

        Log(LOG_I, @"OutputAU is using spatial audio output");
    }
    else {
        // direct CoreAudio, for stereo or when enough real channels are available (HDMI)
        [self setCallbackWithContext:(__bridge void *)self callback:renderCallbackDirect];

        status = AudioUnitSetProperty(_outputAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamDesc, sizeof(streamDesc));
        if (status != noErr) {
            CA_LogError(status, "Failed to set output stream format");
            return NO;
        }

        NSError *error = nil;
        Log(LOG_I, @"OutputAU is using passthrough mode");
        [session setPreferredOutputNumberOfChannels:_channelCount error:&error];
        if (error != nil) {
            Log(LOG_W, @"Warning: failed to set preferred output number of channels to %d: %@", _channelCount, error.localizedDescription);
            // probably ok to continue
        }
        DEBUG_TRACE(@"OutputAU setPreferredOutputNumberOfChannels:%d", _channelCount);

        // Define the direct output stream format to ensure correct multichannel mapping
        AudioChannelLayoutTag layout;
        switch (_channelCount) {
            case 2:
                layout = kAudioChannelLayoutTag_Stereo;
                break;
            case 6:
                layout = kAudioChannelLayoutTag_WAVE_5_1_B; // L R C LFE Rls Rrs
                break;
            case 8:
                layout = kAudioChannelLayoutTag_WAVE_7_1; // L R C LFE Rls Rrs Ls Rs
                break;
            default:
                CA_LogError(-1, "Unsupported number of channels for direct audio mode: %d", _channelCount);
                return NO;
        }

        AVAudioChannelLayout* outLayout = [AVAudioChannelLayout layoutWithLayoutTag:layout];
        AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                                 sampleRate:_sampleRateOpus
                                                                interleaved:YES
                                                              channelLayout:outLayout];

        const AudioStreamBasicDescription* asbd = [format streamDescription];
        CA_PrintASBD("OutputAU AudioStreamBasicDescription:", asbd);

        const AudioChannelLayout* outLayout2 = [outLayout layout];
        UInt32 layoutSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (outLayout2->mNumberChannelDescriptions * sizeof(AudioChannelDescription));
        OSStatus status = AudioUnitSetProperty(_outputAU, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, 0, outLayout2, layoutSize);
        if (status != noErr) {
            CA_LogError(status, "Failed to set OutputAU AudioChannelLayout scope=%d, layout=%d", kAudioUnitScope_Input, outLayout2);
            return status;
        }
        Log(LOG_I, @"OutputAU passthrough channel layout set for %d channels", _channelCount);
    }

    OSStatus statusInit = AudioUnitInitialize(_outputAU);
    if (statusInit != noErr) {
        CA_LogError(statusInit, "Failed to initialize the output audio unit");
        return NO;
    }

    return YES;
#else
    // iOS/tvOS/visionOS implementation using AVAudioEngine
    __block AVAudioSession *session = nil;
    __block NSError *error = nil;

    dispatch_sync(dispatch_get_main_queue(), ^{
        session = [AVAudioSession sharedInstance];

        // CRITICAL: We MUST activate the audio session before instantiating AVAudioEngine!
        // If the session is inactive when AVAudioEngine is created, visionOS throws a
        // "Session lookup failed" (-50) error because the engine captures a null proxy.
        // Doing this synchronously on the main thread ensures the CoreAudio daemon registers it.
        [session setCategory:AVAudioSessionCategoryPlayback error:&error];
        [session setMode:AVAudioSessionModeMoviePlayback error:&error];
        [session setActive:YES error:&error];
        if (error) {
            CA_LogError(-1, "Failed to activate AVAudioSession: %@", error.localizedDescription);
        }

        if (_engine) {
            [_engine stop];
            _engine = nil;
        }
        _engine = [[AVAudioEngine alloc] init];
    });

    [session setPreferredSampleRate:_sampleRateOpus error:&error];
    if (error) {
        CA_LogError(-1, "failed to set preferred samplerate to %.0f: %@", _sampleRateOpus, error.localizedDescription);
    }

    double wantedBuffer = _audioPacketDuration * kBufferSizeFactor;
    [session setPreferredIOBufferDuration:wantedBuffer error:&error];
    if (error) {
        CA_LogError(-1, "failed to set preferred buffer duration to %f: %@", wantedBuffer, error.localizedDescription);
    }
    
    _sampleRateHW = [session sampleRate];

    if (![self initRingBuffer]) {
        DEBUG_TRACE(@"initRingBuffer failed");
        return NO;
    }

    Log(LOG_I, @"OutputAU preparing AVAudioEngine, input: opus %d channels", _channelCount);

    AudioChannelLayoutTag layoutTag;
    switch (_channelCount) {
        case 2: layoutTag = kAudioChannelLayoutTag_Stereo; break;
        case 6: layoutTag = kAudioChannelLayoutTag_AudioUnit_5_1; break;
        case 8: layoutTag = kAudioChannelLayoutTag_AudioUnit_7_1; break;
        default:
            CA_LogError(-1, "Unsupported number of channels: %d", _channelCount);
            return NO;
    }

    AVAudioChannelLayout *layout = [[AVAudioChannelLayout alloc] initWithLayoutTag:layoutTag];
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                             sampleRate:_sampleRateOpus
                                                            interleaved:NO
                                                          channelLayout:layout];

    __weak OutputAU *weakSelf = self;
    _sourceNode = [[AVAudioSourceNode alloc] initWithRenderBlock:^OSStatus(BOOL * _Nonnull isSilence, const AudioTimeStamp * _Nonnull timestamp, AVAudioFrameCount frameCount, AudioBufferList * _Nonnull outputData) {
        OutputAU *me = weakSelf;
        if (!me) return noErr;

        static int renderCounter = 0;
        if (renderCounter++ % 200 == 0) {
            DEBUG_TRACE(@"[Audio Debug] AVAudioSourceNode render block called for %d frames", frameCount);
        }

        int channels = me->_channelCount;
        int framesToRead = frameCount;
        int bytesWanted = framesToRead * channels * sizeof(float);

        uint32_t availableBytes;
        float *buffer = (float *)TPCircularBufferTail(&me->_ringBuffer, &availableBytes);

        if ((int)availableBytes < bytesWanted) {
            for (int c = 0; c < channels; c++) {
                if (c < outputData->mNumberBuffers) {
                    memset(outputData->mBuffers[c].mData, 0, framesToRead * sizeof(float));
                }
            }
            *isSilence = YES;
        } else {
            // De-interleave from _ringBuffer into outputData
            for (int c = 0; c < channels; c++) {
                if (c < outputData->mNumberBuffers) {
                    float *dest = (float *)outputData->mBuffers[c].mData;
                    for (int f = 0; f < framesToRead; f++) {
                        dest[f] = buffer[f * channels + c];
                    }
                }
            }
            TPCircularBufferConsume(&me->_ringBuffer, bytesWanted);
        }
        return noErr;
    }];

    [_engine attachNode:_sourceNode];
    [_engine connect:_sourceNode to:_engine.mainMixerNode format:format];
    [_engine prepare];

    return YES;
#endif
}

- (BOOL)initAudioUnit
{
    OSStatus status = noErr;
    // Initialize the audio unit interface to begin configuring it.
    // AudioUnitInitialize(_outputAU) is called at the end of prepareForPlayback.

    /* macOS:
     * disable OutputAU input IO
     * enable OutputAU output IO
     * get system default output AudioDeviceID  (todo: allow user to choose specific device from list)
     * set OutputAU to AudioDeviceID
     * get device's AudioStreamBasicDescription (format, bit depth, samplerate, etc)
     * get device name
     * get output buffer frame size
     * get output buffer min/max
     * set output buffer frame size
     */

    _outputSoftwareLatencyMin = 0.0;
    _outputSoftwareLatencyMax = 0.0;
    _totalSoftwareLatency     = 0.0025; // Opus has 2.5ms of initial delay

#if TARGET_OS_OSX
    const AudioUnitElement outputElement = 0;
    const AudioUnitElement inputElement = 1;

    {
        uint32_t enableIO = 0;
        status = AudioUnitSetProperty(_outputAU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputElement, &enableIO, sizeof(enableIO));
        if (status != noErr) {
            CA_LogError(status, "Failed to disable the input on AUHAL");
            return NO;
        }

        enableIO = 1;
        status = AudioUnitSetProperty(_outputAU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, outputElement, &enableIO, sizeof(enableIO));
        if (status != noErr) {
            CA_LogError(status, "Failed to enable the output on AUHAL");
            return NO;
        }
    }

    {
        uint32_t size = sizeof(AudioDeviceID);
        AudioObjectPropertyAddress addr = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData((AudioObjectID)kAudioObjectSystemObject, &addr, outputElement, nil, &size, &_outputDeviceID);
        if (status != noErr) {
            CA_LogError(status, "Failed to get the default output device");
            return NO;
        }
    }

    {
        CFStringRef name;
        uint32_t nameSize = sizeof(CFStringRef);
        AudioObjectPropertyAddress addr = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(_outputDeviceID, &addr, 0, nil, &nameSize, &name);
        if (status != noErr) {
            CA_LogError(status, "Failed to get name of output device");
            return NO;
        }
        if (_outputDeviceName) free(_outputDeviceName);
        _outputDeviceName = strdup([(__bridge NSString *)name UTF8String]);
        CFRelease(name);
        DEBUG_TRACE(@"OutputAU default output device ID: %d, name: %s", _outputDeviceID, _outputDeviceName);
    }

    {
        // Set the current device to the default output device.
        // This should be done only after I/O is enabled on the output audio unit.
        status = AudioUnitSetProperty(_outputAU, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, outputElement, &_outputDeviceID, sizeof(AudioDeviceID));
        if (status != noErr) {
            CA_LogError(status, "Failed to set the default output device");
            return NO;
        }
    }

    {
        uint32_t streamFormatSize = sizeof(AudioStreamBasicDescription);
        AudioObjectPropertyAddress addr = {kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(_outputDeviceID, &addr, 0, nil, &streamFormatSize, &_outputASBD);
        if (status != noErr) {
            CA_LogError(status, "Failed to get output device AudioStreamBasicDescription");
            return NO;
        }
        CA_PrintASBD("OutputAU output format:", &_outputASBD);
    }

    // Buffer:
    // The goal here is to set the system buffer to our desired value, which is currently in _audioPacketDuration.
    // First we get the current value, and the range of allowed values, set our value, and then query to find the actual value.
    // We also query the hardware latency (e.g. Bluetooth delay for AirPods), but this is just for fun

    {
        uint32_t bufferFrameSize = 0;
        uint32_t size = sizeof(uint32_t);
        AudioObjectPropertyAddress addr = {kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(_outputDeviceID, &addr, 0, nil, &size, &bufferFrameSize);
        if (status != noErr) {
            CA_LogError(status, "Failed to get the output device buffer frame size");
            return NO;
        }
        DEBUG_TRACE(@"OutputAU output current BufferFrameSize %d", bufferFrameSize);
    }

    {
        AudioValueRange avr;
        uint32_t size = sizeof(AudioValueRange);
        AudioObjectPropertyAddress addr = {kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(_outputDeviceID, &addr, 0, nil, &size, &avr);
        if (status != noErr) {
            CA_LogError(status, "Failed to get the output device buffer frame size range");
            return NO;
        }
        _outputSoftwareLatencyMin = avr.mMinimum / _outputASBD.mSampleRate;
        _outputSoftwareLatencyMax = avr.mMaximum / _outputASBD.mSampleRate;
        DEBUG_TRACE(@"OutputAU output BufferFrameSizeRange: %.0f - %.0f", avr.mMinimum, avr.mMaximum);
    }

    // The latency values we have access to are:
    // kAudioDevicePropertyBufferFrameSize    our requested buffer as close to Opus packet size as possible
    //   + kAudioDevicePropertySafetyOffset   an additional CoreAudio buffer
    //   + kAudioUnitProperty_Latency         processing latency of OutputAU (+ SpatialAU in spatial mode)
    //   = total software latency
    // kAudioDevicePropertyLatency = hardware latency

    {
        double desiredBufferFrameSize = _audioPacketDuration;
        desiredBufferFrameSize = MAX(MIN(desiredBufferFrameSize, _outputSoftwareLatencyMax), _outputSoftwareLatencyMin);
        uint32_t bufferFrameSize = (uint32_t)(desiredBufferFrameSize * _outputASBD.mSampleRate);
        AudioObjectPropertyAddress addrSet = {kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
        status = AudioObjectSetPropertyData(_outputDeviceID, &addrSet, 0, NULL, sizeof(uint32_t), &bufferFrameSize);
        if (status != noErr) {
            CA_LogError(status, "Failed to set the output device buffer frame size");
            return NO;
        }
        DEBUG_TRACE(@"OutputAU output requested BufferFrameSize of %d (%0.3f ms)", bufferFrameSize, desiredBufferFrameSize * 1000.0);

        // see what we got
        uint32_t size = sizeof(uint32_t);
        AudioObjectPropertyAddress addrGet = {kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(_outputDeviceID, &addrGet, 0, nil, &size, &_bufferFrameSize);
        if (status != noErr) {
            CA_LogError(status, "Failed to get the output device buffer frame size");
            return NO;
        }
        double bufferFrameLatency = (double)_bufferFrameSize / _outputASBD.mSampleRate;
        _totalSoftwareLatency += bufferFrameLatency;
        DEBUG_TRACE(@"OutputAU output now has actual BufferFrameSize of %d (%0.3f ms)", _bufferFrameSize, bufferFrameLatency * 1000.0);
    }

    {
        uint32_t safetyOffsetLatency = 0;
        uint32_t size = sizeof(safetyOffsetLatency);
        AudioObjectPropertyAddress addrGet = {kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(_outputDeviceID, &addrGet, 0, nil, &size, &safetyOffsetLatency);
        if (status != noErr) {
            CA_LogError(status, "Failed to get safety offset latency");
            return NO;
        }
        _totalSoftwareLatency += (double)safetyOffsetLatency / _outputASBD.mSampleRate;
        DEBUG_TRACE(@"OutputAU OutputAU safety latency: %0.2f ms", ((double)safetyOffsetLatency / _outputASBD.mSampleRate) * 1000.0);
    }

    {
        uint32_t latencyFrames;
        uint32_t size = sizeof(uint32_t);
        AudioObjectPropertyAddress addr = {kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(_outputDeviceID, &addr, 0, nil, &size, &latencyFrames);
        if (status != noErr) {
            CA_LogError(status, "Failed to get the output device hardware latency");
            return NO;
        }
        _outputHardwareLatency = (double)latencyFrames / _outputASBD.mSampleRate;
        DEBUG_TRACE(@"OutputAU output hardware latency: %d (%0.2f ms)", latencyFrames, _outputHardwareLatency * 1000.0);
    }
#else
    AVAudioSession *session = [AVAudioSession sharedInstance];

    // set iOS metadata
    {
        NSError *error = nil;
        [session setPreferredSampleRate:_sampleRateOpus error:&error];
        if (error != nil) {
            CA_LogError(-1, "failed to set preferred samplerate to %.0f: %@", _sampleRateOpus, error.localizedDescription);
            // maybe ok?
        }
        // actual samplerate is checked in refreshDeviceMetadata() after setActive
    }

    // iOS buffer size
    {
        double wantedBuffer = _audioPacketDuration * kBufferSizeFactor;

        NSError *error = nil;
        [session setPreferredIOBufferDuration:wantedBuffer error:&error];
        if (error != nil) {
            CA_LogError(-1, "failed to set preferred buffer duration to %f: %@", wantedBuffer, error.localizedDescription);
            return NO;
        }
        DEBUG_TRACE(@"OutputAU setPreferredIOBufferDuration %f", wantedBuffer);
        // actual buffer is checked in refreshDeviceMetadata() after setActive
    }

#endif

    // The time, in seconds, that it takes an audio unit to move an audio sample from its input to its output.
    {
        double audioUnitLatency = 0.0;
        uint32_t size = sizeof(audioUnitLatency);
        status = AudioUnitGetProperty(_outputAU, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &audioUnitLatency, &size);
        if (status != noErr) {
            CA_LogError(status, "Failed to get OutputAU AudioUnit latency");
            return NO;
        }
        _totalSoftwareLatency += audioUnitLatency;
        DEBUG_TRACE(@"OutputAU AudioUnit latency: %0.2f ms", audioUnitLatency * 1000.0);
    }

    return YES;
}

- (BOOL)initRingBuffer
{
    // init ring buffer, entries = 16 when duration = 80ms and packet size 5ms
    int packetsToBuffer = BUFFER_DURATION_MS / (_samplesPerFrame / (_sampleRateOpus / 1000.0));
    int ringBufferSize = packetsToBuffer * _channelCount * _samplesPerFrame * sizeof(float);
    bool ok = TPCircularBufferInit(&_ringBuffer, ringBufferSize);
    if (!ok) {
        CA_LogError(-1, "TPCircularBufferInit failed");
        return NO;
    }

    // Spatial mixer code needs to be able to read from the ring buffer
    [_spatialAU setRingBufferPtr:&_ringBuffer];

    // real length will be larger than requested due to memory page alignment
    _bufferSize = _ringBuffer.length;
    DEBUG_TRACE(@"OutputAU ringBuffer created for %d packets, size %d (adjusted %d)",
                packetsToBuffer, ringBufferSize, _bufferSize);

    return YES;
}

- (AUSpatialMixerOutputType)getSpatialMixerOutputType
{
#if TARGET_OS_OSX

    // Check if headphones are plugged in.
    UInt32 dataSource = 0;
    UInt32 size = sizeof(dataSource);

    AudioObjectPropertyAddress addTransType = {kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    OSStatus status = AudioObjectGetPropertyData(_outputDeviceID, &addTransType, 0, NULL, &size, &dataSource);
    if (status != noErr) {
        CA_LogError(status, "Failed to get the transport type of output device");
        return kSpatialMixerOutputType_ExternalSpeakers;
    }

    char outputTransportType[5];
    CA_FourCC(dataSource, outputTransportType);
    DEBUG_TRACE(@"OutputAU output transport type %s", outputTransportType);

    if (dataSource == kAudioDeviceTransportTypeHDMI) {
        dataSource = kIOAudioOutputPortSubTypeExternalSpeaker;
    } else if (dataSource == kAudioDeviceTransportTypeBluetooth || dataSource == kAudioDeviceTransportTypeUSB) {
        dataSource = kIOAudioOutputPortSubTypeHeadphones;
    } else {
        AudioObjectPropertyAddress theAddress = {kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};

        status = AudioObjectGetPropertyData(_outputDeviceID, &theAddress, 0, NULL, &size, &dataSource);
        if (status != noErr) {
            CA_LogError(status, "Couldn't determine default audio device type, defaulting to ExternalSpeakers");
            return kSpatialMixerOutputType_ExternalSpeakers;
        }
    }

    char outputDataSource[5];
    CA_FourCC(dataSource, outputDataSource);
    DEBUG_TRACE(@"OutputAU output data source %s", outputDataSource);

    switch (dataSource) {
        case kIOAudioOutputPortSubTypeInternalSpeaker:
            return kSpatialMixerOutputType_BuiltInSpeakers;
            break;

        case kIOAudioOutputPortSubTypeHeadphones:
            return kSpatialMixerOutputType_Headphones;
            break;

        case kIOAudioOutputPortSubTypeExternalSpeaker:
            return kSpatialMixerOutputType_ExternalSpeakers;
            break;

        default:
            return kSpatialMixerOutputType_Headphones;
            break;
    }

#else

    AVAudioSession *audioSession = [AVAudioSession sharedInstance];

    if ([audioSession.currentRoute.outputs count] != 1) {
        DEBUG_TRACE(@"OutputAU current route has multiple outputs, spatial audio disabled");
        return kSpatialMixerOutputType_ExternalSpeakers;
    }
    else {
        NSString* pType = audioSession.currentRoute.outputs.firstObject.portType;
        DEBUG_TRACE(@"OutputAU current route port type %@", pType);
        if (   [pType isEqualToString:AVAudioSessionPortHeadphones]
            || [pType isEqualToString:AVAudioSessionPortBluetoothA2DP]
            || [pType isEqualToString:AVAudioSessionPortBluetoothLE]
            || [pType isEqualToString:AVAudioSessionPortBluetoothHFP]
            || [pType isEqualToString:AVAudioSessionPortUSBAudio])
        {
            return kSpatialMixerOutputType_Headphones;
        }
        else if ([pType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
            return kSpatialMixerOutputType_BuiltInSpeakers;
        }
        else {
            return kSpatialMixerOutputType_ExternalSpeakers;
        }
    }

#endif
}

static NSString * const SMOT[] = {
    [kSpatialMixerOutputType_Headphones] = @"Headphones",
    [kSpatialMixerOutputType_BuiltInSpeakers] = @"BuiltInSpeakers",
    [kSpatialMixerOutputType_ExternalSpeakers] = @"ExternalSpeakers"
};

- (NSString *)getSMOTString:(AUSpatialMixerOutputType)type
{
    if (type >= 1 && type <= 3) {
        return SMOT[type];
    }
    return @"Unknown";
}

- (void)setCallbackWithContext:(void *)context callback:(AURenderCallback)callback
{
    AURenderCallbackStruct renderCallback = { callback, context };

    OSStatus status = AudioUnitSetProperty(_outputAU, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &renderCallback, sizeof(renderCallback));
    if (status != noErr) {
        CA_LogError(status, "Failed to set output render callback");
    }
}

- (void *)getAudioBuffer:(int *)size
{
    // This provides a buffer for the Opus API to write into.
    //
    // We must always write a full frame of audio. If we don't,
    // the reader will get out of sync with the writer and our
    // channels will get all mixed up. To ensure this is always
    // the case, round our bytes free down to the next multiple
    // of our frame size.
    uint32_t bytesFree;
    void *ptr = TPCircularBufferHead(&_ringBuffer, &bytesFree);
    int bytesPerFrame = _channelCount * sizeof(float);
    *size = (int)(bytesFree / bytesPerFrame) * bytesPerFrame;

    _bufferFilledBytes = _ringBuffer.length - bytesFree;

    return ptr;
}

- (BOOL)submitAudioWithBytesWritten:(int)bytesWritten opusBytes:(int)opusBytes decodeStartTime:(CFTimeInterval)decodeStartTime
{
    // Called after Opus has decoded bytesWritten bytes of PCM into our buffer

#if !TARGET_OS_OSX
    if (_engine && !_engine.isRunning) {
        NSError *error = nil;
        if (![_engine startAndReturnError:&error]) {
            DEBUG_TRACE(@"[Audio Debug] Failed to restart AVAudioEngine: %@", error.localizedDescription);
        } else {
            DEBUG_TRACE(@"[Audio Debug] AVAudioEngine was stopped. Successfully restarted it.");
        }
    }
#endif

    static int submitAudioCounter = 0;
    if (submitAudioCounter++ % 200 == 0) {
        uint32_t freeBytes = 0;
        TPCircularBufferHead(&_ringBuffer, &freeBytes);
        DEBUG_TRACE(@"[Audio Debug] submitAudio: %d bytes (Opus: %d), ring buffer free: %u", bytesWritten, opusBytes, freeBytes);
    }

    if (_needsReinit) {
        // If an audio device has changed, this flag will be set. Break out
        // so we can be recreated.
        return NO;
    }

    // drop packet if we've fallen behind Moonlight's queue by twice our buffer
    // XXX needs tuning
    int pendingAudio = LiGetPendingAudioDuration();
    if (pendingAudio > BUFFER_DURATION_MS * 2) {
        DEBUG_TRACE(@"submitAudio skip-ahead, pending audio duration: %d ms", pendingAudio);
        return YES;
    }

    // Advance the write pointer
    TPCircularBufferProduce(&_ringBuffer, bytesWritten);

    // accumulate stats
    _bitrateSum += opusBytes;
    _opusPackets++;
    _opusToPCMTime += (CACurrentMediaTime() - decodeStartTime);

    return YES;
}

- (double)getSampleRate
{
#if TARGET_OS_OSX
    AudioStreamBasicDescription asbd = {};
    uint32_t streamFormatSize = sizeof(AudioStreamBasicDescription);
    AudioObjectPropertyAddress streamFormatAddress = {kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};

    OSStatus status = AudioObjectGetPropertyData(_outputDeviceID, &streamFormatAddress, 0, nil, &streamFormatSize, &asbd);
    if (status != noErr) {
        return -1;
    }
    return asbd.mSampleRate;
#else
    return [[AVAudioSession sharedInstance] sampleRate];
#endif
}

- (BOOL)start
{
#if TARGET_OS_OSX
    return AudioOutputUnitStart(_outputAU) == noErr;
#else
    NSError *error = nil;
    if (![_engine startAndReturnError:&error]) {
        CA_LogError(-1, "AVAudioEngine failed to start: %@", error.localizedDescription);
        return NO;
    }
    return YES;
#endif
}

- (void)refreshDeviceProperties {
    AVAudioSession *session = [AVAudioSession sharedInstance];

    _ioBufferDuration      = [session IOBufferDuration];
    _sampleRateHW          = [session sampleRate];
    _outputHardwareLatency = [session outputLatency];
    _outputChannels        = (int)[session outputNumberOfChannels];
    _outputTypeStr         = [self getSMOTString:[self getSpatialMixerOutputType]];

    // not sure if we want these yet
    int inputChannels                            = (int)[session inputNumberOfChannels];
    int maximumOutputNumberOfChannels            = (int)[session maximumOutputNumberOfChannels];
    AVAudioSessionMode mode                      = [session mode];
    bool supportsMultichannelContent             = NO;
    AVAudioSessionRenderingMode renderingMode    = AVAudioSessionRenderingModeMonoStereo;

    DEBUG_TRACE(@"refreshed device: %@, %dch, sampleRate %.2f, IOBufferDuration %f, latency %d (%0.2f ms)",
                _outputTypeStr, _outputChannels, _sampleRateHW, _ioBufferDuration,
                (int)(_outputHardwareLatency * _sampleRateHW), _outputHardwareLatency * 1000.0);

    if (@available(iOS 17.2, tvOS 17.2, *)) {

        AVAudioSessionRouteDescription *currentRoute = [session currentRoute];
        AVAudioSessionPortDescription *outputPort    = currentRoute.outputs.firstObject;
        bool isSpatialAudioEnabled                   = outputPort.isSpatialAudioEnabled;
        supportsMultichannelContent                  = [session supportsMultichannelContent];

        DEBUG_TRACE(@"isSpatialAudioEnabled %d, supportsMultichannelContent %d",
                    isSpatialAudioEnabled, supportsMultichannelContent);
        DEBUG_TRACE(@"currentRoute: %@", currentRoute);
        DEBUG_TRACE(@"channels: %@", outputPort.channels);
    }

//    DEBUG_TRACE(@"inputChannels %d, maximumOutputNumberOfChannels %d, mode %@, renderingMode %@, supportsMultichannelContent %@",
//                inputChannels, maximumOutputNumberOfChannels, mode, renderingMode, supportsMultichannelContent);
}

- (BOOL)stop
{
#if TARGET_OS_OSX
    return AudioOutputUnitStop(_outputAU) == noErr;
#else
    if (_engine) {
        [_engine stop];
    }
    return YES;
#endif
}

- (BOOL)isSpatial
{
    return _isSpatial;
}

- (OSStatus)setOutputType:(AUSpatialMixerOutputType)outputType
{
    return [_spatialAU setOutputType:outputType];
}

- (void)setNeedsReinit:(BOOL)value
{
    _needsReinit = value;
}

// update rate is based on how often we're called
- (NSString *)getAudioStatsString
{
    static AudioStatsEWMA *bitrateAvg = nil; if (!bitrateAvg) bitrateAvg = [[AudioStatsEWMA alloc] initWithAlpha:0.2];
    static AudioStatsEWMA *decodeTimeAvg = nil; if (!decodeTimeAvg) decodeTimeAvg = [[AudioStatsEWMA alloc] initWithAlpha:0.2];
    static CFTimeInterval lastTick = 0;
    if (lastTick == 0) lastTick = CACurrentMediaTime();
    CFTimeInterval now = CACurrentMediaTime();

    // add a new sample to the bitrate moving average
    [bitrateAvg addSample:(double)(_bitrateSum * 8) / 1000.0 / (now - lastTick)];

    // track audio decode time as the sum of opus decode -> ring buffer and ring buffer -> processing -> output
    // it doesn't include RTP processing time but probably should
    [decodeTimeAvg addSample:(_opusToPCMTime / 1000.0) / _opusPackets];

    // next call will use data starting right now
    lastTick = now;
    _bitrateSum = 0;
    _opusPackets = 0;

    uint32_t freeBytes = 0;
    TPCircularBufferTail(&_ringBuffer, &freeBytes);
    uint32_t pcmBytes = _ringBuffer.length - freeBytes;
    double pcmDuration = pcmBytes * 1.0 / (_channelCount * _sampleRateOpus * sizeof(float));

    // The leading space before each line is because this gets appended to each video stats line
    NSString *out = [NSString stringWithFormat:@" Audio stream: %dch Opus @ %.0f kbps\n Audio buffer: %.0f%% full (%.2f ms)\n Audio decode: %.2f ms",
                     _channelCount, [bitrateAvg output],
                     (double)(pcmBytes * 100.0 / _ringBuffer.length), pcmDuration * 1000.0,
                     [decodeTimeAvg output]];

//    DEBUG_TRACE(@"buffer health: %.2f %% full, PCM bytes: %d (%.2f ms), free bytes: %d, bitrate: %.0f kbps, decode time: %.2f ms",
//                (double)(pcmBytes * 100.0 / _ringBuffer.length), pcmBytes, pcmDuration * 1000.0, freeBytes, [bitrateAvg output], [decodeTimeAvg output]);

    return out;
}

@end