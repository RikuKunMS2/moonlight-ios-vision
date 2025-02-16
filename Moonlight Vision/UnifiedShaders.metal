#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// HDR metadata struct matching Swift side
struct HDRMetadata {
    float3 colorPrimaries[3];  // RGB primaries
    float2 whitePoint;         // D65 white point
    float maxLuminance;        // Peak brightness in nits
    float minLuminance;        // Min brightness in nits
    float maxCLL;             // Max content light level
    float maxFALL;            // Max frame average light level
};

// PQ EOTF (ST.2084)
float3 PQ_EOTF(float3 color) {
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;
    
    float3 temp = pow(color, float3(1.0 / m2));
    float3 temp2 = max(temp - c1, 0.0);
    float3 temp3 = pow(temp2 / (c2 - c3 * temp), float3(1.0 / m1));
    
    return temp3;
}

// Hable filmic tone mapping
float3 hable(float3 x) {
    const float A = 0.22, B = 0.30, C = 0.10, D = 0.20, E = 0.01, F = 0.30;
    return ((x*(A*x+C*B)+D*E)/(x*(A*x+B)+D*F)) - E/F;
}

vertex VertexOut unifiedVertexShader(uint vertexID [[vertex_id]]) {
    VertexOut out;
    
    // Generate fullscreen quad
    float2 uv = float2(float((vertexID << 1) & 2), float(vertexID & 2));
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.uv = uv;
    
    return out;
}

fragment float4 unifiedFragmentShader(VertexOut in [[stage_in]],
                                    texture2d<float> sourceTexture [[texture(0)]],
                                    constant HDRMetadata& metadata [[buffer(0)]],
                                    constant bool& hdrEnabled [[buffer(1)]]) {
    constexpr sampler textureSampler(coord::normalized,
                                   address::clamp_to_edge,
                                   filter::linear);
    
    float4 color = sourceTexture.sample(textureSampler, in.uv);
    
    if (hdrEnabled) {
        // Apply PQ EOTF and convert to nits
        float3 nits = PQ_EOTF(color.rgb) * metadata.maxLuminance;
        
        // Tone map to display range
        color.rgb = hable(nits / 1000.0);
    }
    
    return color;
}