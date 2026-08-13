## Why

MocapMetric uses the current shared Watch transfer coordinator, but its app UI
does not consume the coordinator's transfer state. The Watch gives no indication
that queued sessions are moving, and the iPhone only reports the last received
filename without distinguishing availability, waiting, transfer, or completion.

## What Changes

- Publish Watch recording, queued-transfer, and pending-session state to iPhone.
- Show compact sync feedback on Watch without an activity indicator.
- Show active transfer or receipt on iPhone with an amber activity indicator.
- Treat paired/installed Watch state as availability rather than immediate-message
  reachability.
- Make Refresh re-request incomplete Watch assets when immediate messaging is
  available.

## Impact

This changes sync state and presentation only. Recording assets, `.mmrec`
assembly, video coordination, and binary formats remain unchanged.
