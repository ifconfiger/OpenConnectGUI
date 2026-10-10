#include "OpenConnectSession.h"

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <Security/Security.h>

struct ocs_session {
    struct openconnect_info *vpninfo;
    char *username;
    char *password;
    char *authgroup;
    ocs_log_fn log;
    ocs_reconnected_fn reconnected;
    void *context;
    pthread_mutex_t command_lock;
    int command_fd;
    int password_used;
    int authgroup_selected;
    int empty_forms;
    int auth_failed;
    int ignore_certificate_errors;
};

static void session_log(ocs_session *session, int level, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));

/* Look up a log format in the extension's string catalog; translations keep the
 * same conversions, which format_arg lets the compiler check at each call. */
static const char *L(const char *key) __attribute__((format_arg(1)));

static const char *L(const char *key)
{
    static _Thread_local char buffer[512];
    CFStringRef source = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    if (!source)
        return key;
    CFStringRef localized = CFBundleCopyLocalizedString(CFBundleGetMainBundle(), source, source, NULL);
    CFRelease(source);
    if (!localized)
        return key;
    Boolean copied = CFStringGetCString(localized, buffer, sizeof(buffer), kCFStringEncodingUTF8);
    CFRelease(localized);
    return copied ? buffer : key;
}

static void session_logv(ocs_session *session, int level, const char *fmt, va_list args)
{
    char message[1024];
    vsnprintf(message, sizeof(message), fmt, args);
    size_t length = strlen(message);
    while (length && (message[length - 1] == '\n' || message[length - 1] == '\r'))
        message[--length] = 0;
    if (length && session->log)
        session->log(session->context, level, message);
}

static void session_log(ocs_session *session, int level, const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    session_logv(session, level, fmt, args);
    va_end(args);
}

static void progress_cb(void *privdata, int level, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));

static void progress_cb(void *privdata, int level, const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    session_logv(privdata, level, fmt, args);
    va_end(args);
}

/* OpenSSL on iOS has no CA store, so every chain lands here; evaluate it with
 * the system trust store and the server's host name instead. */
static int validate_peer_cert_cb(void *privdata, const char *reason)
{
    ocs_session *session = privdata;
    struct oc_cert *chain = NULL;
    int count = openconnect_get_peer_cert_chain(session->vpninfo, &chain);
    if (count <= 0) {
        if (session->ignore_certificate_errors) {
            session_log(session, PRG_INFO, L("Ignored certificate error: %s"), reason);
            return 0;
        }
        session_log(session, PRG_ERR, L("Could not read the server certificate chain: %s"), reason);
        return -EINVAL;
    }

    CFMutableArrayRef certificates = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (int i = 0; i < count; i++) {
        CFDataRef data = CFDataCreate(NULL, chain[i].der_data, chain[i].der_len);
        SecCertificateRef certificate = data ? SecCertificateCreateWithData(NULL, data) : NULL;
        if (certificate) {
            CFArrayAppendValue(certificates, certificate);
            CFRelease(certificate);
        }
        if (data)
            CFRelease(data);
    }
    openconnect_free_peer_cert_chain(session->vpninfo, chain);

    /* get_hostname() returns the resolved address once connected. */
    const char *host = openconnect_get_dnsname(session->vpninfo);
    CFStringRef hostname = host ? CFStringCreateWithCString(NULL, host, kCFStringEncodingUTF8) : NULL;
    SecPolicyRef policy = SecPolicyCreateSSL(true, hostname);
    SecTrustRef trust = NULL;
    int result = -EINVAL;
    if (CFArrayGetCount(certificates) > 0 &&
        SecTrustCreateWithCertificates(certificates, policy, &trust) == errSecSuccess) {
        CFErrorRef error = NULL;
        if (SecTrustEvaluateWithError(trust, &error)) {
            result = 0;
        } else {
            CFStringRef description = error ? CFErrorCopyDescription(error) : NULL;
            char text[512] = "";
            if (description)
                CFStringGetCString(description, text, sizeof(text), kCFStringEncodingUTF8);
            if (session->ignore_certificate_errors) {
                session_log(session, PRG_INFO, L("Ignored certificate error: %s"), text[0] ? text : reason);
                result = 0;
            } else {
                session_log(session, PRG_ERR, L("Server certificate is not trusted: %s (you can choose to ignore certificate errors in the account settings)"),
                            text[0] ? text : reason);
            }
            if (description)
                CFRelease(description);
        }
        if (error)
            CFRelease(error);
        CFRelease(trust);
    }
    CFRelease(policy);
    if (hostname)
        CFRelease(hostname);
    CFRelease(certificates);
    return session->ignore_certificate_errors ? 0 : result;
}

static int match_choice(struct oc_form_opt_select *select, const char *wanted)
{
    for (int i = 0; i < select->nr_choices; i++) {
        struct oc_choice *choice = select->choices[i];
        if ((choice->name && !strcmp(choice->name, wanted)) ||
            (choice->label && !strcasecmp(choice->label, wanted))) {
            select->form._value = choice->name;
            return 0;
        }
    }
    return -1;
}

