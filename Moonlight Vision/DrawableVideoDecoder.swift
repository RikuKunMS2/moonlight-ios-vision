//
//  DrawableVideoDecoder.swift
//  Moonlight
//
//  Created by tht7 on 30/12/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import AVFoundation
import CoreVideo
import Foundation
import Metal
import MetalKit
import QuartzCore // For CADisplayLink
import RealityKit
import SwiftUI
import VideoToolbox

// Add these constants after your existing constants
let kCVPixelBufferYCbCrMatrixKey = "YCbCrMatrix" as CFString
let kCVPixelBufferColorPrimariesKey = "ColorPrimaries" as CFString
let kCVPixelBufferTransferFunctionKey = "TransferFunction" as CFString

struct HDRParams {
    var boost: Float      // Default: 2.0
    var gamma: Float      // Renamed from contrast. Default: 1.0
    var saturation: Float // Default: 1.0
    var brightness: Float // Default: 0.0
}

let kCVImageBufferYCbCrMatrix_ITU_R_2020 = "ITU_R_2020" as CFString
let kCVImageBufferColorPrimaries_ITU_R_2020 = "ITU_R_2020" as CFString
let kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ = "SMPTE_ST_2084_PQ" as CFString

// MARK: - VideoDecoderRenderer

@objc
class DrawableVideoDecoder: NSObject, AnyVideoDecoderRenderer {
    // MARK: - Properties

    private var callbacks: ConnectionCallbacks
    private var streamAspectRatio: Float

    let callbackToRender: @MainActor (TextureResource.DrawableQueue, (Int, Int)?) -> Void

    /// Format and frame info
    private var videoFormat: Int32 = 0
    private var frameRate: Int32 = 0
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0

    private var metalFormat: MTLPixelFormat
    private var decodingFormat: OSType

    /// If true, we'll do pacing logic in displayLink
    private var framePacing: Bool = false

    /// Store parameter set data for H.264 / HEVC
    private var parameterSetBuffers: [[UInt8]] = []

    /// HDR metadata
    private var masteringDisplayColorVolume: Data?
    private var contentLightLevelInfo: Data?
    
    private let hdrSettingsProvider: () -> HDRParams
    /// Our video format description, used when creating sample buffers
    private var formatDesc: CMVideoFormatDescription?

    /// Display link for pacing decode submissions
    private var displayLink: CADisplayLink?

    private let texture: TextureResource
    private var outTexture: MTLTexture?
    private var region = MTLRegionMake2D(0, 0, 1000, 1000)
    var textureCache: CVMetalTextureCache?
    var drawableQueue: TextureResource.DrawableQueue?

