#version 460 core
// The frost on a glass surface: a still, per-pixel grain of light and dark specks, drawn over
// the surface at a few percent (glass.dart). Static: it is the texture of the ice, not noise.
#include <flutter/runtime_effect.glsl>

precision mediump float;

uniform float uStrength;

out vec4 fragColor;

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void main() {
    float n = hash(floor(FlutterFragCoord().xy) * 0.917 + 3.3) - 0.5;
    float alpha = abs(n) * 2.0 * uStrength;
    fragColor = n > 0.0 ? vec4(alpha, alpha, alpha, alpha) : vec4(0.0, 0.0, 0.0, alpha);
}
