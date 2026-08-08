## Context

MocapMetric has two independent user surfaces: an iPhone inbox and a Watch
recorder. The Watch coordinator already sends a prepare/start/stop control
sequence when phone coordination is enabled, and falls back to motion-only
recording when the iPhone is unavailable. The iPhone currently uses a toggle to
arm the capture session and a full-screen cover only while a remote video
session is active.

The desired interaction is explicit: the user opens the iPhone recorder first,
keeps it visible, and then starts/stops the recording from the Watch. The open
screen is the capability gate; no background or automatic UI action should arm
the camera.

## Goals / Non-Goals

**Goals:**

- Make the iPhone recorder a deliberate full-screen mode.
- Accept Watch video preparation only while that mode is open and the camera is
  configured.
- Preserve the existing Watch-controlled start/stop handshake and motion-only
  fallback.
- Capture up to 240 fps when the selected camera format supports it.
- Make recorder state obvious and keep the Back action safe during recording.

**Non-Goals:**

- Change Watch sensor rates, binary formats, package assembly, or timestamp
  schemas.
- Add an iPhone start/stop button for the recording itself.
- Automatically open the recorder in response to WatchConnectivity.
- Guarantee 240 fps on hardware or formats that do not expose it.

## Decisions

### The full-screen view is the video eligibility gate

`PhoneVideoRecorder` will expose explicit open/close operations. Opening sets
the recorder armed and starts camera preparation; closing disarms the recorder
and stops the local capture session. Watch prepare requests continue to be
rejected unless the recorder is armed and configured. The inline preview and
toggle are removed from the main inbox view.

This keeps the gate in the same object that receives Watch commands, instead of
making SwiftUI presentation state and capture eligibility drift apart.

### The Watch remains the only recording control

The full-screen iPhone view will show status but no recording start button.
The `.prepare` message reserves the matching phone session and returns the
shared start time. The `.start` message starts the movie output, and `.stop`
stops it. Opening the view only makes video available; it does not create a
recording.

Manual recorder mode will use a zero-second phone lead time. The camera capture
session is already running when the Watch sends prepare, so the existing
prepare/start/stop identity handshake remains useful without introducing the
old multi-second wait before the Watch session becomes active or starting a
movie before the Watch's explicit start control.

### Use the best available high-speed format up to 240 fps

Camera format selection will choose the highest supported frame rate no greater
than 240 fps, set matching frame durations, and use `.inputPriority` so the
selected high-speed format is respected. The configured rate is still logged
and shown in the recorder status. Devices without a 240 fps format use their
highest available supported rate.

### Back is unavailable while a phone session is active

The Back button closes the recorder only when no prepared remote session or
movie output is active. This avoids silently disabling the video gate or
abandoning a movie session while the Watch is recording. After the Watch stop
has completed, the user can leave the full-screen recorder.

## Risks / Trade-offs

- [High frame rate increases power, heat, and file size] → Use it only in the
  explicitly opened recorder and cap selection at 240 fps.
- [The first movie frame still arrives after the Watch control message] → Keep
  the camera stream live while the recorder is open and retain the first-frame
  timestamp anchor in phone metadata.
- [The user forgets to open the iPhone recorder] → Keep Watch motion-only
  fallback and log the rejected optional video request.
- [Movie finalization takes time after Watch stop] → Keep the recorder screen
  visible while active and update its indicator from the recorder lifecycle;
  do not present a second stop control on iPhone.

## Migration Plan

1. Add the OpenSpec contract and update the MocapMetric architecture decision.
2. Replace the iPhone video section with the open/close full-screen flow.
3. Update camera format selection and retain remote Watch control handling.
4. Build and run simulator tests, then verify a physical Watch/iPhone session
   with recorder closed and open.

Rollback is a source revert. Existing package readers and transferred assets
remain compatible because the recording format does not change.

## Open Questions

None for this change. The physical device determines the actual maximum frame
rate exposed by the selected camera format.
