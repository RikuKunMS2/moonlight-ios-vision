//
//  Shaders.metal
//  Moonlight
//
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//
#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

// MARK: - Constants
// BT.2408 diffuse white: 203 nits → maps to EDR 1.0 in an ideal EDR pipeline.
constant float PQ_REFERENCE_WHITE_NITS = 203.0;
// PQ highlight rolloff (applied to linear Display P3 **luma** to preserve hue).
constant float PQ_SOFT_CLIP_KNEE     = 1.0;
constant float PQ_SOFT_CLIP_MAX_EDR  = 2.55;
// Base trim for all content written to Unlit `rgba16Float` (still hotter than UIKit).
constant float REALITYKIT_UNLIT_HDR_LINEAR_SCALE = 0.68;
// SDR streams in HDR mode: user feedback “仍略亮” — small extra trim on Display P3 path only.
constant float REALITYKIT_SDR_ON_DISPLAYP3_EXTRA = 0.93;
// PQ/HDR needs stronger attenuation than SDR-in-HDR; applied only when isPQ.
constant float REALITYKIT_PQ_EXTRA_LINEAR_SCALE = 0.64;
// Linear Display P3 → relative luminance (D65). Used only after BT*_TO_DISPLAY_P3 for PQ tone mapping.
constant float3 kLinearDisplayP3Luma = float3(0.2289, 0.6917, 0.0793);
constant float3 kRec709Luma = float3(0.2126, 0.7152, 0.0722);
constant float3 kRec2020Luma = float3(0.2627, 0.6780, 0.0593);

// MARK: - Structures
struct ColorEnhancementUniforms {
    float saturation;
    float contrast;
    float warmth;
    float padding1;
};

struct FullHDRParams {
    float boost;
    float contrast;
    float saturation;
    float brightness;
    /// User trim for PQ (ST.2084) / true HDR frames only; 1.0 = default.
    float pqExposure;
    int   mode;
};

struct CopyVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct HDRParams {
    uint is10Bit;
    uint isFullRange;
    uint isPQ;
    uint matrixType;
    uint primariesType;
    uint isTargetDisplayP3;
};


// Column-major linear-light gamut transforms with D65 white point.
constant float3x3 BT709_TO_DISPLAY_P3 = float3x3(
    float3(0.82246, 0.03319, 0.01708),
    float3(0.17754, 0.96681, 0.07240),
    float3(0.00000, 0.00000, 0.91052)
);

constant float3x3 BT2020_TO_DISPLAY_P3 = float3x3(
    float3( 1.22494, -0.04206, -0.01964),
    float3(-0.22494,  1.04206, -0.07864),
    float3( 0.00000,  0.00000,  1.09827)
);

// SMPTE-C (BT.601 studio primaries) to Rec.709 in linear light.
constant float3x3 SMPTEC_TO_BT709 = float3x3(
    float3( 1.0654, -0.0196,  0.0016),
    float3(-0.0554,  1.0364, -0.0044),
    float3(-0.0010, -0.0167,  1.0028)
);

/// SDR → linear Display P3 for `rgba16Float`. Do **not** clamp to 1: per-channel clip skews hue vs UIKit
/// for saturated Rec.709 / SMPTE-C / 2020 colors that land slightly above 1.0 in P3 linear.
inline float3 mapSdrPrimariesToDisplay(float3 linearColor, constant HDRParams& params) {
    if (params.primariesType == 1u) {
        return max(BT2020_TO_DISPLAY_P3 * linearColor, float3(0.0));
    }
    if (params.primariesType == 2u) {
        float3 linear709 = max(SMPTEC_TO_BT709 * linearColor, float3(0.0));
        return max(BT709_TO_DISPLAY_P3 * linear709, float3(0.0));
    }
    return max(BT709_TO_DISPLAY_P3 * linearColor, float3(0.0));
}
inline float pqInv(float p) {
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;
    p = clamp(p, 0.0, 1.0);
    float n = pow(p, 1.0 / m2);
    float num = max(n - c1, 0.0);
    float den = max(c2 - c3 * n, 1e-4);
    return pow(num / den, 1.0 / m1) * 10000.0;
}

