// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// 网页：WebGL 全屏着色器（水纹 / 皮肤）。手指、水滴的位置每帧经 uniform 传进来；整页内容事先画进纹理 uTex。
const fs = `
precision highp float;
uniform sampler2D uTex; uniform vec2 uRes; uniform float uTime, uMode, uDpr, uAmp;
uniform vec4 uDrops[${MAX_DROPS}];   // 水纹：x, y, 起始时刻, 强度
uniform vec4 uF[${MAX_F}];           // 皮肤：x, y, 深度, 暖
uniform vec2 uO[${MAX_F}];           // 皮肤：被手指拖着走的位移
uniform vec3 uWarm;
void main(){
  vec2 p = gl_FragCoord.xy, s = p; vec3 add = vec3(0.); float mul = 1., warm = 0.;
  if (uMode < .5) {
    vec2 disp = vec2(0.); float light = 0.;
    for (int i = 0; i < ${MAX_DROPS}; i++) {
      vec4 d = uDrops[i]; float age = uTime - d.z;
      if (d.w <= 0. || age < 0. || age > 1.6) continue;
      float lam = (22. + 18. * age) * uDpr, w = lam * .55;
      vec2 v = p - d.xy; float r = length(v) + .001; float x = r - age * 150. * uDpr;
      float env = exp(-x * x / (w * w)) * exp(-age * 2.2) * d.w / (1. + r / (140. * uDpr));
      env *= smoothstep(0., 16. * uDpr, r);
      float ph = x * 6.2831 / lam; disp += v / r * sin(ph) * env; light += cos(ph) * env;
    }
    s = p - disp * 10. * uDpr * uAmp; add = vec3(light * .06 * uAmp);
  } else {
    vec2 L = normalize(vec2(-.55, .8));
    for (int i = 0; i < ${MAX_F}; i++) {
      vec4 f = uF[i];
      if (abs(f.z) < 1e-4 && dot(uO[i], uO[i]) < 1e-4) continue;
      float R = (34. + 8. * f.w) * uDpr; vec2 v = p - f.xy; float r2 = dot(v, v);
      float fa = exp(-r2 / (R * R)), fb = exp(-r2 / (R * R * 1.6));
      s += v * f.z * .85 * fa * uAmp - uO[i] * fb * uAmp;
      vec2 g = v / R * 2. * f.z * fa;
      add += vec3(dot(g, L) * .16 * uAmp); mul *= 1. - .18 * max(f.z, 0.) * fa; warm += f.w * max(f.z, 0.) * fa;
    }
  }
  vec3 col = texture2D(uTex, clamp(s / uRes, vec2(0.), vec2(1.))).rgb * mul + add;
  gl_FragColor = vec4(mix(col, uWarm, clamp(warm * .16, 0., .32)), 1.);
}`;
