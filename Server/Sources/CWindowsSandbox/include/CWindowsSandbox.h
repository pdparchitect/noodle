// A bot's harness in an AppContainer on Windows. Each bot has a container of its own, which reaches what
// Windows lets every app read (the system, Program Files), the folders granted to it, and the internet, but
// not the local network, other bots, the server's data or anyone's home. The harness starts inside a job
// that ends everything in it when the server lets go of it.
#ifndef C_WINDOWS_SANDBOX_H
#define C_WINDOWS_SANDBOX_H
#ifdef _WIN32

#include <stdint.h>

struct sandbox_child {
    void *input;
    void *output;
    void *errors;
    void *process;
    void *job;
    uint32_t identifier;
};

// The container named `name` (64 characters at most), made when it is first asked for. Returns a Win32
// error, 0 on success; free the SID with sandbox_free_sid.
uint32_t sandbox_container(const wchar_t *name, void **sid);
void sandbox_free_sid(void *sid);
// Lets the container reach `path` and everything below it: read and run, or also change when `writable`.
uint32_t sandbox_grant(const wchar_t *path, void *sid, int writable);
// Starts `commandLine` in the container. `lessPrivileged` also takes away what Windows lets every app read,
// leaving only what is granted to restricted apps. `environment` is a CREATE_UNICODE_ENVIRONMENT block.
uint32_t sandbox_spawn(void *sid, int lessPrivileged, const wchar_t *application, wchar_t *commandLine,
                       wchar_t *environment, const wchar_t *directory, struct sandbox_child *child);
// The exit code once the process has ended; waits for it.
uint32_t sandbox_wait(void *process);
// Ends everything in the job.
void sandbox_end(void *job, uint32_t code);
void sandbox_close(void *handle);
// Reads up to `count` bytes; 0 at the end, -1 on failure.
long long sandbox_read(void *handle, void *buffer, uint32_t count);
long long sandbox_write(void *handle, const void *buffer, uint32_t count);

#endif
#endif
