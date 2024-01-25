//
//  TemporaryHost.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/24/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation
import SwiftUI

@objc
@Observable public class TemporaryHost: NSObject {
    @objc public var state: HostState = .unknown
    @objc public var pairState: PairState = .unknown
    @objc public var activeAddress: String?
    @objc public var currentGame: String?
    @objc public var httpsPort: ushort = 0
    @objc public var isNvidiaServerSoftware: Bool = false

    @objc public var serverCert: Data?
    @objc public var address: String?
    @objc public var externalAddress: String?
    @objc public var localAddress: String?
    @objc public var ipv6Address: String?
    @objc public var mac: String?
    @objc public var serverCodecModeSupport: Int32 = -1

    @objc public var name = ""
    @objc public var uuid = ""
    @objc public var appList = NSMutableSet()
    
    override init() {}
    
    @objc
    public init(fromHost host: Host) {
        self.address = host.address
        self.externalAddress = host.externalAddress
        self.localAddress = host.localAddress
        self.ipv6Address = host.ipv6Address
        self.mac = host.mac
        self.name = host.name ?? ""
        self.uuid = host.uuid ?? ""
        self.serverCodecModeSupport = host.serverCodecModeSupport
        self.serverCert = host.serverCert
        
        self.pairState = (host.serverCert != nil) ? PairState(rawValue: host.pairState as! Int32)! : PairState.unpaired
        
        super.init()
        // Older clients stored a non-URL-escaped IPv6 string. Try to detect that and fix it up.
        if self.ipv6Address != nil && self.ipv6Address!.contains("[") {
            self.ipv6Address = Utils.addressAndPort(toAddressPortString: self.ipv6Address, port: 47989)
        }
        
        if let hostAppList = host.appList {
            for app in hostAppList {
                let tempApp = TemporaryApp(from: app, withTempHost: self)
                self.appList.add(tempApp)
            }
        }
    }
    
    @objc public func propagateChanges(toParent parentHost: Host) {
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
        parentHost.name = self.name
        parentHost.uuid = self.uuid
        parentHost.serverCodecModeSupport = self.serverCodecModeSupport
        parentHost.pairState = NSNumber(value: self.pairState.rawValue)
    }
}

extension TemporaryHost: Identifiable {}
