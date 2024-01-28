//
//  SDLMainWrapper.m
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/27/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

#define SDL_MAIN_HANDLED
#import "SDLMainWrapper.h"

#import <SDL.h>

@implementation SDLMainWrapper

+ (void) setMainReady {
    SDL_SetMainReady();
}

@end
