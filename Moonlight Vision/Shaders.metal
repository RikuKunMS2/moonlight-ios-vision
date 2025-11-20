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

// Ensure this matches the Swift struct exactly in order and types
struct HDRParams {
    float boost;      // Gain (Make brights brighter)
    float contrast;   // Contrast curve application
    float saturation; // Color intensity
    float brightness; // Offset (Lift blacks/shadows)
};

vertex CopyVertexOut copyVertexShader(ushort vertexID [[vertex_id]]) {
    CopyVertexOut out;
    float2 uv = float2(float((vertexID << ushort(1)) & 2u), float(vertexID & ushort(2)) * 0.5);
    out.position = float4((uv * float2(2.0, -2.0)) + float2(-1.0, 1.0), 0.0, 1.0);
    out.uv = uv;
    return out;
}

// Helper: Converts SMPTE ST.2084 (PQ) encoded values to Linear Nits
float3 PQtoLinear(float3 pq) {
    float m1 = 2610.0 / 4096.0 / 4.0;
    float m2 = 2523.0 / 4096.0 * 128.0;
    float c1 = 3424.0 / 4096.0;
    float c2 = 2413.0 / 4096.0 * 32.0;
    float c3 = 2392.0 / 4096.0 * 32.0;
    
    float3 N = pow(max(pq, 0.0), 1.0 / m2);
    float3 L = pow(max((N - c1) / (c2 - c3 * N), 0.0), 1.0 / m1);
    
    // Result is in range 0.0 - 1.0, where 1.0 = 10,000 nits
    return L * 10000.0;
}

fragment half4 copyFragmentShader(CopyVertexOut in [[stage_in]],
                                texture2d<half> in_tex,
                                constant bool& hdrEnabled [[buffer(0)]],
                                constant HDRParams& hdrParams [[buffer(1)]]) {
    constexpr sampler colorSampler(coord::normalized,
                    address::clamp_to_edge,
                    filter::linear);

    half4 color = in_tex.sample(colorSampler, in.uv);
    float3 rgb = float3(color.rgb);
    
    if (hdrEnabled) {
        // 1. Decode PQ Curve to Linear Light (Nits)
        rgb = PQtoLinear(rgb);
        
        // 2. Apply Saturation (Linear space)
        float luminance = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(luminance), rgb, hdrParams.saturation);

        // 3. Apply Contrast (Optional, centered around mid-tone)
        // rgb = pow(rgb, float3(hdrParams.contrast));
        
        // 4. Apply EDR Scaling / Boost (Gain)
        // The slider value comes in as hdrParams.boost
        float boost = max(hdrParams.boost, 0.1);

        // Multiplication (*) keeps black at 0, but scales up brights
        rgb = (rgb / 100.0) * 1.6 * boost;

        // 5. Apply Brightness (Offset)
        // Add hdrParams.brightness (which we just set to 0.0 in Swift)
        rgb = rgb + float3(hdrParams.brightness);
    }
    
    return half4(half3(rgb), color.a);
}
