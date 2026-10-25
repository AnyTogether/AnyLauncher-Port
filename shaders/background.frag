#version 460 core
// The themes' animated backgrounds: the GLSL form of the macOS launcher's Metal shader
// (BackgroundRenderer.swift), the same looks and the same palette uniforms.
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform float uTime;
uniform float uTheme;
uniform vec3 uDeep;
uniform vec3 uMiddle;
uniform vec3 uBright;

out vec4 fragColor;

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

vec2 hash2(vec2 p) { return vec2(hash(p), hash(p + 17.17)); }

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int octave = 0; octave < 5; octave++) {
        value += amplitude * noise(p);
        p = p * 2.03 + 11.7;
        amplitude *= 0.5;
    }
    return value;
}

// Drifting soft discs of light; rate moves them upwards.
float bokeh(vec2 p, float time, float cells, float rate, float seed) {
    vec2 grid = p * cells;
    grid.y -= time * rate;
    vec2 cell = floor(grid);
    float light = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 here = cell + vec2(float(x), float(y));
            vec2 random = hash2(here + seed);
            vec2 center = here + 0.5 + 0.38 * sin(random * 6.2831 + time * (0.15 + 0.2 * random.yx));
            float radius = mix(0.06, 0.24, random.x * random.x);
            float distance = length(grid - center);
            float twinkle = 0.55 + 0.45 * sin(time * (0.4 + random.y) + random.x * 40.0);
            float present = step(0.55, hash(here + seed * 3.1));
            light += present * twinkle * smoothstep(radius, radius * 0.25, distance) * (0.35 + 0.65 * random.y);
        }
    }
    return light;
}

vec3 cosmic(vec2 uv, float aspect, float time) {
    vec3 color = mix(uMiddle * 1.15, uDeep, smoothstep(0.0, 1.0, uv.y * 0.85 + 0.08));
    color += uBright * 0.28 * exp(-2.8 * length(vec2((uv.x - 0.8) * aspect, uv.y - 0.08)));
    // Ribbons of light flowing across the lower half, as on the console's home screen.
    for (int band = 0; band < 6; band++) {
        float b = float(band);
        float center = 0.56 + 0.028 * b
            + 0.075 * sin(uv.x * (1.4 + 0.22 * b) + time * (0.10 + 0.021 * b) + b * 1.9)
            + 0.03 * sin(uv.x * 4.1 - time * 0.12 + b * 3.1);
        float distance = abs(uv.y - center);
        float core = 0.0016 / (distance + 0.0028);
        float haze = exp(-distance * 14.0);
        float fade = smoothstep(-0.15, 0.4, uv.x) * smoothstep(1.2, 0.6, uv.x);
        float pulse = 0.75 + 0.25 * sin(time * 0.3 + b * 1.7 + uv.x * 2.0);
        vec3 tint = mix(uBright, vec3(0.85, 0.92, 1.0), 0.25 + 0.1 * b);
        color += tint * (core * 0.16 + haze * 0.1) * fade * pulse;
    }
    vec2 p = vec2(uv.x * aspect, uv.y);
    color += uBright * 0.22 * bokeh(p, time, 5.0, 0.012, 1.0);
    color += vec3(0.9, 0.95, 1.0) * 0.14 * bokeh(p, time * 1.3, 11.0, 0.02, 7.0);
    return color;
}

