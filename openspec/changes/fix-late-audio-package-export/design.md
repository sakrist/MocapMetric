## Approach

`RecordingInboxStore.assembleRecordingPackages` will treat a valid existing
package as the source of already-assembled core assets. A later loose audio,
video, or phone-metadata file will be copied into a temporary replacement of
that package, validated, and then atomically swapped into place.

The existing rule that video requires phone metadata remains unchanged. A
loose video is left staged until its matching phone metadata is available.

## Verification

The iPhone test target will assemble a core package, add a loose `.m4a`, run
assembly again, and verify that the validated package contains the audio and
the loose source file has been consumed.
