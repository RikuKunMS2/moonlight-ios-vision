//
//  StreamConfiguration.swift
//  Moonlight
//
//  Created by tht7 on 23/01/2025.
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation

@objcMembers
class StreamConfiguration: NSObject, Codable {
    var host: String!
    var httpsPort: UInt16
    var appVersion: String
    var gfeVersion: String
    var appID: String!
    var appName: String!
    var rtspSessionUrl: String
    var serverCodecModeSupport: Int32
    var width: Int32
    var height: Int32
    var frameRate: Int32
    var bitRate: Int32
    var riKeyId: Int
    var riKey: Data
    var gamepadMask: Int32
    var optimizeGameSettings: Bool
    var playAudioOnPC: Bool
    var swapABXYButtons: Bool
    var audioConfiguration: Int
    var supportedVideoFormats: Int32
    var multiController: Bool
    var useFramePacing: Bool
    var serverCert: Data!
    
    // Default initializer (required for decoding)
    init(
        host: String,
        httpsPort: UInt16,
        appVersion: String,
        gfeVersion: String,
        appID: String,
        appName: String,
        rtspSessionUrl: String,
        serverCodecModeSupport: Int32,
        width: Int32,
        height: Int32,
        frameRate: Int32,
        bitRate: Int32,
        riKeyId: Int,
        riKey: Data,
        gamepadMask: Int32,
        optimizeGameSettings: Bool,
        playAudioOnPC: Bool,
        swapABXYButtons: Bool,
        audioConfiguration: Int,
        supportedVideoFormats: Int32,
        multiController: Bool,
        useFramePacing: Bool,
        serverCert: Data
    ) {
        self.host = host
        self.httpsPort = httpsPort
        self.appVersion = appVersion
        self.gfeVersion = gfeVersion
        self.appID = appID
        self.appName = appName
        self.rtspSessionUrl = rtspSessionUrl
        self.serverCodecModeSupport = serverCodecModeSupport
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitRate = bitRate
        self.riKeyId = riKeyId
        self.riKey = riKey
        self.gamepadMask = gamepadMask
        self.optimizeGameSettings = optimizeGameSettings
        self.playAudioOnPC = playAudioOnPC
        self.swapABXYButtons = swapABXYButtons
        self.audioConfiguration = audioConfiguration
        self.supportedVideoFormats = supportedVideoFormats
        self.multiController = multiController
        self.useFramePacing = useFramePacing
        self.serverCert = serverCert
    }
    
    // Convenience initializer for empty/default values
    override init() {
        self.host = ""
        self.httpsPort = 0
        self.appVersion = ""
        self.gfeVersion = ""
        self.appID = ""
        self.appName = ""
        self.rtspSessionUrl = ""
        self.serverCodecModeSupport = 0
        self.width = 0
        self.height = 0
        self.frameRate = 0
        self.bitRate = 0
        self.riKeyId = 0
        self.riKey = Data()
        self.gamepadMask = 0
        self.optimizeGameSettings = false
        self.playAudioOnPC = false
        self.swapABXYButtons = false
        self.audioConfiguration = 0
        self.supportedVideoFormats = 0
        self.multiController = false
        self.useFramePacing = false
        self.serverCert = Data()
    }
}