inline float3 pqInv(float3 p) {
    return float3(pqInv(p.r), pqInv(p.g), pqInv(p.b));
}

inline float roundedRectSDF(float2 centerPos, float2 size, float radius) {
    return length(max(abs(centerPos) - size + radius, 0.0)) - radius;
}

inline float3 rec709ToLinear(float3 c) {
    // Apple's ColorSync uses a gamma of 1.961 for Rec.709 video, which causes the famous "QuickTime gamma shift".
    // To match UIKit's AVSampleBufferDisplayLayer exactly, we must use the same 1.961 gamma curve
    // instead of the mathematically correct BT.709 piecewise inverse transfer function.
    return pow(clamp(c, 0.0, 1.0), float3(1.961));
}


inline float3 decode709VideoRange(float ySample, float2 uvSample, bool is10Bit) {
    float yOffset = is10Bit ? (64.0 / 1023.0) : (16.0 / 255.0);
    float uvCenter = is10Bit ? (512.0 / 1023.0) : (128.0 / 255.0);
    float y = max(ySample - yOffset, 0.0) * (is10Bit ? (1023.0 / 876.0) : (255.0 / 219.0));
    float cb = uvSample.x - uvCenter;
    float cr = uvSample.y - uvCenter;
    return float3(
        y + 1.79274107 * cr,
        y - 0.21324861 * cb - 0.53290933 * cr,
        y + 2.11240179 * cb
    );
}

inline float3 decode709FullRange(float ySample, float2 uvSample, bool is10Bit) {
    float uvCenter = is10Bit ? (512.0 / 1023.0) : (128.0 / 255.0);
    float y = clamp(ySample, 0.0, 1.0);
    float cb = uvSample.x - uvCenter;
    float cr = uvSample.y - uvCenter;
    return float3(
        y + 1.5748 * cr,
        y - 0.187324 * cb - 0.468124 * cr,
        y + 1.8556 * cb
    );
}

inline float3 decode2020VideoRange(float ySample, float2 uvSample, bool is10Bit) {
    float yOffset = is10Bit ? (64.0 / 1023.0) : (16.0 / 255.0);
    float uvCenter = is10Bit ? (512.0 / 1023.0) : (128.0 / 255.0);
    float y = max(ySample - yOffset, 0.0) * (is10Bit ? (1023.0 / 876.0) : (255.0 / 219.0));
    float cb = uvSample.x - uvCenter;
    float cr = uvSample.y - uvCenter;
    return float3(
        y + 1.67867411 * cr,
        y - 0.18732610 * cb - 0.65042432 * cr,
        y + 2.14177232 * cb
    );
}

inline float3 decode2020FullRange(float ySample, float2 uvSample, bool is10Bit) {
    float uvCenter = is10Bit ? (512.0 / 1023.0) : (128.0 / 255.0);
    float y = clamp(ySample, 0.0, 1.0);
    float cb = uvSample.x - uvCenter;
    float cr = uvSample.y - uvCenter;
    return float3(
        y + 1.4746 * cr,
        y - 0.164553 * cb - 0.571353 * cr,
        y + 1.8814 * cb
    );
}

inline float3 decode601VideoRange(float ySample, float2 uvSample, bool is10Bit) {
    float yOffset = is10Bit ? (64.0 / 1023.0) : (16.0 / 255.0);
    float uvCenter = is10Bit ? (512.0 / 1023.0) : (128.0 / 255.0);
    float y = max(ySample - yOffset, 0.0) * (is10Bit ? (1023.0 / 876.0) : (255.0 / 219.0));
    float cb = uvSample.x - uvCenter;
    float cr = uvSample.y - uvCenter;
    return float3(
        y + 1.596027 * cr,
        y - 0.391762 * cb - 0.812968 * cr,
        y + 2.017232 * cb
    );
}

