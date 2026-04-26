//
//  InputCaptureUIView.swift
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2) on 4/25/26.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI
import RealityKit
import simd
import GameController
import UIKit

final class ThreadSafeHDRSettings: @unchecked Sendable {
    private var params: HDRParams
    private let lock = NSLock()
    init(params: HDRParams) { self.params = params }
    var value: HDRParams {
        get { lock.lock(); defer { lock.unlock() }; return params }
        set { lock.lock(); defer { lock.unlock() }; params = newValue }
    }
}

class HeadPositionStorage {
    var positionInScreenSpace: SIMD3<Float> = .zero
}

class SIMD3Storage {
    var value: SIMD3<Float> = .zero
}

class MutableBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

enum InputMode: Int, CaseIterable {
    case screenMove = 0
    case controller = 1
    case gazeControl = 2
    
    var localizedKey: String {
        switch self {
        case .screenMove: return "input_mode_screen_adjust"
        case .controller: return "input_mode_controller"
        case .gazeControl: return "input_mode_gaze"
        }
    }
    
    var displayName: String {
        switch self {
        case .screenMove: return "Screen Adjust Mode"
        case .controller: return "Controller Mode"
        case .gazeControl: return "Gaze Control Mode"
        }
    }
    
    var icon: String {
        switch self {
        case .screenMove: return "arrow.up.and.down.and.arrow.left.and.right"
        case .controller: return "gamecontroller.fill"
        case .gazeControl: return "eye.fill"
        }
    }
    
    func next() -> InputMode {
        let allCases = InputMode.allCases
        let idx = allCases.firstIndex(of: self) ?? 0
        return allCases[(idx + 1) % allCases.count]
    }
}

struct InputCaptureView: UIViewRepresentable {
    let controllerSupport: ControllerSupport
    @Binding var showKeyboard: Bool
    var isControllerMode: Bool  // True only when inputMode == .controller
    var curvature: Float
    var streamConfig: StreamConfiguration
    let headStorage: HeadPositionStorage
    
    func makeUIView(context: Context) -> InputCaptureUIView {
        let view = InputCaptureUIView()
        view.curvature = curvature
        view.controllerSupport = controllerSupport
        view.streamConfig = streamConfig
        view.headStorage = headStorage
        view.allowTouchPassthrough = !showKeyboard && !isControllerMode
        
        view.isMultipleTouchEnabled = true
        view.isUserInteractionEnabled = true
        view.backgroundColor = UIColor.black.withAlphaComponent(0.01)
        
        return view
    }
    
    func updateUIView(_ uiView: InputCaptureUIView, context: Context) {
        uiView.curvature = curvature
        uiView.streamConfig = streamConfig
        uiView.headStorage = headStorage
        uiView.allowTouchPassthrough = !showKeyboard && !isControllerMode
        uiView.showVirtualKeyboard = showKeyboard
        
        // ALWAYS aggressively reclaim first responder (needed for controller input)
        if !uiView.isFirstResponder {
            _ = uiView.becomeFirstResponder()
            
            // Double-check and force if needed
            if !uiView.isFirstResponder {
                DispatchQueue.main.async {
                    _ = uiView.becomeFirstResponder()
                }
            }
        }
    }
}

class InputCaptureUIView: UIView, UIKeyInput {
    var controllerSupport: ControllerSupport?
    var curvature: Float = 0.0
    var streamConfig: StreamConfiguration?
    var headStorage: HeadPositionStorage?
    var allowTouchPassthrough: Bool = true
    var firstResponderCheckTimer: Timer?
    var showVirtualKeyboard: Bool = false {
        didSet {
            if oldValue != showVirtualKeyboard {
                reloadInputViews()
            }
        }
    }
    
    private let maxCurveAngle: Float = 1.3
    
    // Suppress software keyboard if showVirtualKeyboard is false, but still allow hardware input
    override var inputView: UIView? {
        return showVirtualKeyboard ? nil : UIView()
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupGestures()
        startFirstResponderMonitoring()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGestures()
        startFirstResponderMonitoring()
    }
    
    private func startFirstResponderMonitoring() {
        // Periodically check and reclaim first responder if lost (needed for controller input)
        firstResponderCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.isFirstResponder {
                _ = self.becomeFirstResponder()
            }
        }
    }
    
    deinit {
        firstResponderCheckTimer?.invalidate()
    }
    
    private func setupGestures() {
        // From commit 12250ee: Attach GCEventInteraction for reliable controller input
        DispatchQueue.main.async {
            self.controllerSupport?.attachGCEventInteraction(to: self)
        }
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if allowTouchPassthrough {
            return nil
        }
        return super.hitTest(point, with: event)
    }
    
    override var canBecomeFocused: Bool { true }
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    
    func insertText(_ text: String) {
        let cString = text.cString(using: .utf8)
        cString?.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                LiSendUtf8TextEvent(base, UInt32(text.utf8.count))
            }
        }
    }
    
    func deleteBackward() {
        LiSendKeyboardEvent(0x08, 0x03, 0)
        usleep(50 * 1000)
        LiSendKeyboardEvent(0x08, 0x04, 0)
    }
    
    // Handle special keys like Return/Enter
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        
        for press in presses {
            if KeyboardSupport.sendKeyEvent(for: press, down: true) {
                handled = true
            }
        }
        
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }
    
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        
        for press in presses {
            if KeyboardSupport.sendKeyEvent(for: press, down: false) {
                handled = true
            }
        }
        
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }
}
