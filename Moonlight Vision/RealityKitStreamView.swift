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
                // 1. GLOBAL INPUT CAPTURE (NON-IMMERSIVE ONLY)
                // In Volume mode (isImmersive=false), we rely on the ZStack to fill the volume.
                // In Immersive mode (isImmersive=true), we move this to an Attachment (see makeRealityView).
                if !isImmersive, let support = controllerSupport {
                    RealityKitInputView(
                        streamConfig: streamConfig,
                        controllerSupport: support,
                        showKeyboard: $showVirtualKeyboard
                    )
                    // Make it cover the whole volume so it stays active
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Invisible, but present in the hierarchy to catch events
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
                    controlsView
                        .frame(width: 600)
                        .glassBackgroundEffect()
                }
            }
            
            // INPUT ATTACHMENT (IMMERSIVE ONLY)
            // This attaches the input view physically to the screen in 3D space
            Attachment(id: "input_overlay") {
                if isImmersive, let support = controllerSupport {
                    RealityKitInputView(
                        streamConfig: streamConfig,
                        controllerSupport: support,
                        showKeyboard: $showVirtualKeyboard
                    )
                    // We give it a high-res fixed frame.
                    // We will scale this down to match MAX_WIDTH_METERS in updateStreamEntity.
                    .frame(width: 1920, height: 1920 / CGFloat(aspectRatio))
                    .opacity(0.01) // Invisible but hittable
                }
            }
        }
        // NOTE: Removed .handlesGameControllerEvents to prevent conflict with GCMouse
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
       
        if isImmersive, let controls = attachments.entity(for: "controls") {
            screen.addChild(controls)
            let screenHeight = MAX_WIDTH_METERS * aspectRatio
            controls.position = [0, -(screenHeight / 2.0) - 0.25, 0.1]
        }
        
        // Setup Input Overlay (Immersive Only)
        // We parent it to the screen so it moves/scales with the screen
        if isImmersive, let inputEnt = attachments.entity(for: "input_overlay") {
            screen.addChild(inputEnt)
            // Position slightly in front to prevent z-fighting (though it's invisible)
            // and ensures it catches the raycast first
            inputEnt.position = [0, 0, 0.01]
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
                
                // --- UPDATE INPUT OVERLAY SCALE ---
                // The input overlay is attached to 'screen', so it inherits 'immersiveScale' automatically.
                // However, we need to ensure the input entity's local size matches the mesh size (2 meters).
                if let inputEnt = attachments.entity(for: "input_overlay") {
                    // We defined the SwiftUI frame as 1920 px wide.
                    // We want it to fill MAX_WIDTH_METERS (2.0).
                    // First, get the entity's native size (based on points)
                    let bounds = inputEnt.visualBounds(relativeTo: nil)
                    if bounds.extents.x > 0 {
                        let scale = MAX_WIDTH_METERS / bounds.extents.x
                        inputEnt.scale = SIMD3<Float>(scale, scale, 1)
                    }
                }
                
            } else {
                // Volume Mode Logic (Unchanged)
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
        // Attachments handled in RealityViewBuilder now
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

// MARK: - INTEGRATED INPUT CONTROLLER
// ---------------------------------------------------------

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
        
        vc.keyboardDismissHandler = {
            DispatchQueue.main.async {
                // Optional: Sync state if needed
            }
        }
        return vc
    }

    func updateUIViewController(_ vc: RealityKitInputViewController, context: Context) {
        vc.streamConfig = streamConfig
        
        // Pass the toggle state to the overlay
        if let overlay = vc.view as? RealityKitInputOverlay {
            overlay.streamConfig = streamConfig
            overlay.showSoftwareKeyboard = showKeyboard
            
            // If the user actively toggled the keyboard ON, force focus just in case
            if showKeyboard && !overlay.isFirstResponder {
                print("[RealityKitInput] Update: Forcing focus on Overlay because toggle is ON")
                overlay.becomeFirstResponder()
            }
        }
    }
}

// --- VIEW CONTROLLER ---
class RealityKitInputViewController: UIViewController {
    var streamConfig: StreamConfiguration? {
        didSet {
            if let overlay = view as? RealityKitInputOverlay {
                overlay.streamConfig = streamConfig
            }
        }
    }
    var controllerSupport: ControllerSupport?
    var keyboardDismissHandler: (() -> Void)?
    
    private lazy var inputOverlayView: RealityKitInputOverlay = {
        let v = RealityKitInputOverlay()
        v.parentController = self
        return v
    }()
    
    override func loadView() {
        self.view = inputOverlayView
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if let support = controllerSupport {
            print("[RealityKitInput] Attaching GCEventInteraction...")
            support.attachGCEventInteraction(to: self.view)
            
            // 1. Enable Passthrough for Mouse
            support.realityKitMode = true
            
            // 2. Mouse Callback
            support.realityKitMouseMovedHandler = { [weak self] (dx: Float, dy: Float) in
                guard let self = self else { return }
                self.inputOverlayView.handleRawMouseDelta(dx: dx, dy: dy)
            }
            
            // 3. Explicitly disable GCKeyboard to prevent double inputs
            support.realityKitKeyboardHandler = nil
        }
    }
    
