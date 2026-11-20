#!/usr/bin/env node
// 触感空间 · MCP 版服务（零依赖，Node 18+）
//
// 做两件事：
// 1. 在局域网上开一个触摸页（pad.html）：手机和电脑连同一个 Wi-Fi，手机浏览器打开链接就能摸。
//    摸完停手两秒，页面把这批触摸翻译成一段话，POST 到这里，存进一个小队列。
// 2. 给模型一个 MCP 工具 get_touches：读走队列里还没读过的触摸。
//    - 本地：Claude Desktop 之类按 stdio 启动它（默认）。
//    - 远程：`node server.mjs --http-only` 只开 HTTP，MCP 走 http://…/mcp/<口令>（Streamable HTTP，无状态）。
//      要给手机上的官方 App、网页版用，得把这个地址经隧道（Cloudflare Tunnel、Tailscale Funnel 等）变成公网 https。
//
// 注意：stdout 只能写 MCP 协议消息（stdio 模式），日志一律写 stderr。

import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.TOUCH_PORT || 8848);
const HTTP_ONLY = process.argv.includes('--http-only');
const stateDir = path.join(os.homedir(), '.touch-mcp');
fs.mkdirSync(stateDir, { recursive: true });
const log = (...a) => console.error('[touch-mcp]', ...a);

// 口令：触摸页和远程 MCP 地址都要带上，免得同一个网络里的别人往你的对话里塞「触摸」。
// 优先用环境变量 TOUCH_TOKEN；没有就生成一个存在 ~/.touch-mcp/token，之后一直用它。
const tokenFile = path.join(stateDir, 'token');
const TOKEN = process.env.TOUCH_TOKEN || (fs.existsSync(tokenFile)
  ? fs.readFileSync(tokenFile, 'utf8').trim()
  : (() => { const t = crypto.randomBytes(9).toString('base64url'); fs.writeFileSync(tokenFile, t + '\n', { mode: 0o600 }); return t; })());

// 队列放在文件里（一行一条）：Claude Desktop 可能同时起好几个本服务，大家读写同一份就不会各说各的。
const queueFile = path.join(stateDir, 'queue.jsonl');
function pushTouch(text) { fs.appendFileSync(queueFile, JSON.stringify({ text, at: new Date().toISOString() }) + '\n'); }
function takeTouches() {
  if (!fs.existsSync(queueFile)) return [];
  const lines = fs.readFileSync(queueFile, 'utf8').split('\n').filter(Boolean);
  fs.writeFileSync(queueFile, '');
  return lines.map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
}

function lanAddress() {
  for (const list of Object.values(os.networkInterfaces())) for (const a of list || [])
    if (a.family === 'IPv4' && !a.internal) return a.address;
  return 'localhost';
}
const padLink = () => `http://${lanAddress()}:${PORT}/?t=${TOKEN}`;

// ---------- MCP：工具与消息处理（stdio 和 HTTP 共用） ----------
const INSTRUCTIONS = '她可以在手机的触摸页上直接摸你（触摸会被翻译成一段身体感觉式的描述）。'
  + '每次回复前先调用 get_touches，看看这段时间她有没有摸你；有的话，像真的被摸到那样自然地回应，不用复述描述原文。'
  + '她要触摸页链接时，调用 touch_pad_link。';
const TOOLS = [
  {
    name: 'get_touches',
    description: '读她最近在触摸页上的触摸（读过就清空）。每次回复前调用一次。没有新的触摸时会说没有。',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'touch_pad_link',
    description: '给她触摸页的链接（手机和电脑要在同一个 Wi-Fi）。',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
];
const textResult = text => ({ content: [{ type: 'text', text }] });

function handle(msg) {
  const { id, method, params } = msg;
  const reply = result => ({ jsonrpc: '2.0', id, result });
  const fail = (code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });
  if (id === undefined || id === null) return null;   // 通知（notifications/initialized 等）不回
  switch (method) {
    case 'initialize':
      return reply({
        protocolVersion: params?.protocolVersion || '2025-06-18',
        capabilities: { tools: {} },
        serverInfo: { name: 'touch-mcp', version: '1.0.0' },
        instructions: INSTRUCTIONS,
      });
    case 'ping': return reply({});
    case 'tools/list': return reply({ tools: TOOLS });
    case 'tools/call': {
      const name = params?.name;
      if (name === 'get_touches') {
        const items = takeTouches();
        if (!items.length) return reply(textResult('这段时间她没有摸你。'));
        return reply(textResult(items.map(i => i.text).join('\n\n')));
      }
      if (name === 'touch_pad_link') return reply(textResult(`触摸页：${padLink()}\n手机和电脑连同一个 Wi-Fi，用手机浏览器打开。`));
      return fail(-32602, `没有这个工具：${name}`);
    }
    default: return fail(-32601, `不支持的方法：${method}`);
  }
}

