#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

// MARK: - Constants
constant float REFERENCE_WHITE_NITS = 200.0;
constant float3 kRec709Luma = float3(0.2126, 0.7152, 0.0722);

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
    int   mode;
};

struct CopyVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct HDRParams {
    uint presetIndex;
    uint isPQ;
    uint isBT2020Matrix;
    uint isBT2020Primaries;
};

// MARK: - Matrices
constant float3x3 BT2020_TO_P3 = float3x3(
    float3( 1.6605, -0.1246, -0.0182),
    float3(-0.5876,  1.1329, -0.1006),
    float3(-0.0729, -0.0083,  1.1188)
);

constant float3x3 BT709_TO_P3 = float3x3(
    float3( 0.6069, 0.1735, 0.2006),
    float3( 0.2989, 0.5866, 0.1144),
    float3( 0.0000, 0.0661, 1.1150)
);

// MARK: - Helper Functions
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

inline float expandY_10bit(float y) {
    return clamp((y - 0.06256) * 1.16780, 0.0, 1.0);
}

inline float2 expandCbCr_10bit(float2 uv) {
    return (uv - float2(0.5, 0.5)) * 1.14170;
}

inline float roundedRectSDF(float2 centerPos, float2 size, float radius) {
    return length(max(abs(centerPos) - size + radius, 0.0)) - radius;
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

    float y = expandY_10bit(ySample);
    float2 uv = expandCbCr_10bit(uvSample);
    float cb = uv.x;
    float cr = uv.y;

    float3 rgb_nl;
    if (params.isBT2020Matrix == 1u) {
        rgb_nl = float3(y + 1.4746 * cr, y - 0.16455 * cb - 0.57135 * cr, y + 1.8814 * cb);
    } else {
        rgb_nl = float3(y + 1.5748 * cr, y - 0.1873 * cb - 0.4681 * cr, y + 1.8556 * cb);
    }

    float3 finalColor;
    if (params.isPQ == 1u) {
        float3 linearNits = pqInv(clamp(rgb_nl, 0.0, 1.0));
        finalColor = linearNits / REFERENCE_WHITE_NITS;
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

fragment half4 copyFragmentShaderHEVC_EDR(
    CopyVertexOut in [[stage_in]],
    texture2d<half> rgbTex [[texture(0)]],
    constant HDRParams &params [[buffer(0)]],
    constant FullHDRParams &full [[buffer(1)]],
    constant ColorEnhancementUniforms &enhancements [[buffer(2)]]
) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float3 rgb_nl = float3(rgbTex.sample(s, in.uv).rgb);

    float3 finalColor;
    if (params.isPQ == 1u) {
        float3 linearNits = pqInv(clamp(rgb_nl, 0.0, 1.0));
        finalColor = linearNits / REFERENCE_WHITE_NITS;
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

    float y = expandY_10bit(ySample);
    float2 uv = expandCbCr_10bit(uvSample);
    float cb = uv.x;
    float cr = uv.y;

    float3 rgb_nl;
    if (params.isBT2020Matrix == 1u) {
        rgb_nl = float3(y + 1.4746 * cr, y - 0.16455 * cb - 0.57135 * cr, y + 1.8814 * cb);
    } else {
        rgb_nl = float3(y + 1.5748 * cr, y - 0.1873 * cb - 0.4681 * cr, y + 1.8556 * cb);
    }

    float3 finalColor;
    if (params.isPQ == 1u) {
        float3 linearNits = pqInv(clamp(rgb_nl, 0.0, 1.0));
        finalColor = linearNits / REFERENCE_WHITE_NITS;
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
        finalColor = linearNits / REFERENCE_WHITE_NITS;
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
