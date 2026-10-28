# rex-canvas

Prototype: open a web page in a "canvas" that behaves like a Rex pane, beside an agent's pane.

Rex's Mac app can only draw terminal panes. rex-canvas splits the agent's pane as usual, runs a small placeholder program in the new pane, and draws a borderless WebKit window exactly over that pane's terminal area. Rex stays in charge of the layout. Resizing, zooming, switching tabs and closing the pane all work as they would for any pane, and the canvas follows.

## Install

Requirements: macOS 14 or later, the Xcode command line tools (`xcode-select --install`) and [Rex](https://www.superlogical.com/rex/docs).

```sh
git clone https://github.com/tmustier/rex-canvas.git
cd rex-canvas
./build.sh
ln -sf "$PWD/bin/rex-canvas" ~/.local/bin/rex-canvas   # or any directory on your PATH
```

Rebuild with `./build.sh` after pulling. Run `rex-canvas quit` to load the new build; open canvases come back within a second.

To teach a coding agent to use it, add `skill/SKILL.md` to the agent's skills. For example, for Pi:

```sh
ln -s "$PWD/skill" ~/.pi/agent/skills/rex-canvas
```

## Use

Run these from a Rex pane:

```sh
rex-canvas open http://localhost:3000/          # splits $REX_BLOCK to the right
rex-canvas open ~/path/page.html --id app --ratio 40
rex-canvas open examples/demo.html              # a small demo page
rex-canvas list                                 # canvases beside this pane (--all for every canvas)
rex-canvas navigate URL --id app
rex-canvas context --id app                     # page, selection, last click, page-provided context
rex-canvas ask "Make this shorter" --id app     # send a question to the agent pane, as the Ask agent field does
rex-canvas eval 'document.title' --id app       # agents can read page state
rex-canvas screenshot /tmp/app.png --id app     # agents can see the page
rex-canvas focus|reload|close --id app
```

Inside a canvas:

| Keys | Action |
| --- | --- |
| cmd+shift+A, or Ask agent | Ask the agent pane about this page. Your selection is included. |
| cmd+option+arrow | Return to Rex and focus the agent pane |
| cmd+W | Close the canvas and its pane |
| cmd+R | Reload |
| cmd+[ and cmd+] | Back and forward |
| cmd+= / cmd+- / cmd+0 | Zoom |

Commands act on the canvases beside the pane they run in. Without `--id`, they use the only canvas beside it. `open --id` won't take over a canvas that belongs to another pane.

Focusing the canvas pane in Rex, by clicking its header or with Rex's pane-focus keys, moves the keyboard into the canvas.

### Asking the agent

The canvas has a slim toolbar with back, forward, reload, the page title and an Ask agent button. Your question is typed into the agent pane as one line, followed by Enter:

```
[canvas:app] Make this heading shorter (page "Field notes" file:///…/demo.html; selected "Notes from the tide pools" in body > main > h1; full context: rex-canvas context --id app)
```

The agent can run `rex-canvas context` for the full selection, the last click and anything the page adds through `window.rexCanvasContext = () => ({ ... })`. Pages can open the ask field with `window.rexCanvas.ask("prefilled text")`, but only the person can send.

Safeguards:
- Control characters are removed, so page text can't press Enter or send terminal escape sequences.
- Nothing is sent if the agent pane is running a plain shell, where the line would run as a command.

## How it works

- **Placeholder pane (`rex-canvas stub`).** It sets its terminal title to `canvas:<id>` so the helper can find the pane, and shows the URL for Rex clients without the helper, such as a phone or another Mac. Every second it registers its canvas with the helper and starts the helper if none is running. The pane is the source of truth: if the helper dies, the canvas comes back within a second.
- **Helper (`rex-canvas helper`).** A background accessory app. It reads each pane's on-screen rectangle from the Rex app's accessibility tree, where each pane is an `AXGroup` described by the pane title and holding an `AXTextArea` "Terminal". It places the canvas over that rectangle.
  - **Timing.** A full scan costs about 5 ms and runs 5 times a second, and straight away after Rex events (`rex events -s SESSION`), app switches and accessibility focus changes. While the mouse is held or something has just changed, it re-reads only the cached pane frame on every display refresh (120 Hz on ProMotion screens), which costs two accessibility calls. While a divider next to a canvas is being dragged, it skips Rex entirely and moves the canvas edge with the pointer, then checks against Rex on release (the log records how far off it was).
  - **Window order.** While Rex or the canvas is in front, the canvas floats above the Rex window. While another app is in front, it is ordered directly above the Rex window, so the other app still covers it.
  - **Hiding.** If the pane isn't on screen (another tab, another session, another pane zoomed, Rex minimised or hidden), the canvas hides.
- **Closing.** Closing the pane closes the canvas (`block_closed` event, or the stub's signal handler). Closing the canvas closes the pane.
- **Toolbar and page script.** Each canvas has a native toolbar, so it never covers page controls. A script injected into each page records the latest selection and click for `context`.
- **IPC.** A Unix socket at `~/Library/Application Support/rex-canvas/helper.sock`. The log is `~/Library/Logs/rex-canvas.log`.

Accessibility permission comes from Rex: processes started in a Rex pane are covered by Rex's grant, so there was no extra prompt in testing.

## Tests

`scripts/e2e.sh` runs against the real Rex app, with no other canvases open, from a Rex pane whose tab is on screen. It splits that pane, checks placement, window order, divider moves, zoom, tab switches and closing, then cleans up. `scripts/verify.swift` is the independent checker. It compares canvas windows in the window-server list with pane rectangles from accessibility.

## Known limits (prototype)

- The canvas has its own WebKit storage, so sites like GitHub need one sign-in inside it.
- While Rex is in front, the canvas floats, so Rex's command palette or sheets could appear under it if they overlap the canvas pane.
- Only tested on one display, with Rex expanded to fill the screen (not native full screen).

## Licence

MIT. See [LICENSE](./LICENSE).
