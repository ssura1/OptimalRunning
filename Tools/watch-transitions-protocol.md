# Hardware protocol — transitions, manual advance, and the metrics page

Short companion to [`watch-hardware-protocol.md`](./watch-hardware-protocol.md), covering only
what changed in T-103, T-104 and T-105. Everything here needs a wrist: it is either a
perception question (is a haptic *felt*, is a number *legible*) or a system-gesture question,
and neither is something a test can answer.

Run it as **one interval session, roughly 20 minutes**. Preset: Intervals, 4 × 400 m work /
200 m recovery. Wear the watch — do not run this with the watch on a charger, or auto-lock
will interfere.

> **Before you start:** Settings → confirm **Crown advance** is on. It now defaults on
> (T-105); this is checking the default actually arrived, not switching it on.

---

## Section A — the metrics page, standing still (2 min)

Do this before moving, in good light.

| # | Do | What to record |
|---|---|---|
| A.1 | Start the Interval run. Look at the metrics page without deliberately focusing. | Can you read **distance** at a glance? It moved from 15 pt to 19 pt and onto the same row as average pace (T-103). |
| A.2 | Read all five metrics: elapsed, heart rate, rolling pace, average pace, distance. | Any of them **truncated**, overlapping, or visibly shrunk? The worst case now clears a 40 mm screen by under 1 pt, so this is the check that matters most. |
| A.3 | Settings → Accessibility → **largest** Dynamic Type size. Return to the run. | Same question. The measured budget only covers the *default* size — this is the case AC-FR-A-6-5 does not require but the page should survive. |
| A.4 | Set text size back. | — |

**If A.2 or A.3 shows truncation**, note which metric and at which size, and stop treating the
budget as sufficient — it means the mirror in `MetricsTypography.worstCaseChildren` has drifted
from the view.

---

## Section B — the W/R marker (during the reps)

| # | Do | What to record |
|---|---|---|
| B.1 | During a **work** rep, glance at the header. | Is the `W` chip obvious? Colour is amber. |
| B.2 | During a **recovery**, same. | `R`, cyan. Can you tell which phase you are in **without reading**, purely from the chip colour? |
| B.3 | Cover the chip's colour mentally — just the letter. | `W` vs `R` distinguishable by shape alone? This is the channel that has to work; the colour is the fast one, not the reliable one. |
| B.4 | If the display goes always-on (wrist down, screen dims). | Is the chip still legible dimmed? A separate swatch is chosen for the dimmed background. |

---

## Section C — transitions (the point of the outing)

There are two kinds of boundary and they are reached differently. **Both must be felt.**

| # | Moment | How it ends | What to record |
|---|---|---|---|
| C.1 | **Warm-up → work** | You end it: **tap the screen** | Haptic felt? How long between your tap and the buzz? (up to ~1 s is expected — advance rides the next tick) |
| C.2 | **Work → recovery**, first rep | Automatic, at 400 m | Haptic felt? Felt **without looking**? |
| C.3 | **Recovery → work**, rep 2 | Automatic, at 200 m | Haptic felt? Same as C.2, or noticeably weaker? |
| C.4 | Remaining reps | Automatic | Any boundary you did **not** feel — note which |

**C.5 — the negative control.** Mid-rep (during a 400 m work step), tap the screen. Nothing
should happen: no advance, **and no haptic**. A buzz here would teach you the tap worked.
Record whether anything happened.

---

## Section D — the three ways to advance

Only testable on an **open-goal** step, so do these during the warm-up of a second short run
(or restart and use the warm-up).

| # | Method | Attempts needed |
|---|---|---|
| D.1 | **Screen tap** | ___ / 3 |
| D.2 | **Digital Crown rotation** | ___ / 3 |
| D.3 | **Double Tap** (pinch twice) | ___ / 3 — this took 5 attempts before; it is no longer depended on, so a poor score here is informative rather than blocking |

**D.4 — the interaction worth watching.** With crown advance now on by default, the crown is
captured on the metrics page. Does **paging** between run screens still work normally? If the
crown now fights the pager, that is a regression introduced by the default change and is the
one thing in this document that would send T-105 back.

---

## Recording sheet

Copy this out and fill it in.

```
A.1 distance readable at a glance?      Y / N
A.2 truncation at default type size?    Y / N   which: ______
A.3 truncation at largest type size?    Y / N   which: ______
B.2 phase obvious from chip colour?     Y / N
B.3 W vs R distinguishable by shape?    Y / N
B.4 chip legible when dimmed?           Y / N

C.1 warm-up end (tap)   felt? Y / N   delay: ___ s
C.2 work -> recovery    felt? Y / N
C.3 recovery -> work    felt? Y / N
C.4 boundaries missed:  ______________________
C.5 mid-rep tap did nothing, silently?  Y / N

D.1 tap        ___ / 3
D.2 crown      ___ / 3
D.3 double tap ___ / 3
D.4 paging still normal with crown on?  Y / N
```

---

## What this outing still cannot close

| Question | Why not |
|---|---|
| Whether the sync fix works end to end | Different protocol, different run — needs the phone alongside and a completed run |
| Haptic distinctness between `slowDown`, `speedUp` and `stepTransition` | Needs a run with pace alerts firing; this session's preset has no `workTarget`, so no pace judging happens during reps |
| Battery cost of crown capture | Too small to read over 20 minutes |
