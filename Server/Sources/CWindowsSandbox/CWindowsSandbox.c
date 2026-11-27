#ifdef _WIN32
#include <windows.h>
#include <userenv.h>
#include <aclapi.h>
#include <sddl.h>
#include <stdlib.h>
#include "CWindowsSandbox.h"

static BOOL has_low_label(PACL sacl) {
    for (DWORD i = 0; sacl && i < sacl->AceCount; i++) {
        ACE_HEADER *header;
        if (!GetAce(sacl, i, (void **)&header) || header->AceType != SYSTEM_MANDATORY_LABEL_ACE_TYPE) continue;
        SYSTEM_MANDATORY_LABEL_ACE *label = (SYSTEM_MANDATORY_LABEL_ACE *)header;
        SID *level = (SID *)&label->SidStart;
        if (level->SubAuthority[0] == SECURITY_MANDATORY_LOW_RID && !(header->AceFlags & INHERITED_ACE)) return TRUE;
    }
    return FALSE;
}

uint32_t sandbox_writable(const wchar_t *path) {
    PACL sacl = NULL;
    PSECURITY_DESCRIPTOR labels = NULL;
    DWORD result = GetNamedSecurityInfoW(path, SE_FILE_OBJECT, LABEL_SECURITY_INFORMATION, NULL, NULL, NULL, &sacl, &labels);
    // Labelled before: labelling again would pass it down the folder's whole tree, slowly.
    if (result == ERROR_SUCCESS && !has_low_label(sacl)) {
        PSECURITY_DESCRIPTOR low = NULL;
        PACL lowSacl = NULL;
        BOOL present = FALSE, defaulted = FALSE;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(L"S:(ML;OICI;NW;;;LW)", SDDL_REVISION_1, &low, NULL)
            && GetSecurityDescriptorSacl(low, &present, &lowSacl, &defaulted)) {
            result = SetNamedSecurityInfoW((LPWSTR)path, SE_FILE_OBJECT, LABEL_SECURITY_INFORMATION, NULL, NULL, NULL, lowSacl);
        } else {
            result = GetLastError();
        }
        LocalFree(low);
    }
    LocalFree(labels);
    return result;
}

// The window station and desktop bots start on, made once and kept for as long as the server runs. A program
// that loads user32, as most do, needs one it may use; the server's own may not admit a restricted, low-integrity
// process, as under a service or SSH, and the person's desktop is no place for a bot.
static INIT_ONCE desktop_once = INIT_ONCE_STATIC_INIT;
static HWINSTA bots_station;
static HDESK bots_desktop;

static BOOL CALLBACK make_desktop(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    (void)once; (void)parameter; (void)context;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(A;;GA;;;WD)S:(ML;;NW;;;LW)", SDDL_REVISION_1, &descriptor, NULL)) {
        return FALSE;
    }
    SECURITY_ATTRIBUTES attributes = { sizeof(attributes), descriptor, FALSE };
    bots_station = CreateWindowStationW(L"NoodledBots", 0, WINSTA_ALL_ACCESS, &attributes);
    HWINSTA own = GetProcessWindowStation();
    if (bots_station && SetProcessWindowStation(bots_station)) {
        bots_desktop = CreateDesktopW(L"Bots", NULL, NULL, 0, GENERIC_ALL, &attributes);
        SetProcessWindowStation(own);
    }
    LocalFree(descriptor);
    return bots_station && bots_desktop;
}

