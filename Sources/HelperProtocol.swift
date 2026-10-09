import Foundation

enum HelperService {
    static let name = "xyz.nows.openconnect.privileged"
    static let plist = name + ".plist"
}

@objc protocol OpenConnectHelperProtocol {
    func connect(_ profileData: Data, password: String,
                 reply: @escaping (Int32, String) -> Void)
    func disconnect(_ profileID: String, reply: @escaping (Int32, String) -> Void)
    func cleanup(_ profileID: String, reply: @escaping (Int32, String) -> Void)
    func refreshNetwork(_ profileID: String, reply: @escaping (Int32, String) -> Void)
}
