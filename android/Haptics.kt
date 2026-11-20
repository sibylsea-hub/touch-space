// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// 安卓：按轻重调震动强度（未实测，照官方 API 写的思路代码）
val vibrator: Vibrator = if (Build.VERSION.SDK_INT >= 31)
    context.getSystemService(VibratorManager::class.java).defaultVibrator
else @Suppress("DEPRECATION") context.getSystemService(Vibrator::class.java)

// 按下：强度 ∝ 轻重（0–1）
fun tap(p: Float) {
    if (vibrator.hasAmplitudeControl()) {
        val amp = (40 + 215 * p).toInt().coerceIn(1, 255)
        vibrator.vibrate(VibrationEffect.createOneShot(20, amp))
    } else if (Build.VERSION.SDK_INT >= 29) {
        // 调不了强度：轻的用 tick，重的用 click
        vibrator.vibrate(VibrationEffect.createPredefined(if (p < 0.5f) VibrationEffect.EFFECT_TICK else VibrationEffect.EFFECT_CLICK))
    } else vibrator.vibrate(VibrationEffect.createOneShot((10 + 25 * p).toLong(), VibrationEffect.DEFAULT_AMPLITUDE))
}

// 抚的时候：每划过一段（比如 60dp）轻敲一下，强度跟着当下的轻重
fun stroke(travelledDp: Float, p: Float) { if (travelledDp > 60) tap(p * 0.6f) }
