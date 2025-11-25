//
//  RealityKitStreamView.swift
//  Moonlight Vision
//
//  Created by tht7 on 29/12/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import GameController
import RealityKit
import SwiftUI
import simd

let MAX_WIDTH_METERS: Float = 2
// Limited to ~75 degrees (1.3 rad) to prevent distortion
let MAX_CURVE_ANGLE: Float = 1.3

// MARK: - Delegate
@objc
class DummyControllerDelegate: NSObject, ControllerSupportDelegate {
    func gamepadPresenceChanged() {}
    func mousePresenceChanged() {}
    func streamExitRequested() {}
}

// MARK: - Wrapper View
struct RealityKitStreamView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    
    @Binding var streamConfig: StreamConfiguration?
    var needsHdr: Bool
    var isImmersive: Bool
    
    var body: some View {
        if streamConfig != nil {
            _RealityKitStreamView(
                streamConfig: Binding<StreamConfiguration>(
                    get: { streamConfig ?? StreamConfiguration() },
                    set: { streamConfig = $0 }
                ),
                needsHdr: needsHdr,
                isImmersive: isImmersive
            ) {
                // --- CLOSE ACTION ---
                print("[RealityKitStreamView] Close Action Triggered.")
                
                // 1. Dismiss the current space/window
                if isImmersive {
                    Task { await dismissImmersiveSpace() }
                } else {
                    dismissWindow(id: "realitykitStreamingWindow")
                }
                
                // 2. Clear config to trigger the 'else' block below
                streamConfig = nil
            }
        } else {
            // Cleanup View (Triggers when streamConfig becomes nil)
            ProgressView().onAppear {
                print("[RealityKitStreamView] Stream Ended. Cleaning up.")
                
                // Redundant safety dismissal
                if isImmersive {
                    Task { await dismissImmersiveSpace() }
                } else {
                    dismissWindow(id: "realitykitStreamingWindow")
                }
            }
        }
    }
}

