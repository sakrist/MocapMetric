# MocapMetric

MocapMetric is a debugging and reference app for recording Apple Watch motion
data and reviewing it alongside optional Watch audio and iPhone video.

It records two independent native motion streams:

- Device motion at 200 Hz
- Raw acceleration at 800 Hz

The streams use timestamped binary files with integrity metadata. They are not
row-aligned, so analysis uses their recorded timestamps rather than assuming
matching sample indexes.

## Recording packages

Each session is stored and shared as a `<uuid>.recording` folder containing:

- `<uuid>.device-motion.bin`
- `<uuid>.raw-accelerometer.bin`
- `<uuid>.watch.json`
- Optional `<uuid>.m4a` audio
- Optional `<uuid>.mov` video with `<uuid>.phone.json` metadata

WatchConnectivity may transfer files individually, but the iPhone only exposes
the session after the required files have been assembled and validated.

## Synchronization

When iPhone video is enabled, the iPhone chooses a planned start time and
records a visual sync event. The Watch records motion and audio against that
same time. Export alignment uses the timestamp of the first actual iPhone video
frame as the video anchor:

```text
video-relative-time = watch-sample-time - actual-video-start-time
```

The Watch and iPhone sidecars contain session identity, planned and actual
start times, frequencies, sample counts, file sizes, and hashes.

## Scope

MocapMetric is intended for recording validation, graph review, audio/video
alignment, and data export. It does not perform strike detection or claim that
IMU-derived trajectory or hand-speed values are ground truth.

To use it, start a session on the Watch, perform the recording, stop the
session, and share the resulting recording package from the iPhone.
