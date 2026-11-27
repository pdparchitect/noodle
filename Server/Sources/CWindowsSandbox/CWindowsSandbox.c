#ifdef _WIN32
#include <windows.h>
#include <userenv.h>
#include <aclapi.h>
#include <sddl.h>
#include <stdlib.h>
#include "CWindowsSandbox.h"

uint32_t sandbox_container(const wchar_t *name, void **sid) {
    PSID created = NULL;
    HRESULT result = CreateAppContainerProfile(name, name, L"A Noodle Server bot", NULL, 0, &created);
    if (result == HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS)) result = DeriveAppContainerSidFromAppContainerName(name, &created);
    if (FAILED(result)) return HRESULT_CODE(result);
    *sid = created;
    return 0;
}

void sandbox_free_sid(void *sid) { if (sid) FreeSid(sid); }

uint32_t sandbox_grant(const wchar_t *path, void *sid, int writable) {
    PACL current = NULL, updated = NULL;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    DWORD result = GetNamedSecurityInfoW(path, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, NULL, NULL, &current, NULL, &descriptor);
    if (result != ERROR_SUCCESS) return result;
    DWORD wanted = writable ? FILE_ALL_ACCESS : (FILE_GENERIC_READ | FILE_GENERIC_EXECUTE);
    // Granted before: rewriting the folder's access would pass it down its whole tree again, slowly.
    for (DWORD i = 0; current && i < current->AceCount; i++) {
        ACCESS_ALLOWED_ACE *ace;
        if (!GetAce(current, i, (void **)&ace) || ace->Header.AceType != ACCESS_ALLOWED_ACE_TYPE) continue;
        BYTE inherits = OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE;
        if (EqualSid((PSID)&ace->SidStart, sid) && (ace->Mask & wanted) == wanted && (ace->Header.AceFlags & inherits) == inherits
            && !(ace->Header.AceFlags & INHERITED_ACE)) {
            LocalFree(descriptor);
            return ERROR_SUCCESS;
        }
    }
    EXPLICIT_ACCESS_W access = { 0 };
    access.grfAccessPermissions = wanted;
    access.grfAccessMode = GRANT_ACCESS;
    access.grfInheritance = OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE;
    access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
    access.Trustee.TrusteeType = TRUSTEE_IS_WELL_KNOWN_GROUP;
    access.Trustee.ptstrName = (LPWSTR)sid;
    result = SetEntriesInAclW(1, &access, current, &updated);
    if (result == ERROR_SUCCESS) {
        result = SetNamedSecurityInfoW((LPWSTR)path, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, NULL, NULL, updated, NULL);
    }
    LocalFree(updated);
    LocalFree(descriptor);
    return result;
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

uint32_t sandbox_spawn(void *sid, int lessPrivileged, const wchar_t *application, wchar_t *commandLine,
                       wchar_t *environment, const wchar_t *directory, struct sandbox_child *child) {
    DWORD error = 0;
    HANDLE childInput = NULL, childOutput = NULL, childErrors = NULL;
    HANDLE input = NULL, output = NULL, errors = NULL, job = NULL;
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
    BYTE internetClient[SECURITY_MAX_SID_SIZE];
    DWORD size = sizeof(internetClient);
    if (!CreateWellKnownSid(WinCapabilityInternetClientSid, NULL, internetClient, &size)) return GetLastError();
    SID_AND_ATTRIBUTES capability = { (PSID)internetClient, SE_GROUP_ENABLED };
    SECURITY_CAPABILITIES security = { (PSID)sid, &capability, 1, 0 };

    if (!make_pipe(&childInput, &input, TRUE) || !make_pipe(&childOutput, &output, FALSE)
        || !make_pipe(&childErrors, &errors, FALSE)) { error = GetLastError(); goto done; }

    job = CreateJobObjectW(NULL, NULL);
    if (!job) { error = GetLastError(); goto done; }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = { 0 };
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) { error = GetLastError(); goto done; }

    SIZE_T listSize = 0;
    InitializeProcThreadAttributeList(NULL, 4, 0, &listSize);
    attributes = malloc(listSize);
    if (!attributes || !InitializeProcThreadAttributeList(attributes, 4, 0, &listSize)) { error = ERROR_NOT_ENOUGH_MEMORY; goto done; }
    HANDLE inherited[] = { childInput, childOutput, childErrors };
    DWORD optOut = PROCESS_CREATION_ALL_APPLICATION_PACKAGES_OPT_OUT;
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &security, sizeof(security), NULL, NULL)
        || !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, sizeof(inherited), NULL, NULL)
        || !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST, &job, sizeof(job), NULL, NULL)
        || (lessPrivileged && !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_ALL_APPLICATION_PACKAGES_POLICY,
                                                         &optOut, sizeof(optOut), NULL, NULL))) {
        error = GetLastError();
        goto done;
    }

    STARTUPINFOEXW startup = { 0 };
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = childInput;
    startup.StartupInfo.hStdOutput = childOutput;
    startup.StartupInfo.hStdError = childErrors;
    startup.lpAttributeList = attributes;
    PROCESS_INFORMATION process = { 0 };
    if (!CreateProcessW(application, commandLine, NULL, NULL, TRUE,
                        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW,
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
    child->identifier = process.dwProcessId;
    input = output = errors = job = NULL;

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