inline float3 decode601FullRange(float ySample, float2 uvSample, bool is10Bit) {
    float uvCenter = is10Bit ? (512.0 / 1023.0) : (128.0 / 255.0);
    float y = clamp(ySample, 0.0, 1.0);
    float cb = uvSample.x - uvCenter;
    float cr = uvSample.y - uvCenter;
    return float3(
        y + 1.40200 * cr,
        y - 0.344136 * cb - 0.714136 * cr,
        y + 1.77200 * cb
    );
}

// MARK: - Color Grading
inline float3 applyVisionProGrading(float3 color, ColorEnhancementUniforms params) {
    float luma = dot(color, kRec709Luma);
    float3 saturated = mix(float3(luma), color, params.saturation);
    float3 contrasted = (saturated - 0.5) * params.contrast + 0.5;

    float3 warmed = contrasted;
    if (abs(params.warmth) > 0.001) {
        warmed.r = contrasted.r * (1.0 + params.warmth * 0.5);
        warmed.b = contrasted.b * (1.0 - params.warmth * 0.5);
        warmed = clamp(warmed, 0.0, 1.0);
    }

    return clamp(warmed, 0.0, 1.0);
}

inline float3 applyVisionProGrading(float3 color, constant ColorEnhancementUniforms& paramsConst) {
    ColorEnhancementUniforms local = paramsConst;
    return applyVisionProGrading(color, local);
}

/// PQ / scene-linear HDR: do **not** clamp to 1 — SDR grading would clip highlights and skew hue.
inline float3 applyVisionProGradingHDR(float3 color, ColorEnhancementUniforms params, uint useBT2020Luma) {
    float luma = (useBT2020Luma == 1u) ? dot(color, kRec2020Luma) : dot(color, kRec709Luma);
    float3 saturated = mix(float3(luma), color, params.saturation);
    float3 contrasted = (saturated - float3(luma)) * params.contrast + float3(luma);

    float3 warmed = contrasted;
    if (abs(params.warmth) > 0.001) {
        warmed.r = contrasted.r * (1.0 + params.warmth * 0.5);
        warmed.b = contrasted.b * (1.0 - params.warmth * 0.5);
    }

    return max(warmed, float3(0.0));
}

/// Map absolute-nit BT.2020 (or BT.709) linear light to Display P3 EDR.
/// No clamping — HDR headroom is preserved for soft-clip downstream.
inline float3 pqNitsToDisplayP3(float3 nits, constant HDRParams& params) {
    float3 edr = nits / PQ_REFERENCE_WHITE_NITS; // 203 nits → 1.0 EDR
    bool use2020 = (params.primariesType == 1u) || (params.matrixType == 1u);
    return use2020 ? BT2020_TO_DISPLAY_P3 * edr : BT709_TO_DISPLAY_P3 * edr;
}

/// Soft-clip a single EDR channel. Linear below `knee`, smooth exponential rolloff above.
/// SDR white (1.0) is always below the knee → completely untouched.
inline float pqSoftClip1(float x, float knee, float maxEDR) {
    if (x <= knee) return x;
    float range = maxEDR - knee;
    return knee + range * (1.0 - exp(-(x - knee) / range));
}

/// Compress PQ peaks using **luma** in linear P3 (chromaticity preserved; avoids per-channel clip = hue shift + blown highlights).
inline float3 pqToneMapLumaDisplayP3(float3 cP3, float knee, float maxEDR) {
    float y = max(dot(cP3, kLinearDisplayP3Luma), 1e-6);
    float y2 = pqSoftClip1(y, knee, maxEDR);
    return cP3 * (y2 / y);
}

// MARK: - Vertex Shader
vertex CopyVertexOut copyVertexShader(ushort vid [[vertex_id]]) {
    CopyVertexOut o;
    float2 uv = float2(float((vid << 1) & 2u), float(vid & 2u) * 0.5);
    o.position = float4((uv * float2(2.0, -2.0)) + float2(-1.0, 1.0), 0.0, 1.0);
    o.uv = uv;
    return o;
}

