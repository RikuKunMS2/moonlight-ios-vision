//
//  GazeInputController.swift
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2) on 4/25/26.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation
import simd
import QuartzCore
import AudioToolbox

class GazeInputController {
    private let longPressActivationDelay: TimeInterval = 0.650
    private let doubleTapDeadZoneDelay: TimeInterval = 0.250  // 250ms
    private let doubleTapDeadZoneDelta: Float = 0.025  // 2.5% of screen (normalized)
    // Threshold to cancel long press (roughly size of a button in UV space)
    private let movementTolerance: Float = 0.015

    // State
    private(set) var pinchActive = false
    private var longPressTimer: Timer?
    private var startUV: SIMD2<Float> = .zero
    private var isRightClickMode = false  // Track if we swapped to right-click
    private var lastClickTime: TimeInterval = 0  // Track last click for double-tap detection
    private var lastClickUV: SIMD2<Float> = .zero  // Track last click position

    var streamConfig: StreamConfiguration?
    
    // Button Constants (matching moonlight-common-c)
    private let ACTION_PRESS: Int8 = 0x07
    private let ACTION_RELEASE: Int8 = 0x08
    private let BUTTON_LEFT: Int32 = 0x01
    private let BUTTON_RIGHT: Int32 = 0x03
    
    func onPinchBegan(at uv: SIMD2<Float>) {
        guard !pinchActive else { return }
        pinchActive = true
        startUV = uv
        isRightClickMode = false

        // Check if we're in the double-tap dead zone
        let now = CACurrentMediaTime()
        let timeSinceLastClick = now - lastClickTime
        
        // Calculate distance from last click
        let dx = uv.x - lastClickUV.x
        let dy = uv.y - lastClickUV.y
        let distance = sqrt(dx * dx + dy * dy)
        
        // Don't reposition mouse for clicks within the double-tap deadzone
        // This is critical for double-clicking to work properly
        if timeSinceLastClick > doubleTapDeadZoneDelay || distance > doubleTapDeadZoneDelta {
            sendMousePosition(uv: uv)
        }

        // Press Left Button Immediately ("Shoot First")
        // This makes clicks instant and drags seamless.
        sendMouseButton(action: ACTION_PRESS, button: BUTTON_LEFT)

        // Start Long Press Timer (for Right Click)
        // Always start the timer - it will be cancelled if we're dragging
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressActivationDelay, repeats: false) { [weak self] _ in
            self?.triggerLongPress()
        }
        
