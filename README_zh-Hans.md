<p align="center">
  <a href="README.md">English</a> |
  <a href="README_zh-Hans.md">简体中文</a>
</p>

# Fila

在 iPhone 或 iPad 上浏览、整理和编辑文件。在受支持的系统环境中安装 Fila，即可使用 root 权限访问系统文件。

![预览](./Documentation/screenshots.png)

## 安装

在受支持的设备上，在 Sileo、Zebra 或其他包管理器中添加 OwnGoal Studio 软件源：

**[添加到 Sileo](sileo://source/https://apt.owngoal.dev)** · [apt.owngoal.dev](https://apt.owngoal.dev/)

也可从 [GitHub Releases](https://github.com/owngoal-dev/Fila/releases) 下载。请选择与安装方式匹配的文件。

| 安装方式 | 软件包 | 文件访问 |
| --- | --- | --- |
| [roothide](https://github.com/roothide) 引导环境 | `iphoneos-arm64e` `.deb` | Root 访问 |
| Rootless 引导环境（`/var/jb`） | `iphoneos-arm64` `.deb` | Root 访问 |
| TrollStore | `Fila_<version>.tipa` | `mobile` 用户有权访问的文件 |
| AltStore、SideStore 或 Sideloadly | `Fila_<version>.ipa` | Fila 自己的文件、你导入的文件以及网络共享 |

需要 iOS 15 或更高版本。`.deb` 除应用外还会安装 root 守护进程、归档辅助程序，以及按需启动守护进程的 launchd 任务。Fila 的 root 权限来自该守护进程，因此仅包含应用本体的 `.tipa` 和 `.ipa` 没有 root 权限。`.ipa` 在构建时不包含特权、应用程序和音乐模块，因此不含任何私有 API。

侧载时，请为 Fila、其「文件」扩展以及「存储到 Fila」扩展配置同一 App Group。

## 功能

- **整理**：拷贝、移动、重命名和删除文件。删除的项目默认移到废纸篓，可从中恢复。使用标签页同时打开多个文件夹，在标签页之间以及与其他应用之间拖放项目，通过收藏和最近使用返回已保存或近期访问的位置。
- **搜索**：按名称查找文件和文件夹。搜索不会查看文件内容。
- **网络共享**：在设置 → 服务器中添加 SMB 服务器。已保存的共享会出现在边栏中，浏览方式与普通文件夹相同。所有软件包均包含此功能，`.ipa` 也不例外。
- **应用**：浏览已安装的应用，并在安装方式允许时打开其程序包或数据文件夹。可直接在文件列表中安装 `.deb`、`.tipa` 和 `.ipa` 软件包。
- **查看与编辑**：编辑文本时显示语法高亮，并可查找和自动换行，还可编辑属性列表。预览图片和 PDF，播放音频和视频，以十六进制查看二进制文件，查看 Mach-O 详情，浏览音乐资料库，向其中导入音频，以及删除曲目。
- **归档**：浏览并解压 ZIP、TAR、7z、RAR、xar、cpio、ISO、CAB、LHA 和 ar，其中 7z 和 RAR 为只读。创建 ZIP 和 TAR 归档，可使用 gzip、bzip2、xz、LZMA、lzip、Zstandard 或 LZ4 压缩，并可选择三种压缩级别。ZIP 归档可使用 AES-256 或 ZipCrypto 加密。
- **分享**：导入文件和照片，从 URL 下载，与其他应用共享，或通过浏览器、WebDAV 客户端在网络上发布文件夹。在其他应用的共享表单中选择「存储到 Fila」，即可将文件送入 Fila 的收件箱。
- **「文件」**：在 iOS 16 或更高版本上，可从「文件」打开 Fila 中的文稿。「文件」无法使用 Fila 的 Root 访问。
- **终端**：使用 `.deb` 时，可运行可执行文件，或在当前文件夹打开 shell。以 root 身份开启会话需要 Face ID、Touch ID 或密码验证。`.tipa` 和 `.ipa` 不提供终端。
- **查看详情**：在属性中读取和修改权限、所有者、标志与扩展属性，并可计算校验和。在任务中查看拷贝和下载进度，在设置中查阅 Fila 自身的日志。
- **删除保护**：Fila 拒绝删除、移动或替换关键系统文件夹，但其中的内容仍可编辑；该规则由守护进程强制执行，不受设置影响。

可用的文件夹和操作取决于 Fila 的安装方式。界面提供 13 种语言：简体中文、繁体中文、英语、日语、韩语、法语、德语、西班牙语、意大利语、葡萄牙语（巴西）、俄语、阿拉伯语和越南语。

## 使用 Fila

轻点文件夹以浏览内容，或轻点文件以打开。按住项目可使用“拷贝”“移动”“重命名”和“属性”。点按“选择”可同时处理多个项目。

删除的项目默认移到废纸篓。打开废纸篓并选择“放回原处”即可恢复。若要删除时不经过废纸篓，请关闭设置 → 行为 → 文件操作 → 使用废纸篓。“永久删除”和“清空废纸篓”无法撤销。

要与另一台设备共享文件夹，请打开设置 → 文件共享。选择文件夹，设置用户名、密码和端口，然后开启共享。未作修改时，用户名为 `fila`，端口为 8080。Fila 会显示相应地址和可供扫描的二维码。在连接同一网络的另一台设备上，使用浏览器或 WebDAV 客户端打开该地址并登录。开启“后台保持共享”后，Fila 不在前台时仍可继续提供服务。该连接未加密，请仅在可信任的网络中共享。

要访问网络共享，请打开设置 → 服务器，添加 SMB 服务器的地址和凭据，它便会出现在边栏中。同一页面也可编辑和移除已保存的服务器。

在 iOS 16 或更高版本上，设置 → 「文件」App 文件夹可管理「文件」中显示的文件夹。

## 链接与快捷指令

在“快捷指令”或其他应用中使用 `fila://` 链接打开文件夹、文件或界面。当前安装方式下，Fila 必须有权访问目标位置。`fila://` 链接仅用于导航或查看，任何链接都不会修改或删除文件。

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

Fila 还为“快捷指令”提供十二项操作。其中七项用于读取：在 Fila 中打开、在 Fila 中显示、打开 App 容器、获取文件信息、列出文件夹、查找文件和获取文件文本。另外五项用于写入：新建文件夹、拷贝项目、移动项目、删除项目和向文件写入文本。

## 从源码构建

```sh
make check            # 项目与打包校验
make harness          # 在 Mac 上运行测试套件
make packages         # roothide 与 rootless 的 .deb、TrollStore 的 .tipa，以及侧载用 .ipa
make deb              # roothide .deb
make deb-rootless     # rootless .deb
make tipa
make ipa
make sim              # 构建 Debug 版本并安装到已启动的模拟器
make install          # 为已连接的设备构建并更新安装
```

`make check` 需要 xcodebuild、ldid、dpkg-deb 和 zip；构建 Web 界面还需要 npm。

贡献说明见 [AGENTS.md](AGENTS.md)。

## 许可证

Fila 使用 [MIT 许可证](LICENSE)。

`.deb` 软件包不适用于 App Store。

欢迎加入 [Discord](https://discord.gg/vqhDEep2mN) 社区。