// MARK: - Curved Display Shaders (Standard Linear - Optimized for VR)
fragment half4 copyFragmentShaderHDR_EDR(
    CopyVertexOut in [[stage_in]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> cbcrTex [[texture(1)]],
    constant HDRParams &params [[buffer(0)]],
    constant FullHDRParams &full [[buffer(1)]],
    constant ColorEnhancementUniforms &enhancements [[buffer(2)]]
) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float ySample = yTex.sample(s, in.uv).r;
    float2 uvSample = cbcrTex.sample(s, in.uv).rg;

    float3 rgb_nl;
    if (params.matrixType == 1u) {
        rgb_nl = (params.isFullRange == 1u)
            ? decode2020FullRange(ySample, uvSample, params.is10Bit == 1u)
            : decode2020VideoRange(ySample, uvSample, params.is10Bit == 1u);
    } else if (params.matrixType == 2u) {
        rgb_nl = (params.isFullRange == 1u)
            ? decode601FullRange(ySample, uvSample, params.is10Bit == 1u)
            : decode601VideoRange(ySample, uvSample, params.is10Bit == 1u);
    } else {
        rgb_nl = (params.isFullRange == 1u)
            ? decode709FullRange(ySample, uvSample, params.is10Bit == 1u)
            : decode709VideoRange(ySample, uvSample, params.is10Bit == 1u);
    }

    float3 finalColor;
    if (params.isPQ == 1u) {
        // PQ absolute-nit decode → Display P3 EDR.
        // 203 nits (BT.2408 reference) → 1.0 EDR (display SDR white). No extra gain.
        float3 linearNits = pqInv(clamp(rgb_nl, 0.0, 1.0));
        finalColor = pqNitsToDisplayP3(linearNits, params);

        // Apply user-controlled HDR grading (neutral by default: boost=1, contrast=1, saturation=1, brightness=0).
        finalColor *= max(full.boost, 0.0);
        finalColor += max(full.brightness, 0.0);
        ColorEnhancementUniforms eff = enhancements;
        eff.saturation = enhancements.saturation * full.saturation;
        eff.contrast   = enhancements.contrast   * full.contrast;
        uint useBt2020Luma = ((params.primariesType == 1u) || (params.matrixType == 1u)) ? 1u : 0u;
        finalColor = applyVisionProGradingHDR(finalColor, eff, useBt2020Luma);
        finalColor *= max(full.pqExposure, 0.0);
    } else {
        // SDR content: gamma-decode → Display P3 linear.
        // For rgba16Float target: 1.0 linear = display SDR white (EDR 1.0) — no extra gain needed.
        float3 linearColor = rec709ToLinear(clamp(rgb_nl, 0.0, 1.0));
        if (params.isTargetDisplayP3 == 1u) {
            finalColor = mapSdrPrimariesToDisplay(linearColor, params);
        } else {
            finalColor = (params.primariesType == 2u)
                ? clamp(SMPTEC_TO_BT709 * linearColor, 0.0, 1.0)
                : linearColor;
        }
    }

    finalColor = min(finalColor, float3(20.0));

    if (full.mode == 2) {
        if (in.uv.y < 0.15) {
            float stepVal = floor(in.uv.x * 5.0);
            float targetNits = 0.0;
            if (stepVal == 1.0) targetNits = 100.0;
            else if (stepVal == 2.0) targetNits = 203.0;
            else if (stepVal == 3.0) targetNits = 500.0;
            else if (stepVal == 4.0) targetNits = 1000.0;
            
            float3 testColor = targetNits / PQ_REFERENCE_WHITE_NITS;
            return half4(half3(testColor), 1.0h);
        }
    }

    return half4(half3(finalColor), 1.0h);
}

