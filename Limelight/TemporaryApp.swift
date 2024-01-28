//
//  TemporaryApp.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/27/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation
import Observation

#if os(visionOS)
@Observable
#endif
@objc
@MainActor
public class TemporaryApp: NSObject {
    @objc public var id: String?
    @objc public var name: String?
    @objc public var installPath: String?
    @objc public var hdrSupported = false
    @objc public var hidden = false
    @objc public var maybeHost: Any?

    @objc override public init() {}

    // this is not the right thing to do here
    @objc public init(from app: MoonlightApp, with tempHost: Any) {
        self.id = app.id
        self.name = app.name
        self.hdrSupported = app.hdrSupported
        self.hidden = app.hidden
        self.maybeHost = tempHost
    }

    @objc public func propagateChangesTo(parent: MoonlightApp, withHost host: MoonlightHost) {
        parent.id = self.id
        parent.name = self.name
        parent.hdrSupported = self.hdrSupported
        parent.hidden = self.hidden
        parent.host = host
    }
}
