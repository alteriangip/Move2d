# M0 Results: Touch Input (run 3) and Navigation Prototype

Raw data: [ipad-run3-touch.json](ipad-run3-touch.json) (submitted 2026-11-07 10:38 UTC,
Claude app, **460 px side panel** again).

## What the touch run shows

| Measure | Result | Meaning |
|---------|--------|---------|
| Finger strokes | 992 touch moves, ~59 Hz (display rate) | Touch input reaches the page normally |
| Simultaneous contacts | **up to 5** | Multi-touch is fully available, so two-finger navigation is implementable |
| Safari pinch/rotate gestures | 422 `gesture*` events, all prevented; **page zoom never changed** | The page-zoom guards work |
| Long-press | detected twice by our 500 ms recognizer; **0 system context menus** | The custom long-press menu design works |
| Pencil | 734 moves, median interval 4 ms (≈250 Hz; run 1: 118 Hz), 229 pressure levels, tilt −18…64° | Pencil input is rich; pressure stays optional |
| **Touch cancels** | **16 of 42 touches were cancelled by the system** | Unexplained (see below) |
| Palm during Pencil | Not captured (0 touches began while the Pencil was down) | Either iPadOS rejected the palm before it reached the page, or the step was skipped |
| Largest contact | 271 px wide | Palms arrive as touches with a large contact size, which gives a usable palm signal |
| Selection changes | 23 | Text selection activity during the test. M1 keeps `user-select: none` on everything except text fields |
| Scribble | Not repeated (run 1: no interference) | — |

**"Pinch and pan don't work" (tester note).** That was correct and was the lab's fault: the
touch-logger box only records events and never implemented navigation, and its instruction wrongly
implied it would pan and zoom. The instruction is corrected. A real navigation prototype was
added (below) so navigation can be judged by hand.

**Touch cancels.** The cause is unknown. The candidates are the Claude app's side panel taking
over gestures, and iPadOS system gestures (4–5 finger pinch/swipe; 5 simultaneous contacts were
seen). The new prototype logs each cancel's context (number of contacts, duration, contact size,
whether a gesture was active) so the cause can be identified.

## New in lab v3: Canvas navigation prototype

A working implementation of the editor's planned viewport input policy (doc 01 §1.7.3):

- two fingers: pan + pinch-zoom + rotate, computed as the similarity transform that keeps both
  contacts fixed on the artwork (unit-tested);
- one finger: pan; Pencil: draws strokes that stay attached to the artwork;
- palm rejection: touches with a contact width ≥ 40 px, or starting while the Pencil is down,
  are ignored;
- the camera is updated **once per frame** from the latest contact positions.

Verified in the container with real CDP multi-touch: a 100 → 300 px pinch with a 0.2 rad twist
gives exactly 3.00× zoom and 11.5° rotation; a large (120 px) contact is classified as a palm;
0 cancels; no page zoom.

**Bug found and fixed while verifying:** the first version updated the camera on every
pointer event. Between the two fingers' events the camera briefly saw one finger updated and the
other not. That showed up as a phantom 3.3× zoom and 14.1° rotation in the metrics. Those states
were never drawn, but in the editor they would have been wasted work and a source of jitter.
**Architecture rule for M1: gesture input is accumulated and applied once per frame.**

## Needed: run 4 (about 3 minutes)

In the lab, opened **full screen** (not in the side panel):

1. **Canvas navigation**: follow the 6 steps, rate how it felt, tap Finish.
2. Enter the **device label** (iPadOS version, Pencil model).
3. Submit.
