import Cocoa
import WebKit

private let backendURL = URL(string: "http://127.0.0.1:17840")!

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, NSSpeechSynthesizerDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var backendProcess: Process?
    private var healthAttempts = 0
    private var speechSynthesizer: NSSpeechSynthesizer?
    private var speechRequestID: String?

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
        stopNativeSpeech()
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
            startNativeSpeech(text: text, requestID: requestID, playbackRate: playbackRate)

        case "stopSpeech":
            stopNativeSpeech()

        default:
            break
        }
    }

    private func startNativeSpeech(text: String, requestID: String, playbackRate: Double) {
        stopNativeSpeech()

        // `say -v "Aman (English (India))"` is ambiguous when both the compact
        // and premium Aman voices are installed. Select the premium voice by
        // its stable macOS identifier so the desktop app never falls back to
        // the robotic compact voice merely because both share a display name.
        let preferredVoiceIDs = [
            "com.apple.voice.Aman.premium",
            "com.apple.voice.Aman",
            "com.apple.voice.Tara",
        ]
        let availableVoiceIDs = Set(NSSpeechSynthesizer.availableVoices.map(\.rawValue))
        let selectedVoiceID = preferredVoiceIDs.first(where: availableVoiceIDs.contains)
        let selectedVoice = selectedVoiceID.map(NSSpeechSynthesizer.VoiceName.init(rawValue:))

        guard let synthesizer = NSSpeechSynthesizer(voice: selectedVoice) else {
            logNative("Speech failed to start: no compatible macOS voice is installed")
            sendSpeechStatus(
                requestID: requestID,
                status: "failed",
                message: "No compatible macOS voice is installed."
            )
            return
        }

        synthesizer.delegate = self
        synthesizer.rate = Float(min(400, max(80, 190 * playbackRate)))
        synthesizer.volume = 1
        speechSynthesizer = synthesizer
        speechRequestID = requestID

        guard synthesizer.startSpeaking(text) else {
            speechSynthesizer = nil
            speechRequestID = nil
            logNative("Speech failed to start with voice \(selectedVoiceID ?? "system default")")
            sendSpeechStatus(requestID: requestID, status: "failed", message: "macOS could not start speech playback.")
            return
        }

        logNative("Speech started with voice \(selectedVoiceID ?? "system default") (request \(requestID))")
    }

    private func stopNativeSpeech() {
        guard let synthesizer = speechSynthesizer else { return }
        let requestID = speechRequestID
        speechSynthesizer = nil
        speechRequestID = nil
        synthesizer.delegate = nil
        synthesizer.stopSpeaking()
        if let requestID {
            logNative("Speech cancelled (request \(requestID))")
            sendSpeechStatus(requestID: requestID, status: "cancelled")
        }
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        guard sender === speechSynthesizer, let requestID = speechRequestID else { return }
        speechSynthesizer = nil
        speechRequestID = nil
        let status = finishedSpeaking ? "finished" : "cancelled"
        logNative("Speech \(status) (request \(requestID))")
        sendSpeechStatus(requestID: requestID, status: status)
    }

    private func sendSpeechStatus(requestID: String, status: String, message: String? = nil) {
        var detail = ["requestId": requestID, "status": status]
        if let message {
            detail["message"] = message
        }
        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8) else { return }

        webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('offline-ai-native-tts', { detail: \(json) }));"
        )
    }

    private func logNative(_ message: String) {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Offline AI", isDirectory: true)
        let logURL = logsDirectory.appendingPathComponent("native.log")
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? data.write(to: logURL)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
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
