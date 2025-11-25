//
//  AV1Helper.h
//  Moonlight
//
//  Created by Luma on 11/24/25.
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface AV1Helper : NSObject

/// Parses an AV1 IDR frame using FFmpeg to generate a format description with the required av1C box and HDR metadata.
+ (nullable CMVideoFormatDescriptionRef)createFormatDescriptionFromIDR:(NSData *)frameData
                                           masteringDisplayColorVolume:(nullable NSData *)mdcv
                                                 contentLightLevelInfo:(nullable NSData *)clli;

@end

NS_ASSUME_NONNULL_END
