import Cocoa
import AVFoundation
import WebKit

private let backendURL = URL(string: "http://127.0.0.1:17840")!

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, AVSpeechSynthesizerDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var backendProcess: Process?
    private var healthAttempts = 0
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var speechRequestIDs: [ObjectIdentifier: String] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        createWindow()
        startBackend()
        pollBackend()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        speechSynthesizer.stopSpeaking(at: .immediate)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "offlineAI")
        if let process = backendProcess, process.isRunning {
            process.terminate()
        }
    }

    private func installMenus() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Offline AI", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Offline AI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func createWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Voice mode synthesizes each response asynchronously. Permit its
        // audio element to continue playback after the initial button click.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.userContentController.add(self, name: "offlineAI")

        speechSynthesizer.delegate = self

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Offline AI"
        // Keep web content below the native title bar so the traffic-light
        // controls never overlap Open WebUI's logo, title, or navigation.
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 820, height: 560)
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)

        showStatus(title: "Starting Offline AI", detail: "Preparing Open WebUI and discovering local models…")
    }

    private func startBackend() {
        guard let script = Bundle.main.path(forResource: "start_backend", ofType: "sh") else {
            showStatus(title: "App resources are incomplete", detail: "start_backend.sh is missing.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] task in
            guard task.terminationStatus != 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard self?.healthAttempts ?? 0 < 120 else { return }
                self?.showStatus(
                    title: "Offline AI could not start",
                    detail: "Open ~/Library/Logs/Offline AI/backend.log for details."
                )
            }
        }

        do {
            try process.run()
            backendProcess = process
        } catch {
            showStatus(title: "Offline AI could not start", detail: error.localizedDescription)
        }
    }

    private func pollBackend() {
        healthAttempts += 1
        var request = URLRequest(url: backendURL.appendingPathComponent("health"))
        request.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let ready = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                guard let self else { return }
                if ready {
                    var components = URLComponents(url: backendURL, resolvingAgainstBaseURL: false)!
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
                    components.queryItems = [URLQueryItem(name: "desktop_build", value: build)]
                    var request = URLRequest(url: components.url!)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    self.webView.load(request)
                } else if self.healthAttempts < 120 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.pollBackend() }
                } else {
                    self.showStatus(
                        title: "Offline AI timed out",
                        detail: "Open ~/Library/Logs/Offline AI/backend.log for details, then reopen the app."
                    )
                }
            }
        }.resume()
    }

    private func showStatus(title: String, detail: String) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="dark light">
        <style>html,body{height:100%;margin:0;font:15px -apple-system,BlinkMacSystemFont,sans-serif;background:#0b0b0b;color:#eee}
        main{height:100%;display:grid;place-content:center;text-align:center;gap:12px}.mark{width:72px;height:72px;margin:auto;border-radius:18px}
        h1{font-size:24px;margin:8px 0 0}p{color:#aaa;max-width:460px;margin:0;line-height:1.5}</style></head>
        <body><main><img class="mark" src="file://\(Bundle.main.resourcePath!)/AppIcon.png"><h1>\(title)</h1><p>\(detail)</p></main></body></html>
        """
        webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "offlineAI",
              let payload = message.body as? [String: Any],
              let action = payload["action"] as? String else { return }

        switch action {
        case "speak":
            guard let text = payload["text"] as? String,
                  let requestID = payload["requestId"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            let playbackRate = (payload["playbackRate"] as? NSNumber)?.doubleValue ?? 1
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = preferredSpeechVoice()
            utterance.volume = 1
            utterance.rate = min(
                AVSpeechUtteranceMaximumSpeechRate,
                max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(playbackRate))
            )
            speechRequestIDs[ObjectIdentifier(utterance)] = requestID
            speechSynthesizer.speak(utterance)

        case "stopSpeech":
            speechSynthesizer.stopSpeaking(at: .immediate)

        default:
            break
        }
    }

    private func preferredSpeechVoice() -> AVSpeechSynthesisVoice? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix("en")
        }

        if #available(macOS 10.15, *) {
            if let premium = englishVoices.first(where: { $0.quality == .premium }) {
                return premium
            }
            if let enhanced = englishVoices.first(where: { $0.quality == .enhanced }) {
                return enhanced
            }
        }

        return AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en-US")
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        sendSpeechStatus(for: utterance, status: "finished")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        sendSpeechStatus(for: utterance, status: "cancelled")
    }

    private func sendSpeechStatus(for utterance: AVSpeechUtterance, status: String) {
        guard let requestID = speechRequestIDs.removeValue(forKey: ObjectIdentifier(utterance)) else { return }
        let detail = ["requestId": requestID, "status": status]
        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8) else { return }

        webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('offline-ai-native-tts', { detail: \(json) }));"
        )
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // The packaged UI is served only from the loopback backend. Granting the
        // WebKit request lets macOS show and remember its normal mic/camera consent.
        if origin.host == "127.0.0.1" || origin.host == "localhost" {
            decisionHandler(.grant)
        } else {
            decisionHandler(.deny)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if #available(macOS 11.3, *), navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

        if let url = navigationAction.request.url,
           let host = url.host,
           host != "127.0.0.1" && host != "localhost" && navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    @available(macOS 11.3, *)
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else {
                completionHandler(nil)
                return
            }

            // NSSavePanel has already asked the user to confirm an overwrite.
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            completionHandler(url)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
