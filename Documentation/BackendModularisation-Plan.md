# Backend 模块化实施计划

状态：设计已对齐，待实施。2026-09-09。

本文件是执行顺序与验收清单；[RemoteClients.md](RemoteClients.md) 是接口与行为设计，[Architecture.md](Architecture.md) 记录架构边界。此轮不实现运行时代码，也不创建 target、添加依赖或发布构建。

## 已确认范围

- backend 全部随 app 打包，不安装第三方模块。
- 自有模块编译为动态 framework，通过 Mach-O 非弱依赖在 main 前加载。main 扫描已加载的随包 framework，读取静态 manifest，按名称发现入口类并注册能力。
- 所有自有 framework 与 app 使用同一个版本号、build 号和构建工具链，不独立升级。
- 所有随包模块默认启用，无模块开关，不运行时卸载 backend。页面、订阅和网络连接可以释放自己的资源。
- bootstrap 失败记录 `backend failed to bootstrap`，禁用本次启动的注册，app 内不显示入口、错误行或弹窗。正常操作错误仍正常反馈。
- Local、Privileged、SMB、FTP、Applications、Music 独立拆包；共享契约与 UI 分别为 BackendKit、BackendUI。
- backend 拥有 root、独立偏好和 sidebar 数据；通过 `DefaultStorage` 注入 UserDefaults 读写。不同进程分别保存，不同步 defaults。
- 全局外观和历史记录开关共享；其他偏好归各 backend。
- 一个 SMB share 或一个 FTP 起始目录就是一个 backend。沙盒本地根固定 Documents；完整本地 backend 保留合适的默认位置，不做额外本地根创建功能。
- Applications、Music 没有收藏。Sidebar 按 section 汇总各 backend 的贡献，不支持跨 section 排序。
- 使用 MIT 的 kishikawakatsumi/SMBClient 和 libcurl。SFTP 后置。
- 支持基本的跨 backend 文件/文件夹复制、移动。必要的上传下载由内部传输完成，不要求用户手工接力。
- 沙盒 IPA 不编译、链接或嵌入 Privileged、Applications、Music 模块及其私有依赖。

## 最终模块与类型

| Framework / owner | 主要类型 | 沙盒 IPA |
| --- | --- | --- |
| `FilaBackendKit` | `Backend`、`FileBackend`、`FileService`、`WritableFileService`、`BackendRoot`、`BackendLocation`、`FileLocation`、`DefaultStorage<Value>`、`BackendModule`、`BackendHost` | 包含 |
| `FilaBackendUI` | `BackendListViewController<Item>`、共享列表组件和 UI 接口 | 包含 |
| `FilaLocal` | `LocalFileBackend`、`SandboxedLocalFileBackend`、中立本地访问契约及进程内实现 | 包含 |
| `FilaPrivileged` | `DaemonLink`、daemon/XPC 访问实现，提取自现有 FilaClient | 不包含 |
| `FilaSMB` | `SMBBackend`、SMB 文件服务、连接配置 UI | 包含 |
| `FilaFTP` | `FTPBackend`、libcurl 文件服务、连接配置 UI | 包含 |
| `FilaApplications` | `ApplicationBackend`、应用发现/安装集成、`ApplicationListViewController`、`ApplicationDetailViewController` | 不包含 |
| `FilaMusicLibrary` | `MusicLibraryBackend`、现有音乐编辑/native 集成、`MusicLibraryViewController`、`MusicTrackViewController` | 不包含 |
| App shell | `BackendModuleDiscovery`、`BackendRegistry`、`SidebarModel`、`UserDefaultsStorage<Value>`、`OperationCenter`、`FileTransfer` | 包含 |

`Backend` 是协议，Application/Music 不实现文件访问接口。`FileBackend` 增加文件能力。只有 `SandboxedLocalFileBackend` 继承 `LocalFileBackend`；SMB、FTP 不继承本地实现。

