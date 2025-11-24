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
    float boost;      // Luminance Boost / Gain
    float gamma;      // Gamma correction
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
    
    // SAFEGUARD: Ensure input never exceeds 1.0 or drops below 0.0
    float3 safePQ = clamp(pq, 0.0, 1.0);
    
    float3 N = pow(safePQ, 1.0 / m2);
    
    // Avoid division by zero singularity at N ~= 1.008
    float3 denominator = max(c2 - c3 * N, 0.0001);
    
    float3 L = pow(max((N - c1) / denominator, 0.0), 1.0 / m1);
    
    return L * 10000.0;
}

// BT.2020 to RGB Conversion Constants (Limited Range)
constant float3 kYUVToR = float3(1.0,  0.0000,  1.4746);
constant float3 kYUVToG = float3(1.0, -0.1645, -0.5714);
constant float3 kYUVToB = float3(1.0,  1.8814,  0.0000);

fragment half4 copyFragmentShaderYUV(CopyVertexOut in [[stage_in]],
                                    texture2d<float> luma_tex [[texture(0)]],
                                    texture2d<float> chroma_tex [[texture(1)]],
                                    constant bool& hdrEnabled [[buffer(0)]],
                                    constant HDRParams& hdrParams [[buffer(1)]])
{
    constexpr sampler colorSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    // 1. Sample Y and CbCr planes
    float y = luma_tex.sample(colorSampler, in.uv).r;
    float2 uv = chroma_tex.sample(colorSampler, in.uv).rg;

    // 2. Adjust for Limited Video Range (16-235 -> 0.0-1.0)
    float y_adj = max(y - 0.062745, 0.0);
    float u_adj = uv.r - 0.5;
    float v_adj = uv.g - 0.5;

    // 3. Convert YUV to RGB (BT.2020)
    float r = dot(float3(y_adj, u_adj, v_adj), kYUVToR);
    float g = dot(float3(y_adj, u_adj, v_adj), kYUVToG);
    float b = dot(float3(y_adj, u_adj, v_adj), kYUVToB);

    float3 rgb = float3(r, g, b);

    // --- HDR LOGIC ---
    if (hdrEnabled) {
        // [CRITICAL FIX]
        // Clamp RGB values BEFORE sending them to PQ Decoder.
        // Without this, values like 1.001 trigger a math singularity (Infinity/NaN)
        // which causes the white/cyan screen artifacts.
        rgb = clamp(rgb, 0.0, 1.0);
        
        // 4. Decode PQ Curve to Linear Light (Nits)
        rgb = PQtoLinear(rgb);
       
        // 5. Apply Saturation
        float luminance = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(luminance), rgb, hdrParams.saturation);

        // 6. Apply Gamma (Safe Power)
        if (hdrParams.gamma != 1.0) {
             rgb = pow(max(rgb, 0.0), float3(hdrParams.gamma));
        }
         
        // 7. Apply Boost & Brightness
        float boost = max(hdrParams.boost, 0.1);
        rgb = (rgb / 100.0) * 1.6 * boost;
        rgb = rgb + float3(hdrParams.brightness);
    }
    
    return half4(half3(rgb), 1.0);
}

// Keep the legacy RGB shader for fallback compatibility
fragment half4 copyFragmentShader(CopyVertexOut in [[stage_in]],
                                texture2d<half> in_tex,
                                constant bool& hdrEnabled [[buffer(0)]],
                                constant HDRParams& hdrParams [[buffer(1)]]) {
    constexpr sampler colorSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    half4 color = in_tex.sample(colorSampler, in.uv);
    float3 rgb = float3(color.rgb);
    
    if (hdrEnabled) {
        rgb = clamp(rgb, 0.0, 1.0); // Clamp here too
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
    
    return half4(half3(rgb), color.a);
}
