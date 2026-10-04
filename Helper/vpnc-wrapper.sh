#!/bin/sh
umask 077
script=$1
dns_mode=$2
state="/var/run/vpnc/openconnectgui-${VPNPID}.env"

# vpnc-script removes the gateway host route using the *current* default gateway.
# After a network switch that may differ from the gateway used at connect time,
# leaving a static route to the VPN server through an unreachable old gateway.
stale_gateway_route() {
  [ -n "$VPNGATEWAY" ] || return 1
  case "$VPNGATEWAY" in *:*) return 1 ;; esac
  # route get can return a cached WASCLONED route even while netstat still
  # contains the explicit UGHS route created by vpnc-script.
  route_gateway=$(netstat -rn -f inet | awk -v endpoint="$VPNGATEWAY" \
    '$1 == endpoint && $3 ~ /H/ && $3 ~ /S/ { print $2; exit }')
  [ -n "$route_gateway" ] || return 1
  current_gateway=$(route -n get default 2>/dev/null | awk '$1 == "gateway:" { print $2; exit }')
  [ -n "$current_gateway" ] && [ "$route_gateway" != "$current_gateway" ]
}

case "$reason" in
  connect|reconnect)
    /bin/mkdir -p /var/run/vpnc
    if stale_gateway_route; then
      route -n delete -host "$VPNGATEWAY" || exit $?
    fi
    /usr/bin/env -0 > "$state"
    ;;
esac
if [ "$dns_mode" = local ]; then
  /usr/bin/env -u INTERNAL_IP4_DNS -u INTERNAL_IP6_DNS -u CISCO_DEF_DOMAIN "$script"
else
  "$script"
fi
result=$?
if [ "$result" -eq 0 ] && [ "$reason" = connect ]; then echo OPENCONNECTGUI_NETWORK_READY; fi
if [ "$reason" = disconnect ]; then
  # The upstream script can leave the route behind after the default gateway changes.
  # Only clean up an explicit host route when this process has a saved session.
  if [ -f "$state" ] && stale_gateway_route; then
    route -n delete -host "$VPNGATEWAY" || result=$?
  fi
  /bin/rm -f "$state"
fi
exit "$result"
