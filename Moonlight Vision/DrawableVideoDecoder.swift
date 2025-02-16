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

let kCVImageBufferYCbCrMatrix_ITU_R_2020 = "ITU_R_2020" as CFString
let kCVImageBufferColorPrimaries_ITU_R_2020 = "ITU_R_2020" as CFString
let kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ = "SMPTE_ST_2084_PQ" as CFString

// MARK: - External C references (from bridging header)

// (In Swift, these can be called directly if included in a bridging header)
//
// extern bool LiPollNextVideoFrame(VIDEO_FRAME_HANDLE *handle, PDECODE_UNIT *du);
// extern void LiCompleteVideoFrame(VIDEO_FRAME_HANDLE handle, int decodeUnitResult);
// extern int LiGetPendingVideoFrames(void);
// extern void LiRequestIdrFrame(void);
//
// struct PDECODE_UNIT { ... };
// struct VIDEO_FRAME_HANDLE { ... };
// #define FRAME_TYPE_IDR ...
// #define BUFFER_TYPE_PICDATA ...
// etc.

// MARK: - VideoDecoderRenderer

@objc
class DrawableVideoDecoder: NSObject, AnyVideoDecoderRenderer {
    // MARK: - Properties

    private var callbacks: ConnectionCallbacks
    private var streamAspectRatio: Float
//    let callbackToRender: @MainActor (LowLevelTexture, (Int, Int)?) -> Void

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

    /// Our video format description, used when creating sample buffers
    private var formatDesc: CMVideoFormatDescription?

    /// Display link for pacing decode submissions
    private var displayLink: CADisplayLink?

    private let texture: TextureResource
    private var lowTexture: LowLevelTexture?
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

    private var renderPipelineState: MTLComputePipelineState?
    private var imagePlaneVertexBuffer: MTLBuffer?

    private var hdrEnabled: Bool

    private var hdrRenderer: HDRRenderer?

    private var copyPipelineState: MTLRenderPipelineState?
    private var copyPipelineFormat: MTLPixelFormat?

    // MARK: - Initialization

    init(
        texture: TextureResource,
        callbacks: ConnectionCallbacks,
        aspectRatio: Float,
        useFramePacing: Bool,
        enableHDR: Bool = false,
        callbackToRender: @MainActor @escaping (TextureResource.DrawableQueue, (Int, Int)?) -> Void
    ) {
        metalFormat = .rgba16Float

        // // Format setup based on HDR
        // decodingFormat = enableHDR ?
        //     kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange :
        //     kCVPixelFormatType_Lossless_32BGRA

        decodingFormat = kCVPixelFormatType_Lossless_32BGRA

        self.texture = texture
        self.callbacks = callbacks
        streamAspectRatio = aspectRatio
        framePacing = useFramePacing
        hdrEnabled = enableHDR
        self.callbackToRender = callbackToRender

        decoderCallback = VTDecompressionOutputCallbackRecord()
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

        super.init()
        decoderCallback.decompressionOutputRefCon = Unmanaged.passUnretained(self).toOpaque()

        // Create HDR renderer if needed - moved after super.init()
        if enableHDR {
            do {
                hdrRenderer = try HDRRenderer(device: mtlDevice)
            } catch {
                print("Failed to initialize HDR renderer: \(error)")
                // Fall back to SDR
                hdrEnabled = false
            }
        }
    }

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
            let drawable = try? drawableQueue?.nextDrawable(),
            let commandBuffer = commandQueue?.makeCommandBuffer(),
            let textureCache = textureCache
        else {
            print("ERROR")
            return
        }

        print("\n=== Decompression Output ===")
        printBufferAttributes(imageBuffer)

        guard
            let drawable = try? drawableQueue?.nextDrawable()
        else {
            print("ERROR")
            return
        }