fragment half4 copyFragmentShaderHEVC_EDR(
    CopyVertexOut in [[stage_in]],
    texture2d<half> rgbTex [[texture(0)]],
    constant HDRParams &params [[buffer(0)]],
    constant FullHDRParams &full [[buffer(1)]],
    constant ColorEnhancementUniforms &enhancements [[buffer(2)]]
) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    // Input texture is plain UNorm SDR video; convert Rec.709 video values explicitly.
    float3 rgb_nl = float3(rgbTex.sample(s, in.uv).rgb);

    float3 finalColor;
    if (params.isPQ == 1u) {
        float3 linearNits = pqInv(clamp(rgb_nl, 0.0, 1.0));
        finalColor = pqNitsToDisplayP3(linearNits, params);

        finalColor *= max(full.boost, 0.0);
        finalColor += max(full.brightness, 0.0);
        ColorEnhancementUniforms eff = enhancements;
        eff.saturation = enhancements.saturation * full.saturation;
        eff.contrast   = enhancements.contrast   * full.contrast;
        uint useBt2020Luma = ((params.primariesType == 1u) || (params.matrixType == 1u)) ? 1u : 0u;
        finalColor = applyVisionProGradingHDR(finalColor, eff, useBt2020Luma);
        finalColor *= max(full.pqExposure, 0.0);
    } else {
        float3 linearColor = rec709ToLinear(clamp(rgb_nl, 0.0, 1.0));
        if (params.isTargetDisplayP3 == 1u) {
            finalColor = mapSdrPrimariesToDisplay(linearColor, params);
        } else {
            finalColor = (params.primariesType == 2u)
                ? clamp(SMPTEC_TO_BT709 * linearColor, 0.0, 1.0)
                : linearColor;
        }
    }

    finalColor = min(finalColor, float3(20.0));

    if (full.mode == 2) {
        if (in.uv.y < 0.15) {
            float stepVal = floor(in.uv.x * 5.0);
            float targetNits = 0.0;
            if (stepVal == 1.0) targetNits = 100.0;
            else if (stepVal == 2.0) targetNits = 203.0;
            else if (stepVal == 3.0) targetNits = 500.0;
            else if (stepVal == 4.0) targetNits = 1000.0;
            
            float3 testColor = targetNits / PQ_REFERENCE_WHITE_NITS;
            return half4(half3(testColor), 1.0h);
        }
    }

    return half4(half3(finalColor), 1.0h);
}

// MARK: - UIKit Shaders (Clean Pass-Through with Shader-Based Rounded Corners)
fragment half4 copyFragmentShaderHDR_EDR_UIKit(
    CopyVertexOut in [[stage_in]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> cbcrTex [[texture(1)]],
    constant HDRParams &params [[buffer(0)]],
    constant FullHDRParams &full [[buffer(1)]],
    constant ColorEnhancementUniforms &enhancements [[buffer(2)]]
) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 texSize = float2(yTex.get_width(), yTex.get_height());
    float2 pixelPos = in.uv * texSize;
    float2 centerPos = pixelPos - (texSize * 0.5);
    float cornerRadius = 16.0;
    float dist = roundedRectSDF(centerPos, texSize * 0.5, cornerRadius);

    if (dist > 0.0) {
        discard_fragment();
    }

    float ySample = yTex.sample(s, in.uv).r;
    float2 uvSample = cbcrTex.sample(s, in.uv).rg;

    float3 rgb_nl;
    if (params.matrixType == 1u) {
        rgb_nl = (params.isFullRange == 1u)
            ? decode2020FullRange(ySample, uvSample, params.is10Bit == 1u)
            : decode2020VideoRange(ySample, uvSample, params.is10Bit == 1u);
    } else if (params.matrixType == 2u) {
        rgb_nl = (params.isFullRange == 1u)
            ? decode601FullRange(ySample, uvSample, params.is10Bit == 1u)
            : decode601VideoRange(ySample, uvSample, params.is10Bit == 1u);
    } else {
        rgb_nl = (params.isFullRange == 1u)
            ? decode709FullRange(ySample, uvSample, params.is10Bit == 1u)
            : decode709VideoRange(ySample, uvSample, params.is10Bit == 1u);
    }

    float3 finalColor;
    if (params.isPQ == 1u) {
        float3 linearNits = pqInv(clamp(rgb_nl, 0.0, 1.0));
        finalColor = linearNits / PQ_REFERENCE_WHITE_NITS;
        finalColor *= max(full.pqExposure, 0.0);
    } else {
        finalColor = rgb_nl;
    }

    finalColor *= max(full.boost, 0.0);
    finalColor += max(full.brightness, 0.0);

    ColorEnhancementUniforms eff = enhancements;
    eff.saturation = enhancements.saturation * full.saturation;
    eff.contrast   = enhancements.contrast   * full.contrast;

    finalColor = applyVisionProGrading(finalColor, eff);
    finalColor = (params.isPQ == 1u) ? min(finalColor, float3(20.0)) : clamp(finalColor, 0.0, 1.0);

    return half4(half3(finalColor), 1.0h);
}

