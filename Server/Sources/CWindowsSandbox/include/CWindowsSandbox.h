// A bot's harness sandboxed on Windows, for now less tightly than on Linux and a Mac: a restricted copy of the
// server's own token, with Administrators only denying, no privileges left and low integrity. It writes only in its
// workspace, labelled low, but reads what the server's account can, and bots are not kept from each other. It starts
// inside a job that ends everything in it when the server lets go of it, on a desktop and a console of the server's
// own for bots.
//
// What would keep a bot to its own folders does not yet let harnesses work: an AppContainer is refused the drive path
// of an open file, which Rust's standard library asks for, so Codex cannot start; restricting SIDs get no credentials
// from Windows's TLS; and denying the account keeps out its registry, without which PowerShell cannot start.
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
    // The bot's own console, which the console programs it runs share, and the end of its input the server
    // holds, since the console ends everything in it when that closes.
    void *console;
    void *consoleInput;
    uint32_t identifier;
};

// Lets bots write in `path` and everything below it, by labelling it low.
uint32_t sandbox_writable(const wchar_t *path);
// Starts `commandLine` as a bot. `environment` is a CREATE_UNICODE_ENVIRONMENT block.
uint32_t sandbox_spawn(const wchar_t *application, wchar_t *commandLine, wchar_t *environment,
                       const wchar_t *directory, struct sandbox_child *child);
// The exit code once the process has ended; waits for it.
uint32_t sandbox_wait(void *process);
// Ends everything in the job.
void sandbox_end(void *job, uint32_t code);
// Closes the bot's console and the end of its input the server holds.
void sandbox_close_console(void *console, void *consoleInput);
void sandbox_close(void *handle);
// Reads up to `count` bytes; 0 at the end, -1 on failure.
long long sandbox_read(void *handle, void *buffer, uint32_t count);
long long sandbox_write(void *handle, const void *buffer, uint32_t count);

#endif
#endif
