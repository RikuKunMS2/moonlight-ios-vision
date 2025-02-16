//
//  Shaders.metal
//  Moonlight
//
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct CopyVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct HDRParams {
    float boost;      // Range: 1.0 - 3.0, Default: 2.0
    float contrast;   // Range: 1.0 - 2.0, Default: 1.5
    float saturation; // Range: 1.0 - 2.0, Default: 1.5
};

vertex CopyVertexOut copyVertexShader(ushort vertexID [[vertex_id]]) {
    CopyVertexOut out;
    float2 uv = float2(float((vertexID << ushort(1)) & 2u), float(vertexID & ushort(2)) * 0.5);
    out.position = float4((uv * float2(2.0, -2.0)) + float2(-1.0, 1.0), 0.0, 1.0);
    out.uv = uv;
    return out;
}

fragment half4 copyFragmentShader(CopyVertexOut in [[stage_in]],
                                texture2d<half> in_tex,
                                constant bool& hdrEnabled [[buffer(0)]],
                                constant HDRParams& hdrParams [[buffer(1)]]) {
    constexpr sampler colorSampler(coord::normalized,
                    address::clamp_to_edge,
                    filter::linear);

    half4 color = in_tex.sample(colorSampler, in.uv);
    float3 hdrColor = float3(color.rgb);
    
    if (hdrEnabled) {
        // Convert to luminance using Rec.2020/BT.2020 luminance coefficients
        // These weights represent human perception of brightness from RGB components
        float luminance = dot(hdrColor, float3(0.2126, 0.7152, 0.0722));
        
        // Normalize colors by luminance to preserve color ratios
        // Adding 0.0001 to prevent division by zero
        float3 color_norm = hdrColor / max(luminance, 0.0001);
        
        // Progressive highlight boost configuration
        float knee = 0.5;      // Start boosting at 50% brightness
        float soft_knee = 0.1; // Smooth transition range (0.4 to 0.6) to prevent harsh changes
        
        // Apply highlight boost with smooth transition
        float boosted_luma = luminance;
        if (luminance > knee - soft_knee) {
            // Smooth interpolation around knee point
            float t = smoothstep(knee - soft_knee, knee + soft_knee, luminance);
            // Mix between original and boosted luminance based on smoothstep
            boosted_luma = mix(luminance, luminance * hdrParams.boost, t);
        }
        
        // Recombine boosted luminance with original colors
        // This preserves color ratios while applying the highlight boost
        hdrColor = color_norm * boosted_luma;
        
        // Increase contrast to enhance HDR effect
        // pow(x, contrast) provides a gentle contrast boost that preserves both shadows and highlights
        hdrColor = pow(hdrColor, float3(hdrParams.contrast));
        
        // Enhance color saturation
        // This helps compensate for any saturation loss from the contrast boost
        float3 desaturated = float3(dot(hdrColor, float3(0.333))); // Gray scale
        hdrColor = mix(desaturated, hdrColor, hdrParams.saturation);         // Mix between gray and color
    }
    
    return half4(half3(hdrColor), color.a);
}
