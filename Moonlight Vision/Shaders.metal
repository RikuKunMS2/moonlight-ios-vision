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
    float boost;      // Luminance Boost / Gain
    float gamma;      // Was "contrast" - applied as Power function
    float saturation; // Color intensity
    float brightness; // Brightness Offset
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
        
        // 2. Apply Saturation
        // (0.0 = Grayscale, 1.0 = Normal, >1.0 = Oversaturated)
        float luminance = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(luminance), rgb, hdrParams.saturation);

        // 3. Apply Gamma
        // 1.0 is neutral.
        // > 1.0 makes midtones darker (higher contrast look)
        // < 1.0 lifts shadows (flatter look)
        if (hdrParams.gamma != 1.0) {
             rgb = pow(max(rgb, 0.0), float3(hdrParams.gamma));
        }
        
        // 4. Apply EDR Scaling / Boost (Gain)
        float boost = max(hdrParams.boost, 0.1);
        rgb = (rgb / 100.0) * 1.6 * boost;

        // 5. Apply Brightness Offset
        rgb = rgb + float3(hdrParams.brightness);
    }
    
    return half4(half3(rgb), color.a);
}

// BT.2020 to RGB Conversion Constants (Limited Range)
constant float3 kYUVToR = float3(1.0,  0.0000,  1.4746);
constant float3 kYUVToG = float3(1.0, -0.1645, -0.5714);
constant float3 kYUVToB = float3(1.0,  1.8814,  0.0000);

// NEW: Fragment shader for Bi-Planar YUV inputs (NV12/P010)
fragment half4 copyFragmentShaderYUV(CopyVertexOut in [[stage_in]],
                                     texture2d<float> luma_tex [[texture(0)]],  // Plane 0 (Y)
                                     texture2d<float> chroma_tex [[texture(1)]], // Plane 1 (CbCr)
                                     constant bool& hdrEnabled [[buffer(0)]],
                                     constant HDRParams& hdrParams [[buffer(1)]])
{
    constexpr sampler colorSampler(coord::normalized,
                                   address::clamp_to_edge,
                                   filter::linear);

    // 1. Sample Y and CbCr planes
    float y = luma_tex.sample(colorSampler, in.uv).r;
    float2 uv = chroma_tex.sample(colorSampler, in.uv).rg;

    // 2. Adjust for Limited Video Range (16-235 for 8-bit, scaled)
    // Y is offset by 16/255 (approx 0.0625)
    // UV is offset by 0.5 (center bias)
    float y_adj = max(y - 0.062745, 0.0); // 16/255
    float u_adj = uv.r - 0.5;
    float v_adj = uv.g - 0.5;

    // 3. Convert YUV to RGB (BT.2020)
    float r = dot(float3(y_adj, u_adj, v_adj), kYUVToR);
    float g = dot(float3(y_adj, u_adj, v_adj), kYUVToG);
    float b = dot(float3(y_adj, u_adj, v_adj), kYUVToB);

    float3 rgb = float3(r, g, b);

    // --- HDR LOGIC ---
    if (hdrEnabled) {
        rgb = PQtoLinear(rgb);
        
        float luminance = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(luminance), rgb, hdrParams.saturation);

        if (hdrParams.gamma != 1.0) {
            rgb = pow(max(rgb, 0.0), float3(hdrParams.gamma));
        }
        
        float boost = max(hdrParams.boost, 0.1);
        rgb = (rgb / 100.0) * 1.6 * boost;

        rgb = rgb + float3(hdrParams.brightness);
    }
    
    return half4(half3(rgb), 1.0);
}
