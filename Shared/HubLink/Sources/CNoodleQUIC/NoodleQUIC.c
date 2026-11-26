// msquic is Linux's and Windows's QUIC here; on Apple platforms the Hub uses Network.framework instead.
#if defined(__linux__) || defined(_WIN32)
#ifdef __linux__
#define _GNU_SOURCE
#endif
#include "NoodleQUIC.h"
#include "msquic/msquic.h"

#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <wchar.h>
#include "NoodleQUICWindows.h"
#include <bcrypt.h>
#else
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

static const QUIC_BUFFER alpn = {sizeof("noodle-hub/1") - 1, (uint8_t *)"noodle-hub/1"};
static const QUIC_API_TABLE *api;
static HQUIC registration;
static pthread_once_t loaded = PTHREAD_ONCE_INIT;
static char load_error[256];

#ifndef _WIN32
/// Exiting runs OpenSSL's cleanup, which frees its state while a connection may still be loading its
/// certificate on another thread, crashing on the way out. OpenSSL is told to leave it, before msquic
/// starts it; the process is ending, so nothing is lost.
static void keep_openssl_at_exit(void) {
    void *crypto = dlopen("libcrypto.so.3", RTLD_NOW | RTLD_LOCAL);
    if (!crypto) return;
    typedef int (*Init)(uint64_t, const void *);
    Init init = (Init)dlsym(crypto, "OPENSSL_init_crypto");
    // OPENSSL_INIT_NO_ATEXIT, from OpenSSL 3's crypto.h, which is not among this package's headers.
    if (init) init(0x00080000L, NULL);
}
#endif

static void load(void) {
    typedef QUIC_STATUS(QUIC_API * Open)(uint32_t, const void **);
#ifdef _WIN32
    // The OpenSSL msquic.dll ships beside the program and is loaded from there by its full path: System32's own
    // msquic.dll is the Schannel build, which cannot read the PEM certificates the link pins. What it loads in
    // turn comes from beside it and from System32, never the current folder.
    wchar_t path[MAX_PATH + 16];
    DWORD length = GetModuleFileNameW(NULL, path, MAX_PATH);
    wchar_t *separator = length > 0 && length < MAX_PATH ? wcsrchr(path, L'\\') : NULL;
    HMODULE library = NULL;
    if (separator && wcscpy_s(separator + 1, MAX_PATH + 16 - (size_t)(separator + 1 - path), L"msquic.dll") == 0) {
        library = LoadLibraryExW(path, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    }
    if (!library) {
        snprintf(load_error, sizeof load_error, "msquic.dll is missing beside this program (error %lu).", GetLastError());
        return;
    }
    Open open = (Open)(void *)GetProcAddress(library, "MsQuicOpenVersion");
#else
    keep_openssl_at_exit();
    void *library = dlopen("libmsquic.so.2", RTLD_NOW | RTLD_LOCAL);
    if (!library) library = dlopen("libmsquic.so", RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        snprintf(load_error, sizeof load_error, "msquic is not installed (%s).", dlerror());
        return;
    }
    Open open = (Open)dlsym(library, "MsQuicOpenVersion");
#endif
    const void *table = NULL;
    if (!open || QUIC_FAILED(open(QUIC_API_VERSION_2, &table))) {
        snprintf(load_error, sizeof load_error, "msquic could not be started.");
        return;
    }
    QUIC_REGISTRATION_CONFIG config = {"noodle", QUIC_EXECUTION_PROFILE_LOW_LATENCY};
    if (QUIC_FAILED(((const QUIC_API_TABLE *)table)->RegistrationOpen(&config, &registration))) {
        snprintf(load_error, sizeof load_error, "msquic could not be started.");
        return;
    }
    api = table;
}

static int ready(char *error, size_t error_length) {
    pthread_once(&loaded, load);
    if (!api && error) snprintf(error, error_length, "%s", load_error);
    return api != NULL;
}

static void wait_until(pthread_cond_t *condition, pthread_mutex_t *lock, struct timespec *deadline) {
    if (deadline) pthread_cond_timedwait(condition, lock, deadline);
    else pthread_cond_wait(condition, lock);
}

static struct timespec after(int milliseconds) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += milliseconds / 1000;
    deadline.tv_nsec += (long)(milliseconds % 1000) * 1000000;
    if (deadline.tv_nsec >= 1000000000) { deadline.tv_sec += 1; deadline.tv_nsec -= 1000000000; }
    return deadline;
}

