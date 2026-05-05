//
//  KeyboardSupport.h
//  Moonlight
//
//  Created by Diego Waxemberg on 8/25/18.
//  Copyright © 2018 Moonlight Game Streaming Project. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface KeyboardSupport : NSObject

struct KeyEvent {
    u_short keycode;
    u_short modifierKeycode;
    u_char modifier;
};

+ (BOOL)sendUSBHIDKeyEvent:(NSInteger)hidUsage down:(BOOL)down;
+ (BOOL)sendKeyEventForPress:(UIPress*)press down:(BOOL)down API_AVAILABLE(ios(13.4));
+ (BOOL)sendKeyEvent:(UIKey*)key down:(BOOL)down API_AVAILABLE(ios(13.4));
+ (struct KeyEvent) translateKeyEvent:(unichar) inputChar withModifierFlags:(UIKeyModifierFlags)modifierFlags;

@end
