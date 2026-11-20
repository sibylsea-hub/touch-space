// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// 网页：用 Pointer Events 记下每一笔（多指、鼠标、触控笔都走这一套）
const strokes = []; const active = new Map(); let timer = null;

function pressureOf(e) {
  if (e.pointerType === 'pen' && e.pressure > 0) return Math.min(1, e.pressure);       // 触控笔：真压力
  if (e.pointerType === 'touch' && (e.width > 1 || e.height > 1))                      // 手指：按接触面积估
    return Math.min(1, Math.max(0, (Math.max(e.width, e.height) / 2 - 12) / 32));
  return 0.3;                                                                          // 拿不到就当「轻轻」
}

el.style.touchAction = 'none';   // 不让浏览器拿去滚动、缩放
el.addEventListener('pointerdown', e => {
  el.setPointerCapture(e.pointerId);
  clearTimeout(timer);
  const t = e.timeStamp / 1000, p = pressureOf(e);
  const stroke = { samples: [{ x: e.offsetX, y: e.offsetY, t, p }], start: t, end: t, ended: false };
  strokes.push(stroke); active.set(e.pointerId, stroke);
});
el.addEventListener('pointermove', e => {
  const s = active.get(e.pointerId); if (!s) return;
  const t = e.timeStamp / 1000, last = s.samples[s.samples.length - 1];
  if (Math.hypot(e.offsetX - last.x, e.offsetY - last.y) < 1.5) return;   // 几乎没动的点不记
  s.samples.push({ x: e.offsetX, y: e.offsetY, t, p: pressureOf(e) }); s.end = t;
});
const up = e => {
  const s = active.get(e.pointerId); if (!s) return;
  s.end = e.timeStamp / 1000; s.ended = true; active.delete(e.pointerId);
  // 所有手指离开、两秒没再摸：这一批交给翻译
  if (!active.size) timer = setTimeout(() => {
    const text = TouchTranslate.describe(strokes.splice(0), { w: el.clientWidth, h: el.clientHeight }, 'screen');
    // → 拼进消息 / POST 给 MCP 服务 / 放进剪贴板
  }, 2000);
};
el.addEventListener('pointerup', up); el.addEventListener('pointercancel', up);