    // THE FIX: Target the VIEW, not the CONTROLLER for focus
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        print("[RealityKitInput] ViewDidAppear - Scanning Inputs & Enforcing Focus...")
        
        if let support = controllerSupport {
            for mouse in GCMouse.mice() {
                support.registerMouseCallbacks(mouse)
            }
        }
        
        // CRITICAL FIX: Call becomeFirstResponder on the VIEW (overlay), not self (controller)
        if !self.inputOverlayView.becomeFirstResponder() {
            print("[RealityKitInput] Initial becomeFirstResponder failed. Retrying in 0.5s...")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                let success = self.inputOverlayView.becomeFirstResponder()
                print("[RealityKitInput] Delayed becomeFirstResponder result: \(success)")
            }
        } else {
            print("[RealityKitInput] Initial becomeFirstResponder succeeded.")
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
    
    // CRITICAL FIX: The Controller itself should NOT be the responder. The View should be.
    override var canBecomeFirstResponder: Bool { false }
}

// --- OVERLAY VIEW (With Debug Logging) ---
class RealityKitInputOverlay: UIView, UIKeyInput, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
    
    weak var parentController: RealityKitInputViewController?
    var streamConfig: StreamConfiguration?
    
    // --- KEYBOARD VISIBILITY LOGIC ---
        // If true, we return nil (default soft keyboard).
        // If false, we return a dummy view (hides soft keyboard, keeps hardware input).
        var showSoftwareKeyboard: Bool = false {
            didSet {
                if oldValue != showSoftwareKeyboard {
                    self.reloadInputViews()
                }
            }
        }
    
    // This is the magic that allows capturing input without the UI popping up
        override var inputView: UIView? {
            if showSoftwareKeyboard {
                return nil // Default System Keyboard
            } else {
                return UIView() // Invisible Dummy View
            }
        }
    
    // State for Absolute Position Calculation
    private var currentMousePosition: CGPoint = .zero
    private var lastMouseButtonMask: UIEvent.ButtonMask = []
    private var lastScrollTranslation: CGPoint = .zero
    private let wheelDelta: CGFloat = 120.0
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupInteraction()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupInteraction()
    }
    
    private func setupInteraction() {
        print("[RealityKitInput] Setup Interaction - Overlay Initialized")
        self.backgroundColor = UIColor.black.withAlphaComponent(0.01)
        self.isMultipleTouchEnabled = true
        self.isUserInteractionEnabled = true
        
        // Pointer interaction
        let pointerInteraction = UIPointerInteraction(delegate: self)
        self.addInteraction(pointerInteraction)
        
        // Pan gesture
        let panScroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        panScroll.allowedScrollTypesMask = .all
        panScroll.minimumNumberOfTouches = 0
        panScroll.delegate = self
        self.addGestureRecognizer(panScroll)
        
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        self.addGestureRecognizer(hover)
    }
    
    // MARK: - Focus Debugging
    override var canBecomeFocused: Bool {
        // print("[RealityKitInput] canBecomeFocused checked") // Commented out to avoid log spam
        return true
    }
    
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        print("[RealityKitInput] becomeFirstResponder result: \(result)")
        return result
    }
    
    override func resignFirstResponder() -> Bool {
        print("[RealityKitInput] resignFirstResponder called")
        let result = super.resignFirstResponder()
        if result {
            parentController?.keyboardDismissHandler?()
        }
        return result
    }
    
    // MARK: - KEYBOARD SUPPORT
        
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                if KeyboardSupport.sendKeyEvent(for: press, down: true) {
                    handled = true
                }
            }
            if !handled { super.pressesBegan(presses, with: event) }
        }
        
        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                if KeyboardSupport.sendKeyEvent(for: press, down: false) {
                    handled = true
                }
            }
            if !handled { super.pressesEnded(presses, with: event) }
        }
        
        override var keyCommands: [UIKeyCommand]? {
            var commands: [UIKeyCommand] = []
            let action = #selector(handleDummyKeyCommand(_:))
            let inputs = [
                UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
                UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow,
                UIKeyCommand.inputEscape, UIKeyCommand.inputPageUp,
                UIKeyCommand.inputPageDown, UIKeyCommand.inputHome, UIKeyCommand.inputEnd
            ]
            for input in inputs {
                commands.append(UIKeyCommand(input: input, modifierFlags: [], action: action))
            }
            return commands
        }
        
        @objc func handleDummyKeyCommand(_ sender: UIKeyCommand) { }

    // MARK: - UIKeyInput

    var hasText: Bool { true }
    
    func insertText(_ text: String) {
        print("[RealityKitInput] insertText called with: '\(text)'")
        
        if text.count == 1, let char = text.first {
            let utf16 = String(char).utf16.first!
            print("[RealityKitInput] Attempting translation for char code: \(utf16)")
            
            let keyEvent = KeyboardSupport.translateKeyEvent(utf16, with: [])
            
            if keyEvent.keycode != 0 {
                print("[RealityKitInput] Translation successful -> Sending Low Level Key Event")
                sendLowLevelEvent(event: keyEvent)
                return
            } else {
                print("[RealityKitInput] Translation returned 0 keycode")
            }
        }
        
        print("[RealityKitInput] Sending as UTF-8 Text")
        let cString = text.cString(using: .utf8)
        cString?.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                LiSendUtf8TextEvent(base, UInt32(text.utf8.count))
            }
        }
    }
    
    func deleteBackward() {
        print("[RealityKitInput] deleteBackward")
        LiSendKeyboardEvent(0x08, 0x03, 0)
        usleep(50 * 1000)
        LiSendKeyboardEvent(0x08, 0x04, 0)
    }
    
    private func sendLowLevelEvent(event: KeyEvent) {
        print("[RealityKitInput] Sending HID Event -> Code: 0x\(String(format: "%02X", event.keycode)), Mod: 0x\(String(format: "%02X", event.modifier))")
        
        DispatchQueue.global(qos: .userInteractive).async {
            if event.modifier != 0 {
                LiSendKeyboardEvent(Int16(event.modifierKeycode), 0x03, Int8(event.modifier))
            }
            
            LiSendKeyboardEvent(Int16(event.keycode), 0x03, Int8(event.modifier))
            usleep(50 * 1000)
            LiSendKeyboardEvent(Int16(event.keycode), 0x04, Int8(event.modifier))
            
            if event.modifier != 0 {
                LiSendKeyboardEvent(Int16(event.modifierKeycode), 0x04, Int8(event.modifier))
            }
        }
    }
    
    // MARK: - GCMouse Logic
    
    func handleRawMouseDelta(dx: Float, dy: Float) {
        // print("[RealityKitInput] Mouse Delta: \(dx), \(dy)") // Commented out to avoid log flooding
        guard let config = streamConfig else { return }
        
        let sensitivity: CGFloat = 1.0
        
        var newX = currentMousePosition.x + (CGFloat(dx) * sensitivity)
        var newY = currentMousePosition.y - (CGFloat(dy) * sensitivity)
        
        let width = CGFloat(config.width)
        let height = CGFloat(config.height)
        
        newX = min(max(newX, 0), width)
        newY = min(max(newY, 0), height)
        
        currentMousePosition = CGPoint(x: newX, y: newY)
        
        LiSendMousePositionEvent(Int16(newX), Int16(newY), Int16(width), Int16(height))
    }
    
    func sendMouseButton(action: Int8, button: Int32) {
        print("[RealityKitInput] Mouse Button: \(button) Action: \(action)")
        LiSendMouseButtonEvent(action, button)
    }
    
    // MARK: - Pointer Interaction
    
    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        if lastMouseButtonMask.isEmpty {
            updateCursorFromSystemPointer(location: request.location)
        }
        return UIPointerRegion(rect: self.bounds)
    }
    
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        return nil
    }
    
    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        let loc = gesture.location(in: self)
        if lastMouseButtonMask.isEmpty {
            updateCursorFromSystemPointer(location: loc)
        }
    }
    
    private func updateCursorFromSystemPointer(location: CGPoint) {
        guard let config = streamConfig else { return }
        
        let normX = location.x / self.bounds.width
        let normY = location.y / self.bounds.height
        
        let hostX = normX * CGFloat(config.width)
        let hostY = normY * CGFloat(config.height)
        
        currentMousePosition = CGPoint(x: hostX, y: hostY)
        
        LiSendMousePositionEvent(Int16(hostX), Int16(hostY), Int16(config.width), Int16(config.height))
    }
    
    // MARK: - Touch Handling
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("[RealityKitInput] touchesBegan (Click)")
        sendMouseButton(action: 0, button: 1)
        if let touch = touches.first {
            updateCursorFromSystemPointer(location: touch.location(in: self))
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first {
            updateCursorFromSystemPointer(location: touch.location(in: self))
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("[RealityKitInput] touchesEnded (Release)")
        sendMouseButton(action: 1, button: 1)
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendMouseButton(action: 1, button: 1)
    }
    
    // MARK: - Scroll Handling
    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .began else {
            lastScrollTranslation = .zero
            return
        }
        
        let currentTranslation = gesture.translation(in: self)
        let deltaY = (currentTranslation.y - lastScrollTranslation.y)
        let deltaX = (currentTranslation.x - lastScrollTranslation.x)
        
        if deltaY != 0 {
            let scaledY = (deltaY / self.bounds.height) * wheelDelta * 20.0
            print("[RealityKitInput] Scroll Y: \(scaledY)")
            LiSendHighResScrollEvent(Int16(scaledY))
        }
        
        if deltaX != 0 {
            let scaledX = (deltaX / self.bounds.width) * wheelDelta * 20.0
            LiSendHighResHScrollEvent(Int16(-scaledX))
        }
        
        lastScrollTranslation = currentTranslation
    }
}
