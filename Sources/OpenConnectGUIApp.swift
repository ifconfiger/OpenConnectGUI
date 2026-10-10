import SwiftUI
import Combine
import AppKit
import ServiceManagement

final class OpenConnectAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                               queue: .main) { notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "OpenConnect GUI" else { return }
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct OpenConnectGUIApp: App {
    @NSApplicationDelegateAdaptor(OpenConnectAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var updates = UpdateController()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init() {
        if CommandLine.arguments.contains("--refresh-helper") {
            let service = SMAppService.daemon(plistName: HelperService.plist)
            do {
                try service.unregister()
                try service.register()
                print("Helper status: \(service.status.rawValue)")
                exit(service.status == .enabled ? 0 : 2)
            } catch {
                fputs("Failed to update the helper: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--register-helper") {
            let service = SMAppService.daemon(plistName: HelperService.plist)
            if service.status == .notRegistered || service.status == .notFound {
                do { try service.register() }
                catch { fputs("Failed to register the helper: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            print("Helper status: \(service.status.rawValue)")
            exit(service.status == .enabled ? 0 : 2)
        }
    }

    var body: some Scene {
        WindowGroup("OpenConnect GUI", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 740, minHeight: 540)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates(idle: model.canRelaunchForUpdate) }
                    .disabled(updates.isChecking)
            }
        }

        MenuBarExtra {
            MenuBarContent(model: model, updates: updates)
        } label: {
            Image(systemName: model.connectedID == nil ? "network" : "network.badge.shield.half.filled")
                .onReceive(timer) { _ in
                    if !model.busy { model.refresh() }
                    updates.tick(idle: model.canRelaunchForUpdate)
                }
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.connectedID != nil ? "VPN Connected" : model.waitingForNetwork ? "Waiting for Network" : "VPN Disconnected")
        Button("Open Main Window") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        if model.isConnected {
            Button("Disconnect") { model.disconnect() }.disabled(model.busy)
        } else {
            Button("Connect") { model.connect() }
                .disabled(model.busy || !model.canSave || model.connectedID != nil)
        }
        Divider()
        Button("Check for Updates…") { updates.checkForUpdates(idle: model.canRelaunchForUpdate) }
            .disabled(updates.isChecking)
        Button("Quit OpenConnect GUI") { NSApp.terminate(nil) }
    }
}

private struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTab = 0

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(model.profiles) { profile in
                        HStack(spacing: 8) {
                            Image(systemName: model.connectedID == profile.id ? "checkmark.shield.fill" : "network")
                                .foregroundStyle(model.connectedID == profile.id ? .green : .secondary)
                            Text(profile.name)
                        }
                        .tag(profile.id)
                    }
                }
                Divider()
                HStack {
                    Button(action: model.add) { Image(systemName: "plus") }
                        .help("Add Connection")
                    Button(action: model.delete) { Image(systemName: "minus") }
                        .help("Delete Connection")
                        .disabled(model.selectedID == nil || model.isConnected || model.busy)
                    Spacer()
                }
                .padding(8)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .disabled(model.busy)
        } detail: {
            if model.selectedID != nil {
                detail
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "network").font(.largeTitle)
                    Text("No Connections").font(.title3)
                    Text("Click the plus button at the bottom left to add a VPN.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name.isEmpty ? String(localized: "New Connection") : model.name).font(.title2.bold())
                    Label(model.isConnected ? "Connected" : model.waitingForNetwork ? "Waiting for Network" : model.busy ? "Working…" : "Not Connected",
                          systemImage: model.isConnected ? "checkmark.circle.fill" : model.waitingForNetwork ? "wifi.slash" : "circle")
                        .foregroundStyle(model.isConnected ? .green : model.waitingForNetwork ? .orange : .secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if model.isConnected {
                    Button("Disconnect", action: model.disconnect).disabled(model.busy)
                } else {
                    Button("Connect", action: model.connect)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || !model.canSave || model.connectedID != nil)
                }
            }

            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button { model.errorMessage = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .foregroundStyle(.red)
                .padding(10)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            Picker("Details", selection: $selectedTab) {
                Text("Account").tag(0)
                Text("Log").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if selectedTab == 0 {
                accountTab
            } else {
                logTab
            }
        }
        .padding(20)
    }

    private var accountTab: some View {
        VStack(spacing: 12) {
            Form {
                TextField("Name", text: $model.name)
                TextField("Server", text: $model.server, prompt: Text("vpn.example.com"))
                Toggle("Use HTTP Proxy", isOn: $model.proxyEnabled)
                if model.proxyEnabled {
                    TextField("HTTP Proxy Address", text: $model.proxyURL,
                              prompt: Text("http://127.0.0.1:7897"))
                }
                Picker("Protocol", selection: $model.protocolName) {
                    ForEach(VPNProtocol.allCases) { vpnProtocol in
                        Text(vpnProtocol.title).tag(vpnProtocol.rawValue)
                    }
                }
                Picker("DNS", selection: $model.dnsMode) {
                    ForEach(DNSMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Reconnect Automatically", isOn: $model.autoReconnect)
                Toggle("Ignore Certificate Errors (Insecure)", isOn: $model.ignoreCertificateErrors)
                TextField("Auth Group (Optional)", text: $model.authGroup)
                TextField("Username", text: $model.username)
                SecureField("Password", text: $model.password)
            }
            .formStyle(.grouped)
            .disabled(model.busy || model.isConnected)

            HStack {
                Text("Passwords are stored in this Mac's keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.savedNotice {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Button("Save", action: model.saveTapped)
                    .disabled(!model.canSave || model.busy || model.isConnected)
            }
            Spacer(minLength: 0)
        }
    }

    private var logTab: some View {
        ScrollView {
            Text(model.log.isEmpty ? String(localized: "No logs yet") : model.log)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