fragment half4 copyFragmentShaderHEVC_EDR_UIKit(
    CopyVertexOut in [[stage_in]],
    texture2d<half> rgbTex [[texture(0)]],
    constant HDRParams &params [[buffer(0)]],
    constant FullHDRParams &full [[buffer(1)]],
    constant ColorEnhancementUniforms &enhancements [[buffer(2)]]
) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 texSize = float2(rgbTex.get_width(), rgbTex.get_height());
    float2 pixelPos = in.uv * texSize;
    float2 centerPos = pixelPos - (texSize * 0.5);
    float cornerRadius = 16.0;
    float dist = roundedRectSDF(centerPos, texSize * 0.5, cornerRadius);

    if (dist > 0.0) {
        discard_fragment();
    }

    float3 rgb_nl = float3(rgbTex.sample(s, in.uv).rgb);

    float3 finalColor;
    if (params.isPQ == 1u) {
        float3 linearNits = pqInv(clamp(rgb_nl, 0.0, 1.0));
        finalColor = linearNits / PQ_REFERENCE_WHITE_NITS;
        finalColor *= max(full.pqExposure, 0.0);
    } else {
        finalColor = rgb_nl;
    }

    finalColor *= max(full.boost, 0.0);
    finalColor += max(full.brightness, 0.0);

    ColorEnhancementUniforms eff = enhancements;
    eff.saturation = enhancements.saturation * full.saturation;
    eff.contrast   = enhancements.contrast   * full.contrast;

    finalColor = applyVisionProGrading(finalColor, eff);
    finalColor = (params.isPQ == 1u) ? min(finalColor, float3(20.0)) : clamp(finalColor, 0.0, 1.0);

    return half4(half3(finalColor), 1.0h);
}