    var session: VTDecompressionSession?
    var decoderCallback: VTDecompressionOutputCallbackRecord
    lazy var mtlDevice: MTLDevice = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError()
        }
        return device
    }()

    private lazy var commandQueue: MTLCommandQueue? = mtlDevice.makeCommandQueue()

    private var imagePlaneVertexBuffer: MTLBuffer?

    private var hdrEnabled: Bool
    private var hdrMetadata: SS_HDR_METADATA = SS_HDR_METADATA()

    private var copyPipelineState: MTLRenderPipelineState? // Existing RGB pipeline
    private var yuvPipelineState: MTLRenderPipelineState?  // NEW YUV pipeline
    private var copyPipelineFormat: MTLPixelFormat?

    // MARK: - Initialization

    init(
        texture: TextureResource,
        callbacks: ConnectionCallbacks,
        aspectRatio: Float,
        useFramePacing: Bool,
        enableHDR: Bool = false,
        hdrSettingsProvider: @escaping () -> HDRParams, // <--- Removed @MainActor
        callbackToRender: @MainActor @escaping (TextureResource.DrawableQueue, (Int, Int)?) -> Void
    ) {
        self.hdrSettingsProvider = hdrSettingsProvider
        metalFormat = .rgba16Float

        // Format setup based on HDR
        decodingFormat = enableHDR ?
            kCVPixelFormatType_64RGBAHalf :
            kCVPixelFormatType_Lossless_32BGRA

        self.texture = texture
        self.callbacks = callbacks
        streamAspectRatio = aspectRatio
        framePacing = useFramePacing
        hdrEnabled = enableHDR
        self.callbackToRender = callbackToRender

        decoderCallback = VTDecompressionOutputCallbackRecord()
        
        super.init()
        
        // Setup C-Function Callback
        decoderCallback.decompressionOutputCallback = { decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
            let mySelf = Unmanaged<DrawableVideoDecoder>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
            mySelf.decompressionOutputCallback(
                decompressionOutputRefCon: decompressionOutputRefCon,
                sourceFrameRefCon: sourceFrameRefCon,
                status: status,
                infoFlags: infoFlags,
                imageBuffer: imageBuffer,
                presentationTimeStamp: presentationTimeStamp,
                presentationDuration: presentationDuration
            )
        }
        decoderCallback.decompressionOutputRefCon = Unmanaged.passUnretained(self).toOpaque()
    }
    
    // MARK: - Render Loop
    
    func decompressionOutputCallback(
            decompressionOutputRefCon _: UnsafeMutableRawPointer?,
            sourceFrameRefCon _: UnsafeMutableRawPointer?,
            status _: OSStatus,
            infoFlags _: VTDecodeInfoFlags,
            imageBuffer: CVImageBuffer?,
            presentationTimeStamp _: CMTime,
            presentationDuration _: CMTime?
        ) {
            guard
                let imageBuffer = imageBuffer,
                let textureCache = textureCache,
                let drawable = try? drawableQueue?.nextDrawable(),
                let commandBuffer = commandQueue?.makeCommandBuffer()
            else {
                // Silent return on dropped frames or missing resources
                return
            }

            if hdrEnabled {
                updateHDRMetadata()
            }

            // 1. DETERMINE PIPELINE (RGB vs YUV)
            // Check if we have 1 plane (BGRA/RGBA) or 2 planes (NV12/P010 YUV)
            let planeCount = CVPixelBufferGetPlaneCount(imageBuffer)
            let bufferPixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
            
            var currentPipeline: MTLRenderPipelineState?

            if planeCount > 1 {
                // --- YUV Pipeline (Zero-Copy Path) ---
                if self.yuvPipelineState == nil || copyPipelineFormat != metalFormat {
                    // Requires "copyFragmentShaderYUV" in Shaders.metal
                    self.yuvPipelineState = buildCopyPipeline(metalFormat, fragmentFunction: "copyFragmentShaderYUV")
                    if self.yuvPipelineState != nil { copyPipelineFormat = metalFormat }
                }
                currentPipeline = self.yuvPipelineState
            } else {
                // --- RGB Pipeline (Legacy/Fallback Path) ---
                if self.copyPipelineState == nil || copyPipelineFormat != metalFormat {
                    // Requires "copyFragmentShader" in Shaders.metal
                    self.copyPipelineState = buildCopyPipeline(metalFormat, fragmentFunction: "copyFragmentShader")
                    if self.copyPipelineState != nil { copyPipelineFormat = metalFormat }
                }
                currentPipeline = self.copyPipelineState
            }

            guard let pipelineState = currentPipeline else {
                print("Failed to acquire pipeline state")
                return
            }

            // 2. PREPARE HDR BUFFERS
            let (displayBuffer, contentBuffer) = createHDRParameterBuffers()
            
            // 3. CREATE INPUT TEXTURES
            var rgbTexture: CVMetalTexture?
            var yTexture: CVMetalTexture?
            var uvTexture: CVMetalTexture?
            
            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            
            // Handle resolution changes
            if width != videoWidth || height != videoHeight {
                videoWidth = width
                videoHeight = height
                setupLowLevelTexture()
            }

            // --- ENCODING PASS 1: RENDER (Decode/HDR -> Drawable Level 0) ---
            
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .dontCare // We overwrite everything
            renderPassDescriptor.colorAttachments[0].storeAction = .store

            guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }
            
            renderEncoder.setRenderPipelineState(pipelineState)
            
            // Bind Buffers
            if let enabledBuffer = displayBuffer {
                renderEncoder.setFragmentBuffer(enabledBuffer, offset: 0, index: 0)
            }
            if let paramsBuffer = contentBuffer {
                renderEncoder.setFragmentBuffer(paramsBuffer, offset: 0, index: 1)
            }
            
            // Bind Textures based on Plane Count
            if planeCount > 1 {
                // Determine pixel format for planes (8-bit vs 10-bit)
                // P010/10-bit formats are usually 'x420' or 'l10r'
                let is10Bit = (bufferPixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) ||
                              (bufferPixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
                
                let lumaFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
                let chromaFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm

                // Plane 0: Y (Luma)
                let _ = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, imageBuffer, nil, lumaFormat,
                    CVPixelBufferGetWidthOfPlane(imageBuffer, 0),
                    CVPixelBufferGetHeightOfPlane(imageBuffer, 0),
                    0, &yTexture
                )
                
                // Plane 1: UV (Chroma)
                let _ = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, imageBuffer, nil, chromaFormat,
                    CVPixelBufferGetWidthOfPlane(imageBuffer, 1),
                    CVPixelBufferGetHeightOfPlane(imageBuffer, 1),
                    1, &uvTexture
                )
                
                if let yTex = yTexture, let uvTex = uvTexture,
                   let mtlY = CVMetalTextureGetTexture(yTex),
                   let mtlUV = CVMetalTextureGetTexture(uvTex) {
                    renderEncoder.setFragmentTexture(mtlY, index: 0)
                    renderEncoder.setFragmentTexture(mtlUV, index: 1)
                }
            } else {
                // Single Plane RGB
                let srcMetalFormats = CVMetalHelpers.getTextureTypesForFormat(bufferPixelFormat)
                let _ = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, imageBuffer, nil, srcMetalFormats[0],
                    width, height, 0, &rgbTexture
                )
                
                if let rgbTex = rgbTexture, let mtlRGB = CVMetalTextureGetTexture(rgbTex) {
                    renderEncoder.setFragmentTexture(mtlRGB, index: 0)
                }
            }
            
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()

            // --- ENCODING PASS 2: BLIT (Generate Mipmaps for Shimmer Fix) ---
            // Occurs in the same command buffer to ensure no CPU stalls.
            
            if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                blitEncoder.generateMipmaps(for: drawable.texture)
                blitEncoder.endEncoding()
            }

            // --- SUBMISSION ---
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
            // NOTE: We intentionally removed waitUntilCompleted() to prevent stutter.
        }
    
    private func createHDRParameterBuffers() -> (MTLBuffer?, MTLBuffer?) {
        var hdrEnabled = self.hdrEnabled
        let enabledBuffer = mtlDevice.makeBuffer(bytes: &hdrEnabled,
                                               length: MemoryLayout<Bool>.size,
                                               options: .storageModeShared)
        
        // --- FIX: Read directly (Thread-Safe) ---
        // We no longer dispatch to Main. We assume the provider is thread-safe.
        var hdrParams = self.hdrSettingsProvider()
        // ----------------------------------------
        
        let paramsBuffer = mtlDevice.makeBuffer(bytes: &hdrParams,
                                              length: MemoryLayout<HDRParams>.size,
                                              options: .storageModeShared)
        
        return (enabledBuffer, paramsBuffer)
    }
            
    func setupLowLevelTexture() {
        DispatchQueue.main.sync {
            if videoWidth == 0 || videoHeight == 0 { return }

            self.drawableQueue = {
                let descriptor = TextureResource.DrawableQueue.Descriptor(
                    pixelFormat: metalFormat,
                    width: Int(videoWidth),
                    height: Int(videoHeight),
                    usage: [.renderTarget, .shaderRead], // .shaderRead needed for the Blit engine to read Level 0
                    mipmapsMode: .allocateAll // <--- FIX: MUST be allocateAll to stop shimmer
                )
                do {
                    let queue = try TextureResource.DrawableQueue(descriptor)
                    queue.allowsNextDrawableTimeout = true
                    return queue
                } catch {
                    fatalError("Could not create DrawableQueue: \(error)")
                }
            }()
            region = MTLRegionMake2D(0, 0, videoWidth, videoHeight)
            self.callbackToRender(self.drawableQueue!, (videoWidth, videoHeight))
        }
    }

    /// Basic setup for the decoder
    func setup(withVideoFormat videoFormat: Int32, width videoWidth: Int32, height videoHeight: Int32, frameRate: Int32) {
        self.videoFormat = videoFormat
        self.frameRate = frameRate
        self.videoWidth = Int(videoWidth)
        self.videoHeight = Int(videoHeight)

        // Configure cache attributes with HDR support if enabled
        let cacheAttributes: [String: Any] = [
            kCVMetalTextureCacheMaximumTextureAgeKey as String: 1,
        ]

        let textureAttributes: [String: Any] = {
            var attrs: [String: Any] = [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight,
                kCVPixelBufferPixelFormatTypeKey as String: decodingFormat,
            ]

            if hdrEnabled {
                attrs[kCVPixelBufferYCbCrMatrixKey as String] = kCVImageBufferYCbCrMatrix_ITU_R_2020
                attrs[kCVPixelBufferColorPrimariesKey as String] = kCVImageBufferColorPrimaries_ITU_R_2020
                attrs[kCVPixelBufferTransferFunctionKey as String] = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            }

            return attrs
        }()

        let res = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            cacheAttributes as CFDictionary,
            mtlDevice,
            textureAttributes as CFDictionary,
            &textureCache
        )

        if res != kCVReturnSuccess {
            print("Creating texture cache failed \(res)")
        }

        setupLowLevelTexture()
    }

    /// Start the rendering loop (via CADisplayLink)
    func start() {
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkCallback(_:)))
        if #available(iOS 15.0, tvOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(frameRate),
                maximum: Float(frameRate),
                preferred: Float(frameRate)
            )
        } else {
            displayLink?.preferredFramesPerSecond = Int(frameRate)
        }

        displayLink?.add(to: .main, forMode: .default)
    }

    /// Stop the rendering loop
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Rendering Loop

    @objc private func displayLinkCallback(_ sender: CADisplayLink) {
        var handle: VIDEO_FRAME_HANDLE?
        var du: PDECODE_UNIT?

        while LiPollNextVideoFrame(&handle, &du) {
            // Once we get a new frame from the network/stream, submit it
            guard let handle = handle, let du = du else {
                continue
            }

            // (Implementation detail) DrSubmitDecodeUnit is presumably your custom decode function
            let result = DrSubmitDecodeUnit(du)
            LiCompleteVideoFrame(handle, result)

            // Frame pacing logic
            if framePacing {
                let displayRefreshRate = 1.0 / (sender.targetTimestamp - sender.timestamp)
                if displayRefreshRate >= Double(frameRate) * 0.9 {
                    // Keep one pending frame to smooth out network jitter
                    if LiGetPendingVideoFrames() == 1 {
                        break
                    }
                }
            }
        }
    }

    // MARK: - Decoding & Sample Buffer Handling

    /**
     * Replaces the old `AVSampleBufferDisplayLayer` usage.
     * Instead of enqueuing to a display layer, we create a `CMSampleBuffer`
     * and forward it to your own rendering path (e.g., a Metal texture queue).
     */
    @discardableResult
    func submitDecodeBuffer(
        _ dataPtr: UnsafeMutablePointer<UInt8>!,
        length: Int32,
        bufferType: Int32,
        decode du: PDECODE_UNIT!
    ) -> Int32 {
        // Example bridging of FRAME_TYPE_IDR check:
        if du.pointee.frameType == FRAME_TYPE_IDR {
            // Parameter sets or AV1 config logic...
            // Recreate formatDesc, etc.
            if bufferType != BUFFER_TYPE_PICDATA {
                if bufferType == BUFFER_TYPE_VPS
                    || bufferType == BUFFER_TYPE_SPS
                    || bufferType == BUFFER_TYPE_PPS
                {
                    // Strip the NAL start and store it
                    let startLen = (dataPtr[2] == 0x01) ? 3 : 4
                    let newData = Data(bytes: dataPtr + startLen, count: Int(length) - startLen)
                    parameterSetBuffers.append([UInt8](newData))
                }
                // Freed by someone else, presumably
                return DR_OK
            }

            // If we're handling an IDR frame with actual picture data
            if let formatDesc = recreateFormatDescriptionForIDR(
                dataPtr: dataPtr, length: length
            ) {
                self.formatDesc = formatDesc
                
                let decoderConfiguration: [String: Any] = {
                    var config: [String: Any] = [
                        kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
                    ]

                    if hdrEnabled {
                        config[kVTDecompressionPropertyKey_PixelTransferProperties as String] = [
                            // 1. Convert Colors to Display P3 (Fixes the "Washed Out" pale colors)
                            kVTPixelTransferPropertyKey_DestinationColorPrimaries: kCMFormatDescriptionColorPrimaries_P3_D65,

                            // 2. Keep Brightness as PQ (Fixes the "Black Screen" / conversion error)
                            // We will decode this raw curve manually in the Metal shader.
                            kVTPixelTransferPropertyKey_DestinationTransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                            
                            // 3. Standard Matrix
                            kVTPixelTransferPropertyKey_DestinationYCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
                        ]
                    }

                    return config
                }()
                // NOTE(shinyquagsire23): Setting kCVPixelBufferPixelFormatTypeKey *at all* will trigger
                // a VideoToolbox bug that results in the output CVPixelBuffer's underlying Metal textures
                // being decompressed, resulting in GPU bandwidth penalties
                var attributes: [CFString: Any] = [
                    kCVPixelBufferMetalCompatibilityKey: true,
                    kCVPixelBufferPoolMinimumBufferCountKey: 3
                ]
                
                // We now have a YUV Metal shader, so we do NOT need to force the pixel format.
                // Letting VideoToolbox choose the format (P010/NV12) allows "Zero-Copy" decoding
                // which is essential for 8K/4K AV1 performance.

                // Only keep this line if 'forceFastSecretTextureFormats' is FALSE (simulator/debugging)
                if !forceFastSecretTextureFormats {
                    attributes[kCVPixelBufferPixelFormatTypeKey] = decodingFormat
                }
                
                VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: formatDesc, decoderSpecification: decoderConfiguration as CFDictionary, imageBufferAttributes: attributes as CFDictionary, outputCallback: &decoderCallback, decompressionSessionOut: &session)
                
                // Use exclusive audio mode (microphone not active in this context)
                AudioHelpers.fixAudioForSurroundForCurrentWindow(exclusive: false) // TODO(shinyquagsire23): Make this configurable?
            } else {
                // Couldn't create format description yet
//                free(dataPtr)
                return DR_NEED_IDR
            }
        }

        guard let formatDesc = formatDesc else {
            // We don't have our format yet
//            free(dataPtr)
            return DR_NEED_IDR
        }

        // Now create a CMSampleBuffer and pass it to your rendering pipeline
        guard let sampleBuffer = createSampleBuffer(
            dataPtr: dataPtr,
            length: Int(length),
            formatDesc: formatDesc,
            decodeUnit: du
        ) else {
            // If creation fails, free and request IDR
            free(dataPtr)
            return DR_NEED_IDR
        }

        // Instead of displayLayer.enqueueSampleBuffer(...),
        // we do our own custom rendering:
        VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sampleBuffer, flags: [._EnableAsynchronousDecompression], frameRefcon: nil, infoFlagsOut: nil)

        // If's an IDR, notify that video content is visible
        if du.pointee.frameType == FRAME_TYPE_IDR {
            callbacks.videoContentShown()
        }

        return DR_OK
    }

    // MARK: - Helper: Recreate Format Description for IDR

    private func recreateFormatDescriptionForIDR(
        dataPtr: UnsafeMutablePointer<UInt8>,
        length: Int32
    ) -> CMVideoFormatDescription? {
        // Freed old formatDesc
        if let old = formatDesc {
//            CFRelease(old)
            formatDesc = nil
        }

        // If's H.264 or HEVC, gather parameter sets
        if (videoFormat & VIDEO_FORMAT_MASK_H264) != 0 {
            return createH264FormatDescription()
        } else if (videoFormat & VIDEO_FORMAT_MASK_H265) != 0 {
            return createHEVCFormatDescription()
        } else if (videoFormat & VIDEO_FORMAT_MASK_AV1) != 0 {
            // For AV1, parse your IDR frame to create a format desc
            let frameData = Data(bytesNoCopy: dataPtr, count: Int(length), deallocator: .none)
            return createAV1FormatDescriptionForIDRFrame(frameData)
        } else {
            // Unsupported
            abort()
        }
    }

    /// Creates an H.264 `CMVideoFormatDescription` from the stored `parameterSetBuffers`.
    private func createH264FormatDescription() -> CMVideoFormatDescription? {
        let parameterSetCount = parameterSetBuffers.count
        var paramPtrs: [UnsafePointer<UInt8>] = []
        var paramSizes: [Int] = []

        for (index, ps) in parameterSetBuffers.enumerated() {
            paramPtrs.append(UnsafePointer<UInt8>(parameterSetBuffers[index]))
            paramSizes.append(ps.count)
        }

        var fromatDesc: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: parameterSetCount,
            parameterSetPointers: paramPtrs,
            parameterSetSizes: paramSizes,
            nalUnitHeaderLength: Int32(NAL_LENGTH_PREFIX_SIZE),
            formatDescriptionOut: &fromatDesc
        )

        if status != noErr {
            print("Failed to create H264 format description: \(status)")
            return nil
        }
        return fromatDesc
    }

    /// Creates an HEVC `CMVideoFormatDescription` from the stored `parameterSetBuffers`.
    private func createHEVCFormatDescription() -> CMVideoFormatDescription? {
        let parameterSetCount = parameterSetBuffers.count
        var paramPtrs: [UnsafePointer<UInt8>] = []
        var paramSizes: [Int] = []

        for ps in parameterSetBuffers {
            paramPtrs.append(UnsafePointer<UInt8>(ps))
            paramSizes.append(ps.count)
        }

        // Prepare metadata dictionary
        var videoFormatParams = NSMutableDictionary()

        if let contentLightLevelInfo = contentLightLevelInfo {
            videoFormatParams.setObject(contentLightLevelInfo, forKey: kCMFormatDescriptionExtension_ContentLightLevelInfo as NSString)
//            videoFormatParams[kCMFormatDescriptionExtension_ContentLightLevelInfo] = contentLightLevelInfo
        }
        if let masteringDisplayColorVolume = masteringDisplayColorVolume {
//            videoFormatParams[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = masteringDisplayColorVolume
            videoFormatParams.setObject(masteringDisplayColorVolume, forKey: kCMFormatDescriptionExtension_MasteringDisplayColorVolume as NSString)
        }

        var formatDesc: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: parameterSetCount,
            parameterSetPointers: paramPtrs,
            parameterSetSizes: paramSizes,
            nalUnitHeaderLength: Int32(NAL_LENGTH_PREFIX_SIZE),
            extensions: videoFormatParams as CFDictionary,
            formatDescriptionOut: &formatDesc
        )

