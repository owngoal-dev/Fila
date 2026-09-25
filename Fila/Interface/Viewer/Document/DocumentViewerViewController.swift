import FilaBackendUI
import FilaFormats
import FilaLog
import FilaProtocol
import SnapKit
import Then
import UIKit
import WebKit

/// Word, Excel, PowerPoint, Pages, Numbers, Keynote and RTF, drawn by WebKit.
///
/// WebKit converts these itself — the same conversion QuickLook shows — when
/// one arrives as a page's main resource under its MIME type. The resource is
/// served by `DocumentSchemeHandler` from the descriptor, so the bytes go from
/// the kernel to WebKit's content process with no path in between: no second
/// `open(2)`, no staged copy, and a root-only file draws like any other.
/// `QLPreviewController` cannot do that on any path: it renders in a system
/// extension that opens the URL itself, as `mobile`.
///
/// The page is a converted document, not the web. Nothing is stored, a
/// content rule list blocks every load outside the document's own schemes,
/// and a tapped link leaves for the system instead of navigating here. Page
/// JavaScript stays on, because a workbook switches sheets with the
/// converter's own script.
///
/// When WebKit declines the type or fails to draw it, the file opens as its
/// bytes alone would have — see `openWithoutDocumentViewer`.
final class DocumentViewerViewController: TabContentViewController, WKNavigationDelegate {
    private let handler: DocumentSchemeHandler?
    private lazy var webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration().then {
        // Nothing a document does outlives the screen.
        $0.websiteDataStore = .nonPersistent()
        $0.mediaTypesRequiringUserActionForPlayback = .all
        if let handler {
            $0.setURLSchemeHandler(handler, forURLScheme: DocumentSchemeHandler.scheme)
        }
    }).then {
        // A link preview loads the link, which is the network by another door.
        $0.allowsLinkPreview = false
        $0.navigationDelegate = self
    }

    /// Over the page until WebKit has drawn it: conversion takes a moment,
    /// and the page is blank until then.
    private let status = StatusView(content: .loading(String(localized: "Opening…")))
    private var state = State.loading
    /// The document's own load. Only its failure is the document failing.
    private var documentNavigation: WKNavigation?

    private enum State {
        case loading
        case shown
        /// The content process died once after the page was shown, and the
        /// page was loaded again. A second death gives up.
        case reloaded
        case abandoned
    }

    init(details: FileDetails, file: DescriptorFile) {
        let name = (details.path as NSString).lastPathComponent
        handler = FileFormat.documentMIMEType(name: name).map {
            DocumentSchemeHandler(file: file, name: name, mimeType: $0)
        }
        super.init(nibName: nil, bundle: nil)
        title = name
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        view.addSubview(webView)
        view.addSubview(status)
        webView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        status.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        guard let handler else {
            // Open As › Document on a name WebKit has no type for.
            abandon("no document type for its name")
            return
        }
        DocumentContentRules.load { [weak self] rules in
            guard let self, state == .loading else { return }
            // Fail closed: without the rules the page could reach the network.
            guard let rules else {
                abandon("the content rules did not compile")
                return
            }
            webView.configuration.userContentController.add(rules)
            documentNavigation = webView.load(URLRequest(url: handler.url))
        }
    }

    /// Hands the file back to its container to open without WebKit, once.
    /// Deferred a turn: the container replaces this controller, and doing it
    /// from inside a WebKit callback or `viewDidLoad` would pull the view out
    /// from under its own caller.
    private func abandon(_ reason: String) {
        guard state != .abandoned else { return }
        state = .abandoned
        FilaLog.info("document viewer: \(reason)")
        webView.stopLoading()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            (parent as? ViewerContainerViewController)?.openWithoutDocumentViewer(from: self)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void,
    ) {
        guard let handler, let url = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        if handler.isDocument(url) {
            // The document, or a place inside it.
            decisionHandler(.allow)
            return
        }
        if action.navigationType == .linkActivated {
            decisionHandler(.cancel)
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased()) {
                UIApplication.shared.open(url)
            }
            return
        }
        // The converter's own pages: a workbook's sheets, a frame's blank.
        let isFrame = action.targetFrame.map { !$0.isMainFrame } ?? false
        let isConverted = ["x-apple-ql-id", "about"].contains(url.scheme?.lowercased())
        decisionHandler(isFrame && isConverted ? .allow : .cancel)
    }

    func webView(
        _: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void,
    ) {
        guard response.canShowMIMEType else {
            decisionHandler(.cancel)
            if response.isForMainFrame {
                abandon("WebKit cannot show \(response.response.mimeType ?? "its type")")
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        guard state == .loading || state == .reloaded else { return }
        if state == .loading {
            state = .shown
        }
        status.removeFromSuperview()
    }

    func webView(_: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(navigation, error)
    }

    func webView(_: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(navigation, error)
    }

    /// The document's own load failing before it was shown is the document
    /// failing to open. Any other navigation is one the policy refused.
    private func failed(_ navigation: WKNavigation?, _ error: Error) {
        guard state == .loading, let navigation, navigation === documentNavigation else { return }
        abandon("the document failed to load: \(error)")
    }

    /// The content process is gone — memory, usually. Before the page was
    /// shown that is the document being too much for it; after, the system
    /// reclaimed it in the background, and the page is loaded again, once.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        switch state {
        case .shown:
            state = .reloaded
            webView.reload()
        case .loading, .reloaded:
            abandon("WebKit's content process ended")
        case .abandoned:
            break
        }
    }
}

/// The network, off: every load is blocked, then the schemes a converted
/// document uses are let back in. Compiled once per launch and shared.
///
/// A content rule list is the only switch WebKit gives for subresources — an
/// image, a stylesheet, a `fetch` — which a navigation policy never sees.
/// The probe that chose this showed an `https` image loading without it and
/// blocked with it, while a workbook's sheet tabs kept working.
private enum DocumentContentRules {
    private static var compiled: WKContentRuleList?
    private static var waiting: [(WKContentRuleList?) -> Void]?

    private static let identifier = "wiki.qaq.fila.document-offline"
    /// One rule per scheme: rule lists take no alternation in a URL filter.
    private static let source = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^\(DocumentSchemeHandler.scheme):"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^x-apple-ql-id:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    /// On the main thread, like its callers. A failed compile is not kept, so
    /// the next document tries again.
    static func load(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let compiled {
            completion(compiled)
            return
        }
        if waiting != nil {
            waiting?.append(completion)
            return
        }
        waiting = [completion]
        guard let store = WKContentRuleListStore.default() else {
            finish(nil)
            return
        }
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) { list, error in
            if let error {
                FilaLog.warning("document content rules: \(error)")
            }
            finish(list)
        }
    }

    private static func finish(_ list: WKContentRuleList?) {
        compiled = list
        let callers = waiting ?? []
        waiting = nil
        for caller in callers {
            caller(list)
        }
    }
}
