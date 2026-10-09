#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/bin" "$fixture/state"
sed "s#/var/run/vpnc#$fixture/state#g" "$root/Helper/vpnc-wrapper.sh" > "$fixture/wrapper.sh"

cat > "$fixture/bin/route" <<'EOF'
#!/bin/sh
case "$1 $2 $3" in
  '-n get default')
    printf '   route to: default\n    gateway: %s\n' "$(cat "$FIXTURE/current-gateway")"
    ;;
  '-n get '* )
    if [ -f "$FIXTURE/host-route" ]; then
      printf 'destination: %s\n    gateway: %s\n       flags: <UP,GATEWAY,HOST,DONE,STATIC>\n' "$3" "$(cat "$FIXTURE/host-route")"
    else
      printf 'destination: default\n    gateway: %s\n' "$(cat "$FIXTURE/current-gateway")"
    fi
    ;;
  '-n delete -host')
    rm -f "$FIXTURE/host-route"
    ;;
  'add -host '* )
    [ ! -f "$FIXTURE/host-route" ] || exit 1
    printf '%s\n' "$4" > "$FIXTURE/host-route"
    ;;
  'delete -host '* )
    [ -f "$FIXTURE/host-route" ] || exit 1
    [ "$(cat "$FIXTURE/host-route")" = "$4" ] || exit 1
    rm "$FIXTURE/host-route"
    ;;
  *) echo "unexpected route call: $*" >&2; exit 2 ;;
esac
EOF

cat > "$fixture/bin/netstat" <<'EOF'
#!/bin/sh
printf 'Routing tables\nDestination        Gateway            Flags   Netif\n'
if [ -f "$FIXTURE/host-route" ]; then
  printf '%s     %s     UGHS    en0\n' "$VPNGATEWAY" "$(cat "$FIXTURE/host-route")"
fi
EOF

cat > "$fixture/upstream.sh" <<'EOF'
#!/bin/sh
gateway=$(route -n get default | awk '$1 == "gateway:" { print $2; exit }')
case "$reason" in
  connect|reconnect|attempt-reconnect) route add -host "$VPNGATEWAY" "$gateway" ;;
  disconnect) route delete -host "$VPNGATEWAY" "$gateway" || : ;;
esac
EOF
chmod +x "$fixture/bin/route" "$fixture/bin/netstat" "$fixture/upstream.sh" "$fixture/wrapper.sh"

export FIXTURE="$fixture" PATH="$fixture/bin:$PATH" VPNPID=987654 VPNGATEWAY=101.71.194.176
printf '%s\n' 192.168.5.2 > "$fixture/host-route"
printf '%s\n' 10.196.0.1 > "$fixture/current-gateway"
reason=connect "$fixture/wrapper.sh" "$fixture/upstream.sh" remote >/dev/null
[ "$(cat "$fixture/host-route")" = 10.196.0.1 ]

printf '%s\n' 10.197.0.1 > "$fixture/current-gateway"
reason=reconnect "$fixture/wrapper.sh" "$fixture/upstream.sh" remote >/dev/null
[ "$(cat "$fixture/host-route")" = 10.197.0.1 ]

printf '%s\n' 10.198.0.1 > "$fixture/current-gateway"
reason=disconnect "$fixture/wrapper.sh" "$fixture/upstream.sh" remote >/dev/null
[ ! -e "$fixture/host-route" ]
[ ! -e "$fixture/state/openconnectgui-${VPNPID}.env" ]

reason=connect "$fixture/wrapper.sh" "$fixture/upstream.sh" remote >/dev/null
[ "$(cat "$fixture/host-route")" = 10.198.0.1 ]
rm "$fixture/host-route"
VPNGATEWAY=127.0.0.1 reason=attempt-reconnect "$fixture/wrapper.sh" "$fixture/upstream.sh" remote >/dev/null
[ ! -e "$fixture/host-route" ]
VPNGATEWAY=::1 reason=attempt-reconnect "$fixture/wrapper.sh" "$fixture/upstream.sh" remote >/dev/null
[ ! -e "$fixture/host-route" ]
reason=attempt-reconnect "$fixture/wrapper.sh" "$fixture/upstream.sh" remote >/dev/null
[ "$(cat "$fixture/host-route")" = 10.198.0.1 ]

# A route through a gateway from a vanished network blocks the next connect entirely,
# so the helper prunes it before OpenConnect dials, without running the script.
printf '%s\n' 10.130.0.1 > "$fixture/host-route"
printf '%s\n' 192.168.1.254 > "$fixture/current-gateway"
rm -f "$fixture/state/openconnectgui-${VPNPID}.env"
reason=openconnectgui-prune "$fixture/wrapper.sh" "$fixture/upstream.sh" remote >/dev/null
[ ! -e "$fixture/host-route" ]
[ ! -e "$fixture/state/openconnectgui-${VPNPID}.env" ]

# A route through the gateway still in use is left alone.
printf '%s\n' 192.168.1.254 > "$fixture/host-route"
reason=openconnectgui-prune "$fixture/wrapper.sh" "$fixture/upstream.sh" remote >/dev/null
[ "$(cat "$fixture/host-route")" = 192.168.1.254 ]
rm "$fixture/host-route"

printf 'route regression test passed\n'
