# UI.md — interface contract

Overrides section 6 of `SPEC.md`. Where the two disagree, this file wins.
Visual reference: `loupe-preview.html`.

## Audience

A person who does not know what swap is must still know what to do. Write for them first.
Technical detail is available, never required.

## Structure

Panel is 400 pt wide. Three fixed zones, top to bottom.

1. **Verdict.** State dot, machine name, one headline sentence, one explaining sentence,
   and up to two buttons. This is the only zone that is always visible.
2. **Tabs.** Overview, Apps, Storage, Health. `NSSegmentedControl` or SwiftUI `Picker`.
   Selection persists between openings.
3. **Body.** Tab content. Footer with Clean up, Settings, Quit.

Tabs are named after questions, not metrics:

| Tab | Question | Content |
|---|---|---|
| Overview | Is something wrong right now? | 2×2 tiles, then the reason behind any flagged one |
| Apps | What is causing it? | Metric selector, share bar, ranked list, core grid |
| Storage | Where did my disk go? | Treemap and large files from `mo analyze` |
| Health | Is my Mac in good shape? | Battery, thermal, uptime, pressure score |

## Charts

Three types. Nothing else. No pie, donut, gauge, dial, or radial anything.

**Stat tile.** 180×92. Label with state dot, big number with unit, one line of context,
micro-sparkline bleeding to the bottom edge. Four per Overview.

**Share bar.** One 368×12 horizontal bar split into segments by app, greyscale ramp, with
"Everything else" as the final darkest segment. Answers whether one app is the problem or
everything is. Sits above the ranked list, never per row.

**Micro-sparkline.** 46×15, last 60 s, one per app row. Carries direction only. Pair it
with an arrow glyph so direction is not encoded in shape alone.

**Core grid.** One rounded block per core, fast cluster and efficient cluster separated by
a gap, labelled in plain words. Apple Silicon only; on Intel show a flat grid with no split.

**Removed: full-width track bars per row.** They spent most of their ink on the empty part
and encoded one number each. Do not reintroduce them anywhere.

## Rules

- **Words before numbers.** Every tab opens with a sentence. Every flagged reading gets a
  plain-language reason: "Your Mac has started moving data to disk, which is slower than
  memory", not "pressure: warn".
- **Every number has a denominator.** "21.0 GB of 24 GB". A bare figure is unjudgeable.
- **Plain names in the interface, technical names in tooltips.** "10 fast cores" on screen,
  "performance cluster, `hw.perflevel0`" on hover. Same for pressure, swap, and impact.
- **Direction is a first-class reading.** 88% and falling is fine; 72% and climbing is not.
  Every tile and row shows which way it is moving.
- **Colour is an alarm.** Greyscale until a threshold is crossed, then amber for warn and
  red for critical. Always pair colour with a shape or word so it is not the only signal.
- **A grey dot means checked and fine.** Never leave a normal reading unmarked; silence
  reads as "not measured".
- **Tabular figures on every changing number.** `.monospacedDigit()`.
- **No animation on values.** Animate tab transitions only.
- **State freshness is visible.** "Last checked 2 seconds ago" in the verdict zone. When
  the feed drops, that line ages in place rather than the numbers going quietly stale.

## The calm state is a designed state

Most openings find nothing wrong. That view must look deliberate, not broken.

Headline "Nothing needs your attention". All four tiles grey with grey dots. The reason
block reads "Every check passed. Nothing to explain." Body is shorter than the alarm state;
the panel shrinks to fit.

If the calm state looks like a malfunction, people stop trusting the alarm state.

## Actions belong next to the cause

Naming Chrome and making the user go find it is half an answer. The verdict zone carries
Quit for the named app, with a confirmation sheet. Never offer Force Quit on anything under
`/System` or `/usr/libexec`.

## First run

Three screens, shown once, skippable: what the menu bar shape means, what amber means,
where the tabs are. Store completion in `UserDefaults`.

## Configuration

`panels.toml` still drives the Overview tiles and the Apps metric list, per spec 6.6. The
four tabs are fixed and not user-configurable. Tabs are the information architecture;
letting users rearrange them removes the thing that makes the app legible.

## Accessibility

Every tile and chart gets an `accessibilityLabel` and `accessibilityValue` in the same plain
words shown on screen. The verdict headline is the panel's accessibility summary. Honour
reduce-motion and increase-contrast. Full keyboard navigation: tab between zones, arrows
within a list, `⌘1`–`⌘4` for tabs, Escape closes.