        if let hdrRenderer = hdrRenderer {
            // Update metadata before processing frame
            updateHDRMetadata()

            // HDR path
            hdrRenderer.processFrame(
                sourceBuffer: imageBuffer,
                targetTexture: drawable.texture,
                commandQueue: commandQueue!
            )
        } else {
            // The copy pipeline relines on a fixed output pixel format,
            // so we have to make sure that matches the render target.
            if self.copyPipelineState == nil || copyPipelineFormat != metalFormat {
                self.copyPipelineState = buildCopyPipeline(metalFormat)
                if self.copyPipelineState != nil {
                    copyPipelineFormat = metalFormat
                }
            }
            guard let copyPipelineState = copyPipelineState else {
                print("Failed to set up copy render pipeline!")
                return
            }

            // Figure out the Metal pixel format
            let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
            let srcMetalFormats = CVMetalHelpers.getTextureTypesForFormat(pixelFormat)
            if srcMetalFormats[1] != MTLPixelFormat.invalid {
                print("TODO split planes")
                return
            }
            let srcMetalFormat = srcMetalFormats[0]

            // let numPlanes = CVPixelBufferGetPlaneCount(imageBuffer)
            //            print("Image with planes: \(planes)")
            var imageTexture: CVMetalTexture?
            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            let planeWidth = CVPixelBufferGetWidthOfPlane(imageBuffer, 0)
            let planeHeight = CVPixelBufferGetHeightOfPlane(imageBuffer, 0)

            if width != videoWidth || height != videoHeight {
                print("Got video frame with mismatching dimensions \(width)x\(height) (client texture dimensions \(videoWidth)x\(videoHeight)) - correcting")
                videoWidth = width
                videoHeight = height
                setupLowLevelTexture()
            }
            // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, imageBuffer, nil, srcMetalFormat /* bgra8Unorm */, planeWidth, planeHeight, 0, &imageTexture)
            if result != 0 {
                print("CVMetalTextureCacheCreateTextureFromImage \(result)")
                return
            }
            let mtlTexture = CVMetalTextureGetTexture(imageTexture!)!

            /*
             NSLog(mtlTexture.debugDescription!)
             if !((mtlTexture.debugDescription?.contains("decompressedPixelFormat") ?? true) || (mtlTexture.debugDescription?.contains("isCompressed = 1") ?? true)) {
                 NSLog("NO COMPRESSION ON VT FRAME!!!! AAAAAAAAA!! RIP BANDWIDTH!!")
             }
             */

            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store

            guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                fatalError("Failed to create render command encoder")
            }
            renderEncoder.setRenderPipelineState(copyPipelineState)
            renderEncoder.setFragmentTexture(mtlTexture, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            // I'm not sure why I can't encode these into the same command buffer to be honest
            // (Maybe I need a fence?)
            guard let commandBufferBlit = commandQueue?.makeCommandBuffer(),
                  let blits = commandBufferBlit.makeBlitCommandEncoder()
            else {
                print("ERROR")
                return
            }

            // blits.copy(from: mtlTexture, to: drawable.texture)
            blits.generateMipmaps(for: drawable.texture)
            blits.endEncoding()

            commandBufferBlit.commit()
            commandBufferBlit.waitUntilCompleted()
        }

