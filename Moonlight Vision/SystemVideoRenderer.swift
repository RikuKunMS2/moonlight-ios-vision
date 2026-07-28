//
//  SystemVideoRenderer.swift
//  Moonlight Vision
//
//  A pull-mode video renderer that feeds compressed sample buffers straight into
//  AVSampleBufferVideoRenderer, the system media pipeline's sample-buffer sink.
//  Attached to a RealityKit VideoMaterial(videoRenderer:), this gives the curved
//  RealityKit screen the exact same decode + tone-mapping path as AVPlayer/the
//  UIKit AVSampleBufferDisplayLayer mode — including true HDR/EDR output, which
//  the Metal-texture path (DrawableVideoDecoder) cannot get: RealityKit exposes
//  no EDR API for custom textures and the compositor clamps them to ~1.2x SDR.
//
//  Trade-offs vs DrawableVideoDecoder: no Ambilight (no readable texture), no
//  custom color grading shader, no side-by-side 3D. The stream view falls back
//  to the Metal renderer when those features are requested.
//
//  Copyright © 2026 Moonlight Game Streaming Project. All rights reserved.
//

import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

final class SystemVideoRenderer: NSObject, AnyVideoDecoderRenderer {

    /// The sink handed to VideoMaterial(videoRenderer:).
    let sampleRenderer = AVSampleBufferVideoRenderer()

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let callbacks: ConnectionCallbacks
    private let onFirstFrame: (() -> Void)?

    private var videoFormat: Int32 = 0
    private var frameRate: Int32 = 60
    private var displayLink: CADisplayLink?

    private var parameterSetBuffers: [[UInt8]] = []
    private var formatDesc: CMVideoFormatDescription?
    private var masteringDisplayColorVolume: Data?
    private var contentLightLevelInfo: Data?
    private var firstFrameEmitted = false
    private var timelineAnchored = false
    private var enqueuedCount = 0

    init(callbacks: ConnectionCallbacks, onFirstFrame: (() -> Void)? = nil) {
        self.callbacks = callbacks
        self.onFirstFrame = onFirstFrame
        super.init()
        synchronizer.addRenderer(sampleRenderer)
    }

    // MARK: - AnyVideoDecoderRenderer

    func setup(withVideoFormat videoFormat: Int32, width videoWidth: Int32, height videoHeight: Int32, frameRate: Int32) {
        self.videoFormat = videoFormat
        self.frameRate = frameRate
        print("SystemVideoRenderer: setup format=\(String(format: "0x%04X", videoFormat)) \(videoWidth)x\(videoHeight)@\(frameRate)")
    }

