//
//  ObservableConnectionManager.swift
//  Moonlight
//
//  Created by tht7 on 29/12/2024.
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
    
    // Implement the protocol methods
    func connectionStarted() {
        print("Connection started")
    }
    
    func connectionTerminated(_ errorCode: Int32) {
        print("Connection terminated with error code: \(errorCode)")
        errorMessage = "Connection terminated with error code: \(errorCode)"
        showAlert = true
    }
    
    func stageStarting(_ stageName: UnsafePointer<CChar>!) {
        if let stage = stageName {
            currentStage = String(cString: stage)
            print("Stage starting: \(currentStage)")
        }
    }
    
    func stageComplete(_ stageName: UnsafePointer<CChar>!) {
        if let stage = stageName {
            currentStage = String(cString: stage)
            print("Stage complete: \(currentStage)")
        }
    }
    
    func stageFailed(_ stageName: UnsafePointer<CChar>!, withError errorCode: Int32, portTestFlags: Int32) {
        if let stage = stageName {
            let stageStr = String(cString: stage)
            print("Stage failed: \(stageStr), Error code: \(errorCode), Port test flags: \(portTestFlags)")
            errorMessage = "Stage \(stageStr) failed with error \(errorCode)"
            showAlert = true
        }
    }
    
    func launchFailed(_ message: String!) {
        print("Launch failed: \(message ?? "Unknown error")")
        errorMessage = message
        showAlert = true
    }
    
    func rumble(_ controllerNumber: UInt16, lowFreqMotor: UInt16, highFreqMotor: UInt16) {
        print("Rumble controller \(controllerNumber), LowFreq: \(lowFreqMotor), HighFreq: \(highFreqMotor)")
    }
    
    func connectionStatusUpdate(_ status: Int32) {
        print("Connection status updated to: \(status)")
        connectionStatus = status
    }
    
    func setHdrMode(_ enabled: Bool) {
        print("HDR Mode set to: \(enabled)")
        isHDRModeEnabled = enabled
    }
    
    func rumbleTriggers(_ controllerNumber: UInt16, leftTrigger: UInt16, rightTrigger: UInt16) {
        print("Rumble triggers for controller \(controllerNumber): Left \(leftTrigger), Right \(rightTrigger)")
    }
    
    func setMotionEventState(_ controllerNumber: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        print("Set motion event state: Controller \(controllerNumber), Motion type \(motionType), Report rate \(reportRateHz) Hz")
    }
    
    func setControllerLed(_ controllerNumber: UInt16, r: UInt8, g: UInt8, b: UInt8) {
        print("Set LED for controller \(controllerNumber): R \(r), G \(g), B \(b)")
    }
    
    func videoContentShown() {
        print("Video content shown")
        videoShown = true
        showAlert = false
    }
}
