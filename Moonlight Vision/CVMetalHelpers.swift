//
//  CVMetalHelpers.swift
//
//  Created by Max Thomas
//  No license, do whatever you want with this file
//


#if !targetEnvironment(simulator)
let forceFastSecretTextureFormats = true
#else
let forceFastSecretTextureFormats = false
#endif

//
// Non-conclusive list of interesting private Metal pixel formats
// https://gist.github.com/shinyquagsire23/81c86f4bf670aaa68b5804080ff964a0
//
let MTLPixelFormatYCBCR8_420_2P: UInt = 500
let MTLPixelFormatYCBCR8_422_1P: UInt = 501
let MTLPixelFormatYCBCR8_422_2P: UInt = 502
let MTLPixelFormatYCBCR8_444_2P: UInt = 503
let MTLPixelFormatYCBCR10_444_1P: UInt = 504
let MTLPixelFormatYCBCR10_420_2P: UInt = 505
let MTLPixelFormatYCBCR10_422_2P: UInt = 506
let MTLPixelFormatYCBCR10_444_2P: UInt = 507
let MTLPixelFormatYCBCR10_420_2P_PACKED: UInt = 508
let MTLPixelFormatYCBCR10_422_2P_PACKED: UInt = 509
let MTLPixelFormatYCBCR10_444_2P_PACKED: UInt = 510

let MTLPixelFormatYCBCR8_420_2P_sRGB: UInt = 520
let MTLPixelFormatYCBCR8_422_1P_sRGB: UInt = 521
let MTLPixelFormatYCBCR8_422_2P_sRGB: UInt = 522
let MTLPixelFormatYCBCR8_444_2P_sRGB: UInt = 523
let MTLPixelFormatYCBCR10_444_1P_sRGB: UInt = 524
let MTLPixelFormatYCBCR10_420_2P_sRGB: UInt = 525
let MTLPixelFormatYCBCR10_422_2P_sRGB: UInt = 526
let MTLPixelFormatYCBCR10_444_2P_sRGB: UInt = 527
let MTLPixelFormatYCBCR10_420_2P_PACKED_sRGB: UInt = 528
let MTLPixelFormatYCBCR10_422_2P_PACKED_sRGB: UInt = 529
let MTLPixelFormatYCBCR10_444_2P_PACKED_sRGB: UInt = 530

let MTLPixelFormatRGB8_420_2P: UInt = 540
let MTLPixelFormatRGB8_422_2P: UInt = 541
let MTLPixelFormatRGB8_444_2P: UInt = 542
let MTLPixelFormatRGB10_420_2P: UInt = 543
let MTLPixelFormatRGB10_422_2P: UInt = 544
let MTLPixelFormatRGB10_444_2P: UInt = 545
let MTLPixelFormatRGB10_420_2P_PACKED: UInt = 546
let MTLPixelFormatRGB10_422_2P_PACKED: UInt = 547
let MTLPixelFormatRGB10_444_2P_PACKED: UInt = 548

let MTLPixelFormatRGB10A8_2P_XR10: UInt = 550
let MTLPixelFormatRGB10A8_2P_XR10_sRGB: UInt = 551
let MTLPixelFormatBGRA10_XR: UInt = 552
let MTLPixelFormatBGRA10_XR_sRGB: UInt = 553
let MTLPixelFormatBGR10_XR: UInt = 554
let MTLPixelFormatBGR10_XR_sRGB: UInt = 555
let MTLPixelFormatRGBA16Float_XR: UInt = 556

let MTLPixelFormatYCBCRA8_444_1P: UInt = 560

