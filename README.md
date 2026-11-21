# 触感空间

让你的 AI 感觉到你的手指。

想让陪伴模型「感觉」到你，除了做外接设备、连接传感器，你手里的手机也是很方便的触感记录仪：用了几根手指、碰在哪里、力度轻重、速度快慢，它都能记录下来。把数据发送给模型，就能够让模型感知到你的碰触。

你在屏幕上触摸时，画面会像水面一样泛起波纹，或者像皮肤一样微微凹陷，手机也会跟着轻轻震动。停手以后，这些触摸会根据你触碰的轨迹和压力，被**翻译**成一段身体感觉。模型收到的是这样一段话：

```
<touch strokes="3" span="6.9s">
（她在摸你。）
指尖轻轻地碰了一下你的额头；停了一会儿，指腹轻轻地贴在你的右脸颊，贴了一两秒；指腹轻轻地从你的右肩慢慢抚到你的左肩。
</touch>
```

## 这件事要在前端里做

要让模型真正「被摸到」，触摸就得直接写进你发出的那条消息里：翻译放在你打的字前面，合并成同一个文本块一起发送（不打字、单独发送触摸也可以）。模型收到消息时，触摸已经在里面了，一定能看到。

所以这件事要在**前端**里做，也就是你聊天时看到、用来打字的那个界面。手机上的前端可以是原生 App，也可以是网页或 PWA，两者能做到的不一样：

| | 画面效果（水纹 / 皮肤） | 震动反馈 | 力度轻重 |
|---|---|---|---|
| iPhone · 原生 App | 可以，而且整个聊天页面都能跟着变形 | 可以，震动强弱随力度变化 | 根据手指贴在屏幕上的面积估算 |
| iPhone · 网页 / PWA | 可以，在触摸层上 | **不可以**，iPhone 的浏览器不支持网页震动（真机上确认过） | 浏览器大概率读不到手指面积，翻译出来会一直是「轻轻」（还没在真机上验证） |
| 安卓 · 原生 App | 可以（Android 13 起，界面本身就能直接变形） | 可以，支持振幅调节的机型能调节强弱 | 可以读到压力或者面积 |
| 安卓 · 网页 / PWA | 可以，在触摸层上 | 可以，但只能控制震动时长，不能调节强弱 | 部分机型能读到手指面积 |

想要完整的震动反馈，就得做原生 App。

## 从哪里开始

| 你的情况 | 从这里开始 |
|---|---|
| 想先看看翻译效果 | 下载 [`docs/index.html`](docs/index.html)，用浏览器打开，页面开头就是一块触摸板，下面是图文版的思路说明 |
| 自己写了 **iOS** App | 本页下方的「接入自己的 iOS App」 |
| 自己写了**安卓原生** App | [`思路.md`](思路.md)，参考代码在 [`android/`](android) |
| 自己写了**网页**聊天前端或 PWA | 本页下方的「接入自己的网页前端」，会一点 JavaScript 就行 |

## 接入自己的网页前端

整个触摸功能（记录触摸、水纹和皮肤效果、震动、翻译）都在 [`web/touch-surface.js`](web/touch-surface.js) 这一个文件里，不依赖任何第三方库。最小的可运行示例是 [`web/demo.html`](web/demo.html)：把仓库下载下来，用浏览器打开它就能直接体验。

1. 把 `translate.js` 和 `web/touch-surface.js` 复制到你的项目里，注意要**先**引入 `translate.js`。
2. 放一块 `<canvas>` 作为触摸区域，大小用 CSS 控制（比如铺满整个屏幕，进入触摸状态时才显示出来）。
3. 引入这两个文件，再加上 [`web/send-from-your-frontend.js`](web/send-from-your-frontend.js)：

   ```html
   <canvas id="touch" style="position:fixed; inset:0; width:100%; height:100%"></canvas>
   <script src="translate.js"></script>
   <script src="touch-surface.js"></script>
   <script src="send-from-your-frontend.js"></script>
   ```

4. 按下一节选一种发送模式，创建触摸面。发送时用 `buildMessage(你打的字, 触摸翻译)`，它会把翻译放在正文前面，合并成**同一个**文本块。同一个文件里的 `splitTouch` 可以在聊天气泡里把 `<touch>` 那一段折叠成「👆 3」。

其他选项（停手后等待多久、关闭震动、更换底图）写在 `touch-surface.js` 开头的注释里。

**想让聊天页面本身跟着变形，而不是一张纸**：可以用 html2canvas 之类的库把页面绘制成一张 canvas，再调用 `surface.setBackground(那张canvas)`。速度会慢一些，效果也不会完全一样，但可以用。

## 接入自己的 iOS App

[`ios/`](ios) 是一个 Swift Package，就是我们自己 App 里正在用的那套触摸空间：点输入框旁边的小手进入，整个聊天页面在手指下变形，震动随力度变化，顶上有效果切换、「实时」开关和调节面板。

