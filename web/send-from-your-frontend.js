// 自己的前端：发送时把攒下的触摸翻译排在正文前面，合成同一个文本块（通用写法）
function buildMessage(draft, pendingTouch) {
  const parts = [];
  if (pendingTouch) parts.push(pendingTouch);   // <touch strokes="…"> … </touch>
  if (draft.trim()) parts.push(draft.trim());
  // 一定要是同一个文本块：气泡靠「正文以 <touch 开头」认出它
  return { role: 'user', content: [{ type: 'text', text: parts.join('\n\n') }] };
}

// 气泡里：把 <touch> 段折成「👆 笔数」，点开看全文；剩下的正文照常显示
function splitTouch(text) {
  const m = text.match(/^<touch strokes="(\d+)"[^>]*>\n([\s\S]*?)\n<\/touch>\s*/);
  if (!m) return { touch: null, strokes: 0, rest: text };
  return { touch: m[2], strokes: Number(m[1]), rest: text.slice(m[0].length) };
}