//        parameterSetBuffers.removeAll()
//        _ = paramPtrs.map(UnsafePointer<UInt8>.deallocate)
//        paramPtrs.removeAll()
        if status != noErr {
            print("Failed to create HEVC format description: \(status)")
            return nil
        }
        return formatDesc
    }

    /// Creates an AV1 `CMVideoFormatDescription` from the data for an IDR frame.
        private func createAV1FormatDescriptionForIDRFrame(_ frameData: Data) -> CMVideoFormatDescription? {
            // We must parse the bitstream to find the Sequence Header OBU
            // and generate the 'av1C' atom required by VideoToolbox.
            
            guard let (sequenceHeader, config) = AV1Parser.parseSequenceHeader(from: frameData) else {
                print("Failed to parse AV1 Sequence Header from IDR frame.")
                return nil
            }

            let extensions = buildAV1Extensions(config: config, sequenceHeader: sequenceHeader)

            var newDesc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_AV1,
                width: Int32(self.videoWidth), // Use the session width/height
                height: Int32(self.videoHeight),
                extensions: extensions,
                formatDescriptionOut: &newDesc
            )
            
            if status != noErr {
                print("Failed to create AV1 format description: \(status)")
                return nil
            }
            
            return newDesc
        }

        private func buildAV1Extensions(config: AV1Config, sequenceHeader: Data) -> CFDictionary {
            // Construct the av1C atom
            // https://aomediacodec.github.io/av1-isobmff/#av1c-box
            
            var av1C = Data()
            
            // Marker (1 bit) = 1, Version (7 bits) = 1 -> 0x81
            av1C.append(0x81)
            
            // seq_profile (3 bits), seq_level_idx_0 (5 bits)
            let profileLevel = (UInt8(config.seqProfile & 0x7) << 5) | (UInt8(config.seqLevelIdx0 & 0x1F))
            av1C.append(profileLevel)
            
            // seq_tier_0 (1), high_bitdepth (1), twelve_bit (1), monochrome (1),
            // chroma_subsampling_x (1), chroma_subsampling_y (1), chroma_sample_position (2)
            var flags: UInt8 = 0
            flags |= (config.seqTier0 != 0 ? 1 : 0) << 7
            flags |= (config.highBitdepth != 0 ? 1 : 0) << 6
            flags |= (config.twelveBit != 0 ? 1 : 0) << 5
            flags |= (config.monochrome != 0 ? 1 : 0) << 4
            flags |= (config.chromaSubsamplingX != 0 ? 1 : 0) << 3
            flags |= (config.chromaSubsamplingY != 0 ? 1 : 0) << 2
            flags |= (UInt8(config.chromaSamplePosition & 0x3))
            av1C.append(flags)
            
            // reserved (3) = 0, initial_presentation_delay_present (1), initial_presentation_delay_minus_one (4)
            // We usually assume no special delay for realtime streaming
            av1C.append(0x00)
            
            // configOBUs (The full sequence header OBU)
            av1C.append(sequenceHeader)
            
            var extensions: [CFString: Any] = [:]
            extensions[kCMFormatDescriptionExtension_FormatName] = "av01"
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = [
                "av1C": av1C
            ] as [String: Any]
            
            return extensions as CFDictionary
        }

    // MARK: - Creating a Sample Buffer

    private func printFormatDescription(_ formatDesc: CMFormatDescription) {
        print("\nDecoder configuration:")
        print("Media type: \(CMFormatDescriptionGetMediaType(formatDesc))")
        print("Media subtype: \(CMFormatDescriptionGetMediaSubType(formatDesc))")

        if let colorPrimaries = CMFormatDescriptionGetExtension(formatDesc, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) {
            print("Color primaries: \(colorPrimaries)")
        }
        if let transferFunction = CMFormatDescriptionGetExtension(formatDesc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) {
            print("Transfer function: \(transferFunction)")
        }
        if let ycbcrMatrix = CMFormatDescriptionGetExtension(formatDesc, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) {
            print("YCbCr matrix: \(ycbcrMatrix)")
        }
    }

    private func printBufferAttributes(_ imageBuffer: CVImageBuffer) {
        if let attachments = CVBufferGetAttachments(imageBuffer, .shouldPropagate) as? [String: Any] {
            print("\nBuffer attachments:")
            for (key, value) in attachments {
                print("\(key): \(value)")
                
                // Parse MasteringDisplayColorVolume if present
                if key == kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String,
                   let masteringData = value as? Data {
                    parseMasteringDisplayColorVolume(masteringData)
                }
            }
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        print("\nPixel format details:")
        print("Format: \(String(format: "0x%08x", pixelFormat))")
        print("Plane count: \(CVPixelBufferGetPlaneCount(imageBuffer))")
        print("Color attachments present: \(CVBufferHasAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey))")

        // Print plane details
        for plane in 0 ..< CVPixelBufferGetPlaneCount(imageBuffer) {
            print("\nPlane \(plane):")
            print("Width: \(CVPixelBufferGetWidthOfPlane(imageBuffer, plane))")
            print("Height: \(CVPixelBufferGetHeightOfPlane(imageBuffer, plane))")
            print("Bytes per row: \(CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, plane))")
        }
    }

    private func createSampleBuffer(
        dataPtr: UnsafeMutablePointer<UInt8>,
        length: Int,
        formatDesc: CMVideoFormatDescription,
        decodeUnit: PDECODE_UNIT!
    ) -> CMSampleBuffer? {
        // Create an empty container block for rewriting AnnexB to length-delimited if needed
        var frameBlockBuffer: CMBlockBuffer?

        // If H.264/HEVC, rewrite from AnnexB to length-delimited
        if (videoFormat & (VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265)) != 0 {
            // dataPtr is either tied to the resulting BB, or is copied and freed immediately.
            // dataPtr is also freed even if the result is nil.
            let nals = UnsafeMutableBufferPointer<UInt8>(start: UnsafeMutablePointer(mutating: dataPtr), count: length)
            frameBlockBuffer = annexBBufferToCMSampleBuffer(buffer: nals, videoFormat: formatDesc)
        } else {
            // AV1 or other codecs that don't need rewriting
            let statusDataBlock = CMBlockBufferCreateWithMemoryBlock(
                allocator: nil,
                memoryBlock: dataPtr,
                blockLength: length,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: length,
                flags: 0,
                blockBufferOut: &frameBlockBuffer
            )
            if statusDataBlock != kCMBlockBufferNoErr {
                print("CMBlockBufferCreateWithMemoryBlock failed: \(statusDataBlock)")
                return nil
            }
            // Now the CMBlockBuffer controls freeing `dataPtr`
        }

        // Build the sample buffer
        var sampleBuffer: CMSampleBuffer?
        var sampleTiming = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTimeMake(value: Int64(decodeUnit.pointee.presentationTimeMs), timescale: 1000),
            decodeTimeStamp: CMTime.invalid
        )
        let statusSample = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: frameBlockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        if statusSample != noErr {
            print("CMSampleBufferCreate failed: \(statusSample)")
            return nil
        }
//        print("MEDIA TYPE: \(formatDesc.mediaType)")
//        print("MEDIA SUBTYPE: \(formatDesc.mediaSubType)")
//        guard let sampleBuffer = sampleBuffer,
//                var _ = CMSampleBufferGetImageBuffer(sampleBuffer) else {
//            print("NO BUFFER HERE ")
//            return sampleBuffer
//        }

        return sampleBuffer
    }

    // Based on https://webrtc.googlesource.com/src/+/refs/heads/main/common_video/h264/h264_common.cc
    private func findNaluIndices(bufferBounded: UnsafeMutableBufferPointer<UInt8>) -> ([NaluIndex], Bool) {
        var elgibleForModifyInPlace = true
        guard bufferBounded.count >= /* kNaluShortStartSequenceSize */ 3 else {
            return ([], false)
        }

        var sequences = [NaluIndex]()

        let end = bufferBounded.count - /* kNaluShortStartSequenceSize */ 3
        var i = 0
        let buffer = Data(bytesNoCopy: bufferBounded.baseAddress!, count: bufferBounded.count, deallocator: .none) // ?? why is this faster
        while i < end {
            if buffer[i + 2] > 1 {
                i += 3
            } else if buffer[i + 2] == 1 {
                if buffer[i + 1] == 0 && buffer[i] == 0 {
                    var index = NaluIndex(startOffset: i, payloadStartOffset: i + 3, payloadSize: 0, threeByteHeader: true)
                    if index.startOffset > 0 && buffer[index.startOffset - 1] == 0 {
                        index.startOffset -= 1
                        index.threeByteHeader = false
                    } else {
                        elgibleForModifyInPlace = false
                    }

                    if !sequences.isEmpty {
                        sequences[sequences.count - 1].payloadSize = index.startOffset - sequences.last!.payloadStartOffset
                    }

                    sequences.append(index)
                }

                i += 3
            } else {
                i += 1
            }
        }

        if !sequences.isEmpty {
            sequences[sequences.count - 1].payloadSize = bufferBounded.count - sequences.last!.payloadStartOffset
        }

        return (sequences, elgibleForModifyInPlace)
    }

    private struct NaluIndex {
        var startOffset: Int
        var payloadStartOffset: Int
        var payloadSize: Int
        var threeByteHeader: Bool
    }

    // Based on https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/components/video_codec/nalu_rewriter.cc
    private func annexBBufferToCMSampleBuffer(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat: CMFormatDescription) -> CMBlockBuffer? {
        let (naluIndices, elgibleForModifyInPlace) = findNaluIndices(bufferBounded: buffer)

        if elgibleForModifyInPlace {
            return annexBBufferToCMSampleBufferModifyInPlace(buffer: buffer, videoFormat: videoFormat, naluIndices: naluIndices)
        } else {
            return annexBBufferToCMSampleBufferWithCopy(buffer: buffer, videoFormat: videoFormat, naluIndices: naluIndices)
        }
    }

    private func annexBBufferToCMSampleBufferWithCopy(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat _: CMFormatDescription, naluIndices: [NaluIndex]) -> CMBlockBuffer? {
        var err: OSStatus = 0
        defer { buffer.deallocate() }

        // we're replacing the 3/4 nalu headers with a 4 byte length, so add an extra byte on top of the original length for each 3-byte nalu header
        let blockBufferLength = buffer.count + naluIndices.filter(\.threeByteHeader).count
        let blockBuffer = try! CMBlockBuffer(length: blockBufferLength, flags: .assureMemoryNow)

        var contiguousBuffer: CMBlockBuffer!
        if !CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: 0) {
            err = CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: blockBuffer, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &contiguousBuffer)
            if err != 0 {
                print("CMBlockBufferCreateContiguous error")
                return nil
            }
        } else {
            contiguousBuffer = blockBuffer
        }

        var blockBufferSize = 0
        var dataPtr: UnsafeMutablePointer<Int8>!
        err = CMBlockBufferGetDataPointer(contiguousBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &blockBufferSize, dataPointerOut: &dataPtr)
        if err != 0 {
            print("CMBlockBufferGetDataPointer error")
            return nil
        }

        let pointer = UnsafeMutablePointer<UInt8>(OpaquePointer(dataPtr))!
        var offset = 0

        buffer.withUnsafeBytes { unsafeBytes in
            let bytes = unsafeBytes.bindMemory(to: UInt8.self).baseAddress!

            for index in naluIndices {
                pointer.advanced(by: offset).pointee = UInt8((index.payloadSize >> 24) & 0xFF)
                pointer.advanced(by: offset + 1).pointee = UInt8((index.payloadSize >> 16) & 0xFF)
                pointer.advanced(by: offset + 2).pointee = UInt8((index.payloadSize >> 8) & 0xFF)
                pointer.advanced(by: offset + 3).pointee = UInt8((index.payloadSize) & 0xFF)
                offset += 4

                pointer.advanced(by: offset).update(from: bytes.advanced(by: index.payloadStartOffset), count: blockBufferSize - offset)
                offset += index.payloadSize
            }
        }

        return contiguousBuffer
    }

    private func annexBBufferToCMSampleBufferModifyInPlace(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat _: CMFormatDescription, naluIndices: [NaluIndex]) -> CMBlockBuffer? {
        var offset = 0

        let umrbp = UnsafeMutableRawBufferPointer(start: buffer.baseAddress, count: buffer.count)
        let bb = try! CMBlockBuffer(buffer: umrbp, deallocator: { _, _ in buffer.deallocate() }, flags: .assureMemoryNow)

        let pointer = UnsafeMutablePointer<UInt8>(OpaquePointer(buffer.baseAddress!))!
        for index in naluIndices {
            pointer.advanced(by: offset + 0).pointee = UInt8((index.payloadSize >> 24) & 0xFF)
            pointer.advanced(by: offset + 1).pointee = UInt8((index.payloadSize >> 16) & 0xFF)
            pointer.advanced(by: offset + 2).pointee = UInt8((index.payloadSize >> 8) & 0xFF)
            pointer.advanced(by: offset + 3).pointee = UInt8((index.payloadSize) & 0xFF)
            offset += 4

            offset += index.payloadSize
        }

        if bb == nil {
            buffer.deallocate()
        }

        return bb
    }

    // MARK: - Rendering to the Drawable

    /**
     * Instead of using AVSampleBufferDisplayLayer, you would hand the sample buffer off
     * to your rendering pipeline. For example:
     * 1) Create a CVPixelBuffer from the sample buffer
     * 2) Wrap it in a Metal texture (using `CVMetalTextureCacheCreateTextureFromImage`)
     * 3) Enqueue the texture in a command buffer or store in a GPU queue
     *
     * This is a placeholder function for demonstration.
     */
    private func renderSampleBufferToDrawable(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription: CMFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        let mediaType: CMMediaType = CMFormatDescriptionGetMediaType(formatDescription)

        if mediaType == kCMMediaType_Audio {
            print("this was an audio sample....")
            return
        }

        // Example: Convert to CVPixelBuffer
        guard var imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let drawable = try! drawableQueue!.nextDrawable()
        drawable.texture.replace(region: .init(), mipmapLevel: 0, withBytes: &imageBuffer, bytesPerRow: CVPixelBufferGetBytesPerRow(imageBuffer))

        drawable.present()
        print("Render sample buffer to custom drawable pipeline")
    }

    // MARK: - HDR Mode

    func setHdrMode(_ enabled: Bool) {
        var metadataChanged = false

        // Mastering display color volume check
        let displayMetadata = HDRParsingUtils.parseHDRDisplayMetadata(enabled)

        if let displayMetadata = displayMetadata,
           masteringDisplayColorVolume == nil ||
           masteringDisplayColorVolume != displayMetadata
        {
            masteringDisplayColorVolume = displayMetadata
            metadataChanged = true
        } else if masteringDisplayColorVolume != nil {
            masteringDisplayColorVolume = nil
            metadataChanged = true
        }

        // Content light level info check
        let lightMetadata = HDRParsingUtils.parseHDRLightMetadata(enabled)
        if let lightMetadata = lightMetadata,
           contentLightLevelInfo == nil ||
           contentLightLevelInfo != lightMetadata
        {
            contentLightLevelInfo = lightMetadata
            metadataChanged = true
        } else if contentLightLevelInfo != nil {
            contentLightLevelInfo = nil
            metadataChanged = true
        }

        if metadataChanged {
            updateHDRMetadata()
            LiRequestIdrFrame()
        }
    }

    // Builds a simple copy pipeline with no input buffers, just
        // draw 4 vertices to copy the input texture to the output.
        // Now supports dynamic fragment function selection (RGB vs YUV).
        private func buildCopyPipeline(_ pixelFormat: MTLPixelFormat, fragmentFunction: String) -> MTLRenderPipelineState? {
            guard
                let library = mtlDevice.makeDefaultLibrary()
            else {
                print("Failed to load default Metal library")
                return nil
            }
            
            // Load the constant vertex shader and the dynamic fragment shader
            guard let vertexFunction = library.makeFunction(name: "copyVertexShader"),
                  let fragmentFunc = library.makeFunction(name: fragmentFunction) else {
                print("Failed to load shader functions: copyVertexShader or \(fragmentFunction)")
                return nil
            }
            
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.label = "CopyBlitPipeline_\(fragmentFunction)"
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunc
            
            // Ensure the output format matches the Drawable (usually .rgba16Float for HDR)
            pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
            
            // Disable blending since we are strictly copying/overwriting pixels
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
            
            pipelineDescriptor.maxVertexAmplificationCount = 1

            do {
                return try mtlDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            } catch {
                print("Failed to create render pipeline state: \(error)")
                return nil
            }
        }

    // Convert big endian UInt16 to host Float
    private func convertBigEndianUInt16ToFloat(_ value: UInt16) -> Float {
        let hostValue = CFSwapInt16BigToHost(value)
        return Float(hostValue)
    }


    // MARK: - METAL

    private let planeVertexData: [Float] = [
        -1, -1, 0, 1,
        1, -1, 1, 1,
        -1, 1, 0, 0,
        1, 1, 1, 0,
    ]

    // Add new method to update HDR metadata
    private func updateHDRMetadata() {
        // Get HDR metadata from Moonlight
        if !LiGetHdrMetadata(&hdrMetadata) {
            print("Failed to fetch HDR metadata from Moonlight")
        }
    }
    
    // Parse SMPTE ST 2086 mastering display color volume metadata
    private func parseMasteringDisplayColorVolume(_ data: Data) {
        // Data should be 24 bytes
        guard data.count == 24 else {
            print("Invalid metadata length: \(data.count)")
            return
        }

        // Extract values (stored as normalized 16-bit unsigned integers)
        let displayPrimariesX = [
            Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) })) / 50000.0,
            Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) })) / 50000.0,
            Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt16.self) })) / 50000.0
        ]
        
        let displayPrimariesY = [
            Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) })) / 50000.0,
            Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) })) / 50000.0,
            Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 10, as: UInt16.self) })) / 50000.0
        ]
        
        let whitePointX = Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt16.self) })) / 50000.0
        let whitePointY = Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 14, as: UInt16.self) })) / 50000.0
        
        let maxDisplayLuminance = Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt16.self) }))
        let minDisplayLuminance = Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 18, as: UInt16.self) })) / 10000.0

        print("\nHDR Display Metadata:")
        print("Display Primaries (x,y):")
        print("Red:   (\(displayPrimariesX[0]), \(displayPrimariesY[0]))")
        print("Green: (\(displayPrimariesX[1]), \(displayPrimariesY[1]))")
        print("Blue:  (\(displayPrimariesX[2]), \(displayPrimariesY[2]))")
        print("White Point: (\(whitePointX), \(whitePointY))")
        print("Max Display Luminance: \(maxDisplayLuminance) nits")
        print("Min Display Luminance: \(minDisplayLuminance) nits")
    }
}

