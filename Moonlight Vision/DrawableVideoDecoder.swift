//
//  PDECODE.swift
//  Moonlight
//
//  Created by tht7 on 30/12/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//


import Foundation
import AVFoundation
import QuartzCore  // For CADisplayLink
import UIKit       // If you still need UIColor, etc.
import SwiftUI
import RealityKit
import VideoToolbox
import Metal

// https://gist.github.com/shinyquagsire23/81c86f4bf670aaa68b5804080ff964a0
let MTLPixelFormatYCBCR8_420_2P_sRGB: UInt = 520
let MTLPixelFormatBGRA10_XR: UInt = 552
let FORMAT: [MTLPixelFormat] = [MTLPixelFormat.init(rawValue: MTLPixelFormatYCBCR8_420_2P_sRGB)!, MTLPixelFormat.invalid]

let metalFormat: MTLPixelFormat = .bgra8Unorm_srgb
/*kCVPixelFormatType_32BGRA , kCVPixelFormatType_420YpCbCr8BiPlanarFullRange*/
let decodingFormat = kCVPixelFormatType_Lossless_32BGRA
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

    /// If true, we’ll do pacing logic in displayLink
    private var framePacing: Bool = false

    /// Store parameter set data for H.264 / HEVC
    private var parameterSetBuffers: [Data] = []

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
    
    var session : VTDecompressionSession?
    var decoderCallback: VTDecompressionOutputCallbackRecord
    lazy var mtlDevice: MTLDevice = {
            guard let device = MTLCreateSystemDefaultDevice() else {
                fatalError()
            }
            return device
        }()
    
    private lazy var commandQueue: MTLCommandQueue? = {
            return mtlDevice.makeCommandQueue()
        }()
        
        private var renderPipelineState: MTLComputePipelineState?
        private var imagePlaneVertexBuffer: MTLBuffer?

    // MARK: - Initialization

    init(
        texture: TextureResource,
        callbacks: ConnectionCallbacks,
        aspectRatio: Float,
        useFramePacing: Bool,
//        callbackToRender: @MainActor @escaping (LowLevelTexture, (Int, Int)?) -> Void
        callbackToRender: @MainActor @escaping (TextureResource.DrawableQueue, (Int, Int)?) -> Void
    ) {
        self.texture = texture
        self.callbacks = callbacks
        self.streamAspectRatio = aspectRatio
        self.framePacing = useFramePacing
        self.callbackToRender = callbackToRender
        
        self.decoderCallback = VTDecompressionOutputCallbackRecord()
        self.decoderCallback.decompressionOutputCallback = { decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
            let mySelf = Unmanaged<DrawableVideoDecoder>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
            mySelf.decompressionOutputCallback(decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration)
        }
        
        super.init()
        self.decoderCallback.decompressionOutputRefCon = Unmanaged.passUnretained(self).toOpaque()
    }
    
    func decompressionOutputCallback(_ decompressionOutputRefCon: UnsafeMutableRawPointer?, _ sourceFrameRefCon: UnsafeMutableRawPointer?, _ status: OSStatus, _ infoFlags: VTDecodeInfoFlags, _ imageBuffer: CVImageBuffer?, _ presentationTimeStamp: CMTime, _ presentationDuration: CMTime) {
        guard
            let imageBuffer = imageBuffer,
            let drawable = try? self.drawableQueue?.nextDrawable(),
            let commandBuffer = commandQueue?.makeCommandBuffer(),
            var textureCache = self.textureCache,
            let blits = commandBuffer.makeBlitCommandEncoder() else {
            print("ERROR")
            return
        }
        var planes = CVPixelBufferGetPlaneCount(imageBuffer)
        //            print("Image with planes: \(planes)")
        var imageTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        if (width != videoWidth || height != videoHeight) {
            print("Got video frame with mismatching dimensions \(width)x\(height) (client texture dimensions \(videoWidth)x\(videoHeight)) - correcting")
            self.videoWidth = width
            self.videoHeight = height
            self.setupLowLevelTexture()
        }
        // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, imageBuffer, nil, metalFormat /*bgra8Unorm*/, width, height, 0, &imageTexture)
        let mtlTexture = CVMetalTextureGetTexture(imageTexture!)!
        
        blits.copy(from: mtlTexture, to: drawable.texture)
        blits.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        drawable.present()
    }
    
    func setupLowLevelTexture() {
        DispatchQueue.main.sync {
            if (videoWidth == 0 || videoHeight == 0) {
                print("Tried to set up client texture without defined dimensions (\(videoWidth), \(videoHeight)) - skipping")
                return
            }
            
            self.drawableQueue = {
                let descriptor = TextureResource.DrawableQueue.Descriptor(
                    pixelFormat: metalFormat,
                    width: Int(videoWidth),
                    height: Int(videoHeight),
                    usage: [.renderTarget, .shaderRead, .shaderWrite],
                    mipmapsMode: .none
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
                
                desc.mipmapLevelCount = 1
                desc.pixelFormat = metalFormat //.rgba16Float //.rgba16Float // .rg8Unorm //.r8Unorm// .bgra8Unorm
                desc.textureUsage = [.shaderRead, .shaderWrite, .renderTarget]
                desc.swizzle = .init(red: .red, green: .green, blue: .blue, alpha: .alpha)
                
                
                return desc
            }())
            self.callbackToRender(self.drawableQueue!, (videoWidth, videoHeight))
        }
    }

    /// Basic setup for the decoder
    func setup(withVideoFormat videoFormat: Int32, width videoWidth: Int32, height videoHeight: Int32, frameRate: Int32) {
//        DispatchQueue.main.sync {
            self.videoFormat = videoFormat
            self.frameRate = frameRate
            
            self.videoWidth = Int(videoWidth)
            self.videoHeight = Int(videoHeight)
            
            let res = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, self.mtlDevice, nil, &self.textureCache)//  == kCVReturnSuccess
            if (res != kCVReturnSuccess) {
                print("Creting Image cache failed \(res)")
            }
            
            
            
            setupLowLevelTexture()
