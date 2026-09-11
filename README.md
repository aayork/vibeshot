# VibeShot

A CleanShot-style screenshot tool for [Omarchy](https://omarchy.org/) — capture,
markup, and pin, all as a native Quickshell overlay that themes itself off your
current Omarchy colors instead of popping open a separate GTK app.

![kind: overlay](https://img.shields.io/badge/kind-overlay-blue)

## AI DISCLOSURE

VibeShot is a vide-coded plugin (hence the name). I wanted a personal tool 
similar to CleanShot X to use on Omarchy, and found that VibeShot worked well,
so I decided to publish it.

## What it does

Press a screenshot key and pick a region, window, or fullscreen shot exactly
like Omarchy's stock screenshot tool (same `slurp`/`hyprpicker`/`grim`
pipeline under the hood). Instead of jumping straight into an editor, a small
preview drops into the bottom-left corner with three options:

- **Markup** — opens a full-screen annotation editor: arrows, lines,
  rectangles, ellipses, freehand pen, highlighter, text, and a redact/blackout
  tool, with undo/redo, three stroke widths, and a color palette pulled from
  your live theme (foreground/accent/urgent/muted plus a few fixed accents).
  Copy to clipboard, save to disk, or pin it from there too.
- **Save** — writes the untouched screenshot straight to
  `~/Pictures/Screenshots`.
- **✕ (dismiss)** — throws it away.

Anything you pin (from the preview or from inside the editor) becomes a small
always-on-top floating window you can drag anywhere on screen, with its own
Markup/Save/dismiss controls on hover.

A separate keybind (see below) pops up a small top-center mode picker —
Fullscreen / Area / Window, clickable or via `3`/`4`/`5` while it's open —
loosely mirroring CleanShot's `Cmd+Shift+5` menu (minus the recording options
CleanShot has and VibeShot doesn't, yet).

## Install

```bash
git clone https://github.com/aayork/vibeshot.git ~/.config/omarchy/plugins/aayork.vibeshot
omarchy-shell shell rescanPlugins
omarchy plugin enable aayork.vibeshot
```

### Keybindings

In `~/.config/hypr/bindings.lua`. Use absolute paths, not `~`, if your
Hyprland Lua config doesn't expand it.

An earlier version of this bound `SUPER+V` as a Hyprland *submap* (a leader
key: tap it, then `3`/`4`/`5`) to mirror CleanShot's `Cmd+Shift+3/4/5` more
closely. Don't do that — while a submap is active, Hyprland disables every
other keybind on the system, including unrelated `SUPER+...` ones, until it
resets, and any misfire there leaves the whole session's shortcuts stuck.
Ordinary keybinds below; the mode-picker popup handles `3`/`4`/`5` as
in-app shortcuts on its own instead, which is safe because it only listens
while it's already open and focused.

```lua
hl.unbind("PRINT")

local vibeshot_bin = "/home/YOU/.config/omarchy/plugins/aayork.vibeshot/capture.sh"

-- Hyprland execs capture.sh directly (never as a child of omarchy-shell).
-- Routing the interactive slurp/hyprpicker selection through a Quickshell
-- Process breaks hyprpicker's screen freeze and cuts slurp's selection short
-- on the first click — capture.sh must be launched by Hyprland itself, then
-- it hands the finished PNG to the plugin over `omarchy-shell shell call`.
o.bind("PRINT", "Screenshot", vibeshot_bin .. " smart") -- harmless if your keyboard has no PRINT key
o.bind("ALT + SHIFT + 3", "Screenshot (area)", vibeshot_bin .. " smart")
o.bind("F12", "Screenshot (region)", vibeshot_bin .. " region")
o.bind("ALT + SHIFT + 4", "Screenshot (fullscreen)", vibeshot_bin .. " fullscreen")
o.bind("SUPER + SHIFT + V", "Screenshot menu", "omarchy-shell shell call aayork.vibeshot showMenu ''")

hl.layer_rule({
  match = { namespace = "^aayork-vibeshot-editor$" },
  no_anim = true,
  animation = "none",
  no_screen_share = true,
})

hl.layer_rule({
  match = { namespace = "^vibeshot-pin$" },
  no_anim = true,
  animation = "none",
})
```

`smart`/`region`/`fullscreen`/`windows` are the same modes
`omarchy-capture-region` already supports — `smart` auto-highlights windows
as you hover (closest to CleanShot's own area tool), `region` is pure
freeform with no hinting.

## Uninstall

```bash
omarchy plugin remove aayork.vibeshot
```

Then remove the `o.bind`/`hl.layer_rule` blocks you pasted into
`~/.config/hypr/bindings.lua`, and `hyprctl reload`.

```bash
rm -rf ~/.cache/aayork.vibeshot
```

## Why not just use the stock screenshot tool or others?

The stock GTK-based editor (Tensaku) works fine but looks and feels like a
separate app. VibeShot is a plain Quickshell plugin — no compiling, no separate process,
and it inherits your theme's colors live because it's built directly on
`qs.Commons` (`Color`/`Style`), the same tokens the bar and every other
first-party Omarchy surface use.

## How it works

- `capture.sh` is launched **directly by Hyprland**, not by the Quickshell
  plugin — this matters, see the comment above. It runs the same
  `omarchy-capture-region` + `grim` pipeline as the stock tool, then calls
  `omarchy-shell shell call aayork.vibeshot captured <path>` once it has a
  PNG.
- `VibeShot.qml` is the plugin entry point: an `overlay`-kind Quickshell
  plugin that renders the post-capture preview, the full editor, and owns
  the pin windows.
- `PinWindow.qml` is one floating pin — a small always-on-top layer-shell
  surface, one instance per pinned/previewed screenshot.

## License

MIT
