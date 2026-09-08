# Issues #4, #6, #7, #8 and #9 — device verification

Tested on the vphone running iOS 26.6.1, using SSH through the verified local
2333 → guest 22 route and the native UI socket. Runtime testing began at
19:00:07 JST on September 8, 2026. After a separate session finished using
the device, testing resumed at 19:50 with exclusive access.

The final installed payload was **0.3.8 (67)**. This is a development build;
no release or version tag was created for these changes. Feature flows ran on
builds 65–66; build 67 additionally verified the merged navigation, executable
properties artwork, and cancellation of the remote Close All confirmation.

| Area | Device verification |
| --- | --- |
| Executable artwork (#6) | Mach-O file and symlink show executable artwork in list and grid; ordinary text with execute permissions remains a text document. |
| Properties access (#7) | Folder row has info before its chevron; file row has size before info. Info opens properties; tapping a folder still navigates. Selection mode hides info. |
| Checksums (#8) | MD5, SHA-1 and SHA-256 of `abc` match host references. Full-value alerts and Copy work. MD5 context-menu Copy also works. Each copied value was pasted into a test folder name and independently checked over SSH. |
| Long calculations (#8) | Cancel an 8 GiB sparse-file calculation, retry, and modify the test file during calculation. Cancellation restores the action; mutation produces the explicit changed-file error without displaying a digest. |
| Media properties (#8) | PNG: 360 × 180; WAV: 3 seconds; MP4: 320 × 240, 2 seconds, 24 fps. |
| Navigation (#4) | Applications and Music expose Tabs at the upper left, without a duplicate bottom button. Both open the switcher; switching to a browser works. App and music details retain working Back controls. Search remains available. |
| Save to Fila (#9) | System Files share sheet exposes the localized action and its icon. Text, image and a mixed two-file selection save successfully into Fila's shared Inbox. |
| Duplicate imports (#9) | Repeated saves preserve the original and create numbered copies. Saved text and image bytes match the originals over SSH. |
| Existing Open In (#9) | System Files → Fila opens the destination picker. Cancel leaves the source visible. Confirming the Inbox moves the test file there with unchanged bytes. |

The initial custom accessory implementation triggered a UIKit assertion on
device because the accessory root had Auto Layout's autoresizing mask disabled.
The fix lets UIKit position a container and constrains the 44-point button
inside it. No new Fila crash reports appeared during the exclusive-access run.

## Local validation

- `make harness`: all suites passed (376 tests reported across the runners;
  the cross-volume fixture is skipped when the host lacks that test volume).
- `make check` and unsigned device compilation passed.
- Both Debian flavours, TIPA and IPA packaged and passed payload, signature,
  App Group and entitlement verification.
- The iOS-floor audit passed for the app, embedded frameworks and Save action
  at iOS 15. The File Provider retains its existing separate deployment floor.
- File-layer self-review covered descriptor ownership, cancellation, bounded
  reads, source preservation, exclusive publication, duplicate destinations,
  path/name validation and extension-only OS permissions. No daemon command
  or file-byte operation was added.

The device runs iOS 26; the iOS 15 checks are build/link compatibility checks,
not an iOS 15 runtime test. UI snapshots, command timestamps, exact downloaded
comparison files and build logs are retained locally in
`/tmp/fila-issues-evidence` and `/tmp/fila-issues-*.log`.
