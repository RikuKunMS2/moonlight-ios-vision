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

class GlobalInputState {
    static let shared = GlobalInputState()
    var activeTouchIsHand: Bool = false
    var lastPhysicalMouseActivityTime: TimeInterval = 0
}

@_cdecl("UpdatePhysicalMouseActivityTime")
func UpdatePhysicalMouseActivityTime() {
    GlobalInputState.shared.lastPhysicalMouseActivityTime = CACurrentMediaTime()
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

struct InputCaptureView: UIViewControllerRepresentable {
    let controllerSupport: ControllerSupport
    @Binding var showKeyboard: Bool
    var isControllerMode: Bool  // True only when inputMode == .controller
    var curvature: Float
    var streamConfig: StreamConfiguration
    let headStorage: HeadPositionStorage
    var fpsMouseCapture: Bool
    
    func makeUIViewController(context: Context) -> InputCaptureViewController {
        let vc = InputCaptureViewController()
        let view = vc.captureView
        view.curvature = curvature
        view.controllerSupport = controllerSupport
        controllerSupport.attachGCEventInteraction(to: view)
        view.streamConfig = streamConfig
        view.headStorage = headStorage
        view.allowTouchPassthrough = !showKeyboard && !isControllerMode
        
        controllerSupport.fpsMouseCaptureEnabled = fpsMouseCapture
        controllerSupport.relativeMouseMode = isControllerMode
        
        vc.fpsMouseCaptureEnabled = fpsMouseCapture
        return vc
    }
    
    func updateUIViewController(_ uiViewController: InputCaptureViewController, context: Context) {
        let view = uiViewController.captureView
        view.curvature = curvature
        view.streamConfig = streamConfig
        view.headStorage = headStorage
        view.allowTouchPassthrough = !showKeyboard && !isControllerMode
        view.showVirtualKeyboard = showKeyboard
        
        controllerSupport.fpsMouseCaptureEnabled = fpsMouseCapture
        controllerSupport.relativeMouseMode = isControllerMode
        
        uiViewController.fpsMouseCaptureEnabled = fpsMouseCapture
        
        // ALWAYS aggressively reclaim first responder (needed for controller input)
        if view.window != nil && !view.isFirstResponder && UIApplication.shared.applicationState == .active {
            _ = view.becomeFirstResponder()
            
            // Double-check and force if needed
            if !view.isFirstResponder {
                DispatchQueue.main.async {
                    if view.window != nil && UIApplication.shared.applicationState == .active {
                        _ = view.becomeFirstResponder()
                    }
                }
            }
        }
    }
    
    static func dismantleUIViewController(_ uiViewController: InputCaptureViewController, coordinator: Coordinator) {
        uiViewController.fpsMouseCaptureEnabled = false
        uiViewController.captureView.cleanup()
    }
}

struct SwiftUIAbsoluteMouseTracker: View {
    var controllerSupport: ControllerSupport?
    @Binding var showKeyboard: Bool
    var isControllerMode: Bool
    var curvature: Float
    var streamConfig: StreamConfiguration
    var headStorage: HeadPositionStorage
    var fpsMouseCapture: Bool
    
    @State private var longPressTimer: Timer?
    @State private var isDragging: Bool = false
    
    private let BUTTON_ACTION_PRESS: Int8 = 0x07
    private let BUTTON_ACTION_RELEASE: Int8 = 0x08
    private let BUTTON_LEFT: Int32 = 0x01
    private let BUTTON_RIGHT: Int32 = 0x03
    
    var body: some View {
        GeometryReader { geo in
            InputCaptureView(
                controllerSupport: controllerSupport!,
                showKeyboard: $showKeyboard,
                isControllerMode: isControllerMode,
                curvature: curvature,
                streamConfig: streamConfig,
                headStorage: headStorage,
                fpsMouseCapture: fpsMouseCapture
            )
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard isControllerMode && !fpsMouseCapture else { return }
                switch phase {
                case .active(let location):
                    GlobalInputState.shared.lastPhysicalMouseActivityTime = CACurrentMediaTime()
                    updateCursorFromSystemPointer(location: location, bounds: geo.size)
                case .ended:
                    break
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard isControllerMode && !fpsMouseCapture else { return }
                        
                        let now = CACurrentMediaTime()
                        // If physical mouse hasn't moved or clicked in the last 0.5 seconds, it's a hand pinch!
                        if now - GlobalInputState.shared.lastPhysicalMouseActivityTime > 0.5 {
                            if !GlobalInputState.shared.activeTouchIsHand {
                                GlobalInputState.shared.activeTouchIsHand = true
                                NotificationCenter.default.post(name: Notification.Name("HandPinchDetected"), object: nil)
                            }
                            return
                        } else {
                            GlobalInputState.shared.activeTouchIsHand = false
                        }
                        
                        updateCursorFromSystemPointer(location: value.location, bounds: geo.size)
                        
                        if !isDragging {
                            isDragging = true
                            LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT)
                            
                            longPressTimer?.invalidate()
                            longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.650, repeats: false) { _ in
                                // Right click emulation
                                LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT)
                                LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_RIGHT)
                            }
                        }
                    }
                    .onEnded { value in
                        if GlobalInputState.shared.activeTouchIsHand { return }
                        if isDragging {
                            isDragging = false
                            longPressTimer?.invalidate()
                            longPressTimer = nil
                            
                            LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT)
                            LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT)
                        }
                    }
            )
            .onKeyPress(phases: [.down, .up, .repeat]) { press in
                let down = (press.phase == .down || press.phase == .repeat)
                let KEY_ACTION_DOWN: Int8 = 0x03
                let KEY_ACTION_UP: Int8 = 0x04
                let action = down ? KEY_ACTION_DOWN : KEY_ACTION_UP
                
                var modifiers: Int8 = 0
                if press.modifiers.contains(.shift) { modifiers |= 0x01 }
                if press.modifiers.contains(.control) { modifiers |= 0x02 }
                if press.modifiers.contains(.option) { modifiers |= 0x04 }
                if press.modifiers.contains(.command) { modifiers |= 0x08 }
                
                var keyCode: Int16 = 0
                switch press.key {
                case .upArrow: keyCode = 0x26
                case .downArrow: keyCode = 0x28
                case .leftArrow: keyCode = 0x25
                case .rightArrow: keyCode = 0x27
                case .escape: keyCode = 0x1B
                case .return: keyCode = 0x0D
                case .delete: keyCode = 0x08
                case .deleteForward: keyCode = 0x2E
                case .tab: keyCode = 0x09
                case .space: keyCode = 0x20
                default:
                    if let first16 = press.characters.utf16.first {
                        let unicharValue = first16
                        if unicharValue >= 0x30 && unicharValue <= 0x39 { keyCode = Int16(unicharValue) }
                        else if unicharValue >= 0x41 && unicharValue <= 0x5A { keyCode = Int16(unicharValue) }
                        else if unicharValue >= 0x61 && unicharValue <= 0x7A { keyCode = Int16(unicharValue - 0x20) }
                        else {
                            switch press.key.character {
                            case "-": keyCode = 0xBD
                            case "=": keyCode = 0xBB
                            case "[": keyCode = 0xDB
                            case "]": keyCode = 0xDD
                            case "\\": keyCode = 0xDC
                            case ";": keyCode = 0xBA
                            case "'": keyCode = 0xDE
                            case ",": keyCode = 0xBC
                            case ".": keyCode = 0xBE
                            case "/": keyCode = 0xBF
                            case "`": keyCode = 0xC0
                            default: return .ignored
                            }
                        }
                    } else {
                        return .ignored
                    }
                }
                
                LiSendKeyboardEvent(Int16(bitPattern: 0x8000) | keyCode, action, modifiers)
                return .handled
            }
            .onDisappear {
                longPressTimer?.invalidate()
                longPressTimer = nil
                isDragging = false
            }
        }
    }
    
    private func updateCursorFromSystemPointer(location: CGPoint, bounds: CGSize) {
        // This must perfectly match the sizing in RealityKitStreamView:
        // targetWidth: CURVED_MAX_WIDTH_METERS * 1.05
        let overscaleX: CGFloat = 1.05
        
        let rawNormX = location.x / bounds.width
        let rawNormY = location.y / bounds.height
        
        // Scale out from the exact center (0.5)
        let correctedNormX = (rawNormX - 0.5) * overscaleX + 0.5
        
        // Apply a non-linear curve for the Y axis to allow reaching the top and bottom of the host screen.
        // The physical visionOS volume limits vertical movement, clipping rawNormY before it reaches 0 or 1.
        // We use a cubic curve y = a*x + b*x^3 to maintain reasonable center sensitivity while 
        // aggressively scaling the edges so the user can easily reach the full [-0.5, 0.5] range.
        let dy = rawNormY - 0.5
        let a: CGFloat = 1.5
        let b: CGFloat = 50.0
        let nonLinearY = (a * dy) + (b * (dy * dy * dy))
        let correctedNormY = nonLinearY + 0.5
        
        var hostX = correctedNormX * CGFloat(streamConfig.width)
        var hostY = correctedNormY * CGFloat(streamConfig.height)
        
        // Clamp to bounds to prevent host cursor from wrapping or snapping
        hostX = min(max(hostX, 0), CGFloat(streamConfig.width))
        hostY = min(max(hostY, 0), CGFloat(streamConfig.height))
        
        LiSendMousePositionEvent(Int16(hostX), Int16(hostY), Int16(streamConfig.width), Int16(streamConfig.height))
    }
}

