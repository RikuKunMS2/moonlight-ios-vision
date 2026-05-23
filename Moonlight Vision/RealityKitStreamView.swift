//
//  RealityKitStreamView.swift
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2).
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Moonlight Vision - Immersive streaming view
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
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
import AudioToolbox


struct RealityKitStreamView: View {
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
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
            ZStack {
                Color.black
                    .ignoresSafeArea()
                
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.32))
                    Text(viewModel.localized("stream_stopped"))
                        .font(.title)
                        .bold()
                        .foregroundStyle(.white)
                    Text("The stream window could not be automatically resumed.")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.8))
                    
                    Button {
                        redirectZombieToMainMenu()
                    } label: {
                        Label(viewModel.localized("open_main_menu"), systemImage: "house.fill")
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 16)
                }
            }
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
    @Environment(\.dismiss) private var dismiss
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
    @State private var streamOpQueue = OperationQueue()
    @State private var controllerSupport: ControllerSupport?
    @StateObject var connectionCallbacks: ObservableConnectionManager = .init()
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
    @State private var stagePinnedEntity: Entity? = nil
    
    @State private var ambilightTexture: TextureResource?
    @State private var isPinnedToStage = false
    @State private var isPinningTransitioning = false
    @State private var lastFreeformTransform: Transform?
    @State private var wasInteractiveBeforePin = false
    @State private var pinStartScale: Float = 1.0
    @State private var pinnedStageScale: Float = 1.0
    @State private var screenOriginalParent: Entity?
    @State private var screen: ModelEntity = ModelEntity()
    @State private var immersiveDragBar: ModelEntity = ModelEntity()
    @State private var resizeHandle: ModelEntity = ModelEntity()
    @State private var resizeHandleLeft: ModelEntity = ModelEntity()
    @State private var focusCatcherEntity: ModelEntity = ModelEntity()
    @State private var ambilightLayers: [ModelEntity] = []
    @State private var isInteractive = false
    // Immersive transform (synced with controlState)
    @State private var immersionAmount: Float = 0.0
    // Control panel entity
    @State private var controlPanelEntity: Entity?
    
    @State private var texture: TextureResource
    @State private var videoMode: VideoMode = .standard2D
    @State private var surfaceMaterial: ShaderGraphMaterial?
    
    @State private var curveAnimationMultiplier: Float = 1.0
    @State private var animationTimer: Timer?
    
    @State private var sliderCurvature: Float = 0.0
    @State private var tiltAngle: Float = 0.0
    @State private var tiltDirection: Int = 1
    
    @State private var screenPosition: SIMD3<Float> = SIMD3<Float>(0, 1.0, -1.5)  // Match StreamControlState: x=0, y=1.0, z=-1.5 (viewing 1.5m)
    @State private var screenScale: Float = 0.8
    @State private var needsInitialRecenter: Bool = true
    @State private var backgroundTeardownWorkItem: DispatchWorkItem?
    @State private var isLocked: Bool = false
    @State private var startDragPosition: SIMD3<Float>? = nil
    @State private var startDragGestureScenePosition: SIMD3<Float>? = nil
    @State private var lastDragGestureScenePosition: SIMD3<Float>? = nil
    @State private var lastDragSampleTime: CFTimeInterval = 0
    @State private var dragReleaseVelocity: SIMD3<Float> = .zero
    @State private var inertiaUpdateSubscription: EventSubscription?
    @State private var inertiaVelocity: SIMD3<Float> = .zero
    @State private var hasInitializedPosition = false
    
    @State private var safeHDRSettings = ThreadSafeHDRSettings(
        params: HDRParams(boost: 1.0, contrast: 1.0, saturation: 1.0, brightness: 0.0, pqExposure: 1.0, mode: 0)
    )
    @StateObject private var hdrParams = HDRTestParams()
    @StateObject private var controllerMouseManager = ControllerInputManager()

    @State private var showVirtualKeyboard = false
    @State private var hideControls: Bool = false
    @State private var isMouseCaptureActive: Bool = false
    
    // Keyboard Override State
    @State private var keyboardInput: String = ""
    @State private var previousKeyboardInput: String = ""
    @FocusState private var isKeyboardFocused: Bool
    
    @State private var hideTimer: Timer?
    @State private var controlsEntity: Entity?
    @State private var shouldClose = false
    @FocusState private var isInputFocused: Bool
    @State private var hasPerformedTeardown = false
    @State private var needsResume = false
    // spatialAudioMode is now in viewModel.streamSettings.spatialAudioMode
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
    @State private var arkitSession = ARKitSession()
    @State private var worldTrackingProvider = WorldTrackingProvider()
    @State private var isWorldTrackingRunning = false
    @State private var lastKnownHeadWorldPosition: SIMD3<Float>?
    @State private var lastKnownHeadForward: SIMD3<Float>?
    @State private var isDragFacingCatchupActive = false
    @State private var dragFacingCatchupStartTime: CFTimeInterval = 0
    @State private var dragFacingCatchupFromRotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    @State private var dragFacingCatchupToRotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    @State private var dragFacingCatchupTimer: Timer?
    @State private var isScreenMoveDragging = false
    @State private var dragFacingFollowTimer: Timer?
    @State private var lastScreenMoveReleaseTime: CFTimeInterval = 0
    @State private var lastDragFacingCatchupStartTime: CFTimeInterval = 0
    @State private var isDragBarPinching = false
    @State private var isDragBarScaleAnimating = false
    @State private var isResizeHandlePinching = false
    @State private var isResizeHandleLeftPinching = false
    @State private var isResizeHandleScaleAnimating = false
    @State private var resizeStartScale: Float = 0.8
    @State private var resizeStartScreenPos: SIMD3<Float>?
    @State private var resizeStartGesturePos: SIMD3<Float>?
    @State private var lastSwitchToControllerTime: CFTimeInterval = 0
    
    private let attachmentLayoutAspectBox = MutableBox<Float>(-1)
    private let dragFacingCatchupDuration: CFTimeInterval = 0.36
    private let dragFacingFollowReleaseGraceDuration: CFTimeInterval = 0.13
    private let dragInertiaDecelerationPerSecond: Float = 6.5
    private let dragInertiaStopSpeed: Float = 0.015
    private let headCollisionRadius: Float = 0.42
    private let headCollisionRestitution: Float = 0.18
    private let headCollisionTangentialDamping: Float = 0.74
    private let headCollisionPushoutLerp: Float = 0.32
    private let headCollisionSoftLayerDepth: Float = 0.08
    private let headCollisionSpringStrength: Float = 10.0
    private let autoPitchGazeCompensation: Float = 0.42
    private let autoPitchDeadZoneRadians: Float = (.pi / 180.0) * 3.0
    private let autoPitchSoftZoneRadians: Float = (.pi / 180.0) * 14.0
    private let autoPitchInnerGainUp: Float = 0.34
    private let autoPitchInnerGainDown: Float = 0.30
    private let autoPitchOuterGainUp: Float = 0.54
    private let autoPitchOuterGainDown: Float = 0.48
    private let autoPitchHeightBoostStartMeters: Float = 0.22
    private let autoPitchHeightBoostEndMeters: Float = 1.10
    private let autoPitchHeightGainBoost: Float = 0.58
    private let autoPitchMinDeadZoneRadians: Float = (.pi / 180.0) * 1.0
    
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
    @State private var hintOverlayText2: String = ""
    @State private var hintOverlayIcon2: String = ""
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
    private var immersiveDragBarLength: Float { 0.22 }
    private var immersiveDragBarThickness: Float { 0.014 }
    private var immersiveDragBarDepth: Float { 0.001 }
    private var immersiveDragBarIdleOpacity: Float { 1.0 }
    private var immersiveDragBarHoverOpacity: Float { 0.88 }
    private var immersiveDragBarPinchOpacity: Float { 1.0 }
    private var immersiveDragBarIdleTint: Float { 0.50 }
    private var immersiveDragBarHoverTint: Float { 0.96 }
    private var immersiveDragBarPinchTint: Float { immersiveDragBarHoverTint }
    private var resizeHandleThickness: Float { 0.014 }
    private var resizeHandleIdleTint: Float { 0.45 }
    private var resizeHandlePinchTint: Float { 0.96 }
    private var resizeHandleIdleOpacity: Float { 0.0 }
    private var resizeHandlePinchOpacity: Float { 1.0 }

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
                        print("Suspending stream due to background (debounced 1.5s)")
                        needsResume = true
                        let workItem = DispatchWorkItem {
                            guard self.needsResume else { return }
                            self.renderGateOpen = false
                            let sm = self.streamMan
                            self.streamMan = nil
                            self.controllerSupport?.cleanup()
                            self.controllerSupport = nil
                            sm?.stopStream(completion: {
                                DispatchQueue.main.async {
                                    AudioHelpers.resetAudioSession()
                                }
                            })
                        }
                        backgroundTeardownWorkItem = workItem
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
                    }
                } else if newValue == .active {
                    // Cancel pending teardown if we came back quickly (e.g. notification
                    // banner, brief crown press). The stream is still running, so just
                    // reset the resume flag.
                    if let workItem = backgroundTeardownWorkItem {
                        workItem.cancel()
                        backgroundTeardownWorkItem = nil
                        needsResume = false
                    }
                    if isImmersive,
                       selectedEnvironmentState != .none,
                       !immersiveEnvironment.isLoaded,
                       !immersiveEnvironment.isLoading {
                        immersiveEnvironment.loadEnvironment()
                    }
                    if needsResume {
                        print("Resuming stream from background")
                        needsResume = false
                        // Digital-crown return shifts world tracking origin — recenter
                        // the screen in front of the user on the next RealityView update.
                        if isImmersive { needsInitialRecenter = true }
                        self.renderGateOpen = true
                        controllerSupport = ControllerSupport(config: streamConfig, delegate: DummyControllerDelegate())
                        connectionCallbacks.controllerSupport = controllerSupport
                        if viewModel.streamSettings.controllerMouseMode {
                            controllerSupport?.disableControllerCallbacks()
                            controllerSupport?.controllerMouseMode = true
                            controllerMouseManager.mouseSpeed = viewModel.streamSettings.controllerMouseSpeed
                            controllerMouseManager.start()
                        }
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
                            if viewModel.streamSettings.controllerMouseMode {
                                controllerSupport?.disableControllerCallbacks()
                                controllerSupport?.controllerMouseMode = true
                                controllerMouseManager.mouseSpeed = viewModel.streamSettings.controllerMouseSpeed
                                controllerMouseManager.start()
                            }
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
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("HardwareInputDetected"))) { _ in
                // Mark physical input activity so hand-pinch detection knows a real device is in use
                GlobalInputState.shared.lastPhysicalMouseActivityTime = CACurrentMediaTime()
                let isMouse = GCMouse.mice().count > 0
                if inputMode != .controller {
                    inputMode = .controller
                    lastSwitchToControllerTime = CACurrentMediaTime()
                    UserDefaults.standard.set(inputMode.rawValue, forKey: "immersiveInputMode")
                    // Show both mouse + gamepad modes in the hint overlay
                    showDualHint(
                        text: viewModel.localized("input_mode_mouse"),
                        icon: "cursorarrow.and.square.on.square.dashed",
                        text2: viewModel.localized("input_mode_controller"),
                        icon2: "gamecontroller.fill"
                    )
                    updateScreenInteractivity()
                    startHighlightTimer()
                    startHideTimer()
                }
                // Enter mouse capture mode only when controller mouse mode is off —
                // controller mouse mode users want to see the UI while using the sticks.
                if isImmersive && isMouse && !isMouseCaptureActive
                    && !viewModel.streamSettings.fpsMouseCapture
                    && !viewModel.streamSettings.controllerMouseMode {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isMouseCaptureActive = true
                    }
                    hideTimer?.invalidate()
                    hideTimer = nil
                    hideControls = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("HandPinchDetected"))) { _ in
                // Only allow hand-pinch switch back after 0.5 s since entering
                // controller mode — prevents the physical joystick/button press
                // from racing with hand-tracking pinch detection. Using mode-
                // switch time (not hardware activity time) avoids being blocked
                // by idle stick drift.
                let timeSinceSwitch = CACurrentMediaTime() - lastSwitchToControllerTime
                if inputMode == .controller && !viewModel.streamSettings.fpsMouseCapture && timeSinceSwitch > 0.5 {
                    inputMode = .gazeControl
                    UserDefaults.standard.set(inputMode.rawValue, forKey: "immersiveInputMode")
                    let text = (viewModel.streamSettings.gazeTouchMode) ? viewModel.localized("input_mode_touch") : viewModel.localized(inputMode.localizedKey)
                    let icon: String
                    if viewModel.streamSettings.gazeTouchMode { icon = "hand.point.up.left.fill" }
                    else { icon = "eye" }
                    showInlineHint(text: text, icon: icon)
                    updateScreenInteractivity()
                    startHighlightTimer()
                    startHideTimer()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidDisconnect)) { _ in
                if isMouseCaptureActive && GCMouse.mice().count == 0 {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isMouseCaptureActive = false
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
                if viewModel.streamSettings.controllerMouseMode {
                    // Re-block: ControllerSupport's own GCControllerDidConnect observer
                    // re-registers gamepad callbacks on newly connected controllers.
                    controllerSupport?.disableControllerCallbacks()
                    if !controllerMouseManager.isActive {
                        controllerMouseManager.mouseSpeed = viewModel.streamSettings.controllerMouseSpeed
                        controllerMouseManager.start()
                    }
                }
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
            .onChange(of: inputMode) { oldValue, newValue in
                if oldValue == .gazeControl && newValue != .gazeControl {
                    gazeController.cleanup()
                }
                UserDefaults.standard.set(newValue.rawValue, forKey: "immersiveInputMode")
                updateScreenInteractivity()
                // Mouse capture mode: exit when leaving controller mode.
                // Enter when switching to controller with a physical mouse connected,
                // unless controller mouse mode is active (user wants visible UI with sticks).
                if newValue != .controller {
                    if isMouseCaptureActive {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isMouseCaptureActive = false
                        }
                        startHideTimer()
                    }
                } else if newValue == .controller && isImmersive
                            && GCMouse.mice().count > 0
                            && !viewModel.streamSettings.fpsMouseCapture
                            && !viewModel.streamSettings.controllerMouseMode {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isMouseCaptureActive = true
                    }
                }
            }
            .onChange(of: viewModel.streamSettings.swapABXYButtons) { _, newValue in
                controllerSupport?.setSwapABXYButtons(newValue)
            }
        
        // Split into a second chain to help the type checker
        let controlStateSyncedPart1 = stateChangesApplied
            .onChange(of: tiltAngle) { _, newValue in
                controlState.tiltAngle = newValue
            }
            .onChange(of: viewModel.streamSettings.realitykitAutoPitchFollow) { _, enabled in
                if enabled {
                    tiltAngle = 0.0
                    controlState.tiltAngle = 0.0
                    viewModel.streamSettings.realitykitRendererTilt = 0.0
                }
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
                withAnimation(.interpolatingSpring(stiffness: 50, damping: 20)) {
                    screenPosition.y = newValue
                }
            }
            .onChange(of: controlState.immersivePositionZ) { _, newValue in
                guard !isPinnedToStage else { return }
                withAnimation(.interpolatingSpring(stiffness: 50, damping: 20)) {
                    screenPosition.z = newValue
                }
            }
            .onChange(of: controlState.immersionAmount) { _, newValue in
                immersionAmount = newValue
            }
            .onChange(of: controlState.tiltAngle) { _, newValue in
                tiltAngle = newValue
                viewModel.streamSettings.realitykitRendererTilt = newValue
            }
            .onChange(of: controlState.dimLevel) { _, newValue in
                if dimLevel != newValue {
                    dimLevel = newValue
                    viewModel.streamSettings.dimPassthrough = (newValue != 0)
                    UserDefaults.standard.set(newValue, forKey: "ambient.dimming.level")
                    updateDimmerDomesState()
                }
            }
            // When user closes control panel after enabling controller mouse mode,
            // enter mouse capture to hide UI and keep just the screen + input overlay.
            .onChange(of: controlState.isControlPanelVisible) { _, visible in
                // Let ControllerInputManager know so it can suppress A-button
                // mouse click while the control panel is open.
                controllerMouseManager.isControlPanelOpen = visible
                if !visible && isImmersive && viewModel.streamSettings.controllerMouseMode && !isMouseCaptureActive {
                    inputMode = .controller
                    lastSwitchToControllerTime = CACurrentMediaTime()
                    UserDefaults.standard.set(inputMode.rawValue, forKey: "immersiveInputMode")
                    updateScreenInteractivity()
                    startHighlightTimer()
                    startHideTimer()
                }
            }

        let controlStateSynced = controlStateSyncedPart1
            .onChange(of: controlState.isCalibrationModeActive) { _, _ in
                if viewModel.streamSettings.enableHdr { updateHDRParams() }
            }
            .onChange(of: viewModel.streamSettings.controllerMouseMode) { _, enabled in
                if enabled {
                    // Persist immediately so ControllerSupport.init reads the
                    // correct value when recreating after scenePhase transitions.
                    UserDefaults.standard.set(true, forKey: "controllerMouseMode")
                    // Kill ControllerSupport's gamepad handlers so it stops forwarding
                    // gamepad events to the host — sticks/triggers/buttons are mapped to
                    // mouse events by ControllerInputManager instead.
                    controllerSupport?.disableControllerCallbacks()
                    controllerSupport?.controllerMouseMode = true
                    controllerMouseManager.mouseSpeed = viewModel.streamSettings.controllerMouseSpeed
                    controllerMouseManager.start()
                    if inputMode != .controller {
                        inputMode = .controller
                        lastSwitchToControllerTime = CACurrentMediaTime()
                        UserDefaults.standard.set(inputMode.rawValue, forKey: "immersiveInputMode")
                        updateScreenInteractivity()
                        startHighlightTimer()
                        startHideTimer()
                    }
                } else {
                    // Persist immediately so ControllerSupport.init reads the
                    // correct value when recreating below.
                    UserDefaults.standard.set(false, forKey: "controllerMouseMode")
                    controllerMouseManager.stop()
                    controllerSupport?.controllerMouseMode = false
                    // Recreate ControllerSupport to re-register gamepad handlers
                    controllerSupport?.cleanup()
                    controllerSupport = ControllerSupport(config: streamConfig, delegate: DummyControllerDelegate())
                    connectionCallbacks.controllerSupport = controllerSupport
                }
            }
            .onChange(of: viewModel.streamSettings.controllerMouseSpeed) { _, speed in
                controllerMouseManager.mouseSpeed = speed
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ToggleControlPanel"))) { _ in
                // Exit mouse capture mode so panel can display
                if isMouseCaptureActive {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isMouseCaptureActive = false
                    }
                }
                // Ensure controls are visible
                hideControls = false
                controlsHighlighted = true
                startHighlightTimer()
                startHideTimer()
                // Show the control panel
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    controlState.isControlPanelVisible = true
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
            .onChange(of: viewModel.streamSettings.reactiveLightingEnabled) { _, newValue in
                updateDimmerDomesState()
                updateScreenMaterial()
                if newValue {
                    stopMoonlightCycle()
                    startReactiveLerp()
                } else if dimLevel != 2 && dimLevel != 10 && dimLevel != 13 {
                    stopReactiveLerp()
                }
            }
            .onChange(of: firstFrameReceived) { _, _ in 
                updateScreenMaterial() 
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
        if showScaleHUD && !isMouseCaptureActive {
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
        if hideControls && !isMouseCaptureActive {
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
            Attachment(id: "controls") {
                screenDockBar
                    .opacity(isMouseCaptureActive ? 0 : 1)
                    .allowsHitTesting(!isMouseCaptureActive)
                    .animation(.easeInOut(duration: 0.25), value: isMouseCaptureActive)
            }
            Attachment(id: "controlPanel") {
                if controlState.isControlPanelVisible && !isMouseCaptureActive {
                    if isImmersive {
                        ImmersiveControlPanelView(inputMode: $inputMode)
                            .environmentObject(viewModel)
                            .environmentObject(controlState)
                    } else {
                        VolumeControlPanelView(
                            // openWindow — pushWindow is only valid for Plain/Default WindowGroup;
                            // volumetric streaming windows trigger "PushWindowAction requires…" and can crash.
                            homeAction: { 
                                viewModel.isHidingForResume = true
                                viewModel.savedStreamConfigForResume = streamConfig
                                openWindow(id: "mainView")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    dismissWindow(id: "realitykitStreamingWindow")
                                }
                            },
                            closeAction: {
                                viewModel.savedStreamConfigForResume = nil
                                needsResume = false
                                hasPerformedTeardown = false
                                viewModel.streamState = .stopping
                                triggerCloseSequence()
                            },
                            toggleKeyboardAction: { showVirtualKeyboard.toggle() },
                            isKeyboardActive: showVirtualKeyboard,
                            inputMode: $inputMode,
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
            Attachment(id: "presetPopup") {
                CenterHintOverlay(text: hintOverlayText, icon: hintOverlayIcon,
                                 text2: hintOverlayText2, icon2: hintOverlayIcon2)
                    .opacity(showInlineHint ? 1.0 : 0.0)
                    .scaleEffect(showInlineHint ? 1.0 : 0.95)
                    .animation(.easeOut(duration: 0.15), value: showInlineHint)
            }
            Attachment(id: "dimPicker") {
                dimmingPickerAttachment
                    .opacity(isMouseCaptureActive ? 0 : 1)
            }
            Attachment(id: "stats") {
                statsAttachment
                    .opacity(isMouseCaptureActive ? 0 : 1)
            }
            Attachment(id: "keyboardAndModifiers") {
                PCModifierToolbar {
                    TextField("", text: $keyboardInput)
                        .focused($isKeyboardFocused)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(width: 180)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .opacity(0.7)
                        )
                        .onSubmit {
                            print("[Keyboard] Submit detected, sending Return key and closing keyboard")
                            let hidReturn = Int16(bitPattern: 0x8000 | 0x0D)
                            LiSendKeyboardEvent(hidReturn, 0x03, 0)
                            let swiftUICleanup = {
                                showVirtualKeyboard = false
                                isKeyboardFocused = false
                                keyboardInput = ""
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                LiSendKeyboardEvent(hidReturn, 0x04, 0)
                                swiftUICleanup()
                            }
                            previousKeyboardInput = ""
                        }
                        .onChange(of: keyboardInput) { _, newValue in
                            handleKeyboardInput(newValue)
                        }
                }
                .opacity((showVirtualKeyboard && !isMouseCaptureActive) ? 1.0 : 0.0)
                .scaleEffect((showVirtualKeyboard && !isMouseCaptureActive) ? 1.0 : 0.95)
                .animation(.easeOut(duration: 0.2), value: showVirtualKeyboard)
                .allowsHitTesting(showVirtualKeyboard && !isMouseCaptureActive)
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
        .simultaneousGesture(TapGesture().onEnded {
            guard viewModel.activelyStreaming && !showMenuPanel && !isMouseCaptureActive else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                hideControls = false
                controlsHighlighted = true
            }
            startHighlightTimer()
            let currentMode = SpatialAudioMode(rawValue: viewModel.streamSettings.spatialAudioMode) ?? .window
            AudioHelpers.applySpatialAudioMode(currentMode)
        })
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

        // Kick off stream (internally defers heavy work with asyncAfter)
        startStreamIfNeeded()
        startWorldTrackingIfNeeded()

        // Dismiss windows synchronously (no @State involved)
        dismissWindow(id: "mainView")
        dismissWindow(id: "dummy")

        // Defer all @State mutations to next runloop to avoid
        // "Modifying state during view update" — onAppear fires mid-update-pass.
        DispatchQueue.main.async { [self] in
            print("[StreamView] Re-initializing ControllerSupport with slotOffset: \(streamConfig.controllerSlotOffset)")
            self.controllerSupport = ControllerSupport(config: streamConfig, delegate: DummyControllerDelegate())
            connectionCallbacks.controllerSupport = self.controllerSupport
            if self.viewModel.streamSettings.controllerMouseMode {
                self.controllerSupport?.disableControllerCallbacks()
                self.controllerSupport?.controllerMouseMode = true
                self.controllerMouseManager.mouseSpeed = self.viewModel.streamSettings.controllerMouseSpeed
                self.controllerMouseManager.start()
            }
            connectionCallbacks.showAlert = false
            gazeController.streamConfig = streamConfig

            hasPerformedTeardown = false
            renderGateOpen = true
            lastStreamErrorMessage = nil

            isMenuOpen = false
            controlState.isControlPanelVisible = false

            viewModel.streamSettings.statsOverlay = false
            statsTimer?.invalidate()
            statsTimer = nil
            statsOverlayText = ""

            dimLevel = 0
            viewModel.streamSettings.dimPassthrough = false

            self.targetScale = self.screenScale
            if viewModel.streamSettings.realitykitAutoPitchFollow {
                self.tiltAngle = 0.0
                viewModel.streamSettings.realitykitRendererTilt = 0.0
            } else {
                self.tiltAngle = viewModel.streamSettings.realitykitRendererTilt
            }

            // Initialize input mode from user preference (default: gaze control)
            if UserDefaults.standard.object(forKey: "immersive.defaultControlMode") == nil {
                inputMode = .gazeControl
            } else {
                let defaultMode = UserDefaults.standard.integer(forKey: "immersive.defaultControlMode")
                inputMode = InputMode(rawValue: defaultMode) ?? .gazeControl
            }
            
            print("[StreamView] Initialized input mode from settings: \(inputMode.displayName)")

            // Spatial audio is read from streamSettings, no need to reset it here

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
                recreateStreamTexture()
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
            // In immersive mode, "Home" should open the main menu and hide the stream
            viewModel.isHidingForResume = true
            viewModel.savedStreamConfigForResume = streamConfig
            openWindow(id: "mainView")
            Task { await dismissImmersiveSpace() }
        }
        controlState.closeAction = { [self] in
            viewModel.savedStreamConfigForResume = nil
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
        isDragBarPinching = false
        isDragBarScaleAnimating = false
        isResizeHandlePinching = false
        isResizeHandleLeftPinching = false
        isResizeHandleScaleAnimating = false
        resizeStartGesturePos = nil
        resizeStartScreenPos = nil
        isScreenMoveDragging = false
        stopDragFacingFollowTimer()
        stopDragFacingCatchupTimer()
        stopInertiaMotion()
        inertiaUpdateSubscription?.cancel()
        inertiaUpdateSubscription = nil
        stopWorldTracking()
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
    
    /// Unified drag gesture: both drag-bar screen move and gaze click are handled in gazeControl mode.
    var unifiedDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)  // 0 for instant gaze response
            .targetedToAnyEntity()
            .onChanged { value in
                isInputFocused = true
                guard !viewModel.streamSettings.fpsMouseCapture else { return }

                switch inputMode {
                case .gazeControl:
                    // Dragging the immersive drag bar → screen move
                    if isImmersive, !isPinnedToStage, value.entity === immersiveDragBar {
                        if controlState.isInteractive { return }
                        _ = refreshHeadWorldPosition()
                        stopInertiaMotion()
                        hideTimer?.invalidate()
                        let currentGestureScenePoint = value.convert(value.location3D, from: .local, to: .scene)
                        let currentGestureScenePosition = simd_float3(
                            currentGestureScenePoint.x,
                            currentGestureScenePoint.y,
                            currentGestureScenePoint.z
                        )
                        if startDragPosition == nil {
                            startDragPosition = screenPosition
                            startDragGestureScenePosition = currentGestureScenePosition
                            lastDragGestureScenePosition = currentGestureScenePosition
                            lastDragSampleTime = CACurrentMediaTime()
                            dragReleaseVelocity = .zero
                            isDragBarPinching = true
                            isDragBarScaleAnimating = true
                            AudioServicesPlaySystemSound(1104)
                            isScreenMoveDragging = true
                            startDragFacingFollowTimer()
                            startDragFacingCatchupIfNeeded()
                        }
                        guard let startDragPosition, let startDragGestureScenePosition else { return }
                        let delta = currentGestureScenePosition - startDragGestureScenePosition
                        var proposed = startDragPosition + delta
                        proposed.x = min(max(proposed.x, -allowedLateralMax), allowedLateralMax)
                        screenPosition = proposed
                        let now = CACurrentMediaTime()
                        if let lastPos = lastDragGestureScenePosition {
                            let dt = Float(max(now - lastDragSampleTime, 1e-3))
                            let instantVelocity = (currentGestureScenePosition - lastPos) / dt
                            dragReleaseVelocity = dragReleaseVelocity * 0.55 + instantVelocity * 0.45
                        }
                        lastDragGestureScenePosition = currentGestureScenePosition
                        lastDragSampleTime = now
                        applyFacingRotationIfNeeded()
                        lastDragTime = CACurrentMediaTime()
                        return
                    }
                    // Dragging either resize handle → scale change
                    if isImmersive, !isPinnedToStage, (value.entity === resizeHandle || value.entity === resizeHandleLeft) {
                        if controlState.isInteractive { return }
                        hideTimer?.invalidate()
                        let currentGestureScenePoint = value.convert(value.location3D, from: .local, to: .scene)
                        let currentGestureScenePosition = simd_float3(
                            currentGestureScenePoint.x,
                            currentGestureScenePoint.y,
                            currentGestureScenePoint.z
                        )
                        if resizeStartGesturePos == nil {
                            resizeStartScale = screenScale
                            resizeStartScreenPos = screenPosition
                            resizeStartGesturePos = currentGestureScenePosition
                            if value.entity === resizeHandleLeft {
                                isResizeHandleLeftPinching = true
                            } else {
                                isResizeHandlePinching = true
                            }
                            isResizeHandleScaleAnimating = true
                            showScaleHUD = true
                        }
                        guard let startGesturePos = resizeStartGesturePos else { return }
                        let screenWorldPos = screen.position(relativeTo: nil)
                        let initialDist = simd_length(startGesturePos - screenWorldPos)
                        let currentDist = simd_length(currentGestureScenePosition - screenWorldPos)
                        guard initialDist > 0.001 else { return }
                        let ratio = currentDist / initialDist
                        var proposed = resizeStartScale * ratio
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
                        return
                    }
                    // Not the drag bar or resize handle → gaze click on screen
                    guard value.entity === screen else { return }
                    let uv = hitToUV(value)
                    if !gazeController.pinchActive {
                        gazeController.onPinchBegan(at: uv)
                    } else {
                        gazeController.onPinchChanged(at: uv)
                    }

                case .controller:
                    break  // Let input fall through to InputCaptureView
                }
            }
            .onEnded { _ in
                guard !viewModel.streamSettings.fpsMouseCapture else { return }

                switch inputMode {
                case .gazeControl:
                    if isScreenMoveDragging {
                        startDragPosition = nil
                        startDragGestureScenePosition = nil
                        lastDragGestureScenePosition = nil
                        isDragBarPinching = false
                        isScreenMoveDragging = false
                        lastScreenMoveReleaseTime = CACurrentMediaTime()
                        startInertiaMotionIfNeeded()
                        controlsHighlighted = false
                        startHighlightTimer()
                        controlState.immersivePosition = screenPosition
                        SharePlayManager.shared.broadcastCurrentTransform()
                    }
                    if isResizeHandlePinching || isResizeHandleLeftPinching {
                        resizeStartGesturePos = nil
                        resizeStartScreenPos = nil
                        isResizeHandlePinching = false
                        isResizeHandleLeftPinching = false
                        controlState.immersiveScale = screenScale
                        scaleHUDFadeTimer?.invalidate()
                        scaleHUDFadeTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
                            withAnimation(.easeOut(duration: 0.25)) {
                                showScaleHUD = false
                            }
                        }
                        controlsHighlighted = false
                        startHighlightTimer()
                        SharePlayManager.shared.broadcastCurrentTransform()
                    }
                    if gazeController.pinchActive {
                        gazeController.onPinchEnded()
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
                SharePlayManager.shared.broadcastCurrentTransform()
            }
    }
    
    // MARK: - Gaze Control Gestures
    
    var gazeTapGesture: some Gesture {
        SpatialTapGesture()
            .targetedToEntity(screen)
            .onEnded { value in
                isInputFocused = true
                // If FPS mode is enabled, the pointer is locked and physical mouse handles clicks natively.
                // Do not fire gaze taps, otherwise the cursor snaps to the center.
                guard !viewModel.streamSettings.fpsMouseCapture else { return }
                
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
        let scenePos = value.convert(value.location3D, from: .local, to: .scene)
        let localPos = screen.convert(position: scenePos, from: nil)
        return calculateUV(localPos: localPos)
    }

    private func hitToUV(_ value: EntityTargetValue<DragGesture.Value>) -> SIMD2<Float> {
        let scenePos = value.convert(value.location3D, from: .local, to: .scene)
        let localPos = screen.convert(position: scenePos, from: nil)
        return calculateUV(localPos: localPos)
    }
    
    private func calculateUV(localPos: SIMD3<Float>) -> SIMD2<Float> {
        // Since localPos is perfectly mapped to the unscaled mesh's local coordinate space,
        // we can simply map it back using the physical constants that generated the mesh!
        let meterX = localPos.x
        let meterY = localPos.y
        
        let physicalWidth = CURVED_MAX_WIDTH_METERS // 2.0
        let physicalHeight = physicalWidth * screenAspect
        
        let curveMagnitude = effectiveCurvature
        let maxAngle = CURVED_MAX_ANGLE
        let currentAngle = maxAngle * max(0.0, min(curveMagnitude, 2.0))
        
        var u: Float = 0.5
        
        if currentAngle < 0.001 {
            // Flat Mode
            u = (meterX / physicalWidth) + 0.5
        } else {
            // Curved Mode
            let scaledRadius = physicalWidth / currentAngle
            let maxTheoreticalX = scaledRadius * sin(currentAngle / 2.0)
            
            let clampedX = max(-maxTheoreticalX, min(maxTheoreticalX, meterX))
            let theta = asin(clampedX / scaledRadius)
            
            u = (theta / currentAngle) + 0.5
        }

        // v goes from 0 (top) to 1 (bottom)
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
            SwiftUIAbsoluteMouseTracker(
                controllerSupport: support,
                showKeyboard: $showVirtualKeyboard,
                isControllerMode: inputMode == .controller,
                curvature: effectiveCurvature,
                streamConfig: streamConfig,
                headStorage: headStorage,
                fpsMouseCapture: viewModel.streamSettings.fpsMouseCapture,
                controllerMouseMode: viewModel.streamSettings.controllerMouseMode,
                isImmersive: isImmersive
            )
            .frame(
                width: (showVirtualKeyboard || inputMode == .controller) ? 1920 : 1,
                height: (showVirtualKeyboard || inputMode == .controller) ? (1920 / CGFloat(screenAspect)) : 1
            )
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .focusable()
            .focused($isInputFocused)
            .onAppear {
                isInputFocused = true
            }
            .allowsHitTesting(inputMode == .controller && !viewModel.streamSettings.fpsMouseCapture)
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
                text.withCString { base in
                    LiSendUtf8TextEvent(base, UInt32(text.utf8.count))
                }
            }
        } else if newValue.count < oldValue.count {
            // Character(s) removed - send backspace for each removed character
            let removedCount = oldValue.count - newValue.count
            for i in 0..<removedCount {
                let delayDown = Double(i) * 0.1
                let delayUp = delayDown + 0.05
                let hidBackspace = Int16(bitPattern: 0x8000 | 0x08)
                DispatchQueue.main.asyncAfter(deadline: .now() + delayDown) {
                    LiSendKeyboardEvent(hidBackspace, 0x03, 0) // Backspace Down
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delayUp) {
                    LiSendKeyboardEvent(hidBackspace, 0x04, 0) // Backspace Up
                }
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
            
            // Keyboard toggle
            Button(action: {
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
                Image(systemName: inputMode == .gazeControl ? "eye" : (GCMouse.mice().count > 0 ? "cursorarrow.and.square.on.square.dashed" : "gamecontroller"))
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

        let allCases = InputMode.allCases
        let idx = allCases.firstIndex(of: inputMode) ?? 0
        inputMode = allCases[(idx + 1) % allCases.count]

        UserDefaults.standard.set(inputMode.rawValue, forKey: "immersiveInputMode")
        if inputMode == .controller {
            showDualHint(
                text: viewModel.localized("input_mode_mouse"),
                icon: "cursorarrow.and.square.on.square.dashed",
                text2: viewModel.localized("input_mode_controller"),
                icon2: "gamecontroller.fill"
            )
        } else if inputMode == .gazeControl && viewModel.streamSettings.gazeTouchMode {
            showInlineHint(text: viewModel.localized("input_mode_touch"), icon: "hand.point.up.left.fill")
        } else {
            showInlineHint(text: viewModel.localized("input_mode_gaze"), icon: "eye")
        }
        updateScreenInteractivity()
        startHighlightTimer()
        startHideTimer()
    }
    
    private func showInlineHint(text: String, icon: String) {
        hintOverlayText = text
        hintOverlayIcon = icon
        hintOverlayText2 = ""
        hintOverlayIcon2 = ""
        showInlineHint = true
        hintOverlayTimer?.invalidate()
        hintOverlayTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { _ in
            showInlineHint = false
        }
    }

    private func showDualHint(text: String, icon: String, text2: String, icon2: String) {
        hintOverlayText = text
        hintOverlayIcon = icon
        hintOverlayText2 = text2
        hintOverlayIcon2 = icon2
        showInlineHint = true
        hintOverlayTimer?.invalidate()
        hintOverlayTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { _ in
            showInlineHint = false
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
        updateScreenMaterial()
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
            mode: isHDRPath ? (controlState.isCalibrationModeActive ? 2 : max(hdrParams.mode, 1)) : 0
        )
        safeHDRSettings.value = params
    }
    
    private func updateScreenMaterial() {
        let mat = makeVideoUnlitMaterial(self.texture)
        if videoMode == .sideBySide3D {
            if var sMat = surfaceMaterial {
                try? sMat.setParameter(name: "texture", value: .textureResource(self.texture))
                surfaceMaterial = sMat
                screen.model?.materials = [sMat]
            } else {
                screen.model?.materials = [mat]
            }
        } else {
            screen.model?.materials = [mat]
        }
        
        // Update the single Ambilight layer
        let ambAlpha = viewModel.streamSettings.dimPassthrough ? 1.0 : CGFloat(max(0.2, immersionAmount))
        for ambPlane in ambilightLayers {
            var ambMat = makeVideoUnlitMaterial(self.ambilightTexture ?? self.texture)
            ambMat.color.tint = UIColor.white.withAlphaComponent(ambAlpha)
            ambMat.blending = .transparent(opacity: 1.0)
            ambPlane.model?.materials = [ambMat]
            
            let isAmbilightEnabled = viewModel.streamSettings.reactiveLightingEnabled && firstFrameReceived
            ambPlane.components.set(OpacityComponent(opacity: isAmbilightEnabled ? 1.0 : 0.0))
            print("[Ambilight] Material updated. Opacity: \(isAmbilightEnabled ? 1.0 : 0.0) (reactiveEnabled: \(viewModel.streamSettings.reactiveLightingEnabled), firstFrameReceived: \(firstFrameReceived)). Scale: \(ambPlane.scale.x)")
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
        // Setup Focus Catcher for Pointer Lock / Hardware Input
        // A giant invisible box that fills the bounds to catch gaze, ensuring the scene
        // maintains focus when the user looks away from the screen in controller mode.
        focusCatcherEntity.components.set(OpacityComponent(opacity: 0.0))
        let focusMesh = MeshResource.generateBox(size: 1000)
        focusCatcherEntity.model = ModelComponent(mesh: focusMesh, materials: [UnlitMaterial(color: .clear)])
        focusCatcherEntity.components.set(CollisionComponent(shapes: [.generateBox(size: [1000, 1000, 1000])], isStatic: true))
        content.add(focusCatcherEntity)
        if isImmersive {
            focusCatcherEntity.isEnabled = false
        }
        
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

        if inertiaUpdateSubscription == nil {
            inertiaUpdateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                applyInertiaStep(deltaTime: Float(event.deltaTime))
                updateImmersiveDragBarLayout()
                updateImmersiveDragBarInteractionVisuals()
                updateResizeHandleLayout()
                updateResizeHandleVisuals()
            }
        }
        
        // Setup Ambilight Stack (Single layer for smooth bloom)
        if ambilightLayers.isEmpty {
            let scaleValue: Float = 1.45
            let ambPlane = ModelEntity()
            ambPlane.components.set(OpacityComponent(opacity: 1.0))
            ambPlane.scale = SIMD3<Float>(scaleValue, scaleValue, scaleValue)
            ambPlane.position = SIMD3<Float>(0, 0, -0.04)
            screen.addChild(ambPlane)
            self.ambilightLayers.append(ambPlane)
        }

        let head = AnchorEntity(.head)
        content.add(head)
        self.headAnchor = head

        if !hasInitializedPosition {
            screen.position = screenPosition
            screen.scale = [screenScale, screenScale, screenScale]
            hasInitializedPosition = true
        }
        
        if isImmersive {
            var dragBarMaterial = UnlitMaterial(color: UIColor(
                white: CGFloat(immersiveDragBarIdleTint),
                alpha: CGFloat(immersiveDragBarIdleOpacity)
            ))
            dragBarMaterial.readsDepth = false
            dragBarMaterial.writesDepth = false
            dragBarMaterial.faceCulling = .none
            dragBarMaterial.blending = .transparent(opacity: 1.0)
            let dragBarMesh = makeRoundedDragBarMesh(width: immersiveDragBarLength, height: immersiveDragBarThickness)
            immersiveDragBar = ModelEntity(
                mesh: dragBarMesh,
                materials: [dragBarMaterial]
            )
            immersiveDragBar.name = "ImmersiveWindowDragBar"
            immersiveDragBar.components.set(ModelSortGroupComponent(
                group: ModelSortGroup(depthPass: .postPass),
                order: 100
            ))
            immersiveDragBar.components.set(OpacityComponent(opacity: 1.0))
            immersiveDragBar.components.set(InputTargetComponent())
            let dragBarHitSize = SIMD3<Float>(
                immersiveDragBarLength + 0.08,
                immersiveDragBarThickness + 0.07,
                0.075
            )
            immersiveDragBar.components.set(CollisionComponent(
                shapes: [.generateBox(size: dragBarHitSize)],
                isStatic: true
            ))
            immersiveDragBar.components.set(HoverEffectComponent(.highlight(
                HoverEffectComponent.HighlightHoverEffectStyle(
                    color: .white,
                    strength: 4.0,
                    opacityFunction: .full
                )
            )))
            immersiveDragBar.components.set(GroundingShadowComponent(castsShadow: false))
            immersiveDragBar.scale = screen.scale
            screen.components.set(OpacityComponent(opacity: 1.0))
            if immersiveDragBar.parent == nil { content.add(immersiveDragBar) }
            updateImmersiveDragBarLayout()

            // Resize handle — arc that follows the screen corner radius,
            // matching visionOS native window resize handle.
            var resizeMaterial = UnlitMaterial(color: UIColor(
                white: CGFloat(resizeHandleIdleTint),
                alpha: CGFloat(resizeHandleIdleOpacity)
            ))
            resizeMaterial.readsDepth = false
            resizeMaterial.writesDepth = false
            resizeMaterial.faceCulling = .none
            resizeMaterial.blending = .transparent(opacity: 1.0)
            // Right (bottom-right) resize handle
            let resizeArcMesh = makeCornerArcMesh(
                innerRadius: 0.032,
                thickness: resizeHandleThickness
            )
            resizeHandle = ModelEntity(mesh: resizeArcMesh, materials: [resizeMaterial])
            resizeHandle.name = "ImmersiveResizeHandle"
            resizeHandle.components.set(ModelSortGroupComponent(
                group: ModelSortGroup(depthPass: .postPass),
                order: 101
            ))
            resizeHandle.components.set(OpacityComponent(opacity: 1.0))
            resizeHandle.components.set(InputTargetComponent())
            let hitSize = SIMD3<Float>(0.032 + resizeHandleThickness + 0.04,
                                       0.032 + resizeHandleThickness + 0.04,
                                       0.06)
            resizeHandle.components.set(CollisionComponent(
                shapes: [.generateBox(size: hitSize)],
                isStatic: true
            ))
            resizeHandle.components.set(HoverEffectComponent(.highlight(
                HoverEffectComponent.HighlightHoverEffectStyle(
                    color: .white,
                    strength: 6.0,
                    opacityFunction: .full
                )
            )))
            resizeHandle.components.set(GroundingShadowComponent(castsShadow: false))
            resizeHandle.scale = screen.scale
            if resizeHandle.parent == nil { content.add(resizeHandle) }

            // Left (bottom-left) resize handle — mirrored arc
            var resizeLeftMaterial = UnlitMaterial(color: UIColor(
                white: CGFloat(resizeHandleIdleTint),
                alpha: CGFloat(resizeHandleIdleOpacity)
            ))
            resizeLeftMaterial.readsDepth = false
            resizeLeftMaterial.writesDepth = false
            resizeLeftMaterial.faceCulling = .none
            resizeLeftMaterial.blending = .transparent(opacity: 1.0)
            let resizeLeftArcMesh = makeCornerArcMesh(
                innerRadius: 0.032,
                thickness: resizeHandleThickness,
                flipX: true
            )
            resizeHandleLeft = ModelEntity(mesh: resizeLeftArcMesh, materials: [resizeLeftMaterial])
            resizeHandleLeft.name = "ImmersiveResizeHandleLeft"
            resizeHandleLeft.components.set(ModelSortGroupComponent(
                group: ModelSortGroup(depthPass: .postPass),
                order: 101
            ))
            resizeHandleLeft.components.set(OpacityComponent(opacity: 1.0))
            resizeHandleLeft.components.set(InputTargetComponent())
            resizeHandleLeft.components.set(CollisionComponent(
                shapes: [.generateBox(size: hitSize)],
                isStatic: true
            ))
            resizeHandleLeft.components.set(HoverEffectComponent(.highlight(
                HoverEffectComponent.HighlightHoverEffectStyle(
                    color: .white,
                    strength: 6.0,
                    opacityFunction: .full
                )
            )))
            resizeHandleLeft.components.set(GroundingShadowComponent(castsShadow: false))
            resizeHandleLeft.scale = screen.scale
            if resizeHandleLeft.parent == nil { content.add(resizeHandleLeft) }
        }
        
        if let controls = attachments.entity(for: "controls") {
            self.controlsEntity = controls
            if controls.parent !== screen { screen.addChild(controls) }
            let screenHeight = CURVED_MAX_WIDTH_METERS * screenAspect
            controls.position = [0.0 as Float, (screenHeight / 2.0) + Float(0.08), Float(0.05)]
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
            statsEnt.position = [0.0 as Float, -(screenHeight / 2.0) - Float(0.07), Float(0.08)]
        }

        // Keyboard and PC Modifier Toolbar - unified view below screen
        if let keyboardAndModifiersEnt = attachments.entity(for: "keyboardAndModifiers") {
            if keyboardAndModifiersEnt.parent !== screen { screen.addChild(keyboardAndModifiersEnt) }
            let screenHeight = CURVED_MAX_WIDTH_METERS * screenAspect
            
            let toolbarOffset: Float = 0.12
            keyboardAndModifiersEnt.position = [0.0 as Float, -(screenHeight / 2.0) - Float(toolbarOffset), Float(0.08)]

            if showVirtualKeyboard {
                let bounds = keyboardAndModifiersEnt.visualBounds(relativeTo: screen)
                if bounds.extents.x > 0 {
                    let currentScaleX = max(keyboardAndModifiersEnt.scale.x, 0.0001)
                    let unscaledWidth = Float(bounds.extents.x) / currentScaleX
                    let desiredLocalWidth: Float = 0.65
                    let scale = desiredLocalWidth / unscaledWidth
                    keyboardAndModifiersEnt.scale = [scale, scale, scale]
                }
            } else {
                keyboardAndModifiersEnt.scale = .one
            }
        }
    }

    func updateRealityView(content: RealityViewContent, attachments: RealityViewAttachments, proxy: GeometryProxy3D) {
        // Poll gamepad state directly every frame so hardware→controller mode
        // switch is not dependent on notification delivery ordering. In gaze mode,
        // any stick/trigger/button activity instantly triggers the switch.
        // This runs on the render thread; post the notification so the existing
        // onReceive handler handles all mode-switch side effects on the main queue.
        if inputMode == .gazeControl, !viewModel.streamSettings.controllerMouseMode,
           let gamepad = GCController.controllers().first?.extendedGamepad {
            let hasActivity = abs(gamepad.leftThumbstick.xAxis.value) > 0.12 ||
                              abs(gamepad.leftThumbstick.yAxis.value) > 0.12 ||
                              abs(gamepad.rightThumbstick.xAxis.value) > 0.12 ||
                              abs(gamepad.rightThumbstick.yAxis.value) > 0.12 ||
                              gamepad.leftTrigger.value > 0.15 ||
                              gamepad.rightTrigger.value > 0.15 ||
                              gamepad.buttonA.isPressed ||
                              gamepad.buttonB.isPressed ||
                              gamepad.buttonX.isPressed ||
                              gamepad.buttonY.isPressed ||
                              gamepad.leftShoulder.isPressed ||
                              gamepad.rightShoulder.isPressed ||
                              gamepad.dpad.up.isPressed ||
                              gamepad.dpad.down.isPressed ||
                              gamepad.dpad.left.isPressed ||
                              gamepad.dpad.right.isPressed
            if hasActivity {
                NotificationCenter.default.post(name: Notification.Name("HardwareInputDetected"), object: nil)
            }
        }

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
        
        // Disable shadow casting on the front video entity when reactive lighting is on
        if viewModel.streamSettings.reactiveLightingEnabled {
            screen.components.set(GroundingShadowComponent(castsShadow: false))
        } else {
            screen.components.remove(GroundingShadowComponent.self)
        }
        
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
                
                // Update mesh for the Ambilight layer
                for ambPlane in ambilightLayers {
                    let scaleValue: Float = isImmersive ? 2.5 : 1.45
                    
                    let videoWidth = CURVED_MAX_WIDTH_METERS
                    let videoHeight = videoWidth * screenAspect
                    let padding = (videoWidth * scaleValue - videoWidth) / 2.0
                    let ambWidth = videoWidth * scaleValue
                    let ambHeight = videoHeight + 2.0 * padding
                    let ambAspect = ambHeight / ambWidth
                    
                    let videoAngle = CURVED_MAX_ANGLE * max(0.0, min(currentCurve, 2.0))
                    let videoRadius = (videoAngle < 0.0001) ? Float.infinity : (videoWidth / videoAngle)
                    
                    // Create a perfectly concentric cylinder behind the video to prevent Z-fighting clipping
                    let ambRadius = (videoAngle < 0.0001) ? Float.infinity : (videoRadius + 0.02)
                    
                    if let ambMesh = try? generateCurvedRoundedPlane(
                        width: ambWidth,
                        aspectRatio: ambAspect,
                        resolution: (32, 32),
                        curveMagnitude: currentCurve,
                        cornerRadiusFraction: cornerRadiusFraction,
                        uvScale: scaleValue,
                        isAmbilight: true,
                        forcedRadius: ambRadius
                    ) {
                        if let model = ambPlane.model {
                            try? model.mesh.replace(with: ambMesh.contents)
                        } else {
                            var ambMat = makeVideoUnlitMaterial(self.ambilightTexture ?? self.texture)
                            let ambAlpha = viewModel.streamSettings.dimPassthrough ? 1.0 : CGFloat(max(0.2, immersionAmount))
                            ambMat.color.tint = UIColor.white.withAlphaComponent(ambAlpha)
                            ambMat.blending = .transparent(opacity: 1.0)
                            ambPlane.model = ModelComponent(mesh: ambMesh, materials: [ambMat])
                        }
                        ambPlane.scale = [1.0, 1.0, 1.0]
                        // Push back exactly 2cm to match the radius increase and avoid Z-fighting
                        ambPlane.position = [0, 0, -0.02]
                        ambPlane.components.set(GroundingShadowComponent(castsShadow: false))
                    }
                }
            }
        }
        
        if !isImmersive {
            let volFrame = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
            let volSize = volFrame.extents
            var scaleFactor = volSize.x / 2.0
            
            // Shrink the screen slightly to allow Ambilight to bleed without hitting the volume bounds
            if viewModel.streamSettings.reactiveLightingEnabled {
                scaleFactor *= 0.85
            }
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
                let clampedScale: Float
                if viewModel.streamSettings.realitykitDynamicScale,
                   let headPos = headAnchor?.position(relativeTo: nil) {
                    let distance = simd_length(screenPosition - headPos)
                    let clampedDistance = max(distance, 0.3)
                    let applied = screenScale * clampedDistance / 1.0
                    clampedScale = max(applied, 0.2)
                } else {
                    clampedScale = min(max(screenScale, 0.2), allowedScaleMax)
                }
                screen.scale = [clampedScale, clampedScale, clampedScale]
                screen.position = screenPosition
            }
        }
        if !isPinnedToStage {
            if isImmersive {
                            _ = refreshHeadWorldPosition()
                            applyFacingRotationIfNeeded()
                        } else {
                            let tiltRadians = tiltAngle * .pi / 180.0
                            let tiltRotation = simd_quatf(angle: tiltRadians, axis: SIMD3<Float>(1, 0, 0))
                            screen.transform.rotation = tiltRotation
                        }
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

            // Recenter screen in front of the user on first launch and after
            // digital-crown return (where world tracking origin may have shifted).
            if needsInitialRecenter {
                needsInitialRecenter = false
                DispatchQueue.main.async { [self] in
                    recenterScreenToHead(head: head, fixedDistance: 1.0)
                }
            }

            if nearOrigin && wasFar && delta > 0.25 && notDraggingRecently && !controlState.isInteractive {
                // Use fixed distance when the jump is large (>1.0 m in one frame),
                // which only a digital-crown recenter can produce — walking doesn't
                // move the head that fast. For small jumps (walked to origin),
                // preserve the current distance.
                let isCrownRecenter = delta > 1.0
                DispatchQueue.main.async { [self] in
                    withAnimation(.easeInOut(duration: 0.22)) {
                        recenterScreenToHead(head: head, fixedDistance: isCrownRecenter ? 1.0 : nil)
                    }
                }
            }
        }
        
        updateImmersiveDragBarLayout()
        updateImmersiveDragBarInteractionVisuals()
        updateResizeHandleLayout()
        updateResizeHandleVisuals()

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
        // Fix: height is width / aspect, not width * aspect
        let screenHeight = CURVED_MAX_WIDTH_METERS * screenAspect
        if let statsEnt = attachments.entity(for: "stats") {
            if statsEnt.parent !== screen { screen.addChild(statsEnt) }
            statsEnt.position = [0.0 as Float, -(screenHeight / 2.0) - Float(0.07), Float(0.08)]
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
    
    private func updateImmersiveDragBarLayout() {
        guard isImmersive else {
            immersiveDragBar.isEnabled = false
            return
        }

        immersiveDragBar.isEnabled = !isPinnedToStage && !isPinningTransitioning
        guard immersiveDragBar.parent != nil else { return }

        let screenHeight = CURVED_MAX_WIDTH_METERS * screenAspect
        let localPosition = SIMD3<Float>(
            0,
            -(screenHeight / 2.0) - 0.035,
            0.012
        )
        immersiveDragBar.setPosition(screen.convert(position: localPosition, to: nil), relativeTo: nil)
        immersiveDragBar.setOrientation(screen.orientation(relativeTo: nil), relativeTo: nil)
    }

    private func updateImmersiveDragBarInteractionVisuals() {
        guard isImmersive, immersiveDragBar.parent != nil, immersiveDragBar.isEnabled else { return }

        let resizeActive = isResizeHandlePinching || isResizeHandleLeftPinching
        let dragBarVisible = !resizeActive && !isMouseCaptureActive && inputMode != .controller
        let targetBarOpacity: Float = dragBarVisible ? 1.0 : 0.0
        if (immersiveDragBar.components[OpacityComponent.self]?.opacity ?? 1.0) != targetBarOpacity {
            immersiveDragBar.components.set(OpacityComponent(opacity: targetBarOpacity))
        }

        let targetTint: Float = isDragBarPinching ? immersiveDragBarPinchTint : immersiveDragBarIdleTint
        let targetAlpha: Float = isDragBarPinching ? immersiveDragBarPinchOpacity
                                : resizeActive ? 0.0
                                : immersiveDragBarIdleOpacity
        if var model = immersiveDragBar.model, var mat = model.materials.first as? UnlitMaterial {
            let currentColor = mat.color.tint
            var white: CGFloat = 1.0
            var alpha: CGFloat = 1.0
            if currentColor.getWhite(&white, alpha: &alpha) {
                let nextWhite = Float(white) + (targetTint - Float(white)) * 0.26
                let nextAlpha = Float(alpha) + (targetAlpha - Float(alpha)) * 0.26
                mat.color.tint = UIColor(white: CGFloat(nextWhite), alpha: CGFloat(nextAlpha))
            } else {
                mat.color.tint = UIColor(white: CGFloat(targetTint), alpha: CGFloat(targetAlpha))
            }
            model.materials = [mat]
            immersiveDragBar.model = model
        }

        let baseScale = screen.scale
        let pinchScale = SIMD3<Float>(
            screen.scale.x * 0.88,
            screen.scale.y * 0.88,
            screen.scale.z
        )

        if !isDragBarPinching && !isDragBarScaleAnimating {
            if simd_length(immersiveDragBar.scale - baseScale) > 0 {
                immersiveDragBar.scale = baseScale
            }
            let resizeIdle = !isResizeHandlePinching && !isResizeHandleLeftPinching && !isResizeHandleScaleAnimating
            if resizeIdle {
                let currentScreenOpacity = screen.components[OpacityComponent.self]?.opacity ?? 1.0
                if abs(currentScreenOpacity - 1.0) > 0.001 {
                    screen.components.set(OpacityComponent(opacity: 1.0))
                }
            }
            return
        }

        let targetScale = isDragBarPinching ? pinchScale : baseScale
        let currentScale = immersiveDragBar.scale
        let scaleDistance = simd_length(currentScale - targetScale)
        if scaleDistance > 0.0005 {
            immersiveDragBar.scale = simd_mix(currentScale, targetScale, SIMD3<Float>(repeating: 0.07))
        } else {
            immersiveDragBar.scale = targetScale
            if !isDragBarPinching {
                isDragBarScaleAnimating = false
            }
        }

        let baseLen = simd_length(baseScale)
        let handleLen = simd_length(immersiveDragBar.scale)
        let ratio = baseLen > 0.0001 ? (handleLen / baseLen) : 1.0
        let shrinkProgress = min(max((1.0 - ratio) / 0.12, 0.0), 1.0)
        let screenTarget = 1.0 - (0.35 * shrinkProgress)
        let currentScreenOpacity = screen.components[OpacityComponent.self]?.opacity ?? 1.0
        if abs(currentScreenOpacity - screenTarget) > 0.001 {
            screen.components.set(OpacityComponent(opacity: screenTarget))
        }
    }

    // MARK: - Resize Handle

    private func updateResizeHandleLayout() {
        guard isImmersive else {
            resizeHandle.isEnabled = false
            resizeHandleLeft.isEnabled = false
            return
        }
        let handlesEnabled = !isPinnedToStage && !isPinningTransitioning
        resizeHandle.isEnabled = handlesEnabled
        resizeHandleLeft.isEnabled = handlesEnabled
        guard resizeHandle.parent != nil, resizeHandleLeft.parent != nil else { return }

        let screenWidth: Float = CURVED_MAX_WIDTH_METERS
        let screenHeight = screenWidth * screenAspect
        let cornerOffset: Float = -0.008

        // Fixed position at the bottom-right corner point (independent of corner radius)
        // plus curvature Z displacement so the handle stays on the curved surface.
        let curvedZ: Float
        let curveTiltRight: simd_quatf
        let curveTiltLeft: simd_quatf
        let ec = effectiveCurvature
        let maxCurveAngle = CURVED_MAX_ANGLE
        let currentAngle = maxCurveAngle * max(0.0, min(ec, 2.0))
        if currentAngle < 0.0001 {
            curvedZ = 0.012
            curveTiltRight = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            curveTiltLeft = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        } else {
            let radius = screenWidth / currentAngle
            let halfAngle = currentAngle / 2.0
            curvedZ = 0.012 + radius * (1.0 - cos(halfAngle))
            // Right edge tilts away (negative Y rotation)
            curveTiltRight = simd_quatf(angle: -halfAngle, axis: SIMD3<Float>(0, 1, 0))
            // Left edge tilts away (positive Y rotation — mirrored)
            curveTiltLeft = simd_quatf(angle: halfAngle, axis: SIMD3<Float>(0, 1, 0))
        }

        // Right handle
        let rightLocal = SIMD3<Float>(
            screenWidth / 2.0 + cornerOffset,
            -(screenHeight / 2.0) - cornerOffset,
            curvedZ
        )
        resizeHandle.setPosition(screen.convert(position: rightLocal, to: nil), relativeTo: nil)
        resizeHandle.setOrientation(screen.orientation(relativeTo: nil) * curveTiltRight, relativeTo: nil)

        // Left handle — mirror x
        let leftLocal = SIMD3<Float>(
            -(screenWidth / 2.0) - cornerOffset,
            -(screenHeight / 2.0) - cornerOffset,
            curvedZ
        )
        resizeHandleLeft.setPosition(screen.convert(position: leftLocal, to: nil), relativeTo: nil)
        resizeHandleLeft.setOrientation(screen.orientation(relativeTo: nil) * curveTiltLeft, relativeTo: nil)
    }

    private func updateResizeHandleVisuals() {
        let isPinching = isResizeHandlePinching || isResizeHandleLeftPinching
        let handles = [resizeHandle, resizeHandleLeft]
        for handle in handles {
            guard handle.parent != nil, handle.isEnabled else { continue }

            let thisPinching = (handle === resizeHandle && isResizeHandlePinching)
                            || (handle === resizeHandleLeft && isResizeHandleLeftPinching)
            let suppressed = isDragBarPinching || (isPinching && !thisPinching) || isMouseCaptureActive || inputMode == .controller
            let targetOpacityComp: Float = suppressed ? 0.0 : 1.0
            if (handle.components[OpacityComponent.self]?.opacity ?? 1.0) != targetOpacityComp {
                handle.components.set(OpacityComponent(opacity: targetOpacityComp))
            }

            let targetTint: Float = thisPinching ? resizeHandlePinchTint : resizeHandleIdleTint
            let targetAlpha: Float = thisPinching ? resizeHandlePinchOpacity : resizeHandleIdleOpacity
            if var model = handle.model, var mat = model.materials.first as? UnlitMaterial {
                let currentColor = mat.color.tint
                var white: CGFloat = 1.0
                var alpha: CGFloat = 1.0
                if currentColor.getWhite(&white, alpha: &alpha) {
                    let nextWhite = Float(white) + (targetTint - Float(white)) * 0.26
                    let nextAlpha = Float(alpha) + (targetAlpha - Float(alpha)) * 0.26
                    mat.color.tint = UIColor(white: CGFloat(nextWhite), alpha: CGFloat(nextAlpha))
                } else {
                    mat.color.tint = UIColor(white: CGFloat(targetTint), alpha: CGFloat(targetAlpha))
                }
                model.materials = [mat]
                handle.model = model
            }
        }

        let baseScale = screen.scale
        let pinchScale = SIMD3<Float>(
            screen.scale.x * 0.88,
            screen.scale.y * 0.88,
            screen.scale.z
        )

        if !isPinching && !isResizeHandleScaleAnimating {
            for handle in handles {
                guard handle.parent != nil, handle.isEnabled else { continue }
                if simd_length(handle.scale - baseScale) > 0 {
                    handle.scale = baseScale
                }
            }
            // Screen opacity restoration is handled by the drag bar function
            return
        }

        let targetScale = isPinching ? pinchScale : baseScale
        for handle in handles {
            guard handle.parent != nil, handle.isEnabled else { continue }
            let currentScale = handle.scale
            let scaleDistance = simd_length(currentScale - targetScale)
            if scaleDistance > 0.0005 {
                handle.scale = simd_mix(currentScale, targetScale, SIMD3<Float>(repeating: 0.07))
            } else {
                handle.scale = targetScale
                if !isPinching {
                    isResizeHandleScaleAnimating = false
                }
            }
        }

        if isPinching || isResizeHandleScaleAnimating {
            let baseLen = simd_length(baseScale)
            let handleLen = simd_length(resizeHandle.scale)
            let ratio = baseLen > 0.0001 ? (handleLen / baseLen) : 1.0
            let shrinkProgress = min(max((1.0 - ratio) / 0.12, 0.0), 1.0)
            let targetScreenOpacity = 1.0 - (0.35 * shrinkProgress)
            let currentScreenOpacity = screen.components[OpacityComponent.self]?.opacity ?? 1.0
            if abs(currentScreenOpacity - targetScreenOpacity) > 0.001 {
                screen.components.set(OpacityComponent(opacity: targetScreenOpacity))
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
            
            let bounds = inputEnt.visualBounds(relativeTo: screen)
            if bounds.extents.x > 0 && bounds.extents.y > 0 {
                if showVirtualKeyboard || inputMode == .controller {
                    let unscaledWidth = Float(bounds.extents.x) / max(inputEnt.scale.x, 0.0001)
                    let unscaledHeight = Float(bounds.extents.y) / max(inputEnt.scale.y, 0.0001)
                    
                    if isImmersive {
                        // 2% overscan so the visionOS cursor has room beyond the visible
                        // screen edge, preventing dead zones at left/right boundaries.
                        let scaleX = (CURVED_MAX_WIDTH_METERS * 1.02) / unscaledWidth
                        let scaleY = (CURVED_MAX_WIDTH_METERS * Float(screenAspect) * 1.02) / unscaledHeight
                        inputEnt.scale = [scaleX, scaleY, scaleX]
                    } else {
                        // Volume window: extend past screen edges to prevent volume bounds clipping
                        let scaleX = (CURVED_MAX_WIDTH_METERS * 1.05) / unscaledWidth
                        let scaleY = ((CURVED_MAX_WIDTH_METERS * Float(screenAspect)) * 1.5) / unscaledHeight
                        inputEnt.scale = [scaleX, scaleY, scaleX]
                    }
                } else {
                    inputEnt.scale = .one
                }
            }
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
            sizeToFit(popupEnt, targetWidth: 0.35)
        }
        if let panelEnt = attachments.entity(for: "controlPanel") {
            if panelEnt.parent !== screen { screen.addChild(panelEnt) }
            panelEnt.position = [0.0 as Float, 0.0 as Float, Float(0.22)]
            sizeToFit(panelEnt, targetWidth: 0.95)
        }
        if let controls = attachments.entity(for: "controls") {
            if controls.parent !== screen { screen.addChild(controls) }
            let actualScreenHeight = CURVED_MAX_WIDTH_METERS * Float(screenAspect)
            controls.position = [0.0 as Float, (actualScreenHeight / 2.0) + Float(0.08), Float(0.08)]
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
        if let keyboardAndModifiersEnt = attachments.entity(for: "keyboardAndModifiers") {
            if keyboardAndModifiersEnt.parent !== screen { screen.addChild(keyboardAndModifiersEnt) }
            
            let actualScreenHeight = CURVED_MAX_WIDTH_METERS * Float(screenAspect)
            let toolbarOffset: Float = 0.12
            keyboardAndModifiersEnt.position = [0.0 as Float, -(actualScreenHeight / 2.0) - toolbarOffset, Float(0.08)]
            
            if showVirtualKeyboard {
                sizeToFit(keyboardAndModifiersEnt, targetWidth: 0.65)
            } else {
                keyboardAndModifiersEnt.scale = .one
            }
        }
    }
    
    private func startStreamIfNeeded() {
        guard streamMan == nil else {
            print("[StreamView] StreamManager already exists, skipping duplicate creation")
            needsResume = false
            return
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
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
            
            self.recreateStreamTexture()
            
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
                        isVolumeModeProvider: {
                            !self.isImmersive
                        },
                        enableAmbilightProvider: {
                            self.viewModel.streamSettings.reactiveLightingEnabled
                        },
                        callbackToRender: { textureQueue, ambilightQueue, correctedResolution in
                            guard self.renderGateOpen else { return }

                            DispatchQueue.main.async {
                                if let correctedResolution { 
                                    self.correctedResolution = correctedResolution 
                                }
                                self.texture.replace(withDrawables: textureQueue)
                                
                                if let ambilightQueue {
                                    if self.ambilightTexture == nil {
                                        do {
                                            let targetMipLevel = 6
                                            let ambWidth = max(1, Int(self.streamConfig.width) >> targetMipLevel)
                                            let ambHeight = max(1, Int(self.streamConfig.height) >> targetMipLevel)
                                            let bytesPerPixel = self.viewModel.streamSettings.enableHdr ? 8 : 4
                                            self.ambilightTexture = try TextureResource(
                                                dimensions: .dimensions(width: ambWidth, height: ambHeight),
                                                format: .raw(pixelFormat: self.viewModel.streamSettings.enableHdr ? .rgba16Float : .bgra8Unorm_srgb),
                                                contents: .init(mipmapLevels: [.mip(data: Data(count: bytesPerPixel * ambWidth * ambHeight), bytesPerRow: bytesPerPixel * ambWidth)])
                                            )
                                            self.ambilightTexture?.replace(withDrawables: ambilightQueue)
                                            self.rebindScreenMaterial()
                                        } catch {
                                            print("Failed to init ambilightTexture: \(error)")
                                        }
                                    } else {
                                        self.ambilightTexture?.replace(withDrawables: ambilightQueue)
                                    }
                                }
                                
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
            if let streamMan = self.streamMan {
                self.streamOpQueue.addOperation(streamMan)
            }
            
        }
    }
    
    private func recreateStreamTexture() {
        let desiredHDR = viewModel.streamSettings.enableHdr
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
            let configToUse = self.streamConfig
            Task {
                var isOnline = false
                if let hostAddress = configToUse.host,
                   let host = viewModel.hosts.first(where: { $0.activeAddress == hostAddress || $0.address == hostAddress || $0.localAddress == hostAddress || $0.externalAddress == hostAddress }) {
                    let httpManager = HttpManager(host: host)
                    let serverInfoResponse = ServerInfoResponse()
                    let request = HttpRequest(
                        for: serverInfoResponse,
                        with: httpManager?.newServerInfoRequest(false),
                        fallbackError: 401,
                        fallbackRequest: httpManager?.newHttpServerInfoRequest()
                    )
                    
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            httpManager?.executeRequestSynchronously(request)
                            continuation.resume()
                        }
                    }
                    isOnline = serverInfoResponse.isStatusOk()
                } else {
                    isOnline = true // Fallback to normal retry if host missing
                }
                
                await MainActor.run {
                    guard !self.hasPerformedTeardown, self.viewModel.activelyStreaming else { return }
                    
                    if isOnline {
                        self.reconnectAttemptCount += 1
                        self.isReconnecting = true
                        self.connectionCallbacks.isReconnectingForRetry = true
                        self.isPerformingReconnectTeardown = true
                        print("[StreamView] Connection lost, auto-reconnect attempt \(self.reconnectAttemptCount)/\(self.maxReconnectAttempts)")
                        self.performReconnectTeardown {
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
                                if self.viewModel.streamSettings.controllerMouseMode {
                                    self.controllerSupport?.disableControllerCallbacks()
                                    self.controllerMouseManager.mouseSpeed = self.viewModel.streamSettings.controllerMouseSpeed
                                    self.controllerMouseManager.start()
                                }
                                self.startStreamIfNeeded()
                            }
                        }
                    } else {
                        print("[StreamView] Host offline, aborting reconnect attempts")
                        self.isReconnecting = false
                        self.isPerformingReconnectTeardown = false
                        self.connectionCallbacks.isReconnectingForRetry = false
                        self.reconnectAttemptCount = 0
                        self.lastStreamErrorMessage = msg
                        self.connectionCallbacks.showAlert = true
                        self.connectionCallbacks.errorMessage = msg
                        if self.isImmersive {
                            self.viewModel.streamState = .stopping
                        }
                        self.performReconnectTeardown {
                            NotificationCenter.default.post(name: Notification.Name("RealityKitStreamErrorNotification"), object: nil, userInfo: ["message": msg])
                            if !self.isImmersive {
                                NotificationCenter.default.post(name: Notification.Name("RealityKitRetriesExhausted"), object: nil)
                            }
                        }
                    }
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
        controllerMouseManager.stop()
        statsTimer?.invalidate()
        hintOverlayTimer?.invalidate()
        hintOverlayTimer = nil
        hideTimer?.invalidate()
        moonlightCycleTimer?.invalidate()
        scaleHUDFadeTimer?.invalidate()
        environmentFadeTimer?.invalidate()
        reactiveLerpTimer?.invalidate()
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
        
        // Ensure MainViewModel isn't stuck in .running if the window was closed via system controls
        let wasHidingForResume = viewModel.isHidingForResume
        let isCurrentSession = (viewModel.currentStreamConfig.sessionUUID == streamConfig.sessionUUID)
        if isCurrentSession && viewModel.activelyStreaming && viewModel.streamState != .stopping {
            if wasHidingForResume {
                viewModel.isHidingForResume = false
            } else {
                // User closed the window via system controls. 
                // Implicitly save the config so they can resume via the Main Menu or App Intent.
                viewModel.savedStreamConfigForResume = streamConfig
            }
        }
        
        // CRITICAL: Close render gate BEFORE stopping stream
        renderGateOpen = false

        controllerMouseManager.stop()

        // Audio session will be reset after stopStream completes

        statsTimer?.invalidate()
        hintOverlayTimer?.invalidate()
        hintOverlayTimer = nil
        hideTimer?.invalidate()
        moonlightCycleTimer?.invalidate()
        scaleHUDFadeTimer?.invalidate()
        environmentFadeTimer?.invalidate()
        reactiveLerpTimer?.invalidate()
        
        idrWatchdogTimer1?.invalidate(); idrWatchdogTimer1 = nil
        idrWatchdogTimer2?.invalidate(); idrWatchdogTimer2 = nil
        postFirstFrameRebindTimer?.invalidate(); postFirstFrameRebindTimer = nil
        firstFrameReceived = false
        ambilightTexture = nil
        
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
                
                // CRITICAL: Reset audio session AFTER the stream has fully stopped.
                // Resetting it earlier causes EXC_BAD_ACCESS if the audio thread is still running.
                AudioHelpers.resetAudioSession()
                
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
        cornerRadiusFraction: Float,
        uvScale: Float = 1.0,
        isAmbilight: Bool = false,
        forcedRadius: Float? = nil
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
        
        let currentAngle: Float
        let radius: Float
        let isFlat: Bool
        
        if let fr = forcedRadius {
            radius = fr
            isFlat = !radius.isFinite || radius == 0
            currentAngle = isFlat ? 0.0 : (width / radius)
        } else {
            currentAngle = maxCurveAngle * max(0.0, min(curveMagnitude, 2.0))
            isFlat = currentAngle < 0.0001
            radius = isFlat ? .infinity : (width / currentAngle)
        }
        
        let halfAngle = currentAngle / 2.0
        
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
                
                var final_u = u_tex
                var final_v = v_tex
                
                if isAmbilight {
                    // Do not scale UVs. The texture itself has the video centered 
                    // and fades to black at the edges via the new ambilight shader.
                    final_u = u_tex
                    final_v = v_tex
                }

                texcoords[vi] = SIMD2<Float>(final_u, final_v)

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

    private func makeRoundedDragBarMesh(width: Float, height: Float) -> MeshResource {
        var descriptor = MeshDescriptor(name: "immersive_drag_bar_capsule")
        let radius = height * 0.5
        let halfStraight = max(0, (width * 0.5) - radius)
        let segmentCount = 18

        var positions: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0)]
        var indices: [UInt32] = []

        for i in 0...segmentCount {
            let angle = (Float.pi * 0.5) - (Float(i) / Float(segmentCount)) * Float.pi
            positions.append(SIMD3<Float>(
                halfStraight + cos(angle) * radius,
                sin(angle) * radius,
                0
            ))
        }

        for i in 0...segmentCount {
            let angle = (-Float.pi * 0.5) - (Float(i) / Float(segmentCount)) * Float.pi
            positions.append(SIMD3<Float>(
                -halfStraight + cos(angle) * radius,
                sin(angle) * radius,
                0
            ))
        }

        let outerCount = UInt32(positions.count - 1)
        for i in 1...outerCount {
            let next = (i == outerCount) ? UInt32(1) : i + 1
            indices.append(contentsOf: [0, i, next])
        }

        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? .generatePlane(width: width, height: height)
    }

    /// Generates a thin 90° arc strip with semicircular end caps (matching the
    /// drag bar's rounded look). Set flipX = true for the bottom-left corner.
    private func makeCornerArcMesh(innerRadius: Float, thickness: Float, flipX: Bool = false, segments: Int = 20) -> MeshResource {
        var descriptor = MeshDescriptor(name: "corner_arc_handle")
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        let outerRadius = innerRadius + thickness
        let halfThick = thickness * 0.5
        let midRadius = innerRadius + halfThick
        let sx: Float = flipX ? -1 : 1

        // Main arc strip: inner + outer edge vertices interleaved.
        for i in 0...segments {
            let angle = -Float.pi / 2 + (Float(i) / Float(segments)) * (Float.pi / 2)
            positions.append(SIMD3<Float>(cos(angle) * innerRadius * sx, sin(angle) * innerRadius, 0))
            positions.append(SIMD3<Float>(cos(angle) * outerRadius * sx, sin(angle) * outerRadius, 0))
        }
        for i in 0..<segments {
            let inner0 = UInt32(i * 2)
            let outer0 = UInt32(i * 2 + 1)
            let inner1 = UInt32((i + 1) * 2)
            let outer1 = UInt32((i + 1) * 2 + 1)
            if flipX {
                // Winding reversed for the mirrored mesh so faces point forward
                indices.append(contentsOf: [inner0, inner1, outer0,
                                             outer0, inner1, outer1])
            } else {
                indices.append(contentsOf: [inner0, outer0, inner1,
                                             outer0, outer1, inner1])
            }
        }

        // Semicircular cap at bottom end (–π/2).
        let bottomCapCenter = UInt32(positions.count)
        positions.append(SIMD3<Float>(0, -midRadius, 0))
        let capSegs = 8
        for i in 0...capSegs {
            let a = Float.pi / 2 + (Float(i) / Float(capSegs)) * Float.pi
            positions.append(SIMD3<Float>(cos(a) * halfThick * sx, -midRadius + sin(a) * halfThick, 0))
        }
        for i in 0..<capSegs {
            let a = UInt32(i + 1)
            let b = UInt32(i + 2)
            if flipX {
                indices.append(contentsOf: [bottomCapCenter, bottomCapCenter + b, bottomCapCenter + a])
            } else {
                indices.append(contentsOf: [bottomCapCenter, bottomCapCenter + a, bottomCapCenter + b])
            }
        }
        let firstInner = UInt32(0)
        let firstOuter = UInt32(1)
        if flipX {
            indices.append(contentsOf: [firstInner, bottomCapCenter + 1, firstOuter,
                                         firstOuter, bottomCapCenter + 1, bottomCapCenter + UInt32(capSegs + 1),
                                         firstInner, firstOuter, bottomCapCenter + UInt32(capSegs + 1)])
        } else {
            indices.append(contentsOf: [firstInner, firstOuter, bottomCapCenter + 1,
                                         firstOuter, bottomCapCenter + UInt32(capSegs + 1), bottomCapCenter + 1,
                                         firstOuter, firstInner, bottomCapCenter + UInt32(capSegs + 1)])
        }

        // Semicircular cap at right end (0).
        let lastStripIdx = segments * 2
        let rightCapCenter = UInt32(positions.count)
        positions.append(SIMD3<Float>(midRadius * sx, 0, 0))
        for i in 0...capSegs {
            let a = Float(i) / Float(capSegs) * Float.pi
            positions.append(SIMD3<Float>((midRadius + cos(a) * halfThick) * sx, sin(a) * halfThick, 0))
        }
        for i in 0..<capSegs {
            let a = UInt32(i + 1)
            let b = UInt32(i + 2)
            if flipX {
                indices.append(contentsOf: [rightCapCenter, rightCapCenter + b, rightCapCenter + a])
            } else {
                indices.append(contentsOf: [rightCapCenter, rightCapCenter + a, rightCapCenter + b])
            }
        }
        let lastInner = UInt32(lastStripIdx)
        let lastOuter = UInt32(lastStripIdx + 1)
        if flipX {
            indices.append(contentsOf: [lastInner, lastOuter, rightCapCenter + UInt32(capSegs + 1),
                                         lastOuter, rightCapCenter + 1, rightCapCenter + UInt32(capSegs + 1),
                                         lastOuter, lastInner, rightCapCenter + 1])
        } else {
            indices.append(contentsOf: [lastInner, rightCapCenter + 1, lastOuter,
                                         lastOuter, rightCapCenter + 1, rightCapCenter + UInt32(capSegs + 1),
                                         lastOuter, rightCapCenter + UInt32(capSegs + 1), lastInner])
        }

        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? .generatePlane(width: 1, height: 1)
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
        dimmerDome?.isEnabled = (dimLevel > 0)
        dimmerDomePurple?.isEnabled = (dimLevel == 2 || dimLevel == 10 || viewModel.streamSettings.reactiveLightingEnabled)
        // Note: In Volume Mode, the OS clips the outer glow layers to the window bounds.
        for ambPlane in ambilightLayers {
            ambPlane.isEnabled = viewModel.streamSettings.reactiveLightingEnabled
        }
    }

    private func updateDimmerDomes(content: RealityViewContent) {
        guard dimLevel != lastAppliedDimLevelBox.value else { return }
        lastAppliedDimLevelBox.value = dimLevel
        
        if let dome = dimmerDome {
            let targetAlpha: Float
            switch dimLevel {
            case 1: targetAlpha = 0.25
            case 2: targetAlpha = 0.50
            case 3: targetAlpha = 0.75
            case 4: targetAlpha = 1.00
            default: targetAlpha = 0.0
            }
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

        var clearMat = UnlitMaterial(color: .clear)
        clearMat.blending = .transparent(opacity: 0.0)
        let purpleDome = ModelEntity(mesh: sharedDomeMesh, materials: [clearMat])
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

    private func recenterScreenToHead(head: AnchorEntity, fixedDistance: Float? = nil) {
        let headPos = head.position(relativeTo: nil)
        let current = screenPosition

        // Preserve current height offset
        let yOffset = current.y - headPos.y

        let distance: Float
        if let fixed = fixedDistance {
            distance = fixed
        } else {
            let delta = current - headPos
            distance = simd_length(delta)
        }

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

        // Place screen at the computed distance
        var newPos = simd_float3(
            headPos.x + flatForward.x * distance,
            headPos.y + yOffset,
            headPos.z + flatForward.z * distance
        )

        newPos.x = min(max(newPos.x, -allowedLateralMax), allowedLateralMax)

        screenPosition = newPos
    }

    private func facingHeadRotation() -> simd_quatf {
            let screenWorldPosition = screen.position(relativeTo: nil)
            guard let headWorldPosition = lastKnownHeadWorldPosition ?? refreshHeadWorldPosition() else {
                return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            }
            let toHead = SIMD3<Float>(
                headWorldPosition.x - screenWorldPosition.x,
                headWorldPosition.y - screenWorldPosition.y,
                headWorldPosition.z - screenWorldPosition.z
            )
            let fullLength = simd_length(toHead)
            guard fullLength > 1e-4 else {
                return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            }

            var horizontal = SIMD3<Float>(toHead.x, 0, toHead.z)
            let horizontalLength = simd_length(horizontal)
            guard horizontalLength > 1e-4 else {
                return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            }
            horizontal /= horizontalLength

            let yaw = atan2(horizontal.x, horizontal.z)
            let yawRotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))

            guard viewModel.streamSettings.realitykitAutoPitchFollow else {
                return yawRotation
            }

            let positionPitch = atan2(toHead.y, horizontalLength)
            let gazePitch: Float = {
                guard let forward = lastKnownHeadForward else { return 0 }
                let horizontalForwardLength = simd_length(SIMD2<Float>(forward.x, forward.z))
                guard horizontalForwardLength > 1e-4 else { return 0 }
                return atan2(forward.y, horizontalForwardLength)
            }()
            // Native-like feel: center region stays stable, then pitch response ramps up smoothly.
            let compensatedPitch = autoPitchResponseCurve(
                positionPitch - gazePitch * autoPitchGazeCompensation,
                verticalOffsetMeters: abs(toHead.y)
            )
            let rightAxis = yawRotation.act(SIMD3<Float>(1, 0, 0))
            let pitchRotation = simd_quatf(angle: -compensatedPitch, axis: rightAxis)
            return pitchRotation * yawRotation
        }

    private func autoPitchResponseCurve(_ input: Float, verticalOffsetMeters: Float) -> Float {
        let sign: Float = input >= 0 ? 1 : -1
        let magnitude = abs(input)

        let boostT = min(max(
            (verticalOffsetMeters - autoPitchHeightBoostStartMeters) /
            max(autoPitchHeightBoostEndMeters - autoPitchHeightBoostStartMeters, 1e-4),
            0
        ), 1)
        let boostSmooth = boostT * boostT * (3 - 2 * boostT)
        let effectiveDeadZone = autoPitchDeadZoneRadians + (autoPitchMinDeadZoneRadians - autoPitchDeadZoneRadians) * boostSmooth
        if magnitude <= effectiveDeadZone { return 0 }

        let up = sign > 0
        let innerGain = up ? autoPitchInnerGainUp : autoPitchInnerGainDown
        let outerGain = up ? autoPitchOuterGainUp : autoPitchOuterGainDown

        let shifted = magnitude - effectiveDeadZone
        let softSpan = max(autoPitchSoftZoneRadians - autoPitchDeadZoneRadians, 1e-4)
        let t = min(max(shifted / softSpan, 0), 1)
        let smooth = t * t * (3 - 2 * t) // smoothstep
        let gainBase = innerGain + (outerGain - innerGain) * smooth
        let gain = gainBase * (1.0 + autoPitchHeightGainBoost * boostSmooth)
        return sign * shifted * gain
    }

    private func refreshHeadWorldPosition() -> SIMD3<Float>? {
        if let head = headAnchor {
            var forward = head.transform.rotation.act(SIMD3<Float>(0, 0, -1))
            let forwardLength = simd_length(forward)
            if forwardLength > 1e-4 {
                forward /= forwardLength
                lastKnownHeadForward = forward
            }
        }
        if isImmersive, isWorldTrackingRunning,
           let deviceAnchor = worldTrackingProvider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
            let t = deviceAnchor.originFromAnchorTransform
            let trackedPosition = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            var trackedForward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            let trackedForwardLength = simd_length(trackedForward)
            if trackedForwardLength > 1e-4 {
                trackedForward /= trackedForwardLength
                lastKnownHeadForward = trackedForward
            }
            lastKnownHeadWorldPosition = trackedPosition
            return trackedPosition
        }
        if let head = headAnchor {
            let p = head.position(relativeTo: nil)
            let fallback = SIMD3<Float>(p.x, p.y, p.z)
            lastKnownHeadWorldPosition = fallback
            return fallback
        }
        return lastKnownHeadWorldPosition
    }

    private func applyFacingRotationIfNeeded() {
        guard isImmersive, !isPinnedToStage else { return }
        let manualTilt = viewModel.streamSettings.realitykitAutoPitchFollow ? 0.0 : tiltAngle
        let tiltRadians = manualTilt * .pi / 180.0
        let tiltRotation = simd_quatf(angle: tiltRadians, axis: SIMD3<Float>(1, 0, 0))
        let targetRotation = facingHeadRotation() * tiltRotation
        guard isDragFacingCatchupActive else {
            screen.transform.rotation = targetRotation
            return
        }

        let elapsed = CACurrentMediaTime() - dragFacingCatchupStartTime
        let t = min(max(Float(elapsed / dragFacingCatchupDuration), 0), 1)
        let easedT = t * t * t * (t * (t * 6 - 15) + 10)  // smootherstep easing
        // Follow the latest head pose during catch-up to avoid "chasing old target then snapping".
        dragFacingCatchupToRotation = targetRotation
        screen.transform.rotation = simd_slerp(dragFacingCatchupFromRotation, dragFacingCatchupToRotation, easedT)
        if t >= 1.0 {
            isDragFacingCatchupActive = false
            stopDragFacingCatchupTimer()
            screen.transform.rotation = targetRotation
        }
    }

    private func startDragFacingCatchupIfNeeded() {
        guard isImmersive, !isPinnedToStage else { return }
        let now = CACurrentMediaTime()
        if (now - lastDragFacingCatchupStartTime) < 0.12 {
            return
        }
        let manualTilt = viewModel.streamSettings.realitykitAutoPitchFollow ? 0.0 : tiltAngle
        let tiltRadians = manualTilt * .pi / 180.0
        let tiltRotation = simd_quatf(angle: tiltRadians, axis: SIMD3<Float>(1, 0, 0))
        let currentRotation = screen.transform.rotation
        let targetRotation = facingHeadRotation() * tiltRotation
        let alignment = abs(simd_dot(currentRotation.vector, targetRotation.vector))
        if alignment > 0.999 {
            isDragFacingCatchupActive = false
            return
        }
        dragFacingCatchupFromRotation = currentRotation
        dragFacingCatchupToRotation = targetRotation
        dragFacingCatchupStartTime = now
        lastDragFacingCatchupStartTime = now
        isDragFacingCatchupActive = true
        startDragFacingCatchupTimer()
    }

    private func startDragFacingCatchupTimer() {
        guard dragFacingCatchupTimer == nil else { return }
        dragFacingCatchupTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 90.0, repeats: true) { _ in
            guard isDragFacingCatchupActive else {
                stopDragFacingCatchupTimer()
                return
            }
            _ = refreshHeadWorldPosition()
            applyFacingRotationIfNeeded()
        }
    }

    private func stopDragFacingCatchupTimer() {
        dragFacingCatchupTimer?.invalidate()
        dragFacingCatchupTimer = nil
    }

    private func startDragFacingFollowTimer() {
        guard dragFacingFollowTimer == nil else { return }
        dragFacingFollowTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { _ in
            let now = CACurrentMediaTime()
            let inReleaseGrace = (now - lastScreenMoveReleaseTime) < dragFacingFollowReleaseGraceDuration
            let shouldKeepFollowing = isScreenMoveDragging || isDragFacingCatchupActive || inReleaseGrace
            guard shouldKeepFollowing else {
                stopDragFacingFollowTimer()
                return
            }
            _ = refreshHeadWorldPosition()
            if isScreenMoveDragging || isDragFacingCatchupActive {
                applyFacingRotationIfNeeded()
            } else if inReleaseGrace {
                applyReleaseFacingTailStep(now: now)
            }
        }
    }

    private func stopDragFacingFollowTimer() {
        dragFacingFollowTimer?.invalidate()
        dragFacingFollowTimer = nil
    }

    private func startInertiaMotionIfNeeded() {
        guard isImmersive, !isPinnedToStage else { return }
        let planarVelocity = SIMD3<Float>(dragReleaseVelocity.x, dragReleaseVelocity.y, dragReleaseVelocity.z)
        let speed = simd_length(planarVelocity)
        guard speed > dragInertiaStopSpeed else { return }

        inertiaVelocity = planarVelocity
    }

    private func stopInertiaMotion() {
        inertiaVelocity = .zero
        dragReleaseVelocity = .zero
    }

    private func applyInertiaStep(deltaTime: Float) {
        guard isImmersive, !isPinnedToStage, !isScreenMoveDragging else { return }
        let speed = simd_length(inertiaVelocity)
        guard speed > dragInertiaStopSpeed else { return }

        let clampedDt = min(max(deltaTime, 1.0 / 240.0), 1.0 / 45.0)
        let damping = Float(exp(Double(-dragInertiaDecelerationPerSecond * clampedDt)))
        inertiaVelocity *= damping

        let speedNow = simd_length(inertiaVelocity)
        if speedNow <= dragInertiaStopSpeed {
            stopInertiaMotion()
            return
        }

        var proposed = screenPosition + inertiaVelocity * clampedDt
        proposed.x = min(max(proposed.x, -allowedLateralMax), allowedLateralMax)

        // Emulate native "face collision" feel: if inertia pushes the panel into
        // a head-centered safety sphere, spring it back with damped reflection.
        if let headWorldPosition = lastKnownHeadWorldPosition ?? refreshHeadWorldPosition() {
            var toPanel = proposed - headWorldPosition
            let distance = simd_length(toPanel)
            if distance < headCollisionRadius {
                if distance < 1e-4 {
                    toPanel = SIMD3<Float>(0, 0, -1)
                } else {
                    toPanel /= distance
                }

                let penetration = headCollisionRadius - distance
                let softDepth = max(headCollisionSoftLayerDepth, 1e-3)
                let normalizedCompression = min(max((penetration - softDepth) / softDepth, 0), 1)
                let springFactor = normalizedCompression * normalizedCompression

                // Soft membrane behavior:
                // - allow shallow penetration (shape deformation / energy absorption)
                // - push back increasingly only after entering deeper compression.
                if springFactor > 0 {
                    let boundaryPoint = headWorldPosition + toPanel * headCollisionRadius
                    let pushLerp = headCollisionPushoutLerp * springFactor
                    proposed = simd_mix(proposed, boundaryPoint, SIMD3<Float>(repeating: pushLerp))
                    proposed.x = min(max(proposed.x, -allowedLateralMax), allowedLateralMax)
                }

                // Rebound primarily along incoming direction (like native window feel),
                // while heavily suppressing sideways drift.
                let vNormal = simd_dot(inertiaVelocity, toPanel)
                if vNormal < 0 {
                    let speedIn = simd_length(inertiaVelocity)
                    if speedIn > 1e-4 {
                        let incomingDir = inertiaVelocity / speedIn
                        let compressionBounce = headCollisionRestitution * (0.35 + 0.65 * springFactor)
                        let reboundAlongIncoming = -incomingDir * (speedIn * compressionBounce)

                        // Keep a tiny outward-normal bias so we do not re-penetrate immediately.
                        let outwardNormalBias = toPanel * max(-vNormal, 0) * 0.12
                        inertiaVelocity = reboundAlongIncoming + outwardNormalBias
                    } else {
                        let normalComponent = toPanel * vNormal
                        let tangentialComponent = inertiaVelocity - normalComponent
                        let compressionTangent = headCollisionTangentialDamping - 0.08 * springFactor
                        inertiaVelocity = tangentialComponent * compressionTangent - normalComponent * headCollisionRestitution
                    }
                }

                // Additional spring acceleration for deep compression to mimic elastic membrane restoring force.
                if springFactor > 0 {
                    let springAccel = toPanel * (headCollisionSpringStrength * springFactor)
                    inertiaVelocity += springAccel * clampedDt
                }
            }
        }

        screenPosition = proposed
        _ = refreshHeadWorldPosition()
        applyFacingRotationIfNeeded()
    }

    private func applyReleaseFacingTailStep(now: CFTimeInterval) {
        guard isImmersive, !isPinnedToStage else { return }
        let elapsed = max(0, now - lastScreenMoveReleaseTime)
        let progress = min(max(Float(elapsed / dragFacingFollowReleaseGraceDuration), 0), 1)
        let easeOut = 1 - pow(1 - progress, 3)

        let manualTilt = viewModel.streamSettings.realitykitAutoPitchFollow ? 0.0 : tiltAngle
        let tiltRadians = manualTilt * .pi / 180.0
        let tiltRotation = simd_quatf(angle: tiltRadians, axis: SIMD3<Float>(1, 0, 0))
        let targetRotation = facingHeadRotation() * tiltRotation

        // Strong response right after release, then smoothly taper off.
        let step = 0.34 - 0.28 * easeOut
        screen.transform.rotation = simd_slerp(screen.transform.rotation, targetRotation, step)
    }

    private func startWorldTrackingIfNeeded() {
        guard isImmersive, WorldTrackingProvider.isSupported, !isWorldTrackingRunning else { return }
        Task {
            do {
                try await arkitSession.run([worldTrackingProvider])
                await MainActor.run {
                    isWorldTrackingRunning = true
                    _ = refreshHeadWorldPosition()
                }
            } catch {
                await MainActor.run {
                    isWorldTrackingRunning = false
                    print("[RealityKitStreamView] WorldTrackingProvider failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopWorldTracking() {
        isWorldTrackingRunning = false
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
            if let legacyTilt = defaults.object(forKey: "realitykitTiltAngle") as? Float { 
                controlState.tiltAngle = legacyTilt
                tiltAngle = legacyTilt
                viewModel.streamSettings.realitykitRendererTilt = legacyTilt
                defaults.removeObject(forKey: "realitykitTiltAngle")
            }
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
        var didRestoreSavedPosition = false
        if viewModel.streamSettings.rememberStreamSettings {
            if let savedPosX = defaults.object(forKey: "realitykitImmersivePosX") as? Float,
               let savedPosY = defaults.object(forKey: "realitykitImmersivePosY") as? Float,
               let savedPosZ = defaults.object(forKey: "realitykitImmersivePosZ") as? Float {
                screenPosition = SIMD3<Float>(savedPosX, savedPosY, savedPosZ)
                didRestoreSavedPosition = true
            } else if let packed = defaults.array(forKey: kImmersivePosKey) as? [Float], packed.count == 3 {
                screenPosition = SIMD3<Float>(packed[0], packed[1], packed[2])
                didRestoreSavedPosition = true
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
        // When using the hardcoded default position (no prior saved transform),
        // recenter relative to the user's actual head position once tracking is ready.
        needsInitialRecenter = !didRestoreSavedPosition
        if let savedImmersion = defaults.object(forKey: "realitykitImmersionAmount") as? Float {
            immersionAmount = savedImmersion
        }
        if let savedLocked = defaults.object(forKey: kImmersiveLockedKey) as? Bool {
            controlState.isInteractive = savedLocked
        }
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
            guard (self.dimLevel == 2 || self.dimLevel == 10 || self.viewModel.streamSettings.reactiveLightingEnabled), let purple = self.dimmerDomePurple else { return }
            
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
        let currentMode = SpatialAudioMode(rawValue: viewModel.streamSettings.spatialAudioMode) ?? .window
        AudioHelpers.applySpatialAudioMode(currentMode)
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
        
        // Update Focus Catcher Entity
        // Volume window: a large invisible target helps keep controller / relative-mouse
        // gestures from falling through when the screen has no InputTarget.
        // Immersive space: NEVER attach InputTarget here — the 1000m box would steal
        // essentially all spatial input (gaze, system gestures, etc.) until leaving immersion.
        if inputMode == .controller && !isImmersive {
            focusCatcherEntity.isEnabled = true
            focusCatcherEntity.components.set(InputTargetComponent(allowedInputTypes: .all))
        } else {
            focusCatcherEntity.isEnabled = false
            focusCatcherEntity.components.remove(InputTargetComponent.self)
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
        viewModel.streamSettings.realitykitRendererTilt = viewModel.streamSettings.realitykitAutoPitchFollow ? 0.0 : tiltAngle
        defaults.set(viewModel.streamSettings.realitykitAutoPitchFollow, forKey: "realitykitAutoPitchFollow")
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

struct PCModifierToolbar<Content: View>: View {
    @State private var ctrlActive = false
    @State private var altActive = false
    @State private var shiftActive = false
    @State private var winActive = false
    
    @ViewBuilder let textField: Content

    var body: some View {
        HStack(spacing: 12) {
            Button("Esc") { sendInstantKey(0x1B) }
                .buttonStyle(.bordered)
            Button("Tab") { sendInstantKey(0x09) }
                .buttonStyle(.bordered)
            
            Divider().frame(height: 24)
            
            textField
            
            Divider().frame(height: 24)
            
            Toggle("Win", isOn: Binding(get: { winActive }, set: { val in
                winActive = val; sendToggleKey(0x5B, down: val)
            })).toggleStyle(.button)
            
            Toggle("Ctrl", isOn: Binding(get: { ctrlActive }, set: { val in
                ctrlActive = val; sendToggleKey(0xA2, down: val)
            })).toggleStyle(.button)
            
            Toggle("Alt", isOn: Binding(get: { altActive }, set: { val in
                altActive = val; sendToggleKey(0xA4, down: val)
            })).toggleStyle(.button)
            
            Toggle("Shift", isOn: Binding(get: { shiftActive }, set: { val in
                shiftActive = val; sendToggleKey(0xA0, down: val)
            })).toggleStyle(.button)
        }
        .padding(12)
        .glassBackgroundEffect()
    }
    
    private func sendInstantKey(_ keyCode: Int16) {
        let hidCode = Int16(bitPattern: 0x8000 | UInt16(keyCode))
        LiSendKeyboardEvent(hidCode, 0x03, 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            LiSendKeyboardEvent(hidCode, 0x04, 0)
        }
    }
    
    private func sendToggleKey(_ keyCode: Int16, down: Bool) {
        let hidCode = Int16(bitPattern: 0x8000 | UInt16(keyCode))
        LiSendKeyboardEvent(hidCode, down ? 0x03 : 0x04, 0)
    }
}

let MAX_WIDTH_METERS: Float = 2.0
let MAX_CURVE_ANGLE: Float = 1.3
let CURVED_MAX_WIDTH_METERS: Float = MAX_WIDTH_METERS
let CURVED_MAX_ANGLE: Float = MAX_CURVE_ANGLE
let GAZE_VERTICAL_OFFSET: Float = 0.015

extension CollisionGroup {
    static let screenEntity = CollisionGroup(rawValue: 1 << 0)
    static let uiElements = CollisionGroup(rawValue: 1 << 1)
}