let MTLPixelFormatYCBCR12_420_2P: UInt = 570
let MTLPixelFormatYCBCR12_422_2P: UInt = 571
let MTLPixelFormatYCBCR12_444_2P: UInt = 572
let MTLPixelFormatYCBCR12_420_2P_PQ: UInt = 573
let MTLPixelFormatYCBCR12_422_2P_PQ: UInt = 574
let MTLPixelFormatYCBCR12_444_2P_PQ: UInt = 575
let MTLPixelFormatR10Unorm_X6: UInt = 576
let MTLPixelFormatR10Unorm_X6_sRGB: UInt = 577
let MTLPixelFormatRG10Unorm_X12: UInt = 578
let MTLPixelFormatRG10Unorm_X12_sRGB: UInt = 579
let MTLPixelFormatYCBCR12_420_2P_PACKED: UInt = 580
let MTLPixelFormatYCBCR12_422_2P_PACKED: UInt = 581
let MTLPixelFormatYCBCR12_444_2P_PACKED: UInt = 582
let MTLPixelFormatYCBCR12_420_2P_PACKED_PQ: UInt = 583
let MTLPixelFormatYCBCR12_422_2P_PACKED_PQ: UInt = 584
let MTLPixelFormatYCBCR12_444_2P_PACKED_PQ: UInt = 585
let MTLPixelFormatRGB10A2Unorm_sRGB: UInt = 586
let MTLPixelFormatRGB10A2Unorm_PQ: UInt = 587
let MTLPixelFormatR10Unorm_PACKED: UInt = 588
let MTLPixelFormatRG10Unorm_PACKED: UInt = 589
let MTLPixelFormatYCBCR10_444_1P_XR: UInt = 590
let MTLPixelFormatYCBCR10_420_2P_XR: UInt = 591
let MTLPixelFormatYCBCR10_422_2P_XR: UInt = 592
let MTLPixelFormatYCBCR10_444_2P_XR: UInt = 593
let MTLPixelFormatYCBCR10_420_2P_PACKED_XR: UInt = 594
let MTLPixelFormatYCBCR10_422_2P_PACKED_XR: UInt = 595
let MTLPixelFormatYCBCR10_444_2P_PACKED_XR: UInt = 596
let MTLPixelFormatYCBCR12_420_2P_XR: UInt = 597
let MTLPixelFormatYCBCR12_422_2P_XR: UInt = 598
let MTLPixelFormatYCBCR12_444_2P_XR: UInt = 599
let MTLPixelFormatYCBCR12_420_2P_PACKED_XR: UInt = 600
let MTLPixelFormatYCBCR12_422_2P_PACKED_XR: UInt = 601
let MTLPixelFormatYCBCR12_444_2P_PACKED_XR: UInt = 602
let MTLPixelFormatR12Unorm_X4: UInt = 603
let MTLPixelFormatR12Unorm_X4_PQ: UInt = 604
let MTLPixelFormatRG12Unorm_X8: UInt = 605
let MTLPixelFormatR10Unorm_X6_PQ: UInt = 606
//
// end Metal pixel formats
//

// https://github.com/WebKit/WebKit/blob/f86d3400c875519b3f3c368f1ea9a37ed8a1d11b/Source/WebGPU/WebGPU/BindGroup.mm#L43
let kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange = 0x70663230 as OSType // pf20
let kCVPixelFormatType_422YpCbCr10PackedBiPlanarFullRange = 0x70663232 as OSType // pf22
let kCVPixelFormatType_444YpCbCr10PackedBiPlanarFullRange = 0x70663434 as OSType // pf44

let kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange = 0x70343230 as OSType // p420
let kCVPixelFormatType_422YpCbCr10PackedBiPlanarVideoRange = 0x70343232 as OSType // p422
let kCVPixelFormatType_444YpCbCr10PackedBiPlanarVideoRange = 0x70343434 as OSType // p444

// Apparently kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange is known as kCVPixelFormatType_AGX_420YpCbCr8BiPlanarVideoRange in WebKit.

// Other formats Apple forgot
let kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarFullRange = 0x2D786630 as OSType // -xf0
let kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarFullRange = 0x26786632 as OSType // &xf2
let kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarFullRange = 0x2D786632 as OSType // -xf2
let kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange_compat = 0x26786630 as OSType // &xf0