// MARK: - Main Logic View
struct _RealityKitStreamView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var viewModel: MainViewModel

    @Binding var streamConfig: StreamConfiguration
    var needsHdr: Bool
    var isImmersive: Bool
    let closeAction: () -> Void

    // UI State
    @State private var showVirtualKeyboard = false
    @State var curveMagnitudeMemory: Float = 0
    @State var curveAnimationMultiplier: Float = 1
    @State var controllerSupport: ControllerSupport?
    
    // Tracks when the texture instance has been replaced
    @State private var textureId: UUID = UUID()
    
    // Interaction State
    @State private var isInteractive: Bool = false
    
    // Controls State (Hidable/Movable)
    @State private var isControlsVisible: Bool = true
    @State private var controlsEntity: Entity?
    @State private var startControlsDragPosition: SIMD3<Float>? = nil
    
    // Volumetric Position State
    @State var height: Float = 0
    @State private var depthOffset: Float = 0.0
    @State private var yLimits: ClosedRange<Float> = -0.5...0.5
    @State private var zLimits: ClosedRange<Float> = -0.5...0.5
    
    // Immersive Transform State
    @State private var immersiveScale: Float = 1.8
    @State private var immersivePosition: SIMD3<Float> = SIMD3<Float>(0, 1.5, -2.0)
    @State private var startDragPosition: SIMD3<Float>? = nil
    
    // Immersion State
    @State private var immersionAmount: Float = 0.0
    @State private var blackOutSphere: ModelEntity = ModelEntity()
    
    // HDR Settings (Thread Safe)
    @State private var safeHDRSettings = ThreadSafeHDRSettings(
        params: HDRParams(boost: 2.0, contrast: 1.0, saturation: 1.0, brightness: 0.0)
    )
    
    @State var shouldClose: Bool = false
    @State var hasPerformedTeardown = false
    @State var needsResume = false
    @State var didPerformFullClose = false
    @State var animationTimer: Timer?
    @State var _streamMan: StreamManager?
    @ObservedObject var connectionCallbacks: ObservableConnectionManager = .init()

    @State var texture: TextureResource
    @State var screen: ModelEntity = ModelEntity()
    
    @State var videoMode: VideoMode = .standard2D
    @State private var surfaceMaterial: ShaderGraphMaterial?

    var isSBSVideo: Bool {
        let ratio = Float(streamConfig.width) / Float(streamConfig.height)
        return abs(ratio - (32.0 / 9.0)) < 0.01
    }

    var aspectRatio: Float {
        if videoMode == .sideBySide3D && isSBSVideo {
            return Float(streamConfig.height) / Float(streamConfig.width / 2)
        } else {
            return Float(streamConfig.height) / Float(streamConfig.width)
        }
    }
    
    init(streamConfig: Binding<StreamConfiguration>, needsHdr: Bool, isImmersive: Bool, closeAction: @escaping () -> Void) {
        self.closeAction = closeAction
        self._streamConfig = streamConfig
        self.needsHdr = needsHdr
        self.isImmersive = isImmersive
        self.controllerSupport = ControllerSupport(config: streamConfig.wrappedValue, delegate: DummyControllerDelegate())
        
        // ADAPTIVE PIXEL FORMAT: Fixes Cyan screen on SDR and enables HDR on AV1/HEVC
        let bytesPerPixel = needsHdr ? 8 : 4
        let data = Data.init(count: bytesPerPixel * Int(streamConfig.wrappedValue.width) * Int(streamConfig.wrappedValue.height))
        
        self.texture = try! TextureResource(
            dimensions: .dimensions(width: Int(streamConfig.wrappedValue.width), height: Int(streamConfig.wrappedValue.height)),
            format: .raw(pixelFormat: needsHdr ? .rgba16Float : .bgra8Unorm_srgb), // Adaptive format
            contents: .init(
                mipmapLevels: [
                    .mip(data: data, bytesPerRow: bytesPerPixel * Int(streamConfig.wrappedValue.width)),
                ]
            )
        )
    }

    // MARK: - Main Body
    var body: some View {
        // 1. Base Content Group
        let baseContent = Group {
            if viewModel.activelyStreaming {
                activeStreamView
            } else {
                streamStoppedOverlay
            }
        }

        // 2. Apply Visual Modifiers
        let visualContent = baseContent
            .task {
                await setupMaterial()
            }
            .ornament(visibility: connectionCallbacks.showAlert ? .visible :  .hidden , attachmentAnchor: .scene(.bottomFront), contentAlignment: .bottom) {
                errorOrnament
            }
            .modifier(VolumetricWindowControls(isImmersive: isImmersive, content: { controlsView }))
            .persistentSystemOverlays(viewModel.streamSettings.dimPassthrough ? .hidden : .automatic)
            .preferredSurroundingsEffect(viewModel.streamSettings.dimPassthrough ? .systemDark : nil)
            .volumeBaseplateVisibility(viewModel.streamSettings.dimPassthrough ? .hidden : .automatic)
            .supportedVolumeViewpoints(.front)

        func updateHDRParams() {
            safeHDRSettings.value = HDRParams(
                boost: viewModel.streamSettings.brightness,
                contrast: viewModel.streamSettings.gamma,
                saturation: viewModel.streamSettings.saturation,
                brightness: 0.0
            )
        }
        
        // 3. Apply Logic/Lifecycle Modifiers and Return
        return visualContent
            .onChange(of: viewModel.streamSettings.brightness) { _, _ in updateHDRParams() }
            .onChange(of: viewModel.streamSettings.gamma) { _, _ in updateHDRParams() }
            .onChange(of: viewModel.streamSettings.saturation) { _, _ in updateHDRParams() }
            .onAppear {
                // 1. Initialize HDR Settings
                safeHDRSettings.value = HDRParams(
                    boost: viewModel.streamSettings.brightness,
                    contrast: viewModel.streamSettings.gamma,
                    saturation: viewModel.streamSettings.saturation,
                    brightness: 0.0
                )
                
                // 2. Validate and Start
                if !viewModel.activelyStreaming {
                    print("_RealityKitStreamView: Detected appearance without active stream state.")
                    openWindow(id: "mainView")
                    self.closeAction()
                } else {
                    startStreamIfNeeded()
                }
            }
            .onChange(of: shouldClose) { _, val in
                if val {
                    triggerCloseSequence()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhaseChange(phase)
            }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    var activeStreamView: some View {
        GeometryReader3D { proxy in
            ZStack {
                // 1. GLOBAL INPUT CAPTURE (NON-IMMERSIVE ONLY)
                if !isImmersive, let support = controllerSupport {
                    RealityKitInputView(
                        streamConfig: streamConfig,
                        controllerSupport: support,
                        showKeyboard: $showVirtualKeyboard
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(0.01)
                }

                // 2. The 3D Screen
                makeRealityView(proxy: proxy)
                
                // 3. Keyboard Overlay
                if showVirtualKeyboard {
                    virtualKeyboardOverlay
                }
            }
        }
    }
    
    @ViewBuilder
        func makeRealityView(proxy: GeometryProxy3D) -> some View {
            RealityView { content, attachments in
                setupRealityView(content: content, attachments: attachments)
            } update: { content, attachments in
                updateStreamEntity(content: content, attachments: attachments, proxy: proxy)
            } attachments: {
                // Attachments
                Attachment(id: "controls") {
                    if isImmersive {
                        if isControlsVisible {
                            // Full Controls
                            VStack(spacing: 0) {
                                // Drag Handle / Minimize Bar
                                HStack {
                                    // Drag Indicator
                                    Image(systemName: "line.3.horizontal")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 60, height: 44)
                                        .contentShape(Rectangle())
                                        .hoverEffect()
                                    
                                    Spacer()
                                    
                                    // HIDE BUTTON
                                    Button(action: { withAnimation { isControlsVisible = false } }) {
                                        Label("Hide", systemImage: "chevron.down")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial.opacity(0.3))
                                
                                controlsView
                                    .padding(.bottom, 20)
                            }
                            .frame(width: 600)
                            .glassBackgroundEffect()
                        } else {
                            // Minimized State
                            Button(action: { withAnimation { isControlsVisible = true } }) {
                                Label("Show Controls", systemImage: "slider.horizontal.3")
                            }
                            .glassBackgroundEffect()
                        }
                    }
                }
                
                // INPUT ATTACHMENT (IMMERSIVE ONLY)
                Attachment(id: "input_overlay") {
                    if isImmersive, let support = controllerSupport {
                        RealityKitInputView(
                            streamConfig: streamConfig,
                            controllerSupport: support,
                            showKeyboard: $showVirtualKeyboard
                        )
                        .frame(width: 1920, height: 1920 / CGFloat(aspectRatio))
                        .opacity(0.01)
                    }
                }
            }
            // Gestures
            .gesture(dragGesture)
            .gesture(magnifyGesture)
            .gesture(controlsDragGesture)
        }
    
    // MARK: - Logic Helpers
    
    func triggerCloseSequence() {
        openWindow(id: "mainView")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.closeAction()
        }
    }
    
    func setupMaterial() async {
        if surfaceMaterial == nil {
            do {
                var material = try await ShaderGraphMaterial(named: "/Root/SBSMaterial", from: "SBSMaterial.usda")
                try material.setParameter(name: "texture", value: .textureResource(self.texture))
                self.surfaceMaterial = material
            } catch { print("Material Error: \(error)") }
        }
    }
    
    func setupRealityView(content: RealityViewContent, attachments: RealityViewAttachments) {
            let mesh = try! Self.generateCurvedPlane(
                width: MAX_WIDTH_METERS,
                aspectRatio: aspectRatio,
                resolution: (100,100),
                curveMagnitude: viewModel.streamSettings.realitykitRendererCurvature * curveAnimationMultiplier
            )
            
            let colDepth: Float = isImmersive ? 0.1 : 0.001
            let colBox = ShapeResource.generateBox(width: 2, height: 2 * aspectRatio, depth: colDepth)
                .offsetBy(translation: .init(x: 0, y: -0.43, z: 0))
            
            screen = ModelEntity(mesh: mesh, materials: [])

            if videoMode == .sideBySide3D, let material = surfaceMaterial {
                screen.model?.materials = [material]
            } else {
                screen.model?.materials = [UnlitMaterial(texture: self.texture)]
            }
            
            screen.collision = CollisionComponent(shapes: [colBox], mode: .colliding)
            screen.components.set(InputTargetComponent())
            content.add(screen)
            
            if isImmersive {
                let sphereMesh = MeshResource.generateSphere(radius: 100)
                let blackMaterial = UnlitMaterial(color: .black)
                blackOutSphere = ModelEntity(mesh: sphereMesh, materials: [blackMaterial])
                blackOutSphere.scale = SIMD3<Float>(-1, 1, 1)
                blackOutSphere.components.set(OpacityComponent(opacity: 0.0))
                content.add(blackOutSphere)
            }
            
            if isImmersive, let controls = attachments.entity(for: "controls") {
                self.controlsEntity = controls
                screen.addChild(controls)
                let screenHeight = MAX_WIDTH_METERS * aspectRatio
                controls.position = [0, -(screenHeight / 2.0) - 0.25, 0.1]
                controls.components.set(InputTargetComponent())
            }
            
            if isImmersive, let inputEnt = attachments.entity(for: "input_overlay") {
                screen.addChild(inputEnt)
                inputEnt.position = [0, 0, 0.01]
            }
        }
    
    func updateStreamEntity(content: RealityViewContent, attachments: RealityViewAttachments, proxy: GeometryProxy3D) {
            let currentCurve = viewModel.streamSettings.realitykitRendererCurvature * curveAnimationMultiplier
            
            if let mesh = try? Self.generateCurvedPlane(
                width: MAX_WIDTH_METERS,
                aspectRatio: aspectRatio,
                resolution: (100,100),
                curveMagnitude: currentCurve
            ) {
                try? screen.model!.mesh.replace(with: mesh.contents)
            }
            
            let totalAngle = MAX_CURVE_ANGLE * currentCurve.clamped(to: 0...1)
            let radius = totalAngle < 0.001 ? Float.infinity : (MAX_WIDTH_METERS / totalAngle)
            let curveDepth = totalAngle < 0.001 ? 0 : radius * (1.0 - cos(totalAngle / 2.0))
            let zCorrection = -curveDepth

            if isImmersive {
                screen.scale = SIMD3<Float>(repeating: immersiveScale)
                screen.position = immersivePosition + SIMD3<Float>(0, 0, zCorrection)
                blackOutSphere.components.set(OpacityComponent(opacity: immersionAmount))
                blackOutSphere.position = .zero
                
                if let inputEnt = attachments.entity(for: "input_overlay") {
                    let bounds = inputEnt.visualBounds(relativeTo: nil)
                    if bounds.extents.x > 0 {
                        let inputBuffer: Float = 1.15
                        let scale = (MAX_WIDTH_METERS / bounds.extents.x) * inputBuffer
                        inputEnt.scale = SIMD3<Float>(scale, scale, 1)
                    }
                }
            } else {
                let volSize = content.convert(proxy.frame(in: .local), from: .local, to: .scene).extents
                let scaleFactor = volSize.x / 2.0
                screen.scale = SIMD3<Float>(repeating: scaleFactor)
                updateWindowedLimits(volSize: volSize, scaleFactor: scaleFactor, curveDepth: curveDepth)
                screen.position = SIMD3<Float>(0, height, depthOffset + zCorrection)
            }
            updateAttachments(attachments: attachments)
        }
    
    func updateWindowedLimits(volSize: SIMD3<Float>, scaleFactor: Float, curveDepth: Float) {
            Task { @MainActor in
                let screenHalfHeight = (MAX_WIDTH_METERS * self.aspectRatio * scaleFactor) / 2
                let volHalfHeight = volSize.y / 2
                let safePadding: Float = 0.05
                
                let maxY = max(0, volHalfHeight - screenHalfHeight - safePadding)
                let newYLimits = -maxY...maxY
                
                let volHalfDepth = volSize.z / 2
                let maxZ = volHalfDepth - safePadding
                let scaledCurveDepth = curveDepth * scaleFactor
                let minZ = -volHalfDepth + scaledCurveDepth + safePadding
                let safeMaxZ = max(minZ, maxZ)
                let newZLimits = minZ...safeMaxZ
                
                if self.yLimits != newYLimits {
                    self.yLimits = newYLimits
                    if self.height < newYLimits.lowerBound { self.height = newYLimits.lowerBound }
                    else if self.height > newYLimits.upperBound { self.height = newYLimits.upperBound }
                }
                
                if self.zLimits != newZLimits {
                    self.zLimits = newZLimits
                    if self.depthOffset < newZLimits.lowerBound { self.depthOffset = newZLimits.lowerBound }
                    else if self.depthOffset > newZLimits.upperBound { self.depthOffset = newZLimits.upperBound }
                }
            }
        }
    
    func updateAttachments(attachments: RealityViewAttachments) {
        // Attachments handled in RealityViewBuilder
    }
    
    var dragGesture: some Gesture {
        DragGesture()
            .targetedToEntity(screen)
            .onChanged { value in
                guard isImmersive, !isInteractive else { return }
                if startDragPosition == nil { startDragPosition = immersivePosition }
                let translation = value.convert(value.translation3D, from: .local, to: .scene)
                immersivePosition = startDragPosition! + SIMD3<Float>(translation.x, translation.y, translation.z)
            }
            .onEnded { _ in
                startDragPosition = nil
                if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
            }
    }
    
    var controlsDragGesture: some Gesture {
        DragGesture()
            .targetedToEntity(controlsEntity ?? screen)
            .onChanged { value in
                guard isImmersive else { return }
                guard let entity = controlsEntity,
                      value.entity == entity,
                      let parent = entity.parent else { return }
                
                if startControlsDragPosition == nil { startControlsDragPosition = entity.position }
                
                let translationScene3D = value.convert(value.translation3D, from: .local, to: .scene)
                let translationSceneVector = SIMD3<Float>(Float(translationScene3D.x), Float(translationScene3D.y), Float(translationScene3D.z))
                let translationParentVector = parent.convert(direction: translationSceneVector, from: nil)
                
                entity.position = startControlsDragPosition! + translationParentVector
            }
            .onEnded { _ in
                startControlsDragPosition = nil
            }
    }
    
    var magnifyGesture: some Gesture {
        MagnifyGesture()
            .targetedToEntity(screen)
            .onChanged { value in
                guard isImmersive, !isInteractive else { return }
                let newScale = immersiveScale * Float(value.magnification)
                immersiveScale = min(max(newScale, 0.05), 10.0)
            }
            .onEnded { _ in
                if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
            }
    }
    
    // MARK: - Stream Management
    
    private func startStreamIfNeeded() {
        guard _streamMan == nil else {
            needsResume = false
            return
        }

        dismissWindow(id: "mainView")
        dismissWindow(id: "dummy")

        self.curveAnimationMultiplier = viewModel.streamSettings.realitykitRendererAnimateOpening ? 0 : 1
        didPerformFullClose = false
        
        self._streamMan = StreamManager(
            config: self.streamConfig,
            rendererProvider: {
                DrawableVideoDecoder(
                    texture: self.texture,
                    callbacks: self.connectionCallbacks,
                    aspectRatio: Float(self.streamConfig.width) / Float(self.streamConfig.height),
                    useFramePacing: self.streamConfig.useFramePacing,
                    enableHDR: self.viewModel.streamSettings.enableHdr,
                    hdrSettingsProvider: { [safeHDRSettings] in
                        return safeHDRSettings.value
                    },
                    callbackToRender: { texture, correctedResultion in
                        DispatchQueue.main.async {
                            if let correctedResultion = correctedResultion {
                                streamConfig.width = Int32(correctedResultion.0)
                                streamConfig.height = Int32(correctedResultion.1)
                            }
                            self.texture.replace(withDrawables: texture)
                            self.controllerSupport!.connectionEstablished()
                            if self.curveAnimationMultiplier == 0 { animateOpening() }
                        }
                    })
            },
            connectionCallbacks: self.connectionCallbacks
        )
        let operationQueue = OperationQueue()
        operationQueue.addOperation(_streamMan!)
        needsResume = false
    }

    private func pauseStreamForBackground() {
        guard _streamMan != nil else { return }
        stopStream(teardownCompletely: false)
    }

    private func handleUserRequestedClose() {
        stopStream(teardownCompletely: true)
        DispatchQueue.main.async {
            openWindow(id: "mainView")
        }
    }

    private func stopStream(teardownCompletely: Bool) {
        _streamMan?.stopStream()
        _streamMan = nil
        controllerSupport?.cleanup()

        if teardownCompletely {
            if didPerformFullClose { return }
            didPerformFullClose = true
            viewModel.activelyStreaming = false
            needsResume = false
            self.closeAction()
        } else {
            needsResume = true
        }
    }

    private func handleSceneDisappearance() {
        guard !didPerformFullClose else { return }
        guard !needsResume else { return }
        handleUserRequestedClose()
    }
    
    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            guard !hasPerformedTeardown else { return }
            guard !shouldClose else { return }
            needsResume = true
            hasPerformedTeardown = true
            viewModel.activelyStreaming = false
            _streamMan?.stopStream()
            controllerSupport?.cleanup()
            
        case .active:
            guard needsResume else { return }
            guard !shouldClose else { return }
            guard streamConfig != nil else { return }
            
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000)
                await MainActor.run {
                    guard needsResume else { return }
                    guard !shouldClose else { return }
                    guard streamConfig != nil else { return }
                    
                    needsResume = false
                    hasPerformedTeardown = false
                    viewModel.activelyStreaming = true
                    startStreamIfNeeded()
                }
            }
        default:
            break
        }
    }
    
    func animateOpening() {
        Task {
            self.animationTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
                Task { @MainActor in
                    if self.curveAnimationMultiplier < 1 {
                        self.curveAnimationMultiplier = min(self.curveAnimationMultiplier + 0.01, 1)
                    } else {
                        self.animationTimer?.invalidate(); self.animationTimer = nil
                    }
                }
            }
            self.animationTimer?.fire()
        }
    }
    
    private func loadRealityKitSettings() {
        let defaults = UserDefaults.standard
        if let savedHeight = defaults.object(forKey: "realitykitHeight") as? Float { height = savedHeight }
        if let savedDepthOffset = defaults.object(forKey: "realitykitDepthOffset") as? Float { depthOffset = savedDepthOffset }
        if let savedScale = defaults.object(forKey: "realitykitImmersiveScale") as? Float { immersiveScale = savedScale }
        if let savedPosX = defaults.object(forKey: "realitykitImmersivePosX") as? Float,
           let savedPosY = defaults.object(forKey: "realitykitImmersivePosY") as? Float,
           let savedPosZ = defaults.object(forKey: "realitykitImmersivePosZ") as? Float {
            immersivePosition = SIMD3<Float>(savedPosX, savedPosY, savedPosZ)
        }
        if let savedImmersion = defaults.object(forKey: "realitykitImmersionAmount") as? Float { immersionAmount = savedImmersion }
        if let savedGamma = defaults.object(forKey: "realitykitGamma") as? Float { viewModel.streamSettings.gamma = savedGamma }
        if let savedSat = defaults.object(forKey: "realitykitSaturation") as? Float { viewModel.streamSettings.saturation = savedSat }
    }
    
    private func saveRealityKitSettings() {
        guard viewModel.streamSettings.rememberStreamSettings else { return }
        let defaults = UserDefaults.standard
        defaults.set(viewModel.streamSettings.gamma, forKey: "realitykitGamma")
        defaults.set(viewModel.streamSettings.saturation, forKey: "realitykitSaturation")
        defaults.set(height, forKey: "realitykitHeight")
        defaults.set(depthOffset, forKey: "realitykitDepthOffset")
        defaults.set(immersiveScale, forKey: "realitykitImmersiveScale")
        defaults.set(immersivePosition.x, forKey: "realitykitImmersivePosX")
        defaults.set(immersivePosition.y, forKey: "realitykitImmersivePosY")
        defaults.set(immersivePosition.z, forKey: "realitykitImmersivePosZ")
        defaults.set(immersionAmount, forKey: "realitykitImmersionAmount")
    }
    
    // MARK: - View Components
    
    @ViewBuilder
    var virtualKeyboardOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard").font(.system(size: 40))
            Text(viewModel.localized("keyboard_active")).font(.headline)
            Text(viewModel.localized("tap_video_to_type")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial)
        .cornerRadius(16)
        .allowsHitTesting(true)
        .onTapGesture {
            showVirtualKeyboard = true
        }
        .opacity(0.8)
    }
    
    @ViewBuilder
    var streamStoppedOverlay: some View {
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
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(viewModel.localized("stream_stopped")).font(.title2)
                Text(viewModel.localized("stream_stopped_message")).multilineTextAlignment(.center).padding(.horizontal)
                Button {
                    viewModel.savedStreamConfigForResume = nil
                    triggerCloseSequence()
                } label: {
                    Label(viewModel.localized("open_main_menu"), systemImage: "house.fill").frame(maxWidth: .infinity)
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
    var errorOrnament: some View {
        VStack(alignment: .center) {
            Image(systemName: "exclamationmark.triangle")
            Text(viewModel.localized("stream_error")).font(.title)
            Text(connectionCallbacks.errorMessage ?? viewModel.localized("unknown_error"))
            Button(viewModel.localized("close")) {
                viewModel.activelyStreaming = false
                shouldClose.toggle()
            }
        }
        .padding().glassBackgroundEffect()
    }
    
    @ViewBuilder
    var controlsView: some View {
        StreamControls(
            horizontal: false,
            streamConfig: $streamConfig,
            isKeyboardActive: showVirtualKeyboard,
            closeAction: {
                if streamConfig != nil { viewModel.savedStreamConfigForResume = streamConfig }
                needsResume = false
                hasPerformedTeardown = false
                viewModel.activelyStreaming = false
                self._streamMan?.stopStream()
                self.controllerSupport?.cleanup()
                triggerCloseSequence()
            },
            toggleKeyboardAction: { showVirtualKeyboard.toggle() }
        ) {
            settingsControls
        }
    }
    
    @ViewBuilder
    var settingsControls: some View {
        let labelWidth: CGFloat = 70
        let sliderWidth: CGFloat = 170
        
        if needsHdr || viewModel.streamSettings.enableHdr {
            HStack {
                Text(viewModel.localized("boost"))
                    .font(.caption).bold()
                    .frame(width: labelWidth, alignment: .leading)
                    .help(viewModel.localized("boost_luminance"))
                
                Slider(value: $viewModel.streamSettings.brightness, in: 1.0...5.0, step: 0.1)
                    .frame(width: sliderWidth)
                    .onChange(of: viewModel.streamSettings.brightness) { _, _ in
                        if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                    }
                Text(String(format: "%.1f", viewModel.streamSettings.brightness))
                    .font(.caption).monospacedDigit().frame(width: 35, alignment: .leading)
            }
            .padding(.vertical, 2)
            
            HStack {
                Text(viewModel.localized("gamma"))
                    .font(.caption).bold()
                    .frame(width: labelWidth, alignment: .leading)
                
                Slider(value: $viewModel.streamSettings.gamma, in: 0.5...2.5, step: 0.05)
                    .frame(width: sliderWidth)
                    .onChange(of: viewModel.streamSettings.gamma) { _, _ in
                        if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                    }
                Text(String(format: "%.2f", viewModel.streamSettings.gamma))
                    .font(.caption).monospacedDigit().frame(width: 35, alignment: .leading)
            }
            
            HStack {
                Text(viewModel.localized("saturation"))
                    .font(.caption).bold()
                    .frame(width: labelWidth, alignment: .leading)
                
                Slider(value: $viewModel.streamSettings.saturation, in: 0.0...2.0, step: 0.05)
                    .frame(width: sliderWidth)
                    .onChange(of: viewModel.streamSettings.saturation) { _, _ in
                        if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                    }
                Text(String(format: "%.2f", viewModel.streamSettings.saturation))
                    .font(.caption).monospacedDigit().frame(width: 35, alignment: .leading)
            }
            Divider().padding(.vertical, 5)
        }
        
        HStack {
            Text(viewModel.localized("curvature"))
                .font(.caption).bold()
                .frame(width: labelWidth, alignment: .leading)
            
            Slider(value: $viewModel.streamSettings.realitykitRendererCurvature, in: 0 ... 1, step: 0.001)
                .frame(width: sliderWidth)
                .onChange(of: viewModel.streamSettings.realitykitRendererCurvature) { _, _ in
                    if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                }
            Text(String(format: "%.2f", viewModel.streamSettings.realitykitRendererCurvature))
                .font(.caption).monospacedDigit().frame(width: 35, alignment: .leading)
            
            Button(action: {
                if viewModel.streamSettings.realitykitRendererCurvature == 0 {
                    viewModel.streamSettings.realitykitRendererCurvature = curveMagnitudeMemory
                } else {
                    curveMagnitudeMemory = viewModel.streamSettings.realitykitRendererCurvature
                    viewModel.streamSettings.realitykitRendererCurvature = 0
                }
                if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
            }) {
                Label(viewModel.localized("flatten"), systemImage: viewModel.streamSettings.realitykitRendererCurvature == 0 ? "light.panel" : "pano.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.mini)
        }

        if !isImmersive {
            HStack {
                Text(viewModel.localized("depth"))
                    .font(.caption).bold()
                    .frame(width: labelWidth, alignment: .leading)
                
                Slider(value: $depthOffset, in: zLimits)
                    .frame(width: sliderWidth)
                    .onChange(of: depthOffset) { _, _ in
                        if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                    }
                Text(String(format: "%.2f", depthOffset))
                    .font(.caption).monospacedDigit().frame(width: 35, alignment: .leading)
                
                Button(action: {
                    depthOffset = 0.0
                    if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                }) {
                    Label(viewModel.localized("reset_depth"), systemImage: "arrow.counterclockwise").font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.mini)
            }
            
            HStack {
                Text(viewModel.localized("height"))
                    .font(.caption).bold()
                    .frame(width: labelWidth, alignment: .leading)
                
                Slider(value: $height, in: yLimits)
                    .frame(width: sliderWidth)
                    .onChange(of: height) { _, _ in
                        if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                    }
                Text(String(format: "%.2f", height))
                    .font(.caption).monospacedDigit().frame(width: 35, alignment: .leading)
                Spacer().frame(width: 40)
            }
        } else {
            Divider().padding(.vertical, 5)
            Text(viewModel.localized("spatial")).font(.caption).foregroundStyle(.secondary)
            
            HStack {
                Text(viewModel.localized("immersion"))
                    .font(.caption).bold().frame(width: labelWidth, alignment: .leading)
                Slider(value: $immersionAmount, in: 0.0...1.0)
                    .frame(width: sliderWidth)
                    .onChange(of: immersionAmount) { _, _ in if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() } }
                Text(String(format: "%.0f%%", immersionAmount * 100)).font(.caption).monospacedDigit().frame(width: 35, alignment: .leading)
            }
            
            HStack {
                Text(viewModel.localized("scale"))
                    .font(.caption).bold().frame(width: labelWidth, alignment: .leading)
                Slider(value: $immersiveScale, in: 0.5...6.0)
                    .frame(width: sliderWidth)
                    .onChange(of: immersiveScale) { _, _ in if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() } }
                Text(String(format: "%.1fx", immersiveScale)).font(.caption).monospacedDigit().frame(width: 35, alignment: .leading)
            }
            
            HStack {
                Text(viewModel.localized("distance"))
                    .font(.caption).bold().frame(width: labelWidth, alignment: .leading)
                Slider(value: Binding(get: { immersivePosition.z }, set: { immersivePosition.z = $0; if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() } }), in: -10.0 ... -0.5).frame(width: sliderWidth)
                Text(String(format: "%.1fm", abs(immersivePosition.z))).font(.caption).monospacedDigit().frame(width: 35, alignment: .leading)
            }
            
            HStack {
                Text(viewModel.localized("height"))
                    .font(.caption).bold().frame(width: labelWidth, alignment: .leading)
                Slider(value: Binding(get: { immersivePosition.y }, set: { immersivePosition.y = $0; if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() } }), in: 0.0 ... 5.0).frame(width: sliderWidth)
                Text(String(format: "%.1fm", immersivePosition.y)).font(.caption).monospacedDigit().frame(width: 35, alignment: .leading)
            }
            
            Toggle(isOn: $isInteractive) {
                Label(isInteractive ? viewModel.localized("screen_locked") : viewModel.localized("screen_unlocked"), systemImage: isInteractive ? "lock.fill" : "lock.open.fill")
            }.toggleStyle(.button).padding(.top, 5)
        }

        HStack {
            Toggle(isOn: Binding(get: { videoMode == .sideBySide3D }, set: { val in
                videoMode = val ? .sideBySide3D : .standard2D
                if videoMode == .sideBySide3D {
                    screen.model?.materials = [surfaceMaterial!]
                } else {
                    screen.model?.materials = [UnlitMaterial(texture: texture)]
                }
            })) {
                Label(viewModel.localized("3d_mode"), systemImage: "cube.transparent")
            }.toggleStyle(.button)
        }
        
        Button(action: { }) {
            Label(viewModel.localized("main_button"), systemImage: "gamecontroller.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if let controller = self.controllerSupport?.getOscController() {
                        self.controllerSupport?.setButtonFlag(controller, flags: 0x0400)
                        self.controllerSupport?.updateFinished(controller)
                    }
                }
                .onEnded { _ in
                    if let controller = self.controllerSupport?.getOscController() {
                        self.controllerSupport?.clearButtonFlag(controller, flags: 0x0400)
                        self.controllerSupport?.updateFinished(controller)
                    }
                }
        )
    }
    
    static func generateCurvedPlane(width: Float, aspectRatio: Float, resolution: (UInt32, UInt32), curveMagnitude: Float) throws -> MeshResource {
        var descr = MeshDescriptor(name: "curved_plane_smart")
        let height = width * aspectRatio
        if height.isNaN || height == 0 { print("🚨 [GenMesh] Calculated Height is INVALID") }

        let vertexCount = Int(resolution.0 * resolution.1)
        let triangleCount = Int((resolution.0 - 1) * (resolution.1 - 1) * 2)
        
        var positions: [SIMD3<Float>] = .init(repeating: .zero, count: vertexCount)
        var textureCoordinates: [SIMD2<Float>] = .init(repeating: .zero, count: vertexCount)
        var indices: [UInt32] = .init(repeating: 0, count: triangleCount * 3)

        let totalAngle = MAX_CURVE_ANGLE * curveMagnitude.clamped(to: 0...1)
        let isFlat = totalAngle < 0.0001
        let radius: Float = isFlat ? .infinity : (width / totalAngle)

        var vertexIndex = 0
        var indicesIndex = 0

        for y_v in 0 ..< resolution.1 {
            let v_geo = Float(y_v) / Float(resolution.1 - 1)
            let yPosition = (0.5 - v_geo) * height
            let v_tex = 1.0 - v_geo

            for x_v in 0 ..< resolution.0 {
                let u = Float(x_v) / Float(resolution.0 - 1)
                let xPosition: Float
                let zPosition: Float

                if !isFlat {
                    let theta = (u - 0.5) * totalAngle
                    xPosition = radius * sin(theta)
                    zPosition = radius - (radius * cos(theta))
                } else {
                    xPosition = (u - 0.5) * width
                    zPosition = 0.0
                }

                positions[vertexIndex] = [xPosition, yPosition, zPosition]
                textureCoordinates[vertexIndex] = [u, v_tex]

                if x_v < (resolution.0 - 1) && y_v < (resolution.1 - 1) {
                    let current = UInt32(vertexIndex)
                    let nextRow = current + resolution.0
                    indices[indicesIndex...] = [current, nextRow, nextRow+1, current, nextRow+1, current+1]
                    indicesIndex += 6
                }
                vertexIndex += 1
            }
        }
        descr.positions = MeshBuffer(positions)
        descr.textureCoordinates = MeshBuffers.TextureCoordinates(textureCoordinates)
        descr.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descr])
    }
}

