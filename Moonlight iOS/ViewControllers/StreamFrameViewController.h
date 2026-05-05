//
//  StreamFrameViewController.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "StreamView.h"

#import <UIKit/UIKit.h>

#if TARGET_OS_TV
@import GameController;

@interface StreamFrameViewController : GCEventViewController <ConnectionCallbacks, ControllerSupportDelegate, UserInteractionDelegate, UIScrollViewDelegate>
#else
@interface StreamFrameViewController : UIViewController <ConnectionCallbacks, ControllerSupportDelegate, UserInteractionDelegate, UIScrollViewDelegate>
#endif
@property (nonatomic, strong) StreamConfiguration* streamConfig;

typedef void (^noargCallbackType)(void);
@property (nonatomic, strong) noargCallbackType connectedCallback;
@property (nonatomic, strong) noargCallbackType disconnectedCallback;
#if TARGET_OS_VISION
@property (nonatomic, assign) BOOL uikitReconnectingForRetry;
@property (nonatomic, assign) BOOL fpsMouseCaptureEnabled;
#endif

-(void)updatePreferredDisplayMode:(BOOL)streamActive;
- (void)stopStream;
- (void)startStream;
- (void)toggleKeyboard;
- (void)setAbsoluteTouchMode:(BOOL)enabled;

@end
