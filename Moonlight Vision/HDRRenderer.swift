import Metal
import simd
import CoreVideo
import CoreMedia

// Mirror of the C struct with explicit layout
struct HDRMetadataSwift {
    struct Primary {
        var x: UInt16 // Normalized to 50,000
        var y: UInt16 // Normalized to 50,000
    }
    
    // Exactly match C struct layout
    var primaries: (Primary, Primary, Primary) // 3 pairs of UInt16 = 12 bytes
    var whitePoint: Primary                    // 1 pair of UInt16 = 4 bytes
    var maxDisplayLuminance: UInt16            // 2 bytes
    var minDisplayLuminance: UInt16            // 2 bytes
    var maxContentLightLevel: UInt16           // 2 bytes
    var maxFrameAverageLightLevel: UInt16      // 2 bytes
    var maxFullFrameLuminance: UInt16          // 2 bytes
}

// Add static assertions
extension HDRMetadataSwift {
    static func validateLayout() {
        print("HDR Metadata layout:")
        print("Size: \(MemoryLayout<HDRMetadataSwift>.size) bytes")
        print("Alignment: \(MemoryLayout<HDRMetadataSwift>.alignment) bytes")
        print("Stride: \(MemoryLayout<HDRMetadataSwift>.stride) bytes")
    }
}

class HDRRenderer {
    private let computePipelineState: MTLComputePipelineState
    private let commandQueue: MTLCommandQueue
    private var metadataBuffer: MTLBuffer
    private var textureCache: CVMetalTextureCache?
    private let device: MTLDevice
    