        drawable.present()
    }

    func setupLowLevelTexture() {
        DispatchQueue.main.sync {
            if videoWidth == 0 || videoHeight == 0 {
                print("Tried to set up client texture without defined dimensions (\(videoWidth), \(videoHeight)) - skipping")
                return
            }

            self.drawableQueue = {
                let descriptor = TextureResource.DrawableQueue.Descriptor(
                    pixelFormat: metalFormat,
                    width: Int(videoWidth),
                    height: Int(videoHeight),
                    usage: [.renderTarget, .shaderRead, .shaderWrite], // .renderTarget only, so that we get framebuffer compression
                    mipmapsMode: .allocateAll // shinyquagsire23: Wasteful bc we probably only need like 2, but we don't have a choice here.
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

            self.lowTexture = try! LowLevelTexture(descriptor: {
                var desc = LowLevelTexture.Descriptor()

                desc.textureType = .type2D
                desc.arrayLength = 1

                desc.width = Int(videoWidth)
                desc.height = Int(videoHeight)
                desc.depth = 1

                desc.mipmapLevelCount = 1 // TODO(shinyquagsire23): Maybe 2?
                desc.pixelFormat = metalFormat // .rgba16Float //.rgba16Float // .rg8Unorm //.r8Unorm// .bgra8Unorm
                desc.textureUsage = [.renderTarget, .shaderRead, .shaderWrite] // .renderTarget only, so that we get framebuffer compression
                desc.swizzle = .init(red: .red, green: .green, blue: .blue, alpha: .alpha)

                return desc
            }())
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

        // Configure decoder with HDR settings if enabled
        if let formatDesc = formatDesc {
            let decoderConfiguration: [String: Any] = {
                var config: [String: Any] = [
                    kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
                ]

                if hdrEnabled {
                    config[kVTDecompressionPropertyKey_PixelTransferProperties as String] = [
                        kVTPixelTransferPropertyKey_DestinationColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                        kVTPixelTransferPropertyKey_DestinationTransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                        kVTPixelTransferPropertyKey_DestinationYCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
                    ]
                }

                return config
            }()

            VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDesc,
                decoderSpecification: decoderConfiguration as CFDictionary,
                imageBufferAttributes: textureAttributes as CFDictionary,
                outputCallback: &decoderCallback,
                decompressionSessionOut: &session
            )
        }

        // Rest of setup remains the same...
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
     *  Replaces the old `AVSampleBufferDisplayLayer` usage.
     *  Instead of enqueuing to a display layer, we create a `CMSampleBuffer`
     *  and forward it to your own rendering path (e.g., a Metal texture queue).
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
                // rgba16Float
                let videoDecoderSpecification: [NSString: AnyObject] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: kCFBooleanTrue]
                // NOTE(shinyquagsire23): Setting kCVPixelBufferPixelFormatTypeKey *at all* will trigger
                // a VideoToolbox bug that results in the output CVPixelBuffer's underlying Metal textures
                // being decompressed, resulting in GPU bandwidth penalties
                var attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferPoolMinimumBufferCountKey: 3]
                if !forceFastSecretTextureFormats {
                    attributes[kCVPixelBufferPixelFormatTypeKey] = decodingFormat
                }
                VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: formatDesc, decoderSpecification: videoDecoderSpecification as CFDictionary, imageBufferAttributes: attributes as CFDictionary, outputCallback: &decoderCallback, decompressionSessionOut: &session)
                AudioHelpers.fixAudioForSurroundForCurrentWindow() // TODO(shinyquagsire23): Make this configurable?
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
        // Ported logic from your createAV1FormatDescriptionForIDRFrame:
        // 1) Parse the bitstream with ff_cbs_* calls
        // 2) Build up an extension dictionary
        // 3) Make the format description
        // ...
        // This is just a skeleton that you'd fill with your ff_cbs usage
        // or any other approach to parse AV1 configuration.

        // For demonstration, we'll just return nil or a placeholder:
        // (In real code, you'd port your entire AV1 reading logic here.)
        guard let av1Extensions = buildAV1Extensions(for: frameData) else {
            return nil
        }

        var newDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_AV1,
            width: 1920, // You'd parse from the sequence header
            height: 1080,
            extensions: av1Extensions,
            formatDescriptionOut: &newDesc
        )
        if status != noErr {
            print("Failed to create AV1 format description: \(status)")
            return nil
        }
        return newDesc
    }

    /// Example placeholder building an AV1 extension dictionary
    private func buildAV1Extensions(for _: Data) -> CFDictionary? {
        var extensions: [CFString: Any] = [:]
        extensions[kCMFormatDescriptionExtension_FormatName] = "av01"
        // Add more color info if you parsed it from ff_cbs, etc.
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
            // AV1 or other codecs that don’t need rewriting
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
     *  Instead of using AVSampleBufferDisplayLayer, you would hand the sample buffer off
     *  to your rendering pipeline. For example:
     *  1) Create a CVPixelBuffer from the sample buffer
     *  2) Wrap it in a Metal texture (using `CVMetalTextureCacheCreateTextureFromImage`)
     *  3) Enqueue the texture in a command buffer or store in a GPU queue
     *
     *  This is a placeholder function for demonstration.
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
    // draw 4 vertices to copy the input texture to the output
    private func buildCopyPipeline(_ srcColorFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard
            let library = mtlDevice.makeDefaultLibrary()
        else {
            return nil
        }
        let vertexFunction = library.makeFunction(name: "copyVertexShader")
        let fragmentFunction = library.makeFunction(name: "copyFragmentShader")
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "CopyBlitPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = srcColorFormat
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
        pipelineDescriptor.maxVertexAmplificationCount = 1

        return try? mtlDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    // MARK: - METAL

    private func initializeRenderPipelineState() {
        guard
            let library = mtlDevice.makeDefaultLibrary()
        else {
            return
        }
        // Load a Metal compute kernel written in Metal Shading Language,
        // or abort if that fails.
        guard let library = mtlDevice.makeDefaultLibrary(),
              let function = library.makeFunction(name: "lowLevelTextureKernel"),
              let computePipelineState = try? mtlDevice.makeComputePipelineState(function: function)
        else {
            return
        }
        renderPipelineState = computePipelineState
    }

    private let planeVertexData: [Float] = [
        -1, -1, 0, 1,
        1, -1, 1, 1,
        -1, 1, 0, 0,
        1, 1, 1, 0,
    ]

    // Add new method to update HDR metadata
    private func updateHDRMetadata() {
        if let hdrRenderer = hdrRenderer {
            // Get HDR metadata from Moonlight
            var metadata = SS_HDR_METADATA()
            if LiGetHdrMetadata(&metadata) {
                hdrRenderer.updateMetadata(metadata)
            }
        }
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
