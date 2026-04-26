//
//  AudioStats.h
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

@interface AudioStatsEWMA : NSObject

@property (nonatomic, readonly) double output;
@property (nonatomic, assign) double alpha;

- (instancetype)init;
- (instancetype)initWithAlpha:(double)alpha;
- (double)addSample:(double)input;

@end