    init(device: MTLDevice) throws {
        self.device = device
        
        // Create texture cache
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
        
        // Setup Metal pipeline for HDR processing
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "hdrProcessing") else {
            throw NSError(domain: "HDRRenderer", code: -1, 
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create Metal shader functions"])
        }
        
        computePipelineState = try device.makeComputePipelineState(function: function)
        guard let queue = device.makeCommandQueue() else {
            throw NSError(domain: "HDRRenderer", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create command queue"])
        }
        commandQueue = queue
        
        // Create metadata buffer with explicit options
        let bufferOptions: MTLResourceOptions = [.storageModeShared, .hazardTrackingModeTracked]
        guard let buffer = device.makeBuffer(length: 72,
                                           options: bufferOptions) else {
            throw NSError(domain: "HDRRenderer", code: -3,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create metadata buffer"])
        }
        metadataBuffer = buffer
        
        // Print buffer info
        print("Created metadata buffer:")
        print("- length: \(buffer.length)")
        print("- allocated size: \(buffer.allocatedSize)")
        print("- storage mode: \(buffer.storageMode.rawValue)")
        print("- cpu cache mode: \(buffer.cpuCacheMode.rawValue)")
    }
    
    func updateMetadata(_ cMetadata: SS_HDR_METADATA) {
        // First validate layout
        HDRMetadataSwift.validateLayout()
        
        // Safely copy C struct to our Swift struct
        var metadata = withUnsafePointer(to: cMetadata) { ptr in
            ptr.withMemoryRebound(to: HDRMetadataSwift.self, capacity: 1) { $0.pointee }
        }
        
        let ptr = metadataBuffer.contents()
        var offset = 0
        
        // Update Metal buffer with the values
        writeFloat3(ptr.advanced(by: offset), 
                   x: Float(metadata.primaries.0.x) / 50000.0,
                   y: Float(metadata.primaries.0.y) / 50000.0,
                   z: 1.0 - Float(metadata.primaries.0.x + metadata.primaries.0.y) / 50000.0)
        
        offset = 16
        
        writeFloat3(ptr.advanced(by: offset),
                   x: Float(metadata.primaries.1.x) / 50000.0,
                   y: Float(metadata.primaries.1.y) / 50000.0,
                   z: 1.0 - Float(metadata.primaries.1.x + metadata.primaries.1.y) / 50000.0)
        
        offset = 32
        
        writeFloat3(ptr.advanced(by: offset),
                   x: Float(metadata.primaries.2.x) / 50000.0,
                   y: Float(metadata.primaries.2.y) / 50000.0,
                   z: 1.0 - Float(metadata.primaries.2.x + metadata.primaries.2.y) / 50000.0)
        
        offset = 48
        
        // Write whitePoint (8 bytes)
        writeFloat2(ptr.advanced(by: offset),
                   x: Float(metadata.whitePoint.x) / 50000.0,
                   y: Float(metadata.whitePoint.y) / 50000.0)
        
        offset = 56
        
        // Write remaining floats (16 bytes total)
        writeFloat(ptr.advanced(by: offset), Float(metadata.maxDisplayLuminance))
        writeFloat(ptr.advanced(by: offset + 4), Float(metadata.minDisplayLuminance) / 10000.0)
        writeFloat(ptr.advanced(by: offset + 8), Float(metadata.maxContentLightLevel))
        writeFloat(ptr.advanced(by: offset + 12), Float(metadata.maxFrameAverageLightLevel))
    }
    
    private func writeFloat3(_ ptr: UnsafeMutableRawPointer, x: Float, y: Float, z: Float) {
        ptr.storeBytes(of: x, as: Float.self)
        ptr.advanced(by: 4).storeBytes(of: y, as: Float.self)
        ptr.advanced(by: 8).storeBytes(of: z, as: Float.self)
    }
    
    private func writeFloat2(_ ptr: UnsafeMutableRawPointer, x: Float, y: Float) {
        ptr.storeBytes(of: x, as: Float.self)
        ptr.advanced(by: 4).storeBytes(of: y, as: Float.self)
    }
    
    private func writeFloat(_ ptr: UnsafeMutableRawPointer, _ value: Float) {
        ptr.storeBytes(of: value, as: Float.self)
    }
    
    func processFrame(sourceBuffer: CVImageBuffer, targetTexture: MTLTexture, commandQueue: MTLCommandQueue) {
        print("Processing frame...")
        
        // Create Y texture (10-bit)
        var yTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(sourceBuffer)
        let height = CVPixelBufferGetHeight(sourceBuffer)
        
        print("Creating textures:")
        print("Y texture - width: \(width), height: \(height)")
        
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                 textureCache!,
                                                 sourceBuffer,
                                                 nil,
                                                 .r16Unorm,  // Change to 16-bit to handle 10-bit data
                                                 width,
                                                 height,
                                                 0,
                                                 &yTexture)
        
        // Create CbCr texture (10-bit)
        var cbcrTexture: CVMetalTexture?
        print("CbCr texture - width: \(width/2), height: \(height/2)")
        
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                 textureCache!,
                                                 sourceBuffer,
                                                 nil,
                                                 .rg16Unorm,  // Change to 16-bit to handle 10-bit data
                                                 width / 2,
                                                 height / 2,
                                                 1,
                                                 &cbcrTexture)
        
        guard let yMTLTexture = CVMetalTextureGetTexture(yTexture!),
              let cbcrMTLTexture = CVMetalTextureGetTexture(cbcrTexture!) else {
            print("Failed to create textures")
            return
        }
        
        print("Y format: \(yMTLTexture.pixelFormat.rawValue)")
        print("CbCr format: \(cbcrMTLTexture.pixelFormat.rawValue)")
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            print("Failed to create command buffer or compute encoder")
            return
        }
        
        computeEncoder.setComputePipelineState(computePipelineState)
        
        // Set textures and metadata
        computeEncoder.setTexture(yMTLTexture, index: 0)
        computeEncoder.setTexture(cbcrMTLTexture, index: 1)
        computeEncoder.setTexture(targetTexture, index: 2)
        computeEncoder.setBuffer(metadataBuffer, offset: 0, index: 0)
        
        // Calculate thread groups based on output dimensions
        let w = computePipelineState.threadExecutionWidth
        let h = computePipelineState.maxTotalThreadsPerThreadgroup / w
        let threadsPerThreadgroup = MTLSizeMake(w, h, 1)
        let threadgroupsPerGrid = MTLSizeMake(
            (width + w - 1) / w,
            (height + h - 1) / h,
            1)
        
        print("Dispatching compute shader with dimensions: \(width)x\(height)")
        
        computeEncoder.dispatchThreadgroups(threadgroupsPerGrid,
                                          threadsPerThreadgroup: threadsPerThreadgroup)
        
        computeEncoder.endEncoding()
        commandBuffer.commit()
    }
}
