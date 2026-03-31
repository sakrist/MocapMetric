# HurleyMetric

HurleyMetric records Apple Watch motion data and audio, optionally records iPhone video for the same session, transfers everything to iPhone, and exports the data for later analysis.

## Data Collected

Each recording session can contain:

- Watch CSV: `recording_<session>.csv`
- Watch audio: `recording_<session>.m4a`
- iPhone video: `recording_<session>.mov`
- Watch sync sidecar: `recording_<session>.watch.json`
- iPhone sync sidecar: `recording_<session>.phone.json`

## CSV Format

The watch writes this header:

`timestamp,ax,ay,az,gx,gy,gz,grx,gry,grz`

Columns:

- `timestamp`: watch-side Unix seconds
- `ax, ay, az`: user acceleration
- `gx, gy, gz`: gyroscope rotation rate
- `grx, gry, grz`: gravity vector

## Recording Flow

The current sync flow is:

1. User arms iPhone video in the iPhone app.
2. User taps `Start` on Apple Watch.
3. Watch creates one shared `sessionID`.
4. Watch asks iPhone for a scheduled future start time using WatchConnectivity.
5. iPhone chooses `plannedStartUnix = now + leadTime`.
6. iPhone starts video pre-roll immediately.
7. iPhone writes `recording_<session>.phone.json` with:
   - `sessionID`
   - `plannedStartUnix`
   - `preRollStartUnix`
   - `actualVideoStartUnix` initially `null`
   - `syncFlashUnix`
8. iPhone shows a sync flash at `plannedStartUnix`.
9. Watch receives `plannedStartUnix` and waits until that time.
10. Watch records `actualWatchStartUnix` when recording actually begins.
11. Watch writes `recording_<session>.watch.json` with:
    - `sessionID`
    - `plannedStartUnix`
    - `actualWatchStartUnix`
    - `requestedDeviceMotionInterval`
12. Watch starts:
    - motion logging
    - watch microphone recording
13. iPhone now writes `actualVideoStartUnix` when the first actual video frame is observed through `AVCaptureVideoDataOutput`.
14. When recording stops, watch transfers CSV, audio, and watch sidecar to iPhone.
15. iPhone groups all files by `sessionID` and shows the session in the recordings list.

## Meaning Of The Sidecars

`recording_<session>.phone.json`:

- `plannedStartUnix`: future start time chosen by iPhone and sent to watch
- `preRollStartUnix`: when iPhone started video recording before the planned start
- `actualVideoStartUnix`: estimated Unix time of the first actual recorded video frame
- `syncFlashUnix`: when iPhone showed the visual sync flash

`recording_<session>.watch.json`:

- `plannedStartUnix`: same planned time received from iPhone
- `actualWatchStartUnix`: watch wall-clock time when watch recording actually began
- `requestedDeviceMotionInterval`: requested Core Motion interval

## How Export Alignment Works

The app export path uses both sidecars.

Current alignment model:

1. Verify `phone.sessionID == watch.sessionID`.
2. Verify `phone.plannedStartUnix` and `watch.plannedStartUnix` match within tolerance.
3. Estimate watch-to-phone clock correction:

`watchToPhoneClockOffset = phone.plannedStartUnix - watch.actualWatchStartUnix`

4. Convert each watch CSV sample into iPhone video-relative time:

`videoRelativeTime = sample.timestamp + watchToPhoneClockOffset - phone.actualVideoStartUnix`

This is the model used by the iPhone exporter and should also be used by any external analysis tool if you want results to match the app.

## Using The Files In External Tools

External tools should:

1. Read:
   - CSV
   - `recording_<session>.phone.json`
   - `recording_<session>.watch.json`
2. Parse the first CSV column as watch-side Unix seconds.
3. Compute:

`watchToPhoneClockOffset = phone.plannedStartUnix - watch.actualWatchStartUnix`

4. Convert every CSV timestamp:

`phoneEquivalentUnix = csvTimestamp + watchToPhoneClockOffset`

5. Convert to video timeline:

`videoTimeSeconds = phoneEquivalentUnix - phone.actualVideoStartUnix`

6. Plot IMU against `videoTimeSeconds`.

The same data can also be used to trim or offset video in external tools.

## Current Sources Of Error

The current sync path is better than a simple `sample.timestamp - actualVideoStartUnix` model, but it still has error sources:

1. Watch CSV sample timestamps are written with `Date().timeIntervalSince1970` inside the motion callback.
   - This is callback wall-clock time, not the original Core Motion sample timestamp.
2. `actualVideoStartUnix` is now tied to the first observed video frame, which is better than the movie output start callback, but it is still reconstructed from callback time plus capture clock timing.
3. Watch and iPhone clocks are not explicitly calibrated with a round-trip clock sync protocol.
4. The sync flash is not yet used as a measured alignment event in the app export math.

## Recommended Simplifications And Improvements

If the goal is lower sync error, the highest-value changes are:

1. Use Core Motion relative timestamps on watch.
   - Capture a watch wall-clock anchor once at start.
   - Convert `CMDeviceMotion.timestamp` deltas into Unix time.
   - This is the biggest remaining improvement on the watch side.
2. Keep the current phone first-frame anchor.
   - This is already better than the old movie-output callback timestamp.
3. Keep one planned start value chosen by iPhone.
   - This is simpler and more defensible than trying to start “immediately”.
4. Use the sync flash in external tooling as a verification marker.
   - It gives a visible event in video and a known target time in metadata.

If you want the simplest model with fewer moving parts, the most realistic simplification is:

- keep scheduled start
- keep phone first-frame timestamp
- change only watch sample timestamp generation to use Core Motion deltas

That removes the largest remaining timing ambiguity without redesigning the architecture.

## How To Record And Export

1. Open the iPhone app.
2. If needed, enable iPhone video recording.
3. Open the watch app.
4. Tap `Start`.
5. Wait for the watch armed countdown.
6. Perform swings.
7. Tap `Stop`.
8. Open the iPhone recordings list.
9. Share the session to Mac with AirDrop or Files.

## Key Files

- Watch recorder: `HurleyMetricWatch Watch App/AccelerometerLogger.swift`
- Watch transfer: `HurleyMetricWatch Watch App/WatchRecordingTransferManager.swift`
- iPhone recorder: `HurleyMetric/PhoneVideoRecorder.swift`
- iPhone inbox/receiver: `HurleyMetric/RecordingInboxStore.swift`
- iPhone export alignment: `HurleyMetric/VideoOverlayExporter.swift`
- iPhone recordings UI: `HurleyMetric/ContentView.swift`
