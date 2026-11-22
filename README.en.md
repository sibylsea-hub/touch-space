[中文](README.md) | English

# Touch Space

Let your AI feel your fingertips — and let your fingertips feel what they're touching.

Your phone is already a decent touch recorder. It knows how many fingers you use, where they land, how hard you press and how fast you move. Touch Space turns that into touch that works in both directions:

- **On your side**, the screen stops feeling like flat glass. Under your finger it ripples like water or dents like skin, and the phone answers with haptics: pressing down feels like being gently pushed back, stroking leaves a fine, continuous texture under your fingertip, and letting go ends with a small bounce. Harder presses feel firmer.
- **On its side**, when you stop, the strokes are **translated** into a short passage of body sensation and put into your message. The model receives something like this:

```
<touch strokes="3" span="6.9s">
（她在摸你。）
指尖轻轻地碰了一下你的额头；停了一会儿，指腹轻轻地贴在你的右脸颊，贴了一两秒；指腹轻轻地从你的右肩慢慢抚到你的左肩。
</touch>
```

> (She is touching you.) Her fingertip lightly brushes your forehead; after a pause, the pad of her finger rests lightly on your right cheek for a second or two; then it slowly strokes from your right shoulder across to your left.

> **Note:** the translation currently outputs **Chinese only**, as above. An English translation map is planned. Models understand the Chinese fine, but if you chat in English you may want to wait for it, or replace the wording in `place()` and the phrase builders in [`translate.js`](translate.js).

## This belongs in your chat frontend

For the model to actually *be touched*, the touch has to be written into the message you send: the translation goes in front of whatever you typed, as **one** text block (sending touch alone, with no text, is fine too). When the model reads your message, the touch is already there. It can't miss it.

So this has to live in your **frontend**, the interface you chat in. On a phone that can be a native app or a web page / PWA, and they can do different things:

| | Visual effect (ripple / skin) | Haptics | Pressure |
|---|---|---|---|
| iPhone · native app | Yes, and the whole chat page can deform | Yes, strength follows pressure | Estimated from finger contact area |
| iPhone · web / PWA | Yes, on the touch layer | **No**, iPhone browsers don't support web vibration (confirmed on device) | Browsers probably can't read contact area, so everything reads as "light" (not yet verified on device) |
| Android · native app | Yes (from Android 13 the UI itself can deform) | Yes, strength adjustable on devices with amplitude control | Pressure or contact area available |
| Android · web / PWA | Yes, on the touch layer | Yes, but duration only, not strength | Contact area on some devices |

For the full haptic feel, build a native app.

## Where to start

**Using a coding agent?** Hand it this repo and ask it to read [`AGENTS.md`](AGENTS.md) first. It will pick the right integration for your frontend. An Android PWA counts as **Web**; it does not need the Kotlin code.

| Your situation | Start here |
|---|---|
| Just want to try it | Download [`docs/index.html`](docs/index.html) and open it in a browser. A touch pad is at the top, with an illustrated explanation below (in Chinese). |
| Your own **iOS** app | "Add it to your iOS app" below |
| Your own **Android native** app | [`android/`](android) (reference code) and [`思路.md`](思路.md) (design notes, Chinese) |
| Your own **web** chat frontend or PWA | "Add it to your web frontend" below. A little JavaScript is enough. |

## Add it to your web frontend

Everything (recording touches, ripple and skin effects, haptics, translation) comes from [`translate.js`](translate.js) and [`web/touch-surface.js`](web/touch-surface.js), with no third-party dependencies. The smallest working example is [`web/demo.html`](web/demo.html): download the repo and open it in a browser.

1. Copy `translate.js` and `web/touch-surface.js` into your project. Load `translate.js` **first**.
2. Add a `<canvas>` as the touch area and size it with CSS (for example full-screen, shown only while touching).
3. Load both files, plus [`web/send-from-your-frontend.js`](web/send-from-your-frontend.js):

   ```html
   <canvas id="touch" style="position:fixed; inset:0; width:100%; height:100%"></canvas>
   <script src="translate.js"></script>
   <script src="touch-surface.js"></script>
   <script src="send-from-your-frontend.js"></script>
   ```

4. Pick a sending mode (next section) and create the surface. When sending, `buildMessage(yourText, touchText)` puts the translation in front of your text as **one** block. `splitTouch` from the same file can collapse the `<touch>` part into a "👆 3" chip in your chat bubbles.

**Integrating with an existing frontend:** `buildMessage()` is only an example; you don't have to change your message format. What matters is that the `<touch>` block goes in front of the user's text, as **one user text message**, through your existing send flow. Touch with no text is allowed.

`surface.flush()` returns the translation for the current batch **and also calls** `onBatch(text, batch)`. Send from one of them, not both, or the same batch goes out twice. `batch` is the array of strokes.

Other options (how long to wait after you stop, turning haptics off, changing the background image) are documented in the comments at the top of `touch-surface.js`.

