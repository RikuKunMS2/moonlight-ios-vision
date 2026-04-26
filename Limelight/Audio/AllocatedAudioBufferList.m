#import "AllocatedAudioBufferList.h"

@implementation AllocatedAudioBufferList

- (instancetype)initWithChannelCount:(UInt32)channelCount bufferSize:(uint16_t)bufferSize {
    self = [super init];
    if (self) {
        _bufferList = (AudioBufferList *)malloc(sizeof(AudioBufferList) + (sizeof(AudioBuffer) * channelCount));
        if (!_bufferList) return nil;
        
        _bufferList->mNumberBuffers = channelCount;
        for (UInt32 c = 0;  c < channelCount; ++c) {
            _bufferList->mBuffers[c].mNumberChannels = 1;
            _bufferList->mBuffers[c].mDataByteSize = bufferSize * sizeof(float);
            _bufferList->mBuffers[c].mData = malloc(sizeof(float) * bufferSize);
        }
    }
    return self;
}

- (void)dealloc {
    if (_bufferList) {
        for (UInt32 i = 0; i < _bufferList->mNumberBuffers; ++i) {
            if (_bufferList->mBuffers[i].mData) {
                free(_bufferList->mBuffers[i].mData);
            }
        }
        free(_bufferList);
        _bufferList = NULL;
    }
}

- (AudioBufferList *)get {
    return _bufferList;
}

@end