// Custom Modifier to conditionalize ornaments
struct VolumetricWindowControls<ControlsContent: View>: ViewModifier {
    var isImmersive: Bool
    @ViewBuilder var content: () -> ControlsContent

    @ViewBuilder
    func body(content: Content) -> some View {
        if !isImmersive {
            content.ornament(attachmentAnchor: .scene(.bottomTrailingFront), contentAlignment: .bottomLeading) {
                self.content()
            }
        } else {
            content
        }
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}

class ThreadSafeHDRSettings: @unchecked Sendable {
    private var params: HDRParams
    private let lock = NSLock()
    init(params: HDRParams) { self.params = params }
    var value: HDRParams {
        get { lock.lock(); defer { lock.unlock() }; return params }
        set { lock.lock(); defer { lock.unlock() }; params = newValue }
    }
}

// MARK: - INTEGRATED INPUT CONTROLLER

// --- C-Function Bridges (Manual Linking) ---
@_silgen_name("LiSendMouseButtonEvent")
func LiSendMouseButtonEvent(_ action: Int8, _ button: Int32) -> Int32

@_silgen_name("LiSendMousePositionEvent")
func LiSendMousePositionEvent(_ x: Int16, _ y: Int16, _ width: Int16, _ height: Int16) -> Int32

@_silgen_name("LiSendHighResScrollEvent")
func LiSendHighResScrollEvent(_ scrollAmount: Int16) -> Int32

@_silgen_name("LiSendHighResHScrollEvent")
func LiSendHighResHScrollEvent(_ scrollAmount: Int16) -> Int32

@_silgen_name("LiSendKeyboardEvent")
func LiSendKeyboardEvent(_ keyCode: Int16, _ keyAction: Int8, _ modifiers: Int8) -> Int32

@_silgen_name("LiSendUtf8TextEvent")
func LiSendUtf8TextEvent(_ text: UnsafePointer<CChar>, _ length: UInt32) -> Int32

// --- Constants ---
private let BUTTON_ACTION_PRESS: Int8 = 0
private let BUTTON_ACTION_RELEASE: Int8 = 1
private let BUTTON_LEFT: Int32 = 1
private let BUTTON_RIGHT: Int32 = 2
private let KEY_ACTION_DOWN: Int8 = 0x03
private let KEY_ACTION_UP: Int8 = 0x04

// --- SWIFTUI WRAPPER ---
struct RealityKitInputView: UIViewControllerRepresentable {
    var streamConfig: StreamConfiguration
    let controllerSupport: ControllerSupport
    @Binding var showKeyboard: Bool
    