// The server's token, restricted for a bot: Administrators for denying only, no privileges but passing through
// folders, and low integrity, so it writes only where a folder is labelled low. It still reads what the account can.
static DWORD bot_token(HANDLE *token) {
    HANDLE own;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY | TOKEN_ADJUST_DEFAULT, &own)) {
        return GetLastError();
    }
    BYTE administrators[SECURITY_MAX_SID_SIZE], localAdministrator[SECURITY_MAX_SID_SIZE], low[SECURITY_MAX_SID_SIZE];
    DWORD size = sizeof(administrators); CreateWellKnownSid(WinBuiltinAdministratorsSid, NULL, administrators, &size);
    size = sizeof(localAdministrator); CreateWellKnownSid(WinLocalAccountAndAdministratorSid, NULL, localAdministrator, &size);
    size = sizeof(low); CreateWellKnownSid(WinLowLabelSid, NULL, low, &size);
    SID_AND_ATTRIBUTES denied[] = { { (PSID)administrators, 0 }, { (PSID)localAdministrator, 0 } };
    DWORD error = 0;
    if (!CreateRestrictedToken(own, DISABLE_MAX_PRIVILEGE, 2, denied, 0, NULL, 0, NULL, token)) {
        error = GetLastError();
    } else {
        TOKEN_MANDATORY_LABEL label = { { (PSID)low, SE_GROUP_INTEGRITY } };
        if (!SetTokenInformation(*token, TokenIntegrityLevel, &label, sizeof(label) + GetLengthSid((PSID)low))) {
            error = GetLastError();
            CloseHandle(*token);
        }
    }
    CloseHandle(own);
    return error;
}

// Reads and drops what a bot's console draws, which nobody watches, so it never stops for want of a reader.
static DWORD WINAPI drain_console(LPVOID pipe) {
    char buffer[4096];
    DWORD read;
    while (ReadFile((HANDLE)pipe, buffer, sizeof(buffer), &read, NULL) && read > 0) {}
    CloseHandle((HANDLE)pipe);
    return 0;
}

// A console of the bot's own, run by Windows under the server's account. Without one, each console program the
// bot started would get a new console run as the bot, which a restricted, low-integrity process cannot start;
// and sharing the server's would let a bot send it Control-C.
static HRESULT make_console(HPCON *console, HANDLE *consoleInput) {
    HANDLE inputRead, inputWrite, outputRead, outputWrite;
    if (!CreatePipe(&inputRead, &inputWrite, NULL, 0)) return HRESULT_FROM_WIN32(GetLastError());
    if (!CreatePipe(&outputRead, &outputWrite, NULL, 0)) {
        DWORD error = GetLastError();
        CloseHandle(inputRead);
        CloseHandle(inputWrite);
        return HRESULT_FROM_WIN32(error);
    }
    COORD size = { 120, 40 };
    HRESULT result = CreatePseudoConsole(size, inputRead, outputWrite, 0, console);
    // The console keeps its own copies. Nothing is typed into it, but it ends everything in it once its input
    // closes, so the server holds that open until the bot ends.
    CloseHandle(inputRead);
    CloseHandle(outputWrite);
    if (SUCCEEDED(result)) *consoleInput = inputWrite; else CloseHandle(inputWrite);
    HANDLE drainer = SUCCEEDED(result) ? CreateThread(NULL, 0, drain_console, outputRead, 0, NULL) : NULL;
    if (drainer) CloseHandle(drainer); else CloseHandle(outputRead);
    return result;
}

void sandbox_close_console(void *console, void *consoleInput) {
    if (console) ClosePseudoConsole((HPCON)console);
    if (consoleInput) CloseHandle(consoleInput);
}

// One end of a pipe for the child, which inherits it, and the other for the server, which keeps it.
static BOOL make_pipe(HANDLE *childEnd, HANDLE *serverEnd, BOOL childReads) {
    SECURITY_ATTRIBUTES inherit = { sizeof(inherit), NULL, TRUE };
    HANDLE read, write;
    if (!CreatePipe(&read, &write, &inherit, 0)) return FALSE;
    *childEnd = childReads ? read : write;
    *serverEnd = childReads ? write : read;
    SetHandleInformation(*serverEnd, HANDLE_FLAG_INHERIT, 0);
    return TRUE;
}

