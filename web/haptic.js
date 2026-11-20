// ---------- 震动：网页只能控时长（安卓 Chrome 有，iOS Safari 没有） ----------
const buzz = ms => { try { navigator.vibrate && navigator.vibrate(ms); } catch (_) {} };

// 按下那一下：越重越长
buzz(Math.round(8 + 25 * p));
// 抚的时候：每走 60px 轻敲一下（网页没有连续震动、也调不了强度）
if (travel > 60) { travel = 0; buzz(Math.round(5 + 15 * p)); }
