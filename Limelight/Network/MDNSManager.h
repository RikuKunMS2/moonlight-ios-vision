//
//  MDNSManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/14/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@class TemporaryHost;

@protocol MDNSCallback <NSObject>

- (void) updateHost:(TemporaryHost*)host;

@end

@interface MDNSManager : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate>

@property id<MDNSCallback> callback;

- (id) initWithCallback:(id<MDNSCallback>) callback;
- (void) searchForHosts;
- (void) stopSearching;
- (void) forgetHosts;

@end



