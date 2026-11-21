# Touch Space — Agent 接入说明

本仓库提供可集成到 AI 聊天前端的触摸交互。请先检查用户项目的实际技术栈、消息发送流程及界面结构，再选择适合它的接入方式；不需要为适配本仓库而重构宿主前端。

## 按宿主环境找文件

| 宿主 | 入口 |
|---|---|
| Android PWA、网页、WebView、React/Vue 等 Web 前端 | `translate.js` + `web/touch-surface.js` |
| iOS / SwiftUI 原生 App | `ios/`，接口见 `ios/Sources/TouchSpace/TouchHost.swift` |
| Android / Kotlin 原生 App | `android/`，目前仅是**未实测参考实现** |

Android PWA 走 Web 路径，不走 Kotlin 路径。

## 文件职责

- `README.md`：使用场景、平台差异、接入说明。
- `web/demo.html`：Web 最小运行示例。
- `translate.js`：触摸轨迹到描述文本的转换规则。
- `web/touch-surface.js`：Web 触摸输入、视觉反馈、震动和批次回调。
- `web/send-from-your-frontend.js`：消息拼接示例，不是宿主必须采用的数据格式。
- `docs/index.html`：交互式图文说明；它的内嵌示例不是生产用 Web 模块。

## 接入契约

- 让宿主提供触摸交互区域，并把触摸译文接入**现有的**聊天发送流程。
- 译文形如 `<touch strokes="…" span="…">…</touch>`，应放在用户文字前面，**合成同一条用户文本消息**；只有触摸而没有文字时也可以发送。
- Web 提供手动 `surface.flush()` 与自动 `onBatch(text, batch)` 两种取译文方式。`flush()` **同时返回译文并调用 `onBatch`**；同一批只需发送一次。这里 `batch` 是笔画数组。
- 宿主可以按自己的状态管理方式处理模型回复期间的触摸队列，并决定如何在聊天气泡中折叠触摸段。
- Web 触摸面本身可以变形；如果要变形底下的聊天页面，需要由宿主提供页面背景。
- 震动功能依浏览器与设备能力而定。

用宿主已有的组件、生命周期和消息格式适配即可。更多实现细节直接读对应源码和 `思路.md`。
