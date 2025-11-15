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

let COOL_NUMBER: Float = 2.79945612 // 3.8
let MAX_WIDTH_METERS: Float = 2

@objc
class DummyControllerDelegate: NSObject, ControllerSupportDelegate {
    func gamepadPresenceChanged() {}

    func mousePresenceChanged() {}

    func streamExitRequested() {}
}

struct RealityKitStreamView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow // Keep this
    @Binding var streamConfig: StreamConfiguration?
    var needsHdr: Bool
    
    // @EnvironmentObject private var viewModel: MainViewModel // Not needed here
    
    var body: some View {
        let cornerRadius = CGFloat(MainViewModel.shared.streamSettings.windowCornerRadius)
        if streamConfig != nil {
            _RealityKitStreamView(streamConfig: Binding<StreamConfiguration>(
                get: { streamConfig ?? StreamConfiguration() },
                set: { streamConfig = $0 }
            ), needsHdr: needsHdr) {
                
                // This is the ORIGINAL closeAction passed down.
                // It's used when the view disappears for other reasons (like backgrounding)
                // OR if the disconnect fails and we need to force close.
                
                // We keep the original logic here for safety/cleanup.
                dismissWindow()
                dismissWindow(id: "realitykitStreamingWindow")
                streamConfig = nil
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(MainViewModel.localizedStatic(english: "Stream stopped", chinese: "串流已停止"))
                    .font(.title2)
                Text(MainViewModel.localizedStatic(english: "Please close this window before starting a new stream from the main menu.", chinese: "请在窗口横条上点击关闭按钮，之后即可在主菜单重新启动串流。"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial)
            .onAppear {
                Task { @MainActor in
                    MainViewModel.shared.realityWindowNeedsManualClose = true
                }
            }
            .onDisappear {
                Task { @MainActor in
                    MainViewModel.shared.realityWindowNeedsManualClose = false
                }
            }
        }
    }
}

struct _RealityKitStreamView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var viewModel: MainViewModel

    @Binding var streamConfig: StreamConfiguration

    @State var curveMagnitudeMemory: Float = 0
    @State var curveAnimationMultiplier: Float = 1
    @State var controllerSupport: ControllerSupport?
    @State var height: Float = 0
    
    @State private var depthOffset: Float = 1.0
    
    @State var shouldClose: Bool = false
    @State private var needsResume = false
    @State private var didPerformFullClose = false


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
    

    @State var animationTimer: Timer?

    @State var _streamMan: StreamManager?
    @ObservedObject var connectionCallbacks: ObservableConnectionManager = .init()

    @State var enlarge = false

    @State var texture: TextureResource
    @State var screen: ModelEntity = ModelEntity()
    
    let closeAction: () -> Void

    @State var videoMode: VideoMode = .standard2D

    @State private var surfaceMaterial: ShaderGraphMaterial?

    init(streamConfig: Binding<StreamConfiguration>, needsHdr: Bool, closeAction: @escaping () -> Void) {
        self.closeAction = closeAction
        self._streamConfig = streamConfig
        self.controllerSupport = ControllerSupport(config: streamConfig.wrappedValue, delegate: DummyControllerDelegate())
        let bytesPerPixel = needsHdr ? 8 : 4  // HDR is 64-bit (8 bytes), SDR is 32-bit (4 bytes)
        let data = Data.init(count: bytesPerPixel * Int(streamConfig.wrappedValue.width) * Int(streamConfig.wrappedValue.height)) // Dummy data
        self.texture = try! TextureResource(
            dimensions: .dimensions(width: Int(streamConfig.wrappedValue.width), height: Int(streamConfig.wrappedValue.height)),
            format: .raw(pixelFormat: needsHdr ? .rgba16Float : .bgra8Unorm_srgb), // Doesn't matter, dummy data
            contents: .init(
                mipmapLevels: [
                    .mip(data: data, bytesPerRow: bytesPerPixel * Int(streamConfig.wrappedValue.width)),
                ]
            )
        )
    }

    var body: some View {
        if viewModel.activelyStreaming {
            let cornerRadius = CGFloat(viewModel.streamSettings.windowCornerRadius)
            GeometryReader3D { proxy in
                RealityView { content in
                    let mesh = try! _RealityKitStreamView.generateCurvedPlane(width: MAX_WIDTH_METERS, aspectRatio: aspectRatio, resulotion: (100,100), curveMagnitude: viewModel.streamSettings.realitykitRendererCurvature * curveAnimationMultiplier)
                    let colBox = ShapeResource.generateBox(width: 2, height: 2 * aspectRatio, depth: 0.001).offsetBy(translation: .init(x: 0, y: -0.43, z: 1))
                    screen = ModelEntity(mesh: mesh, materials: [])

                    // Initialize material if needed
                    if surfaceMaterial == nil {
                        surfaceMaterial = try! await ShaderGraphMaterial(
                            named: "/Root/SBSMaterial",
                            from: "SBSMaterial.usda"
                        )

                        try! surfaceMaterial!.setParameter(
                            name: "texture",
                            value: .textureResource(self.texture)
                        )
                    }

                    if videoMode == .sideBySide3D {
                        screen.model?.materials = [surfaceMaterial!]
                    } else {
                        screen.model?.materials = [UnlitMaterial(texture: self.texture)]
                    }

                    screen.collision = CollisionComponent(shapes: [
                        colBox
                    ], mode: .colliding)
                    screen.components.set(InputTargetComponent())
                    content.add(screen)
                } update: { content in
                    let mesh = try! _RealityKitStreamView.generateCurvedPlane(width: MAX_WIDTH_METERS, aspectRatio: aspectRatio, resulotion: (100,100), curveMagnitude: viewModel.streamSettings.realitykitRendererCurvature * curveAnimationMultiplier)
                    let size = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
                    screen.transform.scale = .init(repeating: size.extents.x / 2)
                    screen.transform.translation = SIMD3<Float>(0, height, depthOffset)
                    try! screen.model!.mesh.replace(with: mesh.contents)
                }
                .handlesGameControllerEvents(matching: .gamepad)
        }
        .ornament(visibility: connectionCallbacks.showAlert ? .visible :  .hidden , attachmentAnchor: .scene(.bottomFront), contentAlignment: .bottom) {
            VStack(alignment: .center) {
                Image(systemName: "exclamationmark.triangle")
                Text(MainViewModel.localizedStatic(english: "Stream error", chinese: "串流错误"))
                    .font(.title)
                Text(connectionCallbacks.errorMessage ?? MainViewModel.localizedStatic(english: "Unknown error", chinese: "未知错误"))
                Button(MainViewModel.localizedStatic(english: "Close", chinese: "关闭")) {
                    shouldClose.toggle()
                }
            }
            .padding()
            .glassBackgroundEffect()
        }
        .ornament(attachmentAnchor: .scene(.bottomTrailingFront), contentAlignment: .bottomLeading) {
            // --- START FIX ---
                        // Provide the CORRECT closeAction to StreamControls
                        StreamControls(
                            horizontal: false,
                            streamConfig: $streamConfig,
                            closeAction: {
                                handleUserRequestedClose()
                            }
                        ) {
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
                        .hoverEffect { effect, isActive, proxy in
                            effect.clipShape(.capsule.size(
                                width: isActive ? proxy.size.width : proxy.size.height,
                                height: proxy.size.height,
                                anchor: .leading
                            ))
                            //                            effect.scaleEffect(x: isActive ? 1: 0.5, y: 1, anchor: .leading)
                        }
                }
                HStack {
                    Button("arrow.left.and.line.horizontal.and.arrow.right", systemImage: "arrow.left.and.line.horizontal.and.right.down") {                         // Optional: Action for the button, e.g., reset depth
                         depthOffset = -1.0 // Reset to default example
                    }
                    .accessibilityLabel(viewModel.localized(english: "Adjust Depth", chinese: "调整深度")) // Accessibility
                    Slider(value: $depthOffset, in: -1.5 ... 2.5, step: 0.01) // Adjust range as needed
                        .frame(width: 300)
                        .padding([.trailing])
                        // ... (hover effect if desired)
                }

                HStack {
                    Button(viewModel.localized(english: "3D Mode", chinese: "3D 模式"), systemImage: videoMode == .standard2D ? "rectangle" : "rectangle.split.2x1") {
                        videoMode = videoMode == .standard2D ? .sideBySide3D : .standard2D
                        if videoMode == .sideBySide3D {
                            screen.model?.materials = [surfaceMaterial!]
                        } else {
                            screen.model?.materials = [UnlitMaterial(texture: texture)]
                        }
                    }
                }
                HStack {
                    Button("arrow.up.and.line.horizontal.and.arrow.down", systemImage: "arrow.up.and.line.horizontal.and.arrow.down") {
                        // Do nothing, just display this button like a neat littel label
                    }
                    Slider(value: $height, in: -2 ... 1, step: 0.001)
                        .frame(width: 300)
                        .padding([.trailing])
                        .hoverEffect { effect, isActive, proxy in
                            effect.clipShape(.capsule.size(
                                width: isActive ? proxy.size.width : proxy.size.height,
                                height: proxy.size.height,
                                anchor: .leading
                            ))
                            //                            effect.scaleEffect(x: isActive ? 1: 0.5, y: 1, anchor: .leading)
                        }
                }
                Button(viewModel.localized(english: "Main Button", chinese: "主按钮"), systemImage: "gamecontroller.fill") {
//                    self.controllerSupport?.updateTriggers(<#T##controller: Controller!##Controller!#>, left: <#T##UInt8#>, right: <#T##UInt8#>)
                }.simultaneousGesture(
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
        .onAppear {
            guard handleAppearanceValidation() else { return }
            startStreamIfNeeded()
        }
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
                    enableHDR: self.viewModel.streamSettings.enableHdr
                ) { texture, correctedResultion in
                    DispatchQueue.main.async {
                        if let correctedResultion = correctedResultion {
                            streamConfig.width = Int32(correctedResultion.0)
                            streamConfig.height = Int32(correctedResultion.1)
                        }
                        self.texture.replace(withDrawables: texture)
                        self.controllerSupport!.connectionEstablished()
                        if self.curveAnimationMultiplier == 0 { animateOpening() }
                    }
                }
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

    func animateOpening() {
        Task {
            self.animationTimer = Timer.scheduledTimer(withTimeInterval: 0.04,
                                                       repeats: true)
            { _ in
                Task { @MainActor in
                    if self.curveAnimationMultiplier < 1 {
                        self.curveAnimationMultiplier = min(self.curveAnimationMultiplier + 0.01, 1)
                    } else {
                        if self.animationTimer != nil {
                            self.animationTimer?.invalidate()
                            self.animationTimer = nil
                        }
                    }
                }
            }
            self.animationTimer?.fire()
        }
    }

    static func generateCurvedPlane(
        width: Float, // Chord width
        aspectRatio: Float,
        resulotion: (UInt32, UInt32),
        curveMagnitude: Float // Value from 0 (flat) to 1 (max curve)
    ) throws -> MeshResource {

        var descr = MeshDescriptor(name: "curved_plane_inward")
        let height = width * aspectRatio
        let vertexCount = Int(resulotion.0 * resulotion.1)
        // Correct calculation for number of triangles and indices
        let numQuadsX = resulotion.0 - 1
        let numQuadsY = resulotion.1 - 1
        let triangleCount = Int(numQuadsX * numQuadsY * 2)
        let indexCount = triangleCount * 3

        var positions: [SIMD3<Float>] = .init(repeating: .zero, count: vertexCount)
        var textureCoordinates: [SIMD2<Float>] = .init(repeating: .zero, count: vertexCount)
        var indices: [UInt32] = .init(repeating: 0, count: indexCount)

        // --- Angle and Radius Calculation ---
        let maxCurveAngle: Float = (5.5 * .pi / 6.0) // Max curve: 120 degrees. Adjust as needed.
        let currentAngle = maxCurveAngle * curveMagnitude.clamped(to: 0...1)

        let radius: Float
        let halfAngle = currentAngle / 2.0

        if abs(halfAngle) < 0.0001 {
            radius = .infinity // Flat case
        } else {
            radius = width / (2.0 * sin(halfAngle))
        }
        // --- End Calculation ---

        var vertexIndex: Int = 0
        var indicesIndex: Int = 0

        for y_v in 0 ..< resulotion.1 {
            // v_geo goes 0 for the first row (y_v=0) to 1 for the last row
            let v_geo = Float(y_v) / Float(resulotion.1 - 1)

            // Y position: higher Y for lower v_geo (top of screen)
            let yPosition = (0.5 - v_geo) * height

            // Texture V coordinate: Flipped - V=1 at the top, V=0 at the bottom
            let v_tex = 1.0 - v_geo

            for x_v in 0 ..< resulotion.0 {
                // u goes 0 (left) to 1 (right)
                let u = Float(x_v) / Float(resulotion.0 - 1)

                let xPosition: Float
                let zPosition: Float

                if radius.isFinite && radius > 0 && currentAngle > 0.0001 {
                    // Curved Plane Case
                    let theta = (u - 0.5) * currentAngle // Angle from center: -halfAngle to +halfAngle

                    // X position on the circular arc
                    xPosition = radius * sin(theta)

                    // Z position: Make center positive Z (further away), edges Z=0
                    zPosition = radius * (cos(halfAngle) - cos(theta))

                } else {
                    // Flat Plane Case
                    xPosition = (u - 0.5) * width
                    zPosition = 0.0
                }

                // Assign vertex position (Y is up, +Z is away from viewer)
                positions[vertexIndex] = [xPosition, yPosition, zPosition]

                // Assign texture coordinate (U=horizontal, V=vertical, V=0 is bottom)
                textureCoordinates[vertexIndex] = [u, v_tex] // Use the flipped v_tex

                // Add indices for the quad ending SE of this vertex
                if x_v < numQuadsX && y_v < numQuadsY {
                    let current = UInt32(vertexIndex)
                    let nextRow = current + resulotion.0

                    let topLeft = current
                    let topRight = topLeft + 1
                    let bottomLeft = nextRow
                    let bottomRight = bottomLeft + 1

                    // Triangle 1: Top-Left, Bottom-Left, Bottom-Right
                    indices[indicesIndex + 0] = topLeft
                    indices[indicesIndex + 1] = bottomLeft
                    indices[indicesIndex + 2] = bottomRight

                    // Triangle 2: Top-Left, Bottom-Right, Top-Right
                    indices[indicesIndex + 3] = topLeft
                    indices[indicesIndex + 4] = bottomRight
                    indices[indicesIndex + 5] = topRight

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

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}


// #Preview {
////    NativeStreamView()
//    NativeStreamView()
//}

