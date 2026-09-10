import Foundation

/// 运行时编译，省掉 metallib 的打包麻烦。
/// 脏污全部存在 GPU 纹理里，一个通道一种：
///   T0.r=油污 T0.g=积灰 T0.b=哈气 T0.a=咖啡渍
///   T1.r=墨渍 T1.g=水珠 T1.b=故障红 T1.a=水痕
///   T2.r=薄膜覆盖率
/// 生成 / 挥发 / 擦除全靠固定功能混合，不回读、不上传。
enum Shaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------- 通用

struct SpriteU {
    float4 rect;      // x,y,w,h（纹理像素）
    float4 tint;      // 写进各通道的值
    float4 shapeP;    // x=飞溅量 y=羽化(px) z=备用 w=备用
    float2 texSize;
    float  mode;      // 0 实心 1..6 六种笔法 7 刮板 8 水痕
    float  seed;
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
    float2 px;
};

vertex VOut sprite_vs(uint vid [[vertex_id]], constant SpriteU& u [[buffer(0)]]) {
    float2 corner = float2(float(vid & 1u), float(vid >> 1));
    float2 p = u.rect.xy + corner * u.rect.zw;
    VOut o;
    o.pos = float4(p.x / u.texSize.x * 2.0 - 1.0,
                   1.0 - p.y / u.texSize.y * 2.0, 0.0, 1.0);
    o.uv = corner;
    o.px = p;
    return o;
}

static inline float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}
static inline float hash21(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
static inline float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((float2(p3.x, p3.x) + float2(p3.y, p3.z)) * float2(p3.z, p3.y));
}
static inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
static inline float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) { v += a * vnoise(p); p *= 2.03; a *= 0.5; }
    return v;
}

// ---------------------------------------------------------------- 六种笔法

// 甩出去的小点，油污 / 墨渍 / 水珠共用
static inline float spatterField(float2 q, float seed, float amount) {
    if (amount <= 0.01) return 0.0;
    float2 g = q * 5.5;
    float2 cell = floor(g), f = fract(g) - 0.5;
    float2 jit = hash22(cell + seed) - 0.5;
    float d = length(f - jit * 0.85);
    float rad = 0.05 + hash11(dot(cell, float2(7.7, 3.1)) + seed) * 0.09;
    float keep = step(1.0 - clamp(amount / 14.0, 0.0, 0.6), hash21(cell * 1.7 + seed));
    float fall = smoothstep(2.4, 0.4, length(q));
    return smoothstep(rad, rad * 0.35, d) * keep * fall;
}

// 机械油污：几瓣叠在一起，边缘被噪声啃过
static inline float shapeLobes(float2 q, float seed) {
    float warp = 0.86 + 0.32 * fbm(q * 2.6 + seed * 3.7);
    float v = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float2 o = (hash22(float2(seed, fi)) - 0.5) * 0.62;
        float rr = 0.44 + hash11(seed + fi * 7.7) * 0.5;
        float d = length((q - o) / rr) * warp;
        v = max(v, smoothstep(1.0, 0.05, d) * (0.62 + 0.38 * hash11(seed + fi * 3.1)));
    }
    return v;
}

// 积灰：几乎看不见的雾 + 一层干燥的细颗粒
static inline float shapeSpeckle(float2 q, float seed, float spatter) {
    float r = length(q);
    float haze = smoothstep(1.0, 0.0, r) * 0.17;
    float2 g = q * (17.0 + spatter * 1.6);
    float2 cell = floor(g), f = fract(g) - 0.5;
    float2 jit = hash22(cell + seed) - 0.5;
    float d = length(f - jit * 0.7);
    float rad = 0.10 + hash11(dot(cell, float2(7.1, 3.7)) + seed) * 0.30;
    float keep = step(0.34, hash21(cell * 1.7 + seed));
    float fall = smoothstep(1.35, 0.05, r);
    return clamp(haze + smoothstep(rad, rad * 0.3, d) * keep * fall, 0.0, 1.0);
}

// 哈气：没有核心，全是软边
static inline float shapeSoft(float2 q, float seed) {
    float warp = 0.8 + 0.45 * fbm(q * 1.7 + seed * 2.1);
    float r = length(q) * warp;
    return smoothstep(1.05, 0.0, r) * 0.82;
}