uint32_t sandbox_spawn(const wchar_t *application, wchar_t *commandLine, wchar_t *environment,
                       const wchar_t *directory, struct sandbox_child *child) {
    DWORD error = 0;
    HANDLE childInput = NULL, childOutput = NULL, childErrors = NULL;
    HANDLE input = NULL, output = NULL, errors = NULL, job = NULL, token = NULL;
    HPCON console = NULL;
    HANDLE consoleInput = NULL;
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;

    if ((error = bot_token(&token)) != 0) { token = NULL; goto done; }
    if (!make_pipe(&childInput, &input, TRUE) || !make_pipe(&childOutput, &output, FALSE)
        || !make_pipe(&childErrors, &errors, FALSE)) { error = GetLastError(); goto done; }

    job = CreateJobObjectW(NULL, NULL);
    if (!job) { error = GetLastError(); goto done; }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = { 0 };
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) { error = GetLastError(); goto done; }

    HRESULT made = make_console(&console, &consoleInput);
    if (FAILED(made)) { console = NULL; error = HRESULT_CODE(made); goto done; }
    SIZE_T listSize = 0;
    InitializeProcThreadAttributeList(NULL, 3, 0, &listSize);
    attributes = malloc(listSize);
    if (!attributes || !InitializeProcThreadAttributeList(attributes, 3, 0, &listSize)) { error = ERROR_NOT_ENOUGH_MEMORY; goto done; }
    HANDLE inherited[] = { childInput, childOutput, childErrors };
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, sizeof(inherited), NULL, NULL)
        || !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST, &job, sizeof(job), NULL, NULL)
        || !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, console, sizeof(console), NULL, NULL)) {
        error = GetLastError();
        goto done;
    }

    if (!InitOnceExecuteOnce(&desktop_once, make_desktop, NULL, NULL)) { error = GetLastError(); goto done; }
    STARTUPINFOEXW startup = { 0 };
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.lpDesktop = L"NoodledBots\\Bots";
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = childInput;
    startup.StartupInfo.hStdOutput = childOutput;
    startup.StartupInfo.hStdError = childErrors;
    startup.lpAttributeList = attributes;
    PROCESS_INFORMATION process = { 0 };
    if (!CreateProcessAsUserW(token, application, commandLine, NULL, NULL, TRUE,
                              EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                              environment, directory, &startup.StartupInfo, &process)) {
        error = GetLastError();
        goto done;
    }
    CloseHandle(process.hThread);
    child->input = input;
    child->output = output;
    child->errors = errors;
    child->process = process.hProcess;
    child->job = job;
    child->console = console;
    child->consoleInput = consoleInput;
    child->identifier = process.dwProcessId;
    input = output = errors = job = NULL;
    console = NULL;
    consoleInput = NULL;

done:
    if (attributes) { DeleteProcThreadAttributeList(attributes); free(attributes); }
    // The child has its own copies now, and the server must not keep them, or the pipes never end.
    if (childInput) CloseHandle(childInput);
    if (childOutput) CloseHandle(childOutput);
    if (childErrors) CloseHandle(childErrors);
    if (input) CloseHandle(input);
    if (output) CloseHandle(output);
    if (errors) CloseHandle(errors);
    if (job) CloseHandle(job);
    if (token) CloseHandle(token);
    if (console) ClosePseudoConsole(console);
    if (consoleInput) CloseHandle(consoleInput);
    return error;
}

uint32_t sandbox_wait(void *process) {
    WaitForSingleObject(process, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(process, &code);
    return code;
}

void sandbox_end(void *job, uint32_t code) { if (job) TerminateJobObject(job, code); }

void sandbox_close(void *handle) { if (handle) CloseHandle(handle); }

long long sandbox_read(void *handle, void *buffer, uint32_t count) {
    DWORD read = 0;
    if (ReadFile(handle, buffer, count, &read, NULL)) return read;
    return GetLastError() == ERROR_BROKEN_PIPE ? 0 : -1;
}

long long sandbox_write(void *handle, const void *buffer, uint32_t count) {
    DWORD written = 0;
    return WriteFile(handle, buffer, count, &written, NULL) ? written : -1;
}
#endif
