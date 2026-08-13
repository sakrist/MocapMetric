## Approach

The Watch publishes `WatchRecordingStateContext` whenever recording state,
outstanding file-transfer state, or pending-session count changes. The shared
coordinator remains the source of transfer truth and already excludes a completed
file from the remaining queue count, allowing the last transfer to clear sync.

The Watch screen shows one compact orange text label while idle: `Syncing N
sessions`, `N sessions waiting to sync`, or `All sessions synced`. It does not add
a spinner to the constrained Watch layout and does not compete with active
recording or countdown feedback.

`RecordingInboxStore` consumes live messages and application context, tracks
paired/installed availability, and marks each incoming file callback as active
receipt for three seconds. The recording-list screen renders this as a small
status card. Active sync uses an amber circle and spinner; recording remains red,
available is green, and unavailable is grey.

Refresh reloads the local inbox and asks a reachable Watch to retry files when a
session has only part of its required motion set or the Watch reports a retained
pending session with no active transfer. Immediate reachability is used only for
that command, not for the user-facing availability label.

## Verification

Add state tests for complete versus partial motion sets and Watch context
application. Build the iPhone target with its embedded Watch app, run the
MocapMetric test target, and validate this OpenSpec change strictly.
