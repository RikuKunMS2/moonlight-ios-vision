//
//  Utils.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/27/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation

// We can hide our typecasting crimes here.
@objc extension TemporaryApp {
    func host() -> TemporaryHost? {
        if let ret = maybeHost as? TemporaryHost {
            return ret
        }
        return nil
    }
    
    func setHost(_ newHost: TemporaryHost?) {
        maybeHost = newHost
    }
}
