// QUIC for the Hub's link on Linux, over msquic, which is loaded when first used. Only what the link
// needs: a listener that admits devices by their certificate and hands their streams over, and a
// client that connects to a Hub it pins by key. Every callback comes on one of msquic's threads.
#ifndef NOODLE_QUIC_H
#define NOODLE_QUIC_H

#include <stddef.h>
#include <stdint.h>

typedef struct nq_listener nq_listener;
typedef struct nq_connection nq_connection;
/// A stream stays valid until `nq_stream_release`, after its `stream_closed` too; sending on a
/// closed one does nothing.
typedef struct nq_stream nq_stream;

typedef struct {
    void *context;
    /// The peer's certificate as DER. Nonzero lets the connection in.
    int (*admit)(void *context, nq_connection *connection, const uint8_t *certificate, size_t length);
    /// A stream the peer opened. The callee owns one reference to it.
    void (*stream_opened)(void *context, nq_connection *connection, nq_stream *stream);
    void (*received)(void *context, nq_stream *stream, const uint8_t *bytes, size_t length);
    void (*peer_finished)(void *context, nq_stream *stream);
    /// Bytes handed to `nq_stream_send` that have left, or were dropped with the stream.
    void (*sent)(void *context, nq_stream *stream, size_t length);
    void (*stream_closed)(void *context, nq_stream *stream);
    void (*connection_closed)(void *context, nq_connection *connection);
} nq_callbacks;

/// Nil, with why in `error`, when msquic is missing or the port cannot be opened. `certificate` and
/// `key` are PEM files.
nq_listener *nq_listen(const char *certificate, const char *key, uint16_t port, uint16_t idle_seconds,
                       nq_callbacks callbacks, char *error, size_t error_length);
uint16_t nq_listener_port(nq_listener *listener);
/// Stops taking connections and closes the ones open, then frees the listener.
void nq_listener_close(nq_listener *listener);

/// Queues a copy of `bytes`; `finish` ends this side of the stream after them. Zero on success.
int nq_stream_send(nq_stream *stream, const uint8_t *bytes, size_t length, int finish);
/// Ends the stream both ways at once, with an application error code.
void nq_stream_reset(nq_stream *stream, uint64_t code);
void nq_stream_retain(nq_stream *stream);
void nq_stream_release(nq_stream *stream);

// MARK: The client

typedef struct nq_client nq_client;
/// Says whether the server's certificate, as DER, is the one wanted; nonzero lets the handshake go on.
typedef int (*nq_verify)(void *context, const uint8_t *certificate, size_t length);
/// Connects with the device's certificate and key, as PEM, to a server `verify` accepts, waiting up
/// to `timeout_ms`. Nil with why in `error`; `answered` says whether the server answered at all.
nq_client *nq_connect(const char *host, uint16_t port, const char *certificate_pem, const char *key_pem,
                      nq_verify verify, void *context, int timeout_ms, int *answered, char *error, size_t error_length);
/// Whether the connection has ended or is ending, as when it was idle too long or the server closed it.
int nq_client_is_closed(nq_client *client);
/// Opens a stream and sends `bytes`, finishing the client's side when `finish` is set.
nq_stream *nq_client_open(nq_client *client, const uint8_t *bytes, size_t length, int finish);
/// Waits up to `timeout_ms` for bytes: how many came, 0 once the server finished, -1 when the stream
/// failed, and -2 when nothing came in time.
long nq_client_read(nq_stream *stream, uint8_t *buffer, size_t capacity, int timeout_ms);
void nq_client_close(nq_client *client);

#endif
