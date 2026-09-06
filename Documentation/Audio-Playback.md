# Music playback and system controls

Music uses AVPlayer over the existing DescriptorAsset. AVFoundation loads the
common and format-specific tags from that same asset; no filename is reopened
and no media file is copied to a temporary URL. Supported Now Playing fields
include title, artist, album, album artist, composer, genre, artwork, track/disc
numbers and totals, plus playback duration, elapsed time and current rate.
The system chooses which supplied fields appear on each surface. Unknown tags
are not converted into invented Now Playing keys. Missing titles use the file
name; missing artwork stays absent. Artwork is capped at 16 MB encoded and
rendered at at most 1024 pixels on its longest edge.

The active music session installs play, pause, toggle, stop, position seeking
and 15-second skip commands. Position/rate updates follow playback changes and
seek notifications; the system extrapolates elapsed time between updates.
Background audio keeps playback available while the screen is locked.
Interruptions and removed audio devices pause playback; restarting remains an
explicit user action.

Only the most recently started player owns playback. Switching documents pauses
the previous player without discarding its position. Hidden tab metadata loads
cannot publish over the current owner, and closing an old document cannot clear
newer controls. Music starts on its first actual appearance, so constructing a
hidden restored page does not start it. Closing/stopping the owning music
document removes only its registered command targets, clears its metadata and
deactivates the audio session. A video retains AVKit's native player and Now
Playing behavior; ownership handoff disables a paused retained video's publisher
until that video actually resumes.

## AudioEditorKit evaluation

[AudioEditorKit](https://github.com/Lakr233/AudioEditorKit) provides waveform
visualization, trimming, segment deletion and URL-based export. Its
[package manifest](https://github.com/Lakr233/AudioEditorKit/blob/main/Package.swift)
requires iOS 16 and depends on Swift Atomics and ProgressHUD. Those editing
features do not replace AVFoundation metadata loading or MediaPlayer system
controls, and the URL entry point would need descriptor-aware adaptation or a
materialized copy. It is therefore not linked for this playback request; the
app retains iOS 15 support and its existing descriptor stream.

Validation: host tests cover ID3 text fields, empty-tag fallbacks, track/disc
counts, iTunes binary number pairs and truncated atoms. A successful iOS build
checks API availability. Lock-screen commands, AirPlay, audio interruptions and
multi-tab playback still require real-device interaction; compilation alone is
not a playback test.
