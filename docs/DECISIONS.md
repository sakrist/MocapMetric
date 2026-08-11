# Decisions

## 2026-08-09 — Rename the recording package extension

MocapMetric uses `<uuid>.mmrec` for the shared recording package. This is a
container-name change only: binary streams, JSON sidecars, and optional media
are unchanged, and old `.recording` directories are not accepted as packages.

## 2026-08-08 — Merge late optional assets before package export

WatchConnectivity may deliver audio after the iPhone has already assembled the
core recording package. Package assembly therefore reopens the existing
package and atomically merges late audio, video, or phone metadata before the
package is shared. The recording list and AirDrop export now describe the same
asset set.

## 2026-08-08 — Gate high-speed phone video behind an explicit recorder screen

MocapMetric replaces the iPhone video toggle with an `Open Video Recorder`
button. The full-screen recorder is the only state in which Watch video
preparation is accepted; opening it arms the camera, but the Watch remains the
only source of movie start and stop controls. Closing the idle recorder
disarms video, while motion-only Watch recordings remain valid when the
recorder is not open.

The camera selects the highest supported frame rate up to 240 fps and keeps the
full-screen status visible while a phone session is active. This favors precise
strike and motion review over battery savings when the user explicitly enters
video-recorder mode. Watch prepare reserves the matching session; only the
Watch `.start` control starts the movie file, and `.stop` finalizes it.

## 2026-08-07 — Motion recording does not depend on optional media

MocapMetric always starts a valid motion recording when the Watch has the
required workout and motion permissions. iPhone video is attempted only when
armed and reachable; a rejected or unavailable video preparation falls back to
an immediate motion-only start. Watch audio is also best effort, so a denied
microphone permission leaves out `.m4a` rather than failing motion capture.

The active recording screen shows elapsed Watch time from the actual capture
start in fixed `HH:mm:ss` format. The full-screen iPhone recorder is opened
before the Watch session; the Watch sends its stop control before draining
motion buffers, and the iPhone keeps the recorder visible until the video
container finishes writing.
The previous battery-conscious 60 fps setting is superseded by the explicit
240 fps recorder mode documented on 2026-08-08; the frame timestamp callback
still stops working after it captures the single first-frame timing anchor.

## 2026-08-06 — Use a folder package for portable recordings

MocapMetric persists one session as `<uuid>.mmrec`. The core
package contains the two native Watch binary streams and `.watch.json`; audio
is optional, while video requires `.phone.json`. WatchConnectivity remains
file-oriented for retryability, and the iPhone assembles or replaces packages
atomically after staging. The package has no extra manifest or converted copy
of the sensor data.

New package directories and assets use the UUID directly (`<uuid>.mmrec`,
`<uuid>.device-motion.bin`, and so on). Legacy prefixed loose filenames remain
readable where the shared filename parser supports them.

## 2026-08-06 — Remove strike detection from MocapMetric

MocapMetric remains a debugging/reference app for recording transfer,
binary validation, graph review, and video overlay export. It decodes native
device-motion and raw-accelerometer streams directly with `BinaryMotionReader`
and does not run strike detection or present hit ranges. Strike semantics stay
in the production-facing analysis path.

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

MocapMetric starts a Watch workout session before high-rate capture and does
not treat a zero frequency read immediately after Core Motion start as a
failure. Both native streams are confirmed by their first callbacks and a
short timeout handles genuine startup failures. If startup fails after the
iPhone accepts video preparation, the Watch sends a matching stop command.

## 2026-08-04 — Publish recording state on the main actor

Watch sensor callbacks and recording tasks remain off the main thread for
capture and file work, but every `@Published` recording-state update is
delivered through `MainActor`. This keeps SwiftUI observation safe without
moving high-rate sensor processing onto the UI thread.

## 2026-08-04 — Preserve native raw acceleration in review and export

MocapMetric keeps every decoded 800 Hz raw-accelerometer sample in the raw
graph and overlay export. The other review modes remain on the 200 Hz
device-motion stream.

## 2026-08-02 — Use the shared binary pair as the MocapMetric source format

MocapMetric adopts the existing `WatchMotionRecordingKit` version-1 binary
contract: 200 Hz device motion and independent 800 Hz raw acceleration. This
keeps the debug app aligned with CamanLab and avoids CSV serialization at the
highest-rate path. Existing development CSV fixtures are not a supported
runtime input and should be regenerated as binary sessions when needed.

## 2026-08-02 — Keep phone first-frame timing as the video anchor

Alignment uses the first video sample-buffer timestamp rather than the
movie-output start callback. The callback can occur before the first encoded
frame and is therefore a weaker anchor. Watch and phone planned-start values
are still checked for session validity. The explicit recorder mode starts the
movie from the Watch `.start` control; this supersedes the earlier pre-roll
implementation.

## 2026-08-02 — Preserve Watch audio as an optional MocapMetric asset

The shared motion coordinator supports optional audio capture so MocapMetric
does not lose its existing audio recording behavior while CamanLab can keep
audio disabled. Audio is transferred with the motion binary pair but is not a
requirement for motion analysis.