    func makeUIViewController(context: Context) -> RealityKitInputViewController {
        let vc = RealityKitInputViewController()
        vc.streamConfig = streamConfig
        vc.controllerSupport = controllerSupport
        vc.keyboardDismissHandler = { DispatchQueue.main.async {} }
        return vc
    }

    func updateUIViewController(_ vc: RealityKitInputViewController, context: Context) {
        vc.streamConfig = streamConfig
        if let overlay = vc.view as? RealityKitInputOverlay {
            overlay.streamConfig = streamConfig
            if overlay.showSoftwareKeyboard != showKeyboard {
                overlay.showSoftwareKeyboard = showKeyboard
                if showKeyboard {
                    DispatchQueue.main.async { overlay.becomeFirstResponder() }
                }
            }
        }
    }
}

// --- VIEW CONTROLLER ---
class RealityKitInputViewController: UIViewController {
    var streamConfig: StreamConfiguration? {
        didSet {
            if let overlay = view as? RealityKitInputOverlay { overlay.streamConfig = streamConfig }
        }
    }
    var controllerSupport: ControllerSupport?
    var keyboardDismissHandler: (() -> Void)?
    
    private lazy var inputOverlayView: RealityKitInputOverlay = {
        let v = RealityKitInputOverlay()
        v.parentController = self
        return v
    }()
    
