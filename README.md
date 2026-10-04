# OpenConnect GUI

原生 SwiftUI macOS 客户端，调用本机 OpenConnect 连接 VPN。支持多个连接、Cisco AnyConnect 等 OpenConnect 协议、用户名和密码保存、远程或本地 DNS、断线自动重连、连接状态与日志。

扁平图标的绘制源文件是 `Tools/GenerateFlatLogo.swift`；在项目根目录运行 `swift Tools/GenerateFlatLogo.swift` 可重新生成 macOS 和 iOS 的图标尺寸。

## 安装与构建

要求 macOS 13+、Xcode、[Homebrew OpenConnect](https://formulae.brew.sh/formula/openconnect)：

```sh
brew install openconnect
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project OpenConnectGUI.xcodeproj -scheme OpenConnectGUI -configuration Release -derivedDataPath build-signed build
```

macOS target 默认使用项目配置的 Developer ID 签名。要安装并使用特权辅助服务，需用同一开发团队的有效证书签署 App 与辅助服务，再将签名后的 App 安装到 `/Applications`。首次运行需在系统设置批准后台服务。仅用于编译验证时可在构建命令末尾添加 `CODE_SIGNING_ALLOWED=NO`。

应用查找 `/opt/homebrew/bin/openconnect` 或 `/usr/local/bin/openconnect`。macOS 版包含使用 `SMAppService` 注册的特权辅助服务；首次安装后需在“系统设置 → 通用 → 登录项与扩展”批准它，之后连接和断开通过限定用途的 XPC 接口完成。应用及辅助服务必须使用同一开发团队的有效签名；仅用 `CODE_SIGNING_ALLOWED=NO` 构建的版本不能注册服务。VPN 密码保存在本机钥匙串，连接时通过 XPC 交给辅助服务，再经标准输入传给 OpenConnect，不出现在命令参数或配置文件中。配置和日志保存在 `~/Library/Application Support/OpenConnectGUI/`，进程号文件保存在 `/var/run/vpnc/`。

日志标签显示当前连接尝试；每次新建连接时会清空上一次的日志。连接和保存失败会在窗口内提示。关闭主窗口后应用留在菜单栏，可从菜单栏重新打开窗口、连接、断开或退出。

远程 DNS 使用 VPN 下发的解析服务器，由 Homebrew 安装的 `vpnc-script` 配置；本地 DNS 模式保留 macOS 现有 DNS，同时照常配置 VPN 路由。断开按钮会等待 OpenConnect 进程退出；如果正常信号无效，会强制结束并用连接时保存的脚本环境清理路由与 DNS。自动重连开启时，断网后应用会暂停 VPN 并等待网络恢复；OpenConnect 对短暂中断最多重试 15 秒。VPN 进程退出后，应用最多尝试重连 3 次，网络恢复或切换时重新尝试；仍在运行的连接会在网络切换后刷新。手动断开不会触发重连。

网络切换时，内置包装脚本会检查 VPN 入口是否仍有指向旧网关的静态主机路由，并在重新配置前移除；断开后也会清理这类残留路由。DNS 解析结果无需更改。

服务器需支持所选协议的用户名与密码登录。需要网页 SSO、客户端证书或交互式二次验证的网关，目前无法通过此界面完成登录。

## iPhone 与 iPad

项目包含 `OpenConnectiOS` 和 `OpenConnectPacketTunnel` 两个 iOS target，可编译 iPhone/iPad 的原生 SwiftUI 界面及系统 VPN 扩展。账号、密码、DNS 选项、自动重连开关的保存，以及系统 VPN 配置和连接状态管理已实现。iOS 自动重连还需共享钥匙串供扩展在按需启动时读取凭证。

**iOS 端目前不能建立 OpenConnect VPN。** 项目已有 `NEPacketTunnelFlow` 与 OpenConnect 隧道文件描述符之间的数据包桥接，但扩展尚未接入可用于 iOS 的 libopenconnect 协议核心、认证回调和网络参数回调；点击连接会返回明确错误，不会显示假连接。macOS 的 Homebrew 可执行文件不能直接用于 iOS。实机安装和运行还需要为 App 与扩展配置包含 `packet-tunnel-provider` 权限的 Apple 签名与 provisioning profile。模拟器编译命令：

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project OpenConnectGUI.xcodeproj -scheme OpenConnectiOS -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build-ios CODE_SIGNING_ALLOWED=NO build
```