vec3 aurora(vec2 uv, float aspect, float time) {
    vec3 color = mix(uDeep * 1.8, uDeep * 0.7, uv.y);
    vec2 p = vec2(uv.x * aspect, uv.y);
    for (int layer = 0; layer < 3; layer++) {
        float l = float(layer);
        float sway = fbm(vec2(p.x * 0.7 + l * 3.7 + time * 0.02, time * 0.03 + l));
        float center = 0.30 + 0.09 * l + 0.36 * (sway - 0.5) + 0.05 * sin(p.x * 1.7 + time * 0.08 + l * 2.0);
        float thickness = 6.0 + 2.0 * l + 2.5 * sin(p.x * 1.3 + time * 0.05 + l);
        float below = uv.y - center;
        float curtain = exp(-below * below * thickness * thickness) * smoothstep(-0.35, 0.0, below + 0.12);
        float rays = smoothstep(0.15, 0.95, noise(vec2(p.x * 16.0 + l * 7.0, time * 0.18 + p.x * 0.5)));
        float glow = curtain * (0.45 + 0.55 * rays);
        vec3 tint = mix(uBright, mix(vec3(0.35, 0.55, 1.0), vec3(0.75, 0.4, 1.0), l * 0.5), smoothstep(-0.05, 0.12, -below));
        color += tint * glow * (0.62 - 0.14 * l);
    }
    vec2 starCell = floor(p * 150.0);
    float star = step(0.9965, hash(starCell)) * (0.55 + 0.45 * sin(time * 1.6 + hash(starCell + 3.0) * 30.0));
    vec2 local = fract(p * 150.0) - 0.5;
    color += star * smoothstep(0.35, 0.0, length(local)) * smoothstep(0.8, 0.1, uv.y) * 0.9;
    color += uMiddle * 0.45 * smoothstep(0.6, 1.0, uv.y) * (0.6 + 0.4 * fbm(vec2(p.x * 1.5, time * 0.03)));
    return color;
}

vec3 sunset(vec2 uv, float aspect, float time) {
    vec3 top = uDeep * 1.4;
    vec3 middle = uMiddle;
    vec3 low = mix(uBright, vec3(1.0, 0.42, 0.38), 0.45) * 0.85;
    vec3 color = mix(top, middle, smoothstep(0.0, 0.6, uv.y));
    color = mix(color, low, smoothstep(0.5, 1.1, uv.y));
    vec2 p = vec2(uv.x * aspect, uv.y);
    for (int blob = 0; blob < 6; blob++) {
        float b = float(blob);
        vec2 center = vec2((0.15 + 0.16 * b) * aspect + 0.14 * sin(time * (0.05 + 0.013 * b) + b * 2.0),
                           0.5 + 0.24 * sin(time * (0.04 + 0.01 * b) + b * 1.3));
        float radius = 0.2 + 0.07 * sin(b * 4.1);
        float light = exp(-dot(p - center, p - center) / (radius * radius));
        color += mix(uBright, vec3(1.0, 0.35, 0.6), fract(b * 0.37)) * light * 0.2;
    }
    color += mix(uBright, vec3(1.0, 0.8, 0.6), 0.4) * 0.22 * exp(-abs(uv.y - 0.76) * 5.0) * (0.85 + 0.15 * sin(uv.x * 2.4 + time * 0.15));
    color += vec3(1.0, 0.85, 0.7) * 0.1 * bokeh(p, time, 7.0, -0.01, 3.0);
    return color;
}

// Glass: cold light behind frosted ice. Large soft fields of glacier blue, teal and a little
// periwinkle drift very slowly, two faint diagonal streaks of refracted light cross them, and a
// still frost grain (added in main) sits over it all. Kept dark: white text must read on the
// glass surfaces drawn over any pixel of it (see test/ui/glass_test.dart).
float field(vec2 p, vec2 center, float radius) {
    vec2 d = p - center;
    return exp(-dot(d, d) / (radius * radius));
}

