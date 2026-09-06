# Fila

Browse, organize, and edit files on your iPhone or iPad. Fila supports iOS 15 or
later, with root access on [roothide](https://github.com/roothide) and rootless
jailbreaks. You can also install it through TrollStore or sideloading with more
limited file access.

## Features

- Copy, move, rename, and delete files and folders. Restore deleted items from Trash.
- Keep folders open in tabs and return to them through Favorites and Recents.
- Search for files and folders by name.
- Browse installed apps and open their app and data folders where access is available.
- Run executable files in a terminal on supported jailbreak installations.
- Edit text files and property lists. View images and PDFs, play audio and video,
  and inspect binary files in hex or view Mach-O details.
- Browse and extract archives, including ZIP, TAR, 7z, and RAR. Create ZIP and TAR
  archives, with password protection available for ZIP.
- Import files and photos, download files from a URL, and share files with other apps.
- Share a folder over your network through a web browser or WebDAV client.
- Access Fila documents in the Files app on iOS 16 or later.

Available folders and actions depend on how you install Fila.

## Install

Choose the package that matches your device and installation method.

| Installation | Package | File Access |
| --- | --- | --- |
| roothide jailbreak | `wiki.qaq.fila_<v>_iphoneos-arm64e.deb` | Root access |
| Rootless jailbreak | `wiki.qaq.fila_<v>_iphoneos-arm64.deb` | Root access |
| TrollStore | `Fila_<v>.tipa` | Files accessible to the `mobile` user; no root access |
| AltStore, SideStore, or Sideloadly | `Fila_<v>.ipa` | Fila's own files and files you import; no root access |

`<v>` is the version number in the package name.

- **Jailbroken device:** Open the matching `.deb` with your package manager and install it.
- **TrollStore:** Open the `.tipa` in TrollStore and install it.
- **Sideloading:** Open the `.ipa` with your signing tool and install it. The tool
  must provision the same App Group for Fila and its Files extension.

Root access requires the `.deb` installation on a supported jailbreak. Installing
the `.tipa` or `.ipa` alone does not provide it.

## Using Fila

Tap a folder to browse it or a file to open it. Touch and hold an item for actions
such as Copy, Move, Rename, and Properties. Use Select to work with several items.

Deleted items go to Trash by default. Open Trash and choose Put Back to restore an
item to its original location. Delete Permanently and Empty Trash cannot be undone.
You can change the default deletion behavior in Settings → Move to Trash.

To share a folder with another device, open Settings → File Sharing. Choose the
shared folder and credentials, turn sharing on, then open the displayed address in
a browser or WebDAV client on your network.

On iOS 16 or later, Settings → Files App Folder lets you manage the folder shown
in the Files app. Files cannot use Fila's root access.

Search matches file and folder names; it does not search file contents.

## Links and Shortcuts

Use `fila://` links in Shortcuts or other apps to open a folder, file, or screen.
The destination must be accessible to your Fila installation.

| Link | Opens |
| --- | --- |
| `fila:///var/mobile/Documents` | The Documents folder |
| `fila://open?path=/var/mobile` | The specified folder |
| `fila://open?path=/var/mobile&tab=new` | The folder in a new tab |
| `fila://reveal?path=/etc/hosts` | The folder containing the file |
| `fila://view?path=/etc/hosts` | The file in its viewer |
| `fila://info?path=/etc/hosts` | The file's properties |
| `fila://search?query=hosts` | A name search starting at `/` |
| `fila://search?query=hosts&path=/etc` | A name search within `/etc` |
| `fila://app?bundle=com.example.thing` | The app's bundle folder |
| `fila://app?bundle=com.example.thing&container=data` | The app's data folder |
| `fila://apps` | Applications |
| `fila://settings` | Settings |

These links navigate or inspect files; they do not modify or delete them.

## License

Fila is available under the [MIT license](LICENSE).

Build instructions and contributor guidance are in [AGENTS.md](AGENTS.md).