// 咖啡渍：边缘一圈深、中间淡，圈是歪的
static inline float shapeRing(float2 q, float seed) {
    float ang = atan2(q.y, q.x);
    float wob = 1.0 + 0.07 * sin(ang * 3.0 + seed * 6.0) + 0.05 * sin(ang * 7.0 - seed * 3.0);
    float r = length(q) / wob;
    float rim  = smoothstep(0.70, 0.85, r) * smoothstep(1.02, 0.88, r);
    float wash = smoothstep(1.0, 0.0, r) * 0.30;
    // 杯子挪过留下的第二道环
    float2 q2 = (q - (hash22(float2(seed, 4.0)) - 0.5) * 0.5) / 0.62;
    float r2 = length(q2);
    float rim2 = smoothstep(0.72, 0.88, r2) * smoothstep(1.02, 0.9, r2) * 0.55;
    return clamp(max(rim * 0.95, rim2) + wash, 0.0, 1.0);
}

// 墨渍：实心核心甩出细触须
static inline float shapeSplat(float2 q, float seed) {
    float ang = atan2(q.y, q.x);
    float r = length(q);
    float core = 0.46 + 0.15 * sin(ang * 5.0 + seed * 9.0) + 0.09 * sin(ang * 9.0 - seed * 4.0);
    float v = smoothstep(core, core * 0.72, r);
    float arms = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float a0 = hash11(seed + fi * 2.3) * 6.28318;
        float len = 0.62 + hash11(seed + fi * 5.1) * 0.45;
        float da = abs(atan2(sin(ang - a0), cos(ang - a0)));
        float w = 0.10 * max(0.0, 1.0 - r / len);
        arms = max(arms, smoothstep(w, 0.0, da) * smoothstep(len, len * 0.45, r));
    }
    return clamp(max(v, arms * 0.9), 0.0, 1.0);
}

// 水珠：一颗颗分开的硬边水滴
static inline float shapeDrops(float2 q, float seed, float spatter) {
    float2 g = q * (4.6 + spatter * 0.28);
    float2 cell = floor(g), f = fract(g) - 0.5;
    float2 jit = hash22(cell + seed) - 0.5;
    float d = length(f - jit * 0.8);
    float rad = 0.15 + hash11(dot(cell, float2(5.3, 9.1)) + seed) * 0.28;
    float keep = step(0.40, hash21(cell * 2.3 + seed * 1.7));
    float fall = smoothstep(1.25, 0.08, length(q));
    return clamp(smoothstep(rad, rad * 0.8, d) * keep * fall, 0.0, 1.0);
}

// 刮板：矩形 + 羽化边
static inline float shapeEraser(float2 px, float4 rect, float feather) {
    float f = max(feather, 0.5);
    float2 lo = rect.xy + f;
    float2 hi = rect.xy + rect.zw - f;
    float2 d = min(px - lo, hi - px);
    return clamp(min(d.x, d.y) / f, 0.0, 1.0);
}

// 水痕：斜向的没擦匀的条纹
static inline float shapeStreaks(float2 px, float2 uv, float seed) {
    float w = fract((px.x + px.y * 0.36) / 11.0 + hash11(seed) * 3.0);
    float line = smoothstep(0.5, 0.06, abs(w - 0.5));
    float2 e = min(uv, 1.0 - uv);
    float edge = smoothstep(0.0, 0.08, min(e.x, e.y));
    return line * edge * (0.6 + 0.4 * vnoise(px * 0.05 + seed));
}

fragment float4 sprite_fs(VOut in [[stage_in]], constant SpriteU& u [[buffer(0)]]) {
    int mode = int(u.mode + 0.5);
    float2 q = in.uv * 2.0 - 1.0;
    float cov = 1.0;
    float sp = u.shapeP.x;

    if (mode == 1)      cov = max(shapeLobes(q, u.seed), spatterField(q, u.seed, sp));
    else if (mode == 2) cov = shapeSpeckle(q, u.seed, sp);
    else if (mode == 3) cov = shapeSoft(q, u.seed);
    else if (mode == 4) cov = shapeRing(q, u.seed);
    else if (mode == 5) cov = max(shapeSplat(q, u.seed), spatterField(q, u.seed, sp * 1.4));
    else if (mode == 6) cov = max(shapeDrops(q, u.seed, sp), spatterField(q, u.seed, sp * 0.6));
    else if (mode == 7) cov = shapeEraser(in.px, u.rect, u.shapeP.y);
    else if (mode == 8) cov = shapeStreaks(in.px, in.uv, u.seed);

    return u.tint * cov;
}

// ---------------------------------------------------------------- 合成

struct TypeStyle {
    float4 dark;   // 吸光色
    float4 lit;    // 散射色
    float4 rim;    // 边缘高光
    float4 w;      // x=不透明度倍率
};

struct CompU {
    TypeStyle ty[6];
    float4 streakColor;
    float2 res;        // 遮罩纹理尺寸（像素）
    float2 mouse;      // 同上坐标系，离屏时给很大的负数
    float  haloR;
    float  haloS;
    float  maxAlpha;
    float  filmLevel;
    float  faultPulse;
    float  flushY;     // 冲洗亮带位置，<0 表示没在冲
    float  time;
    float  primary;    // 薄膜算在哪一种头上
};