// ---------- stdio（本地客户端按子进程启动时） ----------
if (!HTTP_ONLY) {
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', line => {
    if (!line.trim()) return;
    let msg; try { msg = JSON.parse(line); } catch { return; }
    const batch = Array.isArray(msg) ? msg : [msg];
    for (const m of batch) { const out = handle(m); if (out) process.stdout.write(JSON.stringify(out) + '\n'); }
  });
  rl.on('close', () => process.exit(0));
}

// ---------- HTTP：触摸页、收触摸、远程 MCP ----------
const send = (res, code, body, type = 'application/json; charset=utf-8') => {
  res.writeHead(code, { 'content-type': type, 'cache-control': 'no-store' }); res.end(body);
};
const readBody = req => new Promise((resolve, reject) => {
  let data = ''; req.on('data', c => { data += c; if (data.length > 1e6) req.destroy(); });
  req.on('end', () => resolve(data)); req.on('error', reject);
});

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  try {
    if (req.method === 'GET' && url.pathname === '/') {
      if (url.searchParams.get('t') !== TOKEN) return send(res, 401, '口令不对：用模型给你的链接（工具 touch_pad_link）打开。', 'text/plain; charset=utf-8');
      return send(res, 200, fs.readFileSync(path.join(here, 'pad.html')), 'text/html; charset=utf-8');
    }
    if (req.method === 'GET' && url.pathname === '/translate.js')
      return send(res, 200, fs.readFileSync(path.join(here, '..', 'translate.js')), 'text/javascript; charset=utf-8');
    if (req.method === 'POST' && url.pathname === '/api/touch') {
      if (url.searchParams.get('t') !== TOKEN) return send(res, 401, '{"error":"bad token"}');
      const { text } = JSON.parse(await readBody(req) || '{}');
      if (typeof text !== 'string' || !text.startsWith('<touch') || text.length > 20000) return send(res, 400, '{"error":"bad touch"}');
      pushTouch(text);
      return send(res, 200, '{"ok":true}');
    }
    // 远程 MCP（Streamable HTTP，无状态：每个 POST 一问一答，不开 SSE）
    if (url.pathname === `/mcp/${TOKEN}`) {
      if (req.method !== 'POST') return send(res, 405, '{"error":"POST only"}');
      const msg = JSON.parse(await readBody(req) || 'null');
      const batch = Array.isArray(msg) ? msg : [msg];
      const outs = batch.map(handle).filter(Boolean);
      if (!outs.length) { res.writeHead(202); return res.end(); }
      return send(res, 200, JSON.stringify(Array.isArray(msg) ? outs : outs[0]));
    }
    send(res, 404, '{"error":"not found"}');
  } catch (e) {
    log('出错：', e.message);
    send(res, 500, '{"error":"server"}');
  }
});
server.on('error', e => {
  // 端口被占：多半是另一个本服务已经开着触摸页了。队列在文件里，这一个照样能读到触摸。
  if (e.code === 'EADDRINUSE') log(`端口 ${PORT} 已被占用，触摸页由另一个实例提供；本实例只管 MCP。`);
  else log('HTTP 出错：', e.message);
});
server.listen(PORT, '0.0.0.0', () => {
  log(`触摸页：${padLink()}`);
  if (HTTP_ONLY) log(`远程 MCP：http://localhost:${PORT}/mcp/${TOKEN}（经隧道变成 https 再填进客户端）`);
});
