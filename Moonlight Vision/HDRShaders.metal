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
    // Convert 10-bit values to normalized float
    float y = ycbcr.x * (1023.0/1024.0);  // Scale 10-bit Y
    float cb = ycbcr.y * (1023.0/1024.0); // Scale 10-bit Cb
    float cr = ycbcr.z * (1023.0/1024.0); // Scale 10-bit Cr
    
    // v210 uses video range
    y = (y - 64.0/1023.0) * (1023.0/(940.0-64.0));   // Video range [64, 940]
    cb = (cb - 512.0/1023.0) * (1023.0/(960.0-64.0)); // Video range [64, 960]
    cr = (cr - 512.0/1023.0) * (1023.0/(960.0-64.0)); // Video range [64, 960]
    
    // BT.2020 conversion matrix
    const float3x3 bt2020 = float3x3(
        float3( 1.0,  0.0,      1.4746),
        float3( 1.0, -0.1645,  -0.5714),
        float3( 1.0,  1.8814,   0.0)
    );
    
    return clamp(bt2020 * float3(y, cb, cr), 0.0, 1.0);
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
    
    // Read 10-bit Y and CbCr values
    float y = yTexture.read(gid).r;
    uint2 cbcrCoord = gid / 2;
    float2 cbcr = cbcrTexture.read(cbcrCoord).rg;
    
    // Debug visualization - show raw 10-bit values
    bool showDebug = true;
    if (showDebug) {
        if (gid.x < output.get_width() / 3) {
            // Show Y (scaled to visible range)
            float y_scaled = (y - 64.0/1023.0) / (940.0/1023.0 - 64.0/1023.0);
            output.write(float4(y_scaled, y_scaled, y_scaled, 1.0), gid);
        } else if (gid.x < (output.get_width() * 2) / 3) {
            // Show Cb (centered around 0.5)
            float cb_scaled = (cbcr.x - 512.0/1023.0) / (960.0/1023.0 - 64.0/1023.0) + 0.5;
            output.write(float4(cb_scaled, cb_scaled, cb_scaled, 1.0), gid);
        } else {
            // Show Cr (centered around 0.5)
            float cr_scaled = (cbcr.y - 512.0/1023.0) / (960.0/1023.0 - 64.0/1023.0) + 0.5;
            output.write(float4(cr_scaled, cr_scaled, cr_scaled, 1.0), gid);
        }
        return;
    }
    
    // Convert to RGB
    float3 rgb = ycbcr2rgb_10bit(float3(y, cbcr));
    
    // Apply HDR processing
    float3 nits = PQ_EOTF(rgb);
    float3 mapped = nits / (nits + metadata.maxCLL);
    
    output.write(float4(mapped, 1.0), gid);
} 