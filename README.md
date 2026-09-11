# VibeShot

A CleanShot-style screenshot tool for [Omarchy](https://omarchy.org/) — capture,
markup, and pin, all as a native Quickshell overlay that themes itself off your
current Omarchy colors instead of popping open a separate GTK app.

![kind: overlay](https://img.shields.io/badge/kind-overlay-blue)

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

Tapping the leader key (`SUPER+V`, see below) also pops up a small top-center
mode picker — Fullscreen / Area / Window — a mouse-clickable twin of the
`3`/`4`/`5` chord, loosely mirroring CleanShot's `Cmd+Shift+5` menu (minus the
recording options CleanShot has and VibeShot doesn't, yet).

## Install

```bash
git clone https://github.com/aayork/vibeshot.git ~/.config/omarchy/plugins/aayork.vibeshot
omarchy-shell shell rescanPlugins
omarchy plugin enable aayork.vibeshot
```

### Keybindings

In `~/.config/hypr/bindings.lua`. This mirrors CleanShot X on macOS: `SUPER+V`
is a leader key (Hyprland submap) — tap it, then `3`/`4`/`5` for
fullscreen/area/window, same as CleanShot's `Cmd+Shift+3/4/5`. Escape cancels
if you tap `SUPER+V` and change your mind. Use absolute paths, not `~`, if
your Hyprland Lua config doesn't expand it.

```lua
hl.unbind("PRINT")
hl.unbind("SUPER + V") -- was: Universal paste

local vibeshot_bin = "/home/YOU/.config/omarchy/plugins/aayork.vibeshot/capture.sh"
local reset_submap = [[hyprctl dispatch 'hl.dsp.submap("reset")']]

-- Hyprland execs capture.sh directly (never as a child of omarchy-shell).
-- Routing the interactive slurp/hyprpicker selection through a Quickshell
-- Process breaks hyprpicker's screen freeze and cuts slurp's selection short
-- on the first click — capture.sh must be launched by Hyprland itself, then
-- it hands the finished PNG to the plugin over `omarchy-shell shell call`.
hl.define_submap("screenshot", "escape", function()
  o.bind("3", "Screenshot (fullscreen)", reset_submap .. "; " .. vibeshot_bin .. " fullscreen")
  o.bind("4", "Screenshot (area)", reset_submap .. "; " .. vibeshot_bin .. " smart")
  o.bind("5", "Screenshot (window)", reset_submap .. "; " .. vibeshot_bin .. " windows")
end)

o.bind("PRINT", "Screenshot", vibeshot_bin .. " smart")
o.bind("SUPER + V", "Screenshot menu", hl.dsp.submap("screenshot"))

-- Mouse-clickable twin of the 3/4/5 chord: show the plugin's mode-picker
-- popup whenever the "screenshot" submap becomes active, hide it again on
-- any reset (successful pick or Escape) — both take this same path.
hl.on("keybinds.submap", function(name)
  if name == "screenshot" then
    hl.exec_cmd("omarchy-shell shell call aayork.vibeshot showMenu ''")
  else
    hl.exec_cmd("omarchy-shell shell call aayork.vibeshot hideMenu ''")
  end
end)

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

Heads up: while the `screenshot` submap is active (right after tapping
`SUPER+V`), a bare `3`/`4`/`5` keypress anywhere — including in a text field —
triggers a screenshot instead of typing that digit, until you press one of
them or Escape.

## Uninstall

```bash
omarchy plugin remove aayork.vibeshot
```

Then remove the `o.bind`/`hl.layer_rule` blocks you pasted into
`~/.config/hypr/bindings.lua`, and `hyprctl reload`.

```bash
rm -rf ~/.cache/aayork.vibeshot
```

## Why not just use the stock screenshot tool / omasnap?

The stock GTK-based editor (Tensaku) works fine but looks and feels like a
separate app. [omasnap](https://github.com/tobi/omasnap) is a great native
alternative but ships as its own compiled binary outside the Omarchy shell.
VibeShot is a plain Quickshell plugin — no compiling, no separate process,
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
