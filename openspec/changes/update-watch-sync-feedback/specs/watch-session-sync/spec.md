## ADDED Requirements

### Requirement: Watch transfer state is visible on both devices

The Watch SHALL publish whether recording files are queued and how many retained
sessions still require transfer. Both devices SHALL distinguish active sync from
idle availability.

#### Scenario: Watch has outstanding files

- **WHEN** one or more recording files are queued with WatchConnectivity
- **THEN** the Watch SHALL show a compact orange sync label with the pending-session count
- **AND** the Watch SHALL NOT show an activity indicator

#### Scenario: iPhone receives a file

- **WHEN** a Watch recording file is copied into the iPhone inbox
- **THEN** the iPhone SHALL show an activity indicator in an amber sync circle while receipt is active

#### Scenario: Final file completes

- **WHEN** the final outstanding Watch file completes and no session remains pending
- **THEN** the Watch SHALL show `All sessions synced`

### Requirement: Availability does not depend on immediate reachability

The iPhone SHALL present the Watch as available when WatchConnectivity is
activated, the Watch is paired, and the Watch app is installed.

#### Scenario: Background delivery is possible while live messaging is unavailable

- **WHEN** the Watch is paired with its app installed but `isReachable` is false
- **THEN** the iPhone SHALL NOT present the Watch as unavailable

### Requirement: Partial recordings can request retry

Refresh SHALL request retry of retained Watch files when the local inbox contains
a partial required motion set and immediate messaging is available.

#### Scenario: User refreshes a partial recording

- **WHEN** Refresh finds only part of the device-motion, raw-acceleration, and Watch-metadata set
- **THEN** the iPhone SHALL send the pending-transfer retry command when the Watch is reachable

#### Scenario: Watch reports retained sessions before any file arrives

- **WHEN** Refresh sees a positive pending-session count with no active Watch transfer
- **THEN** the iPhone SHALL send the pending-transfer retry command when the Watch is reachable
