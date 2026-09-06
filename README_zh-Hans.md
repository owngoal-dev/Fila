<p align="center">
  <a href="README.md">English</a> |
  <a href="README_zh-Hans.md">简体中文</a>
</p>

# Fila

在 iPhone 或 iPad 上浏览、整理和编辑文件。在受支持的越狱设备上安装 Fila，即可使用 root 权限访问系统文件。

![预览](./Documents/screenshots.png)

## 安装

越狱设备上，在 Sileo、Zebra 或其他包管理器中添加 OwnGoal Studio 软件源：

**[添加到 Sileo](sileo://source/https://apt.owngoal.dev)** · [apt.owngoal.dev](https://apt.owngoal.dev/)

也可从 [GitHub Releases](https://github.com/owngoal-dev/Fila/releases) 下载。请选择与安装方式匹配的文件。

| 安装方式 | 软件包 | 文件访问 |
| --- | --- | --- |
| [roothide](https://github.com/roothide) 越狱 | `iphoneos-arm64e` `.deb` | Root 访问 |
| Rootless 越狱（`/var/jb`） | `iphoneos-arm64` `.deb` | Root 访问 |
| TrollStore | `Fila_<version>.tipa` | `mobile` 用户有权访问的文件 |
| AltStore、SideStore 或 Sideloadly | `Fila_<version>.ipa` | Fila 自己的文件以及你导入的文件 |

需要 iOS 15 或更高版本。要使用 root 权限，请在受支持的越狱设备上安装 `.deb` 软件包。`.tipa` 和 `.ipa` 不提供 root 权限。

侧载时，请为 Fila 及其「文件」扩展配置同一 App Group。

## 功能

- **整理**：拷贝、移动、重命名和删除文件。删除的项目默认移到废纸篓，可从中恢复。使用标签页同时打开多个文件夹，通过收藏和最近使用返回已保存或近期访问的位置。
- **搜索**：按名称查找文件和文件夹。搜索不会查看文件内容。
- **应用**：浏览已安装的应用，并在安装方式允许时打开其程序包或数据文件夹。
- **查看与编辑**：编辑文本时显示语法高亮，并可编辑属性列表。预览图片和 PDF，播放音频和视频，以十六进制查看二进制文件，查看 Mach-O 详情，以及浏览音乐资料库。
- **归档**：浏览并解压 ZIP、TAR、7z 和 RAR。创建 ZIP 和 TAR 归档；ZIP 可设置密码。
- **分享**：导入文件和照片，从 URL 下载，与其他应用共享，或通过浏览器、WebDAV 客户端在网络上发布文件夹。
- **「文件」**：在 iOS 16 或更高版本上，可从「文件」打开 Fila 中的文稿。「文件」无法使用 Fila 的 Root 访问。
- **终端**：在越狱设备上，运行可执行文件，或在当前文件夹打开 shell。
- **删除保护**：Fila 默认阻止删除关键系统文件夹。

可用的文件夹和操作取决于 Fila 的安装方式。

## 使用 Fila

轻点文件夹以浏览内容，或轻点文件以打开。按住项目可使用“拷贝”“移动”“重命名”和“属性”。点按“选择”可同时处理多个项目。

删除的项目默认移到废纸篓。打开废纸篓并选择“放回原处”即可恢复。要更改默认删除方式，请打开设置 → 移到废纸篓。“永久删除”和“清空废纸篓”无法撤销。

要与另一台设备共享文件夹，请打开设置 → 文件共享。选择文件夹，设置用户名和密码，然后开启共享。在连接同一网络的另一台设备上，使用浏览器或 WebDAV 客户端打开显示的地址并登录。

在 iOS 16 或更高版本上，设置 → 「文件」App 文件夹可管理「文件」中显示的文件夹。

## 链接

在“快捷指令”或其他应用中使用 `fila://` 链接打开文件夹、文件或界面。当前安装方式下，Fila 必须有权访问目标位置。这些链接仅用于导航或查看，不会修改或删除文件。

| 链接 | 打开 |
| --- | --- |
| `fila:///var/mobile/Documents` | 文稿文件夹 |
| `fila://open?path=/var/mobile` | 指定文件夹 |
| `fila://open?path=/var/mobile&tab=new` | 在新标签页中打开该文件夹 |
| `fila://reveal?path=/etc/hosts` | 包含该文件的文件夹 |
| `fila://view?path=/etc/hosts` | 在查看器中打开该文件 |
| `fila://info?path=/etc/hosts` | 该文件的属性 |
| `fila://search?query=hosts` | 从 `/` 开始按名称搜索 |
| `fila://search?query=hosts&path=/etc` | 在 `/etc` 内按名称搜索 |
| `fila://app?bundle=com.example.thing` | 该应用的程序包文件夹 |
| `fila://app?bundle=com.example.thing&container=data` | 该应用的数据文件夹 |
| `fila://apps` | 应用程序 |
| `fila://settings` | 设置 |

## 从源码构建

```sh
make packages         # roothide 与 rootless 的 .deb、TrollStore 的 .tipa，以及侧载用 .ipa
make deb              # roothide .deb
make deb-rootless     # rootless .deb
make tipa
make ipa
```

贡献说明见 [AGENTS.md](AGENTS.md)。

## 许可证

Fila 使用 [MIT 许可证](LICENSE)。

越狱软件包不适用于 App Store。

欢迎加入 [Discord](https://discord.gg/vqhDEep2mN) 社区。