vec3 glass(vec2 uv, float aspect, float time) {
    vec2 p = vec2(uv.x * aspect, uv.y);
    float t = time * 0.035;
    vec3 glacier = vec3(0.20, 0.50, 0.70);
    vec3 teal = vec3(0.07, 0.40, 0.44);
    vec3 periwinkle = vec3(0.36, 0.38, 0.80);
    // Deep at the left and the bottom, where the words sit; lit towards the upper right.
    vec3 color = mix(uMiddle * 0.30, uDeep * 0.75, smoothstep(0.0, 1.0, uv.y * 0.75 + (1.0 - uv.x) * 0.35));
    // A slow warp, so the fields' edges never look like circles.
    vec2 warp = vec2(fbm(p * 0.8 + vec2(t * 0.6, 3.1)), fbm(p * 0.8 + vec2(7.4, -t * 0.5))) - 0.5;
    vec2 q = p + warp * 0.5;
    color += glacier * 0.74 * field(q, vec2(aspect * (0.70 + 0.06 * sin(t * 0.7)), 0.30 + 0.06 * cos(t * 0.5)), 0.50);
    color += teal * 0.45 * field(q, vec2(aspect * (0.40 + 0.08 * cos(t * 0.6 + 1.3)), 0.62 + 0.05 * sin(t * 0.8)), 0.42);
    color += periwinkle * 0.26 * field(q, vec2(aspect * (0.22 + 0.06 * sin(t * 0.45 + 2.0)), 0.20 + 0.06 * sin(t * 0.55)), 0.36);
    color += uBright * 0.10 * field(q, vec2(aspect * (0.92 + 0.04 * cos(t * 0.9)), 0.05), 0.30);
    // The ice itself: a still mottling, as of frost on the far side of the pane.
    color *= 0.90 + 0.20 * fbm(p * 2.6 + 1.7);
    // Two streaks of light refracted through the pane's edge: soft bands, cyan on one side and
    // periwinkle on the other, barely moving.
    float diagonal = uv.x * aspect * 0.55 + uv.y;
    for (int streak = 0; streak < 2; streak++) {
        float s = float(streak);
        float center = 0.78 + 0.62 * s + 0.05 * sin(t * (0.4 + 0.15 * s) + s * 2.4);
        float width = 0.10 - 0.035 * s;
        float d = (diagonal - center) / width;
        float along = smoothstep(-0.05, 0.4, uv.y) * smoothstep(1.1, 0.45, uv.y);
        float band = exp(-d * d) * along;
        float cold = exp(-(d + 0.9) * (d + 0.9) * 2.5) * along;
        float warm = exp(-(d - 0.9) * (d - 0.9) * 2.5) * along;
        float core = exp(-d * d * 9.0) * along;
        color += vec3(0.78, 0.92, 1.0) * (band * (0.06 - 0.02 * s) + core * (0.05 - 0.015 * s));
        color += vec3(0.30, 0.85, 1.0) * cold * 0.035 + periwinkle * warm * 0.03;
    }
    return color;
}

void main() {
    vec2 position = FlutterFragCoord().xy;
    float aspect = uSize.x / max(uSize.y, 1.0);
    vec2 uv = position / uSize;
    float time = uTime;
    if (uTheme > 2.5) {
        vec3 ice = glass(uv, aspect, time);
        vec2 middle = (uv - vec2(0.5, 0.45)) * vec2(aspect, 1.0);
        ice *= 1.0 - 0.5 * smoothstep(0.3, 1.2, length(middle));
        ice = ice / (1.0 + ice * 0.5);
        // Frost: a grain that stays put (per pixel, not per frame), so it reads as the texture
        // of the ice rather than noise.
        ice += (hash(floor(position) * 0.731 + 5.17) - 0.5) / 255.0 * 5.0;
        fragColor = vec4(ice, 1.0);
        return;
    }
    vec3 color = uTheme > 1.5 ? sunset(uv, aspect, time) : (uTheme > 0.5 ? aurora(uv, aspect, time) : cosmic(uv, aspect, time));
    vec2 centered = (uv - 0.5) * vec2(aspect, 1.0);
    color *= 1.0 - 0.45 * smoothstep(0.35, 1.25, length(centered));
    color = color / (1.0 + color * 0.35);
    color += (hash(position + fract(time) * 91.0) - 0.5) / 255.0 * 2.0;
    fragColor = vec4(color, 1.0);
}
