import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [VPNProfile] = []
    @Published var selectedID: UUID?
    @Published var name = ""
    @Published var server = ""
    @Published var username = ""
    @Published var password = ""
    @Published var protocolName = "anyconnect"
    @Published var authGroup = ""
    @Published var dnsMode: DNSMode = .remote
    @Published var autoReconnect = true
    @Published var ignoreCertificateErrors = false
    @Published var savedNotice = false
    @Published var busy = false
    @Published var connectedID: UUID?
    @Published private(set) var waitingForNetwork = false
    @Published var log = ""
    @Published var errorMessage: String?
    private var supervisedID: UUID?
    private var manualDisconnectID: UUID?
    private var nextReconnectAt: Date?
    private var reconnectAttempts = 0
    private var reconnectExhausted = false
    private var networkAvailable: Bool?
    private var networkSignature: String?
    private var offlineSince: Date?
    private var offlineStopAttempted = false
    private var pendingNetworkRefreshAt: Date?
    private let networkObserver = NetworkPathObserver()

    init() {
        do {
            profiles = try ProfileStore.load()
            if let first = profiles.first { select(first.id) }
            refresh()
            if let helperError = PrivilegedCommand.shared.prepare() { errorMessage = helperError }
        } catch {
            errorMessage = error.localizedDescription
        }
        networkObserver.onChange = { [weak self] state in self?.networkDidChange(state) }
        networkObserver.start()
    }

    var selectedProfile: VPNProfile? { profiles.first { $0.id == selectedID } }
    var isConnected: Bool { connectedID == selectedID && connectedID != nil }
    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !server.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty
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
        savedNotice = false
        do { password = try KeychainStore.password(for: profile.id) ?? "" }
        catch { password = ""; errorMessage = error.localizedDescription }
        log = OpenConnectController.readLog(for: profile)
    }

    func save() throws {
        guard canSave, let id = selectedID, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].protocolName = protocolName
        profiles[index].authGroup = authGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].dnsMode = dnsMode
        profiles[index].autoReconnect = autoReconnect
        profiles[index].ignoreCertificateErrors = ignoreCertificateErrors
        if !autoReconnect && supervisedID == id {
            supervisedID = nil
            nextReconnectAt = nil
            waitingForNetwork = false
        }
        try KeychainStore.save(password, for: id)
        try ProfileStore.save(profiles)
    }

    func saveTapped() {
        do {
            try save()
            errorMessage = nil
            savedNotice = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.savedNotice = false }
        } catch { errorMessage = error.localizedDescription }
    }

    func delete() {
        guard let profile = selectedProfile, !isConnected else { return }
        if supervisedID == profile.id {
            supervisedID = nil
            nextReconnectAt = nil
            waitingForNetwork = false
        }
        do {
            try KeychainStore.delete(for: profile.id)
            profiles.removeAll { $0.id == profile.id }
            try ProfileStore.save(profiles)
            selectedID = nil
            name = ""; server = ""; username = ""; password = ""; authGroup = ""
            select(profiles.first?.id)
        } catch { errorMessage = error.localizedDescription }
    }

    func connect() {
        errorMessage = nil
        do {
            try save()
            guard let profile = selectedProfile else { return }
            guard connectedID == nil else { throw VPNError.alreadyConnected }
            if networkAvailable == false {
                if profile.autoReconnect {
                    supervisedID = profile.id
                    reconnectAttempts = 0
                    reconnectExhausted = false
                    waitingForNetwork = true
                } else {
                    errorMessage = "当前没有可用网络。"
                }
                return
            }
            busy = true
            let savedPassword = password
            Task.detached {
                let result = Result { try OpenConnectController.connect(profile, password: savedPassword) }
                await MainActor.run {
                    self.busy = false
                    if case .failure(let error) = result { self.errorMessage = error.localizedDescription }
                    else if profile.autoReconnect { self.supervisedID = profile.id }
                    self.refresh()
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func disconnect() {
        guard let profile = selectedProfile else { return }
        errorMessage = nil
        supervisedID = nil
        nextReconnectAt = nil
        pendingNetworkRefreshAt = nil
        waitingForNetwork = false
        manualDisconnectID = profile.id
        busy = true
        Task.detached {
            let result = Result { try OpenConnectController.disconnect(profile) }
            await MainActor.run {
                self.busy = false
                if case .failure(let error) = result {
                    self.manualDisconnectID = nil
                    self.errorMessage = error.localizedDescription
                }
                self.refresh()
            }
        }
    }

    func refresh() {
        let previous = connectedID
        let current = profiles.first { OpenConnectController.runningPID(for: $0) != nil }?.id
        connectedID = current
        if let current {
            if supervisedID == nil, manualDisconnectID != current,
               profiles.first(where: { $0.id == current })?.autoReconnect == true {
                supervisedID = current
            }
            if supervisedID == current {
                nextReconnectAt = nil
                reconnectAttempts = 0
            }
        } else if let id = supervisedID, networkAvailable != false, !reconnectExhausted,
                  profiles.contains(where: { $0.id == id && $0.autoReconnect }) {
            if previous == id && nextReconnectAt == nil { nextReconnectAt = Date().addingTimeInterval(5) }
            if let deadline = nextReconnectAt, Date() >= deadline, !busy {
                attemptReconnect(id: id)
            }
        }
        if current == nil { manualDisconnectID = nil }
        if let profile = selectedProfile { log = OpenConnectController.readLog(for: profile) }
        if let current, current == supervisedID, !busy,
           let profile = profiles.first(where: { $0.id == current }) {
            if networkAvailable == false, !offlineStopAttempted,
               let offlineSince, Date().timeIntervalSince(offlineSince) >= 3 {
                suspendForNetworkLoss(profile)
            } else if networkAvailable == true, let deadline = pendingNetworkRefreshAt,
                      Date() >= deadline {
                refreshTunnelForNetworkChange(profile)
            }
        }
    }

    private func networkDidChange(_ state: PhysicalNetworkState) {
        let previousAvailable = networkAvailable
        let previousSignature = networkSignature
        guard previousAvailable != state.available || previousSignature != state.signature else { return }
        networkAvailable = state.available
        networkSignature = state.signature
        if !state.available {
            offlineSince = Date()
            offlineStopAttempted = false
            pendingNetworkRefreshAt = nil
            nextReconnectAt = nil
            waitingForNetwork = supervisedID != nil
            return
        }
        offlineSince = nil
        offlineStopAttempted = false
        waitingForNetwork = false
        guard supervisedID != nil else { return }
        reconnectAttempts = 0
        reconnectExhausted = false
        errorMessage = nil
        if connectedID == supervisedID {
            pendingNetworkRefreshAt = Date().addingTimeInterval(2)
        } else {
            nextReconnectAt = Date().addingTimeInterval(2)
        }
    }

    private func suspendForNetworkLoss(_ profile: VPNProfile) {
        offlineStopAttempted = true
        busy = true
        Task.detached {
            let result = Result { try OpenConnectController.disconnect(profile) }
            await MainActor.run {
                self.busy = false
                if case .failure(let error) = result,
                   OpenConnectController.runningPID(for: profile) != nil {
                    self.errorMessage = "断网后暂停 VPN 失败：" + error.localizedDescription
                }
                self.refresh()
            }
        }
    }

    private func refreshTunnelForNetworkChange(_ profile: VPNProfile) {
        pendingNetworkRefreshAt = nil
        busy = true
        Task.detached {
            let result = Result { try OpenConnectController.refreshNetwork(profile) }
            await MainActor.run {
                self.busy = false
                if case .failure(let error) = result,
                   OpenConnectController.runningPID(for: profile) != nil {
                    self.errorMessage = "网络切换后重新连接失败：" + error.localizedDescription
                }
                self.refresh()
            }
        }
    }

    private func attemptReconnect(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        nextReconnectAt = nil
        busy = true
        Task.detached {
            let result = Result {
                guard let password = try KeychainStore.password(for: id), !password.isEmpty else {
                    throw VPNError.missingPassword
                }
                try OpenConnectController.connect(profile, password: password)
            }
            await MainActor.run {
                self.busy = false
                guard self.supervisedID == id else { return }
                switch result {
                case .success:
                    self.reconnectAttempts = 0
                    self.reconnectExhausted = false
                    self.refresh()
                case .failure(let error):
                    if self.networkAvailable == false {
                        self.waitingForNetwork = true
                        self.nextReconnectAt = nil
                        return
                    }
                    self.reconnectAttempts += 1
                    if self.reconnectAttempts >= 3 {
                        self.reconnectExhausted = true
                        self.errorMessage = "自动重连已暂停，网络变化后会重试：" + error.localizedDescription
                    } else {
                        self.nextReconnectAt = Date().addingTimeInterval(Double(5 * (1 << self.reconnectAttempts)))
                    }
                }
            }
        }
    }
}