现有内部 `FilaClient.FileService` 重命名并解耦为 `LocalFileAccess`，与新的公共 FileService 区分。其接口不能继续通过 DaemonLink 嵌套类型把公共 FilaLocal 拉回 XPC 依赖。保留有实际调用方的迁移兼容声明，迁移完成后删除空转发层。

UI 共用 BackendListViewController；文件、应用、音乐分别为 FileBrowserViewController、ApplicationListViewController、MusicLibraryViewController。Local/SMB/FTP 共用同一个文件 controller，不按协议派生 UI。

## 依赖规则

```text
App shell ----------------------> FilaBackendKit
       |                                  ^
       +--> FilaBackendUI ----------------+
                     ^                    |
                     |                    |
       +-------------+--------------------+-------------+
       |             |                    |             |
    FilaLocal     FilaSMB              FilaFTP      Catalog modules
       ^                                          Applications / Music
       |
 FilaPrivileged

filad: existing FilaProtocol + FilaFileOps + FilaLog only
```

动态模块按名称注册，shell 不 import 具体模块入口。FilaBackendUI 不反向依赖 feature 模块。FilaLocal 不直接或间接依赖 FilaPrivileged。实际依赖图包括内部 C/Objective-C target 和第三方库，不能只检查顶层产品名称。

## 阶段 0：基线与迁移清单

- [ ] 保存当前工作区变更清单，保持已有名称排序修改独立，不覆盖或混入不相关迁移。
- [ ] 先执行 `make harness`，再执行 `make check`，记录构建与测试基线。
- [ ] 列出 AppPreferences、BrowserTabStore、FileClipboard、Sidebar、应用目录 hooks、安装流程、音乐 bridge、扩展与 packager 的实际调用关系。
- [ ] 明确私有 API/entitlement/符号所在模块；检查现有 FilaProtocol/FilaFileOps 的 XPC 耦合。
- [ ] 确定现有文件操作审查门的执行方式；实现触及文件层时完成 code-clarity 和 code-review，不能以构建通过代替。

验收：形成可迁移的 owner 清单及可重复基线；没有运行时行为变更。

## 阶段 1：动态模块骨架和启动注册

- [ ] 创建 FilaBackendKit 与模块入口契约。每个模块入口名固定为 `<framework basename>Module`，显式 Objective-C runtime 名称。
- [ ] 添加 `FilaBackendModule.plist`，包含 schema/契约版本和显示名称资源键。模块身份来自 bundle ID，发布版本来自 Version.xcconfig。
- [ ] 实现 main 中的 BackendModuleDiscovery：限定随包已加载 framework，检查 manifest/版本/入口归属与协议，确定性排序，实例化并注册。
- [ ] 先收集 provider/factory，再解析 backend 需求；单模块注册原子提交，失败不留下部分能力。
- [ ] 编译配置保留无静态符号引用的 framework load command；检查 `-needed_framework` 等设置的实际产物。
- [ ] bootstrap 失败只记录日志并隐藏贡献；不调用网络、不创建页面、不弹授权、不做 +load 自动注册。

验收：Release 优化构建也能自动发现入口；新增模块不改 main 的具体类分支。验证同版本、重复注册、错误 manifest、入口缺失和无 UI 失败反馈。缺失强链接 dylib 的 pre-main 失败由打包检查拦住。

## 阶段 2：Local / Privileged 拆分与 root

- [ ] 提取 FilaLocal 的中立访问接口、进程内访问和 LocalFileBackend；特权选择/XPC 放入 FilaPrivileged。
- [ ] FilaPrivilegedModule 注册特权访问 provider，FilaLocalModule 创建逻辑本地 backend；不产生两个相同的本地 sidebar root。
- [ ] 实现 BackendRoot 和稳定位置身份。SandboxedLocalFileBackend 固定进程内访问与 Documents 根，不能注入 daemon provider。
- [ ] 保留完整版本的 daemon grace 规则、真实 hello 权限判断与 InstallRoot 行为；daemon 尚未启动不算 bootstrap 失败。
- [ ] 偏好与导航在 root 下使用正确的相对/绝对表示；保留旧本地持久化键和值的含义。
- [ ] 公共文件枚举以拉取式分页为最终契约，保留本地首屏增量展示和刷新完整替换，取消时关闭 cursor/句柄。
- [ ] 复用原 FilaFileOps 的文件行为，不复制 syscall/guard/job 实现，不改变普通 daemon 的 writableRoot。

