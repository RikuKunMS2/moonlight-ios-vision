//
//  AV1Helper.m
//  Moonlight
//
//  Created by Luma on 11/24/25.
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//

#import "AV1Helper.h"
#include <libavcodec/avcodec.h>
#include <libavcodec/cbs.h>
#include <libavcodec/cbs_av1.h>
#include <libavformat/avio.h>
#include <libavutil/mem.h>

// Private libavformat API for writing the AV1 Codec Configuration Box
extern int ff_isom_write_av1c(AVIOContext *pb, const uint8_t *buf, int size, int write_seq_header);

@implementation AV1Helper

+ (NSData *)getAv1CodecConfigurationBox:(NSData *)frameData {
    AVIOContext *ioctx = NULL;
    int err;

    err = avio_open_dyn_buf(&ioctx);
    if (err < 0) {
        NSLog(@"[AV1Helper] avio_open_dyn_buf() failed: %d", err);
        return nil;
    }

    // Submit the IDR frame to write the av1C blob
    err = ff_isom_write_av1c(ioctx, (uint8_t *)frameData.bytes, (int)frameData.length, 1);
    if (err < 0) {
        NSLog(@"[AV1Helper] ff_isom_write_av1c() failed: %d", err);
    }

    uint8_t *av1cBuf = NULL;
    int av1cBufLen = avio_close_dyn_buf(ioctx, &av1cBuf);

    NSData *data = nil;
    if (err >= 0 && av1cBufLen > 0) {
        data = [NSData dataWithBytes:av1cBuf length:av1cBufLen];
    }
    
    av_free(av1cBuf);
    return data;
}

+ (nullable CMVideoFormatDescriptionRef)createFormatDescriptionFromIDR:(NSData *)frameData
                                           masteringDisplayColorVolume:(nullable NSData *)mdcv
                                                 contentLightLevelInfo:(nullable NSData *)clli {
    NSMutableDictionary *extensions = [[NSMutableDictionary alloc] init];

    CodedBitstreamContext *cbsCtx = NULL;
    int err = ff_cbs_init(&cbsCtx, AV_CODEC_ID_AV1, NULL);
    if (err < 0) {
        NSLog(@"[AV1Helper] ff_cbs_init() failed: %d", err);
        return nil;
    }

    AVPacket avPacket = {};
    avPacket.data = (uint8_t *)frameData.bytes;
    avPacket.size = (int)frameData.length;

    CodedBitstreamFragment cbsFrag = {};
    err = ff_cbs_read_packet(cbsCtx, &cbsFrag, &avPacket);
    if (err < 0) {
        NSLog(@"[AV1Helper] ff_cbs_read_packet() failed: %d", err);
        ff_cbs_close(&cbsCtx);
        return nil;
    }

#define SET_CFSTR_EXTENSION(key, value) extensions[(__bridge NSString *)key] = (__bridge NSString *)(value)
#define SET_EXTENSION(key, value) extensions[(__bridge NSString *)key] = (value)

    SET_EXTENSION(kCMFormatDescriptionExtension_FormatName, @"av01");
    SET_EXTENSION(kCMFormatDescriptionExtension_Depth, @24);

    CodedBitstreamAV1Context *bitstreamCtx = (CodedBitstreamAV1Context *)cbsCtx->priv_data;
    AV1RawSequenceHeader *seqHeader = bitstreamCtx->sequence_header;
    
    if (seqHeader == NULL) {
        NSLog(@"[AV1Helper] AV1 sequence header not found in IDR frame!");
        ff_cbs_fragment_free(&cbsFrag);
        ff_cbs_close(&cbsCtx);
        return nil;
    }

    // --- Color Primaries ---
    switch (seqHeader->color_config.color_primaries) {
        case 1: SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2); break;
        case 6: SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionColorPrimaries_SMPTE_C); break;
        case 9: SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_2020); break;
        default: break;
    }

    // --- Transfer Function ---
    switch (seqHeader->color_config.transfer_characteristics) {
        case 1:
        case 6: SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2); break;
        case 8: SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_Linear); break;
        case 14:
        case 15: SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_2020); break;
        case 16: SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ); break;
        case 17: SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG); break;
        default: break;
    }

    // --- Matrix Coefficients ---
    switch (seqHeader->color_config.matrix_coefficients) {
        case 1: SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2); break;
        case 6: SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4); break;
        case 9: SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_2020); break;
        default: break;
    }

    SET_EXTENSION(kCMFormatDescriptionExtension_FullRangeVideo, @(seqHeader->color_config.color_range == 1));
    SET_EXTENSION(kCMFormatDescriptionExtension_FieldCount, @(1));

    // --- HDR Metadata ---
    if (clli) { SET_EXTENSION(kCMFormatDescriptionExtension_ContentLightLevelInfo, clli); }
    if (mdcv) { SET_EXTENSION(kCMFormatDescriptionExtension_MasteringDisplayColorVolume, mdcv); }

    // --- AV1 Codec Config Box (Critical) ---
    extensions[(__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = @{
        @"av1C" : [self getAv1CodecConfigurationBox:frameData] ?: [NSData data]
    };
    extensions[@"BitsPerComponent"] = @(bitstreamCtx->bit_depth);

#undef SET_EXTENSION
#undef SET_CFSTR_EXTENSION

    CMVideoFormatDescriptionRef formatDesc = NULL;
    
    // Note: bitstreamCtx->frame_width and frame_height come from the sequence header, so they are accurate (e.g. 3840x2160)
    OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                                     kCMVideoCodecType_AV1,
                                                     bitstreamCtx->frame_width,
                                                     bitstreamCtx->frame_height,
                                                     (__bridge CFDictionaryRef)extensions,
                                                     &formatDesc);

    if (status != noErr) {
        NSLog(@"[AV1Helper] Failed to create AV1 format description: %d", (int)status);
        formatDesc = NULL;
    }

    ff_cbs_fragment_free(&cbsFrag);
    ff_cbs_close(&cbsCtx);
    return formatDesc;
}

@end
