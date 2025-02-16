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

// BT.2020 constants
constant float Kr = 0.2627;
constant float Kb = 0.0593;
constant float Kg = 1.0 - Kr - Kb;

// Video range scale factors for 10-bit
constant float Y_RANGE_MIN = 64.0 / 1023.0;    // 64 in 10-bit space
constant float Y_RANGE_MAX = 940.0 / 1023.0;   // 940 in 10-bit space
constant float C_RANGE_MIN = 64.0 / 1023.0;    // 64 in 10-bit space
constant float C_RANGE_MAX = 960.0 / 1023.0;   // 960 in 10-bit space

float3 ycbcr2rgb_bt2020(float3 ycbcr) {
    // For full range 10-bit, we don't need to scale Y
    float y = ycbcr.x;
    
    // For full range, Cb and Cr are centered at 0.5
    float cb = ycbcr.y - 0.5;
    float cr = ycbcr.z - 0.5;
    
    // BT.2020 conversion matrix for full range
    const float3x3 bt2020 = float3x3(
        float3( 1.0,  0.0,      1.4746),
        float3( 1.0, -0.1646,  -0.5714),
        float3( 1.0,  1.8814,   0.0)
    );
    
    // Apply conversion
    float3 rgb = bt2020 * float3(y, cb, cr);
    
    // For HDR, we might want to apply the PQ EOTF after clamping
    rgb = clamp(rgb, 0.0, 1.0);
    
    // Debug: Split screen to show stages
    if (any(rgb != clamp(rgb, 0.0, 1.0))) {
        return float3(1.0, 0.0, 0.0);  // Show clipped pixels in red
    }
    
    return rgb;
}

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
    
    return temp3 * 10000.0; // Maybe adjust this scaling factor
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
    float3 nits = PQ_EOTF(rgb);
    float maxNits = 1000.0;  // metadata seems not to help with visionPro
    float3 mapped = nits / (nits + maxNits);
    
    output.write(float4(mapped, 1.0), gid);
}