class GlobalPointerLock {
    static let shared = GlobalPointerLock()
    
    var isLocked: Bool = false {
        didSet {
            if oldValue != isLocked {
                DispatchQueue.main.async {
                    for scene in UIApplication.shared.connectedScenes {
                        if let windowScene = scene as? UIWindowScene {
                            for window in windowScene.windows {
                                window.rootViewController?.setNeedsUpdateOfPrefersPointerLocked()
                            }
                        }
                    }
                }
            }
        }
    }
    
    private static let swizzleOnce: Void = {
        let originalSelector = #selector(getter: UIViewController.prefersPointerLocked)
        let swizzledSelector = #selector(getter: UIViewController.swizzled_prefersPointerLocked)
        guard let originalMethod = class_getInstanceMethod(UIViewController.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(UIViewController.self, swizzledSelector) else { return }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    
    static func swizzle() {
        _ = swizzleOnce
    }
}

extension UIViewController {
    @objc dynamic var swizzled_prefersPointerLocked: Bool {
        if GlobalPointerLock.shared.isLocked {
            return true
        }
        return self.swizzled_prefersPointerLocked
    }
}

class InputCaptureViewController: UIViewController {
    var fpsMouseCaptureEnabled: Bool = false {
        didSet {
            if oldValue != fpsMouseCaptureEnabled {
                GlobalPointerLock.shared.isLocked = fpsMouseCaptureEnabled
                if #available(iOS 14.0, *) {
                    setNeedsUpdateOfPrefersPointerLocked()
                }
            }
        }
    }
    
    init() {
        super.init(nibName: nil, bundle: nil)
        GlobalPointerLock.swizzle()
        setupObservers()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        GlobalPointerLock.swizzle()
        setupObservers()
    }
    
    private func setupObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(updatePointerLock), name: .GCMouseDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePointerLock), name: .GCMouseDidDisconnect, object: nil)
        if #available(iOS 14.0, *) {
            NotificationCenter.default.addObserver(self, selector: #selector(pointerLockStateDidChange(_:)), name: UIPointerLockState.didChangeNotification, object: nil)
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    @objc private func appDidEnterBackground() {
        if GlobalPointerLock.shared.isLocked {
            GlobalPointerLock.shared.isLocked = false
        }
    }
    
    @objc private func appWillEnterForeground() {
        if fpsMouseCaptureEnabled {
            GlobalPointerLock.shared.isLocked = true
            if #available(iOS 14.0, *) {
                setNeedsUpdateOfPrefersPointerLocked()
            }
        }
    }
    
    @objc private func updatePointerLock() {
        guard UIApplication.shared.applicationState == .active else { return }
        GlobalPointerLock.shared.isLocked = fpsMouseCaptureEnabled
        if #available(iOS 14.0, *) {
            setNeedsUpdateOfPrefersPointerLocked()
        }
    }
    
    @objc private func pointerLockStateDidChange(_ notification: Notification) {
        if #available(iOS 14.0, *) {
            // If the system drops the pointer lock but we still want it, 
            // aggressively request it back. The system will honor it as soon
            // as our app regains focus.
            if let scene = notification.userInfo?[UIPointerLockState.sceneUserInfoKey] as? UIScene,
               let pointerLockState = (scene as? UIWindowScene)?.pointerLockState {
                
                if !pointerLockState.isLocked && fpsMouseCaptureEnabled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self = self, self.fpsMouseCaptureEnabled else { return }
                        guard UIApplication.shared.applicationState == .active else { return }
                        self.setNeedsUpdateOfPrefersPointerLocked()
                        
                        // Also try the active window's root view controller to be safe
                        for window in (scene as? UIWindowScene)?.windows ?? [] {
                            if window.isKeyWindow {
                                window.rootViewController?.setNeedsUpdateOfPrefersPointerLocked()
                            }
                        }
                    }
                }
            }
        }
    }
    
    lazy var captureView: InputCaptureUIView = {
        let view = InputCaptureUIView()
        view.isMultipleTouchEnabled = true
        view.isUserInteractionEnabled = true
        view.backgroundColor = UIColor.black.withAlphaComponent(0.01)
        return view
    }()
    
    override func loadView() {
        self.view = captureView
    }
    
    override var prefersPointerLocked: Bool {
        return fpsMouseCaptureEnabled
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
        startFirstResponderMonitoring()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        startFirstResponderMonitoring()
    }
    
    private func startFirstResponderMonitoring() {
        // Periodically check and reclaim first responder if lost (needed for controller input)
        firstResponderCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard UIApplication.shared.applicationState == .active else { return }
            if self.window != nil && !self.isFirstResponder {
                _ = self.becomeFirstResponder()
            }
        }
    }
    
    func cleanup() {
        firstResponderCheckTimer?.invalidate()
        firstResponderCheckTimer = nil
    }
    
    deinit {
        cleanup()
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
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
    }
    
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
