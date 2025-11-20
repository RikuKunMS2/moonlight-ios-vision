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
    @Binding var streamConfig: StreamConfiguration?
    var needsHdr: Bool
    
    var body: some View {
        if streamConfig != nil {
            _RealityKitStreamView(streamConfig: Binding<StreamConfiguration>(
                get: { streamConfig ?? StreamConfiguration() },
                set: { streamConfig = $0 }
            ), needsHdr: needsHdr) {
                dismissWindow()
                streamConfig = nil
            }
        } else {
            ProgressView().onAppear { dismissWindow() }
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

    // UI State
    @State private var showVirtualKeyboard = false
    @State var curveMagnitudeMemory: Float = 0
    @State var curveAnimationMultiplier: Float = 1
    @State var controllerSupport: ControllerSupport?
    
    // Position & Limits State
    @State var height: Float = 0
    @State private var depthOffset: Float = 0.0
    @State private var yLimits: ClosedRange<Float> = -0.5...0.5
    @State private var zLimits: ClosedRange<Float> = -0.5...0.5
    
    @State private var safeHDRSettings = ThreadSafeHDRSettings(
            params: HDRParams(boost: 2.0, contrast: 1.0, saturation: 1.0, brightness: 0.0)
        )
    
    @State var shouldClose: Bool = false
    @State var animationTimer: Timer?
    @State var _streamMan: StreamManager?
    @ObservedObject var connectionCallbacks: ObservableConnectionManager = .init()

    @State var texture: TextureResource
    @State var screen: ModelEntity = ModelEntity()
    
    let closeAction: () -> Void
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
    
    init(streamConfig: Binding<StreamConfiguration>, needsHdr: Bool, closeAction: @escaping () -> Void) {
        self.closeAction = closeAction
        self._streamConfig = streamConfig
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
        GeometryReader3D { proxy in
            ZStack {
                RealityView { content in
                    // Initial setup
                    let mesh = try! _RealityKitStreamView.generateCurvedPlane(
                        width: MAX_WIDTH_METERS,
                        aspectRatio: aspectRatio,
                        resolution: (100,100),
                        curveMagnitude: viewModel.streamSettings.realitykitRendererCurvature * curveAnimationMultiplier
                    )
                    
                    let colBox = ShapeResource.generateBox(width: 2, height: 2 * aspectRatio, depth: 0.001)
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
                    
                } update: { content in
                    let currentCurve = viewModel.streamSettings.realitykitRendererCurvature * curveAnimationMultiplier
                    let totalAngle = MAX_CURVE_ANGLE * currentCurve.clamped(to: 0...1)
                    
                    // 1. Generate Mesh
                    let mesh = try! _RealityKitStreamView.generateCurvedPlane(
                        width: MAX_WIDTH_METERS,
                        aspectRatio: aspectRatio,
                        resolution: (100,100),
                        curveMagnitude: currentCurve
                    )
                    
                    // 2. Calculate Z-Correction (Sagitta)
                    let radius = totalAngle < 0.001 ? Float.infinity : (MAX_WIDTH_METERS / totalAngle)
                    // How deep is the curve physically?
                    let curveDepth = totalAngle < 0.001 ? 0 : radius * (1.0 - cos(totalAngle / 2.0))
                    // Push back so edges are at 0
                    let zCorrection = -curveDepth

                    // 3. Scale Calculation
                    // Get volume dimensions
                    let volSize = content.convert(proxy.frame(in: .local), from: .local, to: .scene).extents
                    // We arbitrarily scale so the width fits comfortably (e.g. half the volume width)
                    // Adjust this divider as per your design preference
                    let scaleFactor = volSize.x / 2.0
                    screen.transform.scale = .init(repeating: scaleFactor)
                    
                    // 4. Calculate LIMITS dynamically
                    // This must be done asynchronously to avoid State-update loops during view render
                    DispatchQueue.main.async {
                        // Height: Total volume height / 2 minus Screen Half Height
                        let screenHalfHeight = (MAX_WIDTH_METERS * aspectRatio * scaleFactor) / 2
                        let volHalfHeight = volSize.y / 2
                        let safePadding: Float = 0.05 // 5cm padding
                        
                        let maxY = max(0, volHalfHeight - screenHalfHeight - safePadding)
                        let newYLimits = -maxY...maxY
                        
                        // Depth:
                        // Front Limit: Volume Front - Safe Padding
                        // Back Limit: Volume Back + Screen Depth + Safe Padding
                        let volHalfDepth = volSize.z / 2
                        let maxZ = volHalfDepth - safePadding
                        
                        // The "Back" of our object is at (offset + zCorrection).
                        // But zCorrection is negative. So the physical back is at z - curveDepth * scale.
                        let scaledCurveDepth = curveDepth * scaleFactor
                        let minZ = -volHalfDepth + scaledCurveDepth + safePadding
                        
                        // Ensure range is valid
                        let safeMaxZ = max(minZ, maxZ)
                        let newZLimits = minZ...safeMaxZ
                        
                        // Only update if changed significantly to save cycles
                        if self.yLimits != newYLimits { self.yLimits = newYLimits }
                        if self.zLimits != newZLimits { self.zLimits = newZLimits }
                        
                        // Clamp current values if they are now out of bounds
                        if self.height > newYLimits.upperBound { self.height = newYLimits.upperBound }
                        if self.height < newYLimits.lowerBound { self.height = newYLimits.lowerBound }
                        if self.depthOffset > newZLimits.upperBound { self.depthOffset = newZLimits.upperBound }
                        if self.depthOffset < newZLimits.lowerBound { self.depthOffset = newZLimits.lowerBound }
                    }

                    // 5. Apply Transforms
                    screen.transform.translation = SIMD3<Float>(0, height, depthOffset + zCorrection)
                    try! screen.model!.mesh.replace(with: mesh.contents)
                }
                .handlesGameControllerEvents(matching: .gamepad)
                
                // Input Capture
                if let support = controllerSupport {
                    InputCaptureView(
                        controllerSupport: support,
                        showKeyboard: $showVirtualKeyboard,
                        curvature: viewModel.streamSettings.realitykitRendererCurvature
                    )
                    .aspectRatio(CGFloat(aspectRatio), contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(0.001)
                    .allowsHitTesting(true)
                }
                
                // Keyboard Hint
                if showVirtualKeyboard {
                    VStack(spacing: 12) {
                        Image(systemName: "keyboard").font(.system(size: 40))
                        Text("Keyboard Active").font(.headline)
                        Text("Tap video to type").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial)
                    .cornerRadius(16)
                    .allowsHitTesting(false)
                    .opacity(0.8)
                }
            }
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
                Text("Stream error").font(.title)
                Text(connectionCallbacks.errorMessage ?? "Unknown error")
                Button("Close") { shouldClose.toggle(); dismissWindow() }
            }
            .padding().glassBackgroundEffect()
        }
        .ornament(attachmentAnchor: .scene(.bottomTrailingFront), contentAlignment: .bottomLeading) {
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
                     Text("Boost")
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
                 
                // AUTO-CALCULATED Z-DEPTH SLIDER
                HStack {
                    Button("Reset Depth", systemImage: "arrow.up.and.down.and.arrow.left.and.right") { depthOffset = 0.0 }
                    // Uses dynamic zLimits
                    Slider(value: $depthOffset, in: zLimits)
                        .frame(width: 220)
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
                    )) { Text("3D Mode") }.toggleStyle(.button)
                }
                
                // AUTO-CALCULATED HEIGHT SLIDER
                HStack {
                    Button("Height", systemImage: "arrow.up.and.line.horizontal.and.arrow.down") {}
                    // Uses dynamic yLimits
                    Slider(value: $height, in: yLimits)
                        .frame(width: 220)
                        .padding([.trailing])
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
        }.onChange(of: viewModel.streamSettings.brightness) { _, newValue in
            safeHDRSettings.value = HDRParams(boost: newValue, contrast: 1.0, saturation: 1.0, brightness: 0.0)
        }
        .onAppear {
            safeHDRSettings.value = HDRParams(boost: viewModel.streamSettings.brightness, contrast: 1.0, saturation: 1.0, brightness: 0.0)
            if !viewModel.activelyStreaming {
                openWindow(id: "mainView"); self.closeAction(); return
            }
            dismissWindow(id: "mainView"); dismissWindow(id: "dummy")
            
            self.curveAnimationMultiplier = viewModel.streamSettings.realitykitRendererAnimateOpening ? 0 : 1
            
            self._streamMan = StreamManager(
                config: self.streamConfig,
                rendererProvider: {
                    DrawableVideoDecoder(
                        texture: self.texture,
                        callbacks: self.connectionCallbacks,
                        aspectRatio: Float(self.streamConfig.width) / Float(self.streamConfig.height),
                        useFramePacing: self.streamConfig.useFramePacing,
                        enableHDR: self.viewModel.streamSettings.enableHdr,
                        hdrSettingsProvider: { [safeHDRSettings] in return safeHDRSettings.value },
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
        }
        .onChange(of: shouldClose) { _, val in if val { openWindow(id: "mainView"); dismissWindow() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                viewModel.activelyStreaming = false
                _streamMan?.stopStream()
                controllerSupport?.cleanup()
                if !shouldClose { openWindow(id: "mainView") }
                self.closeAction()
            }
        }
        .persistentSystemOverlays(viewModel.streamSettings.dimPassthrough ? .hidden : .automatic)
        .preferredSurroundingsEffect(viewModel.streamSettings.dimPassthrough ? .systemDark : nil)
        .volumeBaseplateVisibility(viewModel.streamSettings.dimPassthrough ? .hidden : .automatic)
        .supportedVolumeViewpoints(.front)
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
