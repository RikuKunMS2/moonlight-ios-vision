//
//  InputCaptureView.swift
//  Moonlight
//
//  Created by Lumanaire on 11/19/25.
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI
import GameController
import UIKit
import Darwin // Needed for trig functions

// Mouse Constants (Matching Limelight.h)
private let BUTTON_ACTION_PRESS: Int8 = 0
private let BUTTON_ACTION_RELEASE: Int8 = 1
private let BUTTON_LEFT: Int32 = 1
private let BUTTON_RIGHT: Int32 = 2

// Touch Configuration
private let LONG_PRESS_DELAY: TimeInterval = 0.650
private let LONG_PRESS_DELTA: CGFloat = 0.01 // Movement allowed before canceling long press
private let DOUBLE_TAP_DELAY: TimeInterval = 0.250
private let DOUBLE_TAP_DELTA: CGFloat = 0.025

struct InputCaptureView: UIViewRepresentable {
    let controllerSupport: ControllerSupport
    @Binding var showKeyboard: Bool
    var curvature: Float // <-- Add Curvature
    
    func makeUIView(context: Context) -> InputCaptureUIView {
        let view = InputCaptureUIView()
        view.curvature = curvature // Initialize
        
        // 1. Attach hardware mouse/controller support (GCEventInteraction)
        controllerSupport.attachGCEventInteraction(to: view)
        
        // 2. Link keyboard dismissal callback
        view.keyboardDismissHandler = {
            DispatchQueue.main.async {
                self.showKeyboard = false
            }
        }
        return view
    }
    
    func updateUIView(_ uiView: InputCaptureUIView, context: Context) {
        // Update curvature live
        uiView.curvature = curvature
        
        // Handle Virtual Keyboard Toggle
        if showKeyboard {
            if !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            }
        } else {
            if uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }
}

// Invisible View that handles both UIKeyInput (Keyboard) and Touch (Mouse)
class InputCaptureUIView: UIView, UIKeyInput {
    var keyboardDismissHandler: (() -> Void)?
    var curvature: Float = 0.0
    
    // Constants from RealityKitStreamView
    private let maxCurveAngle: Float = (5.5 * .pi / 6.0)
    
    // --- Mouse State ---
    private var longPressTimer: Timer?
    private var lastTouchUpTimestamp: TimeInterval = 0
    private var lastTouchUpLocation: CGPoint = .zero
    private var lastTouchDownLocation: CGPoint = .zero
    
    // --- Keyboard Protocol ---
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    
    func insertText(_ text: String) {
        let cString = text.cString(using: .utf8)
        LiSendUtf8TextEvent(cString, UInt32(text.utf8.count))
    }
    
    func deleteBackward() {
        LiSendKeyboardEvent(0x08, Int8(KEY_ACTION_DOWN), 0)
        usleep(50 * 1000)
        LiSendKeyboardEvent(0x08, Int8(KEY_ACTION_UP), 0)
    }
    
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            keyboardDismissHandler?()
        }
        return result
    }
    
    // MARK: - Touch Handling (Mouse Emulation)
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // We only handle single finger touches for mouse control
        guard let touch = touches.first, touches.count == 1 else { return }
        
        let location = touch.location(in: self)
        let normalizedX = location.x / bounds.width
        let normalizedY = location.y / bounds.height
        
        // Double Click Deadzone Logic
        // If user taps roughly the same spot quickly, don't move the cursor.
        // This makes double-clicking files/folders much easier.
        let distanceSinceUp = hypot(normalizedX - (lastTouchUpLocation.x / bounds.width),
                                    normalizedY - (lastTouchUpLocation.y / bounds.height))
        
        if (touch.timestamp - lastTouchUpTimestamp) > DOUBLE_TAP_DELAY ||
            distanceSinceUp > DOUBLE_TAP_DELTA {
            // Only move cursor if NOT inside the deadzone
            sendMousePosition(x: location.x, y: location.y)
        }
        
        // 1. Press Left Click
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT)
        
        // 2. Start Long Press Timer (for Right Click)
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: LONG_PRESS_DELAY, repeats: false) { [weak self] _ in
            self?.handleLongPress()
        }
        
        lastTouchDownLocation = location
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touches.count == 1 else { return }
        
        let location = touch.location(in: self)
        let normalizedX = location.x / bounds.width
        let normalizedY = location.y / bounds.height
        
        // Check if moved enough to cancel long press (Right Click)
        let distanceMoved = hypot(normalizedX - (lastTouchDownLocation.x / bounds.width),
                                  normalizedY - (lastTouchDownLocation.y / bounds.height))
        
        if distanceMoved > LONG_PRESS_DELTA {
            longPressTimer?.invalidate()
            longPressTimer = nil
        }
        
        // Move Mouse (Dragging)
        sendMousePosition(x: location.x, y: location.y)
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        
        // Cancel Right Click Timer
        longPressTimer?.invalidate()
        longPressTimer = nil
        
        // 1. Release Left Click
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT)
        
        // 2. Release Right Click (Safety cleanup in case long press triggered)
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT)
        
        // Store state for double-click detection
        lastTouchUpTimestamp = touch.timestamp
        lastTouchUpLocation = touch.location(in: self)
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
    
    private func handleLongPress() {
        // Long Press detected:
        // 1. Release Left (cancel the drag/click we started)
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT)
        // 2. Press Right
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_RIGHT)

    }
    
    private func sendMousePosition(x: CGFloat, y: CGFloat) {
        var finalX = x
        
        // --- CURVATURE CORRECTION ---
        // If the screen is curved, the linear touch point X on the flat window
        // does not correspond linearly to the UV X of the texture.
        // We must apply the inverse projection: Linear Chord Position -> Angular Arc Position.
        if curvature > 0.001 {
            let width = bounds.width
            let normalizedX = x / width // 0.0 .. 1.0
            let relativeX = normalizedX - 0.5 // -0.5 .. 0.5
            
            let angle = maxCurveAngle * curvature
            
            // Ratio of Chord / Radius logic derived from Mesh generation:
            // x_mesh = relativeX * 2.0 * sin(angle / 2.0)
            // theta = asin(x_mesh)
            
            let sinTheta = Float(relativeX) * 2.0 * sin(angle / 2.0)
            
            // Clamp to avoid NaN at edges
            let clampedSin = max(-1.0, min(1.0, sinTheta))
            let theta = asin(clampedSin)
            
            let u = (theta / angle) + 0.5
            finalX = CGFloat(u) * width
        }
        // ----------------------------
        
        let width = Int16(bounds.width)
        let height = Int16(bounds.height)
        let sX = Int16(finalX)
        let sY = Int16(y)
        
        LiSendMousePositionEvent(sX, sY, width, height)
    }
}
