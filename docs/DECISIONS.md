# Decisions

## 2026-08-04 — Decouple the Watch graph from high-rate capture

The Watch graph is a visual diagnostic rather than a recording source. The
coordinator records both native sensor streams without involving SwiftUI, but
samples device-motion magnitudes at 25 Hz into a 75-point display history and
publishes it at most 10 times per second. Turning the graph off disables that
history. This protects recording quality and battery life while preserving a
responsive live trace when the graph is useful for debugging.

## 2026-08-04 — Keep the Watch capture hot path allocation-light

The binary writer encodes each sensor record directly into a preallocated
per-batch payload rather than allocating an intermediate `Data` value per
sample. Batched sensor timestamps are checked for monotonic order and sorted
only when necessary. The graph is opt-in and renders asynchronously. These
changes preserve the binary bytes and all native samples while reserving more
Watch CPU and battery for recording itself.

## 2026-08-04 — Confirm high-rate motion from callbacks, under a workout session

HurleyMetric starts a Watch workout session before high-rate capture and does
not treat a zero frequency read immediately after Core Motion start as a
failure. Both native streams are confirmed by their first callbacks and a
short timeout handles genuine startup failures. If startup fails after the
iPhone accepts video pre-roll, the Watch sends a matching stop command.

## 2026-08-04 — Publish recording state on the main actor

Watch sensor callbacks and recording tasks remain off the main thread for
capture and file work, but every `@Published` recording-state update is
delivered through `MainActor`. This keeps SwiftUI observation safe without
moving high-rate sensor processing onto the UI thread.

## 2026-08-04 — Preserve native raw acceleration in review and export

HurleyMetric keeps every decoded 800 Hz raw-accelerometer sample in the raw
graph and overlay export. Device-motion hit ranges are positioned against that
graph by timestamp, while the model and the other review modes remain on the
200 Hz device-motion stream.

## 2026-08-02 — Use the shared binary pair as the HurleyMetric source format

HurleyMetric adopts the existing `WatchMotionRecordingKit` version-1 binary
contract: 200 Hz device motion and independent 800 Hz raw acceleration. This
keeps the debug app aligned with CamanLab and avoids CSV serialization at the
highest-rate path. Existing development CSV fixtures are not a supported
runtime input and should be regenerated as binary sessions when needed.

## 2026-08-02 — Keep phone first-frame timing as the video anchor

The phone starts movie capture during pre-roll, but alignment uses the first
video sample-buffer timestamp rather than the movie-output start callback. The
callback can occur before the first encoded frame and is therefore a weaker
anchor. Watch and phone planned-start values are still checked for session
validity.

## 2026-08-02 — Preserve Watch audio as an optional HurleyMetric asset

The shared motion coordinator supports optional audio capture so HurleyMetric
does not lose its existing audio recording behavior while CamanLab can keep
audio disabled. Audio is transferred with the motion binary pair but is not a
requirement for motion analysis.