// MARK: - Constants Port

private let NALU_START_PREFIX_SIZE: Int = 3
private let NAL_LENGTH_PREFIX_SIZE: Int = 4

// Example: In Objective-C, you had #define VIDEO_FORMAT_MASK_H264 ...
let VIDEO_FORMAT_H264: Int32 = 0x0001 // H.264 High Profile
let VIDEO_FORMAT_H265: Int32 = 0x0100 // HEVC Main Profile
let VIDEO_FORMAT_H265_MAIN10: Int32 = 0x0200 // HEVC Main10 Profile
let VIDEO_FORMAT_AV1_MAIN8: Int32 = 0x1000 // AV1 Main 8-bit profile
let VIDEO_FORMAT_AV1_MAIN10: Int32 = 0x2000 // AV1 Main 10-bit profile

// Masks for clients to use to match video codecs without profile-specific details.
let VIDEO_FORMAT_MASK_H264: Int32 = 0x000F
let VIDEO_FORMAT_MASK_H265: Int32 = 0x0F00
let VIDEO_FORMAT_MASK_AV1: Int32 = 0xF000
let VIDEO_FORMAT_MASK_10BIT: Int32 = 0x2200

// Example placeholders for your decodeUnit
let FRAME_TYPE_IDR = 0x01
let BUFFER_TYPE_PICDATA = 0x00
let BUFFER_TYPE_VPS = 1
let BUFFER_TYPE_SPS = 2
let BUFFER_TYPE_PPS = 3

