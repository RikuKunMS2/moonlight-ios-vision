//
//  RealityKitStreamView.swift
//  Moonlight Vision
//
//  Created by tht7 on 29/12/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI
import RealityKit
import GameController

let COOL_NUMBER: Float = 2.79945612 // 3.8
let MAX_WIDTH_METERS: Float = 2

@objc
class DummyControllerDelegate: NSObject, ControllerSupportDelegate {
    func gamepadPresenceChanged() {
    }

    func mousePresenceChanged() {
    }

    func streamExitRequested() {
    }


}

struct RealityKitStreamView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Binding var streamConfig: StreamConfiguration?
    
    
    var body: some View {
        if streamConfig != nil {
            _RealityKitStreamView(streamConfig: Binding<StreamConfiguration>(
                get: { streamConfig ?? StreamConfiguration() },
                set: { streamConfig = $0 }
            )) {
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

    @State var curveMagnitudeMemory: Float = 0
    @State var curveAnimationMultiplier: Float = 1
    @State var controllerSupport: ControllerSupport?
    @State var height: Float = 0
    
    @State var shouldClose: Bool = false

    var aspectRatio: Float {
        get {
            Float(streamConfig.height) / Float(streamConfig.width)
        }
    }

    @State var animationTimer: Timer?

    @State var _streamMan: StreamManager?
    @ObservedObject var connectionCallbacks: ObservableConnectionManager = ObservableConnectionManager()

    @State var enlarge = false

    @State var texture: TextureResource
    @State var screen: ModelEntity = ModelEntity()
    
    let closeAction: () -> Void

    init(streamConfig: Binding<StreamConfiguration>, closeAction: @escaping () -> Void) {
        self.closeAction = closeAction
        self._streamConfig = streamConfig
        self.controllerSupport = ControllerSupport(config: streamConfig.wrappedValue, delegate: DummyControllerDelegate())
        let data = Data.init(count: 4 * Int(streamConfig.wrappedValue.width) * Int(streamConfig.wrappedValue.height)) // Dummy data
        self.texture = try! TextureResource(
            dimensions: .dimensions(width: Int(streamConfig.wrappedValue.width), height: Int(streamConfig.wrappedValue.height)),
            format: .raw(pixelFormat: .bgra8Unorm_srgb), // Doesn't matter, dummy data
            contents: .init(
                mipmapLevels: [
                    .mip(data: data, bytesPerRow: 4 * Int(streamConfig.wrappedValue.width) ), // TODO is this even needed
                ]
            )
        )
    }

    var body: some View {
        GeometryReader3D { proxy in
                RealityView { content in
                    let mesh = try! _RealityKitStreamView.generateCurvedPlane(width: MAX_WIDTH_METERS, aspectRatio: aspectRatio, resulotion: (50,50), curveMagnitude: viewModel.streamSettings.realitykitRendererCurvature * curveAnimationMultiplier)
                    let colBox = ShapeResource.generateBox(width: 2, height: 2 * aspectRatio, depth: 0.001).offsetBy(translation: .init(x: 0, y: -0.43, z: 1))
                    screen = ModelEntity(mesh: mesh, materials: [UnlitMaterial(texture: self.texture)])
                    screen.collision = CollisionComponent(shapes: [
                        colBox
                    ], mode: .colliding)
                    screen.components.set(InputTargetComponent())
                    content.add(screen)
                } update: { content in
                    let mesh = try! _RealityKitStreamView.generateCurvedPlane(width: MAX_WIDTH_METERS, aspectRatio: aspectRatio, resulotion: (50,50), curveMagnitude: viewModel.streamSettings.realitykitRendererCurvature * curveAnimationMultiplier)
                    let size = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
                    screen.transform.scale = .init(repeating: size.extents.x / 2)
                    screen.transform.translation.y = height
                    try! screen.model!.mesh.replace(with: mesh.contents)
                }
                .handlesGameControllerEvents(matching: .gamepad)
        }
        .ornament(visibility: connectionCallbacks.showAlert ? .visible :  .hidden , attachmentAnchor: .scene(.bottomFront), contentAlignment: .bottom) {
            VStack(alignment: .center) {
                Image(systemName: "exclamationmark.triangle")
                Text("Stream error")
                    .font(.title)
                Text(connectionCallbacks.errorMessage ?? "Unknown error")
                Button("Close") {
                    shouldClose.toggle()
                    dismissWindow()
                }
            }
            .padding()
            .glassBackgroundEffect()
        }
        .ornament(attachmentAnchor: .scene(.bottomTrailingFront), contentAlignment: .bottomLeading) {
            StreamControls(horizontal: false, streamConfig: $streamConfig) {
                HStack {
                    Button("Flatten", systemImage: viewModel.streamSettings.realitykitRendererCurvature == 0 ? "light.panel" : "pano.fill") {
                        if viewModel.streamSettings.realitykitRendererCurvature == 0 {
                            viewModel.streamSettings.realitykitRendererCurvature = curveMagnitudeMemory
                        } else {
                            curveMagnitudeMemory = viewModel.streamSettings.realitykitRendererCurvature
                            viewModel.streamSettings.realitykitRendererCurvature = 0
                        }
                    }
                    Slider(value: $viewModel.streamSettings.realitykitRendererCurvature, in: (0...1), step: 0.001)
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
                    Button("arrow.up.and.line.horizontal.and.arrow.down", systemImage: "arrow.up.and.line.horizontal.and.arrow.down") {
                        // Do nothing, just display this button like a neat littel label
                    }
                    Slider(value: $height, in: (0...1), step: 0.001)
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
                Button("Main Button", systemImage: "house") {
//                    self.controllerSupport?.updateTriggers(<#T##controller: Controller!##Controller!#>, left: <#T##UInt8#>, right: <#T##UInt8#>)
                }.simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged({ _ in
                            if let controller = self.controllerSupport?.getOscController() {
                                self.controllerSupport?.setButtonFlag(controller, flags: 0x0400)
                                self.controllerSupport?.updateFinished(controller)
                            }
                        })
                        .onEnded({ _ in
                            if let controller = self.controllerSupport?.getOscController() {
                                self.controllerSupport?.clearButtonFlag(controller, flags: 0x0400)
                                self.controllerSupport?.updateFinished(controller)
                            }
                        })
                )
            }
        }
        .onAppear() {
            dismissWindow(id: "mainView")
            dismissWindow(id: "dummy")
//            dismissWindow(id: "realitykitStreamingWindow")
            self.curveAnimationMultiplier = viewModel.streamSettings.realitykitRendererAnimateOpening ? 0 : 1
            self._streamMan = StreamManager(
                config:self.streamConfig,
                rendererProvider: {
                    return DrawableVideoDecoder(texture: self.texture, callbacks: self.connectionCallbacks, aspectRatio: Float(self.streamConfig.width) / Float(self.streamConfig.height), useFramePacing: self.streamConfig.useFramePacing) { texture, correctedResultion in
                        DispatchQueue.main.async {
                            if let correctedResultion = correctedResultion {
                                streamConfig.width = Int32(correctedResultion.0)
                                streamConfig.height = Int32(correctedResultion.1)
                            }
                            self.texture.replace(withDrawables: texture)
                            screen.model!.materials = [UnlitMaterial(texture: self.texture)]
                            self.controllerSupport!.connectionEstablished()
                            if (self.curveAnimationMultiplier == 0) { animateOpening() }
                        }
                    }
                },
                connectionCallbacks:self.connectionCallbacks);
            let operationQueue = OperationQueue()
            operationQueue.addOperation(_streamMan!)
        }
        .onChange(of: shouldClose) { _, shouldClose in
            if shouldClose {
                openWindow(id: "mainView")
                dismissWindow()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                //print("active")
                break
            case .inactive:
                print("inactive")
                break
            case .background:
                print("background")
                viewModel.activelyStreaming = false
                _streamMan?.stopStream()
                _streamMan = nil
                controllerSupport?.cleanup()
//                streamConfig = nil
                if !shouldClose { openWindow(id: "mainView") }
                self.closeAction()
//                dismissWindow()
            @unknown default: break
                //print("unknown default")
            }
        }
        .persistentSystemOverlays(viewModel.streamSettings.dimPassthrough ? .hidden : .automatic)
        .preferredSurroundingsEffect(viewModel.streamSettings.dimPassthrough ? .systemDark : nil)

    }

    func animateOpening() {
        Task {
            self.animationTimer = Timer.scheduledTimer(withTimeInterval: 0.04,
                                                       repeats: true) { _ in
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
        width: Float, aspectRatio: Float, resulotion: (UInt32, UInt32), curveMagnitude: Float = 1.0
    ) throws -> MeshResource {
        //TODO maybe use a LowLevelMesh here, I think it can compute the mesh on the GPU AND avoid additional allocations
        var descr = MeshDescriptor()
        let height = width * aspectRatio

        let totalVertices = Int(resulotion.0 * resulotion.1)
        var meshPositions: [SIMD3<Float>] = .init(repeating: .zero, count: totalVertices)
        var textureMap: [SIMD2<Float>] = .init(repeating: .zero, count: totalVertices)
        var indices: [UInt32] = .init(repeating: .zero, count: totalVertices * 6)
        let floorOffset: Float =  (1 - (height / 2))
        let backOffset = curveMagnitude + 1

        for x_v in 0..<(resulotion.0) {
            let vertexCounts = x_v * resulotion.1
            for y_v in 0..<(resulotion.1) {
                let vertexIndex = Int(vertexCounts + y_v);
                let xPosition = (Float(x_v) / Float(resulotion.0 - 1) - 0.5) * width
                let yPosition = ((( 0.5 - Float(y_v) / Float(resulotion.1 - 1))) * height)
                let zPosition = (pow(xPosition, 2) * curveMagnitude / pow(width / 2, 2))

                meshPositions[vertexIndex] = [xPosition, (-yPosition) - floorOffset, zPosition - curveMagnitude + 1]
                textureMap[vertexIndex] = [Float(x_v) / Float(resulotion.0 - 1), Float(y_v) / Float(resulotion.1 - 1)]
                if x_v > 0 && y_v > 0 {
                    let vertexCounts = vertexCounts + y_v - 1
                    let vertexIndex = Int( ( ( x_v - 1) * ( resulotion.1 - 1 ) + ( y_v - 1 ) ) * 6)

                    indices[vertexIndex] = vertexCounts - resulotion.1
                    indices[vertexIndex + 1] = vertexCounts
                    indices[vertexIndex + 2] = vertexCounts - resulotion.1 + 1

                    indices[vertexIndex + 3] = vertexCounts - resulotion.1 + 1
                    indices[vertexIndex + 4] = vertexCounts
                    indices[vertexIndex + 5] = vertexCounts + 1
                }
            }
        }

        descr.primitives = .triangles(indices)
        descr.positions = MeshBuffer(meshPositions)
        descr.textureCoordinates = MeshBuffers.TextureCoordinates(textureMap)

        return try .generate(from: [descr])
    }
}

//#Preview {
////    NativeStreamView()
//    NativeStreamView()
//}

