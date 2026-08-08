## 1. OpenSpec and architecture

- [x] 1.1 Validate the screen-gated video requirements and design.
- [x] 1.2 Record the explicit full-screen video gate and 240 fps decision in
  `docs/DECISIONS.md` and `docs/architecture.md`.

## 2. iPhone recorder UI

- [x] 2.1 Replace the video toggle and inline preview with `Open Video Recorder`.
- [x] 2.2 Add full-screen ready/starting/recording status and Back behavior.
- [x] 2.3 Keep the full-screen recorder open while a prepared remote session or
  movie output is active and disarm it when Back closes an idle recorder.

## 3. Capture and Watch integration

- [x] 3.1 Gate Watch video preparation on the explicitly opened and configured
  recorder.
- [x] 3.2 Preserve Watch-controlled prepare/start/stop and motion-only fallback
  when the recorder is closed, with zero lead time in manual recorder mode.
- [x] 3.3 Select and configure the highest supported camera rate up to 240 fps.
- [ ] 3.4 Add focused tests for closed/open eligibility and high-speed format
  selection where the platform permits.

## 4. Verification

- [x] 4.1 Run OpenSpec strict validation.
- [x] 4.2 Build MocapMetric iPhone and Watch targets and run tests.
- [ ] 4.3 Verify on physical iPhone/Watch: closed recorder gives motion-only,
  open recorder accepts Watch video, Watch start/stop controls the movie, and
  Back is unavailable while recording.
