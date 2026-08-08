## ADDED Requirements

### Requirement: Explicit video recorder opening

The iPhone app SHALL replace the video toggle and inline preview with one
`Open Video Recorder` action. Activating the action SHALL present a full-screen
video recorder and make the phone eligible for Watch video preparation. No
automatic view presentation or camera arming SHALL occur when the app launches
or when a Watch message arrives.

#### Scenario: User opens the video recorder

- **WHEN** the user taps `Open Video Recorder`
- **THEN** the app presents the full-screen recorder and begins preparing the
  camera

#### Scenario: Watch requests video while recorder is closed

- **WHEN** the Watch sends a video prepare request while the full-screen
  recorder is not open
- **THEN** the iPhone rejects the optional video request and the Watch remains
  able to record motion without video

### Requirement: Full-screen recorder controls

The full-screen recorder SHALL show a Back button, the current camera status,
and a clear indicator distinguishing ready, starting, and recording states. The
Back button SHALL close the recorder and disarm the camera only when no
prepared remote session or movie output is active.

#### Scenario: Recorder is ready

- **WHEN** the full-screen recorder is open and no Watch recording is active
- **THEN** it shows a ready/not-recording state and does not create a video file

#### Scenario: Back is tapped while recording

- **WHEN** a phone video session is prepared or movie output is active
- **THEN** the Back action is unavailable and the recorder remains full screen

#### Scenario: Back is tapped while idle

- **WHEN** the full-screen recorder is open and no phone video is active
- **THEN** the recorder closes and future Watch video requests are rejected

### Requirement: Watch-controlled video lifecycle

The iPhone SHALL accept and execute video prepare, start, and stop controls
from the Watch only while the full-screen recorder is open and configured. The
prepare control SHALL reserve the matching session, `.start` SHALL start the
movie output, and `.stop` SHALL stop it. The iPhone SHALL not expose a separate
recording start/stop control in the UI.

#### Scenario: Watch starts an open recorder

- **WHEN** the Watch starts a coordinated recording and the full-screen
  recorder is configured
- **THEN** the iPhone starts the matching movie output for the Watch session

#### Scenario: Watch stops an open recorder

- **WHEN** the Watch stops a coordinated recording
- **THEN** the iPhone stops the matching movie output and finalizes the matching
  phone metadata

#### Scenario: Watch starts while recorder is closed

- **WHEN** the Watch starts a recording while the full-screen recorder is not
  open
- **THEN** no phone movie output starts and the Watch motion recording remains
  valid without video

### Requirement: Low-latency manual video start

When the full-screen recorder is open and configured, the iPhone camera capture
stream SHALL already be running before the Watch requests a recording. The
manual recorder mode SHALL not add an artificial multi-second lead before the
Watch start control becomes active, and movie output SHALL not begin before
that control.

#### Scenario: Watch starts with an open camera stream

- **WHEN** the Watch requests a coordinated recording while the full-screen
  recorder is ready
- **THEN** the iPhone uses the already-running camera stream and begins the
  matching movie session after `.start` without an additional multi-second wait

### Requirement: High-speed capture

When the full-screen recorder is opened, the iPhone camera SHALL select the
highest supported frame rate up to 240 fps, configure matching frame duration
limits, and report the selected rate in diagnostics. The implementation SHALL
not fail solely because the device cannot provide 240 fps.

#### Scenario: Camera supports 240 fps

- **WHEN** the selected camera exposes a valid 240 fps format
- **THEN** video recording uses that format at 240 fps

#### Scenario: Camera does not support 240 fps

- **WHEN** no valid format supports 240 fps
- **THEN** the recorder uses the highest valid supported frame rate at or below
  240 fps and remains usable
