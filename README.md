# rex-canvas

Prototype: open a web page in a "canvas" that behaves like a Rex pane, beside an agent's pane.

Rex's Mac app can only draw terminal panes. rex-canvas splits the agent's pane as usual, runs a small placeholder program in the new pane, and draws a borderless WebKit window exactly over that pane's terminal area. Rex stays in charge of the layout. Resizing, zooming, switching tabs and closing the pane all work as they would for any pane, and the canvas follows.

## Use

```sh
./build.sh
bin/rex-canvas open http://localhost:3000/         # splits $REX_BLOCK to the right
bin/rex-canvas open ~/path/page.html --id app --ratio 40
bin/rex-canvas list
bin/rex-canvas navigate URL --id app
bin/rex-canvas eval 'document.title' --id app    # agents can read page state
bin/rex-canvas screenshot /tmp/app.png --id app # agents can see the page
bin/rex-canvas focus|reload|close --id app
```

Inside a canvas:

| Keys | Action |
| --- | --- |
| cmd+option+arrow | Return to Rex and focus the agent pane |
| cmd+W | Close the canvas and its pane |
| cmd+R | Reload |
| cmd+[ and cmd+] | Back and forward |
| cmd+= / cmd+- / cmd+0 | Zoom |

Focusing the canvas pane in Rex, by clicking its header or with Rex's pane-focus keys, moves the keyboard into the canvas.

## How it works

- **Placeholder pane (`rex-canvas stub`).** It sets its terminal title to `canvas:<id>` so the helper can find the pane, and shows the URL for Rex clients without the helper, such as a phone or another Mac. Every second it registers its canvas with the helper and starts the helper if none is running. The pane is the source of truth: if the helper dies, the canvas comes back within a second.
- **Helper (`rex-canvas helper`).** A background accessory app. It reads each pane's on-screen rectangle from the Rex app's accessibility tree, where each pane is an `AXGroup` described by the pane title and holding an `AXTextArea` "Terminal". It places the canvas over that rectangle.
  - **Timing.** A full scan costs about 5 ms and runs 5 times a second, and straight away after Rex events (`rex events -s SESSION`), app switches and accessibility focus changes. While the mouse is held or something has just changed, it re-reads only the cached pane frame on every display refresh (120 Hz on ProMotion screens), which costs two accessibility calls.
  - **Window order.** While Rex or the canvas is in front, the canvas floats above the Rex window. While another app is in front, it is ordered directly above the Rex window, so the other app still covers it.
  - **Hiding.** If the pane isn't on screen (another tab, another session, another pane zoomed, Rex minimised or hidden), the canvas hides.
- **Closing.** Closing the pane closes the canvas (`block_closed` event, or the stub's signal handler). Closing the canvas closes the pane.
- **IPC.** A Unix socket at `~/Library/Application Support/rex-canvas/helper.sock`. The log is `~/Library/Logs/rex-canvas.log`.

Accessibility permission comes from Rex: processes started in a Rex pane are covered by Rex's grant, so there was no extra prompt in testing.

## Tests

`scripts/e2e.sh` runs against the real Rex app from a Rex pane whose tab is on screen. It splits that pane, checks placement, window order, divider moves, zoom, tab switches and closing, then cleans up. `scripts/verify.swift` is the independent checker. It compares canvas windows in the window-server list with pane rectangles from accessibility.

## Known limits (prototype)

- The canvas has its own WebKit storage, so sites like GitHub need one sign-in inside it.
- While Rex is in front, the canvas floats, so Rex's command palette or sheets could appear under it if they overlap the canvas pane.
- Only tested on one display, with Rex expanded to fill the screen (not native full screen).

## Licence

MIT. See [LICENSE](./LICENSE).
