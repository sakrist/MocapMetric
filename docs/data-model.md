# MocapMetric recording data model

## Session identity

Every new recording uses one lowercase UUID string. The same ID is used in
Watch filenames, Watch metadata, WatchConnectivity control messages, phone
video filenames, and the iPhone recording group.

## Canonical assets

A complete Watch motion session contains:

- `<uuid>.device-motion.bin`: version-1, little-endian, 64-byte
  header followed by 60-byte Float32 device-motion records. The native stream
  is 200 Hz.
- `<uuid>.raw-accelerometer.bin`: version-1, little-endian, 64-byte
  header followed by 20-byte Float32 raw-acceleration records. The native
  stream is 800 Hz and has its own timestamps.
- `<uuid>.watch.json`: finalized counts, sizes, SHA-256 hashes,
  format versions, frequencies, and session timing.

MocapMetric may also include `<uuid>.m4a` from the Watch and
`<uuid>.mov` plus `<uuid>.phone.json` from the iPhone.
Audio and video are optional; the two motion binaries and Watch sidecar are
required for graph review.

The canonical persisted form is a folder-based package:

```text
<uuid>.mmrec/
├── <uuid>.device-motion.bin
├── <uuid>.raw-accelerometer.bin
├── <uuid>.watch.json
├── <uuid>.m4a                 optional
├── <uuid>.mov                 optional
└── <uuid>.phone.json          required when video exists
```

The iPhone keeps the package as raw assets. It does not create CSV files or
store decoded motion samples in the session record. Transfer callbacks may
stage individual files temporarily, but only a validated package is shown as
complete.

## Analysis views

The review graph uses measured 200 Hz device-motion samples for acceleration,
gyro, gravity, and magnitude modes. Raw acceleration mode uses every measured
800 Hz raw sample. The two streams are never assumed to align by row index,
and MocapMetric does not derive strike ranges from either stream.

Video overlay time is calculated as:

```text
sampleUnixSeconds - phone.actualVideoStartUnix
```

`actualVideoStartUnix` is captured from the first observed video sample-buffer
timestamp. The Watch start timestamp is retained for validation and diagnosis,
not used as a clock correction.
