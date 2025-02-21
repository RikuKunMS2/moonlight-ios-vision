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
        // Simple contrast adjustment
        hdrColor = pow(hdrColor, float3(hdrParams.contrast));
        
        // Saturation adjustment
        float3 desaturated = float3(dot(hdrColor, float3(0.333)));
        hdrColor = mix(desaturated, hdrColor, hdrParams.saturation);
    }
    
    return half4(half3(hdrColor), color.a);
}
