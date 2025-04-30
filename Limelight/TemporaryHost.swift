//
//  TemporaryHost.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/24/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation
import SwiftUI
import OrderedCollections

#if os(visionOS)
@Observable
#endif
@objc
@MainActor
public class TemporaryHost: NSObject {
    @MainActor @objc public var state: HostState = .unknown
    @MainActor @objc public var pairState: PairState = .unknown
    @objc public var activeAddress: String?
    @MainActor @objc public var currentGame: String?
    @objc public var httpsPort: ushort = 0
    @objc public var isNvidiaServerSoftware: Bool = false

    @MainActor @objc public var updatePending: Bool = false

    @objc public var serverCert: Data?
    @objc public var address: String?
    @objc public var externalAddress: String?
    @objc public var localAddress: String?
    @objc public var ipv6Address: String?
    @objc public var mac: String?
    @objc public var serverCodecModeSupport: Int32 = -1

    @objc public var name = ""

    @objc public var uuid = ""

    public var appList = OrderedSet<TemporaryApp>()

    @objc(appList) public func getAppList() -> NSSet {
        return NSSet(array: self.appList.elements)
    }

    @objc public func setAppList(_ newList: NSSet) {
        self.appList.removeAll()
        for case let app as TemporaryApp in newList {
            self.appList.append(app)
        }
    }

    override init() { // Default initializer
        super.init()
        self.uuid = UUID().uuidString
        //Log(LOG_DEBUG, "TemporaryHost:init - Generated new UUID: %@", self.uuid)
        self.name = "New Host" // Default name for NEW hosts!
    }

    @objc public init(fromHost host: MoonlightHost) { // Initializer from MoonlightHost (Core Data)
        super.init()
        self.address = host.address
        self.externalAddress = host.externalAddress
        self.localAddress = host.localAddress
        self.ipv6Address = host.ipv6Address
        self.mac = host.mac
        self.name = host.name ?? "Unnamed Host" // Default to "Unnamed Host" if Core Data name is nil!
        self.uuid = host.uuid ?? ""
//        if self.uuid.isEmpty {
  //          self.uuid = UUID().uuidString
            //Log(LOG_DEBUG, "TemporaryHost:init(fromHost) - MoonlightHost UUID was empty, generated new UUID: //      } else {
            //Log(LOG_DEBUG, "TemporaryHost:init(fromHost) - Using existing MoonlightHost UUID: %@", self.uuid)
        //}

        self.serverCodecModeSupport = host.serverCodecModeSupport
        self.serverCert = host.serverCert
        self.pairState = (host.serverCert != nil) ? PairState(rawValue: host.pairState as! Int32)! : PairState.unpaired


        // Older clients stored a non-URL-escaped IPv6 string. Try to detect that and fix it up.
        if self.ipv6Address != nil && self.ipv6Address!.contains("[") {
            self.ipv6Address = Utils.addressAndPort(toAddressPortString: self.ipv6Address, port: 47989)
        }

        if let hostAppList = host.appList {
            for app in hostAppList {
                let tempApp = TemporaryApp(from: app, with: self)
                self.appList.append(tempApp)
            }
        }
    }

    @objc public func propagateChanges(toParent parentHost: MoonlightHost) {
        // Avoid overwriting existing data with nil if
        // we don't have everything populated in the temporary
        // host.
        if self.address != nil {
            parentHost.address = self.address
        }
        if self.externalAddress != nil {
            parentHost.externalAddress = self.externalAddress
        }
        if self.localAddress != nil {
            parentHost.localAddress = self.localAddress
        }
        if self.ipv6Address != nil {
            parentHost.ipv6Address = self.ipv6Address
        }
        if self.mac != nil {
            parentHost.mac = self.mac
        }
        if self.serverCert != nil {
            parentHost.serverCert = self.serverCert
        }
        
        parentHost.serverCodecModeSupport = self.serverCodecModeSupport
        
        parentHost.name = self.name
        parentHost.uuid = self.uuid
            
        parentHost.pairState = NSNumber(value: self.pairState.rawValue)
    }
    

    static func ==(lhs: TemporaryHost, rhs: TemporaryHost) -> Bool {
        lhs.id == rhs.id
    }
    
    public override var hash: Int {
        return id.hash
    }
    
    override public func isEqual(_ object: Any?) -> Bool {
        if let other = object as? TemporaryHost {
            return other.id == self.id
        } else {
            return false
        }
    }
}

extension TemporaryHost: @preconcurrency Identifiable {
    /// `id` for Identifiable conformance is the `uuid`.
    public var id: String { self.uuid }
}