// MARK: Streams

struct nq_stream {
    HQUIC handle;
    nq_listener *listener; // Nil for a client's stream.
    pthread_mutex_t lock;
    pthread_cond_t changed;
    atomic_int references;
    int closed;
    // What a client's stream has read and not handed over yet.
    uint8_t *buffer;
    size_t buffered;
    int finished, failed;
};

struct nq_connection {
    HQUIC handle;
    nq_listener *listener;
    nq_connection *next;
};

struct nq_listener {
    HQUIC handle, configuration;
    nq_callbacks callbacks;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    nq_connection *open;
    int closing;
    uint16_t port;
};

typedef struct {
    QUIC_BUFFER buffer;
    size_t length;
} send_block;

static nq_stream *stream_new(HQUIC handle, nq_listener *listener) {
    nq_stream *stream = calloc(1, sizeof *stream);
    stream->handle = handle;
    stream->listener = listener;
    pthread_mutexattr_t attributes;
    pthread_mutexattr_init(&attributes);
    // A shutdown can complete inside a call made while the lock is held.
    pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&stream->lock, &attributes);
    pthread_mutexattr_destroy(&attributes);
    pthread_cond_init(&stream->changed, NULL);
    atomic_init(&stream->references, 2); // msquic's and the caller's.
    return stream;
}

void nq_stream_retain(nq_stream *stream) { atomic_fetch_add(&stream->references, 1); }

void nq_stream_release(nq_stream *stream) {
    if (!stream || atomic_fetch_sub(&stream->references, 1) != 1) return;
    pthread_mutex_destroy(&stream->lock);
    pthread_cond_destroy(&stream->changed);
    free(stream->buffer);
    free(stream);
}

static QUIC_STATUS QUIC_API stream_callback(HQUIC handle, void *context, QUIC_STREAM_EVENT *event) {
    nq_stream *stream = context;
    nq_callbacks *callbacks = stream->listener ? &stream->listener->callbacks : NULL;
    switch (event->Type) {
    case QUIC_STREAM_EVENT_RECEIVE:
        for (uint32_t i = 0; i < event->RECEIVE.BufferCount; i++) {
            const QUIC_BUFFER *piece = &event->RECEIVE.Buffers[i];
            if (callbacks) {
                callbacks->received(callbacks->context, stream, piece->Buffer, piece->Length);
            } else {
                pthread_mutex_lock(&stream->lock);
                stream->buffer = realloc(stream->buffer, stream->buffered + piece->Length);
                memcpy(stream->buffer + stream->buffered, piece->Buffer, piece->Length);
                stream->buffered += piece->Length;
                pthread_cond_broadcast(&stream->changed);
                pthread_mutex_unlock(&stream->lock);
            }
        }
        break;
    case QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN:
        if (callbacks) {
            callbacks->peer_finished(callbacks->context, stream);
        } else {
            pthread_mutex_lock(&stream->lock);
            stream->finished = 1;
            pthread_cond_broadcast(&stream->changed);
            pthread_mutex_unlock(&stream->lock);
        }
        break;
    case QUIC_STREAM_EVENT_PEER_SEND_ABORTED:
        if (!callbacks) {
            pthread_mutex_lock(&stream->lock);
            stream->failed = 1;
            pthread_cond_broadcast(&stream->changed);
            pthread_mutex_unlock(&stream->lock);
        }
        break;
    case QUIC_STREAM_EVENT_SEND_COMPLETE: {
        send_block *block = event->SEND_COMPLETE.ClientContext;
        if (block) {
            if (callbacks) callbacks->sent(callbacks->context, stream, block->length);
            free(block);
        }
        break;
    }
    case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:
        pthread_mutex_lock(&stream->lock);
        stream->closed = 1;
        if (!stream->finished) stream->failed = 1;
        pthread_cond_broadcast(&stream->changed);
        pthread_mutex_unlock(&stream->lock);
        if (callbacks) callbacks->stream_closed(callbacks->context, stream);
        api->StreamClose(handle);
        nq_stream_release(stream);
        break;
    default:
        break;
    }
    return QUIC_STATUS_SUCCESS;
}

