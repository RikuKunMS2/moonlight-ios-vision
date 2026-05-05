//
//  DepthEstimator.swift
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2).
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Copyright © 2026 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation
import CoreML
import Vision
import CoreVideo
import Metal
import RealityKit

/// Real-time 2D to 3D depth estimation using CoreML.
/// Designed to run asynchronously on a background thread to prevent blocking video decoding.
class DepthEstimator {
    static let shared = DepthEstimator()
    
    private var coreMLRequest: VNCoreMLRequest?
    private let inferenceQueue = DispatchQueue(label: "com.moonlight.depthestimator", qos: .userInteractive)
    
    // For metal texture creation
    private var metalDevice: MTLDevice?
    private var textureCache: CVMetalTextureCache?
    
    // Concurrency control to drop frames if inference falls behind
    private let inflightSemaphore = DispatchSemaphore(value: 1)
    
    // RealityKit Drawable Queue
    private(set) var depthQueue: TextureResource.DrawableQueue?
    private var depthWidth: Int = 0
    private var depthHeight: Int = 0
    private var commandQueue: MTLCommandQueue?
    
    private init() {
        self.metalDevice = MTLCreateSystemDefaultDevice()
        self.commandQueue = self.metalDevice?.makeCommandQueue()
        if let device = self.metalDevice {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
        
        loadModel()
    }
    
    private func loadModel() {
        inferenceQueue.async {
            // NOTE: We assume an optimized MLModel (e.g. DepthAnythingV2 converted to ANE-optimized float16/int8)
            // is bundled with the application under the name "DepthModel.mlmodelc".
            // Since this is a stub for "source your own", we catch the error if it's missing.
            do {
                // If you add your own MLModel to the project, make sure it is named "DepthModel"
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .cpuAndNeuralEngine
                
                guard let modelURL = Bundle.main.url(forResource: "DepthModel", withExtension: "mlmodelc") else {
                    print("[DepthEstimator] DepthModel.mlmodelc not found in bundle. Please drag DepthAnythingV2SmallF16.mlpackage into Xcode and rename it to DepthModel.")
                    return
                }
                
                let mlModel = try MLModel(contentsOf: modelURL, configuration: configuration)
                let visionModel = try VNCoreMLModel(for: mlModel)
                
                self.coreMLRequest = VNCoreMLRequest(model: visionModel) { [weak self] request, error in
                    self?.handleInferenceResults(request: request, error: error)
                }
                self.coreMLRequest?.imageCropAndScaleOption = .scaleFill
                print("[DepthEstimator] CoreML model successfully loaded and ready for 3D ML mode!")
            } catch {
                print("[DepthEstimator] Failed to load ML model: \(error)")
            }
        }
    }
    
    /// Dispatch a pixel buffer for asynchronous depth estimation
    func estimateDepth(from pixelBuffer: CVPixelBuffer) {
        // Drop frame if the previous inference is still running
        if inflightSemaphore.wait(timeout: .now()) != .success {
            return
        }
        
        inferenceQueue.async {
            defer { self.inflightSemaphore.signal() }
            
            guard let request = self.coreMLRequest else {
                // Stub fallback: generate a dummy gradient texture or just do nothing if no model is loaded.
                return
            }
            
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("[DepthEstimator] Vision request failed: \(error)")
            }
        }
    }
    
    private func handleInferenceResults(request: VNRequest, error: Error?) {
        if let results = request.results as? [VNPixelBufferObservation], let observation = results.first {
            processPixelBuffer(observation.pixelBuffer)
        } else if let results = request.results as? [VNCoreMLFeatureValueObservation], let observation = results.first {
            if let multiArray = observation.featureValue.multiArrayValue {
                processMultiArray(multiArray)
            }
        } else {
            print("[DepthEstimator] Unsupported CoreML output type: \(String(describing: request.results))")
        }
    }
    
