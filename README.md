<p align="center">
  <a href="README.md">English</a> |
  <a href="README_zh-Hans.md">简体中文</a>
</p>

# Fila

Browse, organize, and edit files on your iPhone or iPad. Install Fila on a supported system environment to access system files with root privileges.

![Preview](./Documentation/screenshots.png)

## Install

On a supported device, add the OwnGoal Studio repository in Sileo, Zebra, or another package manager:

**[Add to Sileo](sileo://source/https://apt.owngoal.dev)** · [apt.owngoal.dev](https://apt.owngoal.dev/)

Packages are also on [GitHub Releases](https://github.com/owngoal-dev/Fila/releases). Choose the file that matches how you install apps.

| Installation | Package | File access |
| --- | --- | --- |
| [roothide](https://github.com/roothide) bootstrap | `iphoneos-arm64e` `.deb` | Root access |
| Rootless bootstrap (`/var/jb`) | `iphoneos-arm64` `.deb` | Root access |
| TrollStore | `Fila_<version>.tipa` | Files the `mobile` user can reach |
| AltStore, SideStore, or Sideloadly | `Fila_<version>.ipa` | Fila’s own files, files you import, and network shares |

Requires iOS 15 or later. The `.deb` installs the app together with a root daemon, an archive helper, and a launchd job that starts the daemon on demand. That daemon is what gives Fila root access, so the `.tipa` and `.ipa`, which carry the app alone, do not have it. The `.ipa` is built without the privileged, Applications and Music modules, so it contains no private API.

When sideloading, provision the same App Group for Fila, its Files extension, and its Save to Fila extension.

## Features

- **Organize**: Copy, move, rename, and delete files. Deleted items go to Trash by default, where you can restore them. Keep folders open in tabs, drag items between tabs and into other apps, and return to saved or recently visited locations through Favorites and Recents.
- **Search**: Find files and folders by name. Search does not look inside file contents.
- **Network shares**: Add SMB servers in Settings → Servers. Saved shares appear in the sidebar and browse like any other folder. Included in every package, the `.ipa` as well.
- **Apps**: Browse installed apps and open their bundle or data folder when your installation allows it. Install `.deb`, `.tipa`, and `.ipa` packages straight from the file list.
- **View and edit**: Edit text with syntax highlighting, find and soft wrap, and edit property lists. Preview images and PDFs, play audio and video, inspect binaries in hex, and read Mach-O details. Browse the Music library, import audio into it, and delete tracks.
- **Archives**: Browse and extract ZIP, TAR, 7z, RAR, xar, cpio, ISO, CAB, LHA, and ar; 7z and RAR are read-only. Create ZIP and TAR archives, with gzip, bzip2, xz, LZMA, lzip, Zstandard, or LZ4 compression and a choice of three compression levels. A ZIP archive can be encrypted with AES-256 or ZipCrypto.
- **Share**: Import files and photos, download from a URL, share with other apps, or publish a folder over the network through a browser or WebDAV client. Save to Fila in another app’s share sheet sends files to Fila’s Inbox.
- **Files app**: On iOS 16 or later, open Fila documents from the Files app. Files cannot use Fila’s root access.
- **Terminal**: With the `.deb`, run an executable or open a shell in the current folder. A session as root asks for Face ID, Touch ID, or your passcode. The `.tipa` and `.ipa` have no terminal.
- **Inspect**: Read and change permissions, owner, flags, and extended attributes in Properties, and calculate checksums. Watch copies and downloads in Tasks, and read Fila’s own log in Settings.
- **Deletion protection**: Fila refuses to delete, move, or replace key system folders. Everything inside them stays editable, and the daemon enforces the rule regardless of settings.

Available folders and actions depend on how you install Fila. The interface is available in 13 languages: Arabic, English, French, German, Italian, Japanese, Korean, Portuguese (Brazil), Russian, Simplified Chinese, Spanish, Traditional Chinese, and Vietnamese.

## Using Fila

Tap a folder to browse it or a file to open it. Touch and hold an item for Copy, Move, Rename, and Properties. Use Select to work with several items at once.

Deleted items go to Trash by default. Open Trash and choose Put Back to restore an item. To delete without the Trash, turn off Settings → General → File Operations → Use Trash. Delete Permanently and Empty Trash cannot be undone.

To share a folder with another device, open Settings → File Sharing. Choose a folder, set a user name, password, and port, and turn on sharing. The user name is `fila` and the port is 8080 unless you change them. Fila shows the resulting address and a QR code to scan. On the other device connected to the same network, open that address in a browser or WebDAV client and sign in. Turn on Keep Sharing in Background to keep serving while Fila is not on screen. The connection is not encrypted, so share only on a network you trust.

To reach a network share, open Settings → Servers, add an SMB server with its address and credentials, and it appears in the sidebar. The same page edits and removes saved servers.

## Links and Shortcuts

Use `fila://` links in Shortcuts or other apps to open a folder, file, or screen. The destination must be reachable in your Fila installation. A `fila://` link only navigates or inspects; no link modifies or deletes files.

| Link | Opens |
| --- | --- |
| `fila:///var/mobile/Documents` | The Documents folder |
| `fila://open?path=/var/mobile` | The specified folder |
| `fila://open?path=/var/mobile&tab=new` | The folder in a new tab |
| `fila://reveal?path=/etc/hosts` | The folder that contains the file |
| `fila://view?path=/etc/hosts` | The file in its viewer |
| `fila://info?path=/etc/hosts` | The file’s properties |
| `fila://search?query=hosts` | A name search starting at `/` |
| `fila://search?query=hosts&path=/etc` | A name search within `/etc` |
| `fila://app?bundle=com.example.thing` | The app’s bundle folder |
| `fila://app?bundle=com.example.thing&container=data` | The app’s data folder |
| `fila://apps` | Applications |
| `fila://settings` | Settings |

Fila also adds twelve actions to Shortcuts. Seven of them read: Open in Fila, Reveal in Fila, Open App Container, Get File Info, List Folder, Find Files, and Get Text from File. Five of them write: Create Folder, Copy Item, Move Item, Delete Item, and Write Text to File.

## Build from Source

```sh
make check            # project and packaging validation
make harness          # the test suite, on the Mac
make packages         # roothide and rootless .deb, TrollStore .tipa, and sideload .ipa
make deb              # roothide .deb
make deb-rootless     # rootless .deb
make tipa
make ipa
make sim              # Debug build onto the booted simulator
make install          # build for a connected device and update it
```

`make check` needs xcodebuild, ldid, dpkg-deb, and zip; building the web UI also needs npm.

Contributor notes are in [AGENTS.md](AGENTS.md).

## License

Fila is available under the [MIT License](LICENSE).

The `.deb` packages are not for the App Store.

Join the community on [Discord](https://discord.gg/vqhDEep2mN).