int nq_stream_send(nq_stream *stream, const uint8_t *bytes, size_t length, int finish) {
    pthread_mutex_lock(&stream->lock);
    int result = -1;
    if (!stream->closed) {
        if (length == 0 && finish) {
            result = QUIC_FAILED(api->StreamShutdown(stream->handle, QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL, 0)) ? -1 : 0;
        } else if (length > 0) {
            send_block *block = malloc(sizeof *block + length);
            block->buffer.Buffer = (uint8_t *)(block + 1);
            block->buffer.Length = (uint32_t)length;
            block->length = length;
            memcpy(block->buffer.Buffer, bytes, length);
            if (QUIC_FAILED(api->StreamSend(stream->handle, &block->buffer, 1, finish ? QUIC_SEND_FLAG_FIN : QUIC_SEND_FLAG_NONE, block))) {
                free(block);
            } else {
                result = 0;
            }
        } else {
            result = 0;
        }
    }
    pthread_mutex_unlock(&stream->lock);
    return result;
}

void nq_stream_reset(nq_stream *stream, uint64_t code) {
    pthread_mutex_lock(&stream->lock);
    if (!stream->closed) api->StreamShutdown(stream->handle, QUIC_STREAM_SHUTDOWN_FLAG_ABORT, code);
    pthread_mutex_unlock(&stream->lock);
}

// MARK: Listening

static void forget(nq_listener *listener, nq_connection *connection) {
    pthread_mutex_lock(&listener->lock);
    for (nq_connection **link = &listener->open; *link; link = &(*link)->next) {
        if (*link == connection) { *link = connection->next; break; }
    }
    pthread_cond_broadcast(&listener->changed);
    pthread_mutex_unlock(&listener->lock);
}

static QUIC_STATUS QUIC_API connection_callback(HQUIC handle, void *context, QUIC_CONNECTION_EVENT *event) {
    nq_connection *connection = context;
    nq_listener *listener = connection->listener;
    switch (event->Type) {
    case QUIC_CONNECTION_EVENT_PEER_CERTIFICATE_RECEIVED: {
        const QUIC_BUFFER *certificate = (const QUIC_BUFFER *)event->PEER_CERTIFICATE_RECEIVED.Certificate;
        int admitted = certificate && listener->callbacks.admit(listener->callbacks.context, connection, certificate->Buffer, certificate->Length);
        return admitted ? QUIC_STATUS_SUCCESS : QUIC_STATUS_BAD_CERTIFICATE;
    }
    case QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED: {
        nq_stream *stream = stream_new(event->PEER_STREAM_STARTED.Stream, listener);
        api->SetCallbackHandler(event->PEER_STREAM_STARTED.Stream, (void *)stream_callback, stream);
        listener->callbacks.stream_opened(listener->callbacks.context, connection, stream);
        break;
    }
    case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE:
        listener->callbacks.connection_closed(listener->callbacks.context, connection);
        api->ConnectionClose(handle);
        forget(listener, connection);
        free(connection);
        break;
    default:
        break;
    }
    return QUIC_STATUS_SUCCESS;
}

