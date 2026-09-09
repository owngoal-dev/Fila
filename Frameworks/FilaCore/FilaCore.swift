// FilaCore.framework: the one dynamic image every FilaKit module lives in.
//
// The app, the backend module frameworks and the shared UI all need the same
// package targets — the wire vocabulary, the file operations, the formats, the
// backend contract. If each of them linked those targets statically, the
// process would carry one copy of every class per image, and Swift's
// conformance lookup and the Objective-C runtime both misbehave on duplicate
// definitions. So the package is linked exactly once, here, and re-exported:
// `import FilaClient` in the app resolves to the module inside this framework.
//
// This file is the whole target. Nothing else belongs in it: the framework
// has no code of its own, only load commands.

@_exported import AlertController
@_exported import FilaBackendKit
@_exported import FilaBackendUI
@_exported import FilaClient
@_exported import FilaFileOps
@_exported import FilaFormats
@_exported import FilaLog
@_exported import FilaMedia
@_exported import FilaProtocol
@_exported import FilaProvider
@_exported import FilaRemote
@_exported import FilaTerminal
@_exported import SnapKit
@_exported import Then
