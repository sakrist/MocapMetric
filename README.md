# HurleyMetric

HurleyMetric records hand swing motion on Apple Watch and makes recordings available on iPhone for sharing (for example via AirDrop to Mac).

## Data Flow

Current implementation direction is:

1. Apple Watch collects motion samples.
2. Apple Watch writes each recording to a CSV file.
3. When recording stops, watch sends the CSV to iPhone using WatchConnectivity file transfer.
4. iPhone stores received CSV files in its local `WatchRecordings` folder.
5. iPhone app shows recordings list and allows sharing each file (AirDrop, Files, etc.).

Note: Data is **not** collected on phone and sent to watch in the current app.

## CSV Format

Each recording uses this header:

`timestamp,ax,ay,az,gx,gy,gz,grx,gry,grz`

Columns:

- `timestamp`: Unix time in seconds
- `ax, ay, az`: user acceleration
- `gx, gy, gz`: gyroscope rotation rate
- `grx, gry, grz`: gravity vector

## How To Record And Export

1. Open watch app on Apple Watch.
2. Tap `Start`.
3. Perform swings.
4. Tap `Stop`.
5. Open iPhone app and wait for transfer.
6. In `Watch Recordings`, tap share icon on a file.
7. Select AirDrop and send to your Mac.

## Key Files

- Watch recorder: `HurleyMetricWatch Watch App/AccelerometerLogger.swift`
- Watch transfer: `HurleyMetricWatch Watch App/WatchRecordingTransferManager.swift`
- iPhone inbox/receiver: `HurleyMetric/RecordingInboxStore.swift`
- iPhone recordings UI: `HurleyMetric/ContentView.swift`