static QUIC_STATUS QUIC_API listener_callback(HQUIC handle, void *context, QUIC_LISTENER_EVENT *event) {
    nq_listener *listener = context;
    if (event->Type != QUIC_LISTENER_EVENT_NEW_CONNECTION) return QUIC_STATUS_SUCCESS;
    pthread_mutex_lock(&listener->lock);
    if (listener->closing) {
        pthread_mutex_unlock(&listener->lock);
        return QUIC_STATUS_CONNECTION_REFUSED;
    }
    nq_connection *connection = calloc(1, sizeof *connection);
    connection->handle = event->NEW_CONNECTION.Connection;
    connection->listener = listener;
    connection->next = listener->open;
    listener->open = connection;
    pthread_mutex_unlock(&listener->lock);
    api->SetCallbackHandler(connection->handle, (void *)connection_callback, connection);
    QUIC_STATUS status = api->ConnectionSetConfiguration(connection->handle, listener->configuration);
    if (QUIC_FAILED(status)) {
        forget(listener, connection);
        free(connection);
    }
    return status;
}

static HQUIC configuration(const char *certificate, const char *key, uint16_t idle_seconds, int client) {
    QUIC_SETTINGS settings = {0};
    settings.IdleTimeoutMs = (uint64_t)idle_seconds * 1000;
    settings.IsSet.IdleTimeoutMs = 1;
    // msquic gives streams back as they close, so this is how many may be open at once.
    settings.PeerBidiStreamCount = 1024;
    settings.IsSet.PeerBidiStreamCount = 1;
    HQUIC handle = NULL;
    if (QUIC_FAILED(api->ConfigurationOpen(registration, &alpn, 1, &settings, sizeof settings, NULL, &handle))) return NULL;
    QUIC_CERTIFICATE_FILE files = {key, certificate};
    QUIC_CREDENTIAL_CONFIG credential = {0};
    credential.Type = QUIC_CREDENTIAL_TYPE_CERTIFICATE_FILE;
    credential.CertificateFile = &files;
    // Peers are pinned by key, which the callbacks check; no chain is trusted.
    credential.Flags = QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION | QUIC_CREDENTIAL_FLAG_INDICATE_CERTIFICATE_RECEIVED |
                       QUIC_CREDENTIAL_FLAG_USE_PORTABLE_CERTIFICATES |
                       (client ? QUIC_CREDENTIAL_FLAG_CLIENT : QUIC_CREDENTIAL_FLAG_REQUIRE_CLIENT_AUTHENTICATION);
    if (QUIC_FAILED(api->ConfigurationLoadCredential(handle, &credential))) {
        api->ConfigurationClose(handle);
        return NULL;
    }
    return handle;
}

nq_listener *nq_listen(const char *certificate, const char *key, uint16_t port, uint16_t idle_seconds,
                       nq_callbacks callbacks, char *error, size_t error_length) {
    if (!ready(error, error_length)) return NULL;
    nq_listener *listener = calloc(1, sizeof *listener);
    listener->callbacks = callbacks;
    pthread_mutex_init(&listener->lock, NULL);
    pthread_cond_init(&listener->changed, NULL);
    listener->configuration = configuration(certificate, key, idle_seconds, 0);
    if (!listener->configuration) {
        snprintf(error, error_length, "The link certificate could not be loaded.");
        free(listener);
        return NULL;
    }
    QUIC_STATUS status = api->ListenerOpen(registration, listener_callback, listener, &listener->handle);
    QUIC_ADDR address = {0};
    QuicAddrSetFamily(&address, QUIC_ADDRESS_FAMILY_UNSPEC);
    QuicAddrSetPort(&address, port);
    if (QUIC_SUCCEEDED(status)) status = api->ListenerStart(listener->handle, &alpn, 1, &address);
    if (QUIC_FAILED(status)) {
#ifdef _WIN32
        snprintf(error, error_length, "Port %u could not be opened (0x%lx).", port, (unsigned long)status);
#else
        snprintf(error, error_length, "Port %u could not be opened (%s).", port, strerror((int)status));
#endif
        if (listener->handle) api->ListenerClose(listener->handle);
        api->ConfigurationClose(listener->configuration);
        free(listener);
        return NULL;
    }
    uint32_t size = sizeof address;
    if (QUIC_SUCCEEDED(api->GetParam(listener->handle, QUIC_PARAM_LISTENER_LOCAL_ADDRESS, &size, &address))) {
        listener->port = QuicAddrGetPort(&address);
    }
    return listener;
}

