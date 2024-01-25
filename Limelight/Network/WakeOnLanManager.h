//
//  WakeOnLanManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/2/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

@class TemporaryHost;

@interface WakeOnLanManager : NSObject

+ (void) wakeHost:(TemporaryHost*)host;

@end