    override func loadView() { self.view = inputOverlayView }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        if let support = controllerSupport {
            support.attachGCEventInteraction(to: self.view)
            support.realityKitMode = true
            support.realityKitMouseMovedHandler = { [weak self] (dx: Float, dy: Float) in
                self?.inputOverlayView.handleRawMouseDelta(dx: dx, dy: dy)
            }
            support.realityKitKeyboardHandler = nil
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let support = controllerSupport {
            for mouse in GCMouse.mice() { support.registerMouseCallbacks(mouse) }
        }
        if !self.inputOverlayView.becomeFirstResponder() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                _ = self?.inputOverlayView.becomeFirstResponder()
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let support = controllerSupport {
            support.realityKitMode = false
            support.realityKitMouseMovedHandler = nil
            support.realityKitKeyboardHandler = nil
        }
    }
    
    override var canBecomeFirstResponder: Bool { false }
}

// --- OVERLAY VIEW ---
class RealityKitInputOverlay: UIView, UIKeyInput, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
    weak var parentController: RealityKitInputViewController?
    var streamConfig: StreamConfiguration?
    var showSoftwareKeyboard: Bool = false {
        didSet {
            DispatchQueue.main.async {
                if self.showSoftwareKeyboard && !self.isFirstResponder { self.becomeFirstResponder() }
                self.reloadInputViews()
            }
        }
    }
    