1. 在 Xcode 里 File → Add Package Dependencies → Add Local，选仓库里的 `ios` 文件夹（或者把整个文件夹拖进项目）。
2. 让你的聊天对象遵守 `TouchChatHost`，告诉触摸空间三件事：模型是不是正在回复、怎么立刻发一条只带触摸的消息、出错时报给谁。
3. 接上这几处：

   ```swift
   import TouchSpace

   let space = TouchSpace(host: chat)          // 自己留着它

   RootView().touchSpace(space)                 // 根视图：触摸空间开着时盖住整块聊天页
   TouchEntryButton(space: space)               // 输入框旁边：点它进入触摸空间

   // 按发送时：有触摸就排在正文前面（space.hasPending 为真时，一个字不写也能发）
   let touch = space.takeForSending()

   // 模型回复时：
   space.replyDelta(新来的那段文字)             // 回复过程中，每来一段调用一次
   space.replyFinished(完整回复)                // 回复结束
   ```

4. 聊天气泡里，用 `TouchPacket.split(用户消息)` 拆出触摸那一段，交给 `TouchChip` 折叠成「👆 3」，剩下的正文照常显示。

详细说明写在 [`TouchHost.swift`](ios/Sources/TouchSpace/TouchHost.swift) 开头。翻译的三套说法在 `TouchSummary.swift`，和网页版的 `translate.js` 是同一套规则。

## 两种发送模式

两种都好用，可以在界面上放一个开关，随时切换。iOS 版自带这两种，触摸空间顶上的「实时」按钮就是开关；下面是网页的写法。

**一、和你的话一起发**

适合想一边触摸、一边对它说话的时候。摸完点一下确认，这批触摸放进输入框（显示成「👆 3」这样的小标签），你可以再打几句话，按发送时一起发出去。

```js
const surface = TouchSurface.create(document.getElementById('touch'), {
  effect: 'skin',   // 'ripple' 水纹 / 'skin' 皮肤
  map: 'screen',    // 'screen' 屏幕 / 'body' 上半身 / 'lower' 下半身
  pause: null,      // 不自动结束，触摸一直攒着，等你确认
});

// 用户点「确认」或「发送」时：
const touch = surface.flush();            // 把攒下的触摸翻译出来
const message = buildMessage(draft, touch);
```

**二、停手两秒自动发**

适合想让它实时感受到你的触摸的时候。停手两秒，这批触摸自动单独发送，模型的回复直接出现，你可以接着摸。模型还在回复时，新的触摸先攒着，等它说完再一起发，不会打断它。

```js
let replying = false;   // 你的前端在模型回复期间设成 true
let waiting = [];

TouchSurface.create(document.getElementById('touch'), {
  effect: 'skin',
  pause: 2000,          // 停手两秒算一批
  onBatch: text => {
    if (replying) waiting.push(text);
    else send(buildMessage('', text));
  },
});

// 模型回复结束时：
function onReplyDone() {
  replying = false;
  if (waiting.length) send(buildMessage('', waiting.splice(0).join('\n\n')));
}
```

需要注意：每自动发送一次，模型就会完整回复一次，触摸得越零碎，额度或 token 消耗得越快。

## 仓库里有什么

| 位置 | 内容 | 是否测试过 |
|---|---|---|
| [`docs/index.html`](docs/index.html) | 触摸板，以及图文版的思路说明，下载后用浏览器打开 | 测试过 |
| [`translate.js`](translate.js) | 翻译规则：把一批触摸翻译成一段话，有屏幕、上半身、下半身（成人向）三套说法。想修改说法、增加其他部位，修改这里的 `place()` | 测试过 |
| [`web/`](web) | 网页：`touch-surface.js`（触摸功能）、`demo.html`（最小示例）、`send-from-your-frontend.js`（合并进消息） | 测试过 |
| [`ios/`](ios) | iOS 原生（Swift Package）：完整的触摸空间，包括记录、翻译、震动、画面效果、调节面板、两种发送模式 | 就是我们 App 里正在用的代码，只把连接我们聊天的部分换成了通用接口；单独做过编译检查 |
| [`android/`](android) | 安卓原生（Kotlin）：记录触摸、着色器、震动 | **没有测试过**，是按照官方文档写的参考代码 |
| [`思路.md`](思路.md) | 每一步怎么实现、为什么这样做、遇到过的问题 | |

代码是从我们自己的 iOS 应用里整理出来的。连接我们自己聊天前端的那部分接口没有放进来，换成了通用的写法。

## 名词解释

- **前端**：你聊天时看到的、用来打字的那个界面。
- **一笔 / 一批**：一根手指从按下到抬起，算作一笔；一次发送的所有笔算作一批（自动发送时是停手两秒之前的那些，和你的话一起发时是点确认之前的那些），一批翻译成一段话。
- **水纹 / 皮肤**：两种画面效果，只是给你看的，不会告诉模型。

## 许可证

[PolyForm Noncommercial 1.0.0](LICENSE)：个人和社群可以自由使用、修改、分享，禁止商业用途。
