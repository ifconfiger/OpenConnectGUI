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
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init() {
        if CommandLine.arguments.contains("--refresh-helper") {
            let service = SMAppService.daemon(plistName: HelperService.plist)
            do {
                try service.unregister()
                try service.register()
                print("辅助服务状态：\(service.status.rawValue)")
                exit(service.status == .enabled ? 0 : 2)
            } catch {
                fputs("辅助服务更新失败：\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--register-helper") {
            let service = SMAppService.daemon(plistName: HelperService.plist)
            if service.status == .notRegistered || service.status == .notFound {
                do { try service.register() }
                catch { fputs("辅助服务注册失败：\(error.localizedDescription)\n", stderr); exit(1) }
            }
            print("辅助服务状态：\(service.status.rawValue)")
            exit(service.status == .enabled ? 0 : 2)
        }
    }

    var body: some Scene {
        WindowGroup("OpenConnect GUI", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 740, minHeight: 540)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.connectedID == nil ? "network" : "network.badge.shield.half.filled")
                .onReceive(timer) { _ in if !model.busy { model.refresh() } }
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.connectedID != nil ? "VPN 已连接" : model.waitingForNetwork ? "等待网络恢复" : "VPN 未连接")
        Button("打开主窗口") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        if model.isConnected {
            Button("断开连接") { model.disconnect() }.disabled(model.busy)
        } else {
            Button("连接") { model.connect() }
                .disabled(model.busy || !model.canSave || model.connectedID != nil)
        }
        Divider()
        Button("退出 OpenConnect GUI") { NSApp.terminate(nil) }
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
                        .help("新增连接")
                    Button(action: model.delete) { Image(systemName: "minus") }
                        .help("删除连接")
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
                    Text("尚无连接").font(.title3)
                    Text("点击左下角的加号添加 VPN。").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name.isEmpty ? "新连接" : model.name).font(.title2.bold())
                    Label(model.isConnected ? "已连接" : model.waitingForNetwork ? "等待网络恢复" : model.busy ? "正在处理…" : "未连接",
                          systemImage: model.isConnected ? "checkmark.circle.fill" : model.waitingForNetwork ? "wifi.slash" : "circle")
                        .foregroundStyle(model.isConnected ? .green : model.waitingForNetwork ? .orange : .secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if model.isConnected {
                    Button("断开连接", action: model.disconnect).disabled(model.busy)
                } else {
                    Button("连接", action: model.connect)
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
                    .accessibilityLabel("关闭提示")
                }
                .foregroundStyle(.red)
                .padding(10)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            Picker("详情", selection: $selectedTab) {
                Text("账号").tag(0)
                Text("日志").tag(1)
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
                TextField("名称", text: $model.name)
                TextField("服务器", text: $model.server, prompt: Text("vpn.example.com"))
                Picker("协议", selection: $model.protocolName) {
                    ForEach(VPNProtocol.allCases) { vpnProtocol in
                        Text(vpnProtocol.title).tag(vpnProtocol.rawValue)
                    }
                }
                Picker("DNS", selection: $model.dnsMode) {
                    ForEach(DNSMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("断线自动重连", isOn: $model.autoReconnect)
                TextField("认证组（可选）", text: $model.authGroup)
                TextField("用户名", text: $model.username)
                SecureField("密码", text: $model.password)
            }
            .formStyle(.grouped)
            .disabled(model.busy || model.isConnected)

            HStack {
                Text("密码保存在本机钥匙串")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("保存", action: model.saveTapped)
                    .disabled(!model.canSave || model.busy || model.isConnected)
            }
            Spacer(minLength: 0)
        }
    }

    private var logTab: some View {
        ScrollView {
            Text(model.log.isEmpty ? "暂无日志" : model.log)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