uint16_t nq_listener_port(nq_listener *listener) { return listener->port; }

void nq_listener_close(nq_listener *listener) {
    pthread_mutex_lock(&listener->lock);
    listener->closing = 1;
    pthread_mutex_unlock(&listener->lock);
    // Waits for the listener's own callbacks to end.
    api->ListenerClose(listener->handle);
    pthread_mutex_lock(&listener->lock);
    for (nq_connection *connection = listener->open; connection; connection = connection->next) {
        api->ConnectionShutdown(connection->handle, QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0);
    }
    while (listener->open) wait_until(&listener->changed, &listener->lock, NULL);
    pthread_mutex_unlock(&listener->lock);
    api->ConfigurationClose(listener->configuration);
    pthread_mutex_destroy(&listener->lock);
    pthread_cond_destroy(&listener->changed);
    free(listener);
}

// MARK: The client

struct nq_client {
    HQUIC handle, configuration;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    int connected, ending, closed, answered;
    nq_verify verify;
    void *context;
};

static QUIC_STATUS QUIC_API client_callback(HQUIC handle, void *context, QUIC_CONNECTION_EVENT *event) {
    nq_client *client = context;
    QUIC_STATUS status = QUIC_STATUS_SUCCESS;
    pthread_mutex_lock(&client->lock);
    switch (event->Type) {
    case QUIC_CONNECTION_EVENT_PEER_CERTIFICATE_RECEIVED: {
        // Whatever the server is, it answered; a server that is not the one wanted is refused here,
        // before anything is sent to it.
        client->answered = 1;
        const QUIC_BUFFER *certificate = (const QUIC_BUFFER *)event->PEER_CERTIFICATE_RECEIVED.Certificate;
        if (!certificate || !client->verify(client->context, certificate->Buffer, certificate->Length)) {
            status = QUIC_STATUS_BAD_CERTIFICATE;
        }
        break;
    }
    case QUIC_CONNECTION_EVENT_CONNECTED: client->connected = 1; break;
    case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT:
        // A handshake the server failed still means the server is there.
        if (event->SHUTDOWN_INITIATED_BY_TRANSPORT.Status != QUIC_STATUS_CONNECTION_IDLE &&
            event->SHUTDOWN_INITIATED_BY_TRANSPORT.Status != QUIC_STATUS_UNREACHABLE &&
            event->SHUTDOWN_INITIATED_BY_TRANSPORT.Status != QUIC_STATUS_CONNECTION_TIMEOUT) {
            client->answered = 1;
        }
        client->ending = 1;
        break;
    case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_PEER:
        client->answered = 1;
        client->ending = 1;
        break;
    case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE: client->ending = 1; client->closed = 1; break;
    default: break;
    }
    pthread_cond_broadcast(&client->changed);
    pthread_mutex_unlock(&client->lock);
    return status;
}

#ifdef _WIN32
/// `path`, given in UTF-8, as Windows's wide calls take it.
static int wide(const char *path, wchar_t *out, int capacity) {
    return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, out, capacity) > 0 ? 0 : -1;
}

