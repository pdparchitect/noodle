// A bot's harness in a sandbox of its own on Windows: a restricted copy of the server's own token, at low
// integrity, with Administrators for denying only and no privileges. Every file the harness opens must also
// grant a SID of the bot's own, so it reaches what Windows lets every user read (the system, Program Files)
// and the folders granted to it, but not other bots, the server's data or anyone's home; and it writes only
// where it is granted and labelled low, its workspace. It starts inside a job that ends everything in it when
// the server lets go of it, on a desktop of the server's own for bots.
//
// An AppContainer would be stricter still, but Windows refuses it the drive path of an open file, which
// Rust's standard library asks for whenever it resolves a path, so Codex cannot start in one.
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

// The bot's own SID, the same for the same name (64 characters at most). Returns a Win32 error, 0 on success;
// free the SID with sandbox_free_sid.
uint32_t sandbox_bot(const wchar_t *name, void **sid);
void sandbox_free_sid(void *sid);
// Lets the bot reach `path` and everything below it: read and run, or also change when `writable`, which also
// labels it low so a low-integrity process may write there.
uint32_t sandbox_grant(const wchar_t *path, void *sid, int writable);
// Starts `commandLine` as the bot. `environment` is a CREATE_UNICODE_ENVIRONMENT block.
uint32_t sandbox_spawn(void *sid, const wchar_t *application, wchar_t *commandLine, wchar_t *environment,
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
