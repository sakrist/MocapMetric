## Why

MocapMetric currently exposes video as an iPhone toggle and can present video
state independently of the actual recorder screen. That makes it unclear when
the Watch is allowed to request video and adds avoidable startup behavior. The
recorder should be an explicit full-screen mode that the user opens before a
Watch session, while the Watch remains responsible for recording start and
stop.

## What Changes

- Replace the iPhone video toggle and inline preview with one `Open Video Recorder`
  button.
- Make the full-screen recorder the only state in which Watch video requests
  are accepted.
- Keep Watch start and stop controls authoritative for the phone movie output.
- Remove the artificial multi-second lead for manually opened video; the camera
  stream is already live when the Watch requests a session.
- Show a Back button and a clear ready/recording indicator in the full-screen
  recorder; prevent leaving while a phone recording is active.
- Configure the camera for the highest available frame rate up to 240 fps.
- Keep motion-only Watch recording available when the recorder is not open.

## Capabilities

### New Capabilities

- `screen-gated-video-recording`: Manual full-screen video-recorder lifecycle,
  Watch eligibility, remote start/stop, and high-speed capture behavior.

### Modified Capabilities

None.

## Impact

- `MocapMetric/MocapMetric/Sources/ContentView.swift` changes the iPhone video
  section and full-screen recorder presentation.
- `PhoneVideoRecorder` owns the open/close gate, camera configuration, and
  remote movie lifecycle.
- `RecordingInboxStore` continues routing Watch prepare/start/stop messages.
- `MocapMetricWatch` and `WatchMotionRecordingKit` keep the existing optional
  phone-coordination fallback.
- No recording package filenames or binary formats change.
