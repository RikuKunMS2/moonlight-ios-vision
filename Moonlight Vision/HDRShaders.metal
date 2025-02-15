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

// YCbCr to RGB conversion
float3 ycbcr2rgb(float3 ycbcr) {
    // BT.2020 YCbCr to RGB matrix for 10-bit
    const float3x3 conversion = float3x3(
        float3(1.0,      0.0,          1.4746),
        float3(1.0,     -0.1645,      -0.5714),
        float3(1.0,      1.8814,       0.0)
    );
    
    // Adjust for video range (64-940 for Y, 64-960 for CbCr)
    float y = (ycbcr.x - (64.0/1023.0)) * (1023.0/(940.0-64.0));
    float cb = (ycbcr.y - (512.0/1023.0)) * (1023.0/(960.0-64.0));
    float cr = (ycbcr.z - (512.0/1023.0)) * (1023.0/(960.0-64.0));
    
    return clamp(conversion * float3(y, cb, cr), 0.0, 1.0);
}

// PQ EOTF (SMPTE ST 2084)
float3 PQ_EOTF(float3 color) {
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;
    
    float3 temp = pow(color, float3(1.0 / m2));
    float3 temp2 = max(temp - c1, 0.0);
    float3 temp3 = pow(temp2 / (c2 - c3 * temp), float3(1.0 / m1));
    
    return temp3 * 10000.0; // Convert to nits
}

float3 ycbcr2rgb_10bit(float3 ycbcr) {
    // v210 format uses video range [64, 940] for Y and [64, 960] for CbCr
    float y = (ycbcr.x - (64.0/1024.0)) / ((940.0-64.0)/1024.0);
    float cb = (ycbcr.y - (64.0/1024.0)) / ((960.0-64.0)/1024.0) - 0.5;
    float cr = (ycbcr.z - (64.0/1024.0)) / ((960.0-64.0)/1024.0) - 0.5;
    
    // BT.2020 coefficients for 10-bit video range
    const float Kb = 0.0593;
    const float Kr = 0.2627;
    
    // Convert to RGB
    float r = y + 2.0 * (1.0 - Kr) * cr;
    float b = y + 2.0 * (1.0 - Kb) * cb;
    float g = (y - Kr * r - Kb * b) / (1.0 - Kr - Kb);
    
    return clamp(float3(r, g, b), 0.0, 1.0);
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
    
    float y = yTexture.read(gid).r;
    uint2 cbcrCoord = gid / 2;
    float2 cbcr = cbcrTexture.read(cbcrCoord).rg;
    
    // Debug visualization
    bool showDebug = true;  // Toggle for debugging
    if (showDebug) {
        // Show raw values before conversion
        if (gid.x < output.get_width() / 4) {
            // Y component
            output.write(float4(y, y, y, 1.0), gid);
        } else if (gid.x < output.get_width() * 2/4) {
            // Cb component
            output.write(float4(cbcr.x, cbcr.x, cbcr.x, 1.0), gid);
        } else if (gid.x < output.get_width() * 3/4) {
            // Cr component
            output.write(float4(cbcr.y, cbcr.y, cbcr.y, 1.0), gid);
        } else {
            // Show converted RGB
            float3 rgb = ycbcr2rgb_10bit(float3(y, cbcr.x, cbcr.y));
            output.write(float4(rgb, 1.0), gid);
        }
        return;
    }
    
    // Normal processing
    float3 rgb = ycbcr2rgb_10bit(float3(y, cbcr.x, cbcr.y));
    float3 nits = PQ_EOTF(rgb);
    float3 mapped = nits / (nits + metadata.maxCLL);
    
    output.write(float4(mapped, 1.0), gid);
} 