    func start() {
        print("SystemVideoRenderer: start()")

        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkCallback(_:)))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(frameRate),
            maximum: Float(frameRate),
            preferred: Float(frameRate)
        )
        displayLink?.add(to: .main, forMode: .default)
    }

    func stop() {
        print("SystemVideoRenderer: stop()")
        displayLink?.invalidate()
        displayLink = nil
        synchronizer.setRate(0, time: .zero)
        sampleRenderer.flush()
        formatDesc = nil
        parameterSetBuffers.removeAll()
        masteringDisplayColorVolume = nil
        contentLightLevelInfo = nil
        firstFrameEmitted = false
        timelineAnchored = false
        enqueuedCount = 0
    }

    func setHdrMode(_ enabled: Bool) {
        let newMdcv = HDRParsingUtils.parseHDRDisplayMetadata(enabled)
        let newClli = HDRParsingUtils.parseHDRLightMetadata(enabled)
        let changed = (newMdcv != masteringDisplayColorVolume) || (newClli != contentLightLevelInfo)
        masteringDisplayColorVolume = newMdcv
        contentLightLevelInfo = newClli
        if changed {
            // Recreate the format description with the new metadata on the next IDR.
            LiRequestIdrFrame()
        }
    }

    // MARK: - Frame pump (pull-mode renderer, same pattern as DrawableVideoDecoder)

    @objc private func displayLinkCallback(_: CADisplayLink) {
        var handle: VIDEO_FRAME_HANDLE?
        var du: PDECODE_UNIT?
        while LiPollNextVideoFrame(&handle, &du) {
            guard let handle = handle, let du = du else { continue }
            LiCompleteVideoFrame(handle, DrSubmitDecodeUnit(du))
        }
    }

    // MARK: - Decode buffer submission

    @discardableResult
    @objc(submitDecodeBuffer:length:bufferType:decodeUnit:)
    func submitDecodeBuffer(
        _ dataPtr: UnsafeMutablePointer<UInt8>!,
        length: Int32,
        bufferType: Int32,
        decode decodeUnit: PDECODE_UNIT!
    ) -> Int32 {
        if decodeUnit.pointee.frameType == FRAME_TYPE_IDR {
            if bufferType != BUFFER_TYPE_PICDATA {
                if bufferType == BUFFER_TYPE_VPS || bufferType == BUFFER_TYPE_SPS || bufferType == BUFFER_TYPE_PPS {
                    let startLen = (dataPtr[2] == 0x01) ? 3 : 4
                    parameterSetBuffers.append([UInt8](Data(bytes: dataPtr + startLen, count: Int(length) - startLen)))
                }
                return DR_OK
            }

            guard let newDesc = recreateFormatDescriptionForIDR(dataPtr: dataPtr, length: length) else {
                return DR_NEED_IDR
            }
            formatDesc = newDesc
            AudioHelpers.fixAudioForSurroundForCurrentWindow()
        }

        guard let formatDesc = formatDesc else {
            return DR_NEED_IDR
        }

        if sampleRenderer.status == .failed || sampleRenderer.requiresFlushToResumeDecoding {
            print("SystemVideoRenderer: renderer failed (\(String(describing: sampleRenderer.error))), flushing")
            sampleRenderer.flush()
            free(dataPtr)
            return DR_NEED_IDR
        }

        // createSampleBuffer takes ownership of dataPtr in every outcome:
        // transferred to the CMBlockBuffer on success, freed internally on failure.
        guard let sampleBuffer = createSampleBuffer(
            dataPtr: dataPtr, length: Int(length), formatDesc: formatDesc, decodeUnit: decodeUnit
        ) else {
            return DR_NEED_IDR
        }

        // Bypass the synchronizer timeline: game streaming wants every frame on
        // screen as soon as it is decoded. Use the CF API directly — a Swift
        // conditional cast of the CFArray can fail silently.
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachmentsArray) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        // Anchor the synchronizer timebase to the stream's PTS domain on the first
        // sample, so playback also works if DisplayImmediately is not honored.
        if !timelineAnchored {
            timelineAnchored = true
            synchronizer.setRate(1.0, time: CMTimeMake(value: Int64(decodeUnit.pointee.presentationTimeMs), timescale: 1000))
        }

        sampleRenderer.enqueue(sampleBuffer)

        enqueuedCount += 1
        if enqueuedCount == 1 || enqueuedCount % 300 == 0 {
            print("SystemVideoRenderer: enqueued=\(enqueuedCount) status=\(sampleRenderer.status.rawValue) error=\(String(describing: sampleRenderer.error)) rate=\(synchronizer.rate)")
        }

        if decodeUnit.pointee.frameType == FRAME_TYPE_IDR && !firstFrameEmitted {
            firstFrameEmitted = true
            callbacks.videoContentShown()
            if let onFirstFrame = onFirstFrame {
                DispatchQueue.main.async { onFirstFrame() }
            }
        }

        return DR_OK
    }

    // MARK: - Format descriptions
    // Mirrors the UIKit AVSampleBufferDisplayLayer path: parameter sets carry the
    // colorimetry (VUI / sequence header), we only add HDR mastering metadata.

    private func recreateFormatDescriptionForIDR(dataPtr: UnsafeMutablePointer<UInt8>, length: Int32) -> CMVideoFormatDescription? {
        formatDesc = nil
        defer { parameterSetBuffers.removeAll() }

        if (videoFormat & VIDEO_FORMAT_MASK_H264) != 0 {
            return createParameterSetFormatDescription(hevc: false)
        } else if (videoFormat & VIDEO_FORMAT_MASK_H265) != 0 {
            return createParameterSetFormatDescription(hevc: true)
        } else if (videoFormat & VIDEO_FORMAT_MASK_AV1) != 0 {
            let frameData = Data(bytes: dataPtr, count: Int(length))
            return AV1FormatDescriptionBridge.formatDescription(
                fromIDRFrame: frameData,
                masteringDisplayColorVolume: masteringDisplayColorVolume,
                contentLightLevelInfo: contentLightLevelInfo
            )
        }
        return nil
    }

    private func createParameterSetFormatDescription(hevc: Bool) -> CMVideoFormatDescription? {
        guard !parameterSetBuffers.isEmpty else { return nil }
        var paramPtrs: [UnsafePointer<UInt8>] = []
        var paramSizes: [Int] = []
        for index in parameterSetBuffers.indices {
            paramPtrs.append(UnsafePointer<UInt8>(parameterSetBuffers[index]))
            paramSizes.append(parameterSetBuffers[index].count)
        }

        var desc: CMFormatDescription?
        let status: OSStatus
        if hevc {
            let extensions = NSMutableDictionary()
            if let mdcv = masteringDisplayColorVolume {
                extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as NSString] = mdcv as NSData
            }
            if let clli = contentLightLevelInfo {
                extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as NSString] = clli as NSData
            }
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSetBuffers.count,
                parameterSetPointers: paramPtrs,
                parameterSetSizes: paramSizes,
                nalUnitHeaderLength: 4,
                extensions: extensions as CFDictionary,
                formatDescriptionOut: &desc
            )
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSetBuffers.count,
                parameterSetPointers: paramPtrs,
                parameterSetSizes: paramSizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &desc
            )
        }
        if status != noErr {
            print("SystemVideoRenderer: format description creation failed: \(status)")
            return nil
        }
        return desc
    }

    // MARK: - Sample buffers (Annex B fixup identical to DrawableVideoDecoder)

    private func createSampleBuffer(
        dataPtr: UnsafeMutablePointer<UInt8>,
        length: Int,
        formatDesc: CMVideoFormatDescription,
        decodeUnit: PDECODE_UNIT!
    ) -> CMSampleBuffer? {
        var frameBlockBuffer: CMBlockBuffer?

        if (videoFormat & (VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265)) != 0 {
            let nals = UnsafeMutableBufferPointer<UInt8>(start: dataPtr, count: length)
            frameBlockBuffer = annexBToLengthPrefixed(buffer: nals)
        } else {
            let status = CMBlockBufferCreateWithMemoryBlock(
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
            if status != kCMBlockBufferNoErr {
                print("SystemVideoRenderer: CMBlockBufferCreateWithMemoryBlock failed: \(status)")
                free(dataPtr)
                return nil
            }
        }

        guard frameBlockBuffer != nil else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleTiming = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTimeMake(value: Int64(decodeUnit.pointee.presentationTimeMs), timescale: 1000),
            decodeTimeStamp: .invalid
        )
        let status = CMSampleBufferCreateReady(
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
        if status != noErr {
            print("SystemVideoRenderer: CMSampleBufferCreateReady failed: \(status)")
            return nil
        }
        return sampleBuffer
    }

    private struct NaluIndex {
        var startOffset: Int
        var payloadStartOffset: Int
        var payloadSize: Int
        var threeByteHeader: Bool
    }

    /// Rewrites Annex-B start codes into 4-byte big-endian length prefixes.
    /// In-place when every start code is 4 bytes; otherwise falls back to a copy.
    private func annexBToLengthPrefixed(buffer: UnsafeMutableBufferPointer<UInt8>) -> CMBlockBuffer? {
        let (naluIndices, modifyInPlace) = findNaluIndices(bufferBounded: buffer)
        guard !naluIndices.isEmpty else {
            buffer.deallocate()
            return nil
        }

        if modifyInPlace {
            var offset = 0
            let raw = UnsafeMutableRawBufferPointer(start: buffer.baseAddress, count: buffer.count)
            guard let blockBuffer = try? CMBlockBuffer(buffer: raw, deallocator: { _, _ in buffer.deallocate() }, flags: .assureMemoryNow) else {
                buffer.deallocate()
                return nil
            }
            let pointer = buffer.baseAddress!
            for index in naluIndices {
                pointer.advanced(by: offset + 0).pointee = UInt8((index.payloadSize >> 24) & 0xFF)
                pointer.advanced(by: offset + 1).pointee = UInt8((index.payloadSize >> 16) & 0xFF)
                pointer.advanced(by: offset + 2).pointee = UInt8((index.payloadSize >> 8) & 0xFF)
                pointer.advanced(by: offset + 3).pointee = UInt8(index.payloadSize & 0xFF)
                offset += 4 + index.payloadSize
            }
            return blockBuffer
        }

        defer { buffer.deallocate() }
        let blockLength = naluIndices.reduce(0) { $0 + 4 + $1.payloadSize }
        guard let blockBuffer = try? CMBlockBuffer(length: blockLength, flags: .assureMemoryNow) else {
            return nil
        }
        var contiguous: CMBlockBuffer! = blockBuffer
        if !CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: 0) {
            var created: CMBlockBuffer?
            guard CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: blockBuffer, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &created) == noErr, created != nil else {
                return nil
            }
            contiguous = created
        }
        var totalLength = 0
        var rawPtr: UnsafeMutablePointer<Int8>!
        guard CMBlockBufferGetDataPointer(contiguous, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &rawPtr) == noErr else {
            return nil
        }
        let dst = UnsafeMutableRawPointer(rawPtr).assumingMemoryBound(to: UInt8.self)
        let src = buffer.baseAddress!
        var offset = 0
        for index in naluIndices {
            dst.advanced(by: offset + 0).pointee = UInt8((index.payloadSize >> 24) & 0xFF)
            dst.advanced(by: offset + 1).pointee = UInt8((index.payloadSize >> 16) & 0xFF)
            dst.advanced(by: offset + 2).pointee = UInt8((index.payloadSize >> 8) & 0xFF)
            dst.advanced(by: offset + 3).pointee = UInt8(index.payloadSize & 0xFF)
            offset += 4
            dst.advanced(by: offset).update(from: src.advanced(by: index.payloadStartOffset), count: index.payloadSize)
            offset += index.payloadSize
        }
        return contiguous
    }

    private func findNaluIndices(bufferBounded: UnsafeMutableBufferPointer<UInt8>) -> ([NaluIndex], Bool) {
        var eligibleForModifyInPlace = true
        guard bufferBounded.count >= 3 else { return ([], false) }

        var sequences = [NaluIndex]()
        let end = bufferBounded.count - 3
        var i = 0
        let buffer = Data(bytesNoCopy: bufferBounded.baseAddress!, count: bufferBounded.count, deallocator: .none)
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
                        eligibleForModifyInPlace = false
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
        return (sequences, eligibleForModifyInPlace)
    }
}
