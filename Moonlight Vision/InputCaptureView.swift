//
//  InputCaptureView.swift
//  Moonlight
//
//  Simplified Touch & Hover Handler
//

import SwiftUI
import UIKit

// Bridge to C-functions
private let BUTTON_ACTION_PRESS: Int8 = 0
private let BUTTON_ACTION_RELEASE: Int8 = 1
private let BUTTON_LEFT: Int32 = 1
private let BUTTON_RIGHT: Int32 = 2

struct InputCaptureView: UIViewRepresentable {
    let controllerSupport: ControllerSupport
    @Binding var showKeyboard: Bool
    var curvature: Float

    func makeUIView(context: Context) -> InputCaptureUIView {
        let view = InputCaptureUIView()
        view.curvature = curvature
        view.controllerSupport = controllerSupport
        
        // 1. Allow Multi-touch (essential for gestures)
        view.isMultipleTouchEnabled = true
        
        // 2. User Interaction Enabled
        view.isUserInteractionEnabled = true
        
        // 3. Background Color: MUST NOT BE CLEAR/NIL.
        // 0.01 Alpha is invisible to eye but visible to hit-testing.
        view.backgroundColor = UIColor.black.withAlphaComponent(0.01)
        
        return view
    }

    func updateUIView(_ uiView: InputCaptureUIView, context: Context) {
        uiView.curvature = curvature
        
        // Handle Keyboard toggling
        if showKeyboard && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !showKeyboard && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }
}

// The workhorse view
class InputCaptureUIView: UIView, UIKeyInput {
    var controllerSupport: ControllerSupport?
    var curvature: Float = 0.0
    
    // Math Constants
    private let maxCurveAngle: Float = (5.5 * .pi / 6.0)
    
    // State
    private var lastMouseX: CGFloat = 0
    private var lastMouseY: CGFloat = 0
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupGestures()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGestures()
    }
    
    private func setupGestures() {
        // 1. HOVER: Handles moving the mouse WITHOUT clicking
        // This is specific to Trackpads and Eye Gaze on visionOS
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        self.addGestureRecognizer(hover)
        
        // 2. Game Controller: Hook up the physical hardware support
        // We do this after init so the view is ready
        DispatchQueue.main.async {
            self.controllerSupport?.attachGCEventInteraction(to: self)
        }
    }
    
    // MARK: - Hover Handling (Passive Movement)
    
    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        let location = gesture.location(in: self)
        
        // Send mouse move immediately
        // We do NOT filter by "lastMouseX" here because the OS interpolation
        // needs high refresh rates for smooth movement.
        sendMousePosition(x: location.x, y: location.y)
    }

    // MARK: - Touch Handling (Active Clicking/Dragging)
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 1. Move cursor to touch point
        if let touch = touches.first {
            let loc = touch.location(in: self)
            sendMousePosition(x: loc.x, y: loc.y)
        }
        
        // 2. Send Left Click Down
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT)
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 1. Move cursor (Dragging)
        if let touch = touches.first {
            let loc = touch.location(in: self)
            sendMousePosition(x: loc.x, y: loc.y)
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 1. Release Left Click
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT)
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 1. Release Left Click
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT)
    }
    
    // MARK: - Coordinate Mapping
    
    private func sendMousePosition(x: CGFloat, y: CGFloat) {
        var finalX = x
        
        // If this view is attached to a FLAT plate, curvature is 0.
        // If attached to the CURVED screen, this math fixes the distortion.
        if curvature > 0.001 {
            let width = bounds.width
            let normalizedX = x / width
            let relativeX = normalizedX - 0.5
            
            let angle = (5.5 * .pi / 6.0) * curvature
            let sinTheta = Float(relativeX) * 2.0 * sin(angle / 2.0)
            let clampedSin = max(-1.0, min(1.0, sinTheta))
            let theta = asin(clampedSin)
            
            let u = (theta / angle) + 0.5
            finalX = CGFloat(u) * width
        }
        
        let width = Int16(bounds.width)
        let height = Int16(bounds.height)
        let sX = Int16(finalX)
        let sY = Int16(y)
        
        LiSendMousePositionEvent(sX, sY, width, height)
    }
    
    // MARK: - Focus & Keyboard
    
    override var canBecomeFocused: Bool { true }
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
}