/// Makes a new folder in this user's temporary folder, which only this user and administrators can open, and
/// puts its path in `folder` as UTF-8, which msquic's OpenSSL opens as such whatever the code page.
static int private_folder(char *folder, size_t capacity) {
    wchar_t temporary[MAX_PATH + 1], path[MAX_PATH + 64];
    DWORD length = GetTempPathW(MAX_PATH + 1, temporary);
    if (length == 0 || length > MAX_PATH) return -1;
    for (int attempt = 0; attempt < 16; attempt++) {
        unsigned char random[16];
        if (!BCRYPT_SUCCESS(BCryptGenRandom(NULL, random, sizeof random, BCRYPT_USE_SYSTEM_PREFERRED_RNG))) return -1;
        wchar_t name[2 * sizeof random + 1];
        for (size_t index = 0; index < sizeof random; index++) swprintf(name + 2 * index, 3, L"%02x", random[index]);
        swprintf(path, MAX_PATH + 64, L"%lsnoodle-link-%ls", temporary, name);
        // An existing name fails here, as with mkdtemp.
        if (CreateDirectoryW(path, NULL)) {
            return WideCharToMultiByte(CP_UTF8, 0, path, -1, folder, (int)capacity, NULL, NULL) > 0 ? 0 : -1;
        }
    }
    return -1;
}

/// Writes `text` to the new file `path`, failing if anything is there already.
static int write_private(const char *path, const char *text) {
    wchar_t name[MAX_PATH + 128];
    if (wide(path, name, MAX_PATH + 128) != 0) return -1;
    HANDLE file = CreateFileW(name, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_TEMPORARY, NULL);
    if (file == INVALID_HANDLE_VALUE) return -1;
    DWORD length = (DWORD)strlen(text), written = 0;
    BOOL wrote = WriteFile(file, text, length, &written, NULL);
    CloseHandle(file);
    return wrote && written == length ? 0 : -1;
}

static void remove_file(const char *path) {
    wchar_t name[MAX_PATH + 128];
    if (wide(path, name, MAX_PATH + 128) == 0) DeleteFileW(name);
}

static void remove_folder(const char *path) {
    wchar_t name[MAX_PATH + 128];
    if (wide(path, name, MAX_PATH + 128) == 0) RemoveDirectoryW(name);
}
#else
/// Makes a new folder only this user can open, in the temporary folder, and puts its path in `folder`.
static int private_folder(char *folder, size_t capacity) {
    const char *temporary = getenv("TMPDIR");
    snprintf(folder, capacity, "%s/noodle-link-XXXXXX", temporary && *temporary ? temporary : "/tmp");
    return mkdtemp(folder) ? 0 : -1;
}

/// Writes `text` to the new file `path` that only this user can read, failing if anything is there already.
static int write_private(const char *path, const char *text) {
    int file = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (file < 0) return -1;
    size_t length = strlen(text), written = 0;
    while (written < length) {
        ssize_t count = write(file, text + written, length - written);
        if (count <= 0) { close(file); return -1; }
        written += (size_t)count;
    }
    close(file);
    return 0;
}

static void remove_file(const char *path) { unlink(path); }

static void remove_folder(const char *path) { rmdir(path); }
#endif

/// msquic reads a certificate only from files. They are written to a folder only this user can open,
/// loaded, and removed at once, so the device's key stays on disk for no longer than that.
static HQUIC client_configuration(const char *certificate_pem, const char *key_pem) {
    char folder[1024];
    if (private_folder(folder, sizeof folder) != 0) return NULL;
    char certificate[1100], key[1100];
    snprintf(certificate, sizeof certificate, "%s/certificate.pem", folder);
    snprintf(key, sizeof key, "%s/key.pem", folder);
    HQUIC handle = NULL;
    if (write_private(certificate, certificate_pem) == 0 && write_private(key, key_pem) == 0) {
        handle = configuration(certificate, key, 30, 1);
    }
    remove_file(key);
    remove_file(certificate);
    remove_folder(folder);
    return handle;
}

