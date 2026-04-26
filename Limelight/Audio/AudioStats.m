//
//  AudioStats.m
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2).
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//  Based on files created by Andy Grundman https://github.com/andygrundman
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

#import "AudioStats.h"

static const double kDefaultAlpha = 0.1;
static const double kInitialOutput = -1.0;

@implementation AudioStatsEWMA
@synthesize output = _output;
@synthesize alpha = _alpha;

- (instancetype)init {
    return [self initWithAlpha:kDefaultAlpha];
}

- (instancetype)initWithAlpha:(double)alpha {
    self = [super init];
    if (self) {
        NSAssert(alpha >= 0.0 && alpha <= 1.0, @"alpha must be between 0 and 1");
        _alpha = alpha;
        _output = kInitialOutput;
    }
    return self;
}

- (double)addSample:(double)input {
    if (_output == kInitialOutput) {
        _output = input;
    } else {
        _output = _alpha * (input - _output) + _output;
    }
    return _output;
}

- (double)output {
    NSAssert(_output != kInitialOutput, @"EWMA is uninitialized: no input has been provided");
    return _output;
}

@end
