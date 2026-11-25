# Noodlet recordings: frame timing report

Measured on 2026-11-24 with `Applet/scripts/test-rendering.sh` on an M1 Max, three noodlets, each recorded for **60 seconds** with its window hidden and again in front.

## Summary

| Noodlet | Hidden before | Hidden after | In front | Dropped frames |
|---|--:|--:|--:|--:|
| Orbit | 12 fps | 30 fps | 30 fps | 0 |
| Particles | 9 fps | 30 fps | 30 fps | 0 |
| Hit & Run | 14 fps | 30 fps | 29.8 fps | 3 |

Hidden recordings now match recordings in front. The three frames Hit & Run drops in front are the game's own loading pauses, *not* the recorder.

## What changed

1. A hidden page gets no animation frames, so the recorder drives its own clock.
2. Timers and animations hold between frames, so a frame never sees half a step.
3. A test films a moving square and checks every frame is 1/30 s apart.

> Recording in real time can only be as smooth as the page is drawn. Recording frame by frame is as smooth as the clock.

## Follow-ups

- [x] Frame spacing test in CI
- [x] Hidden-window recordings on the Mac
- [ ] Same check on iPhone
- [ ] Audio kept in step when frames take longer than 1/30 s

```swift
for frame in 0..<frames {
    await page.advance(to: Double(frame) / 30)
    try await encoder.append(page.snapshot())
}
```
