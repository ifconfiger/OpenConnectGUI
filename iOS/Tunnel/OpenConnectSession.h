#ifndef OPENCONNECT_SESSION_H
#define OPENCONNECT_SESSION_H

#include <openconnect.h>

/* Thin C layer over libopenconnect for the packet tunnel. It answers the
 * authentication forms with saved credentials, validates the server against
 * the iOS trust store and turns libopenconnect's printf-style logging into
 * plain strings that Swift can consume. */

typedef struct ocs_session ocs_session;
typedef void (*ocs_log_fn)(void *context, int level, const char *message);
typedef void (*ocs_reconnected_fn)(void *context);

ocs_session *ocs_session_new(const char *protocol, const char *username, const char *password,
                             const char *authgroup, int ignore_certificate_errors, ocs_log_fn log,
                             ocs_reconnected_fn reconnected, void *context);
void ocs_session_free(ocs_session *session);
struct openconnect_info *ocs_session_vpninfo(ocs_session *session);

/* Authenticates and opens the CSTP connection. Returns 0 or a negative errno. */
int ocs_session_connect(ocs_session *session, const char *server);
/* Non-zero when the server rejected the saved credentials or asked for input
 * that cannot be answered without the user (for example a second factor). */
int ocs_session_auth_failed(ocs_session *session);
/* Thread-safe: queues an OC_CMD_* byte for the running connect or main loop. */
void ocs_session_send_command(ocs_session *session, char command);

#endif