        lastClickTime = now
        lastClickUV = uv
    }
    
    func onPinchChanged(at uv: SIMD2<Float>) {
        // Always update position (Dragging happens naturally because Left is already Down)
        sendMousePosition(uv: uv)
        
        // Check distance to see if we should cancel the "Right Click" timer
        if longPressTimer != nil {
            let dx = uv.x - startUV.x
            let dy = uv.y - startUV.y
            let dist = sqrt(dx*dx + dy*dy)
            
            if dist > movementTolerance {
                // Moved too far, user is dragging. Cancel Right Click timer.
                longPressTimer?.invalidate()
                longPressTimer = nil
            }
        }
    }
    
    func onPinchEnded() {
        guard pinchActive else { return }
        pinchActive = false
        
        // Cancel timer if it hasn't fired yet
        longPressTimer?.invalidate()
        longPressTimer = nil
        
        // Release buttons based on what mode we're in
        if isRightClickMode {
            // Release Right Button
            sendMouseButton(action: ACTION_RELEASE, button: BUTTON_RIGHT)
        } else {
            // Release Left Button (Standard Click / Drag End)
            sendMouseButton(action: ACTION_RELEASE, button: BUTTON_LEFT)
        }
        
        isRightClickMode = false
    }
    
    private func triggerLongPress() {
        // User held still! Swap Left Click for Right Click.
        isRightClickMode = true
        
        // 1. Release Left (Cancel the click/drag we started)
        sendMouseButton(action: ACTION_RELEASE, button: BUTTON_LEFT)
        
        // 2. Press Right
        sendMouseButton(action: ACTION_PRESS, button: BUTTON_RIGHT)
        
        // 3. Provide subtle audio feedback to indicate right-click is armed
        AudioServicesPlaySystemSound(1104) // Standard keyboard 'tock' sound
    }
    
    private func sendMousePosition(uv: SIMD2<Float>) {
        guard let config = streamConfig else { return }
        let x = Int16(uv.x * Float(config.width))
        let y = Int16(uv.y * Float(config.height))
        LiSendMousePositionEvent(x, y, Int16(config.width), Int16(config.height))
    }
    
    // MARK: - Touch Mode (Relative Mouse Movement)
    // For trackpad-style cursor control
    // Works like a real trackpad:
    // - Drag = move cursor only (no click)
    // - Quick tap = click
    // - Tap + hold + drag = click and drag

    
    private var lastTouchPosition: SIMD3<Float>? = nil
    private var touchStartPosition: SIMD3<Float>? = nil
    private var touchStartTime: TimeInterval = 0
    private var hasMovedInTouch = false
    private var touchClickTimer: Timer? = nil
    private var touchModeInitialized = false  // Track if cursor has been centered
    private let touchTapThreshold: Float = 0.01  // 1cm movement = drag, not tap
    private let touchTapTimeThreshold: TimeInterval = 0.2  // 200ms = quick tap
    
    func onTouchDragBegan(at worldPos: SIMD3<Float>) {
        guard !pinchActive else { return }
        pinchActive = true
        lastTouchPosition = worldPos
        touchStartPosition = worldPos
        touchStartTime = CACurrentMediaTime()
        hasMovedInTouch = false
        isRightClickMode = false
        
        // On first touch in Touch mode, center the cursor
        if !touchModeInitialized {
            forceCursorToCenter()
            touchModeInitialized = true
        }
        
        // DON'T press any button yet - wait to see if it's a tap or drag
        // Start a timer to detect "tap and hold" for click-drag
        touchClickTimer?.invalidate()
        touchClickTimer = Timer.scheduledTimer(withTimeInterval: touchTapTimeThreshold, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // If still holding after 200ms and haven't moved much, it's a click-drag
            if !self.hasMovedInTouch {
                self.sendMouseButton(action: self.ACTION_PRESS, button: self.BUTTON_LEFT)
            }
        }
    }
    
    func onTouchDragChanged(at worldPos: SIMD3<Float>) {
        guard let lastPos = lastTouchPosition,
              let startPos = touchStartPosition else { return }
        
        // Calculate delta in world space
        let delta = worldPos - lastPos
        
        // Check if we've moved significantly from start
        let totalDelta = worldPos - startPos
        let totalDist = simd_length(totalDelta)
        
        if totalDist > touchTapThreshold {
            hasMovedInTouch = true
            // Cancel the click timer - this is a drag, not a tap
            touchClickTimer?.invalidate()
            touchClickTimer = nil
        }
        
        // Convert 3D delta to 2D screen movement
        // Scale factor: adjust sensitivity (higher = more sensitive)
        let sensitivity: Float = 800.0
        let deltaX = delta.x * sensitivity
        let deltaY = -delta.y * sensitivity  // Invert Y for natural movement
        
        // Send relative mouse movement (cursor moves, no button pressed)
        sendRelativeMouseMovement(dx: deltaX, dy: deltaY)
        
        lastTouchPosition = worldPos
    }
    
    func onTouchDragEnded() {
        guard pinchActive else { return }
        pinchActive = false
        
        let now = CACurrentMediaTime()
        let holdDuration = now - touchStartTime
        
        // Cancel timers
        touchClickTimer?.invalidate()
        touchClickTimer = nil
        longPressTimer?.invalidate()
        longPressTimer = nil
        
        // Determine what kind of gesture this was
        if !hasMovedInTouch && holdDuration < touchTapTimeThreshold {
            // Quick tap without movement = CLICK
            sendMouseButton(action: ACTION_PRESS, button: BUTTON_LEFT)
            // Release after a tiny delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.sendMouseButton(action: self?.ACTION_RELEASE ?? 0x08, button: self?.BUTTON_LEFT ?? 0x01)
            }
        } else if !hasMovedInTouch && holdDuration >= touchTapTimeThreshold {
            // Held still for a while = click was already sent by timer, now release
            sendMouseButton(action: ACTION_RELEASE, button: BUTTON_LEFT)
        } else {
            // Movement happened = just cursor movement, no click needed
            // (unless click timer fired for click-drag, in which case release it)
            if holdDuration >= touchTapTimeThreshold {
                sendMouseButton(action: ACTION_RELEASE, button: BUTTON_LEFT)
            }
        }
        
        lastTouchPosition = nil
        touchStartPosition = nil
        hasMovedInTouch = false
        isRightClickMode = false
    }
    
    private var currentMouseX: Int16 = 0
    private var currentMouseY: Int16 = 0
    
    private func sendRelativeMouseMovement(dx: Float, dy: Float) {
        guard let config = streamConfig else { return }
        
        // Update internal cursor position
        currentMouseX = Int16(max(0, min(Float(config.width), Float(currentMouseX) + dx)))
        currentMouseY = Int16(max(0, min(Float(config.height), Float(currentMouseY) + dy)))
        
        LiSendMousePositionEvent(currentMouseX, currentMouseY, Int16(config.width), Int16(config.height))
    }
    
    func forceCursorToCenter() {
        guard let config = streamConfig else { return }
        
        // Calculate exact center pixels
        let centerX = Int16(config.width / 2)
        let centerY = Int16(config.height / 2)
        
        // Update internal tracking
        currentMouseX = centerX
        currentMouseY = centerY
        
        print("🎯 Forcing Mouse to Center: \(centerX), \(centerY)")
        LiSendMousePositionEvent(centerX, centerY, Int16(config.width), Int16(config.height))
    }

    private func sendMouseButton(action: Int8, button: Int32) {
        LiSendMouseButtonEvent(action, button)
    }
    
    func cleanup() {
        longPressTimer?.invalidate()
        longPressTimer = nil
        touchClickTimer?.invalidate()
        touchClickTimer = nil
        lastTouchPosition = nil
        touchStartPosition = nil
        touchModeInitialized = false  // Reset for next time
        if pinchActive {
            // Safety release both buttons
            sendMouseButton(action: ACTION_RELEASE, button: BUTTON_LEFT)
            sendMouseButton(action: ACTION_RELEASE, button: BUTTON_RIGHT)
        }
        pinchActive = false
        isRightClickMode = false
    }
}