class CVMetalHelpers {
    // Useful for debugging.
    static let coreVideoPixelFormatToStr: [OSType:String] = [
        kCVPixelFormatType_128RGBAFloat: "128RGBAFloat",
        kCVPixelFormatType_14Bayer_BGGR: "BGGR",
        kCVPixelFormatType_14Bayer_GBRG: "GBRG",
        kCVPixelFormatType_14Bayer_GRBG: "GRBG",
        kCVPixelFormatType_14Bayer_RGGB: "RGGB",
        kCVPixelFormatType_16BE555: "16BE555",
        kCVPixelFormatType_16BE565: "16BE565",
        kCVPixelFormatType_16Gray: "16Gray",
        kCVPixelFormatType_16LE5551: "16LE5551",
        kCVPixelFormatType_16LE555: "16LE555",
        kCVPixelFormatType_16LE565: "16LE565",
        kCVPixelFormatType_16VersatileBayer: "16VersatileBayer",
        kCVPixelFormatType_1IndexedGray_WhiteIsZero: "WhiteIsZero",
        kCVPixelFormatType_1Monochrome: "1Monochrome",
        kCVPixelFormatType_24BGR: "24BGR",
        kCVPixelFormatType_24RGB: "24RGB",
        kCVPixelFormatType_2Indexed: "2Indexed",
        kCVPixelFormatType_2IndexedGray_WhiteIsZero: "WhiteIsZero",
        kCVPixelFormatType_30RGB: "30RGB",
        kCVPixelFormatType_30RGBLEPackedWideGamut: "30RGBLEPackedWideGamut",
        kCVPixelFormatType_32ABGR: "32ABGR",
        kCVPixelFormatType_32ARGB: "32ARGB",
        kCVPixelFormatType_32AlphaGray: "32AlphaGray",
        kCVPixelFormatType_32BGRA: "32BGRA",
        kCVPixelFormatType_32RGBA: "32RGBA",
        kCVPixelFormatType_40ARGBLEWideGamut: "40ARGBLEWideGamut",
        kCVPixelFormatType_40ARGBLEWideGamutPremultiplied: "40ARGBLEWideGamutPremultiplied",
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: "420YpCbCr10BiPlanarFullRange",
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: "420YpCbCr10BiPlanarVideoRange",
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: "420YpCbCr8BiPlanarFullRange",
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: "420YpCbCr8BiPlanarVideoRange",
        kCVPixelFormatType_420YpCbCr8Planar: "420YpCbCr8Planar",
        kCVPixelFormatType_420YpCbCr8PlanarFullRange: "420YpCbCr8PlanarFullRange",
        kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar: "TriPlanar",
        kCVPixelFormatType_422YpCbCr10: "422YpCbCr10",
        kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: "422YpCbCr10BiPlanarFullRange",
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: "422YpCbCr10BiPlanarVideoRange",
        kCVPixelFormatType_422YpCbCr16: "422YpCbCr16",
        kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange: "422YpCbCr16BiPlanarVideoRange",
        kCVPixelFormatType_422YpCbCr8: "422YpCbCr8",
        kCVPixelFormatType_422YpCbCr8BiPlanarFullRange: "422YpCbCr8BiPlanarFullRange",
        kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange: "422YpCbCr8BiPlanarVideoRange",
        kCVPixelFormatType_422YpCbCr8FullRange: "422YpCbCr8FullRange",
        kCVPixelFormatType_422YpCbCr8_yuvs: "yuvs",
        kCVPixelFormatType_422YpCbCr_4A_8BiPlanar: "8BiPlanar",
        kCVPixelFormatType_4444AYpCbCr16: "4444AYpCbCr16",
        kCVPixelFormatType_4444AYpCbCr8: "4444AYpCbCr8",
        kCVPixelFormatType_4444YpCbCrA8: "4444YpCbCrA8",
        kCVPixelFormatType_4444YpCbCrA8R: "4444YpCbCrA8R",
        kCVPixelFormatType_444YpCbCr10: "444YpCbCr10",
        kCVPixelFormatType_444YpCbCr10BiPlanarFullRange: "444YpCbCr10BiPlanarFullRange",
        kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: "444YpCbCr10BiPlanarVideoRange",
        kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange: "444YpCbCr16BiPlanarVideoRange",
        kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar: "TriPlanar",
        kCVPixelFormatType_444YpCbCr8: "444YpCbCr8",
        kCVPixelFormatType_444YpCbCr8BiPlanarFullRange: "444YpCbCr8BiPlanarFullRange",
        kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange: "444YpCbCr8BiPlanarVideoRange",
        kCVPixelFormatType_48RGB: "48RGB",
        kCVPixelFormatType_4Indexed: "4Indexed",
        kCVPixelFormatType_4IndexedGray_WhiteIsZero: "WhiteIsZero",
        kCVPixelFormatType_64ARGB: "64ARGB",
        kCVPixelFormatType_64RGBAHalf: "64RGBAHalf",
        kCVPixelFormatType_64RGBALE: "64RGBALE",
        kCVPixelFormatType_64RGBA_DownscaledProResRAW: "DownscaledProResRAW",
        kCVPixelFormatType_8Indexed: "8Indexed",
        kCVPixelFormatType_8IndexedGray_WhiteIsZero: "WhiteIsZero",
        kCVPixelFormatType_ARGB2101010LEPacked: "ARGB2101010LEPacked",
        kCVPixelFormatType_DepthFloat16: "DepthFloat16",
        kCVPixelFormatType_DepthFloat32: "DepthFloat32",
        kCVPixelFormatType_DisparityFloat16: "DisparityFloat16",
        kCVPixelFormatType_DisparityFloat32: "DisparityFloat32",
        kCVPixelFormatType_Lossless_32BGRA: "32BGRA",
        kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange_compat: "Lossless_420YpCbCr10PackedBiPlanarFullRange",
        kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange: "Lossless_420YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange: "Lossless_420YpCbCr8BiPlanarFullRange",
        kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange: "Lossless_420YpCbCr8BiPlanarVideoRange",
        kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange: "Lossless_422YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarFullRange: "Lossless_422YpCbCr10PackedBiPlanarFullRange",
        kCVPixelFormatType_Lossy_32BGRA: "32BGRA",
        kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarFullRange: "Lossy_420YpCbCr10PackedBiPlanarFullRange",
        kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange: "Lossy_420YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange: "Lossy_420YpCbCr8BiPlanarFullRange",
        kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange: "Lossy_420YpCbCr8BiPlanarVideoRange",
        kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarFullRange: "Lossy_422YpCbCr10PackedBiPlanarFullRange",
        kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange: "Lossy_422YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_OneComponent10: "OneComponent10",
        kCVPixelFormatType_OneComponent12: "OneComponent12",
        kCVPixelFormatType_OneComponent16: "OneComponent16",
        kCVPixelFormatType_OneComponent16Half: "OneComponent16Half",
        kCVPixelFormatType_OneComponent32Float: "OneComponent32Float",
        kCVPixelFormatType_OneComponent8: "OneComponent8",
        kCVPixelFormatType_TwoComponent16: "TwoComponent16",
        kCVPixelFormatType_TwoComponent16Half: "TwoComponent16Half",
        kCVPixelFormatType_TwoComponent32Float: "TwoComponent32Float",
        kCVPixelFormatType_TwoComponent8: "TwoComponent8",
        
        kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange: "420YpCbCr10PackedBiPlanarFullRange",
        kCVPixelFormatType_422YpCbCr10PackedBiPlanarFullRange: "kCVPixelFormatType_422YpCbCr10PackedBiPlanarFullRange",
        kCVPixelFormatType_444YpCbCr10PackedBiPlanarFullRange: "kCVPixelFormatType_444YpCbCr10PackedBiPlanarFullRange",
        kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange: "kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_422YpCbCr10PackedBiPlanarVideoRange: "kCVPixelFormatType_422YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_444YpCbCr10PackedBiPlanarVideoRange: "kCVPixelFormatType_444YpCbCr10PackedBiPlanarVideoRange",
        
        // Internal formats?
        0x61766331: "NonDescriptH264",
        0x68766331: "NonDescriptHVC1"
    ]
    