验收：full local 与 sandbox local 跑相同公共契约测试；sandbox 无 daemon 查找；root/路径/句柄生命周期检查通过；完整本地功能和大目录分页无退化。

## 阶段 3：DefaultStorage、sidebar 和订阅

- [ ] 实现按进程和 backend scope 注入的 DefaultStorage 与 UserDefaultsStorage。保留缺失与显式空值区别。
- [ ] 迁移收藏、历史、最后位置、排序、隐藏文件、默认布局与目录布局；appSort/appScope 留给 ApplicationBackend。
- [ ] 保留 favorites/recents/recentFiles/preset 等旧键、历史过滤与顺序。旧历史不伪造访问时间。
- [ ] 实现 backend 独立 sidebar 完整快照流，缓冲最新一份；SidebarModel 合并已到达贡献，不等所有连接成功。
- [ ] 全局历史关闭清理本进程所有 backend 历史，包括离线 backend；不添加跨进程同步。
- [ ] 实现独立目录失效订阅：先订阅再发初始事件，刷新期间保留一次后续事件，取消后拒绝旧结果。
- [ ] 迁移后删除旧全局偏好读取和重复 NotificationCenter 刷新路径，OperationCenter 保留唯一作业事件消费者。

验收：多 subscriber 不抢事件；离线收藏可见；模块失败不留占位；偏好 scope 互不污染；跨 section 拖动被拒绝；后台无多余轮询。

## 阶段 4：Application / Music 与共享 UI

- [ ] 创建 FilaBackendUI，将真实重复的订阅、刷新状态和列表基础行为收敛到 BackendListViewController。
- [ ] BrowserViewController 迁移为 FileBrowserViewController，保持文件列表为 collection view、分页、选择和标签页状态。
- [ ] ApplicationBackend 接管 catalog、偏好、应用操作；迁移两个应用 controller 和专属 UI/资源至 FilaApplications。
- [ ] MusicLibraryBackend 接管曲库查询、变更与操作；保留 MusicLibraryEditor/native bridge 单一低层 owner，迁移列表与详情 UI/资源至 FilaMusicLibrary。
- [ ] Application/Music 不增加收藏接口，不把应用和歌曲包装为文件。
- [ ] 模块注册 screen factory，shell 按 BackendLocation 路由；应用图标/目录装饰通过注入能力接入。
- [ ] 迁移 feature 资源目录、模块 bundle 本地化与编译器提取校验。

验收：原应用和音乐功能保持；音乐导出限制保留；列表共享生命周期但专属行为不塞进公共基类；不存在动态库循环依赖。

## 阶段 5：沙盒 IPA composition

- [ ] 在手写 Xcode project 中新增 FilaSandboxed target/scheme，复用公共实现；完整 Fila 用于 deb/tipa。
- [ ] `make ipa` 使用 sandbox composition；`make packages` 正确构建两套产物，不交叉污染 DerivedData/缓存。
- [ ] sandbox 仅链接/嵌入公共契约、UI、Local、SMB、FTP 与允许的依赖，排除 Privileged/Applications/Music。
- [ ] 检查文件系统同步组、Objective-C bridges、selector 字符串、私有框架、图标 hooks、入口路由和 transitive dependencies 的残留。
- [ ] 保持 App Group、File Provider、Save Action 及普通文件预览/媒体播放；不因隔离音乐库而删除普通音频播放。
- [ ] 所有 app/自有 framework 版本只来自 Version.xcconfig，全部适用签名、entitlement 和 iOS-floor 检查。

