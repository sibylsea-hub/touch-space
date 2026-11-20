// 安卓：在自定义 View 里记下每一笔（未实测，照官方 API 写的思路代码）
data class Sample(val x: Float, val y: Float, val t: Double, val p: Float)
class Stroke(val samples: MutableList<Sample>, var ended: Boolean = false)

private val strokes = mutableListOf<Stroke>()
private val active = mutableMapOf<Int, Stroke>()          // pointerId → 这根手指的一笔

private fun pressureOf(e: MotionEvent, i: Int): Float {
    // 有的机型 getPressure 是真压力，有的是按面积换算的；也可以用接触椭圆的长轴 touchMajor（像素）自己换算
    val major = e.getTouchMajor(i) / resources.displayMetrics.density   // 换成 dp
    val byArea = ((major / 2 - 12) / 32).coerceIn(0f, 1f)
    return maxOf(e.getPressure(i).coerceIn(0f, 1f), byArea)
}

override fun onTouchEvent(e: MotionEvent): Boolean {
    val t = e.eventTime / 1000.0
    when (e.actionMasked) {
        MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
            val i = e.actionIndex
            val s = Stroke(mutableListOf(Sample(e.getX(i), e.getY(i), t, pressureOf(e, i))))
            strokes += s; active[e.getPointerId(i)] = s
        }
        MotionEvent.ACTION_MOVE -> for (i in 0 until e.pointerCount) {
            val s = active[e.getPointerId(i)] ?: continue
            // 一帧里攒下的中间点（对应 iOS 的合并触摸）
            for (h in 0 until e.historySize)
                s.samples += Sample(e.getHistoricalX(i, h), e.getHistoricalY(i, h), e.getHistoricalEventTime(h) / 1000.0, pressureOf(e, i))
            s.samples += Sample(e.getX(i), e.getY(i), t, pressureOf(e, i))
        }
        MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_CANCEL -> {
            val i = e.actionIndex
            active.remove(e.getPointerId(i))?.ended = true
            if (active.isEmpty()) scheduleTranslate()   // 两秒没再摸就翻译这一批（规则同 translate.js）
        }
    }
    return true
}