//            texture.replace(withDrawables: self.drawableQueue!)
            
            let imagePlaneVertexDataCount = planeVertexData.count * MemoryLayout<Float>.size
            
            imagePlaneVertexBuffer = mtlDevice.makeBuffer(
                bytes: planeVertexData,
                length: imagePlaneVertexDataCount,
                options: []
            )
            
            self.initializeRenderPipelineState()
            // Width/height not specifically used in this example, but you can store them if needed
//        }
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
                    || bufferType == BUFFER_TYPE_PPS {

                    // Strip the NAL start and store it
                    var startLen = (dataPtr[2] == 0x01) ? 3 : 4
                    let newData = Data(bytes: dataPtr + startLen, count: Int(length) - startLen)
                    parameterSetBuffers.append(newData)
                }
                // Freed by someone else, presumably
                return DR_OK
            }

            // If we’re handling an IDR frame with actual picture data
            if let formatDesc = recreateFormatDescriptionForIDR(
                dataPtr: dataPtr, length: length
            ) {
                self.formatDesc = formatDesc
                // rgba16Float
                let attributes = [kCVPixelBufferPixelFormatTypeKey : decodingFormat /*kCVPixelFormatType_32BGRA , kCVPixelFormatType_420YpCbCr8BiPlanarFullRange*/] as CFDictionary
                VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: formatDesc, decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: &self.decoderCallback, decompressionSessionOut: &self.session)
            } else {
                // Couldn’t create format description yet
//                free(dataPtr)
                return DR_NEED_IDR
            }
        }

        guard let formatDesc = self.formatDesc else {
            // We don’t have our format yet
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
        VTDecompressionSessionDecodeFrame(self.session!, sampleBuffer: sampleBuffer, flags: [._EnableAsynchronousDecompression], frameRefcon: nil, infoFlagsOut: nil)
//        renderSampleBufferToDrawable(sampleBuffer)

        // If it’s an IDR, notify that video content is visible
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
            self.formatDesc = nil
        }

        // If it’s H.264 or HEVC, gather parameter sets
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

        for ps in parameterSetBuffers {
            ps.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
                paramPtrs.append(rawPtr.baseAddress!.assumingMemoryBound(to: UInt8.self))
                paramSizes.append(ps.count)
            }
        }

        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: parameterSetCount,
            parameterSetPointers: &paramPtrs,
            parameterSetSizes: &paramSizes,
            nalUnitHeaderLength: Int32(NAL_LENGTH_PREFIX_SIZE),
            formatDescriptionOut: &formatDesc
        )

        parameterSetBuffers.removeAll()

        if status != noErr {
            print("Failed to create H264 format description: \(status)")
            return nil
        }
        return formatDesc
    }

    /// Creates an HEVC `CMVideoFormatDescription` from the stored `parameterSetBuffers`.
    private func createHEVCFormatDescription() -> CMVideoFormatDescription? {
        let parameterSetCount = parameterSetBuffers.count
        var paramPtrs: [UnsafePointer<UInt8>] = []
        var paramSizes: [Int] = []

        for ps in parameterSetBuffers {
            let uint8Ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: ps.count)
            ps.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
                // This might be an extra memcpy shameeeeee
                uint8Ptr.initialize(from: rawPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), count: ps.count)
                paramPtrs.append(uint8Ptr)
                paramSizes.append(ps.count)
            }
        }

        // Prepare metadata dictionary
        var videoFormatParams: NSMutableDictionary = NSMutableDictionary()

        if let contentLightLevelInfo = contentLightLevelInfo {
            videoFormatParams.setObject(contentLightLevelInfo, forKey: kCMFormatDescriptionExtension_ContentLightLevelInfo as NSString)
//            videoFormatParams[kCMFormatDescriptionExtension_ContentLightLevelInfo] = contentLightLevelInfo
        }
        if let masteringDisplayColorVolume = masteringDisplayColorVolume {
//            videoFormatParams[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = masteringDisplayColorVolume
            videoFormatParams.setObject(masteringDisplayColorVolume, forKey: kCMFormatDescriptionExtension_MasteringDisplayColorVolume as NSString)
        }

        var formatDesc = UnsafeMutablePointer<CMFormatDescription?>.allocate(capacity: 1)
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: parameterSetCount,
            parameterSetPointers: UnsafePointer<UnsafePointer<UInt8>>(paramPtrs),
            parameterSetSizes: UnsafePointer<Int>(paramSizes),
            nalUnitHeaderLength: Int32(NAL_LENGTH_PREFIX_SIZE),
            extensions: videoFormatParams as CFDictionary,
            formatDescriptionOut: formatDesc
        )

        parameterSetBuffers.removeAll()
        _ = paramPtrs.map(UnsafePointer<UInt8>.deallocate)
        paramPtrs.removeAll()
        if status != noErr {
            print("Failed to create HEVC format description: \(status)")
            return nil
        }
        return formatDesc.pointee
    }

    /// Creates an AV1 `CMVideoFormatDescription` from the data for an IDR frame.
    private func createAV1FormatDescriptionForIDRFrame(_ frameData: Data) -> CMVideoFormatDescription? {
        // Ported logic from your createAV1FormatDescriptionForIDRFrame:
        // 1) Parse the bitstream with ff_cbs_* calls
        // 2) Build up an extension dictionary
        // 3) Make the format description
        // ...
        // This is just a skeleton that you’d fill with your ff_cbs usage
        // or any other approach to parse AV1 configuration.

        // For demonstration, we’ll just return nil or a placeholder:
        // (In real code, you’d port your entire AV1 reading logic here.)
        guard let av1Extensions = buildAV1Extensions(for: frameData) else {
            return nil
        }

        var newDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_AV1,
            width: 1920,  // You’d parse from the sequence header
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
    private func buildAV1Extensions(for frameData: Data) -> CFDictionary? {
        var extensions: [CFString: Any] = [:]
        extensions[kCMFormatDescriptionExtension_FormatName] = "av01"
        // Add more color info if you parsed it from ff_cbs, etc.
        return extensions as CFDictionary
    }

    // MARK: - Creating a Sample Buffer

    private func createSampleBuffer(
        dataPtr: UnsafeMutablePointer<UInt8>,
        length: Int,
        formatDesc: CMVideoFormatDescription,
        decodeUnit: PDECODE_UNIT!
    ) -> CMSampleBuffer? {

        // Create block buffer from data
        var dataBlockBuffer: CMBlockBuffer?
        let statusDataBlock = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: dataPtr,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &dataBlockBuffer
        )
        if statusDataBlock != kCMBlockBufferNoErr {
            print("CMBlockBufferCreateWithMemoryBlock failed: \(statusDataBlock)")
            return nil
        }
        // Now the CMBlockBuffer controls freeing `dataPtr`

        // Create an empty container block for rewriting AnnexB to length-delimited if needed
        var frameBlockBuffer: CMBlockBuffer?
        let statusFrameBlock = CMBlockBufferCreateEmpty(
            allocator: nil,
            capacity: 0,
            flags: 0,
            blockBufferOut: &frameBlockBuffer
        )
        if statusFrameBlock != kCMBlockBufferNoErr {
            print("CMBlockBufferCreateEmpty failed: \(statusFrameBlock)")
            return nil
        }

        // If H.264/HEVC, rewrite from AnnexB to length-delimited
        if (videoFormat & (VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265)) != 0 {
            rewriteAnnexBToLengthDelimited(
                frameBlockBuffer: frameBlockBuffer!,
                dataBlockBuffer: dataBlockBuffer!,
                totalLength: length
            )
        } else {
            // AV1 or other codecs that don’t need rewriting
            let statusRef = CMBlockBufferAppendBufferReference(
                frameBlockBuffer!,
                targetBBuf: dataBlockBuffer!,
                offsetToData: 0,
                dataLength: length,
                flags: 0
            )
            if statusRef != kCMBlockBufferNoErr {
                print("CMBlockBufferAppendBufferReference failed: \(statusRef)")
                return nil
            }
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

    /// Rewrites the given data from Annex-B format to length-delimited for H.264/HEVC
    private func rewriteAnnexBToLengthDelimited(
        frameBlockBuffer: CMBlockBuffer,
        dataBlockBuffer: CMBlockBuffer,
        totalLength: Int
    ) {
        // NALU start prefix size is 3 or 4 bytes. 
        // The code finds start codes, then appends length prefixes instead.
        let dataPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: totalLength)
        defer { dataPtr.deallocate() }

        // We read out the original data
        CMBlockBufferCopyDataBytes(dataBlockBuffer, atOffset: 0, dataLength: totalLength, destination: dataPtr)

        var lastOffset = -1
        for i in 0..<(totalLength - NALU_START_PREFIX_SIZE) {
            // Search for 00 00 01
            if dataPtr[i] == 0 && dataPtr[i+1] == 0 && dataPtr[i+2] == 1 {
                // Found a new NALU start
                if lastOffset != -1 {
                    updateAnnexBBuffer(
                        frameBlockBuffer: frameBlockBuffer,
                        dataBlockBuffer: dataBlockBuffer,
                        offset: lastOffset,
                        length: i - lastOffset
                    )
                }
                lastOffset = i
            }
        }

        if lastOffset != -1 {
            // Append the last chunk
            updateAnnexBBuffer(
                frameBlockBuffer: frameBlockBuffer,
                dataBlockBuffer: dataBlockBuffer,
                offset: lastOffset,
                length: totalLength - lastOffset
            )
        }
    }

    /// This function does the final rewriting step for each found NALU
    private func updateAnnexBBuffer(
        frameBlockBuffer: CMBlockBuffer,
        dataBlockBuffer: CMBlockBuffer,
        offset: Int,
        length: Int
    ) {
        // Insert the 4-byte length prefix instead of start code
        let oldOffset = CMBlockBufferGetDataLength(frameBlockBuffer)
        let statusAppend = CMBlockBufferAppendMemoryBlock(
            frameBlockBuffer,
            memoryBlock: nil,
            length: NAL_LENGTH_PREFIX_SIZE,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: NAL_LENGTH_PREFIX_SIZE,
            flags: 0
        )
        if statusAppend != noErr {
            print("CMBlockBufferAppendMemoryBlock failed: \(statusAppend)")
            return
        }

        // The new length (strip out the start code bytes)
        let dataLength = length - NALU_START_PREFIX_SIZE
        let lengthBytes: [UInt8] = [
            UInt8((dataLength >> 24) & 0xFF),
            UInt8((dataLength >> 16) & 0xFF),
            UInt8((dataLength >> 8) & 0xFF),
            UInt8(dataLength & 0xFF)
        ]

        let statusReplace = CMBlockBufferReplaceDataBytes(
            with: lengthBytes,
            blockBuffer: frameBlockBuffer,
            offsetIntoDestination: oldOffset,
            dataLength: NAL_LENGTH_PREFIX_SIZE
        )
        if statusReplace != noErr {
            print("CMBlockBufferReplaceDataBytes failed: \(statusReplace)")
            return
        }

        // Attach the data buffer by reference
        let statusRef = CMBlockBufferAppendBufferReference(
            frameBlockBuffer,
            targetBBuf: dataBlockBuffer,
            offsetToData: offset + NALU_START_PREFIX_SIZE,
            dataLength: dataLength,
            flags: 0
        )
        if statusRef != noErr {
            print("CMBlockBufferAppendBufferReference failed: \(statusRef)")
        }
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
        print("NOW DRAWING")
        let drawable = try! self.drawableQueue!.nextDrawable()
        
        
//        let isPlanar = CVPixelBufferIsPlanar(imageBuffer)
//            let width = isPlanar ? CVPixelBufferGetWidthOfPlane(imageBuffer, 0) : CVPixelBufferGetWidth(imageBuffer)
//            let height = isPlanar ? CVPixelBufferGetHeightOfPlane(imageBuffer, 0) : CVPixelBufferGetHeight(imageBuffer)
//
//            var cvMetalTexture: CVMetalTexture?
//            CVMetalTextureCacheCreateTextureFromImage(nil, _textureCache!, imageBuffer, nil, pixelFormat, width, height, 0, &cvMetalTexture)
//
//        guard let cvMetalTextureUnbound = cvMetalTexture else {
//                throw MyError.normal
//            }
//        let metalTexture = CVMetalTextureGetTexture(cvMetalTextureUnbound)!
//        
        drawable.texture.replace(region: .init(), mipmapLevel: 0, withBytes: &imageBuffer, bytesPerRow: CVPixelBufferGetBytesPerRow(imageBuffer))
        
        
    
        drawable.present()
        // Then do something like:
        // let pixelBuffer = imageBuffer as CVPixelBuffer
        // Convert pixelBuffer -> MTLTexture, etc.
        // drawableQueue.enqueue(texture)
        // ...
        // For now, just log it
        print("Render sample buffer to custom drawable pipeline")
    }

    // MARK: - HDR Mode

    func setHdrMode(_ enabled: Bool) {
        var hdrMetadata = SS_HDR_METADATA()
        let hasMetadata = enabled && LiGetHdrMetadata(&hdrMetadata)
        var metadataChanged = false

        // Mastering display color volume check
        if hasMetadata && hdrMetadata.displayPrimaries.0.x != 0 && hdrMetadata.maxDisplayLuminance != 0 {
            // Build the data the same way as the Objective-C code
            // ...
            // Compare to `masteringDisplayColorVolume`; if changed, update and set `metadataChanged = true`
        } else if masteringDisplayColorVolume != nil {
            masteringDisplayColorVolume = nil
            metadataChanged = true
        }

        // Content light level info check
        if hasMetadata && hdrMetadata.maxContentLightLevel != 0 && hdrMetadata.maxFrameAverageLightLevel != 0 {
            // Build `cll` structure, compare to `contentLightLevelInfo`
            // TODO
            /*
             struct {
                 uint16_t max_content_light_level;
                 uint16_t max_frame_average_light_level;
             } __attribute__((packed, aligned(2))) cll;

             cll.max_content_light_level = __builtin_bswap16(hdrMetadata.maxContentLightLevel);
             cll.max_frame_average_light_level = __builtin_bswap16(hdrMetadata.maxFrameAverageLightLevel);

             NSData* newCll = [NSData dataWithBytes:&cll length:sizeof(cll)];
             if (contentLightLevelInfo == nil || ![newCll isEqualToData:contentLightLevelInfo]) {
                 contentLightLevelInfo = newCll;
                 metadataChanged = YES;
             }
             */
            // ...
        } else if contentLightLevelInfo != nil {
            contentLightLevelInfo = nil
            metadataChanged = true
        }

        if metadataChanged {
            LiRequestIdrFrame()
        }
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
              let computePipelineState = try? mtlDevice.makeComputePipelineState(function: function) else {
            return
        }
        self.renderPipelineState = computePipelineState;
    }

        private let planeVertexData: [Float] = [
            -1, -1,  0,  1,
             1, -1,  1,  1,
             -1,  1,  0,  0,
             1,  1,  1,  0
        ]
}

