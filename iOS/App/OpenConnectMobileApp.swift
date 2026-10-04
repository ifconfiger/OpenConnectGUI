import SwiftUI
import NetworkExtension

@main
struct OpenConnectMobileApp: App {
    @StateObject private var model = MobileVPNModel()

    var body: some Scene {
        WindowGroup {
            MobileContentView(model: model)
        }
    }
}

@MainActor
final class MobileVPNModel: ObservableObject {
    @Published var profiles: [VPNProfile] = []
    @Published var selectedID: UUID?
    @Published var name = ""
    @Published var server = ""
    @Published var username = ""
    @Published var password = ""
    @Published var protocolName = VPNProtocol.anyconnect.rawValue
    @Published var authGroup = ""
    @Published var dnsMode: DNSMode = .remote
    @Published var autoReconnect = true
    @Published var ignoreCertificateErrors = false
    @Published var notice: String?
    @Published var status: NEVPNStatus = .disconnected
    @Published var busy = false
    @Published var message: String?
    @Published var log = ""

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var logTimer: Timer?
    private var noticeTask: Task<Void, Never>?

    init() {
        do { profiles = try MobileProfileStore.load() }
        catch { message = error.localizedDescription }
        if let first = profiles.first { select(first.id) }
        Task { await loadManager() }
    }

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
    }

    var selectedProfile: VPNProfile? { profiles.first { $0.id == selectedID } }
    var isConnected: Bool { status == .connected || status == .connecting || status == .reasserting }
    var statusText: String {
        switch status {
        case .connected: "已连接"
        case .connecting: "正在连接…"
        case .reasserting: "正在重新连接…"
        case .disconnecting: "正在断开…"
        default: "未连接"
        }
    }
    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func add() {
        let profile = VPNProfile(name: "新连接", server: "", username: "")
        profiles.append(profile)
        select(profile.id)
    }

    func select(_ id: UUID?) {
        selectedID = id
        guard let profile = selectedProfile else { return }
        name = profile.name
        server = profile.server
        username = profile.username
        protocolName = profile.protocolName
        authGroup = profile.authGroup
        dnsMode = profile.dnsMode
        autoReconnect = profile.autoReconnect
        ignoreCertificateErrors = profile.ignoreCertificateErrors
        do { password = try KeychainStore.password(for: profile.id) ?? "" }
        catch { password = ""; message = error.localizedDescription }
        log = ""
    }

    @discardableResult
    func save() -> Bool {
        guard canSave else {
            message = "请填写名称、服务器和用户名。"
            return false
        }
        do {
            // Editing before any profile exists (first launch) creates one.
            if selectedID == nil || !profiles.contains(where: { $0.id == selectedID }) {
                let profile = VPNProfile(name: name, server: server, username: username)
                profiles.append(profile)
                selectedID = profile.id
            }
            guard let id = selectedID, let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
            profiles[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            profiles[index].server = server.trimmingCharacters(in: .whitespacesAndNewlines)
            profiles[index].username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            profiles[index].protocolName = protocolName
            profiles[index].authGroup = authGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            profiles[index].dnsMode = dnsMode
            profiles[index].autoReconnect = autoReconnect
            profiles[index].ignoreCertificateErrors = ignoreCertificateErrors
            try KeychainStore.save(password, for: id)
            try MobileProfileStore.save(profiles)
            message = nil
            show(notice: "已保存")
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    private func show(notice text: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func delete() {
        guard let selectedID, !isConnected else { return }
        do {
            try KeychainStore.delete(for: selectedID)
            profiles.removeAll { $0.id == selectedID }
            try MobileProfileStore.save(profiles)
            select(profiles.first?.id)
        } catch { message = error.localizedDescription }
    }

    func connect() {
        guard save() else { return }
        guard let profile = selectedProfile, !password.isEmpty else {
            message = "请填写并保存 VPN 密码。"
            return
        }
        message = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let manager = try await currentManager()
                let configuration = NETunnelProviderProtocol()
                configuration.providerBundleIdentifier = "xyz.nows.openconnect.tunnel"
                configuration.serverAddress = profile.server
                configuration.providerConfiguration = ["profile": try JSONEncoder().encode(profile)]
                manager.protocolConfiguration = configuration
                manager.localizedDescription = profile.name
                manager.isEnabled = true
                // With auto-reconnect the system restarts the tunnel whenever it
                // drops; the extension reads the password from the shared keychain.
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                manager.onDemandRules = [rule]
                manager.isOnDemandEnabled = profile.autoReconnect
                try await save(manager)
                try await load(manager)
                try manager.connection.startVPNTunnel(options: ["password": password as NSString,
                                                                "manual": NSNumber(value: true)])
                status = manager.connection.status
                log = "正在连接 \(profile.server)…"
            } catch {
                message = error.localizedDescription
                log = "连接失败：\(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        guard let manager else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                manager.isOnDemandEnabled = false
                try await save(manager)
                manager.connection.stopVPNTunnel()
                status = manager.connection.status
                log = "已请求断开连接。"
            } catch { message = error.localizedDescription }
        }
    }

    private func loadManager() async {
        do {
            let managers = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
                NETunnelProviderManager.loadAllFromPreferences { managers, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: managers ?? []) }
                }
            }
            let manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == "xyz.nows.openconnect.tunnel" }
                ?? NETunnelProviderManager()
            self.manager = manager
            status = manager.connection.status
            statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange,
                                                                     object: manager.connection,
                                                                     queue: .main) { [weak self] _ in
                Task { @MainActor in self?.statusDidChange() }
            }
            statusDidChange()
        } catch { message = error.localizedDescription }
    }

    private func statusDidChange() {
        guard let manager else { return }
        let previous = status
        status = manager.connection.status
        if status == .disconnected || status == .invalid {
            logTimer?.invalidate()
            logTimer = nil
            if previous != .disconnected && previous != .invalid { showDisconnectError(manager) }
        } else if logTimer == nil {
            refreshLog()
            logTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshLog() }
            }
        }
    }

    private func refreshLog() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        try? session.sendProviderMessage(Data("log".utf8)) { [weak self] data in
            guard let data, !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.log = text }
        }
    }

    private func showDisconnectError(_ manager: NETunnelProviderManager) {
        manager.connection.fetchLastDisconnectError { [weak self] error in
            guard let error else { return }
            let message = (error as NSError).userInfo[NSUnderlyingErrorKey].flatMap { ($0 as? Error)?.localizedDescription }
                ?? error.localizedDescription
            Task { @MainActor in
                self?.message = message
                self?.log += (self?.log.isEmpty == false ? "\n" : "") + "连接已结束：\(message)"
            }
        }
    }

    private func currentManager() async throws -> NETunnelProviderManager {
        if manager == nil { await loadManager() }
        guard let manager else { throw NSError(domain: "OpenConnect", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "无法加载系统 VPN 配置。"]) }
        return manager
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func load(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

private struct MobileContentView: View {
    @ObservedObject var model: MobileVPNModel
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if !model.profiles.isEmpty {
                    Picker("连接", selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                        ForEach(model.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal)
                }

                HStack {
                    Label(model.statusText,
                          systemImage: model.status == .connected ? "checkmark.shield.fill" : "network")
                        .foregroundStyle(model.status == .connected ? .green : .secondary)
                    Spacer()
                    Button(model.isConnected ? "断开连接" : "连接") {
                        if model.isConnected { model.disconnect() } else { model.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.selectedID == nil || (!model.isConnected && !model.canSave))
                }
                .padding(.horizontal)

                if let message = model.message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }

                Picker("详情", selection: $tab) {
                    Text("账号").tag(0)
                    Text("日志").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if tab == 0 { account } else { log }
            }
            .overlay(alignment: .bottom) {
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.green, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.notice)
            .navigationTitle("OpenConnect")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("新增", systemImage: "plus", action: model.add)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("删除", systemImage: "trash", action: model.delete)
                        .disabled(model.selectedID == nil || model.isConnected)
                }
            }
        }
    }

    private var account: some View {
        Form {
            TextField("名称", text: $model.name)
            TextField("服务器", text: $model.server)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker("协议", selection: $model.protocolName) {
                ForEach(VPNProtocol.allCases) { item in Text(item.title).tag(item.rawValue) }
            }
            Picker("DNS", selection: $model.dnsMode) {
                ForEach(DNSMode.allCases) { item in Text(item.title).tag(item) }
            }
            Toggle("断线自动重连", isOn: $model.autoReconnect)
            Toggle("忽略证书错误（不安全）", isOn: $model.ignoreCertificateErrors)
            TextField("认证组（可选）", text: $model.authGroup)
            TextField("用户名", text: $model.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("密码", text: $model.password)
            Section {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                    model.save()
                } label: {
                    Text("保存").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isConnected)
            } footer: {
                Text("密码保存在钥匙串，VPN 扩展自动读取，无需每次输入。")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .disabled(model.busy)
    }

    private var log: some View {
        ScrollView {
            Text(model.log.isEmpty ? "暂无日志" : model.log)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding()
        }
    }
}
