//
//  RealityKitStreamView.swift
//  Moonlight Vision
//
//  Moonlight Vision - Immersive streaming view
//

import SwiftUI
import RealityKit
import simd
import GameController
import ARKit
import UIKit
import AVFoundation
import QuartzCore
import ImageIO
import os



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

let MAX_WIDTH_METERS: Float = 2.0
let MAX_CURVE_ANGLE: Float = 1.3
let CURVED_MAX_WIDTH_METERS: Float = MAX_WIDTH_METERS
let CURVED_MAX_ANGLE: Float = MAX_CURVE_ANGLE
let GAZE_VERTICAL_OFFSET: Float = 0.015  // Small upward offset to compensate for eye-to-cursor alignment

extension CollisionGroup {
    static let screenEntity = CollisionGroup(rawValue: 1 << 0)
    static let uiElements = CollisionGroup(rawValue: 1 << 1)
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

struct RealityKitStreamView: View {
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @EnvironmentObject private var viewModel: MainViewModel
    @Binding var streamConfig: StreamConfiguration?
    var needsHdr: Bool
    var isImmersive: Bool
    
    var body: some View {
        if let config = streamConfig {
            if config.sessionUUID == viewModel.activeSessionToken {
                _RealityKitStreamView(
                    streamConfig: Binding<StreamConfiguration>(
                        get: { config },
                        set: { streamConfig = $0 }
                    ),
                    needsHdr: needsHdr,
                    isImmersive: isImmersive,
                    swapAction: { }
                )
                .id(config.sessionUUID)
            } else {
                // Ghost/stale window: a different session UUID is active.
                // Redirect to main menu and close this window.
                Color.black
                    .ignoresSafeArea()
                    .task {
                        print("Ghost view detected (UUID \(config.sessionUUID) != active \(viewModel.activeSessionToken)). Redirecting to main menu.")
                        redirectZombieToMainMenu()
                    }
            }
        } else {
            // Zombie window: visionOS restored this scene after a reboot or long
            // sleep but the process has no active stream (StreamConfiguration was
            // never persisted across a process kill).  Redirect to main menu.
            Color.black
                .ignoresSafeArea()
                .task {
                    guard !viewModel.activelyStreaming else { return }
                    print("[RealityKitStreamView] Zombie scene detected (nil config, not streaming). Redirecting to main menu.")
                    redirectZombieToMainMenu()
                }
        }
    }

    /// Open the main menu window and close this dead streaming window/space.
    private func redirectZombieToMainMenu() {
        viewModel.savedStreamConfigForResume = nil
        openWindow(id: "mainView")
        // Small delay so the main window has time to register before we close self.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if isImmersive {
                Task { await dismissImmersiveSpace() }
            } else {
                dismissWindow(id: "realitykitStreamingWindow")
            }
            streamConfig = nil
        }
    }
}