nq_client *nq_connect(const char *host, uint16_t port, const char *certificate_pem, const char *key_pem,
                      nq_verify verify, void *context, int timeout_ms, int *answered, char *error, size_t error_length) {
    *answered = 0;
    if (!ready(error, error_length)) return NULL;
    nq_client *client = calloc(1, sizeof *client);
    pthread_mutex_init(&client->lock, NULL);
    pthread_cond_init(&client->changed, NULL);
    client->verify = verify;
    client->context = context;
    client->configuration = client_configuration(certificate_pem, key_pem);
    if (!client->configuration || QUIC_FAILED(api->ConnectionOpen(registration, client_callback, client, &client->handle)) ||
        QUIC_FAILED(api->ConnectionStart(client->handle, client->configuration, QUIC_ADDRESS_FAMILY_UNSPEC, host, port))) {
        snprintf(error, error_length, "The connection could not be started.");
        if (client->handle) api->ConnectionClose(client->handle);
        if (client->configuration) api->ConfigurationClose(client->configuration);
        free(client);
        return NULL;
    }
    struct timespec deadline = after(timeout_ms);
    pthread_mutex_lock(&client->lock);
    while (!client->connected && !client->ending) {
        if (pthread_cond_timedwait(&client->changed, &client->lock, &deadline) == ETIMEDOUT) break;
    }
    int connected = client->connected && !client->ending;
    *answered = client->answered;
    pthread_mutex_unlock(&client->lock);
    if (!connected) {
        snprintf(error, error_length, *answered ? "The Hub refused the connection." : "The Hub did not answer.");
        nq_client_close(client);
        return NULL;
    }
    return client;
}

int nq_client_is_closed(nq_client *client) {
    pthread_mutex_lock(&client->lock);
    int ending = client->ending;
    pthread_mutex_unlock(&client->lock);
    return ending;
}

nq_stream *nq_client_open(nq_client *client, const uint8_t *bytes, size_t length, int finish) {
    nq_stream *stream = stream_new(NULL, NULL);
    if (QUIC_FAILED(api->StreamOpen(client->handle, QUIC_STREAM_OPEN_FLAG_NONE, stream_callback, stream, &stream->handle)) ||
        QUIC_FAILED(api->StreamStart(stream->handle, QUIC_STREAM_START_FLAG_IMMEDIATE))) {
        if (stream->handle) api->StreamClose(stream->handle);
        atomic_store(&stream->references, 1);
        nq_stream_release(stream);
        return NULL;
    }
    nq_stream_send(stream, bytes, length, finish);
    return stream;
}

ptrdiff_t nq_client_read(nq_stream *stream, uint8_t *buffer, size_t capacity, int timeout_ms) {
    struct timespec deadline = after(timeout_ms);
    pthread_mutex_lock(&stream->lock);
    int timed_out = 0;
    while (stream->buffered == 0 && !stream->finished && !stream->failed) {
        if (pthread_cond_timedwait(&stream->changed, &stream->lock, &deadline) == ETIMEDOUT) { timed_out = 1; break; }
    }
    long result;
    if (stream->buffered > 0) {
        size_t count = stream->buffered < capacity ? stream->buffered : capacity;
        memcpy(buffer, stream->buffer, count);
        memmove(stream->buffer, stream->buffer + count, stream->buffered - count);
        stream->buffered -= count;
        result = (long)count;
    } else if (stream->finished) {
        result = 0;
    } else {
        result = timed_out && !stream->failed ? -2 : -1;
    }
    pthread_mutex_unlock(&stream->lock);
    return result;
}

void nq_client_close(nq_client *client) {
    api->ConnectionShutdown(client->handle, QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0);
    pthread_mutex_lock(&client->lock);
    struct timespec deadline = after(5000);
    while (!client->closed) {
        if (pthread_cond_timedwait(&client->changed, &client->lock, &deadline) == ETIMEDOUT) break;
    }
    pthread_mutex_unlock(&client->lock);
    api->ConnectionClose(client->handle);
    api->ConfigurationClose(client->configuration);
    pthread_mutex_destroy(&client->lock);
    pthread_cond_destroy(&client->changed);
    free(client);
}
#endif
