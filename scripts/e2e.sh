#!/bin/sh
# End-to-end placement test against the real Rex app. Run from a Rex pane whose session is on screen.
# It splits this pane, so it changes the visible layout while it runs, and cleans up afterwards.
set -u
cd "$(dirname "$0")/.."
swiftc -O scripts/verify.swift -o bin/verify 2>/dev/null || exit 1
t() { perl -e 'alarm 15; exec @ARGV' "$@"; }
S=$REX_SESSION A=$REX_BLOCK
page=$(mktemp -d)/index.html
printf '<!doctype html><title>e2e</title><h1>rex-canvas e2e</h1>' > "$page"
P=$(t ./bin/rex-canvas open "$page" --id e2e --ratio 45 | jq -r .placeholder)
H=$(pgrep -f 'rex-canvas helper')
pass=0 fail=0
check() { # name, jq condition over verify output
  sleep 0.4
  out=$(./bin/verify "$H")
  if echo "$out" | jq -e "$2" >/dev/null; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1: $out"; fi
}
covered='.canvas_panes_visible | map(select(.pane == "canvas:e2e")) | .[0].covered == true'
hidden='(.canvas_panes_visible | map(select(.pane == "canvas:e2e")) | length == 0) and .canvas_windows_shown == 0'
check "opens over its pane" "$covered"
check "sits directly above the Rex window" '.canvas_panes_visible[0].directly_above_rex == true'
rex api call -s "$S" session.resize_pane "{\"direction\":\"horizontal\",\"before_block_id\":\"$A\",\"after_block_id\":\"$P\",\"ratio\":0.7}" >/dev/null
check "follows a divider move" "$covered"
rex zoom -s "$S" "$A" --on
check "hides while the agent pane is zoomed" "$hidden"
rex zoom -s "$S" "$A" --off
check "returns after unzoom" "$covered"
rex zoom -s "$S" "$P" --on
check "fills the window when its own pane is zoomed" "$covered"
rex zoom -s "$S" "$P" --off
W=$(rex window new -s "$S" e2e-other --focus=true --json -- sleep 30 | jq -r .window_id)
check "hides on another tab" "$hidden"
rex window close -s "$S" "$W"
check "returns on its tab" "$covered"
rex block close -s "$S" "$P"
sleep 1
if t ./bin/rex-canvas list | jq -e 'map(select(.id == "e2e")) | length == 0' >/dev/null; then pass=$((pass+1)); echo "PASS closing the pane closes the canvas"; else fail=$((fail+1)); echo "FAIL closing the pane closes the canvas"; fi
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
