
#import <Foundation/Foundation.h>
#import "CoreAudioRenderer.h"
#import "OutputAU.h"

#include <Limelight.h>

@implementation CoreAudioRenderer
{
    OutputAU *_outputAU;
    bool hasPlayedAudio;
}

-(instancetype)initWithConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
{
    self = [super init];

    hasPlayedAudio = NO;
    _outputAU = [[OutputAU alloc] init];
    [_outputAU stop];

    if (![_outputAU prepareForPlayback:opusConfig]) {
        return NULL;
    }

#if TARGET_OS_OSX
    // Handle macOS route changes
    [_outputAU initListeners];
#else
    // Disable lowering volume of other audio streams
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleRouteChange:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];
#endif

    return self;
}

-(void)start {
    AVAudioSession *session = [AVAudioSession sharedInstance];

    NSError *error = nil;
    [session setActive:YES error:&error];
    if (error != nil) {
        CA_LogError(-1, "failed to setActive:YES: %@, ignoring...", error.localizedDescription);
    }

    // refresh device properties that may change after setActive
    [_outputAU refreshDeviceProperties];

    // After the AudioUnit starts it will begin calling the callback defined in
    // prepareForPlayback() to receive PCM for playback
    [_outputAU start];
}

-(void)stop {
    [_outputAU stop];

    NSError *error = nil;
    [[AVAudioSession sharedInstance] setActive:NO error:&error];
    if (error != nil) {
        CA_LogError(-1, "failed to setActive:NO: %@, ignoring...", error.localizedDescription);
    }
}

-(void *)getAudioBuffer:(int *)size
{
    return [_outputAU getAudioBuffer:size];
}

-(BOOL)submitAudio:(int)bytesWritten opusBytes:(int)opusBytes decodeStartTime:(CFTimeInterval)decodeStartTime
{
    return [_outputAU submitAudioWithBytesWritten:bytesWritten opusBytes:opusBytes decodeStartTime:decodeStartTime];
}

-(NSString *)getAudioStatsString
{
    return [_outputAU getAudioStatsString];
}

-(void)dealloc {
    DEBUG_TRACE(@"CoreAudioRenderer dealloc");
}

-(void)handleRouteChange:(NSNotification *)notification
{
    AUSpatialMixerOutputType outputType = [_outputAU getSpatialMixerOutputType];
    Log(LOG_I, @"CoreAudioRenderer route change -> %@", [_outputAU getSMOTString:outputType]);

    // always reinit on a change
    [_outputAU setNeedsReinit:YES];
}

@end


//
//#if TARGET_OS_OSX
//// XXX Objective-C <-> C stuff
//OSStatus onDeviceOverload(AudioObjectID /*inObjectID*/,
//                          uint32_t /*inNumberAddresses*/,
//                          const AudioObjectPropertyAddress * /*inAddresses*/,
//                          void *inClientData)
//{
//    CoreAudioRenderer *me = (CoreAudioRenderer *)inClientData;
//    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "CoreAudioRenderer output device overload");
//    me->statsIncDeviceOverload();
//    return noErr;
//}
//
//OSStatus onAudioNeedsReinit(AudioObjectID /*inObjectID*/,
//                            uint32_t /*inNumberAddresses*/,
//                            const AudioObjectPropertyAddress * /*inAddresses*/,
//                            void *inClientData)
//{
//    CoreAudioRenderer *me = (CoreAudioRenderer *)inClientData;
//    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "CoreAudioRenderer output device had a change, will reinit");
//    me->m_needsReinit = YES;
//    return noErr;
//}
//#endif
//
//-(BOOL)initListeners
//{
//#if TARGET_OS_OSX
//    // events we care about on our output device
//
//    AudioObjectPropertyAddress addr{kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
//    OSStatus status = AudioObjectAddPropertyListener(m_OutputDeviceID, &addr, onDeviceOverload, self);
//    if (status != noErr) {
//        CA_LogError(status, "Failed to add listener for kAudioDeviceProcessorOverload");
//        return NO;
//    }
//
//    addr.mSelector = kAudioDevicePropertyDeviceHasChanged;
//    status = AudioObjectAddPropertyListener(m_OutputDeviceID, &addr, onAudioNeedsReinit, self);
//    if (status != noErr) {
//        CA_LogError(status, "Failed to add listener for kAudioDevicePropertyDeviceHasChanged");
//        return NO;
//    }
//
//    // non-device-specific listeners
//    addr.mSelector = kAudioHardwarePropertyServiceRestarted;
//    status = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &addr, onAudioNeedsReinit, self);
//    if (status != noErr) {
//        CA_LogError(status, "Failed to add listener for kAudioHardwarePropertyServiceRestarted");
//        return NO;
//    }
//
//    addr.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
//    status = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &addr, onAudioNeedsReinit, self);
//    if (status != noErr) {
//        CA_LogError(status, "Failed to add listener for kAudioDevicePropertyIOStoppedAbnormally");
//        return NO;
//    }
//#else
//    [[NSNotificationCenter defaultCenter] addObserver:self
//                                             selector:@selector(handleRouteChange:) name:AVAudioSessionRouteChangeNotification
//                                               object:nil];
//#endif
//
//    return YES;
//}
//
//-(void)deinitListeners
//{
//#if TARGET_OS_OSX
//    AudioObjectPropertyAddress addr{kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
//    AudioObjectRemovePropertyListener(m_OutputDeviceID, &addr, onDeviceOverload, self);
//
//    addr.mSelector = kAudioDevicePropertyDeviceHasChanged;
//    AudioObjectRemovePropertyListener(m_OutputDeviceID, &addr, onAudioNeedsReinit, self);
//
//    addr.mSelector = kAudioHardwarePropertyServiceRestarted;
//    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &addr, onAudioNeedsReinit, self);
//
//    addr.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
//    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &addr, onAudioNeedsReinit, self);
//#endif
//}
//
