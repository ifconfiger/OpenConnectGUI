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
    @Published var status: NEVPNStatus = .disconnected
    @Published var busy = false
    @Published var message: String?
    @Published var log = ""

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

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
        do { password = try KeychainStore.password(for: profile.id) ?? "" }
        catch { password = ""; message = error.localizedDescription }
        log = ""
    }

    func save() {
        do {
            guard canSave, let id = selectedID,
                  let index = profiles.firstIndex(where: { $0.id == id }) else { return }
            profiles[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            profiles[index].server = server.trimmingCharacters(in: .whitespacesAndNewlines)
            profiles[index].username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            profiles[index].protocolName = protocolName
            profiles[index].authGroup = authGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            profiles[index].dnsMode = dnsMode
            profiles[index].autoReconnect = autoReconnect
            try KeychainStore.save(password, for: id)
            try MobileProfileStore.save(profiles)
            message = "账号已保存。"
        } catch { message = error.localizedDescription }
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
        save()
        guard let profile = selectedProfile, !password.isEmpty else {
            message = "请填写并保存 VPN 密码。"
            return
        }
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
                // On-demand starts do not carry startVPNTunnel(options:). Keep
                // this disabled until the extension can read credentials from
                // a shared Keychain access group.
                manager.onDemandRules = []
                manager.isOnDemandEnabled = false
                try await save(manager)
                try await load(manager)
                try manager.connection.startVPNTunnel(options: ["password": password as NSString])
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
                Task { @MainActor in
                    guard let self, let manager = self.manager else { return }
                    self.status = manager.connection.status
                }
            }
        } catch { message = error.localizedDescription }
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
                    Label(model.isConnected ? "已连接" : "未连接",
                          systemImage: model.isConnected ? "checkmark.shield.fill" : "network")
                        .foregroundStyle(model.isConnected ? .green : .secondary)
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
            TextField("认证组（可选）", text: $model.authGroup)
            TextField("用户名", text: $model.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("密码", text: $model.password)
            Button("保存", action: model.save).disabled(!model.canSave || model.isConnected)
        }
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
