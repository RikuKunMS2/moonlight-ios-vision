//
//  ControllerSupport.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "Controller.h"
#import <UIKit/UIKit.h>

// It's in Swift's hands now
@class TemporarySettings;

@class StreamConfiguration;

@class OnScreenControls;

@protocol ControllerSupportDelegate <NSObject>

- (void) gamepadPresenceChanged;
- (void) mousePresenceChanged;
- (void) streamExitRequested;

@end

@interface ControllerSupport : NSObject;
@property (nonatomic, assign) BOOL relativeMouseMode;
// Add these properties
@property (nonatomic, assign) BOOL realityKitMode;
@property (nonatomic, copy) void (^realityKitMouseMovedHandler)(float deltaX, float deltaY);

// Keyboard Reality Kit Stuff
@property (nonatomic, copy) void (^realityKitKeyboardHandler)(int keyCode, BOOL pressed);
-(void) registerKeyboardCallbacks:(GCKeyboard*) keyboard API_AVAILABLE(ios(14.0));

-(id) initWithConfig:(StreamConfiguration*)streamConfig delegate:(id<ControllerSupportDelegate>)delegate;
-(void) connectionEstablished;
-(void) registerMouseCallbacks:(GCMouse*) mouse API_AVAILABLE(ios(14.0));

-(void) initAutoOnScreenControlMode:(OnScreenControls*)osc;
-(void) cleanup;
-(Controller*) getOscController;

-(void) updateLeftStick:(Controller*)controller x:(short)x y:(short)y;
-(void) updateRightStick:(Controller*)controller x:(short)x y:(short)y;

-(void) updateLeftTrigger:(Controller*)controller left:(unsigned char)left;
-(void) updateRightTrigger:(Controller*)controller right:(unsigned char)right;
-(void) updateTriggers:(Controller*)controller left:(unsigned char)left right:(unsigned char)right;

-(void) updateButtonFlags:(Controller*)controller flags:(int)flags;
-(void) setButtonFlag:(Controller*)controller flags:(int)flags;
-(void) clearButtonFlag:(Controller*)controller flags:(int)flags;

-(void) updateFinished:(Controller*)controller;

-(void) rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor;
-(void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger;
-(void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz;
-(void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b;

+(int) getConnectedGamepadMask:(StreamConfiguration*)streamConfig settings:(TemporarySettings* _Nullable)settings;

-(NSUInteger) getConnectedGamepadCount;

- (void) attachGCEventInteractionToView:(UIView *)view;
- (void) detachGCEventInteractionFromView:(UIView *)view;

@end