struct _RealityKitStreamView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var viewModel: MainViewModel
    @EnvironmentObject private var controlState: StreamControlState
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    @Binding var streamConfig: StreamConfiguration
    var needsHdr: Bool
    var isImmersive: Bool
    let swapAction: () -> Void
    
    // Volume window positioning (non-immersive only)
    @State private var volumeHeight: Float = 0
    @State private var volumeDepthOffset: Float = 0.0
    @State private var volumeYLimits: ClosedRange<Float> = -0.5...0.5
    @State private var volumeZLimits: ClosedRange<Float> = -0.5...0.5
    
    @State private var streamMan: StreamManager?
    @State private var controllerSupport: ControllerSupport?
    @ObservedObject var connectionCallbacks: ObservableConnectionManager = .init()
    @State private var lastStreamErrorMessage: String? = nil
    
    /// Auto-reconnect: attempt count (0 = fresh, 1..=max = retrying). Reset on first frame.
    @State private var reconnectAttemptCount: Int = 0
    @State private var isReconnecting: Bool = false
    @State private var isPerformingReconnectTeardown: Bool = false  // Ignore ConnectionTerminatedForRetry during this
    private let maxReconnectAttempts = 3
    private let reconnectDelaySeconds: TimeInterval = 2.5
    
    // Immersive Environment
    @State private var immersiveEnvironment = ImmersiveEnvironment()
    @State private var blackOutSphere: ModelEntity = ModelEntity()
    @State private var selectedEnvironmentState: EnvironmentStateType = .none
    @State private var isUpdatingImmersion = false
    // Stage Pinning
    @State private var isPinnedToStage = false
    @State private var isPinningTransitioning = false
    @State private var lastFreeformTransform: Transform?
    @State private var wasInteractiveBeforePin = false
    @State private var pinStartScale: Float = 1.0
    @State private var pinnedStageScale: Float = 1.0
    @State private var screenOriginalParent: Entity?
    @State private var isInteractive = false
    // Immersive transform (synced with controlState)
    @State private var immersionAmount: Float = 0.0
    // Control panel entity
    @State private var controlPanelEntity: Entity?
    
    @State private var texture: TextureResource
    @State private var screen: ModelEntity = ModelEntity()
    @State private var videoMode: VideoMode = .standard2D
    @State private var surfaceMaterial: ShaderGraphMaterial?
    
    @State private var curveAnimationMultiplier: Float = 1.0
    @State private var animationTimer: Timer?
    
    @State private var sliderCurvature: Float = 0.0
    @State private var tiltAngle: Float = 0.0
    @State private var tiltDirection: Int = 1
    
    @State private var screenPosition: SIMD3<Float> = SIMD3<Float>(0, 1.0, -1.5)  // Match StreamControlState: x=0, y=1.0, z=-1.5 (viewing 1.5m)
    @State private var screenScale: Float = 0.8
    @State private var isLocked: Bool = false
    @State private var startDragPosition: SIMD3<Float>? = nil
    @State private var hasInitializedPosition = false
    
    @State private var safeHDRSettings = ThreadSafeHDRSettings(
        params: HDRParams(boost: 1.0, contrast: 1.0, saturation: 1.0, brightness: 0.0, pqExposure: 1.0, mode: 0)
    )
    @StateObject private var hdrParams = HDRTestParams()

    @State private var showVirtualKeyboard = false
    @State private var hideControls: Bool = false
    
    // Keyboard Override State
    @State private var keyboardInput: String = ""
    @State private var previousKeyboardInput: String = ""
    @FocusState private var isKeyboardFocused: Bool
    
    @State private var hideTimer: Timer?
    @State private var controlsEntity: Entity?
    @State private var shouldClose = false
    @State private var hasPerformedTeardown = false
    @State private var needsResume = false
    @State private var spatialAudioMode: Bool = true
    @State private var statsOverlayText: String = ""
    @State private var statsTimer: Timer?
    @State private var showScaleHUD: Bool = false
    @State private var showModeLabel: Bool = false
    @State private var modeLabelTimer: Timer?
    @State private var controlsHighlighted: Bool = false
    @State private var immersiveSpaceSceneID: String?
    @State private var showMenuPanel = false
    @State private var menuEntity: Entity?
    @State private var menuScaleInitialized = false
    @State private var menuBaseWidth: Float = 0
    @State private var inputScaleInitialized = false
    @State private var inputBaseWidth: Float = 0
    @State private var swapInProgress = false
    @State private var menuPanelInstanceID = UUID()
    @State private var showDimmingPicker = false
    @State private var inputMode: InputMode = .gazeControl // Three-mode input toggle (default: gaze control)
    @State private var gazeController = GazeInputController()

    private let headStorage = HeadPositionStorage()
    
    @State private var renderGateOpen: Bool = true
    
    private let attachmentLayoutAspectBox = MutableBox<Float>(-1)
    
    // Stats attachment sizing in meters (fixed width target)
    @State private var statsScaleInitialized = false
    @State private var statsBaseWidth: Float = 0
    private let statsCardWidthMeters: Float = 0.55
    
    @State private var gestureInitialScale: Float? = nil
    @State private var targetScale: Float = 0.8
    @State private var scaleHUDFadeTimer: Timer?
    @State private var environmentFadeTimer: Timer?
    
    @State private var dimmerDome: ModelEntity?
    @State private var dimmerDomePurple: ModelEntity?
    @State private var purpleGradientTextureColors: TextureResource?
    @State private var purpleGradientTexturePurpleBlack: TextureResource?
    @State private var eclipseGradientTexture: TextureResource?
    @State private var twilightGradientTexture: TextureResource?
    @State private var dawnGradientTexture: TextureResource?
    @State private var sunriseGradientTexture: TextureResource?
    @State private var woodlandGradientTexture: TextureResource?
    @State private var desertGradientTexture: TextureResource?
    @State private var duskHDRTexture: TextureResource?
    @State private var moonlightCycleTimer: Timer?
    @State private var moonlightCyclePhase: CGFloat = 0.0
    private let dimAlphas: [CGFloat] = [0.0, 0.82]
    @State private var dimLevel: Int = 0
    private let lastAppliedDimLevelBox = MutableBox(-1)
    @State private var environmentSphereLevel: Int = 0
    @State private var environmentUSDZLevel: Int = 0
    @State private var moonlightMaterial: UnlitMaterial?
    @State private var lastMoonlightAppliedRGB: SIMD3<Float> = .zero
    @State private var lastMoonlightUpdateTime: CFTimeInterval = CACurrentMediaTime()
    private let moonlightCycleDurationLowPower: CGFloat = 22.0
    private let moonlightUpdateIntervalLowPower: TimeInterval = 0.22
    private let moonlightColorDeltaThresholdLowPower: Float = 0.03
    private let moonlightAlphaLowPower: CGFloat = 0.78
    
    @State private var lastEnvironmentSphereLevelApplied: Int = 0
    
    @State private var showInlineHint: Bool = false
    @State private var hintOverlayText: String = ""
    @State private var hintOverlayIcon: String = "info.circle"
    @State private var hintOverlayTimer: Timer?
    
    // Co-op invite button state
    @State private var isHDRTexture: Bool = false
    
    @State private var currentAmbientColor: UIColor = .black
    @State private var targetReactiveColor: UIColor = .black
    @State private var reactiveLerpTimer: Timer?
    @State private var cachedReactiveMaterial: UnlitMaterial?
    
    let brandPurple = Color(red: 0.7, green: 0.3, blue: 0.9)
    let brandViolet = Color(red: 0.85, green: 0.6, blue: 0.95)
    
    @State private var isMenuOpen: Bool = false
    
    @State private var isMenuOpen1: Bool = false
    
    @State private var environmentDome: ModelEntity?
    @State private var usdzAboveTheClouds: Entity?
    @State private var usdzAnime: Entity?
    @State private var usdzJustSky: Entity?
    @State private var usdzNightTime: Entity?
    @State private var jpgAboveTheCloudsTexture: TextureResource?
    @State private var jpgAnimeTexture: TextureResource?
    @State private var jpgJustSkyTexture: TextureResource?
    @State private var jpgNightTimeTexture: TextureResource?
    @State private var jpgTest1Texture: TextureResource?
    @State private var jpgTest2Texture: TextureResource?
    @State private var jpgTest3Texture: TextureResource?
    @State private var extraSkyboxTextures: [TextureResource] = []
    @State private var extraSkyboxNames: [String] = []
    /// In-flight skybox bundle scan — cancel before starting another to avoid duplicate GPU allocations.
    @State private var extraSkyboxLoadTask: Task<Void, Never>?
    @State private var dimmerGradientPreloadTask: Task<Void, Never>?
    
    @State private var builtinSkyboxTextures: [String: TextureResource] = [:]
    @State private var envPresetSkyboxTextures: [String: TextureResource] = [:]
    @State private var envPresetLevel: Int = 0

    var isSBSVideo: Bool {
        let ratio = Float(streamConfig.width) / Float(streamConfig.height)
        return abs(ratio - (32.0 / 9.0)) < 0.01
    }

    @State private var firstFrameReceived = false
    @State private var idrWatchdogTimer1: Timer?
    @State private var idrWatchdogTimer2: Timer?
    @State private var postFirstFrameRebindTimer: Timer?
    
    var allowedScaleMax: Float { 8.0 }
    var cornerRadiusFraction: Float { viewModel.streamSettings.realitykitScreenCornerRadius }
    var swapCardWidthMeters: Float { 0.55 }
    
    /// Effective curvature: uses slider value from control panel, with animation multiplier
    var effectiveCurvature: Float {
        sliderCurvature * curveAnimationMultiplier
    }
    
    var screenAspect: Float {
        if let (w, h) = correctedResolution {
            if videoMode == .sideBySide3D, abs(Float(w) / Float(h) - (32.0 / 9.0)) < 0.01 {
                return Float(h) / Float(w / 2)
            } else {
                return Float(h) / Float(w)
            }
        } else {
        if videoMode == .sideBySide3D && isSBSVideo {
            return Float(streamConfig.height) / Float(streamConfig.width / 2)
        } else {
            return Float(streamConfig.height) / Float(streamConfig.width)
            }
        }
    }
    
    @State private var correctedResolution: (Int, Int)? = nil
    
    private let lastGeneratedCurveBox = MutableBox<Float?>(nil)
    private let lastGeneratedAspectBox = MutableBox<Float?>(nil)
    private let lastGeneratedCornerBox = MutableBox<Float?>(nil)
    /// Timestamp of the last mesh generation; used to throttle rebuilds during slider drag.
    private let lastMeshGenTimeBox = MutableBox<Date?>(nil)
    /// Minimum interval between mesh rebuilds (seconds). Limits to ~15 rebuilds/sec during drag.
    private static let meshGenMinInterval: TimeInterval = 0.06
    
    var body: some View {
        let contentView = Group {
            if viewModel.activelyStreaming {
                mainContent
            } else {
                ZStack {
                streamStoppedOverlay
                    if lastStreamErrorMessage != nil {
                        realityKitErrorOverlay(message: lastStreamErrorMessage!)
                    } else {
                        errorHUDOverlay
                    }
                }
            }
        }
        let baseView = contentView
            .overlay(alignment: .bottom) { scaleHUDOverlay }
            .volumeBaseplateVisibility(viewModel.streamSettings.dimPassthrough ? .hidden : .automatic)
            .supportedVolumeViewpoints(.front)
            .preferredSurroundingsEffect(!isImmersive && viewModel.streamSettings.dimPassthrough ? .systemDark : nil)
        
        let lifecycleApplied = baseView
            .task { await setupMaterial() }
            .onAppear(perform: setupScene)
            .onDisappear(perform: teardownScene)
            .onChange(of: viewModel.shouldCloseStream) { _, shouldClose in
                if shouldClose && !hasPerformedTeardown {
                    triggerCloseSequence()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RequestStreamCloseFromMainMenu"))) { _ in
                guard !hasPerformedTeardown else { return }
                triggerCloseSequence()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RealityKitStreamErrorNotification"))) { notification in
                if let msg = notification.userInfo?["message"] as? String {
                    lastStreamErrorMessage = msg
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ConnectionTerminatedForRetry"))) { notification in
                DispatchQueue.main.async { handleConnectionTerminatedForRetry(notification: notification) }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RKStreamFirstFrameShown"))) { _ in
                if reconnectAttemptCount > 0 {
                    reconnectAttemptCount = 0
                    isReconnecting = false
                    connectionCallbacks.isReconnectingForRetry = false
                    print("[StreamView] Reconnect succeeded, reset attempt count")
                }
            }
            .onChange(of: scenePhase) { oldValue, newValue in
                if newValue == .background {
                    if isImmersive {
                        // Trim large GPU assets while the immersive space is not visible — Studio USDZ,
                        // skybox JPEGs, and generated gradient textures otherwise stay resident across
                        // many crown in/out cycles and virtual-scene toggles.
                        releaseImmersiveHeavyCachesForBackground()
                    }
                    if viewModel.activelyStreaming, streamMan != nil {
                        print("Suspending stream due to background")
                        needsResume = true
                        streamMan?.stopStream()
                        streamMan = nil
                        controllerSupport?.cleanup()
                        controllerSupport = nil
                    }
                } else if newValue == .active {
                    if isImmersive,
                       selectedEnvironmentState != .none,
                       !immersiveEnvironment.isLoaded,
                       !immersiveEnvironment.isLoading {
                        immersiveEnvironment.loadEnvironment()
                    }
                    if needsResume {
                        print("Resuming stream from background")
                        needsResume = false
                        self.renderGateOpen = true
                        controllerSupport = ControllerSupport(config: streamConfig, delegate: DummyControllerDelegate())
                        connectionCallbacks.controllerSupport = controllerSupport
                        startStreamIfNeeded()
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            fixAudioForCurrentMode()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            self.refreshAfterResume()
                        }
                    } else if viewModel.activelyStreaming, !isReconnecting {
                        // Health check: If stream should be running but isn't, restart it
                        if streamMan == nil {
                            print("[StreamView] Stream died while inactive - restarting")
                            self.renderGateOpen = true
                            controllerSupport = ControllerSupport(config: streamConfig, delegate: DummyControllerDelegate())
                            connectionCallbacks.controllerSupport = controllerSupport
                            startStreamIfNeeded()
                        }
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            fixAudioForCurrentMode()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.refreshAfterResume() }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .immersiveScreenWakeRequested)) { _ in
                guard viewModel.activelyStreaming && !showMenuPanel else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    hideControls = false
                    controlsHighlighted = true
                }
                startHighlightTimer()
                fixAudioForCurrentMode()
            }
            .onReceive(NotificationCenter.default.publisher(for: .resumeStreamFromMenu)) { _ in
                guard viewModel.activelyStreaming else { return }
                dismissWindow(id: "mainView")
                isMenuOpen = false
                withAnimation(.easeInOut(duration: 0.3)) {
                    hideControls = false
                    controlsHighlighted = true
                }
                startHighlightTimer()
                fixAudioForCurrentMode()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mainViewWindowClosed)) { _ in
                self.handleWindowClose()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ambientAverageColorUpdated)) { notification in
                guard dimLevel == 2 || dimLevel == 10 || dimLevel == 12 else { return }  // Only process in Reactive V1, V2, and Starfield modes
                if let r = notification.userInfo?["r"] as? Float,
                   let g = notification.userInfo?["g"] as? Float,
                   let b = notification.userInfo?["b"] as? Float {
                    // Boost saturation and brightness for more dramatic effect (1.3x)
                    let boostedR = min(1.0, r * 1.3)
                    let boostedG = min(1.0, g * 1.3)
                    let boostedB = min(1.0, b * 1.3)
                    // Set target color - the lerp timer will smoothly interpolate to it
                    targetReactiveColor = UIColor(red: CGFloat(boostedR), green: CGFloat(boostedG), blue: CGFloat(boostedB), alpha: 1.0)
                    
                }
            }
        
        let stateChangesApplied = lifecycleApplied
            .onChange(of: viewModel.streamSettings.statsOverlay) { oldValue, newValue in 
                handleStatsOverlay(oldValue: oldValue, newValue: newValue)
            }
            .onChange(of: viewModel.activelyStreaming) { oldValue, newValue in 
                self.renderGateOpen = true
                handleActiveStreaming(oldValue: oldValue, newValue: newValue)
            }
            .onChange(of: videoMode) { _, _ in updateScreenMaterial() }
            .onChange(of: showMenuPanel) { _, _ in updateScreenInteractivity() }
            .onChange(of: inputMode) { _, _ in updateScreenInteractivity() }
            .onChange(of: viewModel.streamSettings.swapABXYButtons) { _, newValue in
                controllerSupport?.setSwapABXYButtons(newValue)
            }
        
        // Split into a second chain to help the type checker
        let controlStateSynced = stateChangesApplied
            .onChange(of: tiltAngle) { _, newValue in
                controlState.tiltAngle = newValue
            }
            .onChange(of: dimLevel) { _, newValue in
                controlState.dimLevel = newValue
            }
            .onChange(of: controlState.immersiveScale) { _, newValue in
                guard !isPinnedToStage else { return }
                screenScale = newValue
                targetScale = newValue
            }
            .onChange(of: controlState.immersivePositionX) { _, newValue in
                guard !isPinnedToStage else { return }
                screenPosition.x = newValue
            }
            .onChange(of: controlState.immersivePositionY) { _, newValue in
                guard !isPinnedToStage else { return }
                screenPosition.y = newValue
            }
            .onChange(of: controlState.immersivePositionZ) { _, newValue in
                guard !isPinnedToStage else { return }
                screenPosition.z = newValue
            }
            .onChange(of: controlState.immersionAmount) { _, newValue in
                immersionAmount = newValue
            }
            .onChange(of: controlState.tiltAngle) { _, newValue in
                tiltAngle = newValue
            }
            .onChange(of: controlState.dimLevel) { _, newValue in
                if dimLevel != newValue {
                    dimLevel = newValue
                    viewModel.streamSettings.dimPassthrough = (newValue != 0)
                    UserDefaults.standard.set(newValue, forKey: "ambient.dimming.level")
                    updateDimmerDomesState()
                }
            }
            .onChange(of: viewModel.streamSettings.realitykitRendererCurvature) { _, newValue in
                sliderCurvature = newValue
            }
            .onChange(of: viewModel.streamSettings.enableHdr) { _, _ in
                applyDefaultDisplayParams()
            }
            .onChange(of: viewModel.streamSettings.brightness) { _, _ in
                if viewModel.streamSettings.enableHdr { updateHDRParams() }
            }
            .onChange(of: viewModel.streamSettings.gamma) { _, _ in
                if viewModel.streamSettings.enableHdr { updateHDRParams() }
            }
            .onChange(of: viewModel.streamSettings.saturation) { _, _ in
                if viewModel.streamSettings.enableHdr { updateHDRParams() }
            }
            .onChange(of: viewModel.streamSettings.pqExposure) { _, _ in
                if viewModel.streamSettings.enableHdr { updateHDRParams() }
            }

        return controlStateSynced
    }
    
    // MARK: - Body Subviews

    @ViewBuilder
    private var streamStoppedOverlay: some View {
        ZStack {
            RealityView { content in
                let scaffoldMesh = MeshResource.generateBox(size: 2.0)
                let material = UnlitMaterial(color: .clear)
                let scaffoldEntity = ModelEntity(mesh: scaffoldMesh, materials: [material])
                scaffoldEntity.components.set(OpacityComponent(opacity: 0.0))
                content.add(scaffoldEntity)
            }
            .allowsHitTesting(false)
            
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(viewModel.localized("stream_stopped"))
                    .font(.title2)
                Text(viewModel.localized("stream_stopped_message"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button {
                    viewModel.savedStreamConfigForResume = nil
                    lastStreamErrorMessage = nil
            openWindow(id: "mainView")
                    triggerCloseSequence()
                } label: {
                    Label(viewModel.localized("open_main_menu"), systemImage: "house.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }
            .frame(width: 600, height: 400)
            .padding()
            .glassBackgroundEffect()
        }
    }
    
    @ViewBuilder
    private var mainContent: some View {
        GeometryReader3D { proxy in
            ZStack {
                makeRealityView(proxy: proxy)
                controlsHint
                errorHUDOverlay
                if isReconnecting {
                    reconnectingOverlay
                }
            }
        }
    }
    
    @ViewBuilder
    private var reconnectingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(.white)
            Text(viewModel.localized("reconnecting"))
                .font(.headline)
                .foregroundStyle(.white)
            Text(String(format: viewModel.localized("reconnect_attempt"), reconnectAttemptCount, maxReconnectAttempts))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(24)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .zIndex(1500)
    }

    @ViewBuilder
    private var scaleHUD: some View {
        Text(String(format: "%.2fx", targetScale))
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(.black.opacity(0.7))
            )
            .padding(.bottom, 30)
    }

    @ViewBuilder
    private var scaleHUDOverlay: some View {
        if showScaleHUD {
            scaleHUD
                .transition(.opacity)
                .zIndex(1200)
        }
    }
    
    @ViewBuilder
    private func realityKitErrorOverlay(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.32))
            Text(viewModel.localized("stream_error"))
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                lastStreamErrorMessage = nil
                connectionCallbacks.showAlert = false
                openWindow(id: "mainView")
                triggerCloseSequence()
            } label: {
                Label(viewModel.localized("close"), systemImage: "xmark.circle.fill")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .zIndex(1400)
    }
    
    @ViewBuilder
    private func immersiveErrorFloatingOverlay() -> some View {
        let msg = lastStreamErrorMessage ?? connectionCallbacks.errorMessage ?? viewModel.localized("unknown_error")
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.32))
            Text(viewModel.localized("stream_error"))
                .font(.headline)
                .foregroundStyle(.white)
            Text(msg)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(4)
            Button {
                lastStreamErrorMessage = nil
                connectionCallbacks.showAlert = false
                openWindow(id: "mainView")
                triggerCloseSequence()
            } label: {
                Label(viewModel.localized("close"), systemImage: "xmark.circle.fill")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: 320)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    @ViewBuilder
    private var errorHUDOverlay: some View {
        if connectionCallbacks.showAlert {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.32))
                Text(viewModel.localized("stream_error"))
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(connectionCallbacks.errorMessage ?? viewModel.localized("unknown_error"))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button {
                    connectionCallbacks.showAlert = false
                    openWindow(id: "mainView")
                    triggerCloseSequence()
                } label: {
                    Label(viewModel.localized("close"), systemImage: "xmark.circle.fill")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .zIndex(1400)
        }
    }

    @ViewBuilder
    private var controlsHint: some View {
        if hideControls {
            VStack {
                 HStack {
                    Spacer()
                    Text(viewModel.localized("tap_reveal_controls"))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                        .padding(8)
                        .background(.black.opacity(0.3))
                        .cornerRadius(8)
                    Spacer()
                }
                .padding(.top, 40)
                Spacer()
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
    
    @ViewBuilder
        func makeRealityView(proxy: GeometryProxy3D) -> some View {
            RealityView { content, attachments in
            setupDimmerDomes(content: content)
            setupEnvironment360(content: content)
                setupRealityView(content: content, attachments: attachments)
            
           
            
            
            } update: { content, attachments in
            updateDimmerDomes(content: content)
            updateEnvironment360(content: content)
            updateRealityView(content: content, attachments: attachments, proxy: proxy)
            } attachments: {
            Attachment(id: "controls") { screenDockBar }
            Attachment(id: "controlPanel") {
                if controlState.isControlPanelVisible {
                    if isImmersive {
                        ImmersiveControlPanelView()
                            .environmentObject(viewModel)
                            .environmentObject(controlState)
                    } else {
                        VolumeControlPanelView(
                            // openWindow — pushWindow is only valid for Plain/Default WindowGroup;
                            // volumetric streaming windows trigger "PushWindowAction requires…" and can crash.
                            homeAction: { openWindow(id: "mainView") },
                            closeAction: {
                                viewModel.savedStreamConfigForResume = streamConfig
                                needsResume = false
                                hasPerformedTeardown = false
                                viewModel.streamState = .stopping
                                triggerCloseSequence()
                            },
                            toggleKeyboardAction: { showVirtualKeyboard.toggle() },
                            isKeyboardActive: showVirtualKeyboard,
                            depthOffset: $volumeDepthOffset,
                            height: $volumeHeight,
                            zLimits: volumeZLimits,
                            yLimits: volumeYLimits,
                            needsHdr: needsHdr
                        )
                            .environmentObject(viewModel)
                            .environmentObject(controlState)
                    }
                }
            }
            Attachment(id: "inputOverlay") { inputCaptureAttachment }
            if showInlineHint {
                Attachment(id: "presetPopup") {
                    CenterHintOverlay(text: hintOverlayText, icon: hintOverlayIcon)
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .center)))
                }
            }
            Attachment(id: "dimPicker") { dimmingPickerAttachment }
            Attachment(id: "stats") { statsAttachment }
            if showVirtualKeyboard {
                Attachment(id: "keyboardTextField") {
                    TextField("", text: $keyboardInput)
                        .focused($isKeyboardFocused)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .frame(width: 180)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .opacity(0.7)
                        )
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                isKeyboardFocused = true
                            }
                        }
                        .onSubmit {
                            print("[Keyboard] Submit detected, sending Return key and closing keyboard")
                            LiSendKeyboardEvent(0x0D, 0x03, 0)
                            usleep(50 * 1000)
                            LiSendKeyboardEvent(0x0D, 0x04, 0)
                            showVirtualKeyboard = false
                            isKeyboardFocused = false
                            keyboardInput = ""
                            previousKeyboardInput = ""
                        }
                        .onChange(of: keyboardInput) { _, newValue in
                            handleKeyboardInput(newValue)
                        }
                        .onChange(of: isKeyboardFocused) { _, newValue in
                            if !newValue && showVirtualKeyboard {
                                print("[Keyboard] Focus lost, closing keyboard")
                                showVirtualKeyboard = false
                                keyboardInput = ""
                                previousKeyboardInput = ""
                            }
                        }
                }
            }
            if isImmersive && isReconnecting {
                Attachment(id: "reconnectingOverlay") {
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(1.0)
                            .tint(.white)
                        Text(viewModel.localized("reconnecting"))
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Text(String(format: viewModel.localized("reconnect_attempt"), reconnectAttemptCount, maxReconnectAttempts))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(16)
                    .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            if isImmersive && (lastStreamErrorMessage != nil || connectionCallbacks.showAlert) {
                Attachment(id: "immersiveErrorOverlay") {
                    immersiveErrorFloatingOverlay()
                }
            }
        }
        .upperLimbVisibility(shouldHideHands ? .hidden : .automatic)
        // Unified drag handles both Screen Move and Gaze Drag to prevent conflicts
        // Magnify and drag run simultaneously to allow pinch-to-zoom
        .gesture(magnifyGesture.simultaneously(with: unifiedDragGesture))
        // NOTE: gazeTapGesture disabled - DragGesture(minimumDistance: 0) handles all pinch
        // interactions including quick taps. Having both gestures causes conflicts.
        // .gesture(gazeTapGesture, isEnabled: inputMode == .gazeControl)
        .onTapGesture {
            guard viewModel.activelyStreaming && !showMenuPanel else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                hideControls = false
                controlsHighlighted = true
            }
            startHighlightTimer()
            if self.spatialAudioMode {
                AudioHelpers.fixAudioForSurroundForCurrentWindow()
            } else {
                AudioHelpers.fixAudioForDirectStereo()
            }
        }
    }

    // MARK: - Scene Setup & Teardown

    private func setupScene() {
        if !viewModel.activelyStreaming {
            // Scene appeared while not streaming — zombie window (e.g. restored by
            // visionOS after a reboot with a stale StreamConfiguration value).
            // Redirect to main menu and close self.
            openWindow(id: "mainView")
            Task { @MainActor in
                viewModel.userDidRequestDisconnect()
                await dismissImmersiveSpace()
                if !isImmersive {
                    dismissWindow(id: "realitykitStreamingWindow")
                }
            }
            return
        }

        // Non-state prep: safe to do synchronously
        print("[StreamView] Re-initializing ControllerSupport with slotOffset: \(streamConfig.controllerSlotOffset)")
        self.controllerSupport = ControllerSupport(config: streamConfig, delegate: DummyControllerDelegate())
        connectionCallbacks.controllerSupport = self.controllerSupport
        connectionCallbacks.showAlert = false
        gazeController.streamConfig = streamConfig

        // Kick off stream (internally defers heavy work with asyncAfter)
        startStreamIfNeeded()

        // Dismiss windows synchronously (no @State involved)
        dismissWindow(id: "mainView")
        dismissWindow(id: "dummy")

        // Defer all @State mutations to next runloop to avoid
        // "Modifying state during view update" — onAppear fires mid-update-pass.
        DispatchQueue.main.async { [self] in
            hasPerformedTeardown = false
            renderGateOpen = true
            lastStreamErrorMessage = nil

            isMenuOpen = false

            viewModel.streamSettings.statsOverlay = false
            statsTimer?.invalidate()
            statsTimer = nil
            statsOverlayText = ""

            dimLevel = 0
            viewModel.streamSettings.dimPassthrough = false

            self.targetScale = self.screenScale

            // Initialize input mode from user preference
            let defaultMode = UserDefaults.standard.integer(forKey: "immersive.defaultControlMode")
            inputMode = InputMode(rawValue: defaultMode) ?? .gazeControl
            print("[StreamView] Initialized input mode from settings: \(inputMode.displayName)")

            spatialAudioMode = true

            if needsHdr {
                hdrParams.mode = 1
                safeHDRSettings.value = HDRParams(
                    boost: 1.0,
                    contrast: 1.0,
                    saturation: 1.0,
                    brightness: 0.0,
                    pqExposure: viewModel.streamSettings.pqExposure,
                    mode: 1
                )
                ensureHDRTextureMatchesSetting()
            }

            if let sceneID = UIApplication.shared.connectedScenes.first?.session.persistentIdentifier {
                self.immersiveSpaceSceneID = sceneID
            }

            restoreSavedTransform()

            hideTimer?.invalidate()
            hideTimer = nil
            hideControls = false

            openedMainAfterDisconnect = false

            applyDefaultDisplayParams()

            // Initialize slider curvature from saved settings
            sliderCurvature = viewModel.streamSettings.realitykitRendererCurvature

            // Second pass — needs first-pass @State to have settled
            setupControlStateCallbacks()

            // Sync rendering state → controlState (so sliders reflect actual values)
            controlState.immersiveScale = screenScale
            controlState.immersivePosition = screenPosition
            controlState.immersionAmount = immersionAmount
            controlState.dimLevel = dimLevel
            controlState.tiltAngle = tiltAngle

            // Restore persisted environment state from shared control state (immersive only).
            // Volume window must never load studio - it has no studio, only passthrough.
            let restoredEnvState: EnvironmentStateType
            if isImmersive {
                restoredEnvState = controlState.selectedEnvironmentState
                selectedEnvironmentState = restoredEnvState
                immersiveEnvironment.isSemiImmersionEnabled = controlState.isSemiImmersionEnabled
                controlState.canPinToStage = immersiveEnvironment.dockingAnchor != nil && restoredEnvState != .none
                // Reset pin state when immersive loads - screen starts unpinned (crown leave/return or fresh session)
                controlState.isPinnedToStage = false
                controlState.isPinningTransitioning = false
            } else {
                restoredEnvState = .none
                selectedEnvironmentState = .none
                immersiveEnvironment.requestEnvironmentState(.none)
                immersiveEnvironment.isSemiImmersionEnabled = false
                controlState.canPinToStage = false
            }

            if restoredEnvState != .none {
                immersiveEnvironment.requestEnvironmentState(restoredEnvState)
                updateImmersionStyle(
                    state: restoredEnvState,
                    semi: immersiveEnvironment.isSemiImmersionEnabled,
                    shouldLock: false
                )
            } else {
                immersiveEnvironment.requestEnvironmentState(.none)
                updateImmersionStyle(state: .none, semi: false, shouldLock: false)
            }
        }
        // Keep previous environment selections across stream restarts (immersive only).
        // Resetting these to `.none`/`0` can leave the dome active but untextured (black)
        // until the user manually toggles environment again.
    }
    
    private func setupControlStateCallbacks() {
        controlState.needsHdr = needsHdr
        controlState.controllerSupport = controllerSupport
        
        controlState.homeAction = { [self] in
            // In immersive mode, "Home" should fully stop stream first.
            // IMPORTANT: do NOT set activelyStreaming=false before dismissImmersiveSpace.
            // Setting it early causes the body to switch to streamStoppedOverlay (with its
            // own RealityView scaffold), removing the main RealityView while the VT decoder
            // may still be writing to its Metal textures — a reliable EXC_BAD_ACCESS crash.
            needsResume = false
            hasPerformedTeardown = false
            viewModel.streamState = .stopping
            performCompleteTeardown()
            viewModel.shouldCloseStream = false
            Task {
                await dismissImmersiveSpace()
                // MoonlightVisionApp.onDisappear fires when the space is dismissed and
                // unconditionally saves streamConfig → savedStreamConfigForResume. Clear it
                // here (after onDisappear) so "return to stream" doesn't appear after an
                // explicit home action.
                viewModel.savedStreamConfigForResume = nil
                // Switch the body AFTER the space is gone; the main RealityView has already
                // been removed by the system-level space dismissal at this point.
                viewModel.activelyStreaming = false
                // Open main menu after immersive teardown — never pushWindow on volumetric scenes.
                openWindow(id: "mainView")
            }
        }
        controlState.closeAction = { [self] in
            if streamConfig != nil { viewModel.savedStreamConfigForResume = streamConfig }
            needsResume = false
            hasPerformedTeardown = false
            viewModel.streamState = .stopping
            performCompleteTeardown()
        }
        
        controlState.toggleKeyboardAction = { [self] in
            showVirtualKeyboard.toggle()
            controlState.isKeyboardActive = showVirtualKeyboard
            let key = showVirtualKeyboard ? "show_keyboard" : "hide_keyboard"
            showInlineHint(text: viewModel.localized(key), icon: "keyboard")
        }
        
        controlState.toggleDimmingPickerAction = { [self] in
            showDimmingPicker.toggle()
        }
        
        immersiveEnvironment.onLoadComplete = { [self] in
            if immersiveEnvironment.activeState != .none && immersiveEnvironment.dockingAnchor != nil {
                controlState.canPinToStage = true
            }
        }
        
        controlState.onEnvironmentChange = { [self] newState in
            selectedEnvironmentState = newState
            controlState.canPinToStage = immersiveEnvironment.dockingAnchor != nil && newState != .none
            
            if newState != .none && !immersiveEnvironment.isLoaded && !immersiveEnvironment.isLoading {
                immersiveEnvironment.loadEnvironment()
            }
            immersiveEnvironment.requestEnvironmentState(newState)
            let needsLock = (selectedEnvironmentState == .none || newState == .none)
            updateImmersionStyle(state: newState, semi: immersiveEnvironment.isSemiImmersionEnabled, shouldLock: needsLock)
            if newState == .none && isPinnedToStage {
                unpinStreamFromStage(animated: false)
            }
        }
        
        controlState.onSemiImmersionToggle = { [self] enabled in
            immersiveEnvironment.isSemiImmersionEnabled = enabled
            controlState.isSemiImmersionEnabled = enabled
            updateImmersionStyle(state: immersiveEnvironment.activeState, semi: enabled, shouldLock: true)
        }
        
        controlState.onPinToggle = { [self] in
            if isPinnedToStage {
                unpinStreamFromStage(animated: true)
            } else {
                pinStreamToStage()
            }
        }
        
        controlState.saveSettings = { [self] in
                syncLocalStateToControlState()
            saveRealityKitSettings()
        }
        
        controlState.toggle3DMode = { [self] in
            if videoMode == .sideBySide3D {
                videoMode = .standard2D
            } else {
                videoMode = .sideBySide3D
            }
            updateScreenMaterial()
            controlState.videoMode = videoMode
        }
        
        controlState.onOverlayHint = nil
    }
    
    private func syncLocalStateToControlState() {
        controlState.immersiveScale = screenScale
        controlState.immersivePosition = screenPosition
        controlState.immersionAmount = immersionAmount
        controlState.isPinnedToStage = isPinnedToStage
    }
    
    private func updateImmersionStyle(state: EnvironmentStateType, semi: Bool, shouldLock: Bool = true) {
        if shouldLock { isUpdatingImmersion = true }
        
        Task { @MainActor in
            if state == .none {
                viewModel.currentImmersionStyle = .mixed
                ImmersionStyleManager.shared.currentStyle = .mixed
            } else {
                if semi {
                    viewModel.currentImmersionStyle = .progressive
                    ImmersionStyleManager.shared.currentStyle = .progressive
                } else {
                    viewModel.currentImmersionStyle = .full
                    ImmersionStyleManager.shared.currentStyle = .full
                }
            }
            
            if shouldLock {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                isUpdatingImmersion = false
            }
        }
    }
    
    private func teardownScene() {
        statsTimer?.invalidate()
        statsTimer = nil
        stopMoonlightCycle()
        stopReactiveLerp()
        
        if !hasPerformedTeardown {
            performCompleteTeardown()
        }
        saveCurrentTransform()
    }
    
    // MARK: - onChange Handlers

    private func handleStatsOverlay(oldValue: Bool, newValue: Bool) {
        if newValue { startStatsTimer() } else { statsTimer?.invalidate(); statsTimer = nil; statsOverlayText = "" }
    }

    private func handleActiveStreaming(oldValue: Bool, newValue: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            showMenuPanel = false
        }
        if newValue {
            ensureStreamStartedIfNeeded()
            dismissWindow(id: "mainView")
        }
    }

    private func handleStreamState(oldValue: StreamLifecycleState, newValue: StreamLifecycleState) {
        if newValue == .starting {
            ensureStreamStartedIfNeeded()
        } else if(newValue == .idle) {
            self.shouldClose = false
        }
    }
    
    // MARK: - Gestures
    
    /// Unified drag gesture to prevent conflict between Screen Move and Gaze Control
    /// Both modes use drag, so we combine them into a single gesture that routes based on inputMode
    var unifiedDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)  // 0 for instant gaze response
            .targetedToEntity(screen)
            .onChanged { value in
                // DISPATCHER: Route logic based on active mode
                switch inputMode {
                case .screenMove:
                    if controlState.isInteractive { return }  // Locked: ignore drag
                    // --- SCREEN MOVE LOGIC ---
                    hideTimer?.invalidate()
                    if startDragPosition == nil { startDragPosition = screenPosition }
                    let translation = value.convert(value.translation3D, from: .local, to: .scene)
                    var proposed = startDragPosition! + simd_float3(translation.x, translation.y, translation.z)
                    proposed.x = min(max(proposed.x, -allowedLateralMax), allowedLateralMax)
                    screenPosition = proposed
                    lastDragTime = CACurrentMediaTime()
                    
                case .gazeControl:
                    // --- GAZE CONTROL LOGIC ---
                    // Check if using Touch mode (hand drag) or Gaze mode (eye tracking)
                    if viewModel.streamSettings.gazeTouchMode {
                        // TOUCH MODE: Relative mouse movement (trackpad style)
                        let worldPos = value.convert(value.location3D, from: .local, to: .scene)
                        if !gazeController.pinchActive {
                            gazeController.onTouchDragBegan(at: worldPos)
                        } else {
                            gazeController.onTouchDragChanged(at: worldPos)
                        }
                    } else {
                        // GAZE MODE: Eye tracking (current implementation)
                        let uv = hitToUV(value)
                        if !gazeController.pinchActive {
                            gazeController.onPinchBegan(at: uv)
                        } else {
                            gazeController.onPinchChanged(at: uv)
                        }
                    }
                    
                case .controller:
                    break  // Let input fall through to InputCaptureView
                }
            }
            .onEnded { _ in
                // CLEANUP DISPATCHER
                switch inputMode {
                case .screenMove:
                    startDragPosition = nil
                    controlsHighlighted = false
                    startHighlightTimer()
                    // Sync position back to controlState for slider display
                    controlState.immersivePosition = screenPosition
                    
                case .gazeControl:
                    // Always cleanup gaze state
                    if gazeController.pinchActive {
                        if viewModel.streamSettings.gazeTouchMode {
                            gazeController.onTouchDragEnded()
                        } else {
                            gazeController.onPinchEnded()
                        }
                    }
                    
                case .controller:
                    break
                }
            }
    }
    
    var magnifyGesture: some Gesture {
        MagnifyGesture()
            .targetedToEntity(screen)
            .onChanged { value in
                hideTimer?.invalidate()
                if gestureInitialScale == nil {
                    gestureInitialScale = screenScale
                    showScaleHUD = true
                }
                let base = gestureInitialScale ?? screenScale
                var proposed = base * Float(value.magnification)
                proposed = min(max(proposed, 0.2), allowedScaleMax)
                targetScale = proposed
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.85)) {
                    screenScale = targetScale
                }

                scaleHUDFadeTimer?.invalidate()
                scaleHUDFadeTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        showScaleHUD = false
                    }
                }
            }
            .onEnded { _ in
                gestureInitialScale = nil
                scaleHUDFadeTimer?.invalidate()
                scaleHUDFadeTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        showScaleHUD = false
                    }
                }
                controlsHighlighted = false
                startHighlightTimer()
                // Sync scale back to controlState for slider display
                controlState.immersiveScale = screenScale
            }
    }
    
    // MARK: - Gaze Control Gestures
    
    var gazeTapGesture: some Gesture {
        SpatialTapGesture()
            .targetedToEntity(screen)
            .onEnded { value in
                guard inputMode == .gazeControl else {
                    print("[Gaze] Tap ignored - not in gaze control mode (current: \(inputMode))")
                    return
                }
                let uv = hitToUV(value)
                print("[Gaze] Tap detected at UV: \(uv)")
                gazeController.onPinchBegan(at: uv)
                gazeController.onPinchEnded()
            }
    }
    
   
   
    
    // MARK: - "World Space" Gaze Calculation
    // Bypasses local coordinate glitches by calculating vector projection in absolute room space.
    
    private func hitToUV(_ value: EntityTargetValue<SpatialTapGesture.Value>) -> SIMD2<Float> {
        // 1. Get Touch in World Space
        // We bypass local coordinate confusion entirely.
        let touchWorld = value.convert(value.location3D, from: .local, to: .scene)
        
        return calculateUV(touchWorld: touchWorld)
    }

    private func hitToUV(_ value: EntityTargetValue<DragGesture.Value>) -> SIMD2<Float> {
        // 1. Get Touch in World Space
        // We bypass local coordinate confusion entirely.
        let touchWorld = value.convert(value.location3D, from: .local, to: .scene)
        
        return calculateUV(touchWorld: touchWorld)
    }
    
    private func calculateUV(touchWorld: SIMD3<Float>) -> SIMD2<Float> {
        // 1. GET SCREEN BASIS VECTORS (Orientation)
        // This handles rotation/tilt.
        let screenTransform = screen.transformMatrix(relativeTo: nil)
        let rightDir = simd_normalize(SIMD3<Float>(screenTransform.columns.0.x, screenTransform.columns.0.y, screenTransform.columns.0.z))
        let upDir    = simd_normalize(SIMD3<Float>(screenTransform.columns.1.x, screenTransform.columns.1.y, screenTransform.columns.1.z))
        let center   = SIMD3<Float>(screenTransform.columns.3.x, screenTransform.columns.3.y, screenTransform.columns.3.z)
        
        // 2. PROJECT TOUCH (Get Distance in Meters)
        let delta = touchWorld - center
        let meterX = simd_dot(delta, rightDir) // e.g., 4.0 meters
        let meterY = simd_dot(delta, upDir)
        
       
        let globalScale = screen.scale(relativeTo: nil).x
        let safeScale = globalScale > 0 ? globalScale : 1.0
        
    
        let baseWidth = CURVED_MAX_WIDTH_METERS // 2.0
        let physicalWidth = baseWidth * safeScale
        let physicalHeight = physicalWidth * screenAspect
        
       
        let curveMagnitude = effectiveCurvature
        let maxAngle = CURVED_MAX_ANGLE
        let currentAngle = maxAngle * max(0.0, min(curveMagnitude, 2.0))
        
        var u: Float = 0.5
        
      
        if currentAngle < 0.001 {
            // Flat Mode
            u = (meterX / physicalWidth) + 0.5
                        } else {
           
            let scaledRadius = physicalWidth / currentAngle
            let maxTheoreticalX = scaledRadius * sin(currentAngle / 2.0)
            
            let clampedX = max(-maxTheoreticalX, min(maxTheoreticalX, meterX))
            let theta = asin(clampedX / scaledRadius)
            
            u = (theta / currentAngle) + 0.5
        }

      
        let v = 0.5 - (meterY / physicalHeight) - GAZE_VERTICAL_OFFSET
        
        
        let offsetX = Float(viewModel.streamSettings.gazeCursorOffsetX) / Float(streamConfig.width)
        let offsetY = -Float(viewModel.streamSettings.gazeCursorOffsetY) / Float(streamConfig.height)
        
        let calibratedU = u + offsetX
        let calibratedV = v + offsetY
        
        return SIMD2<Float>(
            max(0, min(1, calibratedU)),
            max(0, min(1, calibratedV))
        )
    }

    @State private var headAnchor: AnchorEntity?
    private let lastHeadWorldPosStorage = SIMD3Storage()
    @State private var lastDragTime: CFTimeInterval = 0

    private let allowedLateralMax: Float = 3.0
    
    // MARK: - RealityView Attachments

    @ViewBuilder
    private var inputCaptureAttachment: some View {
        if let support = controllerSupport {
            InputCaptureView(
                controllerSupport: support,
                showKeyboard: $showVirtualKeyboard,
                isControllerMode: inputMode == .controller,
                curvature: effectiveCurvature,
                streamConfig: streamConfig,
                headStorage: headStorage
            )
            .frame(width: 1920, height: 1920 / CGFloat(screenAspect))
            .opacity(0.01)
            // Input Mode handling:
            // - Controller mode: allowsHitTesting(true) → Controller works
            // - Other modes: allowsHitTesting(false) → RealityKit gestures work
            .allowsHitTesting(showVirtualKeyboard || inputMode == .controller)
        }
    }

    @ViewBuilder
    private var dimmingPickerAttachment: some View {
        if showDimmingPicker {
            DimmingPickerView(
                dimLevel: Binding(
                    get: { dimLevel },
                    set: { val in
                        dimLevel = val
                        viewModel.streamSettings.dimPassthrough = (val != 0)
                        UserDefaults.standard.set(val, forKey: "ambient.dimming.level")
                        
                        // Don't enable dimmer if environment is active - let environment binding handle it after fade
                        if environmentDome?.isEnabled != true {
                            updateDimmerDomesState()
                        }
                        
                        // Handle Reactive modes (V1, V2, and V3)
                        if val == 2 || val == 10 || val == 13 {
                            stopMoonlightCycle()
                            startReactiveLerp()
                } else {
                            stopMoonlightCycle()
                            stopReactiveLerp()
                        }
                    }
                ),
                isPresented: $showDimmingPicker,
                environmentSphereLevel: Binding(
                    get: { environmentSphereLevel },
                    set: { newValue in
                        environmentSphereLevel = newValue
                        
                        // If disabling environment while dimming is active, wait for fade before enabling dimmer
                        if newValue == 0 && dimLevel != 0 {
                            updateEnvironmentState()
                            
                            // Wait for environment fade to complete (0.5s + small buffer)
                            Task {
                                try? await Task.sleep(for: .milliseconds(600))
                                await MainActor.run {
                                    updateDimmerDomesState()
                    }
                }
            } else {
                            updateEnvironmentState()
                        }
                    }
                ),
                envPresetLevel: Binding(
                    get: { envPresetLevel },
                    set: { newValue in
                        envPresetLevel = newValue
                        updateEnvPresetState()
                    }
                )
            )
            .environmentObject(viewModel)
        } else {
            Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
        }
    }

    private func handleKeyboardInput(_ newValue: String) {
        let oldValue = previousKeyboardInput
        
        if newValue.count > oldValue.count {
            // Character(s) added - send the new characters
            let newChars = String(newValue.suffix(newValue.count - oldValue.count))
            for char in newChars {
                let text = String(char)
                let cString = text.cString(using: .utf8)
                cString?.withUnsafeBufferPointer { ptr in
                    if let base = ptr.baseAddress {
                        LiSendUtf8TextEvent(base, UInt32(text.utf8.count))
                    }
                }
            }
        } else if newValue.count < oldValue.count {
            // Character(s) removed - send backspace for each removed character
            let removedCount = oldValue.count - newValue.count
            for _ in 0..<removedCount {
                LiSendKeyboardEvent(0x08, 0x03, 0) // Backspace Down
                usleep(50 * 1000)
                LiSendKeyboardEvent(0x08, 0x04, 0) // Backspace Up
            }
        }
        
        // Update previous value for next comparison
        previousKeyboardInput = newValue
    }

    @ViewBuilder
    private var statsAttachment: some View {
        VStack(spacing: 6) {
            Text(statsOverlayText.isEmpty ? "Collecting stats..." : statsOverlayText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(10)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .frame(width: 420)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(viewModel.streamSettings.statsOverlay ? 1 : 0)
        .allowsHitTesting(false)
    }

    // MARK: - Screen Dock Bar (positioned above screen)
    
    @ViewBuilder
    private var screenDockBar: some View {
        HStack(spacing: 16) {
            // Control Panel toggle
            if controlState.isControlPanelVisible {
                Button(action: { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { controlState.isControlPanelVisible = false } }) {
                    Label(viewModel.localized("hide_panel"), systemImage: "rectangle.badge.minus")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { controlState.isControlPanelVisible = true } }) {
                    Label(viewModel.localized("control_panel"), systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
            }
            
            // Immersion mode toggle (only shown when in virtual environment)
            if selectedEnvironmentState != .none {
                Button(action: {
                    controlState.onSemiImmersionToggle?(!controlState.isSemiImmersionEnabled)
                }) {
                    Label(
                        controlState.isSemiImmersionEnabled ? viewModel.localized("semi_short") : viewModel.localized("full_short"),
                        systemImage: controlState.isSemiImmersionEnabled ? "circle.lefthalf.filled" : "circle.fill"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isUpdatingImmersion)
            }
            
            // Keyboard toggle (next to stats)
            Button(action: {
                if inputMode == .controller && !showVirtualKeyboard {
                    inputMode = .screenMove
                    gazeController.cleanup()
                    UserDefaults.standard.set(inputMode.rawValue, forKey: "immersiveInputMode")
                }
                showVirtualKeyboard.toggle()
                controlState.isKeyboardActive = showVirtualKeyboard
                let key = showVirtualKeyboard ? "show_keyboard" : "hide_keyboard"
                showInlineHint(text: viewModel.localized(key), icon: "keyboard")
            }) {
                Image(systemName: showVirtualKeyboard ? "keyboard.fill" : "keyboard")
            }
            .buttonStyle(.bordered)
            
            // Input mode cycle
            Button(action: { cycleInputMode() }) {
                Image(systemName: inputMode == .gazeControl ? "eye" : inputMode == .controller ? "gamecontroller" : "arrow.up.and.down.and.arrow.left.and.right")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .glassBackgroundEffect()
        // Match backup dock behavior: fully visible when gazed, dim when not focused.
        .hoverEffect { effect, isActive, _ in
            effect.opacity(isActive ? 1.0 : 0.2)
        }
        .allowsHitTesting(true)
    }
    
    private func cycleInputMode() {
        gazeController.cleanup()
        inputMode = inputMode.next()
        
        UserDefaults.standard.set(inputMode.rawValue, forKey: "immersiveInputMode")
        let text = (inputMode == .gazeControl && viewModel.streamSettings.gazeTouchMode) ? viewModel.localized("input_mode_touch") : viewModel.localized(inputMode.localizedKey)
        let icon: String
        if inputMode == .gazeControl && viewModel.streamSettings.gazeTouchMode { icon = "hand.point.up.left.fill" }
        else if inputMode == .gazeControl { icon = "eye" }
        else if inputMode == .controller { icon = "gamecontroller" }
        else { icon = "arrow.up.and.down.and.arrow.left.and.right" }
        showInlineHint(text: text, icon: icon)
        updateScreenInteractivity()
        startHighlightTimer()
        startHideTimer()
    }
    
    private func showInlineHint(text: String, icon: String) {
        hintOverlayText = text
        hintOverlayIcon = icon
        showInlineHint = true
        hintOverlayTimer?.invalidate()
        hintOverlayTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.15)) {
                showInlineHint = false
            }
        }
    }
    
    private var shouldHideHands: Bool {
        environmentSphereLevel > 0 && viewModel.streamSettings.hideHandsIn360Environment
    }
    
    // Volume ornament control panel removed - volume mode now uses VolumeControlPanelView on-screen
    // private var volumeControlsView: ... (StandardControlPanelView was here)

    private func refreshAfterResume() {
        LiRequestIdrFrame()
        rebindScreenMaterial()
    }
    
    private func rebindScreenMaterial() {
        if videoMode == .sideBySide3D {
            if var mat = surfaceMaterial {
                try? mat.setParameter(name: "texture", value: .textureResource(self.texture))
                surfaceMaterial = mat
                screen.model?.materials = [mat]
            } else {
                screen.model?.materials = [makeVideoUnlitMaterial(texture)]
            }
        } else {
            screen.model?.materials = [makeVideoUnlitMaterial(self.texture)]
        }
    }

    private func makeVideoUnlitMaterial(_ texture: TextureResource) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(texture: .init(texture))
        return material
    }

    // MARK: - HDR & Material

    private func applyDefaultDisplayParams() {
        if viewModel.streamSettings.enableHdr {
            hdrParams.mode = 1
            updateHDRParams()
        } else {
            var params = safeHDRSettings.value
            params.boost = 1.00
            params.saturation = 1.00
            params.contrast = 1.00
            params.brightness = 0.00
            params.pqExposure = 1.00
            params.mode = 0
            safeHDRSettings.value = params
        }
    }

    private func updateHDRParams() {
        let isHDRPath = viewModel.streamSettings.enableHdr
        let params = HDRParams(
            // Avoid applying HDR boost curve to SDR streams; this causes washed-out/overexposed output.
            boost: isHDRPath ? viewModel.streamSettings.brightness : 1.0,
            // Keep SDR rendering neutral; only apply gamma/saturation tuning on HDR path.
            contrast: isHDRPath ? viewModel.streamSettings.gamma : 1.0,
            saturation: isHDRPath ? viewModel.streamSettings.saturation : 1.0,
            brightness: 0.0,
            pqExposure: isHDRPath ? viewModel.streamSettings.pqExposure : 1.0,
            mode: isHDRPath ? max(hdrParams.mode, 1) : 0
        )
        safeHDRSettings.value = params
    }
    
    private func updateScreenMaterial() {
        if videoMode == .sideBySide3D {
            if var mat = surfaceMaterial {
                try? mat.setParameter(name: "texture", value: .textureResource(self.texture))
                surfaceMaterial = mat
                screen.model?.materials = [mat]
            } else {
                screen.model?.materials = [makeVideoUnlitMaterial(texture)]
            }
        } else {
            screen.model?.materials = [makeVideoUnlitMaterial(self.texture)]
        }
    }
    
    private func setupMaterial() async {
        if surfaceMaterial == nil {
            do {
                var material = try await ShaderGraphMaterial(named: "/Root/SBSMaterial", from: "SBSMaterial.usda")
                try material.setParameter(name: "texture", value: .textureResource(self.texture))
                self.surfaceMaterial = material
            } catch {
                self.surfaceMaterial = nil
            }
        }
    }

    /// Convert UV coordinates (0-1) to 3D position on the curved mesh (in mesh-local space)
    private func uvTo3DPosition(uv: SIMD2<Float>) -> SIMD3<Float> {
        let width = CURVED_MAX_WIDTH_METERS
        let height = width * screenAspect
        let curveMagnitude = effectiveCurvature
        let maxCurveAngle: Float = CURVED_MAX_ANGLE
        let currentAngle = maxCurveAngle * max(0.0, min(curveMagnitude, 2.0))
        
        // Convert UV to mesh coordinates
        // U: 0 = left edge, 1 = right edge
        // V: 0 = top edge, 1 = bottom edge
        
        var x: Float
        var z: Float
        
        if currentAngle < 0.0001 {
            // Flat mode
            x = (uv.x - 0.5) * width
            z = 0
                    } else {
            // Curved mode
            let radius = width / currentAngle
            let theta = (uv.x - 0.5) * currentAngle
            
            x = radius * sin(theta)
            z = radius * (1.0 - cos(theta))
        }
        
        // Y is straightforward (flipped because V=0 is top)
        let y = (0.5 - uv.y) * height
        
        return SIMD3(x, y, z)
    }

    // MARK: - RealityView Setup

    func setupRealityView(content: RealityViewContent, attachments: RealityViewAttachments) {
        // Safe mesh generation with fallback
        let mesh: MeshResource
        do {
            mesh = try generateCurvedRoundedPlane(
                width: CURVED_MAX_WIDTH_METERS,
                aspectRatio: screenAspect,
                resolution: (512, 512),
                curveMagnitude: effectiveCurvature,
                cornerRadiusFraction: cornerRadiusFraction
            )
        } catch {
            print("⚠️ Failed to generate curved mesh: \(error). Using flat fallback.")
            mesh = .generatePlane(width: CURVED_MAX_WIDTH_METERS, height: CURVED_MAX_WIDTH_METERS * screenAspect)
        }
        
        if videoMode == .standard2D {
            screen = ModelEntity(mesh: mesh, materials: [makeVideoUnlitMaterial(texture)])
        } else {
            let material = makeVideoUnlitMaterial(texture)
            screen = ModelEntity(mesh: mesh, materials: [material])
        }

        // Generate curved collision mesh that matches visual geometry
        let collisionMesh: MeshResource
        do {
            collisionMesh = try generateCurvedRoundedPlane(
                width: CURVED_MAX_WIDTH_METERS,
                aspectRatio: screenAspect,
                resolution: (256, 256),
                curveMagnitude: effectiveCurvature,
                cornerRadiusFraction: 0
            )
        } catch {
            print("⚠️ Failed to generate collision mesh: \(error). Using flat fallback.")
            collisionMesh = .generatePlane(width: CURVED_MAX_WIDTH_METERS, height: CURVED_MAX_WIDTH_METERS * screenAspect)
        }
            
            Task {
            if let collisionShape = try? await ShapeResource.generateStaticMesh(from: collisionMesh) {
                await MainActor.run {
                    screen.components.set(CollisionComponent(
                        shapes: [collisionShape],
                        filter: CollisionFilter(
                            group: .screenEntity,
                            mask: .all
                        )
                    ))
                }
            }
        }
        
        screen.components.set(InputTargetComponent(allowedInputTypes: .all))
        
        screen.position = SIMD3<Float>(0, 0, -1.5)
        
        content.add(screen)
        if screenOriginalParent == nil { screenOriginalParent = screen.parent }
        
        // blackOutSphere removed - using dimmerDome for passthrough dimming instead

        let head = AnchorEntity(.head)
        content.add(head)
        self.headAnchor = head

        if !hasInitializedPosition {
            screen.position = screenPosition
            screen.scale = [screenScale, screenScale, screenScale]
            hasInitializedPosition = true
        }
        
        if let controls = attachments.entity(for: "controls") {
            self.controlsEntity = controls
            if controls.parent !== screen { screen.addChild(controls) }
            let screenHeight = CURVED_MAX_WIDTH_METERS * screenAspect
            controls.position = [0.0 as Float, (screenHeight / 2.0) + Float(0.03), Float(0.05)]
        }
        
        // Control panel - attach to screen so it follows screen movement.
        if let panel = attachments.entity(for: "controlPanel") {
            self.controlPanelEntity = panel
            if panel.parent !== screen { screen.addChild(panel) }
            panel.position = [0.0 as Float, 0.0 as Float, Float(0.22)]
            panel.components.set(InputTargetComponent())
        }
        
        if let inputEnt = attachments.entity(for: "inputOverlay") {
            if inputEnt.parent !== screen { screen.addChild(inputEnt) }
            inputEnt.position = [0.0 as Float, 0.0 as Float, Float(0.005)]
            
            let bounds = inputEnt.visualBounds(relativeTo: screen)
            if bounds.extents.x > 0 {
                let currentScaleX = max(inputEnt.scale.x, 0.0001)
                let unscaledWidth = Float(bounds.extents.x) / currentScaleX
                let desiredLocalWidth = CURVED_MAX_WIDTH_METERS * 1.05
                let scale = desiredLocalWidth / unscaledWidth
                inputEnt.scale = [scale, scale, scale]
            }
        }

        if let statsEnt = attachments.entity(for: "stats") {
            if statsEnt.parent !== screen { screen.addChild(statsEnt) }
            if !statsScaleInitialized {
                let bounds = statsEnt.visualBounds(relativeTo: screen)
                if bounds.extents.x > 0 {
                    let currentScaleX = max(statsEnt.scale.x, 0.0001)
                    let unscaledWidth = Float(bounds.extents.x) / currentScaleX
                    let targetLocalWidth = statsCardWidthMeters
                    let scale = targetLocalWidth / unscaledWidth
                    statsEnt.scale = [scale, scale, scale]
                }
            }
            let screenHeight = CURVED_MAX_WIDTH_METERS * screenAspect
            statsEnt.position = [0.0 as Float, -(screenHeight / 2.0) - Float(0.07), Float(0.07)]
        }

        // Keyboard TextField - positioned below screen, centered
        if let keyboardEnt = attachments.entity(for: "keyboardTextField") {
            if keyboardEnt.parent !== screen { screen.addChild(keyboardEnt) }
            let screenHeight = CURVED_MAX_WIDTH_METERS * screenAspect
            
            let keyboardOffset: Float = 0.08
            keyboardEnt.position = [0.0 as Float, -(screenHeight / 2.0) - Float(keyboardOffset), Float(0.05)]

            if showVirtualKeyboard {
                let bounds = keyboardEnt.visualBounds(relativeTo: screen)
                if bounds.extents.x > 0 {
                    let currentScaleX = max(keyboardEnt.scale.x, 0.0001)
                    let unscaledWidth = Float(bounds.extents.x) / currentScaleX
                    let desiredLocalWidth: Float = 0.25
                    let scale = desiredLocalWidth / unscaledWidth
                    keyboardEnt.scale = [scale, scale, scale]
                }
        } else {
                keyboardEnt.scale = .one
            }
        }
    }

    func updateRealityView(content: RealityViewContent, attachments: RealityViewAttachments, proxy: GeometryProxy3D) {
        // Immersive Environment Management (no @Published modifications here!)
        let envRoot = immersiveEnvironment.rootEntity
        let currentEnvState = immersiveEnvironment.environmentStateHandler.activeState
        
        if let envRoot = envRoot {
            let isInScene = envRoot.parent != nil
            if currentEnvState != .none {
                if !isInScene { content.add(envRoot) }
                if !envRoot.isEnabled { envRoot.isEnabled = true }
            } else {
                if isInScene { content.remove(envRoot) }
                if envRoot.isEnabled { envRoot.isEnabled = false }
            }
        }
        
        // Passthrough dimming via immersionAmount: reuse dimmerDome when no custom environment and no dimLevel active
        if currentEnvState == .none, dimLevel == 0, immersionAmount > 0.001 {
            dimmerDome?.isEnabled = true
            dimmerDome?.components.set(OpacityComponent(opacity: immersionAmount))
        }
        
        let currentCurve = effectiveCurvature
        
        
        // Determine whether the mesh needs to be rebuilt.
        // The time-gate prevents multiple rebuilds per drag step: at 90 Hz, a 60ms gate
        // keeps rebuilds to ~15/sec max, which is plenty for smooth visual feedback.
        let now = Date()
        let timeSinceLastGen = lastMeshGenTimeBox.value.map { now.timeIntervalSince($0) } ?? .infinity
        let geometryChanged: Bool
        if let lastCurve = lastGeneratedCurveBox.value, let lastAspect = lastGeneratedAspectBox.value, let lastCorner = lastGeneratedCornerBox.value {
            geometryChanged = abs(currentCurve - lastCurve) > 0.001 || abs(screenAspect - lastAspect) > 0.001 || abs(cornerRadiusFraction - lastCorner) > 0.0001
        } else {
            geometryChanged = true
        }
        let needsMeshUpdate = geometryChanged && timeSinceLastGen >= Self.meshGenMinInterval

        if needsMeshUpdate {
            lastMeshGenTimeBox.value = now
            // Resolution note: 128×128 gives smooth curvature at any practical viewing distance
            // on Vision Pro and costs ~4× less than 512×512.  Collision mesh at 32×32 is more
            // than sufficient for hit-testing a large curved plane.
            if let mesh = try? generateCurvedRoundedPlane(
                width: CURVED_MAX_WIDTH_METERS,
                aspectRatio: screenAspect,
                resolution: (128, 128),
                curveMagnitude: currentCurve,
                cornerRadiusFraction: cornerRadiusFraction
            ) {
                if let model = screen.model {
                    try? model.mesh.replace(with: mesh.contents)
                }

                if let collisionMesh = try? generateCurvedRoundedPlane(
                    width: CURVED_MAX_WIDTH_METERS,
                    aspectRatio: screenAspect,
                    resolution: (32, 32),
                    curveMagnitude: currentCurve,
                    cornerRadiusFraction: 0
                ) {
                    Task {
                        if let collisionShape = try? await ShapeResource.generateStaticMesh(from: collisionMesh) {
                            await MainActor.run {
                                self.screen.components.set(CollisionComponent(
                                    shapes: [collisionShape],
                                    filter: CollisionFilter(
                                        group: .screenEntity,
                                        mask: .all
                                    )
                                ))
                            }
                        }
                    }

                    self.lastGeneratedCurveBox.value = currentCurve
                    self.lastGeneratedAspectBox.value = self.screenAspect
                    self.lastGeneratedCornerBox.value = self.cornerRadiusFraction
                }
            }
        }
        
        if !isImmersive {
            let volFrame = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
            let volSize = volFrame.extents
            let scaleFactor = volSize.x / 2.0
            screen.scale = [scaleFactor, scaleFactor, scaleFactor]
            let curveDepth = effectiveCurvature * CURVED_MAX_WIDTH_METERS * screenAspect * 0.15
            let zCorrection = curveDepth * scaleFactor * 0.5
            updateVolumeWindowLimits(volSize: volSize, scaleFactor: scaleFactor, curveDepth: curveDepth)
            screen.position = SIMD3<Float>(0, volumeHeight, volumeDepthOffset + zCorrection)
        } else {
            if isPinnedToStage {
                if !isPinningTransitioning {
                    if let anchor = immersiveEnvironment.dockingAnchor, screen.parent == anchor {
                        var currentTransform = screen.transform
                        currentTransform.scale = SIMD3<Float>(repeating: controlState.pinnedStageScale)
                        let forwardOffset: Float = 0.05
                        let keyboardRaise: Float = (controlState.isKeyboardActive && controlState.isPinnedToStage) ? 0.25 : 0
                        // When stats overlay is on and pinned screen scale is 5 and height >= 0.75m, raise by 0.40m
                        let statsRaise: Float = (viewModel.streamSettings.statsOverlay && controlState.isPinnedToStage
                            && controlState.pinnedStageScale >= 4.99
                            && controlState.pinnedStageHeight >= 0.75) ? 0.40 : 0
                        currentTransform.translation = SIMD3<Float>(0, forwardOffset, -(controlState.pinnedStageHeight + keyboardRaise + statsRaise))
                        screen.transform = currentTransform
                    }
                }
                } else {
                screen.scale = [screenScale, screenScale, screenScale]
                screen.position = screenPosition
            }
        }
        if !isPinnedToStage {
            let tiltRadians = tiltAngle * .pi / 180.0
            let tiltRotation = simd_quatf(angle: tiltRadians, axis: SIMD3<Float>(1, 0, 0))
            screen.transform.rotation = tiltRotation
        }
        
        if let head = headAnchor {
            let p = head.position(relativeTo: nil)
            
            let localHead = screen.convert(position: .zero, from: head)
            headStorage.positionInScreenSpace = localHead
            
            let lastPos = lastHeadWorldPosStorage.value
            let delta = simd_length(p - lastPos)
            let nearOrigin = simd_length(p) < 0.1
            let wasFar = simd_length(lastPos) > 0.25
            let notDraggingRecently = (CACurrentMediaTime() - lastDragTime) > 0.4
            lastHeadWorldPosStorage.value = p
            
            if nearOrigin && wasFar && delta > 0.25 && notDraggingRecently && !controlState.isInteractive {
                DispatchQueue.main.async { [self] in
                    withAnimation(.easeInOut(duration: 0.22)) {
                        recenterScreenToHead(head: head)
                    }
                }
            }
        }
        
        // Attachment layout: recompute when aspect changes OR when a new attachment entity gets attached.
        let hasNewAttachmentEntity =
            (attachments.entity(for: "controlPanel")?.parent !== screen) ||
            (attachments.entity(for: "inputOverlay")?.parent !== screen) ||
            (attachments.entity(for: "dimPicker")?.parent !== screen) ||
            (attachments.entity(for: "presetPopup")?.parent !== screen) ||
            (attachments.entity(for: "keyboardTextField")?.parent !== screen) ||
            (attachments.entity(for: "reconnectingOverlay")?.parent !== screen) ||
            (attachments.entity(for: "immersiveErrorOverlay")?.parent !== screen)
        let needsAttachmentLayout =
            abs(attachmentLayoutAspectBox.value - screenAspect) > 0.001 || hasNewAttachmentEntity
        
        if needsAttachmentLayout {
            layoutAttachments(attachments: attachments)
            attachmentLayoutAspectBox.value = screenAspect
        }
        
        // Lightweight per-frame: only update position-sensitive attachments
        let screenHeight = CURVED_MAX_WIDTH_METERS * screenAspect
        if let statsEnt = attachments.entity(for: "stats") {
            if statsEnt.parent !== screen { screen.addChild(statsEnt) }
            statsEnt.position = [0.0 as Float, -(screenHeight / 2.0) - Float(0.07), Float(0.07)]
        }
        if let keyboardEnt = attachments.entity(for: "keyboardTextField") {
            if keyboardEnt.parent !== screen { screen.addChild(keyboardEnt) }
            let keyboardOffset: Float = 0.08
            keyboardEnt.position = [0.0 as Float, -(screenHeight / 2.0) - Float(keyboardOffset), Float(0.05)]
        }
        if let panelEnt = attachments.entity(for: "controlPanel") {
            if panelEnt.parent !== screen { screen.addChild(panelEnt) }
            panelEnt.position = [0.0 as Float, 0.0 as Float, Float(0.22)]
        }
        if let reconnectEnt = attachments.entity(for: "reconnectingOverlay") {
            if reconnectEnt.parent !== screen { screen.addChild(reconnectEnt) }
            reconnectEnt.position = [0.0 as Float, 0.0 as Float, Float(0.4)]
        }
        if let errorEnt = attachments.entity(for: "immersiveErrorOverlay") {
            if errorEnt.parent !== screen { screen.addChild(errorEnt) }
            errorEnt.position = [0.0 as Float, 0.0 as Float, Float(0.45)]
        }
    }

    // MARK: - Stream Management

    private func ensureStreamStartedIfNeeded() {
        startStreamIfNeeded()
    }
    
    private func updateVolumeWindowLimits(volSize: SIMD3<Float>, scaleFactor: Float, curveDepth: Float) {
        let screenHalfHeight = (CURVED_MAX_WIDTH_METERS * screenAspect * scaleFactor) / 2
        let volHalfHeight = volSize.y / 2
        let safePadding: Float = 0.05
        let maxY = max(0, volHalfHeight - screenHalfHeight - safePadding)
        let newYLimits: ClosedRange<Float> = -maxY...maxY
        let volHalfDepth = volSize.z / 2
        let maxZ = volHalfDepth - safePadding
        let scaledCurveDepth = curveDepth * scaleFactor
        let minZ = -volHalfDepth + scaledCurveDepth + safePadding
        let safeMaxZ = max(minZ, maxZ)
        let newZLimits: ClosedRange<Float> = minZ...safeMaxZ
        // Use epsilon comparison to avoid @State writes on every RealityView.update call
        // during window drag (window size changes are tiny floating-point updates each frame).
        // Without this, moving the window triggers constant SwiftUI re-renders of the control panel.
        let eps: Float = 0.002
        let needsYUpdate = abs(volumeYLimits.lowerBound - newYLimits.lowerBound) > eps ||
                           abs(volumeYLimits.upperBound - newYLimits.upperBound) > eps
        let needsZUpdate = abs(volumeZLimits.lowerBound - newZLimits.lowerBound) > eps ||
                           abs(volumeZLimits.upperBound - newZLimits.upperBound) > eps
        // Never write @State from inside RealityView.update — defer to next runloop
        // to avoid "Modifying state during view update" warnings.
        if needsYUpdate || needsZUpdate {
            DispatchQueue.main.async { [self] in
                if needsYUpdate {
                    volumeYLimits = newYLimits
                    volumeHeight = min(max(volumeHeight, newYLimits.lowerBound), newYLimits.upperBound)
                }
                if needsZUpdate {
                    volumeZLimits = newZLimits
                    volumeDepthOffset = min(max(volumeDepthOffset, newZLimits.lowerBound), newZLimits.upperBound)
                }
            }
        }
    }
    
    /// Heavy attachment layout - only called when screen aspect ratio changes
    private func layoutAttachments(attachments: RealityViewAttachments) {
        func sizeToFit(_ entity: Entity, targetWidth: Float) {
            let bounds = entity.visualBounds(relativeTo: screen)
            if bounds.extents.x > 0 {
                let currentScaleX = max(entity.scale.x, 0.0001)
                let unscaledWidth = Float(bounds.extents.x) / currentScaleX
                let scale = targetWidth / unscaledWidth
                entity.scale = [scale, scale, scale]
            }
        }
        
        if let inputEnt = attachments.entity(for: "inputOverlay") {
            if inputEnt.parent !== screen { screen.addChild(inputEnt) }
            inputEnt.position = [0.0 as Float, 0.0 as Float, Float(0.01)]
            sizeToFit(inputEnt, targetWidth: CURVED_MAX_WIDTH_METERS * 1.05)
        }
        if let dimPickerEnt = attachments.entity(for: "dimPicker") {
            if dimPickerEnt.parent !== screen { screen.addChild(dimPickerEnt) }
            // Place in front of control panel (z=0.22) so it isn't obscured
            dimPickerEnt.position = [0.0 as Float, 0.0 as Float, Float(0.28)]
            sizeToFit(dimPickerEnt, targetWidth: 0.52)
        }
        if let statsEnt = attachments.entity(for: "stats") {
            if statsEnt.parent !== screen { screen.addChild(statsEnt) }
            if !statsScaleInitialized {
                sizeToFit(statsEnt, targetWidth: statsCardWidthMeters)
            }
        }
        if let popupEnt = attachments.entity(for: "presetPopup") {
            if popupEnt.parent !== screen { screen.addChild(popupEnt) }
            popupEnt.position = [0.0 as Float, 0.0 as Float, Float(0.15)]
            if showInlineHint {
                sizeToFit(popupEnt, targetWidth: 0.35)
            } else {
                popupEnt.scale = .one
            }
        }
        if let panelEnt = attachments.entity(for: "controlPanel") {
            if panelEnt.parent !== screen { screen.addChild(panelEnt) }
            panelEnt.position = [0.0 as Float, 0.0 as Float, Float(0.22)]
            sizeToFit(panelEnt, targetWidth: 0.95)
        }
        if let reconnectEnt = attachments.entity(for: "reconnectingOverlay") {
            if reconnectEnt.parent !== screen { screen.addChild(reconnectEnt) }
            reconnectEnt.position = [0.0 as Float, 0.0 as Float, Float(0.4)]
            sizeToFit(reconnectEnt, targetWidth: 0.35)
        }
        if let errorEnt = attachments.entity(for: "immersiveErrorOverlay") {
            if errorEnt.parent !== screen { screen.addChild(errorEnt) }
            errorEnt.position = [0.0 as Float, 0.0 as Float, Float(0.45)]
            sizeToFit(errorEnt, targetWidth: 0.55)
        }
        if let keyboardEnt = attachments.entity(for: "keyboardTextField") {
            if keyboardEnt.parent !== screen { screen.addChild(keyboardEnt) }
            if showVirtualKeyboard {
                sizeToFit(keyboardEnt, targetWidth: 0.25)
                            } else {
                keyboardEnt.scale = .one
            }
        }
    }
    
    private func startStreamIfNeeded() {
        guard streamMan == nil else {
            print("[StreamView] StreamManager already exists, skipping duplicate creation")
            needsResume = false
            return
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !self.hasPerformedTeardown, self.viewModel.activelyStreaming, self.streamMan == nil else {
                print("[StreamView] Aborting stream start - Teardown: \(self.hasPerformedTeardown), Streaming: \(self.viewModel.activelyStreaming), Exists: \(self.streamMan != nil)")
                return
            }
            
            self.renderGateOpen = true
            self.firstFrameReceived = false
            self.idrWatchdogTimer1?.invalidate(); self.idrWatchdogTimer1 = nil
            self.idrWatchdogTimer2?.invalidate(); self.idrWatchdogTimer2 = nil
            self.postFirstFrameRebindTimer?.invalidate(); self.postFirstFrameRebindTimer = nil
            self.idrWatchdogTimer1 = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                if !self.firstFrameReceived { LiRequestIdrFrame() }
            }
            self.idrWatchdogTimer2 = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { _ in
                if !self.firstFrameReceived { LiRequestIdrFrame() }
            }
            
            self.ensureHDRTextureMatchesSetting()
            
            // Set controller support reference for rumble forwarding
            self.connectionCallbacks.controllerSupport = self.controllerSupport
            
            // Capture texture locally for thread-safe background access
            let localTexture = self.texture
            
            self.streamMan = StreamManager(
                config: self.streamConfig,
                rendererProvider: {
                    DrawableVideoDecoder(
                        texture: localTexture,
                        callbacks: self.connectionCallbacks,
                        aspectRatio: self.screenAspect,
                        useFramePacing: self.streamConfig.useFramePacing,
                        enableHDR: self.viewModel.streamSettings.enableHdr,
                        hdrSettingsProvider: {
                            self.safeHDRSettings.value
                        },
                        enhancementsProvider: {
                            (1.0, 1.0, 0.0)
                        },
                        callbackToRender: { textureQueue, correctedResolution in
                            guard self.renderGateOpen else { return }

                            DispatchQueue.main.async {
                                if let correctedResolution { 
                                    self.correctedResolution = correctedResolution 
                                }
                                self.texture.replace(withDrawables: textureQueue)
                                
                                // First Frame Logic
                                if !self.firstFrameReceived {
                                    self.firstFrameReceived = true
                                    self.idrWatchdogTimer1?.invalidate(); self.idrWatchdogTimer1 = nil
                                    self.idrWatchdogTimer2?.invalidate(); self.idrWatchdogTimer2 = nil
                                    
                                    self.postFirstFrameRebindTimer?.invalidate()
                                    self.postFirstFrameRebindTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { _ in
                                        self.rebindScreenMaterial()
                                    }
                                    
                                    self.controllerSupport?.connectionEstablished()
                                    self.startHideTimer()
                                }
                            }
                        }
                    )
                },
                connectionCallbacks: self.connectionCallbacks
            )
            let operationQueue = OperationQueue()
            if let streamMan = self.streamMan {
                operationQueue.addOperation(streamMan)
            }
            
        }
    }
    
    private func ensureHDRTextureMatchesSetting() {
        let desiredHDR = viewModel.streamSettings.enableHdr
        if desiredHDR == isHDRTexture { return }
        
        let width = Int(streamConfig.width)
        let height = Int(streamConfig.height)
        let bytesPerPixel = desiredHDR ? 8 : 4
        let data = Data(count: bytesPerPixel * width * height)
        
        if let newTexture = try? TextureResource(
            dimensions: .dimensions(width: width, height: height),
            format: .raw(pixelFormat: desiredHDR ? .rgba16Float : .bgra8Unorm_srgb),
            contents: .init(mipmapLevels: [.mip(data: data, bytesPerRow: bytesPerPixel * width)])
        ) {
            self.texture = newTexture
            self.isHDRTexture = desiredHDR
            rebindScreenMaterial()
        }
    }
    
    @State private var openedMainAfterDisconnect = false
    
    private func triggerCloseSequence() {
        performCompleteTeardown()
        viewModel.activelyStreaming = false
        viewModel.shouldCloseStream = false

        if isImmersive {
            if lastStreamErrorMessage == nil {
                openWindow(id: "mainView")
                Task {
                    await dismissImmersiveSpace()
                }
            }
            // When lastStreamErrorMessage != nil, keep immersive space open to show error overlay; user taps 关闭 to dismiss
        } else {
            // Use dismissWindow(id:) without value: StreamConfiguration lacks Hashable, value-based dismiss fails to match
            dismissWindow(id: "realitykitStreamingWindow")
        }
    }
    
    private func cycleTiltAngle() {
        tiltAngle += 10.0
        if tiltAngle > 60.0 {
            tiltAngle = 0.0
        }
    }
    
    private func handleConnectionTerminatedForRetry(notification: Notification) {
        guard !hasPerformedTeardown, viewModel.activelyStreaming else { return }
        guard !isPerformingReconnectTeardown else { return }  // Ignore spurious from our own stopStream
        let msg = (notification.userInfo?["message"] as? String) ?? viewModel.localized("unknown_error")
        
        if reconnectAttemptCount < maxReconnectAttempts {
            reconnectAttemptCount += 1
            isReconnecting = true
            connectionCallbacks.isReconnectingForRetry = true
            isPerformingReconnectTeardown = true
            print("[StreamView] Connection lost, auto-reconnect attempt \(reconnectAttemptCount)/\(maxReconnectAttempts)")
            performReconnectTeardown {
                self.isPerformingReconnectTeardown = false
                DispatchQueue.main.asyncAfter(deadline: .now() + self.reconnectDelaySeconds) {
                    guard !self.hasPerformedTeardown, self.viewModel.activelyStreaming else {
                        self.isReconnecting = false
                        self.connectionCallbacks.isReconnectingForRetry = false
                        return
                    }
                    self.renderGateOpen = true
                    self.controllerSupport = ControllerSupport(config: self.streamConfig, delegate: DummyControllerDelegate())
                    self.connectionCallbacks.controllerSupport = self.controllerSupport
                    self.startStreamIfNeeded()
                }
            }
            } else {
            print("[StreamView] Reconnect attempts exhausted, showing error overlay")
            isReconnecting = false
            isPerformingReconnectTeardown = false
            connectionCallbacks.isReconnectingForRetry = false
            reconnectAttemptCount = 0
            lastStreamErrorMessage = msg
            connectionCallbacks.showAlert = true
            connectionCallbacks.errorMessage = msg
            if isImmersive {
                viewModel.streamState = .stopping
            }
            // Soft teardown first (stop stream without full close).
            // In immersive: keep activelyStreaming=true so we stay in mainContent and show
            // errorHUDOverlay on top — switching to else branch causes space to dismiss/crash.
            performReconnectTeardown {
                NotificationCenter.default.post(name: Notification.Name("RealityKitStreamErrorNotification"), object: nil, userInfo: ["message": msg])
                if !self.isImmersive {
                    NotificationCenter.default.post(name: Notification.Name("RealityKitRetriesExhausted"), object: nil)
                }
            }
        }
    }
    
    private func performReconnectTeardown(completion: @escaping () -> Void) {
        guard streamMan != nil else {
            completion()
            return
        }
        print("[StreamView] Reconnect teardown (soft stop, no RKStreamDidTeardown)")
        renderGateOpen = false
        statsTimer?.invalidate()
        hintOverlayTimer?.invalidate()
        hintOverlayTimer = nil
        hideTimer?.invalidate()
        moonlightCycleTimer?.invalidate()
        idrWatchdogTimer1?.invalidate(); idrWatchdogTimer1 = nil
        idrWatchdogTimer2?.invalidate(); idrWatchdogTimer2 = nil
        postFirstFrameRebindTimer?.invalidate(); postFirstFrameRebindTimer = nil
        firstFrameReceived = false
        // Allow the next connection's first frame to re-arm the RKStreamFirstFrameShown
        // notification. Without this reset the idempotency guard in videoContentShown()
        // would silently swallow the reconnect signal.
        connectionCallbacks.videoShown = false
        controllerSupport?.cleanup()
        controllerSupport = nil
        
        let sm = streamMan
        streamMan = nil
        var completed = false
        let finish = {
            guard !completed else { return }
            completed = true
            DispatchQueue.main.async { completion() }
        }
        sm?.stopStream(completion: { finish() })
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { finish() }
    }
    
    private func performCompleteTeardown() {
        guard !hasPerformedTeardown else { return }
        hasPerformedTeardown = true
        
        print("[StreamView] 🔴 TEARDOWN START")
        
        // CRITICAL: Close render gate BEFORE stopping stream
        renderGateOpen = false
        
        statsTimer?.invalidate()
        hintOverlayTimer?.invalidate()
        hintOverlayTimer = nil
        hideTimer?.invalidate()
        moonlightCycleTimer?.invalidate()
        
        idrWatchdogTimer1?.invalidate(); idrWatchdogTimer1 = nil
        idrWatchdogTimer2?.invalidate(); idrWatchdogTimer2 = nil
        postFirstFrameRebindTimer?.invalidate(); postFirstFrameRebindTimer = nil
        firstFrameReceived = false
        
        controllerSupport?.cleanup()
        controllerSupport = nil
        
        // CRITICAL: Use stopStreamWithCompletion so we wait for LiStopConnection()
        // to fully finish before declaring teardown complete. Without this, a new
        // connection can start while the old one is still stopping, causing initLock
        // timeout and black screen.
        if let sm = streamMan {
            print("[StreamView] Stopping StreamManager (waiting for completion)...")
            streamMan = nil  // Clear reference now to prevent double-stop
            
            // Safety flag to ensure TEARDOWN COMPLETE fires exactly once, even if
            // both the completion callback and the safety timeout race.
            var teardownPosted = false
            let postTeardown = {
                guard !teardownPosted else { return }
                teardownPosted = true
                print("[StreamView] StreamManager stopped, clearing references")
                print("[StreamView] 🔴 TEARDOWN COMPLETE")
                NotificationCenter.default.post(name: Notification.Name("RKStreamDidTeardown"), object: nil)
            }
            
            sm.stopStream(completion: {
                DispatchQueue.main.async {
                    postTeardown()
                }
            })
            
            // Safety timeout: if stopStream completion doesn't fire within 5s
            // (e.g., ENet control stream is stuck), forcibly post teardown so the
            // UI state machine isn't stuck in .stopping forever. Connection.m has
            // its own internal 10s+10s timeouts for initLock/LiStopConnection, so
            // the underlying stop will eventually complete on its own.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                if !teardownPosted {
                    print("[StreamView] ⚠️ StreamManager stop timed out after 5s - forcing teardown complete")
                    postTeardown()
                }
            }
        } else {
            print("[StreamView] 🔴 TEARDOWN COMPLETE (no stream to stop)")
            NotificationCenter.default.post(name: Notification.Name("RKStreamDidTeardown"), object: nil)
        }
    }
    
    private func cleanupResources() {
        streamMan = nil
        controllerSupport?.cleanup()
        controllerSupport = nil
    }

    private func startEnvironmentFade(targetOpacity: Float, completion: (() -> Void)? = nil) {
        environmentFadeTimer?.invalidate()
        
        guard let dome = environmentDome else {
            completion?()
            return
        }
        
        // Ensure OpacityComponent exists
        if dome.components[OpacityComponent.self] == nil {
            dome.components.set(OpacityComponent(opacity: targetOpacity == 1.0 ? 0.0 : 1.0))
        }
        
        let startOpacity = dome.components[OpacityComponent.self]?.opacity ?? 0.0
        
        // If already close to target, just set and finish
        if abs(startOpacity - targetOpacity) < 0.01 {
            dome.components.set(OpacityComponent(opacity: targetOpacity))
            completion?()
            return
        }
        
        let duration: TimeInterval = 0.5
        let steps = 30
        let interval = duration / Double(steps)
        let stepAmount = (targetOpacity - startOpacity) / Float(steps)
        
        var currentStep = 0
        
        environmentFadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak dome] timer in
            guard let dome = dome else {
                timer.invalidate()
                return
            }
            
            currentStep += 1
            let newOpacity = startOpacity + stepAmount * Float(currentStep)
            dome.components.set(OpacityComponent(opacity: newOpacity))
            
            if currentStep >= steps {
                if targetOpacity >= 1.0 {
                    // Remove OpacityComponent when fully visible to avoid interfering with controls
                    dome.components.remove(OpacityComponent.self)
                } else {
                    dome.components.set(OpacityComponent(opacity: targetOpacity))
                }
                timer.invalidate()
                // self.environmentFadeTimer = nil // Omitted to avoid self capture complexity
                completion?()
            }
        }
    }

    private func updateEnvironmentState() {
        guard let dome = environmentDome else { return }
        
        if environmentSphereLevel == 0 {
            startEnvironmentFade(targetOpacity: 0.0) {
                dome.isEnabled = false
                self.lastEnvironmentSphereLevelApplied = 0
            }
            return
        }
        
        // If already enabled, fade out first then swap
        if dome.isEnabled {
            startEnvironmentFade(targetOpacity: 0.0) {
                if let tex = self.currentSkyboxTexture() {
                    self.applySkyboxTexture(tex)
                    self.lastEnvironmentSphereLevelApplied = self.environmentSphereLevel
                    self.startEnvironmentFade(targetOpacity: 1.0)
                }
            }
            return
        }
        
        if !dome.isEnabled {
            dome.isEnabled = true
            dome.components.set(OpacityComponent(opacity: 0.0))
        }
        
        if let tex = currentSkyboxTexture() {
            applySkyboxTexture(tex)
            lastEnvironmentSphereLevelApplied = environmentSphereLevel
            startEnvironmentFade(targetOpacity: 1.0)
        }
    }
    
    private func updateEnvPresetState() {
        guard let dome = environmentDome else { return }
        
        if envPresetLevel == 0 {
            startEnvironmentFade(targetOpacity: 0.0) {
                dome.isEnabled = false
            }
            return
        }
        
        // If already enabled, fade out first then swap
        if dome.isEnabled {
            startEnvironmentFade(targetOpacity: 0.0) {
                if let tex = self.currentNewsetTexture() {
                    self.applySkyboxTexture(tex)
                    self.startEnvironmentFade(targetOpacity: 1.0)
                }
            }
            return
        }
        
        if !dome.isEnabled {
            dome.isEnabled = true
            dome.components.set(OpacityComponent(opacity: 0.0))
        }
        
        if let tex = currentNewsetTexture() {
            applySkyboxTexture(tex)
            startEnvironmentFade(targetOpacity: 1.0)
        }
    }

    private func currentSkyboxTexture() -> TextureResource? {
        let builtinNames: [String] = []
        let idx = environmentSphereLevel - 1
        if idx >= 0 && idx < builtinNames.count {
            if let cached = builtinSkyboxTextures[builtinNames[idx]] {
                return cached
            }
            if let tex = loadTextureFromBundle(candidates: [builtinNames[idx]], subdirectory: nil) {
                builtinSkyboxTextures[builtinNames[idx]] = tex
                return tex
            }
        } else if idx >= 0 && idx - builtinNames.count < extraSkyboxTextures.count {
            return extraSkyboxTextures[idx - builtinNames.count]
        }
        return nil
    }
    
    private func currentNewsetTexture() -> TextureResource? {
        let ambientPresetNames: [String] = []
        let idx = envPresetLevel - 1
        if idx >= 0 && idx < ambientPresetNames.count {
            let name = ambientPresetNames[idx]
            
            if let cached = envPresetSkyboxTextures[name] {
                return cached
            }
            
            // Try without subdirectory (files added as group)
            if let url = Bundle.main.url(forResource: name, withExtension: "jpg") {
                if let tex = try? TextureResource.load(contentsOf: url) {
                    envPresetSkyboxTextures[name] = tex
                    return tex
                }
            }
        }
        return nil
    }
    
    private func applySkyboxTexture(_ texture: TextureResource) {
        guard let dome = environmentDome else { return }
        var mat = UnlitMaterial(texture: texture)
        // Keep the skybox material opaque when fully visible.
        // OpacityComponent drives the fade and will automatically take the entity through a transparent path while fading.
        mat.blending = .opaque
        
        guard let mesh = dome.model?.mesh else { return }
        dome.model = ModelComponent(mesh: mesh, materials: [mat])
        
        // Apply rotation based on which set is active
        if envPresetLevel > 0 {
            let ambientPresetNames: [String] = []
            let ambientPresetRotations: [String: Float] = [:]
            let idx = envPresetLevel - 1
            if idx >= 0 && idx < ambientPresetNames.count {
                let skyboxName = ambientPresetNames[idx]
                if let rotationAngle = ambientPresetRotations[skyboxName] {
                    dome.orientation = simd_quatf(angle: rotationAngle, axis: SIMD3<Float>(0, 1, 0))
        } else {
                    dome.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
                }
            }
        } else if environmentSphereLevel > 0 {
            let builtinNames: [String] = []
            let rotations: [String: Float] = [:]
            let idx = environmentSphereLevel - 1
            if idx >= 0 && idx < builtinNames.count {
                let skyboxName = builtinNames[idx]
                if let rotationAngle = rotations[skyboxName] {
                    dome.orientation = simd_quatf(angle: rotationAngle, axis: SIMD3<Float>(0, 1, 0))
        } else {
                    dome.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
                }
            }
        } else {
            dome.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }
    }

    private func loadTextureFromBundle(candidates: [String], subdirectory: String?) -> TextureResource? {
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: subdirectory) {
                do {
                    let tex = try TextureResource.load(contentsOf: url)
                    return tex
                } catch {
                    print("[Texture] Error loading \(name).jpg: \(error)")
                }
            }
        }
        return nil
    }

    // MARK: - Mesh Generation

    func generateCurvedRoundedPlane(
        width: Float,
        aspectRatio: Float,
        resolution: (UInt32, UInt32),
        curveMagnitude: Float,
        cornerRadiusFraction: Float
    ) throws -> MeshResource {
        var descr = MeshDescriptor(name: "curved_rounded_plane")
        let height = width * aspectRatio
        let vertexCount = Int(resolution.0 * resolution.1)
        let numQuadsX = resolution.0 - 1
        let numQuadsY = resolution.1 - 1
        let triangleCount = Int(numQuadsX * numQuadsY * 2)
        let indexCount = triangleCount * 3
        
        var positions = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var texcoords = [SIMD2<Float>](repeating: .zero, count: vertexCount)
        var indices = [UInt32](repeating: 0, count: indexCount)
        
        let maxCurveAngle: Float = CURVED_MAX_ANGLE
        let currentAngle = maxCurveAngle * max(0.0, min(curveMagnitude, 2.0))
        let halfAngle = currentAngle / 2.0
        let isFlat = currentAngle < 0.0001
        let radius: Float = isFlat ? .infinity : (width / currentAngle)
        
        let cornerRadius = max(0.0, min(0.25, cornerRadiusFraction)) * height
        let x0 = -width / 2.0
        let y0 = -height / 2.0
        
        let texInset: Float = 0.002
        
        var vi = 0
        var ii = 0

        for y_v in 0 ..< resolution.1 {
            let v_geo = Float(y_v) / Float(resolution.1 - 1)
            let yFlat = (0.5 - v_geo) * height
            let v_tex = (1.0 - v_geo) * (1.0 - 2.0 * texInset) + texInset

            for x_v in 0 ..< resolution.0 {
                let u = Float(x_v) / Float(resolution.0 - 1)
                let xFlat = (u - 0.5) * width

                var xr = xFlat, yr = yFlat
                if cornerRadius > 0 {
                    if xr < x0 + cornerRadius && yr < y0 + cornerRadius {
                        let dx = xr - (x0 + cornerRadius), dy = yr - (y0 + cornerRadius)
                        if let (nx, ny) = normalizeAndScale(dx, dy, cornerRadius) { xr = (x0 + cornerRadius) + nx; yr = (y0 + cornerRadius) + ny }
                    } else if xr > -x0 - cornerRadius && yr < y0 + cornerRadius {
                        let dx = xr - (-x0 - cornerRadius), dy = yr - (y0 + cornerRadius)
                        if let (nx, ny) = normalizeAndScale(dx, dy, cornerRadius) { xr = (-x0 - cornerRadius) + nx; yr = (y0 + cornerRadius) + ny }
                    } else if xr < x0 + cornerRadius && yr > -y0 - cornerRadius {
                        let dx = xr - (x0 + cornerRadius), dy = yr - (-y0 - cornerRadius)
                        if let (nx, ny) = normalizeAndScale(dx, dy, cornerRadius) { xr = (x0 + cornerRadius) + nx; yr = (-y0 - cornerRadius) + ny }
                    } else if xr > -x0 - cornerRadius && yr > -y0 - cornerRadius {
                        let dx = xr - (-x0 - cornerRadius), dy = yr - (-y0 - cornerRadius)
                        if let (nx, ny) = normalizeAndScale(dx, dy, cornerRadius) { xr = (-x0 - cornerRadius) + nx; yr = (-y0 - cornerRadius) + ny }
                    }
                }
                
                var px = xr, pz: Float = 0.0
                if !isFlat, radius.isFinite {
                    let t = xr / (width / 2.0)
                    let theta = t * halfAngle
                    px = radius * sin(theta)
                    pz = radius - (radius * cos(theta))
                }

                positions[vi] = SIMD3<Float>(px, yr, pz)
                let u_tex = u * (1.0 - 2.0 * texInset) + texInset
                texcoords[vi] = SIMD2<Float>(u_tex, v_tex)

                if x_v < numQuadsX && y_v < numQuadsY {
                    let current = UInt32(vi), nextRow = current + resolution.0
                    indices[ii + 0] = current; indices[ii + 1] = nextRow; indices[ii + 2] = nextRow + 1
                    indices[ii + 3] = current; indices[ii + 4] = nextRow + 1; indices[ii + 5] = current + 1
                    ii += 6
                }
                vi += 1
            }
        }

        descr.positions = MeshBuffer(positions)
        descr.textureCoordinates = MeshBuffers.TextureCoordinates(texcoords)
        descr.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descr])
    }

    private func normalizeAndScale(_ dx: Float, _ dy: Float, _ cornerRadius: Float) -> (Float, Float)? {
        let dist = sqrt(dx*dx + dy*dy)
        if dist > cornerRadius {
            let s = cornerRadius / dist
            return (dx * s, dy * s)
        }
        return nil
    }
    
    private func getDimmerMaterial() -> (RealityKit.Material, TextureResource?) {
        if dimLevel == 11 {
            if let cached = moonlightMaterial {
                return (cached, nil)
            } else {
                let initial = getMoonlightCycleColor(phase: moonlightCyclePhase).withAlphaComponent(moonlightAlphaLowPower)
                var mat = moonlightMaterial ?? UnlitMaterial(color: initial)
                mat.blending = .transparent(opacity: 1.0)
                moonlightMaterial = mat
                return (mat, nil)
            }
        }

        if dimLevel == 2 {
            // Reactive V1 - Keeps transparency (0.85), so keep .transparent
            var mat = UnlitMaterial(color: currentAmbientColor.withAlphaComponent(0.85))
            mat.blending = .transparent(opacity: 1.0)
            return (mat, nil)
        }

        if dimLevel == 10 {
            // Reactive V2 - SOLID COLOR (reactive)
            // Use .opaque for proper Z-sorting so UI icons render on top
            var mat = UnlitMaterial(color: currentAmbientColor.withAlphaComponent(1.0))
            mat.blending = .opaque
            return (mat, nil)
        }
        
        if dimLevel == 12 {
            // Starfield - Pure black background
            var mat = UnlitMaterial(color: .black)
            mat.blending = .opaque
            return (mat, nil)
        }

        let selectedTex: TextureResource?
        switch dimLevel {
        case 4: selectedTex = eclipseGradientTexture
        case 5: selectedTex = purpleGradientTexturePurpleBlack
        case 6: selectedTex = twilightGradientTexture
        case 7: selectedTex = dawnGradientTexture
        case 8: selectedTex = sunriseGradientTexture
        case 9: selectedTex = woodlandGradientTexture
        case 14: selectedTex = desertGradientTexture
        default: selectedTex = purpleGradientTextureColors
        }

        let mat: RealityKit.Material
        if let tex = selectedTex {
            var unlitMat = UnlitMaterial(texture: tex)

            // Eclipse (Level 4) is SOLID black - use .opaque for proper Z-sorting
            if dimLevel == 4 {
                unlitMat.color.tint = .white
                unlitMat.blending = .opaque
        } else {
                // All other gradients are semi-transparent
                let tintAlpha: CGFloat = {
                    switch dimLevel {
                    case 5: return 0.95
                    case 6, 7, 8, 9, 14: return 0.90
                    default: return 0.5
                    }
                }()
                unlitMat.color.tint = UIColor.white.withAlphaComponent(tintAlpha)
                unlitMat.blending = .transparent(opacity: 1.0)
            }
            mat = unlitMat
        } else {
            var fallback = UnlitMaterial(color: .purple)
            let fallbackAlpha: CGFloat = {
                switch dimLevel {
                case 4, 5: return 0.95
                case 6, 7, 8, 9, 10: return 0.90
                default: return 0.5
                }
            }()
            fallback.color.tint = UIColor(red: 0.60, green: 0.40, blue: 0.90, alpha: fallbackAlpha)
            fallback.blending = .transparent(opacity: 1.0)
            mat = fallback
        }
        return (mat, selectedTex)
    }

    private func updateDimmerDomesState() {
        dimmerDome?.isEnabled = (dimLevel == 1)
        dimmerDomePurple?.isEnabled = (dimLevel >= 2 && dimLevel <= 14)
        
        
    }

    private func updateDimmerDomes(content: RealityViewContent) {
        let isReactiveMode = (dimLevel == 2 || dimLevel == 10 || dimLevel == 12)
        
        guard dimLevel != lastAppliedDimLevelBox.value else { return }
        lastAppliedDimLevelBox.value = dimLevel
        
        if let dome = dimmerDome {
            let targetAlpha: Float = viewModel.streamSettings.dimPassthrough ? Float(dimAlphas[1]) : Float(dimAlphas[0])
            if let comp = dome.components[OpacityComponent.self], abs(comp.opacity - targetAlpha) > 0.001 {
                dome.components.set(OpacityComponent(opacity: targetAlpha))
            } else if dome.components[OpacityComponent.self] == nil {
                dome.components.set(OpacityComponent(opacity: targetAlpha))
            }

            if dome.model?.materials.isEmpty ?? true, let mesh = dome.model?.mesh {
                var blackMat = UnlitMaterial(color: .black)
                blackMat.blending = .transparent(opacity: 1.0)
                dome.model = ModelComponent(mesh: mesh, materials: [blackMat])
            }
        }

        if !isReactiveMode, let purple = self.dimmerDomePurple {
            let (mat, _) = getDimmerMaterial()
            purple.model?.materials = [mat]
        }
    }

    private func setupDimmerDomes(content: RealityViewContent) {
        guard dimmerDome == nil else {
            updateDimmerDomesState()
            return
        }

        let sharedDomeMesh: MeshResource = .generateSphere(radius: 60.0)
        
        var blackMat = UnlitMaterial(color: .black)
        blackMat.blending = .transparent(opacity: 1.0)
        let dome = ModelEntity(mesh: sharedDomeMesh, materials: [blackMat])
        dome.scale.x = -1.0
        dome.position = .zero
        dome.components.set(OpacityComponent(opacity: 0.0))
        dome.components.set(InputTargetComponent(allowedInputTypes: []))
        content.add(dome)
        self.dimmerDome = dome

        let purpleDome = ModelEntity(mesh: sharedDomeMesh, materials: [])
        purpleDome.scale.x = -1.0
        purpleDome.position = .zero
        purpleDome.components.set(InputTargetComponent(allowedInputTypes: []))
        content.add(purpleDome)
        self.dimmerDomePurple = purpleDome

        updateDimmerDomesState()

        dimmerGradientPreloadTask?.cancel()
        dimmerGradientPreloadTask = Task {
            purpleGradientTextureColors = try? await makeGradientTexture(size: 1024, gradient: .sunset)
            purpleGradientTexturePurpleBlack = try? await makeGradientTexture(size: 1024, gradient: .midnight)
            eclipseGradientTexture = try? await makeGradientTexture(size: 1024, gradient: .eclipse)
            twilightGradientTexture = try? await makeGradientTexture(size: 1024, gradient: .twilight)
            dawnGradientTexture = try? await makeGradientTexture(size: 1024, gradient: .dawn)
            sunriseGradientTexture = try? await makeGradientTexture(size: 1024, gradient: .sunrise)
            woodlandGradientTexture = try? await makeGradientTexture(size: 1024, gradient: .woodland)
            desertGradientTexture = try? await makeGradientTexture(size: 1024, gradient: .desert)
            duskHDRTexture = try? await TextureResource(named: "dusk")
            await MainActor.run { self.dimmerGradientPreloadTask = nil }
        }
    }

    // MARK: - Gradient Presets and Generator for Dimming Textures
    enum GradientPreset {
        case sunset
        case midnight
        case eclipse
        case twilight
        case dawn
        case sunrise
        case woodland
        case desert
    }

    func makeGradientTexture(size: Int, gradient: GradientPreset) async throws -> TextureResource? {
        let s = max(size, 32)
        let rect = CGRect(x: 0, y: 0, width: s, height: s)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: s, height: s))

        let img = renderer.image { ctx in
            ctx.cgContext.setFillColor(UIColor.clear.cgColor)
            ctx.cgContext.fill(rect)

            let colors: [CGColor]
            let locations: [CGFloat]

            switch gradient {
            case .sunset:
                colors = [
                    UIColor(red: 0.60, green: 0.40, blue: 0.90, alpha: 0.50).cgColor,
                    UIColor(red: 0.95, green: 0.60, blue: 0.85, alpha: 0.45).cgColor,
                    UIColor(red: 0.95, green: 0.45, blue: 0.60, alpha: 0.42).cgColor,
                    UIColor(red: 0.976, green: 0.627, blue: 0.251, alpha: 0.38).cgColor
                ]
                locations = [0.0, 0.33, 0.65, 1.0]

            case .midnight:
                colors = [
                    UIColor(red: 0.60, green: 0.40, blue: 0.90, alpha: 0.42).cgColor,
                    UIColor(red: 0.60, green: 0.40, blue: 0.90, alpha: 0.30).cgColor,
                    UIColor(red: 0.50, green: 0.30, blue: 0.75, alpha: 0.18).cgColor,
                    UIColor.black.withAlphaComponent(0.84).cgColor,
                    UIColor.black.withAlphaComponent(0.94).cgColor,
                    UIColor.black.withAlphaComponent(1.00).cgColor
                ]
                locations = [0.00, 0.20, 0.35, 0.50, 0.80, 1.00]

            case .eclipse:
                colors = [
                    UIColor.black.cgColor,
                    UIColor.black.cgColor,
                    UIColor.black.cgColor,
                    UIColor.black.cgColor
                ]
                locations = [0.0, 0.30, 0.70, 1.0]

            case .twilight:
                colors = [
                    UIColor(red: 0.25, green: 0.20, blue: 0.40, alpha: 0.70).cgColor,
                    UIColor(red: 0.40, green: 0.25, blue: 0.50, alpha: 0.75).cgColor,
                    UIColor(red: 0.20, green: 0.15, blue: 0.30, alpha: 0.82).cgColor,
                    UIColor(red: 0.05, green: 0.03, blue: 0.10, alpha: 0.90).cgColor
                ]
                locations = [0.0, 0.35, 0.70, 1.0]

            case .dawn:
                colors = [
                    UIColor(red: 0.95, green: 0.75, blue: 0.55, alpha: 0.45).cgColor,
                    UIColor(red: 0.90, green: 0.60, blue: 0.70, alpha: 0.50).cgColor,
                    UIColor(red: 0.60, green: 0.45, blue: 0.75, alpha: 0.60).cgColor,
                    UIColor(red: 0.30, green: 0.25, blue: 0.45, alpha: 0.75).cgColor
                ]
                locations = [0.0, 0.30, 0.65, 1.0]

            case .sunrise:
                colors = [
                    UIColor(red: 1.00, green: 0.85, blue: 0.40, alpha: 0.38).cgColor,
                    UIColor(red: 0.98, green: 0.70, blue: 0.50, alpha: 0.42).cgColor,
                    UIColor(red: 0.90, green: 0.50, blue: 0.60, alpha: 0.48).cgColor,
                    UIColor(red: 0.70, green: 0.40, blue: 0.70, alpha: 0.55).cgColor
                ]
                locations = [0.0, 0.30, 0.65, 1.0]

            case .woodland:
                colors = [
                    UIColor(red: 0.25, green: 0.45, blue: 0.22, alpha: 0.65).cgColor,
                    UIColor(red: 0.18, green: 0.32, blue: 0.15, alpha: 0.75).cgColor,
                    UIColor(red: 0.08, green: 0.18, blue: 0.06, alpha: 0.90).cgColor,
                    UIColor(red: 0.04, green: 0.10, blue: 0.03, alpha: 0.98).cgColor
                ]
                locations = [0.0, 0.30, 0.60, 1.0]

            case .desert:
                colors = [
                    UIColor(red: 0.95, green: 0.80, blue: 0.55, alpha: 0.60).cgColor,
                    UIColor(red: 0.80, green: 0.60, blue: 0.40, alpha: 0.70).cgColor,
                    UIColor(red: 0.35, green: 0.22, blue: 0.12, alpha: 0.90).cgColor,
                    UIColor(red: 0.20, green: 0.12, blue: 0.06, alpha: 0.98).cgColor
                ]
                locations = [0.0, 0.25, 0.55, 1.0]
            }

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let cgGradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) {
                let startPoint = CGPoint(x: rect.midX, y: rect.minY)
                let endPoint = CGPoint(x: rect.midX, y: rect.maxY)
                ctx.cgContext.drawLinearGradient(
                    cgGradient,
                    start: startPoint,
                    end: endPoint,
                    options: [.drawsAfterEndLocation]
                )
            }
        }

        if let cg = img.cgImage {
            return try TextureResource.generate(from: cg, options: .init(semantic: .color))
        }
        return nil
    }

    private func getMoonlightCycleColor(phase: CGFloat) -> UIColor {
        let p = phase.truncatingRemainder(dividingBy: 1.0)
        if p < 0.2 {
            return interpolateColor(from: UIColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 0.96), to: UIColor(red: 0.10, green: 0.06, blue: 0.16, alpha: 0.96), progress: p / 0.2)
        } else if p < 0.4 {
            return interpolateColor(from: UIColor(red: 0.10, green: 0.06, blue: 0.16, alpha: 0.96), to: UIColor(red: 0.08, green: 0.10, blue: 0.18, alpha: 0.96), progress: (p - 0.2) / 0.2)
        } else if p < 0.6 {
            return interpolateColor(from: UIColor(red: 0.08, green: 0.10, blue: 0.18, alpha: 0.96), to: UIColor(red: 0.20, green: 0.16, blue: 0.28, alpha: 0.96), progress: (p - 0.4) / 0.2)
        } else if p < 0.8 {
            return interpolateColor(from: UIColor(red: 0.20, green: 0.16, blue: 0.28, alpha: 0.96), to: UIColor(red: 0.22, green: 0.28, blue: 0.36, alpha: 0.96), progress: (p - 0.6) / 0.2)
        } else {
            return interpolateColor(from: UIColor(red: 0.22, green: 0.28, blue: 0.36, alpha: 0.96), to: UIColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 0.96), progress: (p - 0.8) / 0.2)
        }
    }

    private func interpolateColor(from: UIColor, to: UIColor, progress: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        from.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        to.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * progress, green: g1 + (g2 - g1) * progress, blue: b1 + (b2 - b1) * progress, alpha: a1 + (a2 - a1) * progress)
    }
    
    private func rgb(_ color: UIColor) -> SIMD3<Float> {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3<Float>(Float(r), Float(g), Float(b))
    }

    private func colorDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return simd_length(d)
    }

    private func setupEnvironment360(content: RealityViewContent) {
        // RealityView's initial closure can run more than once across SwiftUI updates; guard
        // so we never stack duplicate 60m spheres or re-fire skybox loads.
        guard environmentDome == nil else { return }

        let sphere = ModelEntity(mesh: .generateSphere(radius: 60.0), materials: [UnlitMaterial(color: .clear)])
        sphere.scale.x = -1.0
        sphere.isEnabled = false
        content.add(sphere)
        environmentDome = sphere

        if extraSkyboxTextures.isEmpty && extraSkyboxNames.isEmpty {
            loadExtraSkyboxesFromBundle()
        }
        if environmentSphereLevel != 0, let tex = currentSkyboxTexture() {
            sphere.isEnabled = true
            applySkyboxTexture(tex)
            lastEnvironmentSphereLevelApplied = environmentSphereLevel
        } else if envPresetLevel != 0, let tex = currentSkyboxTexture() {
            sphere.isEnabled = true
            applySkyboxTexture(tex)
        }
    }

    func updateEnvironment360(content: RealityViewContent) {
        // We handle environment updates via updateEnvironmentState() triggered by Binding changes
        // to support fade animations. Automatic updates here would interfere with transitions.
    }

    private func restoreEnvironmentTextureIfNeeded() {
        guard let dome = environmentDome else { return }
        guard immersiveEnvironment.environmentStateHandler.activeState != .none || selectedEnvironmentState != .none else { return }
        guard environmentSphereLevel != 0 || envPresetLevel != 0 else { return }
        guard let tex = currentSkyboxTexture() else { return }

        dome.isEnabled = true
        applySkyboxTexture(tex)
    }

    internal init(streamConfig: Binding<StreamConfiguration>, needsHdr: Bool, isImmersive: Bool, swapAction: @escaping () -> Void) {
        self.swapAction = swapAction
        self._streamConfig = streamConfig
        self.needsHdr = needsHdr
        self.isImmersive = isImmersive
        self.controllerSupport = ControllerSupport(config: streamConfig.wrappedValue, delegate: DummyControllerDelegate())
        
        let bytesPerPixel = needsHdr ? 8 : 4
        let data = Data(count: bytesPerPixel * Int(streamConfig.wrappedValue.width) * Int(streamConfig.wrappedValue.height))
        
        // Safe texture creation with fallback
        do {
            self.texture = try TextureResource(
                dimensions: .dimensions(width: Int(streamConfig.wrappedValue.width), height: Int(streamConfig.wrappedValue.height)),
                format: needsHdr
                    ? .raw(pixelFormat: .rgba16Float)
                    : .raw(pixelFormat: .bgra8Unorm_srgb),
                contents: .init(mipmapLevels: [.mip(data: data, bytesPerRow: bytesPerPixel * Int(streamConfig.wrappedValue.width))])
            )
            self.isHDRTexture = needsHdr
        } catch {
            print("⚠️ Failed to create main texture: \(error). Using fallback.")
            // Fallback to minimal 1x1 texture to prevent crash
            let fallbackData = Data(count: 4)
            self.texture = try! TextureResource(
                dimensions: .dimensions(width: 1, height: 1),
                format: .raw(pixelFormat: .bgra8Unorm_srgb),
                contents: .init(mipmapLevels: [.mip(data: fallbackData, bytesPerRow: 4)])
            )
            self.isHDRTexture = false
        }
    }

    private func recenterScreenToHead(head: AnchorEntity) {
        let headPos = head.position(relativeTo: nil)
        let current = screenPosition

        // Preserve current height offset
        let yOffset = current.y - headPos.y
        
        // Calculate the ACTUAL 3D distance from head to screen (not just horizontal)
        let delta = current - headPos
        let actualDistance = simd_length(delta)

        // Get head's forward direction (where you're looking)
        let q = head.transform.rotation
        var headForward = q.act(simd_float3(0, 0, -1))

        // Flatten to horizontal plane (ignore vertical component)
        var flatForward = simd_float3(headForward.x, 0, headForward.z)
        let norm = simd_length(flatForward)
        if norm < 1e-4 {
            flatForward = simd_float3(0, 0, -1)
        } else {
            flatForward /= norm
        }

        // Place screen dead center at the same 3D distance
        var newPos = simd_float3(
            headPos.x + flatForward.x * actualDistance,
            headPos.y + yOffset,
            headPos.z + flatForward.z * actualDistance
        )

        newPos.x = min(max(newPos.x, -allowedLateralMax), allowedLateralMax)

        screenPosition = newPos
    }

    private func saveCurrentTransform() {
        var pos = screenPosition
        let scale = screenScale
        let packed = [pos.x, pos.y, pos.z]
        UserDefaults.standard.set(packed, forKey: kImmersivePosKey)
        UserDefaults.standard.set(scale, forKey: kImmersiveScaleKey)
    }

    private func restoreSavedTransform() {
        let defaults = UserDefaults.standard
        if !isImmersive {
            if let h = defaults.object(forKey: "realitykitHeight") as? Float { volumeHeight = h }
            if let d = defaults.object(forKey: "realitykitDepthOffset") as? Float { volumeDepthOffset = d }
            if let tilt = defaults.object(forKey: "realitykitTiltAngle") as? Float { controlState.tiltAngle = tilt }
            if viewModel.streamSettings.rememberStreamSettings {
                if let c = defaults.object(forKey: "realitykitVolumeCurvature") as? Float { viewModel.streamSettings.realitykitRendererCurvature = c }
                if let g = defaults.object(forKey: "realitykitVolumeGamma") as? Float { viewModel.streamSettings.gamma = g }
                if let s = defaults.object(forKey: "realitykitVolumeSaturation") as? Float { viewModel.streamSettings.saturation = s }
                if let b = defaults.object(forKey: "realitykitVolumeBrightness") as? Float { viewModel.streamSettings.brightness = b }
                if let p = defaults.object(forKey: "realitykitVolumePqExposure") as? Float {
                    viewModel.streamSettings.pqExposure = p
                } else if let p = defaults.object(forKey: "realitykitPqExposure") as? Float {
                    viewModel.streamSettings.pqExposure = p
                }
                if let dim = defaults.object(forKey: "realitykitVolumeDimPassthrough") as? Bool { viewModel.streamSettings.dimPassthrough = dim }
            }
            return
        }
        // Prefer controlState values (saved by control panel) over legacy immersive.pos/scale
        if viewModel.streamSettings.rememberStreamSettings {
            if let c = defaults.object(forKey: "realitykitImmersiveCurvature") as? Float { viewModel.streamSettings.realitykitRendererCurvature = c }
            if let g = defaults.object(forKey: "realitykitImmersiveGamma") as? Float { viewModel.streamSettings.gamma = g }
            if let s = defaults.object(forKey: "realitykitImmersiveSaturation") as? Float { viewModel.streamSettings.saturation = s }
            if let b = defaults.object(forKey: "realitykitImmersiveBrightness") as? Float { viewModel.streamSettings.brightness = b }
            if let p = defaults.object(forKey: "realitykitImmersivePqExposure") as? Float { viewModel.streamSettings.pqExposure = p }
        }
        // Position/scale: only restore when rememberStreamSettings and valid saved data exists
        let defaultImmersivePosition = SIMD3<Float>(0, 1.0, -1.5)
        let defaultImmersiveScale: Float = 0.8
        if viewModel.streamSettings.rememberStreamSettings {
            if let savedPosX = defaults.object(forKey: "realitykitImmersivePosX") as? Float,
               let savedPosY = defaults.object(forKey: "realitykitImmersivePosY") as? Float,
               let savedPosZ = defaults.object(forKey: "realitykitImmersivePosZ") as? Float {
                screenPosition = SIMD3<Float>(savedPosX, savedPosY, savedPosZ)
            } else if let packed = defaults.array(forKey: kImmersivePosKey) as? [Float], packed.count == 3 {
                screenPosition = SIMD3<Float>(packed[0], packed[1], packed[2])
            } else {
                screenPosition = defaultImmersivePosition
            }
            if let savedScale = defaults.object(forKey: "realitykitImmersiveScale") as? Float, savedScale > 0 {
                screenScale = savedScale
            } else {
                let scale = defaults.float(forKey: kImmersiveScaleKey)
                screenScale = scale > 0 ? scale : defaultImmersiveScale
            }
        } else {
            screenPosition = defaultImmersivePosition
            screenScale = defaultImmersiveScale
        }
        if let savedImmersion = defaults.object(forKey: "realitykitImmersionAmount") as? Float {
            immersionAmount = savedImmersion
        }
        if let savedLocked = defaults.object(forKey: kImmersiveLockedKey) as? Bool {
            controlState.isInteractive = savedLocked
        }
        tiltAngle = 0.0
    }
    
    private let kImmersiveLockedKey = "immersive.locked"
    private let kImmersivePosKey = "immersive.pos"
    private let kImmersiveScaleKey = "immersive.scale"
    private func handleWindowClose() {
        isMenuOpen = false
        if let sceneID = self.immersiveSpaceSceneID {
            AudioHelpers.fixAudioForScene(identifier: sceneID)
        } else {
            fixAudioForCurrentMode()
        }
    }

    private func stopMoonlightCycle() {
        moonlightCycleTimer?.invalidate()
        moonlightCycleTimer = nil
        moonlightMaterial = nil
    }
    
    // MARK: - Reactive Color Lerp
    
    private func startReactiveLerp() {
        reactiveLerpTimer?.invalidate()
        
        // Initialize colors if starting fresh
        if currentAmbientColor == .black && targetReactiveColor == .black {
            let initialColor = UIColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0)
            currentAmbientColor = initialColor
            targetReactiveColor = initialColor
        }
        
        if cachedReactiveMaterial == nil {
            let alpha: CGFloat = (dimLevel == 10) ? 1.0 : 0.85
            var mat = UnlitMaterial(color: currentAmbientColor.withAlphaComponent(alpha))
            mat.blending = (dimLevel == 10) ? .opaque : .transparent(opacity: 1.0)
            cachedReactiveMaterial = mat
        }
        
        reactiveLerpTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            guard (self.dimLevel == 2 || self.dimLevel == 10), let purple = self.dimmerDomePurple else { return }
            
            let lerpFactor: CGFloat = 0.15
            
            var currentR: CGFloat = 0, currentG: CGFloat = 0, currentB: CGFloat = 0, currentA: CGFloat = 0
            self.currentAmbientColor.getRed(&currentR, green: &currentG, blue: &currentB, alpha: &currentA)
            
            var targetR: CGFloat = 0, targetG: CGFloat = 0, targetB: CGFloat = 0, targetA: CGFloat = 0
            self.targetReactiveColor.getRed(&targetR, green: &targetG, blue: &targetB, alpha: &targetA)
            
            let newR = currentR + (targetR - currentR) * lerpFactor
            let newG = currentG + (targetG - currentG) * lerpFactor
            let newB = currentB + (targetB - currentB) * lerpFactor
            
            self.currentAmbientColor = UIColor(red: newR, green: newG, blue: newB, alpha: 1.0)
            
            if var mat = self.cachedReactiveMaterial {
                let alpha: CGFloat = (self.dimLevel == 10) ? 1.0 : 0.85
                mat.color.tint = self.currentAmbientColor.withAlphaComponent(alpha)
                self.cachedReactiveMaterial = mat
                purple.model?.materials = [mat]
            }
        }
    }
    
    private func stopReactiveLerp() {
        reactiveLerpTimer?.invalidate()
        reactiveLerpTimer = nil
        cachedReactiveMaterial = nil
    }

    // MARK: - Timers & State Changes

    private func startHideTimer() {
        hideTimer?.invalidate()
        hideControls = false
        controlsHighlighted = true

        hideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.35)) {
                hideControls = true
                controlsHighlighted = false
            }
        }
    }
    
    private func startHighlightTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.35)) {
                hideControls = true
                controlsHighlighted = false
            }
        }
    }

    // MARK: - UI Helpers

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if let streamMan = self.streamMan, let stats = streamMan.getStatsOverlayText() {
                self.statsOverlayText = stats
            }
        }
    }
    
    private func fixAudioForCurrentMode() {
        if self.spatialAudioMode {
            AudioHelpers.fixAudioForSurroundForCurrentWindow()
        } else {
            AudioHelpers.fixAudioForDirectStereo()
        }
    }

    private func updateScreenInteractivity() {
        guard screen.parent != nil else { return }
        // Disable screen collision when menus are showing OR when in Controller mode
        // Controller buttons map to system gestures which hit CollisionComponent
        let shouldDisableInteractions = showMenuPanel || inputMode == .controller
        if shouldDisableInteractions {
            screen.components.remove(CollisionComponent.self)
            screen.components.remove(InputTargetComponent.self)
        } else {
            // Generate curved collision mesh for accurate gaze hit detection
            if let collisionMesh = try? generateCurvedRoundedPlane(
                width: CURVED_MAX_WIDTH_METERS,
                aspectRatio: screenAspect,
                resolution: (256, 256),
                curveMagnitude: effectiveCurvature,
                cornerRadiusFraction: 0
            ) {
                Task {
                    if let collisionShape = try? await ShapeResource.generateStaticMesh(from: collisionMesh) {
                        await MainActor.run {
                            screen.components.set(CollisionComponent(
                                shapes: [collisionShape],
                                filter: CollisionFilter(
                                    group: .screenEntity,
                                    mask: .all
                                )
                            ))
                        }
                    }
                }
            }
            screen.components.set(InputTargetComponent(allowedInputTypes: .all))
        }
    }
    
    // MARK: - Preload Skyboxes
    private func loadExtraSkyboxesFromBundle() {
        extraSkyboxLoadTask?.cancel()
        // Load skyboxes on background thread to avoid blocking main thread during view setup
        extraSkyboxLoadTask = Task.detached(priority: .background) {
            let exts = ["jpg", "jpeg", "png"]
            let builtinSet: Set<String> = ["AboveClouds", "Above_Clouds"]
            var names: [String] = []
            var textures: [TextureResource] = []
            
            for ext in exts {
                if let urls = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Skyboxes") {
                    for url in urls {
                        let base = url.deletingPathExtension().lastPathComponent
                        if builtinSet.contains(base) { continue }
                        if names.contains(base) { continue }
                        do {
                            let tex = try TextureResource.load(contentsOf: url)
                            names.append(base)
                            textures.append(tex)
                        } catch {
                            print("[Texture] Error loading \(base).\(ext): \(error)")
                        }
                    }
                }
            }
            
            // Update state on main thread once loading is complete
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.extraSkyboxNames = names
                self.extraSkyboxTextures = textures
                print("[Skybox] Loaded \(names.count) extra skyboxes in background")
                self.restoreEnvironmentTextureIfNeeded()
                self.extraSkyboxLoadTask = nil
            }
        }
    }

    /// Drop large optional GPU resources when immersive session or app backgrounds.
    /// Studio USDZ is released via `ImmersiveEnvironment`; skybox / dimmer textures are cleared here.
    private func releaseImmersiveHeavyCachesForBackground() {
        extraSkyboxLoadTask?.cancel()
        extraSkyboxLoadTask = nil
        dimmerGradientPreloadTask?.cancel()
        dimmerGradientPreloadTask = nil

        extraSkyboxTextures = []
        extraSkyboxNames = []
        builtinSkyboxTextures = [:]
        envPresetSkyboxTextures = [:]

        purpleGradientTextureColors = nil
        purpleGradientTexturePurpleBlack = nil
        eclipseGradientTexture = nil
        twilightGradientTexture = nil
        dawnGradientTexture = nil
        sunriseGradientTexture = nil
        woodlandGradientTexture = nil
        desertGradientTexture = nil
        duskHDRTexture = nil
        jpgAboveTheCloudsTexture = nil
        jpgAnimeTexture = nil
        jpgJustSkyTexture = nil
        jpgNightTimeTexture = nil
        jpgTest1Texture = nil
        jpgTest2Texture = nil
        jpgTest3Texture = nil
        moonlightMaterial = nil
        cachedReactiveMaterial = nil
        environmentFadeTimer?.invalidate()

        if let dome = environmentDome, let mesh = dome.model?.mesh {
            var clearMat = UnlitMaterial(color: .clear)
            clearMat.blending = .transparent(opacity: 1.0)
            dome.model = ModelComponent(mesh: mesh, materials: [clearMat])
        }
        if let purple = dimmerDomePurple, let mesh = purple.model?.mesh {
            var m = UnlitMaterial(color: .black)
            m.blending = .transparent(opacity: 1.0)
            purple.model = ModelComponent(mesh: mesh, materials: [m])
        }

        immersiveEnvironment.unloadStudioRootFromMemory()
    }
    
    // MARK: - Stage Pinning
    
    private let STUDIO_DOCK_WIDTH_METERS: Float = 2.0
    private let STUDIO_DOCK_HEIGHT_METERS: Float = 1.5
    
    private func stageScaleForCurrentStream() -> Float {
        let baseWidth = MAX_WIDTH_METERS
        let baseHeight = max(0.001, baseWidth * screenAspect)
        let widthScale = STUDIO_DOCK_WIDTH_METERS / baseWidth
        let heightScale = STUDIO_DOCK_HEIGHT_METERS / baseHeight
        let stageScale = min(widthScale, heightScale) * 0.95
        return min(stageScale, 4.5)
    }
    
    private func pinStreamToStage() {
        guard !isPinnedToStage, !isPinningTransitioning else { return }
        guard immersiveEnvironment.environmentStateHandler.activeState != .none else {
            print("Pin requires Studio environment (not passthrough)")
            return
        }
        guard let anchor = immersiveEnvironment.dockingAnchor, anchor.scene != nil else {
            print("Stage anchor unavailable, cannot pin screen")
            return
        }
        guard screen.parent != nil else { return }
        
        lastFreeformTransform = Transform(matrix: screen.transformMatrix(relativeTo: nil))
        pinStartScale = screen.scale.x
        wasInteractiveBeforePin = isInteractive
        isInteractive = true
        
        let defaultScale: Float = 5.0
        let defaultHeight: Float = 0.75
        let targetScaleVal: Float
        if controlState.pinnedStageScale == 1.0 || abs(controlState.pinnedStageScale - 1.0) < 0.01 {
            targetScaleVal = defaultScale
            controlState.pinnedStageScale = defaultScale
        } else {
            targetScaleVal = controlState.pinnedStageScale
        }
        if abs(controlState.pinnedStageHeight - 0.0) < 0.01 {
            controlState.pinnedStageHeight = defaultHeight
        }
        pinnedStageScale = targetScaleVal
        
        let forwardOffset: Float = 0.05
        let pitchAdjustment = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let customStageTransform = Transform(
            scale: SIMD3<Float>(repeating: targetScaleVal),
            rotation: pitchAdjustment,
            translation: SIMD3<Float>(0, forwardOffset, -controlState.pinnedStageHeight)
        )
        
        isPinnedToStage = true
        isPinningTransitioning = true
        controlState.isPinnedToStage = true
        controlState.isPinningTransitioning = true
        
        let anchorMatrix = anchor.transformMatrix(relativeTo: nil)
        let worldTarget = Transform(matrix: anchorMatrix * customStageTransform.matrix)
        
        screen.move(to: worldTarget, relativeTo: nil, duration: 1.5, timingFunction: .easeInOut)
        
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_550_000_000)
            guard isPinnedToStage else { return }
            screen.setParent(anchor, preservingWorldTransform: true)
            screen.transform = customStageTransform
            isPinningTransitioning = false
            controlState.isPinningTransitioning = false
        }
    }
    
    private func unpinStreamFromStage(animated: Bool) {
        guard isPinnedToStage else { return }
        if isPinningTransitioning && animated { return }
        
        let targetTransform = lastFreeformTransform ?? Transform(matrix: screen.transformMatrix(relativeTo: nil))
        
        let completeUnpin: @MainActor () -> Void = { [self] in
            isPinnedToStage = false
            isPinningTransitioning = false
            isInteractive = wasInteractiveBeforePin
            pinStartScale = screenScale
            controlState.isPinnedToStage = false
            controlState.isPinningTransitioning = false
        }
        
        isPinningTransitioning = true
        controlState.isPinningTransitioning = true
        
        if let originalParent = screenOriginalParent {
            screen.setParent(originalParent, preservingWorldTransform: true)
        } else {
            screen.setParent(nil, preservingWorldTransform: true)
        }
        
        if animated {
            screen.move(to: targetTransform, relativeTo: nil, duration: 1.0, timingFunction: .easeInOut)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                completeUnpin()
            }
        } else {
            screen.transform = targetTransform
            Task { @MainActor in
                completeUnpin()
            }
        }
    }
    
    // MARK: - Settings Persistence
    
    private func saveRealityKitSettings() {
        guard viewModel.streamSettings.rememberStreamSettings else { return }
        let defaults = UserDefaults.standard
        if isImmersive {
            defaults.set(screenScale, forKey: "realitykitImmersiveScale")
            defaults.set(screenPosition.x, forKey: "realitykitImmersivePosX")
            defaults.set(screenPosition.y, forKey: "realitykitImmersivePosY")
            defaults.set(screenPosition.z, forKey: "realitykitImmersivePosZ")
            defaults.set(immersionAmount, forKey: "realitykitImmersionAmount")
            defaults.set(controlState.pinnedStageScale, forKey: "realitykitPinnedStageScale")
            defaults.set(controlState.pinnedStageHeight, forKey: "realitykitPinnedStageHeight")
            defaults.set(controlState.isInteractive, forKey: kImmersiveLockedKey)
            defaults.set(viewModel.streamSettings.realitykitRendererCurvature, forKey: "realitykitImmersiveCurvature")
            defaults.set(viewModel.streamSettings.gamma, forKey: "realitykitImmersiveGamma")
            defaults.set(viewModel.streamSettings.saturation, forKey: "realitykitImmersiveSaturation")
            defaults.set(viewModel.streamSettings.brightness, forKey: "realitykitImmersiveBrightness")
            defaults.set(viewModel.streamSettings.pqExposure, forKey: "realitykitImmersivePqExposure")
        } else {
            defaults.set(volumeHeight, forKey: "realitykitHeight")
            defaults.set(volumeDepthOffset, forKey: "realitykitDepthOffset")
        }
        viewModel.streamSettings.save()
    }
}

// VolumetricWindowControls removed - volume mode now uses VolumeControlPanelView on-screen

// MARK: - Notification Extensions

extension Notification.Name {
    static let mainViewWindowClosed = Notification.Name("MainViewWindowClosed")
    static let resumeStreamFromMenu = Notification.Name("ResumeStreamFromMenu")
    static let rkStreamDidTeardown = Notification.Name("RKStreamDidTeardown")
    static let immersiveScreenWakeRequested = Notification.Name("ImmersiveScreenWakeRequested")
}