static int process_auth_form_cb(void *privdata, struct oc_auth_form *form)
{
    ocs_session *session = privdata;
    int empty = 1;

    if (form->error)
        session_log(session, PRG_ERR, "%s", form->error);
    if (form->message)
        session_log(session, PRG_INFO, "%s", form->message);

    if (form->authgroup_opt && session->authgroup[0]) {
        if (match_choice(form->authgroup_opt, session->authgroup)) {
            session_log(session, PRG_ERR, L("The server has no auth group named \"%s\"."), session->authgroup);
            session->auth_failed = 1;
            return OC_FORM_RESULT_CANCELLED;
        }
        if (!session->authgroup_selected) {
            session->authgroup_selected = 1;
            return OC_FORM_RESULT_NEWGROUP;
        }
    }

    for (struct oc_form_opt *opt = form->opts; opt; opt = opt->next) {
        if (opt->flags & OC_FORM_OPT_IGNORE)
            continue;
        switch (opt->type) {
        case OC_FORM_OPT_SELECT: {
            struct oc_form_opt_select *select = (struct oc_form_opt_select *)opt;
            if (select != form->authgroup_opt && !opt->_value && select->nr_choices > 0)
                opt->_value = select->choices[0]->name;
            break;
        }
        case OC_FORM_OPT_TEXT:
            if (strncasecmp(opt->name, "user", 4) && strncasecmp(opt->name, "uname", 5)) {
                session_log(session, PRG_ERR, L("The server asks for \"%s\"; cannot log in automatically."),
                            opt->label ? opt->label : opt->name);
                session->auth_failed = 1;
                return OC_FORM_RESULT_CANCELLED;
            }
            if (openconnect_set_option_value(opt, session->username))
                return OC_FORM_RESULT_ERR;
            empty = 0;
            break;
        case OC_FORM_OPT_PASSWORD:
            /* A second password prompt means the saved one was rejected or the
             * gateway wants a one-time code; neither can be answered here. */
            if (session->password_used) {
                session_log(session, PRG_ERR, L("The server asked for \"%s\" again; the saved password is invalid or two-factor authentication is required."),
                            opt->label ? opt->label : opt->name);
                session->auth_failed = 1;
                return OC_FORM_RESULT_CANCELLED;
            }
            if (openconnect_set_option_value(opt, session->password))
                return OC_FORM_RESULT_ERR;
            session->password_used = 1;
            empty = 0;
            break;
        case OC_FORM_OPT_TOKEN:
            empty = 0;
            break;
        default:
            break;
        }
    }

    if (!empty)
        session->empty_forms = 0;
    else if (++session->empty_forms >= 3) {
        session_log(session, PRG_ERR, L("The server kept returning empty login forms; it may require a certificate or web login."));
        session->auth_failed = 1;
        return OC_FORM_RESULT_CANCELLED;
    }
    return OC_FORM_RESULT_OK;
}

static void reconnected_cb(void *privdata)
{
    ocs_session *session = privdata;
    if (session->reconnected)
        session->reconnected(session->context);
}

static char *copy_string(const char *value)
{
    return strdup(value ? value : "");
}

ocs_session *ocs_session_new(const char *protocol, const char *username, const char *password,
                             const char *authgroup, int ignore_certificate_errors, ocs_log_fn log,
                             ocs_reconnected_fn reconnected, void *context)
{
    static pthread_once_t ssl_once = PTHREAD_ONCE_INIT;
    pthread_once(&ssl_once, (void (*)(void))openconnect_init_ssl);

    ocs_session *session = calloc(1, sizeof(*session));
    if (!session)
        return NULL;
    session->username = copy_string(username);
    session->password = copy_string(password);
    session->authgroup = copy_string(authgroup);
    session->ignore_certificate_errors = ignore_certificate_errors;
    session->log = log;
    session->reconnected = reconnected;
    session->context = context;
    session->command_fd = -1;
    pthread_mutex_init(&session->command_lock, NULL);

    session->vpninfo = openconnect_vpninfo_new("Open AnyConnect VPN Agent", validate_peer_cert_cb, NULL,
                                               process_auth_form_cb, progress_cb, session);
    if (!session->username || !session->password || !session->authgroup || !session->vpninfo ||
        openconnect_set_protocol(session->vpninfo, protocol)) {
        ocs_session_free(session);
        return NULL;
    }
    openconnect_set_loglevel(session->vpninfo, PRG_INFO);
    openconnect_set_reported_os(session->vpninfo, "apple-ios");
    openconnect_set_reconnected_handler(session->vpninfo, reconnected_cb);
    session->command_fd = openconnect_setup_cmd_pipe(session->vpninfo);
    return session;
}

void ocs_session_free(ocs_session *session)
{
    if (!session)
        return;
    pthread_mutex_lock(&session->command_lock);
    if (session->vpninfo)
        openconnect_vpninfo_free(session->vpninfo); /* also closes the command pipe */
    session->vpninfo = NULL;
    session->command_fd = -1;
    pthread_mutex_unlock(&session->command_lock);
    pthread_mutex_destroy(&session->command_lock);
    if (session->password) {
        memset(session->password, 0, strlen(session->password));
        free(session->password);
    }
    free(session->username);
    free(session->authgroup);
    free(session);
}

struct openconnect_info *ocs_session_vpninfo(ocs_session *session)
{
    return session->vpninfo;
}

int ocs_session_connect(ocs_session *session, const char *server)
{
    int ret = openconnect_parse_url(session->vpninfo, server);
    if (ret)
        return ret;
    ret = openconnect_obtain_cookie(session->vpninfo);
    if (ret) {
        /* Gateways such as ocserv answer a wrong password with HTTP 401
         * instead of another password form. */
        if (session->password_used)
            session->auth_failed = 1;
        return ret > 0 ? -ECANCELED : ret;
    }
    return openconnect_make_cstp_connection(session->vpninfo);
}

int ocs_session_auth_failed(ocs_session *session)
{
    return session->auth_failed;
}

void ocs_session_send_command(ocs_session *session, char command)
{
    pthread_mutex_lock(&session->command_lock);
    if (session->command_fd >= 0)
        (void)write(session->command_fd, &command, 1);
    pthread_mutex_unlock(&session->command_lock);
}