    override var inputView: UIView? { showSoftwareKeyboard ? nil : UIView() }
    private var currentMousePosition: CGPoint = .zero
    private var lastMouseButtonMask: UIEvent.ButtonMask = []
    private var lastScrollTranslation: CGPoint = .zero
    private let wheelDelta: CGFloat = 120.0
    
    override init(frame: CGRect) { super.init(frame: frame); setupInteraction() }
    required init?(coder: NSCoder) { super.init(coder: coder); setupInteraction() }
    
    private func setupInteraction() {
        self.backgroundColor = UIColor.black.withAlphaComponent(0.01)
        self.isMultipleTouchEnabled = true
        self.isUserInteractionEnabled = true
        self.addInteraction(UIPointerInteraction(delegate: self))
        let panScroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        panScroll.allowedScrollTypesMask = .all
        panScroll.delegate = self
        self.addGestureRecognizer(panScroll)
        self.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:))))
    }
    
    override var canBecomeFocused: Bool { true }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { parentController?.keyboardDismissHandler?() }
        return result
    }
    
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses { if KeyboardSupport.sendKeyEvent(for: press, down: true) { handled = true } }
        if !handled { super.pressesBegan(presses, with: event) }
    }
    
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses { if KeyboardSupport.sendKeyEvent(for: press, down: false) { handled = true } }
        if !handled { super.pressesEnded(presses, with: event) }
    }
    
    var hasText: Bool { true }
    func insertText(_ text: String) {
        if text.count == 1, let char = text.first {
            let utf16 = String(char).utf16.first!
            let keyEvent = KeyboardSupport.translateKeyEvent(utf16, with: [])
            if keyEvent.keycode != 0 { sendLowLevelEvent(event: keyEvent); return }
        }
        let cString = text.cString(using: .utf8)
        cString?.withUnsafeBufferPointer { ptr in if let base = ptr.baseAddress { LiSendUtf8TextEvent(base, UInt32(text.utf8.count)) } }
    }
    
    func deleteBackward() {
        LiSendKeyboardEvent(0x08, 0x03, 0)
        usleep(50 * 1000)
        LiSendKeyboardEvent(0x08, 0x04, 0)
    }
    
    private func sendLowLevelEvent(event: KeyEvent) {
        DispatchQueue.global(qos: .userInteractive).async {
            if event.modifier != 0 { LiSendKeyboardEvent(Int16(event.modifierKeycode), 0x03, Int8(event.modifier)) }
            LiSendKeyboardEvent(Int16(event.keycode), 0x03, Int8(event.modifier))
            usleep(50 * 1000)
            LiSendKeyboardEvent(Int16(event.keycode), 0x04, Int8(event.modifier))
            if event.modifier != 0 { LiSendKeyboardEvent(Int16(event.modifierKeycode), 0x04, Int8(event.modifier)) }
        }
    }
    
    func handleRawMouseDelta(dx: Float, dy: Float) {
        guard let config = streamConfig else { return }
        let sensitivity: CGFloat = 1.0
        var newX = currentMousePosition.x + (CGFloat(dx) * sensitivity)
        var newY = currentMousePosition.y - (CGFloat(dy) * sensitivity)
        let width = CGFloat(config.width); let height = CGFloat(config.height)
        newX = min(max(newX, 0), width); newY = min(max(newY, 0), height)
        currentMousePosition = CGPoint(x: newX, y: newY)
        LiSendMousePositionEvent(Int16(newX), Int16(newY), Int16(width), Int16(height))
    }
    
    func sendMouseButton(action: Int8, button: Int32) { LiSendMouseButtonEvent(action, button) }
    
    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        if lastMouseButtonMask.isEmpty { updateCursorFromSystemPointer(location: request.location) }
        return UIPointerRegion(rect: self.bounds)
    }
    
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { return nil }
    
    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        if lastMouseButtonMask.isEmpty { updateCursorFromSystemPointer(location: gesture.location(in: self)) }
    }
    
    private func updateCursorFromSystemPointer(location: CGPoint) {
        guard let config = streamConfig else { return }
        let inputBuffer: CGFloat = 1.15
        let rawNormX = location.x / self.bounds.width
        let rawNormY = location.y / self.bounds.height
        let correctedNormX = (rawNormX - 0.5) * inputBuffer + 0.5
        let correctedNormY = (rawNormY - 0.5) * inputBuffer + 0.5
        var hostX = correctedNormX * CGFloat(config.width)
        var hostY = correctedNormY * CGFloat(config.height)
        hostX = min(max(hostX, 0), CGFloat(config.width))
        hostY = min(max(hostY, 0), CGFloat(config.height))
        currentMousePosition = CGPoint(x: hostX, y: hostY)
        LiSendMousePositionEvent(Int16(hostX), Int16(hostY), Int16(config.width), Int16(config.height))
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendMouseButton(action: 0, button: 1)
        if let touch = touches.first { updateCursorFromSystemPointer(location: touch.location(in: self)) }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first { updateCursorFromSystemPointer(location: touch.location(in: self)) }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { sendMouseButton(action: 1, button: 1) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { sendMouseButton(action: 1, button: 1) }
    
    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .began else { lastScrollTranslation = .zero; return }
        let currentTranslation = gesture.translation(in: self)
        let deltaY = (currentTranslation.y - lastScrollTranslation.y)
        let deltaX = (currentTranslation.x - lastScrollTranslation.x)
        if deltaY != 0 { LiSendHighResScrollEvent(Int16((deltaY / self.bounds.height) * wheelDelta * 20.0)) }
        if deltaX != 0 { LiSendHighResHScrollEvent(Int16(-(deltaX / self.bounds.width) * wheelDelta * 20.0)) }
        lastScrollTranslation = currentTranslation
    }
}
