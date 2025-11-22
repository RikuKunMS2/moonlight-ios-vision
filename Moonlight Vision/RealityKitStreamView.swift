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
                
                // REMOVED: openWindow(id: "mainView")
                // We removed this because the child view (_RealityKitStreamView)
                // already opens the main window before calling the close action.
                // Leaving it here causes a Double Window bug.
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
    
    // Tracks when the texture instance has been replaced
        @State private var textureId: UUID = UUID()
        // Tracks if the visual entity has been updated to match the new texture
        @State private var appliedTextureId: UUID? = nil
    
    // --- Mouse Mode State ---
    @State private var mouseInputMode: MouseInputMode = .absolute
    
    // Interaction State
    @State private var isInteractive: Bool = true
    
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
    
    @State private var safeHDRSettings = ThreadSafeHDRSettings(
            params: HDRParams(boost: 2.0, contrast: 1.0, saturation: 1.0, brightness: 0.0)
        )
    
    @State var shouldClose: Bool = false
    @State var hasPerformedTeardown = false
    @State var needsResume = false
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

        // 3. Apply Logic/Lifecycle Modifiers and Return
        return visualContent
            .onChange(of: viewModel.streamSettings.brightness) { _, newValue in
                safeHDRSettings.value = HDRParams(boost: newValue, contrast: 1.0, saturation: 1.0, brightness: 0.0)
            }
            .onChange(of: mouseInputMode) { _, newMode in
                // Ensure ControllerSupport has property 'relativeMouseMode' added in Obj-C
                controllerSupport?.relativeMouseMode = (newMode == .relative)
            }
            .onAppear {
                setupStreamOnAppear()
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
                makeRealityView(proxy: proxy)
                
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
            Attachment(id: "input_capture") {
                if let support = controllerSupport {
                    InputCaptureView(
                        controllerSupport: support,
                        showKeyboard: $showVirtualKeyboard,
                        mouseInputMode: $mouseInputMode,
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
        .gesture(dragGesture)
        .gesture(magnifyGesture)
    }
    
    // MARK: - Logic Helpers
    
    func triggerCloseSequence() {
        // 1. Open Main Menu FIRST to ensure user has somewhere to go
        openWindow(id: "mainView")
        
        // 2. Delay the teardown slightly to allow the new window to appear
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

        // FIX: Only apply surfaceMaterial if it exists AND we are actually in 3D mode
        if videoMode == .sideBySide3D, let material = surfaceMaterial {
            screen.model?.materials = [material]
        } else {
            screen.model?.materials = [UnlitMaterial(texture: self.texture)]
        }
        
        screen.collision = CollisionComponent(shapes: [colBox], mode: .colliding)
        screen.components.set(InputTargetComponent())
        content.add(screen)
        
        // Setup "Black Out" Sphere (Immersive Only)
        if isImmersive {
            let sphereMesh = MeshResource.generateSphere(radius: 100) // 100m radius
            let blackMaterial = UnlitMaterial(color: .black)
            
            blackOutSphere = ModelEntity(mesh: sphereMesh, materials: [blackMaterial])
            blackOutSphere.scale = SIMD3<Float>(-1, 1, 1)
            blackOutSphere.components.set(OpacityComponent(opacity: 0.0))
            content.add(blackOutSphere)
        }
        
        // Attachments
        if let inputAttachment = attachments.entity(for: "input_capture") {
            screen.addChild(inputAttachment)
            inputAttachment.position = [0, 0, 0.001]
        }
        
        if isImmersive, let controls = attachments.entity(for: "controls") {
            screen.addChild(controls)
            let screenHeight = MAX_WIDTH_METERS * aspectRatio
            controls.position = [0, -(screenHeight / 2.0) - 0.25, 0.1]
        }
    }
    
    func updateStreamEntity(content: RealityViewContent, attachments: RealityViewAttachments, proxy: GeometryProxy3D) {
            let currentCurve = viewModel.streamSettings.realitykitRendererCurvature * curveAnimationMultiplier
            
            // 1. Mesh Generation
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

            // 2. Transforms
            if isImmersive {
                screen.scale = SIMD3<Float>(repeating: immersiveScale)
                screen.position = immersivePosition + SIMD3<Float>(0, 0, zCorrection)
                
                blackOutSphere.components.set(OpacityComponent(opacity: immersionAmount))
                blackOutSphere.position = .zero
            } else {
                // We can revert to the standard logic since the Volume Size is now guaranteed
                // to be 2m (thanks to the Invisible Tent Pole).
                
                let volSize = content.convert(proxy.frame(in: .local), from: .local, to: .scene).extents
                let scaleFactor = volSize.x / 2.0
                screen.scale = SIMD3<Float>(repeating: scaleFactor)
                
                updateWindowedLimits(volSize: volSize, scaleFactor: scaleFactor, curveDepth: curveDepth)
                
                screen.position = SIMD3<Float>(0, height, depthOffset + zCorrection)
            }

            // 3. Attachments
            updateAttachments(attachments: attachments)
        }
    
        // Updated helper to just handle state updates
        func updateWindowedLimits(minZ: Float, maxZ: Float, minY: Float, maxY: Float) {
            Task { @MainActor in
                // Only update state if changed to prevent render loops
                let newZLimits = minZ...max(minZ, maxZ)
                let newYLimits = minY...max(minY, maxY)
                
                if self.zLimits != newZLimits { self.zLimits = newZLimits }
                if self.yLimits != newYLimits { self.yLimits = newYLimits }
                
                // Optional: Auto-correct the slider values if they are wildly out of bounds
                if self.depthOffset < minZ { self.depthOffset = minZ }
                if self.depthOffset > maxZ { self.depthOffset = maxZ }
            }
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
            
            if self.yLimits != newYLimits { self.yLimits = newYLimits }
            if self.zLimits != newZLimits { self.zLimits = newZLimits }
        }
    }
    
    func updateAttachments(attachments: RealityViewAttachments) {
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
        .allowsHitTesting(false)
        .opacity(0.8)
    }
    
    @ViewBuilder
        var streamStoppedOverlay: some View {
            ZStack {
                // --- THE FIX: INVISIBLE SCAFFOLD ---
                // This RealityView exists solely to force the Volume to maintain
                // a 2x2x2 meter size, preventing it from collapsing when the stream stops.
                RealityView { content in
                    // Create a box that matches your defaultSize (2m x 2m x 2m)
                    let scaffoldMesh = MeshResource.generateBox(size: 2.0)
                    
                    // Make it invisible
                    let material = UnlitMaterial(color: .clear)
                    let scaffoldEntity = ModelEntity(mesh: scaffoldMesh, materials: [material])
                    
                    // Ensure it is fully transparent and does not block touches
                    scaffoldEntity.components.set(OpacityComponent(opacity: 0.0))
                    // Do NOT add an InputTargetComponent, so clicks pass through to the buttons
                    
                    content.add(scaffoldEntity)
                }
                .allowsHitTesting(false) // Double safety to ensure buttons work
                
                // --- EXISTING UI CONTENT ---
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
                        triggerCloseSequence()
                    } label: {
                        Label(viewModel.localized("open_main_menu"), systemImage: "house.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }
                .frame(width: 600, height: 400) // Give the UI a fixed reasonable size
                .padding()
                .glassBackgroundEffect() // Use glass effect for better visibility in volume
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
            mouseInputMode: $mouseInputMode,
            isKeyboardActive: showVirtualKeyboard,
            closeAction: {
                if streamConfig != nil {
                    viewModel.savedStreamConfigForResume = streamConfig
                }
                needsResume = false
                hasPerformedTeardown = false
                viewModel.activelyStreaming = false
                self._streamMan?.stopStream()
                self.controllerSupport?.cleanup()
                
                // Use central close sequence
                triggerCloseSequence()
            },
            toggleKeyboardAction: { showVirtualKeyboard.toggle() }
        ) {
            // Additions (HDR, Flatten, etc.)
            settingsControls
        }
    }
    
    @ViewBuilder
    var settingsControls: some View {
        if needsHdr || viewModel.streamSettings.enableHdr {
            HStack {
                Image(systemName: "sun.max.fill")
                Text(viewModel.localized("boost_luminance"))
                Slider(value: $viewModel.streamSettings.brightness, in: 1.0...5.0, step: 0.1)
                    .frame(width: 220)
                .onChange(of: viewModel.streamSettings.brightness) { _, _ in
                    if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                }
            }
            .padding(.vertical, 5)
        }
        
        HStack {
            Button(viewModel.localized("flatten"), systemImage: viewModel.streamSettings.realitykitRendererCurvature == 0 ? "light.panel" : "pano.fill") {
                if viewModel.streamSettings.realitykitRendererCurvature == 0 {
                    viewModel.streamSettings.realitykitRendererCurvature = curveMagnitudeMemory
                } else {
                    curveMagnitudeMemory = viewModel.streamSettings.realitykitRendererCurvature
                    viewModel.streamSettings.realitykitRendererCurvature = 0
                }
                if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
            }
            Slider(value: $viewModel.streamSettings.realitykitRendererCurvature, in: 0 ... 1, step: 0.001)
                .frame(width: 220)
                .padding([.trailing])
                .onChange(of: viewModel.streamSettings.realitykitRendererCurvature) { _, _ in
                    if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                }
        }

        if !isImmersive {
            HStack {
                Button(viewModel.localized("reset_depth"), systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
                    depthOffset = 0.0
                    if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                }
                Slider(value: $depthOffset, in: zLimits)
                    .frame(width: 220)
                    .padding([.trailing])
                    .onChange(of: depthOffset) { _, _ in
                        if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                    }
            }
            HStack {
                Button(viewModel.localized("height"), systemImage: "arrow.up.and.line.horizontal.and.arrow.down") {}
                Slider(value: $height, in: yLimits)
                    .frame(width: 220)
                    .padding([.trailing])
                    .onChange(of: height) { _, _ in
                        if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                    }
            }
        } else {
            Divider().padding(.vertical, 5)
            Text(viewModel.localized("spatial")).font(.caption).foregroundStyle(.secondary)
            
            HStack {
                Image(systemName: immersionAmount > 0.5 ? "moon.fill" : "moon")
                Text(viewModel.localized("black_sphere_opacity"))
                Slider(value: $immersionAmount, in: 0.0...1.0)
                    .frame(width: 220)
                    .onChange(of: immersionAmount) { _, _ in
                        if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                    }
            }
            
            HStack {
                  Image(systemName: "arrow.up.left.and.arrow.down.right")
                  Text(viewModel.localized("size"))
                  Slider(value: $immersiveScale, in: 0.5...6.0)
                    .frame(width: 220)
                    .onChange(of: immersiveScale) { _, _ in
                        if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                    }
            }
            
            HStack {
                  Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                  Text(viewModel.localized("distance"))
                  Slider(value: Binding(
                    get: { immersivePosition.z },
                    set: {
                        immersivePosition.z = $0
                        if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                    }
                  ), in: -10.0 ... -0.5)
                    .frame(width: 220)
            }
            
            HStack {
                  Image(systemName: "arrow.up.and.down")
                  Text(viewModel.localized("height"))
                  Slider(value: Binding(
                    get: { immersivePosition.y },
                    set: {
                        immersivePosition.y = $0
                        if viewModel.streamSettings.rememberStreamSettings { saveRealityKitSettings() }
                    }
                  ), in: 0.0 ... 5.0)
                    .frame(width: 220)
            }
            
            Toggle(isOn: $isInteractive) {
                Label(isInteractive ? viewModel.localized("screen_locked") : viewModel.localized("screen_unlocked"),
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
            )) { Text(viewModel.localized("3d_mode")) }.toggleStyle(.button)
        }
        
        Button(viewModel.localized("main_button"), systemImage: "gamecontroller.fill") { }
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
    
    func setupStreamOnAppear() {
            safeHDRSettings.value = HDRParams(boost: viewModel.streamSettings.brightness, contrast: 1.0, saturation: 1.0, brightness: 0.0)
            
            if !viewModel.activelyStreaming {
                print("[RealityKitStreamView] Zombie state detected. Restoring main view.")
                triggerCloseSequence()
                return
            }
            
            dismissWindow(id: "mainView")
            dismissWindow(id: "dummy")
            
            self.curveAnimationMultiplier = viewModel.streamSettings.realitykitRendererAnimateOpening ? 0 : 1
            
            if viewModel.streamSettings.rememberStreamSettings {
                loadRealityKitSettings()
            }
            
            // REVERTED: No longer creating a new TextureResource here.
            // We trust the existing self.texture is valid because the Volume size is now stable.
            
            self._streamMan = StreamManager(
                config: self.streamConfig,
                rendererProvider: {
                    DrawableVideoDecoder(
                        texture: self.texture, // Use the existing texture
                        callbacks: self.connectionCallbacks,
                        aspectRatio: Float(self.streamConfig.width) / Float(self.streamConfig.height),
                        useFramePacing: self.streamConfig.useFramePacing,
                        enableHDR: self.viewModel.streamSettings.enableHdr,
                        hdrSettingsProvider: { [safeHDRSettings] in return safeHDRSettings.value },
                        callbackToRender: { [weak viewModel] texture, correctedResultion in
                            
                            DispatchQueue.main.async {
                                // KEEP THIS GUARD: It prevents background GPU crashes without affecting connection logic
                                guard let vm = viewModel, vm.activelyStreaming else { return }
                                
                                if let correctedResultion = correctedResultion {
                                    self.streamConfig.width = Int32(correctedResultion.0)
                                    self.streamConfig.height = Int32(correctedResultion.1)
                                }
                                
                                self.texture.replace(withDrawables: texture)
                                
                                if let support = self.controllerSupport {
                                    support.connectionEstablished()
                                }
                                if self.curveAnimationMultiplier == 0 { self.animateOpening() }
                            }
                        })
                },
                connectionCallbacks: self.connectionCallbacks
            )
            let operationQueue = OperationQueue()
            operationQueue.addOperation(_streamMan!)
        }
    
    
    func handleScenePhaseChange(_ phase: ScenePhase) {
            switch phase {
            case .background:
                guard !hasPerformedTeardown else { return }
                guard !shouldClose else { return }
                
                // We still need to stop the stream to prevent the background GPU crash,
                // but we do it cleanly without extra logging overhead.
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
                    // REVERT: Back to the original fast 0.1s delay.
                    // Since the volume size is now held open by the 'Invisible Tent Pole',
                    // we don't need to wait long for the OS to stabilize the layout.
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    
                    await MainActor.run {
                        guard needsResume else { return }
                        guard !shouldClose else { return }
                        guard streamConfig != nil else { return }
                        
                        needsResume = false
                        hasPerformedTeardown = false
                        viewModel.activelyStreaming = true
                        
                        // Resume the stream immediately
                        setupStreamOnAppear()
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
    }
    
    private func saveRealityKitSettings() {
        guard viewModel.streamSettings.rememberStreamSettings else { return }
        let defaults = UserDefaults.standard
        defaults.set(height, forKey: "realitykitHeight")
        defaults.set(depthOffset, forKey: "realitykitDepthOffset")
        defaults.set(immersiveScale, forKey: "realitykitImmersiveScale")
        defaults.set(immersivePosition.x, forKey: "realitykitImmersivePosX")
        defaults.set(immersivePosition.y, forKey: "realitykitImmersivePosY")
        defaults.set(immersivePosition.z, forKey: "realitykitImmersivePosZ")
        defaults.set(immersionAmount, forKey: "realitykitImmersionAmount")
    }
    
    static func generateCurvedPlane(
            width: Float, aspectRatio: Float, resolution: (UInt32, UInt32), curveMagnitude: Float
        ) throws -> MeshResource {
            // LOGGING INPUTS
            // print("   -> [GenMesh] W:\(width) Ratio:\(aspectRatio) Curve:\(curveMagnitude)")

            var descr = MeshDescriptor(name: "curved_plane_smart")
            let height = width * aspectRatio
            
            // CHECK FOR INVALID HEIGHT
            if height.isNaN || height == 0 {
                 print("🚨 [GenMesh] Calculated Height is INVALID (Width: \(width) * Ratio: \(aspectRatio))")
            }

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

                    // CHECK FOR NAN IN POSITIONS
                    if xPosition.isNaN || yPosition.isNaN || zPosition.isNaN {
                        print("🚨 [GenMesh] NaN detected at vert \(vertexIndex): [\(xPosition), \(yPosition), \(zPosition)]")
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