    // Get bits per component for video format
    static func getBpcForVideoFormat(_ videoFormat: CMFormatDescription) -> Int {
        let bpcRaw = videoFormat.extensions["BitsPerComponent" as CFString]
        return (bpcRaw != nil ? bpcRaw as! NSNumber : 8).intValue
    }
    
    // Returns true if video format is full-range
    static func getIsFullRangeForVideoFormat(_ videoFormat: CMFormatDescription) -> Bool {
        let isFullVideoRaw = videoFormat.extensions["FullRangeVideo" as CFString]
        return ((isFullVideoRaw != nil ? isFullVideoRaw as! NSNumber : 0).intValue != 0)
    }
    
    // The Metal texture formats for each of the planes of a given CVPixelFormatType
    static func getTextureTypesForFormat(_ format: OSType) -> [MTLPixelFormat]
    {
        // TODO(shinyquagsire23): I still haven't figured out how to determine if a pixel format
        // is valid on a particular hardware configuration, Metal throws asserts for invalid formats
        switch(format) {
            // 8-bit biplanar
            case kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
                return forceFastSecretTextureFormats ? [MTLPixelFormat.init(rawValue: MTLPixelFormatYCBCR8_420_2P_sRGB)!, MTLPixelFormat.invalid] : [MTLPixelFormat.r8Unorm, MTLPixelFormat.rg8Unorm]

            // 10-bit biplanar
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                 kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
                return forceFastSecretTextureFormats ? [MTLPixelFormat.init(rawValue: MTLPixelFormatYCBCR10_420_2P_sRGB)!, MTLPixelFormat.invalid] : [MTLPixelFormat.r16Unorm, MTLPixelFormat.rg16Unorm]

            //
            // If it's good enough for WebKit, it's good enough for me.
            // https://github.com/WebKit/WebKit/blob/f86d3400c875519b3f3c368f1ea9a37ed8a1d11b/Source/WebGPU/WebGPU/MetalSPI.h#L30
            // https://github.com/WebKit/WebKit/blob/f86d3400c875519b3f3c368f1ea9a37ed8a1d11b/Source/WebGPU/WebGPU/BindGroup.mm#L43
            // https://github.com/WebKit/WebKit/blob/ef1916c078676dca792cef30502a765d398dcc18/Source/WebGPU/WebGPU/BindGroup.mm#L416
            //
            // 10-bit packed biplanar 4:2:0
            case kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange_compat,
                 kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange:
                return [MTLPixelFormat.init(rawValue: MTLPixelFormatYCBCR10_420_2P_PACKED_sRGB)!, MTLPixelFormat.invalid] // MTLPixelFormatYCBCR10_420_2P_PACKED
            
            // 10-bit packed biplanar 4:2:2
            case kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr10PackedBiPlanarVideoRange:
                return [MTLPixelFormat.init(rawValue: MTLPixelFormatYCBCR10_422_2P_PACKED_sRGB)!, MTLPixelFormat.invalid] // MTLPixelFormatYCBCR10_422_2P_PACKED
            
            // 10-bit packed biplanar 4:4:4
            case kCVPixelFormatType_444YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_444YpCbCr10PackedBiPlanarVideoRange:
                return [MTLPixelFormat.init(rawValue: MTLPixelFormatYCBCR10_444_2P_PACKED_sRGB)!, MTLPixelFormat.invalid] // MTLPixelFormatYCBCR10_444_2P_PACKED
            
            // RGB formats
            case kCVPixelFormatType_32BGRA,
                 kCVPixelFormatType_Lossless_32BGRA,
                 kCVPixelFormatType_Lossy_32BGRA:
                return [MTLPixelFormat.bgra8Unorm_srgb, MTLPixelFormat.invalid]
            case kCVPixelFormatType_32RGBA:
                return [MTLPixelFormat.rgba8Unorm_srgb, MTLPixelFormat.invalid]

            // Guess 8-bit biplanar otherwise
            default:
                let formatStr = coreVideoPixelFormatToStr[format, default: "unknown"]
                print("Warning: Pixel format \(formatStr) (\(format)) is not currently accounted for! Returning 8-bit vals")
                return [MTLPixelFormat.r8Unorm, MTLPixelFormat.rg8Unorm]
        }
    }
    
    static func isFormatSecret(_ format: OSType) -> Bool
    {
        switch(format) {
            // Packed formats, requires secret MTLTexture pixel formats
            case kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange_compat,
                 kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_444YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_422YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_444YpCbCr10PackedBiPlanarVideoRange:
            return true;
            
            // Not packed, but there's still a nice pixel format for them that's a
            // few hundred microseconds faster.
            case kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange, // 8-bit
                 kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
                 
                 // 10-bit
                 kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                 kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
                return forceFastSecretTextureFormats
            default:
                return false
        }
    }
}
