#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

@interface AllocatedAudioBufferList : NSObject

@property (nonatomic, readonly) AudioBufferList * _Nullable bufferList;

- (instancetype _Nullable)initWithChannelCount:(UInt32)channelCount bufferSize:(uint16_t)bufferSize;
- (AudioBufferList * _Nullable)get;

@end
