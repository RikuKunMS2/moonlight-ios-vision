#import "AVSync.h"
#import "CoreAudioHelpers.h"

// private methods
@interface AVSync ()
- (instancetype)init;
@end

@implementation AVSync
{
    CMTime           _audioPts;
    CMTime           _currentPts;
    CFTimeInterval   _audioPtsUpdateTime;
    CMTime           _videoPts;
    CFTimeInterval   _videoPtsUpdateTime;
    dispatch_queue_t _syncQueue;
}

static AVSync* instance;

+(instancetype)sharedInstance
{
    if (!instance) {
        instance = [[AVSync alloc] init];
    }
    return instance;
}

-(instancetype)init
{
    self = [super init];

    _syncQueue = dispatch_queue_create("com.moonlight.AVSync",
                                        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT,
                                                                                QOS_CLASS_USER_INITIATED, 0));
    return self;
}

-(void)setVideoPts:(uint32_t)pts
{
    dispatch_barrier_async(_syncQueue, ^{
        self->_videoPts = CMTimeMake(pts, 1000);
        self->_videoPtsUpdateTime = CACurrentMediaTime();
    });
}

- (void)setAudioPtsAndCurrentTime:(CMTime)pts currentTime:(CMTime)currentTime
{
    dispatch_barrier_async(_syncQueue, ^{
        self->_audioPts = pts;
        self->_currentPts = currentTime;
        self->_audioPtsUpdateTime = CACurrentMediaTime();
    });
}

// Returns:
//   avOffset:   ms difference between audio and video presentation times, >0 video ahead of audio, <0 audio ahead of video
//   audioDelay: ms delay between current playhead and audio presentation time, i.e. length of buffered audio
-(double)getAVSyncOffsets:(double *)audioDelay
{
    __block double avOffset = 0.0;
    __block double delay = 0.0;

    dispatch_barrier_sync(_syncQueue, ^{
        avOffset = CMTimeGetSeconds(CMTimeSubtract(_videoPts, _audioPts)) * 1000.0;
        delay    = CMTimeGetSeconds(CMTimeSubtract(_audioPts, _currentPts)) * 1000.0;
    });

    *audioDelay = delay;
    return avOffset;
}

-(double)getAudioDelay
{
    __block double delay = 0.0;

    dispatch_barrier_sync(_syncQueue, ^{
        delay = CMTimeGetSeconds(CMTimeSubtract(_audioPts, _currentPts)) * 1000.0;
    });

    return delay;
}

@end
