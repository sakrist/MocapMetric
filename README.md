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
9. Watch receives `plannedStartUnix` and starts motion/audio pre-roll locally.
10. Watch discards motion samples whose computed Unix timestamp is before `plannedStartUnix`.
11. Watch writes `recording_<session>.watch.json` with:
    - `sessionID`
    - `plannedStartUnix`
    - `actualWatchStartUnix`
    - `requestedDeviceMotionInterval`
12. Watch starts:
    - motion delivery before the sync point
    - watch microphone recording scheduled against the same wall-clock start
    - one watch wall-clock anchor is captured on the first motion sample
    - later CSV timestamps are derived from `CMDeviceMotion.timestamp` deltas
    - only samples at or after `plannedStartUnix` are written to CSV
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
- `actualWatchStartUnix`: Unix time of the first motion sample that was kept and written to CSV
- `requestedDeviceMotionInterval`: requested Core Motion interval

## How Export Alignment Works

The app export path uses both sidecars.

Current alignment model:

1. Verify `phone.sessionID == watch.sessionID`.
2. Verify `phone.plannedStartUnix` and `watch.plannedStartUnix` match within tolerance.
3. Use the iPhone video anchor:

`actualVideoStartUnix = phone.actualVideoStartUnix`

4. Convert each watch CSV sample into iPhone video-relative time:

`videoRelativeTime = sample.timestamp - phone.actualVideoStartUnix`

Why watch actual start is not used as a correction term:

- `plannedStartUnix - actualWatchStartUnix` mixes two different effects:
  - device clock offset
  - watch-side start latency
- if the watch starts late, applying that term shifts the entire IMU trace too early in video
- empirical comparison against recorded sessions showed this over-correction in practice

So the app now uses watch sidecars for validation and diagnostics, but anchors the overlay timeline to `actualVideoStartUnix`.

## Using The Files In External Tools

External tools should:

1. Read:
   - CSV
   - `recording_<session>.phone.json`
   - `recording_<session>.watch.json`
2. Parse the first CSV column as watch-side Unix seconds.
3. Validate:

- `phone.sessionID == watch.sessionID`
- `abs(phone.plannedStartUnix - watch.plannedStartUnix)` is small

4. Convert every CSV timestamp:

`phoneEquivalentUnix = csvTimestamp`

5. Convert to video timeline:

`videoTimeSeconds = phoneEquivalentUnix - phone.actualVideoStartUnix`

6. Plot IMU against `videoTimeSeconds`.

The same data can also be used to trim or offset video in external tools.

## Current Sources Of Error

The current sync path is better than a simple `sample.timestamp - actualVideoStartUnix` model, but it still has error sources:

1. Watch CSV timestamps now use one wall-clock anchor plus `CMDeviceMotion.timestamp` deltas.
   - This removes per-sample callback jitter.
   - Watch motion now pre-rolls before the agreed sync time, so first-kept-sample latency is reduced versus starting Core Motion exactly at the target instant.
   - The remaining watch-side error is still tied to the first anchor callback timing.
2. `actualVideoStartUnix` is now tied to the first observed video frame, which is better than the movie output start callback, but it is still reconstructed from callback time plus capture clock timing.
3. Watch and iPhone clocks are not explicitly calibrated with a round-trip clock sync protocol.
4. The sync flash is not yet used as a measured alignment event in the app export math.
5. The current export model intentionally does not apply a watch-start correction because that term also contains watch-side start latency and can over-correct.

## Recommended Simplifications And Improvements

If the goal is lower sync error, the highest-value changes are:

1. The watch now uses Core Motion relative timestamps for CSV samples and pre-rolls motion before the agreed sync point.
   - Remaining improvement would be to tighten the first sample anchor further or store extra timing anchors in metadata.
2. Keep the current phone first-frame anchor.
   - This is already better than the old movie-output callback timestamp.
3. Keep one planned start value chosen by iPhone.
   - This is simpler and more defensible than trying to start “immediately”.
4. Use the sync flash in external tooling as a verification marker.
   - It gives a visible event in video and a known target time in metadata.

If you want the simplest model with fewer moving parts, the most realistic simplification is:

- keep scheduled start
- keep phone first-frame timestamp
- keep watch sample timestamp generation based on Core Motion deltas
- avoid adding more sync layers until there is measurement proving they help

That keeps the architecture understandable while removing the largest per-sample timing ambiguity.

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