// Example decode results
let DR_OK: Int32 = 0
let DR_NEED_IDR: Int32 = -1

// MARK: - AV1 Parsing Helpers

struct AV1Config {
    let seqProfile: Int
    let seqLevelIdx0: Int
    let seqTier0: Int
    let highBitdepth: Int
    let twelveBit: Int
    let monochrome: Int
    let chromaSubsamplingX: Int
    let chromaSubsamplingY: Int
    let chromaSamplePosition: Int
}

class AV1Parser {
    static func parseSequenceHeader(from data: Data) -> (Data, AV1Config)? {
        let bytes = [UInt8](data)
        var offset = 0
        let len = bytes.count
        
        // Iterate over OBUs
        while offset < len {
            let startIndex = offset
            
            // 1. Parse OBU Header
            if offset >= len { break }
            let headerByte = bytes[offset]
            offset += 1
            
            let forbiddenBit = (headerByte >> 7) & 1
            if forbiddenBit != 0 { return nil } // Valid OBU must have 0 here
            
            let obuType = (headerByte >> 3) & 0xF
            let extensionFlag = (headerByte >> 2) & 1
            let hasSizeField = (headerByte >> 1) & 1
            
            if extensionFlag == 1 {
                // We skip the extension byte if present
                if offset >= len { break }
                offset += 1
            }
            
            // 2. Parse OBU Size
            var obuSize = 0
            if hasSizeField == 1 {
                var value: Int = 0
                var leb128bytes = 0
                while offset < len {
                    let b = bytes[offset]
                    offset += 1
                    value |= (Int(b & 0x7F) << (leb128bytes * 7))
                    leb128bytes += 1
                    if (b & 0x80) == 0 { break }
                }
                obuSize = value
            } else {
                obuSize = len - offset
            }
            
            let payloadOffset = offset
            let nextOBU = payloadOffset + obuSize
            
            // 3. Check if this is the Sequence Header (OBU Type 1)
            if obuType == 1 {
                // Extract the raw OBU data (Header + Size + Payload) for the av1C box
                let obuData = data.subdata(in: startIndex..<nextOBU)
                
                // Parse the payload to get config details
                let reader = BitReader(data: bytes, offset: payloadOffset)
                
                // seq_profile (3)
                let seqProfile = reader.read(bits: 3)
                // still_picture (1)
                let stillPicture = reader.read(bits: 1)
                // reduced_still_picture_header (1)
                let reducedStillPictureHeader = reader.read(bits: 1)
                
                var seqLevelIdx0 = 0
                var seqTier0 = 0
                var highBitdepth = 0
                var twelveBit = 0
                var monochrome = 0
                var chromaSubsamplingX = 1
                var chromaSubsamplingY = 1
                var chromaSamplePosition = 0
                
                if reducedStillPictureHeader == 1 {
                    seqLevelIdx0 = reader.read(bits: 5)
                } else {
                    // timing_info_present_flag (1)
                    if reader.read(bits: 1) == 1 {
                        // num_units_in_display_tick (32)
                        _ = reader.read(bits: 32)
                        // time_scale (32)
                        _ = reader.read(bits: 32)
                        // equal_picture_interval (1)
                        if reader.read(bits: 1) == 1 {
                            // num_ticks_per_picture_minus_1 (uvlc)
                            _ = reader.readUVLC()
                        }
                        // decoder_model_info_present_flag (1)
                        if reader.read(bits: 1) == 1 {
                            // buffer_delay_length_minus_1 (5)
                            _ = reader.read(bits: 5)
                            // num_units_in_decoding_tick (32)
                            _ = reader.read(bits: 32)
                            // buffer_removal_time_length_minus_1 (5)
                            _ = reader.read(bits: 5)
                            // frame_presentation_time_length_minus_1 (5)
                            _ = reader.read(bits: 5)
                        }
                    }
                    
                    // initial_display_delay_present_flag (1)
                    if reader.read(bits: 1) == 1 {
                         // initial_display_delay_minus_1 (4)
                        _ = reader.read(bits: 4)
                    }
                    
                    // operating_points_cnt_minus_1 (5)
                    let operatingPointsCntMinus1 = reader.read(bits: 5)
                    
                    for _ in 0...operatingPointsCntMinus1 {
                        // operating_point_idc (12)
                        _ = reader.read(bits: 12)
                        // seq_level_idx (5)
                        let level = reader.read(bits: 5)
                        if level > 7 {
                            // seq_tier (1)
                            let tier = reader.read(bits: 1)
                            if seqTier0 == 0 { seqTier0 = tier }
                        }
                        if seqLevelIdx0 == 0 { seqLevelIdx0 = level }
                        // decoder_model_present_for_this_op (1) -> if true, reads more...
                        // We assume moonlight doesn't send complex decoder models in standard stream.
                        // Parsing skipped to keep simple, assuming standard stream.
                    }
                }
                
                // frame_width_bits_minus_1 (4)
                let frameWidthBits = reader.read(bits: 4) + 1
                // frame_height_bits_minus_1 (4)
                let frameHeightBits = reader.read(bits: 4) + 1
                // max_frame_width_minus_1 (frameWidthBits)
                _ = reader.read(bits: frameWidthBits)
                // max_frame_height_minus_1 (frameHeightBits)
                _ = reader.read(bits: frameHeightBits)
                
                // frame_id_numbers_present_flag (1)
                let frameIdNumbersPresent = reader.read(bits: 1)
                if frameIdNumbersPresent == 1 {
                    // delta_frame_id_length_minus_2 (4)
                    _ = reader.read(bits: 4)
                    // additional_frame_id_length_minus_1 (3)
                    _ = reader.read(bits: 3)
                }
                
                // use_128x128_superblock (1)
                _ = reader.read(bits: 1)
                // enable_filter_intra (1)
                _ = reader.read(bits: 1)
                // enable_intra_edge_filter (1)
                _ = reader.read(bits: 1)
                
                if reducedStillPictureHeader == 0 {
                    // enable_interintra_compound (1)
                    _ = reader.read(bits: 1)
                    // enable_masked_compound (1)
                    _ = reader.read(bits: 1)
                    // enable_warped_motion (1)
                    _ = reader.read(bits: 1)
                    // enable_dual_filter (1)
                    _ = reader.read(bits: 1)
                    // enable_order_hint (1)
                    let enableOrderHint = reader.read(bits: 1)
                    if enableOrderHint == 1 {
                        // enable_jnt_comp (1)
                        _ = reader.read(bits: 1)
                        // enable_ref_frame_mvs (1)
                        _ = reader.read(bits: 1)
                    }
                    
                    // seq_choose_screen_content_tools (1)
                    let seqChooseScreenContentTools = reader.read(bits: 1)
                    if seqChooseScreenContentTools == 0 {
                        // seq_force_screen_content_tools (1)
                        _ = reader.read(bits: 1)
                    }
                    
                    if seqChooseScreenContentTools > 0 {
                        // seq_choose_integer_mv (1)
                        _ = reader.read(bits: 1)
                    } else {
                        // seq_force_integer_mv (1)
                        _ = reader.read(bits: 1)
                    }
                    
                    if enableOrderHint == 1 {
                        // order_hint_bits_minus_1 (3)
                        _ = reader.read(bits: 3)
                    }
                }
                
                // enable_superres (1)
                _ = reader.read(bits: 1)
                // enable_cdef (1)
                _ = reader.read(bits: 1)
                // enable_restoration (1)
                _ = reader.read(bits: 1)
                
                // Color Config
                highBitdepth = reader.read(bits: 1)
                if seqProfile == 2 && highBitdepth == 1 {
                    twelveBit = reader.read(bits: 1)
                    monochrome = reader.read(bits: 1)
                } else {
                    twelveBit = 0
                    monochrome = 0
                }
                
                // BitDepth = 8 + (highBitdepth * 2) + (twelveBit * 2) -> 8, 10, 12
                
                if seqProfile == 1 {
                    monochrome = 0
                }
                
                if monochrome == 1 {
                    chromaSubsamplingX = 1
                    chromaSubsamplingY = 1
                } else {
                    if seqProfile == 0 && highBitdepth == 1 {
                        chromaSubsamplingX = 1
                        chromaSubsamplingY = 1
                    } else {
                        // color_primaries_original (1)
                        // transfer_characteristics_original (1)
                        // matrix_coefficients_original (1)
                        // We assume standard so we don't read full color description here to avoid complexity
                        
                        // Actually we MUST read subsampling to form valid av1C
                        // color_description_present_flag (1)
                        let colorDescriptionPresent = reader.read(bits: 1)
                        if colorDescriptionPresent == 1 {
                            // color_primaries (8)
                            _ = reader.read(bits: 8)
                            // transfer_characteristics (8)
                            _ = reader.read(bits: 8)
                            // matrix_coefficients (8)
                            _ = reader.read(bits: 8)
                        } else {
                            // defaults
                        }
                        
                        if monochrome == 1 {
                            // already set
                        } else if seqProfile == 0 && highBitdepth == 1 {
                             // 4:4:4 -> x=0, y=0? No profile 0 high is 4:2:0 10-bit usually.
                             // Actually Logic:
                             // if ( seq_profile == 0 )
                             //   subsampling_x = 1
                             //   subsampling_y = 1
                             chromaSubsamplingX = 1
                             chromaSubsamplingY = 1
                        } else if seqProfile == 1 {
                             chromaSubsamplingX = 0
                             chromaSubsamplingY = 0
                        } else {
                            if seqProfile == 2 {
                                if highBitdepth == 1 {
                                    if twelveBit == 1 {
                                        chromaSubsamplingX = reader.read(bits: 1)
                                        if chromaSubsamplingX == 1 {
                                            chromaSubsamplingY = reader.read(bits: 1)
                                        } else {
                                            chromaSubsamplingY = 0
                                        }
                                    } else {
                                        chromaSubsamplingX = 0
                                        chromaSubsamplingY = 0
                                    }
                                } else {
                                    chromaSubsamplingX = 0
                                    chromaSubsamplingY = 0
                                }
                            }
                        }
                        
                        if chromaSubsamplingX == 1 && chromaSubsamplingY == 1 {
                            chromaSamplePosition = reader.read(bits: 2)
                        }
                    }
                }
                
                // separate_uv_delta_q (1)
                _ = reader.read(bits: 1)
                
                let config = AV1Config(
                    seqProfile: seqProfile,
                    seqLevelIdx0: seqLevelIdx0,
                    seqTier0: seqTier0,
                    highBitdepth: highBitdepth,
                    twelveBit: twelveBit,
                    monochrome: monochrome,
                    chromaSubsamplingX: chromaSubsamplingX,
                    chromaSubsamplingY: chromaSubsamplingY,
                    chromaSamplePosition: chromaSamplePosition
                )
                
                return (obuData, config)
            }
            
            offset = nextOBU
        }
        
        return nil
    }
}