    private func processMultiArray(_ multiArray: MLMultiArray) {
        let shape = multiArray.shape
        guard shape.count >= 2 else { return }
        let height = shape[shape.count - 2].intValue
        let width = shape[shape.count - 1].intValue
        
        let isFloat16 = multiArray.dataType == .float16
        let pixelFormat: MTLPixelFormat = isFloat16 ? .r16Float : .r32Float
        
        if width != depthWidth || height != depthHeight || depthQueue == nil {
            depthWidth = width
            depthHeight = height
            do {
                let descriptor = TextureResource.DrawableQueue.Descriptor(
                    pixelFormat: pixelFormat,
                    width: width,
                    height: height,
                    usage: [.renderTarget, .shaderRead, .shaderWrite],
                    mipmapsMode: .none
                )
                depthQueue = try TextureResource.DrawableQueue(descriptor)
                depthQueue?.allowsNextDrawableTimeout = true
            } catch {
                print("[DepthEstimator] Failed to create drawable queue: \(error)")
                return
            }
        }
        
        guard let queue = depthQueue else { return }
        do {
            let drawable = try queue.nextDrawable()
            let targetTex = drawable.texture
            
            let itemSize = isFloat16 ? 2 : 4
            let rowStride = multiArray.strides[shape.count - 2].intValue * itemSize
            
            multiArray.withUnsafeBytes { buffer in
                if let baseAddress = buffer.baseAddress {
                    targetTex.replace(
                        region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: baseAddress,
                        bytesPerRow: rowStride
                    )
                }
            }
            drawable.present()
        } catch {}
    }
    
    private func processPixelBuffer(_ depthPixelBuffer: CVPixelBuffer) {
        // Convert to MTLTexture for the RealityKit shader
        if let textureCache = self.textureCache {
            let width = CVPixelBufferGetWidth(depthPixelBuffer)
            let height = CVPixelBufferGetHeight(depthPixelBuffer)
            let formatType = CVPixelBufferGetPixelFormatType(depthPixelBuffer)
            
            var metalPixelFormat: MTLPixelFormat = .r16Float
            if formatType == kCVPixelFormatType_32BGRA {
                metalPixelFormat = .bgra8Unorm
            } else if formatType == kCVPixelFormatType_OneComponent8 {
                metalPixelFormat = .r8Unorm
            } else if formatType == kCVPixelFormatType_OneComponent16Half {
                metalPixelFormat = .r16Float
            } else if formatType == kCVPixelFormatType_OneComponent32Float {
                metalPixelFormat = .r32Float
            }
            
            // Recreate queue if dimensions change
            if width != depthWidth || height != depthHeight || depthQueue == nil {
                depthWidth = width
                depthHeight = height
                do {
                    let descriptor = TextureResource.DrawableQueue.Descriptor(
                        pixelFormat: metalPixelFormat,
                        width: width,
                        height: height,
                        usage: [.renderTarget, .shaderRead, .shaderWrite],
                        mipmapsMode: .none
                    )
                    depthQueue = try TextureResource.DrawableQueue(descriptor)
                    depthQueue?.allowsNextDrawableTimeout = true
                } catch {
                    print("[DepthEstimator] Failed to create drawable queue: \(error)")
                }
            }
            
            var cvTextureOut: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                depthPixelBuffer,
                nil,
                metalPixelFormat,
                width,
                height,
                0,
                &cvTextureOut
            )
            
            if status == kCVReturnSuccess, let cvTexture = cvTextureOut, let sourceTex = CVMetalTextureGetTexture(cvTexture), let queue = depthQueue {
                do {
                    let drawable = try queue.nextDrawable()
                    let targetTex = drawable.texture
                    
                    if let commandBuffer = commandQueue?.makeCommandBuffer(),
                       let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                        blitEncoder.copy(from: sourceTex,
                                         sourceSlice: 0,
                                         sourceLevel: 0,
                                         sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                                         sourceSize: MTLSize(width: width, height: height, depth: 1),
                                         to: targetTex,
                                         destinationSlice: 0,
                                         destinationLevel: 0,
                                         destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                        blitEncoder.endEncoding()
                        commandBuffer.commit()
                        commandBuffer.waitUntilCompleted()
                        drawable.present()
                    }
                } catch {
                    // Queue timeout
                }
            }
        }
    }
}
