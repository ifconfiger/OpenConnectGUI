#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
cat > "$fixture/main.swift" <<'EOF'
import Foundation

let id = UUID().uuidString
let old = """
{"id":"\(id)","name":"VPN","server":"vpn.example.com","username":"user",\
"proxyURL":"http://127.0.0.1:7897"}
"""
var profile = try JSONDecoder().decode(VPNProfile.self, from: Data(old.utf8))
precondition(!profile.proxyEnabled, "legacy proxy URL must not enable proxy")
precondition(profile.hasValidProxy)
profile.proxyEnabled = true
precondition(profile.hasValidProxy)
profile.proxyURL = ""
precondition(!profile.hasValidProxy, "enabled proxy needs an address")
profile.proxyURL = "http://127.0.0.1:7897"
let saved = try JSONEncoder().encode(profile)
let restored = try JSONDecoder().decode(VPNProfile.self, from: saved)
precondition(restored.proxyEnabled)
print("proxy opt-in migration test passed")
EOF
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc \
  "$root/Sources/Profile.swift" "$fixture/main.swift" -o "$fixture/proxy-opt-in"
"$fixture/proxy-opt-in"
