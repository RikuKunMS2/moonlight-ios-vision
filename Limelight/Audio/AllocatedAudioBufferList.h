//
//  AllocatedAudioBufferList.h
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
#import <AudioToolbox/AudioToolbox.h>

@interface AllocatedAudioBufferList : NSObject

@property (nonatomic, readonly) AudioBufferList * _Nullable bufferList;

- (instancetype _Nullable)initWithChannelCount:(UInt32)channelCount bufferSize:(uint16_t)bufferSize;
- (AudioBufferList * _Nullable)get;

@end
