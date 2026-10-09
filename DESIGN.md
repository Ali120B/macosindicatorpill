# macospills — shared pill design spec

One look, every desktop. All backends implement this spec; only the
overlay mechanism and caret source differ per compositor.

## The capsule

- Size: **46 × 30 px** (logical), fully round (`border-radius: 50%`).
- Fill: **`#0a84ff`** (macOS system blue — pops on dark windows and,
  with its shadow, on light ones).
- Shadow: soft, falling below the capsule. QML: stacked rings with
  quadratic alpha falloff (no shader). GNOME: `box-shadow`.
- Fades: **90 ms in / 140 ms out**, `OutCubic`. Re-pop restarts the
  fade-in from 0 (no blink-through-hide).

## The glyph

⇪ as macOS draws it — an **outlined arrow over a bar**, drawn as a path
(not a font glyph, so it never turns to tofu):

- 16 × 16 box. Arrow polyline:
  `(8,1.5) → (14.5,7) → (11,7) → (11,9.5) → (5,9.5) → (5,7) → (1.5,7) → close`
  stroke 1.6, round joins + caps.
- Bar: rounded rect `x=5, y=12, w=6, h=2.5, r=1`, same stroke, no fill.
- Ink: **`#ffffff`** (white) on the blue capsule.

## Placement

- Caret known: centered on the caret, just **below** it with a **6 px**
  gap; above it when there is no room below. Clamped to the monitor.
- No caret: the pill hides (KDE, Hyprland). GNOME centers it on the
  focused monitor at **92% height** (Solium's on-screen fallback) —
  showing a pill with nowhere to point was judged worse on the
  follow-the-caret backends.
- Follows the caret while visible where the platform allows it.

## Behavior

- **Held while Caps Lock is ON**, hidden when it goes off.
- **First-key arming**: appears only after live typing in the focused
  field — never on the caps toggle, a focus jump, or a mouse click.
  Arming latches till caps off / focus or click change / caret loss, so
  every field needs a fresh keypress, no exceptions.
  (Supersedes the old caps_on_focus re-pop: focus changes with caps on
  stay hidden until you type.)
- Caps-only. No layout/num pills.
- Caps state from the **kernel LED** (`/sys/class/leds/*capslock/brightness`).

## Layout flash

macOS flashes the input source ~1 s on switch. Same capsule, short
source label (`EN`, `ARA`) instead of ⇪; 46 px minimum width, grows
with the label.

- Shows for **1 s** on real layout switches, placed exactly like the
  caps pill (below the caret, 6 px capsule gap; above without room).
  Snaps on appear, follows the caret while showing.
- Same visibility rules: a known caret is required — never the
  fallback, never on the desktop. Re-switching restarts the hold.
  Needs no key-arming (the switch hotkey is the interaction).
- Precedence: a switch always preempts a showing caps pill for its
  second, then hands back to it. Caps turning on preempts a flash but
  stays hidden itself until a keypress (strict arming, no exceptions).
- The first value seen after start is the seed, never a flash.
