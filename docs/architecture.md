# HurleyMetric recording architecture

The Watch uses `WatchMotionRecordingKit.WatchRecordingCoordinator` for both
motion streams, timestamp projection, binary writing, pending transfer, and
retry. HurleyMetric enables the coordinator's optional Watch audio recorder.

The iPhone has three responsibilities:

1. `RecordingInboxStore` receives files, replaces duplicate deliveries
   idempotently, groups assets by UUID, and exposes complete or partial
   sessions.
2. `BinaryMotionReader` validates and decodes the device-motion and raw-
   accelerometer binaries, then keeps measured samples for graph review and
   overlay export. HurleyMetric does not run strike detection.
3. `PhoneVideoRecorder` starts movie capture during the scheduled pre-roll,
   records the first actual video frame timestamp, and stops only the matching
   session. `VideoOverlayExporter` uses that timestamp as the video anchor.

The shared binary package remains the source of truth for header layout,
record sizes, stream names, and metadata contracts. HurleyMetric should not
duplicate binary encoders or accept CSV as a runtime motion format.

## Recording startup and diagnostics

The Watch starts a short `HKWorkoutSession` before requesting the 200 Hz
device-motion and 800 Hz raw-accelerometer streams. The coordinator treats
the initial Core Motion frequency values as provisional: the first batches
confirm both streams, while a short startup timeout or callback error fails
the session. A failed Watch start sends the matching stop control to the
iPhone so a video pre-roll cannot remain running.

The coordinator, WatchConnectivity transport, and iPhone video recorder log
start requests, capabilities, callback failures, and capture-output errors
through `OSLog`. The on-device status remains concise; Xcode Console contains
the detailed failure context.

## Live Watch diagnostics

The live Watch graph is diagnostic-only and must never determine capture,
binary-writing, or transfer cadence. Device motion remains recorded at 200 Hz
and raw acceleration at 800 Hz on the coordinator's serial motion queue.

For the Watch UI, the coordinator keeps a 75-point device-motion magnitude
history, sampling every eighth accepted 200 Hz value (25 Hz), and publishes a
snapshot at most 10 times per second. The graph therefore shows a smooth
recent trend without making SwiftUI redraw for every sensor batch. When the
graph is hidden, its history is neither built nor published; the lightweight
latest-value and sample-count display remains throttled as well.

The graph starts hidden so a normal recording uses no live-chart work. When it
is enabled, its canvas is rendered asynchronously. The binary writer encodes
each batch directly into its preallocated payload and only sorts a sensor batch
when its timestamps are not already ordered. These performance details do not
change the binary contract or the native sensor data retained on disk.

## Transfer ordering

WatchConnectivity may deliver files in any order. The iPhone keeps each
received asset under its canonical filename and only binary decoding
requires the complete device-motion/raw-accelerometer/Watch-metadata set.
Phone video and phone metadata can arrive independently and are optional for
motion graph review.
