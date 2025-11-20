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

@objc
class DummyControllerDelegate: NSObject, ControllerSupportDelegate {
    func gamepadPresenceChanged() {}
    func mousePresenceChanged() {}
    func streamExitRequested() {}
}

struct RealityKitStreamView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    
    @Binding var streamConfig: StreamConfiguration?
    var needsHdr: Bool
    var isImmersive: Bool
    
    var body: some View {
        let cornerRadius = CGFloat(MainViewModel.shared.streamSettings.windowCornerRadius)
        // We unwrap the binding here to pass a non-optional binding to the internal view
        if streamConfig != nil {
            _RealityKitStreamView(
                streamConfig: Binding<StreamConfiguration>(
                    get: { streamConfig ?? StreamConfiguration() },
                    set: { streamConfig = $0 }
                ),
                needsHdr: needsHdr,
                isImmersive: isImmersive
                isImmersive: isImmersive
            ) {
                // Close Action
                if isImmersive {
                    Task { await dismissImmersiveSpace() }
                } else {
                    dismissWindow()
                }
                streamConfig = nil
            }
        } else {
            ProgressView().onAppear {
                if isImmersive {
                    Task { await dismissImmersiveSpace() }
                } else {
                    dismissWindow()
>>>>>>> 11169f0 (11.0.14 D Immersive Mode Added)
                }
            }
        }
    }
}

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
    
    // Interaction State (Immersive Only)
    @State private var isInteractive: Bool = true // If false, gestures move the screen
    
    // Volumetric Position State
    @State var height: Float = 0
    @State private var depthOffset: Float = 0.0
    @State private var yLimits: ClosedRange<Float> = -0.5...0.5
    @State private var zLimits: ClosedRange<Float> = -0.5...0.5
    
    // Immersive Transform State
    @State private var immersiveScale: Float = 1.8 // Default scale
    @State private var immersivePosition: SIMD3<Float> = SIMD3<Float>(0, 1.5, -2.0) // Default: 1.5m up, 2m away
    @State private var startDragPosition: SIMD3<Float>? = nil
    
    // --- NEW: Immersion (Black Out) State ---
    @State private var immersionAmount: Float = 0.0
    @State private var blackOutSphere: ModelEntity = ModelEntity()
    // ----------------------------------------
    
    @State private var safeHDRSettings = ThreadSafeHDRSettings(
            params: HDRParams(boost: 2.0, contrast: 1.0, saturation: 1.0, brightness: 0.0)
        )
    
    @State var shouldClose: Bool = false
    @State private var needsResume = false
    @State private var didPerformFullClose = false
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
        let bytesPerPixel = needsHdr ? 8 : 4
        let data = Data.init(count: bytesPerPixel * Int(streamConfig.wrappedValue.width) * Int(streamConfig.wrappedValue.height))
        self.texture = try! TextureResource(
            dimensions: .dimensions(width: Int(streamConfig.wrappedValue.width), height: Int(streamConfig.wrappedValue.height)),
            format: .raw(pixelFormat: needsHdr ? .rgba16Float : .bgra8Unorm_srgb),
            contents: .init(
                mipmapLevels: [ .mip(data: data, bytesPerRow: bytesPerPixel * Int(streamConfig.wrappedValue.width)) ]
            )
        )
    }

    var body: some View {
        if viewModel.activelyStreaming {
            let cornerRadius = CGFloat(viewModel.streamSettings.windowCornerRadius)
            GeometryReader3D { proxy in
                ZStack {
                    RealityView { content, attachments in
                        // 1. Setup Screen
                    let mesh = try! _RealityKitStreamView.generateCurvedPlane(
                        width: MAX_WIDTH_METERS,
                        aspectRatio: aspectRatio,
                        resolution: (100,100),
                        curveMagnitude: viewModel.streamSettings.realitykitRendererCurvature * curveAnimationMultiplier
                    )
                    
                    let colDepth: Float = isImmersive ? 0.1 : 0.001
                    let colBox = ShapeResource.generateBox(width: 2, height: 2 * aspectRatio, depth: colDepth)
                        .offsetBy(translation: .init(x: 0, y: -0.43, z: 0))
                    
                    screen = ModelEntity(mesh: mesh, materials: [])
                    if let material = surfaceMaterial {
                        screen.model?.materials = [material]
                    } else {
                        screen.model?.materials = [UnlitMaterial(texture: self.texture)]
                    }
                    
                    screen.collision = CollisionComponent(shapes: [colBox], mode: .colliding)
                    screen.components.set(InputTargetComponent())
                    content.add(screen)
                    
                    // 2. Setup "Black Out" Sphere (Immersive Only)
                    if isImmersive {
                        // Create a giant black sphere
                        let sphereMesh = MeshResource.generateSphere(radius: 100) // 100m radius
                        let blackMaterial = UnlitMaterial(color: .black)
                        
                        blackOutSphere = ModelEntity(mesh: sphereMesh, materials: [blackMaterial])
                        // Invert scale on X to flip the sphere inside-out so we see the color from inside
                        blackOutSphere.scale = SIMD3<Float>(-1, 1, 1)
                        
                        // Start invisible
                        blackOutSphere.components.set(OpacityComponent(opacity: 0.0))
                        
                        content.add(blackOutSphere)
                    }
                    
                    // 3. Attachments
                    if let inputAttachment = attachments.entity(for: "input_capture") {
                        screen.addChild(inputAttachment)
                        inputAttachment.position = [0, 0, 0.001]
                    }
                    
                    if isImmersive, let controls = attachments.entity(for: "controls") {
                        screen.addChild(controls)
                        let screenHeight = MAX_WIDTH_METERS * aspectRatio
                        controls.position = [0, -(screenHeight / 2.0) - 0.25, 0.1]
                    }
                    
                } update: { content, attachments in
                    let currentCurve = viewModel.streamSettings.realitykitRendererCurvature * curveAnimationMultiplier
                    let totalAngle = MAX_CURVE_ANGLE * currentCurve.clamped(to: 0...1)
                    
                    // --- UPDATE MESH ---
                    let mesh = try! _RealityKitStreamView.generateCurvedPlane(
                        width: MAX_WIDTH_METERS,
                        aspectRatio: aspectRatio,
                        resolution: (100,100),
                        curveMagnitude: currentCurve
                    )
                    
                    let radius = totalAngle < 0.001 ? Float.infinity : (MAX_WIDTH_METERS / totalAngle)
                    let curveDepth = totalAngle < 0.001 ? 0 : radius * (1.0 - cos(totalAngle / 2.0))
                    let zCorrection = -curveDepth

                    // --- APPLY TRANSFORMS ---
                    if isImmersive {
                        screen.scale = SIMD3<Float>(repeating: immersiveScale)
                        screen.position = immersivePosition + SIMD3<Float>(0, 0, zCorrection)
                        
                        // Update Black Out Sphere Opacity
                        blackOutSphere.components.set(OpacityComponent(opacity: immersionAmount))
                        // Keep the sphere centered on the user (0,0,0) so they don't walk out of it easily
                        blackOutSphere.position = .zero
                        
                    } else {
                        let volSize = content.convert(proxy.frame(in: .local), from: .local, to: .scene).extents
                        let scaleFactor = volSize.x / 2.0
                        screen.scale = SIMD3<Float>(repeating: scaleFactor)
                        
                        DispatchQueue.main.async {
                            let screenHalfHeight = (MAX_WIDTH_METERS * aspectRatio * scaleFactor) / 2
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
                            
                            if self.yLimits != newYLimits { self.yLimits = newYLimits }
                            if self.zLimits != newZLimits { self.zLimits = newZLimits }
                        }
                        
                        screen.position = SIMD3<Float>(0, height, depthOffset + zCorrection)
                    }

                    try! screen.model!.mesh.replace(with: mesh.contents)
                    
                    // --- UPDATE ATTACHMENTS ---
                    if let inputAttachment = attachments.entity(for: "input_capture") {
                        let attachmentWidthPoints: Float = 2000.0
                        let physicalWidth: Float = MAX_WIDTH_METERS
                        let requiredScale = physicalWidth / attachmentWidthPoints
                        inputAttachment.scale = SIMD3<Float>(requiredScale, requiredScale, requiredScale)
                        
                        if isInteractive {
                             if !inputAttachment.components.has(InputTargetComponent.self) {
                                inputAttachment.components.set(InputTargetComponent())
                             }
                        } else {
                             if inputAttachment.components.has(InputTargetComponent.self) {
                                inputAttachment.components.remove(InputTargetComponent.self)
                             }
                        }
                    }
                } attachments: {
                    Attachment(id: "input_capture") {
                        if let support = controllerSupport {
                            InputCaptureView(
                                controllerSupport: support,
                                showKeyboard: $showVirtualKeyboard,
                                curvature: viewModel.streamSettings.realitykitRendererCurvature
                            )
                            .frame(width: 2000, height: 2000 * CGFloat(aspectRatio))
                            .opacity(0.001)
                        }
                    }
                    
                    Attachment(id: "controls") {
                        if isImmersive {
                            controlsView
                                .frame(width: 600)
                                .glassBackgroundEffect()
                        }
                    }
                }
                .handlesGameControllerEvents(matching: .gamepad)
                .gesture(
                    DragGesture()
                        .targetedToEntity(screen)
                        .onChanged { value in
                            guard isImmersive, !isInteractive else { return }
                            if startDragPosition == nil { startDragPosition = immersivePosition }
                            let translation = value.convert(value.translation3D, from: .local, to: .scene)
                            immersivePosition = startDragPosition! + SIMD3<Float>(translation.x, translation.y, translation.z)
                        }
                        .onEnded { _ in startDragPosition = nil }
                )
                .gesture(
                    MagnifyGesture()
                        .targetedToEntity(screen)
                        .onChanged { value in
                            guard isImmersive, !isInteractive else { return }
                            let newScale = immersiveScale * Float(value.magnification)
                            immersiveScale = min(max(newScale, 0.05), 10.0)
                        }
                )
                
                // Keyboard Hint Overlay
                if showVirtualKeyboard {
                    VStack(spacing: 12) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 40))
                        Text(viewModel.localized(english: "Keyboard Active", chinese: "键盘已激活"))
                            .font(.headline)
                        Text(viewModel.localized(english: "Tap anywhere on the video to open the keyboard", chinese: "点击视频任意位置打开键盘"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial)
                    .cornerRadius(16)
                    .allowsHitTesting(false)
                    .opacity(0.8)
                }
                } // End ZStack
            }
        } else {
            // Stream stopped overlay
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(viewModel.localized(english: "Stream stopped", chinese: "串流已停止"))
                    .font(.title2)
                Text(viewModel.localized(english: "Please close this window before starting a new stream from the main menu.", chinese: "请在窗口横条上点击关闭按钮，之后即可在主菜单重新启动串流。"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button {
                    // Clear saved config to prevent auto-resume
                    viewModel.savedStreamConfigForResume = nil
                    openWindow(id: "mainView")
                    dismissWindow()
                    closeAction()
                } label: {
                    Label(viewModel.localized(english: "Open Main Menu", chinese: "打开主菜单"), systemImage: "house.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial)
        }
        .task {
            if surfaceMaterial == nil {
                do {
                    var material = try await ShaderGraphMaterial(named: "/Root/SBSMaterial", from: "SBSMaterial.usda")
                    try material.setParameter(name: "texture", value: .textureResource(self.texture))
                    self.surfaceMaterial = material
                } catch { print("Material Error: \(error)") }
            }
        }
        .ornament(visibility: connectionCallbacks.showAlert ? .visible :  .hidden , attachmentAnchor: .scene(.bottomFront), contentAlignment: .bottom) {
            VStack(alignment: .center) {
                Image(systemName: "exclamationmark.triangle")
                Text(MainViewModel.localizedStatic(english: "Stream error", chinese: "串流错误"))
                    .font(.title)
                Text(connectionCallbacks.errorMessage ?? MainViewModel.localizedStatic(english: "Unknown error", chinese: "未知错误"))
                Button(MainViewModel.localizedStatic(english: "Close", chinese: "关闭")) {
                    shouldClose.toggle()
                    dismissWindow()
                }
            }
            .padding().glassBackgroundEffect()
        }
<<<<<<< HEAD
        .ornament(attachmentAnchor: .scene(.bottomTrailingFront), contentAlignment: .bottomLeading) {
<<<<<<< HEAD
            StreamControls(
                horizontal: false,
                streamConfig: $streamConfig,
                isKeyboardActive: showVirtualKeyboard, // <-- Pass State
                closeAction: {
                    handleUserRequestedClose()
                },
                toggleKeyboardAction: {
                    showVirtualKeyboard.toggle()
                }
            ) {
                            if needsHdr || viewModel.streamSettings.enableHdr {
                                HStack {
                                    Image(systemName: "sun.max.fill")
                                    Text(viewModel.localized(english: "Boost / Luminance", chinese: "增强 / 亮度"))
                                    
                                    // Change the Binding and the Range.
                                    // We are repurposing the 'brightness' variable in viewModel to store Boost value for now
                                    // to save you from editing CoreData again immediately.
                                    // Range: 1.0 (Normal) to 5.0 (Very Bright)
                                    Slider(value: $viewModel.streamSettings.brightness, in: 1.0...5.0, step: 0.1)
                                        .frame(width: 300)
                                }
                                .padding(.vertical, 5)
                            }
                            HStack {
                                Button(viewModel.localized(english: "Flatten", chinese: "扁平化"), systemImage: viewModel.streamSettings.realitykitRendererCurvature == 0 ? "light.panel" : "pano.fill") {
                                    if viewModel.streamSettings.realitykitRendererCurvature == 0 {
                                        viewModel.streamSettings.realitykitRendererCurvature = curveMagnitudeMemory
                                    } else {
                                        curveMagnitudeMemory = viewModel.streamSettings.realitykitRendererCurvature
                                        viewModel.streamSettings.realitykitRendererCurvature = 0
                                    }
                                }
                                Slider(value: $viewModel.streamSettings.realitykitRendererCurvature, in: 0 ... 1, step: 0.001)
                                    .frame(width: 300)
                                    .padding([.trailing])
                            }
                 
                // AUTO-CALCULATED Z-DEPTH SLIDER
                HStack {
                    Button(viewModel.localized(english: "Reset Depth", chinese: "重置深度"), systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
                        depthOffset = 0.0
                    }
                    .accessibilityLabel(viewModel.localized(english: "Adjust Depth", chinese: "调整深度"))
                    // Uses dynamic zLimits
                    Slider(value: $depthOffset, in: zLimits)
                        .frame(width: 300)
                        .padding([.trailing])
                }

                HStack {
                    Toggle(isOn: Binding(
                        get: { videoMode == .sideBySide3D },
                        set: { val in
                            videoMode = val ? .sideBySide3D : .standard2D
                            if videoMode == .sideBySide3D {
                                screen.model?.materials = [surfaceMaterial!]
                            } else {
                                screen.model?.materials = [UnlitMaterial(texture: texture)]
                            }
                        }
                    )) {
                        Text(viewModel.localized(english: "3D Mode", chinese: "3D 模式"))
                    }
                    .toggleStyle(.button)
                }
                
                // AUTO-CALCULATED HEIGHT SLIDER
                HStack {
                    Button(viewModel.localized(english: "Height", chinese: "高度"), systemImage: "arrow.up.and.line.horizontal.and.arrow.down") {}
                    // Uses dynamic yLimits
                    Slider(value: $height, in: yLimits)
                        .frame(width: 300)
                        .padding([.trailing])
                }
                
                Button(viewModel.localized(english: "Main Button", chinese: "主按钮"), systemImage: "gamecontroller.fill") {
                }
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
        }.onChange(of: viewModel.streamSettings.brightness) { _, newValue in
            safeHDRSettings.value = HDRParams(boost: newValue, contrast: 1.0, saturation: 1.0, brightness: 0.0)
        }
        .onAppear {
            safeHDRSettings.value = HDRParams(
                boost: viewModel.streamSettings.brightness, // Using brightness slider for boost
                contrast: 1.0,
                saturation: 1.0,
                brightness: 0.0
            )
            
            guard handleAppearanceValidation() else { return }
            startStreamIfNeeded()
        }
        .modifier(VolumetricWindowControls(isImmersive: isImmersive, content: { controlsView }))
        .onChange(of: shouldClose) { _, shouldClose in
            if shouldClose {
                handleUserRequestedClose()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if needsResume, viewModel.activelyStreaming {
                    // Add a small delay to ensure we're truly back from background
                    // This prevents resuming when just switching between regular apps
                    Task {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second delay
                        if needsResume, viewModel.activelyStreaming {
                            await MainActor.run {
                                startStreamIfNeeded()
                            }
                        }
                    }
                }
            case .background:
                // Only pause when truly backgrounded (e.g., immersive scene or headset removal)
                // Don't pause on .inactive as it triggers too easily when switching apps
                pauseStreamForBackground()
            default:
                break
            }
        }
        .persistentSystemOverlays(viewModel.streamSettings.dimPassthrough ? .hidden : .automatic)
        .preferredSurroundingsEffect(viewModel.streamSettings.dimPassthrough ? .systemDark : nil)
        .volumeBaseplateVisibility(viewModel.streamSettings.dimPassthrough ? .hidden : .automatic)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .supportedVolumeViewpoints(.front)
            .onDisappear {
                handleSceneDisappearance()
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(viewModel.localized(english: "Stream stopped", chinese: "串流已停止"))
                    .font(.title2)
                Text(viewModel.localized(english: "Please close this window before starting a new stream from the main menu.", chinese: "请在窗口横条上点击关闭按钮，之后即可在主菜单重新启动串流。"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial)
        }
    }

    private func handleAppearanceValidation() -> Bool {
        if !viewModel.activelyStreaming {
            print("_RealityKitStreamView: Detected appearance without active stream state. Closing stream window and opening main view.")
            openWindow(id: "mainView")
            self.closeAction()
            return false
        }
        return true
    }

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
        viewModel.realityWindowNeedsManualClose = true
    }

    private func stopStream(teardownCompletely: Bool) {
        _streamMan?.stopStream()
        _streamMan = nil
        controllerSupport?.cleanup()

        if teardownCompletely {
            if didPerformFullClose {
                return
            }
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
        handleExternalWindowDismiss()
    }

    private func handleExternalWindowDismiss() {
        stopStream(teardownCompletely: true)
        DispatchQueue.main.async {
            openWindow(id: "mainView")
        }
        viewModel.realityWindowNeedsManualClose = true
    }
    
    @ViewBuilder
    var controlsView: some View {
        StreamControls(
            horizontal: false,
            streamConfig: $streamConfig,
            isKeyboardActive: showVirtualKeyboard,
            closeAction: {
               viewModel.activelyStreaming = false
               self._streamMan?.stopStream()
               self.controllerSupport?.cleanup()
               openWindow(id: "mainView")
               self.closeAction()
             },
            toggleKeyboardAction: { showVirtualKeyboard.toggle() }
        ) {
            HStack {
                Image(systemName: "sun.max.fill")
                Text("Boost / Luminance")
                Slider(value: $viewModel.streamSettings.brightness, in: 1.0...5.0, step: 0.1).frame(width: 220)
            }
            .padding(.vertical, 5)
            
            HStack {
               Button("Flatten", systemImage: viewModel.streamSettings.realitykitRendererCurvature == 0 ? "light.panel" : "pano.fill") {
                   if viewModel.streamSettings.realitykitRendererCurvature == 0 {
                       viewModel.streamSettings.realitykitRendererCurvature = curveMagnitudeMemory
                   } else {
                       curveMagnitudeMemory = viewModel.streamSettings.realitykitRendererCurvature
                       viewModel.streamSettings.realitykitRendererCurvature = 0
                   }
               }
               Slider(value: $viewModel.streamSettings.realitykitRendererCurvature, in: 0 ... 1, step: 0.001)
                   .frame(width: 220)
                   .padding([.trailing])
           }

            if !isImmersive {
                // --- VOLUMETRIC CONTROLS ---
                HStack {
                    Button("Reset Depth", systemImage: "arrow.up.and.down.and.arrow.left.and.right") { depthOffset = 0.0 }
                    Slider(value: $depthOffset, in: zLimits)
                        .frame(width: 220)
                        .padding([.trailing])
                }
                HStack {
                    Button("Height", systemImage: "arrow.up.and.line.horizontal.and.arrow.down") {}
                    Slider(value: $height, in: yLimits)
                        .frame(width: 220)
                        .padding([.trailing])
                }
            } else {
                // --- IMMERSIVE CONTROLS ---
                Divider().padding(.vertical, 5)
                Text("Spatial").font(.caption).foregroundStyle(.secondary)
                
                // BLACK OUT SLIDER
                HStack {
                    Image(systemName: immersionAmount > 0.5 ? "moon.fill" : "moon")
                    Text("Black Sphere Opacity")
                    Slider(value: $immersionAmount, in: 0.0...1.0)
                        .frame(width: 220)
                }
                
                HStack {
                      Image(systemName: "arrow.up.left.and.arrow.down.right")
                      Text("Size")
                      Slider(value: $immersiveScale, in: 0.5...6.0)
                        .frame(width: 220)
                }
                
                HStack {
                      Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                      Text("Distance")
                      Slider(value: Binding(
                        get: { immersivePosition.z },
                        set: { immersivePosition.z = $0 }
                      ), in: -10.0 ... -0.5)
                        .frame(width: 220)
                }
                
                HStack {
                      Image(systemName: "arrow.up.and.down")
                      Text("Height")
                      Slider(value: Binding(
                        get: { immersivePosition.y },
                        set: { immersivePosition.y = $0 }
                      ), in: 0.0 ... 5.0)
                        .frame(width: 220)
                }
                
                Toggle(isOn: $isInteractive) {
                    Label(isInteractive ? "Screen Locked (Inputs Active)" : "Screen Unlocked (Movable Screen Active)",
                          systemImage: isInteractive ? "lock.fill" : "lock.open.fill")
                }
                .toggleStyle(.button)
                .padding(.top, 5)
            }

            HStack {
                Toggle(isOn: Binding(
                    get: { videoMode == .sideBySide3D },
                    set: { val in
                        videoMode = val ? .sideBySide3D : .standard2D
                        if videoMode == .sideBySide3D {
                           screen.model?.materials = [surfaceMaterial!]
                       } else {
                           screen.model?.materials = [UnlitMaterial(texture: texture)]
                       }
                    }
                )) { Text("3D Mode") }.toggleStyle(.button)
            }
            
            Button("Main Button", systemImage: "gamecontroller.fill") { }
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
    
    static func generateCurvedPlane(
        width: Float, aspectRatio: Float, resolution: (UInt32, UInt32), curveMagnitude: Float
    ) throws -> MeshResource {
        var descr = MeshDescriptor(name: "curved_plane_smart")
        let height = width * aspectRatio
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
            content
                .ornament(attachmentAnchor: .scene(.bottomTrailingFront), contentAlignment: .bottomLeading) {
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