constexpr sampler linSampler(filter::linear, address::clamp_to_edge);

static inline float totalAt(texture2d<float> t0, texture2d<float> t1, float2 uv) {
    float4 a = t0.sample(linSampler, uv);
    float4 b = t1.sample(linSampler, uv);
    return a.r + a.g + a.b + a.a + b.r + b.g;
}

fragment float4 comp_fs(VOut in [[stage_in]],
                        texture2d<float> t0 [[texture(0)]],
                        texture2d<float> t1 [[texture(1)]],
                        texture2d<float> t2 [[texture(2)]],
                        constant CompU& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float2 px = uv * u.res;

    float4 a = t0.sample(linSampler, uv);
    float4 b = t1.sample(linSampler, uv);
    float film = t2.sample(linSampler, uv).r * u.filmLevel;

    // 干净的地方直接返回，省掉整套噪声。屏幕大部分时候是干净的。
    float any = a.r + a.g + a.b + a.a + b.r + b.g + b.b + b.a + film;
    if (any < 0.004) return float4(0.0);

    float th[6];
    th[0] = a.r; th[1] = a.g; th[2] = a.b; th[3] = a.a; th[4] = b.r; th[5] = b.g;
    int pri = clamp(int(u.primary + 0.5), 0, 5);
    th[pri] += film;

    // 鼠标周围让一圈出来，正在看的地方总是能看清
    float halo = 1.0;
    if (u.haloR > 1.0 && u.haloS > 0.0) {
        float d = distance(px, u.mouse);
        halo = 1.0 - u.haloS * (1.0 - smoothstep(0.0, u.haloR, d));
    }

    float4 outc = float4(0.0);   // 预乘
    float3 rimCol = float3(0.0);
    float  rimW = 0.0;

    for (int i = 0; i < 6; i++) {
        float t = clamp(th[i] * halo, 0.0, 1.0);
        if (t <= 0.003) continue;
        float n = smoothstep(0.26, 0.74, fbm(px / 46.0 + float2(float(i) * 13.7, float(i) * 7.3)));
        float3 base = mix(u.ty[i].dark.rgb, u.ty[i].lit.rgb, n);
        float al = clamp(t * u.maxAlpha * u.ty[i].w.x, 0.0, 1.0);
        outc.rgb += base * al * (1.0 - outc.a);
        outc.a   += al * (1.0 - outc.a);
        rimCol += u.ty[i].rim.rgb * t;
        rimW += t;
    }

    // 边缘浮雕：让每块脏有厚度，水珠自动镶亮边
    if (rimW > 0.001) {
        float2 texel = 1.0 / u.res;
        float here = totalAt(t0, t1, uv);
        float up   = totalAt(t0, t1, uv - texel * 2.0);
        float rimAmt = clamp((up - here) * 1.7, 0.0, 1.0) * clamp(rimW * 2.0, 0.0, 1.0);
        if (rimAmt > 0.002) {
            float3 rc = rimCol / max(rimW, 0.0001);
            float ra = rimAmt * 0.55 * halo;
            outc.rgb += rc * ra * (1.0 - outc.a);
            outc.a   += ra * (1.0 - outc.a);
        }
    }

    // 水痕
    float st = b.a * halo;
    if (st > 0.003) {
        float sa = clamp(st * 0.55, 0.0, 1.0);
        outc.rgb += u.streakColor.rgb * sa * (1.0 - outc.a);
        outc.a   += sa * (1.0 - outc.a);
    }

    // 故障红：会呼吸，不挥发
    float fa = b.b;
    if (fa > 0.003) {
        float pulse = 0.55 + 0.25 * sin(u.faultPulse * 3.1);
        float3 red = float3(0.36, 0.075, 0.05) + float3(0.42, 0.06, 0.03) * pulse;
        float al = clamp(fa * u.maxAlpha * 1.05, 0.0, 1.0);
        outc.rgb += red * al * (1.0 - outc.a);
        outc.a   += al * (1.0 - outc.a);
    }

    // 冲洗亮带
    if (u.flushY >= 0.0) {
        float d = (u.flushY - px.y) / max(u.res.y * 0.16, 1.0);
        if (d >= 0.0 && d <= 1.0) {
            float band = pow(1.0 - d, 3.0);
            float ba = band * 0.42;
            outc.rgb += float3(0.78, 0.93, 0.98) * ba * (1.0 - outc.a);
            outc.a   += ba * (1.0 - outc.a);
        }
    }

    return clamp(outc, 0.0, 1.0);
}
"""#
}
