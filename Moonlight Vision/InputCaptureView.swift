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

// --- Configuration Constants ---
private let BUTTON_ACTION_PRESS: Int8 = 0
private let BUTTON_ACTION_RELEASE: Int8 = 1
private let BUTTON_LEFT: Int32 = 1
private let BUTTON_RIGHT: Int32 = 2

// Touch/Tap Timing
private let LONG_PRESS_DELAY: TimeInterval = 0.650
private let DOUBLE_TAP_DELAY: TimeInterval = 0.250
private let DOUBLE_TAP_DELTA: CGFloat = 0.025

// --- Enums ---
public enum MouseInputMode {
    case absolute // Remote Desktop, RTS, Strategy (Cursor maps 1:1 to screen)
    case relative // FPS, Action games (Raw delta movement via GCMouse)
}

struct InputCaptureView: UIViewRepresentable {
    let controllerSupport: ControllerSupport
    @Binding var showKeyboard: Bool
    @Binding var mouseInputMode: MouseInputMode // <-- New Binding for Hybrid Mode
    var curvature: Float
    
    func makeUIView(context: Context) -> InputCaptureUIView {
        let view = InputCaptureUIView()
        view.curvature = curvature
        view.mouseInputMode = mouseInputMode
        
        // 1. Attach hardware mouse/controller support (GCEventInteraction)
        // This handles Game Controller buttons and GCMouse (Relative) inputs
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
        // Update state live
        uiView.curvature = curvature
        uiView.mouseInputMode = mouseInputMode
        
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

// Invisible View that handles UIKeyInput (Keyboard), Gestures (Mouse), and Touches (Clicks)
class InputCaptureUIView: UIView, UIKeyInput {
    
    var keyboardDismissHandler: (() -> Void)?
    var curvature: Float = 0.0
    var mouseInputMode: MouseInputMode = .absolute
    
    // Constants from RealityKitStreamView
    private let maxCurveAngle: Float = (5.5 * .pi / 6.0)
    
    // --- Mouse State ---
    private var longPressTimer: Timer?
    private var lastTouchUpTimestamp: TimeInterval = 0
    private var lastTouchUpLocation: CGPoint = .zero
    
    // --- Keyboard Protocol ---
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    
    // MARK: - Initialization & Gestures
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupGestures()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGestures()
    }
    
    private func setupGestures() {
        // 1. Hover Gesture: Handles mouse movement WITHOUT clicking (Passive Move)
        let hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        self.addGestureRecognizer(hoverGesture)
        
        // 2. Pan Gesture: Handles mouse movement WHILE clicking (Drag)
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.maximumNumberOfTouches = 1
        panGesture.cancelsTouchesInView = false // Important: Allows touchesBegan to still fire for Clicking
        self.addGestureRecognizer(panGesture)
    }
    
    // MARK: - Gesture Handlers (Absolute Movement)
    
    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        // If in Relative mode, ignore this. GCMouse (ControllerSupport) handles movement.
        guard mouseInputMode == .absolute else { return }
        
        guard gesture.state == .began || gesture.state == .changed else { return }
        let location = gesture.location(in: self)
        sendMousePosition(at: location)
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // If in Relative mode, ignore drag here.
        guard mouseInputMode == .absolute else { return }
        
        guard gesture.state == .began || gesture.state == .changed else { return }
        let location = gesture.location(in: self)
        sendMousePosition(at: location)
    }

    // MARK: - Touch Handling (Clicks)
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // If in Relative mode, clicks are typically handled by GCMouse.leftButton.
        // We return early to avoid double-clicking.
        guard mouseInputMode == .absolute else { return }
        
        // We only handle single finger touches for mouse control
        guard let touch = touches.first, touches.count == 1 else { return }
        
        let location = touch.location(in: self)
        
        // 1. Move cursor to click location immediately
        sendMousePosition(at: location)
        
        // 2. Press Left Click
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT)
        
        // 3. Start Long Press Timer (for Right Click emulation)
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: LONG_PRESS_DELAY, repeats: false) { [weak self] _ in
            self?.handleLongPress()
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard mouseInputMode == .absolute else { return }
        guard let touch = touches.first else { return }
        
        // Cancel Right Click Timer
        longPressTimer?.invalidate()
        longPressTimer = nil
        
        // 1. Release Left Click
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT)
        
        // 2. Release Right Click (Safety cleanup)
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT)
        
        // Store state for potential future double-click logic
        lastTouchUpTimestamp = touch.timestamp
        lastTouchUpLocation = touch.location(in: self)
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
    
    private func handleLongPress() {
        // Long Press detected: Release Left, Press Right
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT)
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_RIGHT)
    }
    
    // MARK: - Coordinate Mapping (Curvature Correction)
    
    private func sendMousePosition(at location: CGPoint) {
        var finalX = location.x
        
        // --- CURVATURE CORRECTION ---
        // If the screen is curved, the linear touch point X on the flat window
        // does not correspond linearly to the UV X of the texture.
        // We must apply the inverse projection: Linear Chord Position -> Angular Arc Position.
        if curvature > 0.001 {
            let width = bounds.width
            let normalizedX = location.x / width // 0.0 .. 1.0
            let relativeX = normalizedX - 0.5 // -0.5 .. 0.5
            
            let angle = maxCurveAngle * curvature
            
            // Ratio of Chord / Radius logic derived from Mesh generation
            let sinTheta = Float(relativeX) * 2.0 * sin(angle / 2.0)
            
            // Clamp to avoid NaN at edges
            let clampedSin = max(-1.0, min(1.0, sinTheta))
            let theta = asin(clampedSin)
            
            let u = (theta / angle) + 0.5
            finalX = CGFloat(u) * width
        }
        
        // Clamp coordinates to view bounds to prevent wrapping/out-of-bounds issues
        let clampedX = max(0, min(bounds.width, finalX))
        let clampedY = max(0, min(bounds.height, location.y))
        
        let width = Int16(bounds.width)
        let height = Int16(bounds.height)
        let sX = Int16(clampedX)
        let sY = Int16(clampedY)
        
        LiSendMousePositionEvent(sX, sY, width, height)
    }
    
    // MARK: - Keyboard Handling
    
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
}
