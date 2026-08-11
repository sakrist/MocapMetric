## ADDED Requirements

### Requirement: Complete package export

The iPhone SHALL keep the assembled `<uuid>.mmrec` folder synchronized with
all optional assets received for that session before the recording is shared.

#### Scenario: Audio arrives after core assets

- **WHEN** the core motion files and Watch metadata have already been assembled
  into a recording package and the matching `.m4a` arrives later
- **THEN** the iPhone SHALL merge the `.m4a` into the existing package
- **AND** sharing the package SHALL include the audio file
- **AND** the loose late-arriving `.m4a` SHALL no longer remain as a separate
  source beside the package

#### Scenario: Video metadata is still incomplete

- **WHEN** a video file arrives without matching phone metadata
- **THEN** the iPhone SHALL leave the video staged until phone metadata arrives
- **AND** it SHALL NOT replace the package with a video asset that cannot be
  validated

#### Scenario: Package schema remains stable

- **WHEN** optional assets are merged into an existing package
- **THEN** the package SHALL retain its canonical UUID filenames and existing
  core assets
