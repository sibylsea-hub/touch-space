# 触感空间 · MCP 版

用手机屏幕当触感记录仪：在手机浏览器里打开触摸页，摸；停手两秒，这批触摸被翻译成一段身体感觉式的描述，存在电脑上的这个小服务里。模型通过 MCP 工具 `get_touches` 读到它。

- 零依赖：只要装了 Node 18 以上。
- 画面：触摸页上有水纹、皮肤两种效果（WebGL）。
- 震动：安卓 Chrome 能震（网页只能控时长）；iPhone 的 Safari 不支持网页震动。
- 翻译规则在 `../translate.js`，想改说法、加一套身体映射，改那一个文件。

## 文件

| 文件 | 做什么 |
|---|---|
| `server.mjs` | MCP 服务 + 触摸页的小网站 |
| `pad.html` | 触摸页（手机打开的那一页） |
| `../translate.js` | 翻译：一批触摸 → 一段话 |

## 接 Claude Desktop（本机，最简单）

1. 把整个仓库克隆或下载到电脑上某处，比如 `~/touch-space`。
2. 打开 Claude Desktop 的配置文件 `claude_desktop_config.json`（设置 → 开发者 → 编辑配置），加上：

```json
{
  "mcpServers": {
    "touch": {
      "command": "node",
      "args": ["/Users/你的用户名/touch-space/mcp/server.mjs"]
    }
  }
}
```

   `command` 找不到 node 的话，换成 node 的完整路径（终端里跑 `which node` 看）。

3. 重启 Claude Desktop。跟它说「给我触摸页的链接」，它会调用 `touch_pad_link` 给你一个 `http://192.168.x.x:8848/?t=…` 的地址。
4. 手机和电脑连同一个 Wi-Fi，用手机浏览器打开这个地址，摸。
5. 回到对话里随便说一句（或者只发一个「👆」），它会调用 `get_touches` 读到你刚才的触摸。

服务第一次启动时会生成一个口令存在 `~/.touch-mcp/token`，链接里的 `?t=…` 就是它。别把链接发给别人。

## 接网页版、手机上的官方 App（远程，进阶）

这两种只认公网 https 的 MCP 地址，所以要多两步：

1. 只开 HTTP：`node server.mjs --http-only`。它会打印本机的 MCP 地址 `http://localhost:8848/mcp/<口令>`。
2. 用隧道把 8848 端口变成公网 https，比如 Cloudflare Tunnel（`cloudflared tunnel --url http://localhost:8848`）或 Tailscale Funnel。
3. 在客户端的「自定义连接器」里填 `https://<隧道地址>/mcp/<口令>`。

口令就在地址里，所以地址等于钥匙：别公开。手机上的触摸页仍然走局域网地址（或者也走隧道：`https://<隧道地址>/?t=<口令>`）。

## 限制

- MCP 不能自己推一条消息进对话：模型要调用 `get_touches` 才知道你摸了。服务在初始化时告诉模型「每次回复前先看一眼」，大多数时候它会照做；它没看的话，发个「👆」提醒它。
- 不是实时：摸完要等你下一句话（或你发个「👆」），它才会读到。
- 队列只存在 `~/.touch-mcp/queue.jsonl`，读过就清空。

## 可以改的地方

- `TOUCH_PORT`：换端口（默认 8848）。
- `TOUCH_TOKEN`：自己指定口令。
- `server.mjs` 里的 `INSTRUCTIONS`：告诉模型怎么对待触摸。
- `../translate.js` 里的 `place()`：位置怎么说。屏幕、上半身两套都在这里，加别的映射也在这里。