验收：普通 IPA 的实际 binary、load commands 和资源中没有被排除功能；完整版本保有这些模块。上架审核另行评估，不把成功打包称作 App Store 批准。

## 阶段 6：SMB / FTP 连接与文件访问

- [ ] 锁定 SMBClient 和 libcurl 版本，记录许可证、可重复构建及传递依赖。确定并验证 FTPS 的 TLS/trust 构建。
- [ ] 创建 FilaSMB/FilaFTP 动态模块、入口类、manifest、连接配置 UI 和每配置 backend 实例。
- [ ] 凭据通过宿主 Keychain 能力获取，普通配置经各自 DefaultStorage 保存。
- [ ] 实现 metadata、拉取分页/接收预算、有界流式传输、超时和取消。必要时使用库的低层 API，不能给完整大数组套一层“分页”。
- [ ] SMB 默认按选定库已验证的 SMB2 能力交付，不宣称 SMB3 encryption/CHANGE_NOTIFY；FTP/SMB 目录更新使用受控观察轮询。
- [ ] 实现 snapshot 预览与远程 root 配置；连接/认证错误正常反馈，不当成模块 bootstrap 故障。

验收：host/iOS 构建通过；真实 Samba、Windows signing-required、NAS、FTP/FTPS 场景有结果记录；超大目录、多 GB 文件、Unicode、空文件、证书错误与取消均不造成无界内存或挂起。

## 阶段 7：跨 backend 复制与移动

- [ ] 在现有 OperationCenter 下实现单一 FileTransfer executor 和必要的 WritableFileService，不引入第二个 job center。
- [ ] FileClipboard 改为 backend-aware locations，保留 paste snapshot/revision 和“仅完整成功才消费 cut”的规则。
- [ ] 本地间使用原生 jobs；远程路线按需下载/上传并逐文件中转，统一为一个用户操作和诚实进度。
- [ ] 先完成并发布目标，再验证并清理源。支持目录/空目录，清理只针对已复制且验证的条目，不盲删重新枚举出的新内容。
- [ ] 明确冲突、可支持的覆盖策略、源变化、空间不足、链接/元数据差异、取消和未知发布结果。
- [ ] 删除源失败保留副本并报告部分移动；不做破坏性回滚，不自动重试不确定写入。
- [ ] Application/Music 继续用专属安装/导入/导出操作，仅实际文件部分复用传输，不把剪切解释为卸载或删曲。

验收：Local↔SMB、Local↔FTP、SMB↔FTP 的复制/移动测试检查两端最终内容；失败/取消/部分成功保留可恢复数据；切换 clipboard 不受旧 completion 影响。

## 阶段 8：整体清理与交付验收

- [ ] 按 code-clarity 删除兼容空壳、重复状态、重复通知、通用命令袋和实际没有消费者的能力接口。
- [ ] 每阶段单独 review，保持可构建；文件操作相关变更完成规定的两道审查。
- [ ] 运行 harness/check、两套 app build、所有 wrappers 验证、动态依赖/签名/版本/iOS-floor 审计。
- [ ] simulator 验证通用 UI；vphone 验证特权 XPC；真实远程服务验证协议行为。没有实测的项目明确标记，不声称通过。
- [ ] 更新 Architecture/Roadmap/开发说明，使其描述最终实现，清除本计划已被替代的旧约束；不引入项目生成器。

完成标准：新 backend 只需实现模块、manifest 和注册入口，不修改 main/sidebar 的具体类型分支；backend 能独立提供数据、偏好与 UI；sandbox 的二进制边界真实成立；原本地能力和用户数据没有迁移退化。

## 执行原则

按上述顺序推进，不在这次计划落盘时开工。实施时每阶段保留清晰的 diff/review 边界；遇到真实依赖阻塞先修复边界，不通过复制业务实现绕过。暂不发布、推送或安装新版本。开发验证可使用隔离构建目录，原有用户改动保持独立。
