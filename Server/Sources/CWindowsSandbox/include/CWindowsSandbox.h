// A bot's harness sandboxed on Windows, as far as Windows allows without an account for each bot: a restricted copy
// of the server's own token in which the server's account and Administrators only deny and no privileges are left,
// at low integrity. It reaches what Windows lets every user read (the system, Program Files) and the folders granted
// to the server's logon session, its workspace, package and installation, but nothing granted to the server's account
// alone, such as its home and the server's data; and it writes only in its workspace, labelled low. Bots are not kept
// from each other: they share the logon session their folders are granted to. The harness starts inside a job that
// ends everything in it when the server lets go of it, on a desktop and a console of the server's own for bots.
//
// What would keep bots apart does not let harnesses work: an AppContainer is refused the drive path of an open file,
// which Rust's standard library asks for whenever it resolves a path, so Codex cannot start in one; and a token with
// restricting SIDs gets no credentials from Windows's TLS, so no harness reaches its service.
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

// The SID bots' folders are granted to: the server's logon session's. Returns a Win32 error, 0 on success; free
// the SID with sandbox_free_sid.
uint32_t sandbox_bots(void **sid);
void sandbox_free_sid(void *sid);
// Lets bots reach `path` and everything below it: read and run, or also change when `writable`, which also labels
// it low so a low-integrity process may write there.
uint32_t sandbox_grant(const wchar_t *path, void *sid, int writable);
// Starts `commandLine` as a bot. `environment` is a CREATE_UNICODE_ENVIRONMENT block. `keepAccount`, for testing
// only, leaves the server's account in the token: the bot then reads everything the account can, its registry
// included, which PowerShell needs to start, and is held back only from writing outside its workspace.
uint32_t sandbox_spawn(const wchar_t *application, wchar_t *commandLine, wchar_t *environment,
                       const wchar_t *directory, int keepAccount, struct sandbox_child *child);
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
