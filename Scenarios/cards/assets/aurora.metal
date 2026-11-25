#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Slow bands of green and violet light drifting over a night sky.
[[ stitchable ]] half4 aurora(float2 position, half4 color, float2 size, float time) {
    float2 uv = position / size;
    float glow = 0.0;
    for (int band = 0; band < 3; band++) {
        float offset = float(band) * 1.7;
        float wave = 0.35 + 0.12 * sin(uv.x * (3.0 + offset) + time * (0.4 + 0.1 * offset))
                          + 0.05 * sin(uv.x * 11.0 - time * 0.7 + offset);
        glow += exp(-pow((uv.y - wave) * 9.0, 2.0)) * (0.6 - 0.15 * float(band));
    }
    float3 sky = mix(float3(0.01, 0.02, 0.06), float3(0.03, 0.05, 0.14), uv.y);
    float3 light = mix(float3(0.15, 0.95, 0.55), float3(0.55, 0.3, 0.95), uv.x);
    return half4(half3(sky + light * glow), 1.0h) * color.a;
}
