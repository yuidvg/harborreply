import AppKit
import SwiftUI
import Carbon

@main enum HarborReplyApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // SwiftUI content lives in the retained main window; no placeholder scene is needed.
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var appUpdater: AppUpdater?
    private var explicitQuit = false
    private lazy var model = ReplyCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reject unsupported CLI modes before initializing preferences or Mail capture.
        guard !ProcessInfo.processInfo.arguments.dropFirst().contains(where: {
            $0.hasPrefix("--") && $0 != "--diagnostics"
        }) else {
            FileHandle.standardError.write(Data("未対応の起動オプションです。\n".utf8))
            exit(64)
        }
        Diagnostics.configure(enabled: model.diagnosticsEnabled || ProcessInfo.processInfo.arguments.contains("--diagnostics"), persist: false)
        Diagnostics.record(.appStarted, count: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init))
        NSApp.setActivationPolicy(.accessory)
        appUpdater = AppUpdater(model: model)
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "HarborReply")
        let menu = NSMenu()
        menu.addItem(withTitle: "HarborReplyについて", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: "HarborReplyを開く", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(withTitle: "選択メールから返信 ⌃⌥R", action: #selector(capture), keyEquivalent: "")
        menu.addItem(withTitle: "アップデートを確認…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "終了", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem?.menu = menu
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in delegate.capture() }; return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        let id = EventHotKeyID(signature: 0x48425250, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { model.message = "ショートカットを登録できませんでした。メニューバーから利用できます。" }
        showPanel()
    }
    private func installMainMenu() {
        let main = NSMenu()
        let application = NSMenu(title: "HarborReply")
        application.addItem(withTitle: "HarborReplyについて", action: #selector(showAbout), keyEquivalent: "").target = self
        application.addItem(withTitle: "設定…", action: #selector(showSettings), keyEquivalent: ",").target = self
        application.addItem(withTitle: "アップデートを確認…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        application.addItem(.separator())
        application.addItem(withTitle: "HarborReplyを隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        application.addItem(withTitle: "終了", action: #selector(quit), keyEquivalent: "q").target = self
        let applicationItem = NSMenuItem(); applicationItem.submenu = application; main.addItem(applicationItem)

        // AppKit supplies responder-chain editing shortcuts for the hosted SwiftUI editors.
        let edit = NSMenu(title: "編集")
        for (title, action, key) in [
            ("取り消す", "undo:", "z"), ("やり直す", "redo:", "Z"),
            ("切り取り", "cut:", "x"), ("コピー", "copy:", "c"),
            ("ペースト", "paste:", "v"), ("すべて選択", "selectAll:", "a")
        ] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)
        let windowMenu = NSMenu(title: "ウィンドウ")
        windowMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem(); windowItem.submenu = windowMenu; main.addItem(windowItem)
        NSApp.mainMenu = main
    }
    @objc private func checkForUpdates() { appUpdater?.checkForUpdates() }
    @objc private func showSettings() { presentPanel(); model.tab = 2 }
    @objc private func showAbout() {
        let fingerprint = (try? MailBridgeResource.fingerprint()).map { String($0.prefix(12)) } ?? "unavailable"
        NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string: "Mail Bridge: \(fingerprint)")])
    }
    @objc func showPanel() {
        presentPanel()
        model.captureMailIfEnabled()
    }
    private func presentPanel() {
        let start = Date()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 920), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "HarborReply"; w.contentView = NSHostingView(rootView: MainView(model: model))
            w.minSize = NSSize(width: 700, height: 650)
            w.isReleasedWhenClosed = false; w.center(); window = w
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        model.panelMilliseconds = Date().timeIntervalSince(start) * 1000
    }
    @objc func capture() { presentPanel(); model.tab = 0; model.captureMail() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if explicitQuit { return .terminateNow }
        guard !model.busy, !model.importing, !model.mailIndexRunning, !model.styleExtracting,
              model.session.phase != .listening, model.intent.isEmpty, model.replyBody.isEmpty else {
            model.message = "文章をコピーして返信をクリアし、処理を停止してから更新してください。"
            presentPanel()
            return .terminateCancel
        }
        return .terminateNow
    }
    @objc func quit() { explicitQuit = true; Diagnostics.record(.appStopping); model.stopMailIndex(); model.clearSession(); NSApp.terminate(nil) }
}
