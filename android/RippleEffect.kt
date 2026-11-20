// 安卓 13+：直接给整个 View 挂 AGSL 着色器做水纹，不用截图（未实测，照官方 API 写的思路代码）
@RequiresApi(33)
class RippleEffect(private val target: View) {
    private val shader = RuntimeShader("""
        uniform shader content;      // View 本来的画面
        uniform float2 drops[8];     // 水滴位置（像素）
        uniform float ages[8];       // 每滴落下了多少秒（> 1.6 秒就当没有）
        uniform float dpr;
        half4 main(float2 p) {
            float2 disp = float2(0);
            for (int i = 0; i < 8; i++) {
                float age = ages[i];
                if (age < 0.0 || age > 1.6) continue;
                float lam = (22.0 + 18.0 * age) * dpr, w = lam * 0.55;
                float2 v = p - drops[i]; float r = length(v) + 0.001;
                float x = r - age * 150.0 * dpr;
                float env = exp(-x * x / (w * w)) * exp(-age * 2.2) / (1.0 + r / (140.0 * dpr));
                env *= smoothstep(0.0, 16.0 * dpr, r);
                disp += v / r * sin(x * 6.2831 / lam) * env;
            }
            return content.eval(p - disp * 10.0 * dpr);
        }
    """.trimIndent())

    // 每帧：更新水滴，重新挂上效果；水滴都散完了就把效果拿掉、不再刷新（省电）
    fun frame(drops: FloatArray, ages: FloatArray) {
        shader.setFloatUniform("drops", drops)
        shader.setFloatUniform("ages", ages)
        shader.setFloatUniform("dpr", target.resources.displayMetrics.density)
        val busy = ages.any { it in 0f..1.6f }
        target.setRenderEffect(if (busy) RenderEffect.createRuntimeShaderEffect(shader, "content") else null)
    }
}
