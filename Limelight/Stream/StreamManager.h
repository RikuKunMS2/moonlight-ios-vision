//
//  StreamManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

//#import "StreamConfiguration.h"
#import "AnyVideoDecoderRenderer.h"
#import "Connection.h"

@interface StreamManager : NSOperation

- (id) initWithConfig:(StreamConfiguration*)config rendererProvider:(id<AnyVideoDecoderRenderer> __strong (^)(void))rendererProvider connectionCallbacks:(id<ConnectionCallbacks>)callback;

- (void) stopStream;

- (NSString*) getStatsOverlayText;

@end