class BitReader {
    let data: [UInt8]
    var byteOffset: Int
    var bitOffset: Int
    
    init(data: [UInt8], offset: Int) {
        self.data = data
        self.byteOffset = offset
        self.bitOffset = 0
    }
    
    func read(bits: Int) -> Int {
        var value = 0
        for _ in 0..<bits {
            if byteOffset >= data.count { return 0 }
            let byte = data[byteOffset]
            let bit = (byte >> (7 - bitOffset)) & 1
            value = (value << 1) | Int(bit)
            
            bitOffset += 1
            if bitOffset == 8 {
                bitOffset = 0
                byteOffset += 1
            }
        }
        return value
    }
    
    func readUVLC() -> Int {
        var leadingZeros = 0
        while true {
            let bit = read(bits: 1)
            if bit == 1 { break }
            leadingZeros += 1
        }
        if leadingZeros >= 32 { return (1 << 32) - 1 }
        let value = read(bits: leadingZeros)
        return (1 << leadingZeros) - 1 + value
    }
}

// Example placeholder for your C struct
// struct DECODE_UNIT {
//    var frameType: Int32
//    var presentationTimeMs: Int64
// }

//// Example placeholder for C function
// @_silgen_name("DrSubmitDecodeUnit")
// func DrSubmitDecodeUnit(_ du: UnsafeMutablePointer<DECODE_UNIT>) -> Int32 {
//    // Replace with real logic
//    return 0
// }

// Example for HDR metadata
// struct SS_HDR_METADATA {
//    // Add your fields, e.g.:
//    var displayPrimaries: (vector_ushort2, vector_ushort2, vector_ushort2) = (.zero, .zero, .zero)
//    var whitePoint: vector_ushort2 = .zero
//    var minDisplayLuminance: UInt32 = 0
//    var maxDisplayLuminance: UInt32 = 0
//    var maxContentLightLevel: UInt16 = 0
//    var maxFrameAverageLightLevel: UInt16 = 0
// }

//// Example bridging
// @_silgen_name("LiGetHdrMetadata")
// func LiGetHdrMetadata(_ hdr: UnsafeMutablePointer<SS_HDR_METADATA>) -> Bool {
//    // Stub, return false for now
//    return false
// }
