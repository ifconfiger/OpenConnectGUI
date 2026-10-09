# OpenConnect GUI

原生 SwiftUI macOS 与 iOS 客户端，内置 OpenConnect 连接 VPN。支持多个连接、Cisco AnyConnect 等 OpenConnect 协议、用户名和密码保存、远程或本地 DNS、断线自动重连、连接状态与日志。

扁平图标的绘制源文件是 `Tools/GenerateFlatLogo.swift`；在项目根目录运行 `swift Tools/GenerateFlatLogo.swift` 可重新生成 macOS 和 iOS 的图标尺寸。

## 安装与构建

要求 Apple 芯片 Mac（macOS 13+）和 Xcode。OpenConnect 已内置，无需安装 Homebrew 或其他依赖：

```sh
xcodegen generate
xcodebuild -project OpenConnectGUI.xcodeproj -scheme OpenConnectGUI -configuration Release -derivedDataPath build-signed build
```

`Vendor/OpenConnect/` 是预编译的 OpenConnect 9.21（静态链接 OpenSSL 3.5.9，仅 arm64）：macOS 命令行程序 `macos/openconnect`、iOS 静态库 `OpenConnect.xcframework`，以及 `vpnc-script`。它们只依赖系统自带的 libxml2、zlib、iconv。运行 `Scripts/build-openconnect.sh` 可从固定版本、校验过 SHA-256 的源码重新生成，只需 Xcode 命令行工具。许可证见 `Vendor/OpenConnect/licenses/`。

macOS target 默认使用项目配置的 Developer ID 签名。要安装并使用特权辅助服务，需用同一开发团队的有效证书签署 App 与辅助服务，再将签名后的 App 安装到 `/Applications`。首次运行需在系统设置批准后台服务。仅用于编译验证时可在构建命令末尾添加 `CODE_SIGNING_ALLOWED=NO`。

构建时 `openconnect` 被签名后放进 `Contents/MacOS/`，`vpnc-script` 放进 `Contents/Resources/`；内置 OpenSSL 使用系统证书 `/etc/ssl/cert.pem` 校验服务器。macOS 版包含使用 `SMAppService` 注册的特权辅助服务；首次安装后需在“系统设置 → 通用 → 登录项与扩展”批准它，之后连接和断开通过限定用途的 XPC 接口完成。应用及辅助服务必须使用同一开发团队的有效签名；仅用 `CODE_SIGNING_ALLOWED=NO` 构建的版本不能注册服务。VPN 密码保存在本机钥匙串，连接时通过 XPC 交给辅助服务，再经标准输入传给 OpenConnect，不出现在命令参数或配置文件中。配置和日志保存在 `~/Library/Application Support/OpenConnectGUI/`，进程号文件保存在 `/var/run/vpnc/`。

日志标签显示当前连接尝试；每次新建连接时会清空上一次的日志。连接和保存失败会在窗口内提示。关闭主窗口后应用留在菜单栏，可从菜单栏重新打开窗口、连接、断开或退出。

远程 DNS 使用 VPN 下发的解析服务器，由内置的 `vpnc-script` 配置；本地 DNS 模式保留 macOS 现有 DNS，同时照常配置 VPN 路由。断开按钮会等待 OpenConnect 进程退出；如果正常信号无效，会强制结束并用连接时保存的脚本环境清理路由与 DNS。自动重连开启时，断网后应用会暂停 VPN 并等待网络恢复；OpenConnect 对短暂中断最多重试 15 秒。VPN 进程退出后，应用最多尝试重连 3 次，网络恢复或切换时重新尝试；仍在运行的连接会在网络切换后刷新。手动断开不会触发重连。

网络切换时，内置包装脚本会检查 VPN 入口是否仍有指向旧网关的静态主机路由，并在重新配置前移除；断开后也会清理这类残留路由。DNS 解析结果无需更改。

macOS 连接默认强制直连，不读取系统代理；旧配置中的代理地址也不会自动启用。只有在账号页明确打开“使用 HTTP 代理”并填写地址（如 `http://127.0.0.1:7897`）时，OpenConnect 才会经代理建立 HTTPS 隧道。代理地址不含用户名和密码。

服务器证书无效（自签名、过期、域名不符）时，可在账号中开启“忽略证书错误（不安全）”：macOS 版连接前读取服务器当前证书，并用 `--servercert` 固定信任它；iOS 版直接接受该证书。这会失去对中间人攻击的防护，只建议在内网自签名证书的场景使用。

服务器需支持所选协议的用户名与密码登录。需要网页 SSO、客户端证书或交互式二次验证的网关，目前无法通过此界面完成登录。

## iPhone 与 iPad

`OpenConnectiOS` 是 iPhone/iPad 的 SwiftUI App，`OpenConnectPacketTunnel` 是系统 VPN 扩展。扩展静态链接 `OpenConnect.xcframework`，在进程内完成 OpenConnect 认证和隧道，并用 `NEPacketTunnelFlow` 收发数据包；服务器证书用 iOS 系统信任库校验。

- **免重复输入密码**：密码保存在 App 与扩展共享的钥匙串访问组 `$(AppIdentifierPrefix)xyz.nows.openconnect.shared`。扩展启动时自动读取并回答登录表单（用户名、密码、认证组）。
- **断线重连**：开启“断线自动重连”后会启用系统按需连接（On Demand），隧道断开后由系统自动拉起。扩展内部的处理：网络切换时立刻沿用现有会话重连；网络中断时等待恢复；会话过期或被服务器结束时，用保存的密码重新登录，并按 4–60 秒退避重试，期间状态显示“正在重新连接”。手动断开会关闭按需连接。
- **防止账号锁定**：服务器拒绝保存的密码，或要求二次验证时，扩展会停止，不会重试。自动重连也不会再用同一组凭证尝试，直到你在 App 中更新密码或手动连接。

日志标签实时显示扩展日志；连接结束时会显示断开原因。需要网页 SSO、客户端证书或二次验证的网关暂不支持。实机运行需要包含 `packet-tunnel-provider` 和钥匙串共享权限的签名与 provisioning profile（团队 SWKH4B9DH8，自动签名）。模拟器编译命令：

```sh
xcodegen generate
xcodebuild -project OpenConnectGUI.xcodeproj -scheme OpenConnectiOS -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build-ios CODE_SIGNING_ALLOWED=NO build
```
