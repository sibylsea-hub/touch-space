// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// 触感空间的着色器（全屏滤镜）。
//
// 进空间前截的聊天页是一张纹理，`touch_filter_fragment` 按手指算每个像素该从截图的哪里取色。
// 和 web/touch-surface.js 里的 GLSL 是同一套，常数照搬。与草图的差别只有坐标系：
// 草图用 gl_FragCoord（左下原点、y 向上），这里用 Metal 的片元坐标（左上原点、y 向下），所以
// - 手指、水滴的位置直接传像素坐标，不做 `H - y` 翻转；皮肤的拖拽位移 y 也不取反；
// - 皮肤的光照方向 (-.55, .8) 写成 (-.55, -.8)。
//
// 统一参数 `u` 是一串 float4，下标与 Swift 侧 `TouchFilter.uniforms` 一一对应（改一边必须改另一边）：
//   u[0] = 画布像素宽高、时间（秒）、模式（0 水纹 / 1 皮肤）
//   u[1] = 渲染缩放（草图的 uDpr）、幅度、皮肤范围倍数（调参面板，1 = 出厂）、0
//   u[2] = 画布在截图里的 UV 子矩形：原点 xy、尺寸 zw
//   u[3] = 暖色 rgb；u[4] = 空着
//   u[5 + i]  = 第 i 滴水：x、y（像素）、起始时刻、强度（40 滴）
//   u[45 + i] = 第 i 根手指：x、y（像素）、深度 / 吸力、暖（5 根）
//   u[50 + i] = 第 i 根手指被拖着走的位移 x、y（像素）

#include <metal_stdlib>
using namespace metal;

constant int kTouchFilterDrops = 40;
constant int kTouchFilterFingers = 5;
constant int kTouchFilterDropBase = 5;
constant int kTouchFilterFingerBase = 45;
constant int kTouchFilterOffsetBase = 50;

struct TouchVOut {
    float4 position [[position]];
    float2 uv;
};

vertex TouchVOut touch_vertex(uint vid [[vertex_id]]) {
    // 一个盖满屏幕的大三角形。uv 左上为原点（与 pt 坐标同向）。
    float2 xy = float2(float((vid << 1) & 2), float(vid & 2));
    TouchVOut o;
    o.position = float4(xy * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(xy.x, 1.0 - xy.y);
    return o;
}

fragment float4 touch_filter_fragment(TouchVOut in [[stage_in]],
                                           texture2d<float> page [[texture(0)]],
                                           sampler smp [[sampler(0)]],
                                           constant float4 *u [[buffer(0)]]) {
    float2 res = u[0].xy;
    float time = u[0].z, mode = u[0].w;
    float dpr = u[1].x, amp = u[1].y, skinSize = u[1].z;
    float3 warmColor = u[3].rgb;

    float2 p = in.position.xy, s = p;
    float3 add = float3(0.0);
    float mul = 1.0, warm = 0.0;
    if (mode < 0.5) {
        float2 disp = float2(0.0);
        float light = 0.0;
        // 一滴只起一两道圈：包络比波长窄，圈往外走、变宽、变淡。
        for (int i = 0; i < kTouchFilterDrops; i++) {
            float4 d = u[kTouchFilterDropBase + i];
            float age = time - d.z;
            // 缩小过（水纹太大会扫过整块屏幕）：原来圈以 300pt/s 走 2.6 秒、能扫过整块屏幕。
            // 现在 150pt/s、1.6 秒散完、衰减更快、波长更短，圈大约在指尖外一两百 pt 内就淡掉。
            if (d.w <= 0.0 || age < 0.0 || age > 1.6) continue;
            float lam = (22.0 + 18.0 * age) * dpr, w = lam * 0.55;
            float2 v = p - d.xy;
            float r = length(v) + 0.001;
            float x = r - age * 150.0 * dpr;
            float env = exp(-x * x / (w * w)) * exp(-age * 2.2) * d.w / (1.0 + r / (140.0 * dpr));
            env *= smoothstep(0.0, 16.0 * dpr, r);
            float ph = x * 6.2831 / lam;
            disp += v / r * sin(ph) * env;
            light += cos(ph) * env;
        }
        s = p - disp * 10.0 * dpr * amp;
        add = float3(light * 0.06 * amp);
    } else {
        const float2 L = normalize(float2(-0.55, -0.8));
        for (int i = 0; i < kTouchFilterFingers; i++) {
            float4 f = u[kTouchFilterFingerBase + i];
            float2 o = u[kTouchFilterOffsetBase + i].xy;
            if (abs(f.z) < 1e-4 && dot(o, o) < 1e-4) continue;
            // 真机上调小过（变形面积要小一些、跟着手指）：
            // 凹陷 58→34pt（按久了 +18→+8），被拖的那圈 R²×3.2→×1.6（≈104pt→43pt）。
            // 高斯在 2R 处才淡到看不出，所以 34pt 大约是「指腹边上再露出一圈」，不会整块藏在手指底下。
            float R = (34.0 + 8.0 * f.w) * dpr * skinSize;
            float2 v = p - f.xy;
            float r2 = dot(v, v);
            float fa = exp(-r2 / (R * R)), fb = exp(-r2 / (R * R * 1.6));
            s += v * f.z * 0.85 * fa * amp - o * fb * amp;
            float2 g = v / R * 2.0 * f.z * fa;
            add += float3(dot(g, L) * 0.16 * amp);
            mul *= 1.0 - 0.18 * max(f.z, 0.0) * fa;
            warm += f.w * max(f.z, 0.0) * fa;
        }
    }
    float2 uv = clamp(s / res, float2(0.0), float2(1.0));
    uv = u[2].xy + uv * u[2].zw;
    float3 col = page.sample(smp, uv).rgb * mul + add;
    col = mix(col, warmColor, clamp(warm * 0.16, 0.0, 0.32));
    return float4(col, 1.0);
}

