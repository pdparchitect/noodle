// msquic is Linux's QUIC here; on Apple platforms the Hub uses Network.framework instead.
#ifdef __linux__
#define _GNU_SOURCE
#include "NoodleQUIC.h"
#include "msquic/msquic.h"

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>

static const QUIC_BUFFER alpn = {sizeof("noodle-hub/1") - 1, (uint8_t *)"noodle-hub/1"};
static const QUIC_API_TABLE *api;
static HQUIC registration;
static pthread_once_t loaded = PTHREAD_ONCE_INIT;
static char load_error[256];

static void load(void) {
    void *library = dlopen("libmsquic.so.2", RTLD_NOW | RTLD_LOCAL);
    if (!library) library = dlopen("libmsquic.so", RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        snprintf(load_error, sizeof load_error, "msquic is not installed (%s).", dlerror());
        return;
    }
    typedef QUIC_STATUS(QUIC_API * Open)(uint32_t, const void **);
    Open open = (Open)dlsym(library, "MsQuicOpenVersion");
    const void *table = NULL;
    if (!open || QUIC_FAILED(open(QUIC_API_VERSION_2, &table))) {
        snprintf(load_error, sizeof load_error, "msquic could not be started.");
        return;
    }
    QUIC_REGISTRATION_CONFIG config = {"noodled", QUIC_EXECUTION_PROFILE_LOW_LATENCY};
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
        snprintf(error, error_length, "Port %u could not be opened (%s).", port, strerror((int)status));
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

// MARK: The test client

struct nq_client {
    HQUIC handle, configuration;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    int connected, closed;
    uint8_t *peer;
    size_t peer_capacity, *peer_length;
};

static QUIC_STATUS QUIC_API client_callback(HQUIC handle, void *context, QUIC_CONNECTION_EVENT *event) {
    nq_client *client = context;
    pthread_mutex_lock(&client->lock);
    switch (event->Type) {
    case QUIC_CONNECTION_EVENT_PEER_CERTIFICATE_RECEIVED: {
        const QUIC_BUFFER *certificate = (const QUIC_BUFFER *)event->PEER_CERTIFICATE_RECEIVED.Certificate;
        if (certificate && client->peer && certificate->Length <= client->peer_capacity) {
            memcpy(client->peer, certificate->Buffer, certificate->Length);
            *client->peer_length = certificate->Length;
        }
        break;
    }
    case QUIC_CONNECTION_EVENT_CONNECTED: client->connected = 1; break;
    case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE: client->closed = 1; break;
    default: break;
    }
    pthread_cond_broadcast(&client->changed);
    pthread_mutex_unlock(&client->lock);
    return QUIC_STATUS_SUCCESS;
}

nq_client *nq_connect(const char *host, uint16_t port, const char *certificate, const char *key,
                      uint8_t *peer, size_t peer_capacity, size_t *peer_length, char *error, size_t error_length) {
    if (!ready(error, error_length)) return NULL;
    nq_client *client = calloc(1, sizeof *client);
    pthread_mutex_init(&client->lock, NULL);
    pthread_cond_init(&client->changed, NULL);
    client->peer = peer;
    client->peer_capacity = peer_capacity;
    client->peer_length = peer_length;
    client->configuration = configuration(certificate, key, 30, 1);
    if (!client->configuration || QUIC_FAILED(api->ConnectionOpen(registration, client_callback, client, &client->handle)) ||
        QUIC_FAILED(api->ConnectionStart(client->handle, client->configuration, QUIC_ADDRESS_FAMILY_UNSPEC, host, port))) {
        snprintf(error, error_length, "The connection could not be started.");
        if (client->handle) api->ConnectionClose(client->handle);
        if (client->configuration) api->ConfigurationClose(client->configuration);
        free(client);
        return NULL;
    }
    struct timespec deadline = after(5000);
    pthread_mutex_lock(&client->lock);
    while (!client->connected && !client->closed) {
        if (pthread_cond_timedwait(&client->changed, &client->lock, &deadline) == ETIMEDOUT) break;
    }
    int connected = client->connected && !client->closed;
    pthread_mutex_unlock(&client->lock);
    if (!connected) {
        snprintf(error, error_length, "The server did not let the connection in.");
        nq_client_close(client);
        return NULL;
    }
    return client;
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

long nq_client_read(nq_stream *stream, uint8_t *buffer, size_t capacity, int timeout_ms) {
    struct timespec deadline = after(timeout_ms);
    pthread_mutex_lock(&stream->lock);
    while (stream->buffered == 0 && !stream->finished && !stream->failed) {
        if (pthread_cond_timedwait(&stream->changed, &stream->lock, &deadline) == ETIMEDOUT) break;
    }
    long result;
    if (stream->buffered > 0) {
        size_t count = stream->buffered < capacity ? stream->buffered : capacity;
        memcpy(buffer, stream->buffer, count);
        memmove(stream->buffer, stream->buffer + count, stream->buffered - count);
        stream->buffered -= count;
        result = (long)count;
    } else {
        result = stream->finished ? 0 : -1;
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