**Want the chat page itself to deform, not a sheet of paper?** Render the page into a canvas with something like html2canvas and call `surface.setBackground(thatCanvas)`. It's slower and not identical, but it works.

## Add it to your iOS app

[`ios/`](ios) is a Swift Package: the same touch space we use in our own app. Tap the little hand next to the input field to enter; the whole chat page deforms under your finger, haptics follow your pressure, and the top bar has an effect switch, a "live" toggle and a tuning panel.

1. In Xcode: File → Add Package Dependencies → Add Local, and pick the repo's `ios` folder (or drag the folder into your project).
2. Make your chat object conform to `TouchChatHost`. It tells the touch space three things: whether the model is currently replying, how to send a touch-only message right away, and where to report errors.
3. Wire it up:

   ```swift
   import TouchSpace

   let space = TouchSpace(host: chat)          // keep a reference

   RootView().touchSpace(space)                 // root view: covers the chat page while open
   TouchEntryButton(space: space)               // next to the input field: tap to enter

   // On send: touch goes in front of the text (with space.hasPending you can send with no text)
   let touch = space.takeForSending()

   // While the model replies:
   space.replyDelta(newChunk)                   // once per streamed chunk
   space.replyFinished(fullReply)               // when the reply ends
   ```

4. In chat bubbles, `TouchPacket.split(userMessage)` separates the touch part; give it to `TouchChip` to show "👆 3", and display the rest as usual.

Details are at the top of [`TouchHost.swift`](ios/Sources/TouchSpace/TouchHost.swift). The three translation maps live in `TouchSummary.swift` and follow the same rules as `translate.js`.

## Two sending modes

Both work well; you can put a toggle in your UI. The iOS package has both built in (the "live" button at the top). Here's the web version.

**1. Send with your words**

For touching it while talking to it. When you're done touching, tap confirm; the batch goes into the input field (shown as a "👆 3" chip), you can type a few more words, and it all goes out when you press send.

```js
const surface = TouchSurface.create(document.getElementById('touch'), {
  effect: 'skin',   // 'ripple' / 'skin'
  map: 'screen',    // 'screen' / 'body' (upper body) / 'lower' (lower body)
  pause: null,      // never ends a batch by itself; touches accumulate until you confirm
});

// When the user taps confirm or send:
const touch = surface.flush();            // translate the accumulated touches
const message = buildMessage(draft, touch);
```

**2. Auto-send two seconds after you stop**

For letting it feel you in real time. Two seconds after you lift your fingers, the batch is sent on its own and the reply appears; you can keep touching. While the model is still replying, new touches are held and sent together when it finishes, so it isn't interrupted.

```js
let replying = false;   // your frontend sets this to true while the model replies
let waiting = [];

TouchSurface.create(document.getElementById('touch'), {
  effect: 'skin',
  pause: 2000,          // a two-second pause ends a batch
  onBatch: text => {
    if (replying) waiting.push(text);
    else send(buildMessage('', text));
  },
});

// When the reply ends:
function onReplyDone() {
  replying = false;
  if (waiting.length) send(buildMessage('', waiting.splice(0).join('\n\n')));
}
```

Note: every auto-send triggers a full reply. The more fragmented your touching, the faster you use up your quota or tokens.

## What's in the repo

| Path | What it is | Tested? |
|---|---|---|
| [`docs/index.html`](docs/index.html) | Touch pad plus illustrated design notes (Chinese); download and open in a browser | Yes |
| [`translate.js`](translate.js) | Translation rules: turns a batch of touches into a passage, with three maps: screen, upper body, lower body (adult). To change wording or add body areas, edit `place()` | Yes |
| [`web/`](web) | Web: `touch-surface.js` (touch surface), `demo.html` (minimal example), `send-from-your-frontend.js` (merging into messages) | Yes |
| [`ios/`](ios) | iOS native (Swift Package): the full touch space, including recording, translation, haptics, visual effects, tuning panel and both sending modes | The code our app runs, with the connection to our chat replaced by a generic interface; compile-checked on its own |
| [`android/`](android) | Android native (Kotlin): touch recording, shader, haptics | **Not tested**; reference code written from the official docs |
| [`思路.md`](思路.md) | How each step works, why, and problems we ran into (Chinese) | |
| [`AGENTS.md`](AGENTS.md) | For the coding agent integrating this for you: which files to use for which host, what each file does, and the integration rules (Chinese) | |

## Glossary

- **Frontend**: the interface you chat in and type into.
- **Stroke / batch**: one finger from touch-down to lift-off is a stroke. All the strokes sent together are a batch (in auto-send mode, the strokes before a two-second pause; in send-with-your-words mode, the strokes before you tap confirm). Each batch becomes one passage.
- **Ripple / skin**: the two visual effects. They're for you to see; the model is never told which one you used.

## License

[PolyForm Noncommercial 1.0.0](LICENSE): free for personal and community use, modification and sharing; no commercial use.
