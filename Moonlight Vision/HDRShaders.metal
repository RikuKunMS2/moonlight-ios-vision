#include <metal_stdlib>
using namespace metal;

struct HDRMetadata {
    float colorPrimariesMatrix0[3];  // 12 bytes (3 floats)
    float _pad0;                     // 4 bytes padding
    float colorPrimariesMatrix1[3];  // 12 bytes (3 floats)
    float _pad1;                     // 4 bytes padding
    float colorPrimariesMatrix2[3];  // 12 bytes (3 floats)
    float _pad2;                     // 4 bytes padding
    float whitePoint[2];            // 8 bytes (2 floats)
    float maxLuminance;             // 4 bytes
    float minLuminance;             // 4 bytes
    float maxCLL;                   // 4 bytes
    float maxFALL;                  // 4 bytes
};

// PQ EOTF might need adjustment
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

kernel void hdrProcessing(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> cbcrTexture [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant HDRMetadata& metadata [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    // YCbCr to RGB conversion
    float y = yTexture.read(gid).r;
    uint2 cbcrCoord = gid / 2;
    float2 cbcr = cbcrTexture.read(cbcrCoord).rg;
    float cb = cbcr.x - 0.5;
    float cr = cbcr.y - 0.5;
    
    float3 rgb = float3(
        y + 1.4746 * cr,
        y - 0.1646 * cb - 0.5714 * cr,
        y + 1.8814 * cb
    );
    
    rgb = clamp(rgb, 0.0, 1.0);
    
    // Apply PQ EOTF and tone mapping that worked
    float3 nits = PQ_EOTF(rgb) * metadata.maxLuminance;

    float3 mapped = hable(nits / 1000.0);
    
    output.write(float4(mapped, 1.0), gid);
}
