//
//  ObservableConnectionManager.swift
//  Moonlight Vision
//
//  Created by tht7 on 29/12/2024.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Moonlight
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation
import Combine
@MainActor
@objc class ObservableConnectionManager: NSObject, ObservableObject, ConnectionCallbacks {
    
    // Published properties for SwiftUI to observe
    @Published var connectionStatus: Int32 = 0
    @Published var currentStage: String = ""
    @Published var errorMessage: String?
    @Published var isHDRModeEnabled: Bool = false
    @Published var videoShown: Bool = false
    @Published var showAlert = false

    /// Reference to ControllerSupport for rumble forwarding (RealityKit path)
    weak var controllerSupport: ControllerSupport?

    /// When true, stageFailed/launchFailed are treated as retry failures (posted as ConnectionTerminatedForRetry).
    var isReconnectingForRetry: Bool = false

    // Implement the protocol methods
    func connectionStarted() {
        print("Connection started")
    }
    
    func connectionTerminated(_ errorCode: Int32) {
        let msg = "Connection terminated with error code: \(errorCode)"
        print("Connection terminated with error code: \(errorCode)")
        Task { @MainActor in
            self.errorMessage = msg
            NotificationCenter.default.post(
                name: Notification.Name("ConnectionTerminatedForRetry"),
                object: nil,
                userInfo: ["errorCode": errorCode, "message": msg]
            )
        }
    }
    
    func stageStarting(_ stageName: UnsafePointer<CChar>!) {
        let stage = stageName.map { String(cString: $0) } ?? ""
        print("Stage starting: \(stage)")
        Task { @MainActor in self.currentStage = stage }
    }
    
    func stageComplete(_ stageName: UnsafePointer<CChar>!) {
        let stage = stageName.map { String(cString: $0) } ?? ""
        print("Stage complete: \(stage)")
        Task { @MainActor in self.currentStage = stage }
    }
    
    func stageFailed(_ stageName: UnsafePointer<CChar>!, withError errorCode: Int32, portTestFlags: Int32) {
        let msg: String
        if let stage = stageName {
            let stageStr = String(cString: stage)
            msg = "Stage \(stageStr) failed with error \(errorCode)"
            print("Stage failed: \(stageStr), Error code: \(errorCode), Port test flags: \(portTestFlags)")
        } else {
            msg = "Stage failed with error \(errorCode)"
        }
        let reconnecting = isReconnectingForRetry
        Task { @MainActor in
            self.errorMessage = msg
            if reconnecting {
                NotificationCenter.default.post(
                    name: Notification.Name("ConnectionTerminatedForRetry"),
                    object: nil,
                    userInfo: ["errorCode": errorCode, "message": msg]
                )
            } else {
                self.showAlert = true
                NotificationCenter.default.post(name: Notification.Name("RealityKitStreamErrorNotification"), object: nil, userInfo: ["message": msg])
                NotificationCenter.default.post(name: Notification.Name("StreamStartFailed"), object: nil)
            }
        }
    }
    
    func launchFailed(_ message: String!) {
        let msg = message ?? "Unknown error"
        print("Launch failed: \(msg)")
        let reconnecting = isReconnectingForRetry
        Task { @MainActor in
            self.errorMessage = message
            if reconnecting {
                NotificationCenter.default.post(
                    name: Notification.Name("ConnectionTerminatedForRetry"),
                    object: nil,
                    userInfo: ["message": msg]
                )
            } else {
                self.showAlert = true
                NotificationCenter.default.post(name: Notification.Name("RealityKitStreamErrorNotification"), object: nil, userInfo: ["message": msg])
                NotificationCenter.default.post(name: Notification.Name("StreamStartFailed"), object: nil)
            }
        }
    }
    
    func rumble(_ controllerNumber: UInt16, lowFreqMotor: UInt16, highFreqMotor: UInt16) {
        controllerSupport?.rumble(controllerNumber, lowFreqMotor: lowFreqMotor, highFreqMotor: highFreqMotor)
    }
    
    func connectionStatusUpdate(_ status: Int32) {
        print("Connection status updated to: \(status)")
        Task { @MainActor in self.connectionStatus = status }
    }
    
    func setHdrMode(_ enabled: Bool) {
        print("HDR Mode set to: \(enabled)")
        Task { @MainActor in self.isHDRModeEnabled = enabled }
    }
    
    func rumbleTriggers(_ controllerNumber: UInt16, leftTrigger: UInt16, rightTrigger: UInt16) {
        controllerSupport?.rumbleTriggers(controllerNumber, leftTrigger: leftTrigger, rightTrigger: rightTrigger)
    }
    
    func setMotionEventState(_ controllerNumber: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        print("Set motion event state: Controller \(controllerNumber), Motion type \(motionType), Report rate \(reportRateHz) Hz")
    }
    
    func setControllerLed(_ controllerNumber: UInt16, r: UInt8, g: UInt8, b: UInt8) {
        print("Set LED for controller \(controllerNumber): R \(r), G \(g), B \(b)")
    }
    
    func videoContentShown() {
        print("Video content shown")
        Task { @MainActor in
            // Only post the first-frame notification once per stream session.
            // DrawableVideoDecoder may call this on every IDR frame in error-recovery
            // paths; without this guard each call queues a Task that fires onChange
            // observers multiple times per SwiftUI frame.
            guard !self.videoShown else { return }
            self.videoShown = true
            self.showAlert = false
            NotificationCenter.default.post(name: Notification.Name("RKStreamFirstFrameShown"), object: nil)
        }
    }
}