// MARK: - Constants Port

private let NALU_START_PREFIX_SIZE: Int = 3
private let NAL_LENGTH_PREFIX_SIZE: Int = 4

// Example: In Objective-C, you had #define VIDEO_FORMAT_MASK_H264 ...
let VIDEO_FORMAT_H264: Int32         = 0x0001 // H.264 High Profile
let VIDEO_FORMAT_H265: Int32         = 0x0100 // HEVC Main Profile
let VIDEO_FORMAT_H265_MAIN10: Int32  = 0x0200 // HEVC Main10 Profile
let VIDEO_FORMAT_AV1_MAIN8: Int32    = 0x1000 // AV1 Main 8-bit profile
let VIDEO_FORMAT_AV1_MAIN10: Int32   = 0x2000 // AV1 Main 10-bit profile

// Masks for clients to use to match video codecs without profile-specific details.
let VIDEO_FORMAT_MASK_H264: Int32  = 0x000F
let VIDEO_FORMAT_MASK_H265: Int32  = 0x0F00
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
//struct DECODE_UNIT {
//    var frameType: Int32
//    var presentationTimeMs: Int64
//}

//// Example placeholder for C function
//@_silgen_name("DrSubmitDecodeUnit")
//func DrSubmitDecodeUnit(_ du: UnsafeMutablePointer<DECODE_UNIT>) -> Int32 {
//    // Replace with real logic
//    return 0
//}

// Example for HDR metadata
//struct SS_HDR_METADATA {
//    // Add your fields, e.g.:
//    var displayPrimaries: (vector_ushort2, vector_ushort2, vector_ushort2) = (.zero, .zero, .zero)
//    var whitePoint: vector_ushort2 = .zero
//    var minDisplayLuminance: UInt32 = 0
//    var maxDisplayLuminance: UInt32 = 0
//    var maxContentLightLevel: UInt16 = 0
//    var maxFrameAverageLightLevel: UInt16 = 0
//}

//// Example bridging
//@_silgen_name("LiGetHdrMetadata")
//func LiGetHdrMetadata(_ hdr: UnsafeMutablePointer<SS_HDR_METADATA>) -> Bool {
//    // Stub, return false for now
//    return false
//}