// MARK: - Ambilight Shader (Downsampled + Vignette)
fragment half4 copyFragmentShaderAmbilight(
    CopyVertexOut in [[stage_in]],
    texture2d<half> sourceTex [[texture(0)]],
    texture2d<half> prevTex [[texture(1)]],
    constant int &isVolumeMode [[buffer(1)]]
) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    
    float w = max(float(sourceTex.get_width()), 1.0);
    float h = max(float(sourceTex.get_height()), 1.0);
    float aspect = w / h;
    
    // The ambPlane is baseScale times larger than the screen physically (padding added to width).
    // The padding is added uniformly to all 4 sides in physical space.
    float baseScale = (isVolumeMode == 1) ? 1.45 : 2.5;
    
    // To map `in.uv` correctly, Y scale must be larger because padding is a larger percentage of height than width.
    float2 scale = float2(baseScale, 1.0 + aspect * (baseScale - 1.0));
    float2 videoUV = (in.uv - 0.5) * scale + 0.5;
    
    // Calculate distance from the video box (which is [0, 1] in videoUV space)
    float2 dist = max(float2(0.0), abs(videoUV - 0.5) * 2.0 - 1.0);
    
    // Divide Y by aspect to convert back to true isotropic physical distance.
    dist.y /= aspect;
    float distLength = length(dist);
    
    // Make the center (under the video mesh) completely hollow.
    // Shrink the mathematical cutout slightly (inset to 0.85) so the sharp 90-degree 
    // corners of the hole hide completely behind the physical rounded corners of the video mesh.
    float2 hollowDist = max(float2(0.0), abs(videoUV - 0.5) * 2.0 - 0.85);
    if (length(hollowDist) <= 0.0) {
        return half4(0.0); // Transparent hollow center
    }
    
    // Perimeter Analysis Zones Grid
    float2 zoneSize = float2(0.12, 0.12 * aspect); 
    // Inset a bit further to avoid seeing dark edges/vignette around the video
    float2 letterboxSkip = float2(0.04, 0.04 * aspect);
    
    float2 zoneCenterOffset = letterboxSkip + (zoneSize * 0.5);
    
    // Map external UVs to the nearest internal perimeter zone
    float2 zoneCenterUV;
    zoneCenterUV.x = clamp(videoUV.x, zoneCenterOffset.x, 1.0 - zoneCenterOffset.x);
    zoneCenterUV.y = clamp(videoUV.y, zoneCenterOffset.y, 1.0 - zoneCenterOffset.y);
    
    // Color Averaging calculation per Zone
    half4 color = half4(0.0);
    float totalWeight = 0.0;
    
    // Dynamically expand the sampling radius based on distance.
    // This scatters edge pixels over a wider area to prevent stretching artifacts (solid lines).
    float spreadFactor = 1.0 + distLength * 8.0; 
    float2 dynamicBlurRadius = (zoneSize * 0.5) * spreadFactor;
    
    // Clamp the blur radius to prevent it from sampling past the center of the video.
    // If the radius grows too large in immersive mode, the top blur samples the bottom of the video,
    // which causes the top and bottom glow to look unnaturally dark and muddy.
    dynamicBlurRadius = min(dynamicBlurRadius, float2(0.4));
    
    // Define a small safe inset to avoid sampling the absolute extreme edge pixels of the texture,
    // which often contain a 1-pixel black border from hardware video decoders.
    float2 safeInset = float2(0.01);
    float2 minUV = safeInset;
    float2 maxUV = 1.0 - safeInset;
    
    float maxLuma = 0.0;
    
    for (int y = -2; y <= 2; ++y) {
        for (int x = -2; x <= 2; ++x) {
            float2 offset = float2(float(x), float(y)) / 2.0;
            float weight = exp(-2.0 * (offset.x*offset.x + offset.y*offset.y));
            // Clamp sample to the safe inner bounds instead of [0, 1] to prevent pulling in black border pixels
            float2 sampleUV = clamp(zoneCenterUV + offset * dynamicBlurRadius, minUV, maxUV);
            half4 sampleColor = sourceTex.sample(s, sampleUV);
            color += sampleColor * half(weight);
            totalWeight += weight;
            
            float luma = dot(sampleColor.rgb, half3(0.2126, 0.7152, 0.0722));
            maxLuma = max(maxLuma, luma);
        }
    }
    color /= half(totalWeight);
    
    // Saturation Boost
    float avgLuma = dot(color.rgb, half3(0.2126, 0.7152, 0.0722));
    float saturationBoost = 2.2; 
    color.rgb = mix(half3(avgLuma), color.rgb, half(saturationBoost));
    
    // Dynamic Luminance Mapping (dimming HDR peaks to LED physical constraints)
    float powerLimit = 1.0;
    float dynamicDimming = (maxLuma > powerLimit) ? (powerLimit / maxLuma) : 1.0;
    color.rgb *= half(dynamicDimming);
    
    // Brightness Scalar to achieve Additive Blending intensity
    color.rgb *= half(2.5); // Emission scalar
    color.rgb = max(color.rgb, half3(0.0));
    
    // The physical distance from edge to mesh boundary is exactly (baseScale - 1.0) on all straight edges.
    // In Volume Mode, visionOS imposes strict window clipping, so we fade out slightly earlier.
    float outerBound = (isVolumeMode == 1) ? 0.44 : (baseScale - 1.0);
    
    // Power curve fade: smoothly interpolates to 0 exactly at the edges of the mesh.
    float normalizedDist = clamp(distLength / outerBound, 0.0, 1.0);
    float fade = pow(1.0 - normalizedDist, 2.0); // Smooth quadratic falloff
    
    // explicitly set alpha to fade, keep RGB untampered so RealityKit can composite it properly.
    half4 currentColor = half4(color.rgb, half(fade));
    
    // Temporal Smoothing (Mix 10% new frame with 90% previous frame)
    half4 previousColor = prevTex.sample(s, in.uv);
    return mix(previousColor, currentColor, 0.10);
}
