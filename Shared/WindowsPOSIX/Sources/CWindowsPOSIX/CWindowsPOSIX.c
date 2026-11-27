#ifdef _WIN32
#define _CRT_RAND_S
#define WIN32_NO_STATUS
#include <windows.h>
#undef WIN32_NO_STATUS
#include <ntstatus.h>
#include <winternl.h>
#include <aclapi.h>
#include <tlhelp32.h>
#include <io.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <wchar.h>
#include "CWindowsPOSIX.h"

#ifndef FILE_OPEN_REPARSE_POINT
#define FILE_OPEN_REPARSE_POINT 0x00200000
#endif

// Win32 paths to NT ones, as CreateFileW makes them; exported by ntdll since Windows Vista.
NTSYSAPI NTSTATUS NTAPI RtlDosPathNameToNtPathName_U_WithStatus(PCWSTR dosName, PUNICODE_STRING ntName,
                                                                 PWSTR *filePart, PVOID relativeName);
NTSYSAPI NTSTATUS NTAPI NtSetInformationFile(HANDLE handle, PIO_STATUS_BLOCK io, PVOID information, ULONG length,
                                             FILE_INFORMATION_CLASS kind);
// FileRenameInformation and FileRenameInformationEx, which winternl.h does not name. Called directly, since
// SetFileInformationByHandle refuses a rename relative to a folder handle.
#define NOODLE_FILE_RENAME_INFORMATION ((FILE_INFORMATION_CLASS)10)
#define NOODLE_FILE_RENAME_INFORMATION_EX ((FILE_INFORMATION_CLASS)65)

// MARK: Errors

// The C runtime ends the process when a call such as close(-1) gets a descriptor that is not open; POSIX
// code expects -1 and EBADF, which it gives once this handler is in place.
static void ignore_invalid_parameter(const wchar_t *expression, const wchar_t *function, const wchar_t *file,
                                     unsigned int line, uintptr_t reserved) {
    (void)expression; (void)function; (void)file; (void)line; (void)reserved;
}

__attribute__((constructor)) static void install_invalid_parameter_handler(void) {
    _set_invalid_parameter_handler(ignore_invalid_parameter);
}

static int errno_from_win32(DWORD error) {
    switch (error) {
    case ERROR_FILE_NOT_FOUND: case ERROR_PATH_NOT_FOUND: case ERROR_INVALID_DRIVE: case ERROR_BAD_NETPATH:
    case ERROR_BAD_PATHNAME: case ERROR_DELETE_PENDING: return ENOENT;
    case ERROR_ACCESS_DENIED: case ERROR_SHARING_VIOLATION: case ERROR_PRIVILEGE_NOT_HELD: return EACCES;
    case ERROR_FILE_EXISTS: case ERROR_ALREADY_EXISTS: return EEXIST;
    case ERROR_LOCK_VIOLATION: case ERROR_IO_PENDING: return EWOULDBLOCK;
    case ERROR_DIR_NOT_EMPTY: return ENOTEMPTY;
    case ERROR_DIRECTORY: return ENOTDIR;
    case ERROR_NOT_SAME_DEVICE: return EXDEV;
    case ERROR_INVALID_NAME: case ERROR_INVALID_PARAMETER: return EINVAL;
    case ERROR_FILENAME_EXCED_RANGE: return ENAMETOOLONG;
    case ERROR_DISK_FULL: case ERROR_HANDLE_DISK_FULL: return ENOSPC;
    case ERROR_INVALID_HANDLE: return EBADF;
    case ERROR_NOT_ENOUGH_MEMORY: case ERROR_OUTOFMEMORY: return ENOMEM;
    case ERROR_CANT_RESOLVE_FILENAME: return ELOOP;
    default: return EIO;
    }
}

static int fail_win32(DWORD error) { errno = errno_from_win32(error); return -1; }

static int fail_nt(NTSTATUS status) {
    switch (status) {
    case STATUS_FILE_IS_A_DIRECTORY: errno = EISDIR; return -1;
    case STATUS_NOT_A_DIRECTORY: errno = ENOTDIR; return -1;
    case STATUS_OBJECT_NAME_COLLISION: errno = EEXIST; return -1;
    case STATUS_DELETE_PENDING: errno = ENOENT; return -1;
    case STATUS_STOPPED_ON_SYMLINK: errno = ELOOP; return -1;
    default: return fail_win32(RtlNtStatusToDosError(status));
    }
}

// MARK: Strings

static wchar_t *widen(const char *text) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (count <= 0) { errno = EINVAL; return NULL; }
    wchar_t *wide = malloc(sizeof(wchar_t) * (size_t)count);
    if (!wide) { errno = ENOMEM; return NULL; }
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, count);
    for (wchar_t *c = wide; *c; c++) if (*c == L'/') *c = L'\\';
    return wide;
}

static char *narrow(const wchar_t *wide, int length) {
    int count = WideCharToMultiByte(CP_UTF8, 0, wide, length, NULL, 0, NULL, NULL);
    char *text = malloc((size_t)count + 1);
    if (!text) { errno = ENOMEM; return NULL; }
    WideCharToMultiByte(CP_UTF8, 0, wide, length, text, count, NULL, NULL);
    text[count] = 0;
    return text;
}

// Foundation spells a drive path /C:/..., and Windows C:/...
static const char *drive_path(const char *path) {
    if (path[0] == '/' && path[1] && path[2] == ':') return path + 1;
    return path;
}

static BOOL is_absolute(const char *path) {
    path = drive_path(path);
    return path[0] == '/' || path[0] == '\\' || (path[0] && path[1] == ':');
}

// A name below a folder: no stream suffix, no climbing out, nothing absolute.
static BOOL is_safe_relative(const wchar_t *name) {
    if (name[0] == L'\\' || wcschr(name, L':')) return FALSE;
    const wchar_t *part = name;
    while (*part) {
        const wchar_t *end = wcschr(part, L'\\');
        size_t length = end ? (size_t)(end - part) : wcslen(part);
        if (length == 2 && part[0] == L'.' && part[1] == L'.') return FALSE;
        if (!end) break;
        part = end + 1;
    }
    return TRUE;
}

// MARK: Identity and access

static PSID current_user;
static PSID current_owner;
static BYTE system_sid[SECURITY_MAX_SID_SIZE];
static BYTE administrators_sid[SECURITY_MAX_SID_SIZE];
static BYTE creator_owner_sid[SECURITY_MAX_SID_SIZE];
static PACL private_acl;
static SECURITY_DESCRIPTOR private_descriptor;
static INIT_ONCE identity_once = INIT_ONCE_STATIC_INIT;

static void *token_information(HANDLE token, TOKEN_INFORMATION_CLASS kind) {
    DWORD size = 0;
    GetTokenInformation(token, kind, NULL, 0, &size);
    void *information = size ? malloc(size) : NULL;
    if (information && !GetTokenInformation(token, kind, information, size, &size)) { free(information); return NULL; }
    return information;
}

static BOOL CALLBACK load_identity(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    (void)once; (void)parameter; (void)context;
    HANDLE token;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return FALSE;
    TOKEN_USER *user = token_information(token, TokenUser);
    TOKEN_OWNER *owner = token_information(token, TokenOwner);
    CloseHandle(token);
    if (!user || !owner) return FALSE;
    current_user = user->User.Sid;
    current_owner = owner->Owner;
    DWORD size = SECURITY_MAX_SID_SIZE;
    CreateWellKnownSid(WinLocalSystemSid, NULL, system_sid, &size);
    size = SECURITY_MAX_SID_SIZE;
    CreateWellKnownSid(WinBuiltinAdministratorsSid, NULL, administrators_sid, &size);
    size = SECURITY_MAX_SID_SIZE;
    CreateWellKnownSid(WinCreatorOwnerSid, NULL, creator_owner_sid, &size);
    PSID granted[] = { current_user, (PSID)system_sid, (PSID)administrators_sid };
    DWORD aclSize = sizeof(ACL);
    for (int i = 0; i < 3; i++) aclSize += sizeof(ACCESS_ALLOWED_ACE) - sizeof(DWORD) + GetLengthSid(granted[i]);
    private_acl = malloc(aclSize);
    if (!private_acl || !InitializeAcl(private_acl, aclSize, ACL_REVISION)) return FALSE;
    for (int i = 0; i < 3; i++) {
        if (!AddAccessAllowedAceEx(private_acl, ACL_REVISION, OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE,
                                   FILE_ALL_ACCESS, granted[i])) return FALSE;
    }
    InitializeSecurityDescriptor(&private_descriptor, SECURITY_DESCRIPTOR_REVISION);
    SetSecurityDescriptorDacl(&private_descriptor, TRUE, private_acl, FALSE);
    SetSecurityDescriptorControl(&private_descriptor, SE_DACL_PROTECTED, SE_DACL_PROTECTED);
    return TRUE;
}

static BOOL identity(void) { return InitOnceExecuteOnce(&identity_once, load_identity, NULL, NULL); }

static BOOL is_private_mode(int mode) { return (mode & 077) == 0; }

static PSECURITY_DESCRIPTOR descriptor_for(int mode) {
    return is_private_mode(mode) && identity() ? &private_descriptor : NULL;
}

static HANDLE handle_of(int descriptor);
static BOOL is_trusted(PSID sid);
static NTSTATUS open_handle(int folder, const char *path, ACCESS_MASK access, ULONG disposition, ULONG options,
                            PSECURITY_DESCRIPTOR descriptor, HANDLE *handle);

// Whether everything the folder holding `path` lets in, or passes down, is trusted: then an owner-only item made
// there inherits, and so keeps what the folder passes down to a bot, instead of an ACL of its own that would cut
// it off.
static BOOL parent_is_private(int folder, const char *path) {
    if (!identity()) return FALSE;
    const char *slash = strrchr(path, '/'), *backslash = strrchr(path, '\\');
    const char *separator = slash > backslash ? slash : backslash;
    HANDLE parent = NULL;
    BOOL opened = FALSE;
    if (!separator && folder != AT_FDCWD) {
        parent = handle_of(folder);
    } else {
        size_t length = separator ? (size_t)(separator - path) : 0;
        char *name = malloc(length + 4);
        if (!name) return FALSE;
        if (separator) { memcpy(name, path, length); name[length] = 0; } else { name[0] = '.'; name[1] = 0; }
        if (length == 2 && name[1] == ':') { name[2] = '/'; name[3] = 0; }
        opened = NT_SUCCESS(open_handle(folder, name, READ_CONTROL, FILE_OPEN, 0, NULL, &parent));
        free(name);
        if (!opened) return FALSE;
    }
    PACL acl = NULL;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    BOOL trusted = parent && parent != INVALID_HANDLE_VALUE
        && GetSecurityInfo(parent, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, NULL, NULL, &acl, NULL, &descriptor) == ERROR_SUCCESS
        && acl != NULL;
    for (DWORD i = 0; trusted && i < acl->AceCount; i++) {
        ACE_HEADER *header;
        if (!GetAce(acl, i, (void **)&header) || header->AceType != ACCESS_ALLOWED_ACE_TYPE) continue;
        if (((ACCESS_ALLOWED_ACE *)header)->Mask && !is_trusted((PSID)&((ACCESS_ALLOWED_ACE *)header)->SidStart)) trusted = FALSE;
    }
    LocalFree(descriptor);
    if (opened) CloseHandle(parent);
    return trusted;
}

// The ACL a new item gets for `mode`: owner-only, unless the folder it is made in is that already.
static PSECURITY_DESCRIPTOR descriptor_for_new(int folder, const char *path, int mode) {
    if (!is_private_mode(mode) || parent_is_private(folder, path)) return NULL;
    return descriptor_for(mode);
}

void *noodle_private_security(void) { return identity() ? &private_descriptor : NULL; }

// This logon session's SID, which Noodle Server grants its bots' folders to. A bot works in the server's own folders,
// as on Linux, where it runs as the server's account; reaching them does not make them anyone else's.
static BOOL is_session_sid(PSID sid) {
    SID_IDENTIFIER_AUTHORITY *authority = GetSidIdentifierAuthority(sid);
    static const BYTE nt[6] = { 0, 0, 0, 0, 0, 5 };
    return authority && memcmp(authority->Value, nt, 6) == 0 && *GetSidSubAuthorityCount(sid) == 3
        && *GetSidSubAuthority(sid, 0) == SECURITY_LOGON_IDS_RID;
}

static BOOL is_trusted(PSID sid) {
    return EqualSid(sid, current_user) || EqualSid(sid, current_owner) || EqualSid(sid, (PSID)system_sid)
        || EqualSid(sid, (PSID)administrators_sid) || EqualSid(sid, (PSID)creator_owner_sid) || is_session_sid(sid);
}

// Owner and permission bits from an item's ACL: group and other bits appear when anyone beyond the owner,
// SYSTEM and Administrators may reach it.
static void apply_security(HANDLE handle, struct noodle_stat *status, BOOL directory) {
    int base = directory ? 0700 : 0600;
    status->st_uid = -2;
    status->st_mode |= base | 077;
    PSID owner = NULL;
    PACL acl = NULL;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    if (!identity() || GetSecurityInfo(handle, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                                       &owner, NULL, &acl, NULL, &descriptor) != ERROR_SUCCESS) return;
    if (owner && (EqualSid(owner, current_user) || EqualSid(owner, current_owner))) status->st_uid = 0;
    BOOL shared = acl == NULL;
    for (DWORD i = 0; acl && i < acl->AceCount && !shared; i++) {
        ACE_HEADER *header;
        if (!GetAce(acl, i, (void **)&header) || header->AceType != ACCESS_ALLOWED_ACE_TYPE) continue;
        if (header->AceFlags & INHERIT_ONLY_ACE) continue;
        ACCESS_ALLOWED_ACE *ace = (ACCESS_ALLOWED_ACE *)header;
        if (ace->Mask && !is_trusted((PSID)&ace->SidStart) && !(owner && EqualSid((PSID)&ace->SidStart, owner))) shared = TRUE;
    }
    if (!shared) status->st_mode = (status->st_mode & ~0777) | base;
    LocalFree(descriptor);
}

static int set_private(HANDLE handle, int mode) {
    DWORD result;
    if (is_private_mode(mode)) {
        if (!identity()) return fail_win32(GetLastError());
        result = SetSecurityInfo(handle, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                                 NULL, NULL, private_acl, NULL);
    } else {
        // Back to what the folder passes down.
        ACL empty;
        InitializeAcl(&empty, sizeof(empty), ACL_REVISION);
        result = SetSecurityInfo(handle, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION | UNPROTECTED_DACL_SECURITY_INFORMATION,
                                 NULL, NULL, &empty, NULL);
    }
    return result == ERROR_SUCCESS ? 0 : fail_win32(result);
}

// MARK: Opening

static HANDLE handle_of(int descriptor) { return (HANDLE)_get_osfhandle(descriptor); }
static char *final_path(HANDLE handle);

// Opens `path`, relative to the folder open as `folder` unless it is absolute or the folder is AT_FDCWD.
static NTSTATUS open_handle(int folder, const char *path, ACCESS_MASK access, ULONG disposition, ULONG options,
                            PSECURITY_DESCRIPTOR descriptor, HANDLE *handle) {
    UNICODE_STRING name;
    HANDLE root = NULL;
    BOOL converted = FALSE;
    wchar_t *wide = NULL;
    if (folder != AT_FDCWD && !is_absolute(path)) {
        root = handle_of(folder);
        if (root == INVALID_HANDLE_VALUE) return STATUS_INVALID_HANDLE;
        if (!(wide = widen(path))) return STATUS_OBJECT_NAME_INVALID;
        if (!is_safe_relative(wide)) { free(wide); return STATUS_OBJECT_NAME_INVALID; }
        // "." is the folder itself, which an empty name opens.
        if (wcscmp(wide, L".") == 0) wide[0] = 0;
        RtlInitUnicodeString(&name, wide);
    } else {
        if (!(wide = widen(drive_path(path)))) return STATUS_OBJECT_NAME_INVALID;
        NTSTATUS status = RtlDosPathNameToNtPathName_U_WithStatus(wide, &name, NULL, NULL);
        free(wide);
        wide = NULL;
        if (!NT_SUCCESS(status)) return status;
        converted = TRUE;
    }
    OBJECT_ATTRIBUTES attributes;
    InitializeObjectAttributes(&attributes, &name, OBJ_CASE_INSENSITIVE, root, descriptor);
    IO_STATUS_BLOCK io;
    NTSTATUS status = NtCreateFile(handle, access | SYNCHRONIZE, &attributes, &io, NULL, FILE_ATTRIBUTE_NORMAL,
                                   FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, disposition,
                                   options | FILE_SYNCHRONOUS_IO_NONALERT, NULL, 0);
    if (converted) RtlFreeUnicodeString(&name);
    free(wide);
    return status;
}

static BOOL is_link(HANDLE handle) {
    FILE_ATTRIBUTE_TAG_INFO tag;
    if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &tag, sizeof(tag))) return FALSE;
    return (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
        && (tag.ReparseTag == IO_REPARSE_TAG_SYMLINK || tag.ReparseTag == IO_REPARSE_TAG_MOUNT_POINT);
}

static BOOL is_directory(HANDLE handle) {
    FILE_BASIC_INFO basic;
    return GetFileInformationByHandleEx(handle, FileBasicInfo, &basic, sizeof(basic))
        && (basic.FileAttributes & FILE_ATTRIBUTE_DIRECTORY);
}

int noodle_openat(int folder, const char *path, int flags, int mode) {
    int accessMode = flags & (_O_RDONLY | _O_WRONLY | _O_RDWR);
    BOOL writes = accessMode == _O_WRONLY || accessMode == _O_RDWR;
    ACCESS_MASK access = READ_CONTROL | FILE_READ_ATTRIBUTES;
    if (accessMode == _O_RDONLY || accessMode == _O_RDWR) access |= FILE_GENERIC_READ;
    if (writes) access |= FILE_GENERIC_WRITE;
    if (flags & O_DIRECTORY) access |= FILE_LIST_DIRECTORY | FILE_TRAVERSE;
    // Truncation waits until the item is known not to be a link.
    ULONG disposition = (flags & _O_CREAT) ? ((flags & _O_EXCL) ? FILE_CREATE : FILE_OPEN_IF) : FILE_OPEN;
    ULONG options = 0;
    if (flags & O_NOFOLLOW) options |= FILE_OPEN_REPARSE_POINT;
    if (flags & O_DIRECTORY) options |= FILE_DIRECTORY_FILE;
    else if (writes) options |= FILE_NON_DIRECTORY_FILE;
    HANDLE handle;
    NTSTATUS status = open_handle(folder, path, access, disposition, options,
                                  (flags & _O_CREAT) ? descriptor_for_new(folder, path, mode) : NULL, &handle);
    if (!NT_SUCCESS(status)) return fail_nt(status);
    if ((flags & O_NOFOLLOW) && is_link(handle)) { CloseHandle(handle); errno = ELOOP; return -1; }
    if ((flags & _O_TRUNC) && writes) {
        FILE_END_OF_FILE_INFO end = { 0 };
        if (!SetFileInformationByHandle(handle, FileEndOfFileInfo, &end, sizeof(end))) {
            DWORD error = GetLastError();
            CloseHandle(handle);
            return fail_win32(error);
        }
    }
    int crtFlags = (accessMode == _O_RDONLY ? _O_RDONLY : 0) | (flags & _O_APPEND);
    int descriptor = _open_osfhandle((intptr_t)handle, crtFlags);
    if (descriptor < 0) { CloseHandle(handle); errno = EMFILE; return -1; }
    return descriptor;
}

int noodle_open(const char *path, int flags, int mode) { return noodle_openat(AT_FDCWD, path, flags, mode); }

// MARK: Status

static void timespec_from(LARGE_INTEGER time, struct timespec *out) {
    // 100-nanosecond intervals since 1601.
    long long intervals = time.QuadPart - 116444736000000000LL;
    out->tv_sec = (time_t)(intervals / 10000000LL);
    out->tv_nsec = (long)((intervals % 10000000LL) * 100);
    if (out->tv_nsec < 0) { out->tv_sec -= 1; out->tv_nsec += 1000000000L; }
}

static int status_of(HANDLE handle, struct noodle_stat *status) {
    memset(status, 0, sizeof(*status));
    DWORD type = GetFileType(handle);
    if (type == FILE_TYPE_PIPE) { status->st_mode = _S_IFIFO | 0600; status->st_nlink = 1; return 0; }
    if (type == FILE_TYPE_CHAR) { status->st_mode = _S_IFCHR | 0600; status->st_nlink = 1; return 0; }
    BY_HANDLE_FILE_INFORMATION information;
    FILE_BASIC_INFO basic;
    if (!GetFileInformationByHandle(handle, &information)
        || !GetFileInformationByHandleEx(handle, FileBasicInfo, &basic, sizeof(basic))) return fail_win32(GetLastError());
    BOOL directory = (information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    status->st_mode = is_link(handle) ? S_IFLNK : directory ? _S_IFDIR : _S_IFREG;
    status->st_dev = information.dwVolumeSerialNumber;
    status->st_ino = ((uint64_t)information.nFileIndexHigh << 32) | information.nFileIndexLow;
    status->st_nlink = (int32_t)information.nNumberOfLinks;
    status->st_size = ((int64_t)information.nFileSizeHigh << 32) | information.nFileSizeLow;
    timespec_from(basic.LastAccessTime, &status->st_atim);
    timespec_from(basic.LastWriteTime, &status->st_mtim);
    timespec_from(basic.ChangeTime, &status->st_ctim);
    apply_security(handle, status, directory);
    return 0;
}

int noodle_fstat(int descriptor, struct noodle_stat *status) {
    HANDLE handle = handle_of(descriptor);
    if (handle == INVALID_HANDLE_VALUE) { errno = EBADF; return -1; }
    return status_of(handle, status);
}

int noodle_fstatat(int folder, const char *path, struct noodle_stat *status, int flags) {
    HANDLE handle;
    NTSTATUS result = open_handle(folder, path, READ_CONTROL | FILE_READ_ATTRIBUTES, FILE_OPEN,
                                  (flags & AT_SYMLINK_NOFOLLOW) ? FILE_OPEN_REPARSE_POINT : 0, NULL, &handle);
    if (!NT_SUCCESS(result)) return fail_nt(result);
    int outcome = status_of(handle, status);
    CloseHandle(handle);
    return outcome;
}

// MARK: Changing

int noodle_unlinkat(int folder, const char *path, int flags) {
    HANDLE handle;
    NTSTATUS status = open_handle(folder, path, DELETE | FILE_READ_ATTRIBUTES, FILE_OPEN, FILE_OPEN_REPARSE_POINT, NULL, &handle);
    if (!NT_SUCCESS(status)) return fail_nt(status);
    // A link to a folder is removed like a file, as unlink(2) removes a symbolic link.
    BOOL folderItem = is_directory(handle) && !is_link(handle);
    if (folderItem && !(flags & AT_REMOVEDIR)) { CloseHandle(handle); errno = EISDIR; return -1; }
    if (!folderItem && (flags & AT_REMOVEDIR)) { CloseHandle(handle); errno = ENOTDIR; return -1; }
    // POSIX semantics: the name goes at once, even while the item is open elsewhere.
    FILE_DISPOSITION_INFO_EX disposition = {
        FILE_DISPOSITION_FLAG_DELETE | FILE_DISPOSITION_FLAG_POSIX_SEMANTICS | FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE
    };
    BOOL done = SetFileInformationByHandle(handle, FileDispositionInfoEx, &disposition, sizeof(disposition));
    if (!done && GetLastError() == ERROR_INVALID_PARAMETER) {
        FILE_DISPOSITION_INFO legacy = { TRUE };
        done = SetFileInformationByHandle(handle, FileDispositionInfo, &legacy, sizeof(legacy));
    }
    DWORD error = done ? 0 : GetLastError();
    CloseHandle(handle);
    return done ? 0 : fail_win32(error);
}

static int rename_item(int fromFolder, const char *from, int toFolder, const char *to, BOOL replace) {
    HANDLE handle;
    NTSTATUS status = open_handle(fromFolder, from, DELETE | FILE_READ_ATTRIBUTES, FILE_OPEN, FILE_OPEN_REPARSE_POINT, NULL, &handle);
    if (!NT_SUCCESS(status)) return fail_nt(status);
    HANDLE root = NULL;
    UNICODE_STRING converted = { 0 };
    wchar_t *wide = NULL;
    const wchar_t *target;
    if (toFolder != AT_FDCWD && !is_absolute(to)) {
        root = handle_of(toFolder);
        if (!(wide = widen(to)) || !is_safe_relative(wide)) { free(wide); CloseHandle(handle); errno = EINVAL; return -1; }
        target = wide;
    } else {
        if (!(wide = widen(drive_path(to)))) { CloseHandle(handle); return -1; }
        status = RtlDosPathNameToNtPathName_U_WithStatus(wide, &converted, NULL, NULL);
        free(wide);
        wide = NULL;
        if (!NT_SUCCESS(status)) { CloseHandle(handle); return fail_nt(status); }
        target = converted.Buffer;
    }
    DWORD nameBytes = (DWORD)(root ? wcslen(target) * sizeof(wchar_t) : converted.Length);
    DWORD size = (DWORD)(offsetof(FILE_RENAME_INFO, FileName) + nameBytes + sizeof(wchar_t));
    FILE_RENAME_INFO *information = calloc(1, size);
    BOOL done = FALSE;
    DWORD error = ERROR_NOT_ENOUGH_MEMORY;
    if (information) {
        information->Flags = FILE_RENAME_FLAG_POSIX_SEMANTICS | (replace ? FILE_RENAME_FLAG_REPLACE_IF_EXISTS : 0);
        information->RootDirectory = root;
        information->FileNameLength = nameBytes;
        memcpy(information->FileName, target, nameBytes);
        IO_STATUS_BLOCK io;
        status = NtSetInformationFile(handle, &io, information, size, NOODLE_FILE_RENAME_INFORMATION_EX);
        if (status == STATUS_INVALID_INFO_CLASS || status == STATUS_NOT_SUPPORTED || status == STATUS_INVALID_PARAMETER) {
            information->Flags = 0;
            information->ReplaceIfExists = (BOOLEAN)replace;
            status = NtSetInformationFile(handle, &io, information, size, NOODLE_FILE_RENAME_INFORMATION);
        }
        done = NT_SUCCESS(status);
        free(information);
    }
    if (converted.Buffer) RtlFreeUnicodeString(&converted);
    free(wide);
    CloseHandle(handle);
    if (!information) return fail_win32(error);
    return done ? 0 : fail_nt(status);
}

int noodle_renameat(int fromFolder, const char *from, int toFolder, const char *to) {
    return rename_item(fromFolder, from, toFolder, to, TRUE);
}

int noodle_renameat_exclusive(int fromFolder, const char *from, int toFolder, const char *to) {
    return rename_item(fromFolder, from, toFolder, to, FALSE);
}

int noodle_mkdirat(int folder, const char *path, int mode) {
    HANDLE handle;
    NTSTATUS status = open_handle(folder, path, FILE_LIST_DIRECTORY, FILE_CREATE, FILE_DIRECTORY_FILE,
                                  descriptor_for_new(folder, path, mode), &handle);
    if (!NT_SUCCESS(status)) return fail_nt(status);
    CloseHandle(handle);
    return 0;
}

int noodle_fchmod(int descriptor, int mode) {
    HANDLE handle = handle_of(descriptor);
    if (handle == INVALID_HANDLE_VALUE) { errno = EBADF; return -1; }
    HANDLE writable = ReOpenFile(handle, READ_CONTROL | WRITE_DAC, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                 FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT);
    if (writable == INVALID_HANDLE_VALUE) return fail_win32(GetLastError());
    int outcome = set_private(writable, mode);
    CloseHandle(writable);
    return outcome;
}

int noodle_fchmodat(int folder, const char *path, int mode) {
    HANDLE handle;
    NTSTATUS status = open_handle(folder, path, READ_CONTROL | WRITE_DAC, FILE_OPEN, 0, NULL, &handle);
    if (!NT_SUCCESS(status)) return fail_nt(status);
    int outcome = set_private(handle, mode);
    CloseHandle(handle);
    return outcome;
}

// MARK: Descriptors

// flock(2) is advisory, but Windows locks bytes for real; one byte far past any content stands for the
// whole file, so holding the lock never blocks reading or writing it.
int noodle_flock(int descriptor, int operation) {
    HANDLE handle = handle_of(descriptor);
    if (handle == INVALID_HANDLE_VALUE) { errno = EBADF; return -1; }
    OVERLAPPED place = { 0 };
    place.Offset = 0xFFFFFFFE;
    place.OffsetHigh = 0x7FFFFFFF;
    // As flock(2) converts a held lock, this one is let go first.
    UnlockFileEx(handle, 0, 1, 0, &place);
    if (operation & LOCK_UN) return 0;
    DWORD flags = ((operation & LOCK_EX) ? LOCKFILE_EXCLUSIVE_LOCK : 0) | ((operation & LOCK_NB) ? LOCKFILE_FAIL_IMMEDIATELY : 0);
    if (!LockFileEx(handle, flags, 0, 1, 0, &place)) return fail_win32(GetLastError());
    return 0;
}

// Unlike pread(2), this moves the descriptor's position, as Windows does for a synchronous handle.
long long noodle_pread(int descriptor, void *buffer, size_t count, long long offset) {
    HANDLE handle = handle_of(descriptor);
    if (handle == INVALID_HANDLE_VALUE) { errno = EBADF; return -1; }
    OVERLAPPED place = { 0 };
    place.Offset = (DWORD)offset;
    place.OffsetHigh = (DWORD)(offset >> 32);
    DWORD read = 0;
    if (!ReadFile(handle, buffer, count > 0x7FFFFFFF ? 0x7FFFFFFF : (DWORD)count, &read, &place)) {
        if (GetLastError() == ERROR_HANDLE_EOF) return 0;
        return fail_win32(GetLastError());
    }
    return read;
}

int noodle_fsync(int descriptor) {
    HANDLE handle = handle_of(descriptor);
    if (handle == INVALID_HANDLE_VALUE) { errno = EBADF; return -1; }
    return FlushFileBuffers(handle) ? 0 : fail_win32(GetLastError());
}

int noodle_ftruncate(int descriptor, long long length) {
    HANDLE handle = handle_of(descriptor);
    if (handle == INVALID_HANDLE_VALUE) { errno = EBADF; return -1; }
    FILE_END_OF_FILE_INFO end;
    end.EndOfFile.QuadPart = length;
    return SetFileInformationByHandle(handle, FileEndOfFileInfo, &end, sizeof(end)) ? 0 : fail_win32(GetLastError());
}

// MARK: Folders

struct noodle_dir {
    int descriptor;
    BOOL started;
    BOOL finished;
    BYTE *buffer;
    FILE_ID_BOTH_DIR_INFO *next;
    struct noodle_dirent entry;
};

noodle_DIR *noodle_fdopendir(int descriptor) {
    HANDLE handle = handle_of(descriptor);
    if (handle == INVALID_HANDLE_VALUE) { errno = EBADF; return NULL; }
    if (!is_directory(handle)) { errno = ENOTDIR; return NULL; }
    noodle_DIR *folder = calloc(1, sizeof(noodle_DIR));
    if (folder) folder->buffer = malloc(64 * 1024);
    if (!folder || !folder->buffer) { free(folder); errno = ENOMEM; return NULL; }
    folder->descriptor = descriptor;
    return folder;
}

struct noodle_dirent *noodle_readdir(noodle_DIR *folder) {
    if (!folder->next) {
        if (folder->finished) return NULL;
        FILE_INFO_BY_HANDLE_CLASS kind = folder->started ? FileIdBothDirectoryInfo : FileIdBothDirectoryRestartInfo;
        folder->started = TRUE;
        if (!GetFileInformationByHandleEx(handle_of(folder->descriptor), kind, folder->buffer, 64 * 1024)) {
            folder->finished = TRUE;
            if (GetLastError() != ERROR_NO_MORE_FILES) fail_win32(GetLastError());
            return NULL;
        }
        folder->next = (FILE_ID_BOTH_DIR_INFO *)folder->buffer;
    }
    FILE_ID_BOTH_DIR_INFO *item = folder->next;
    folder->next = item->NextEntryOffset ? (FILE_ID_BOTH_DIR_INFO *)((BYTE *)item + item->NextEntryOffset) : NULL;
    int length = WideCharToMultiByte(CP_UTF8, 0, item->FileName, (int)(item->FileNameLength / sizeof(wchar_t)),
                                     folder->entry.d_name, (int)sizeof(folder->entry.d_name) - 1, NULL, NULL);
    folder->entry.d_name[length > 0 ? length : 0] = 0;
    folder->entry.d_ino = (uint64_t)item->FileId.QuadPart;
    BOOL link = (item->FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
        && (item->EaSize == IO_REPARSE_TAG_SYMLINK || item->EaSize == IO_REPARSE_TAG_MOUNT_POINT);
    folder->entry.d_type = link ? 10 : (item->FileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 4 : 8;
    return &folder->entry;
}

void noodle_rewinddir(noodle_DIR *folder) {
    folder->started = FALSE;
    folder->finished = FALSE;
    folder->next = NULL;
}

int noodle_closedir(noodle_DIR *folder) {
    int outcome = _close(folder->descriptor);
    free(folder->buffer);
    free(folder);
    return outcome;
}

// MARK: Links

// REPARSE_DATA_BUFFER's symbolic link form, which only the driver kit's headers declare.
typedef struct {
    ULONG ReparseTag;
    USHORT ReparseDataLength;
    USHORT Reserved;
    USHORT SubstituteNameOffset;
    USHORT SubstituteNameLength;
    USHORT PrintNameOffset;
    USHORT PrintNameLength;
    ULONG Flags;
    WCHAR PathBuffer[1];
} symlink_reparse;
#define SYMLINK_RELATIVE 1

static void enable_symlink_privilege(void) {
    static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
    BOOL pending;
    if (!InitOnceBeginInitialize(&once, 0, &pending, NULL) || !pending) return;
    HANDLE token;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token)) {
        TOKEN_PRIVILEGES privileges = { 1 };
        if (LookupPrivilegeValueW(NULL, L"SeCreateSymbolicLinkPrivilege", &privileges.Privileges[0].Luid)) {
            privileges.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
            AdjustTokenPrivileges(token, FALSE, &privileges, 0, NULL, NULL);
        }
        CloseHandle(token);
    }
    InitOnceComplete(&once, 0, NULL);
}

// Whether the target, read from the link's folder, is a folder: Windows links say which they point at.
static BOOL target_is_folder(HANDLE folder, const wchar_t *target) {
    if ((target[0] && target[1] == L':') || target[0] == L'\\') {
        DWORD attributes = GetFileAttributesW(target);
        return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY);
    }
    char *base = final_path(folder);
    if (!base) return FALSE;
    wchar_t *wideBase = widen(base);
    free(base);
    if (!wideBase) return FALSE;
    size_t length = wcslen(wideBase) + wcslen(target) + 2;
    wchar_t *joined = malloc(sizeof(wchar_t) * length);
    BOOL isFolder = FALSE;
    if (joined) {
        swprintf(joined, length, L"%ls\\%ls", wideBase, target);
        DWORD attributes = GetFileAttributesW(joined);
        isFolder = attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY);
        free(joined);
    }
    free(wideBase);
    return isFolder;
}

int noodle_symlinkat(const char *target, int folder, const char *path) {
    HANDLE root = folder == AT_FDCWD ? NULL : handle_of(folder);
    wchar_t *print = NULL, *substitute = NULL;
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, target, -1, NULL, 0);
    if (count <= 1) { errno = EINVAL; return -1; }
    print = malloc(sizeof(wchar_t) * (size_t)count);
    substitute = widen(drive_path(target));
    if (!print || !substitute) { free(print); free(substitute); errno = ENOMEM; return -1; }
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, target, -1, print, count);
    BOOL relative = !is_absolute(target);
    BOOL isFolder = root ? target_is_folder(root, substitute) : FALSE;
    UNICODE_STRING converted = { 0 };
    const wchar_t *substituteName = substitute;
    USHORT substituteBytes = (USHORT)(wcslen(substitute) * sizeof(wchar_t));
    if (!relative) {
        NTSTATUS status = RtlDosPathNameToNtPathName_U_WithStatus(substitute, &converted, NULL, NULL);
        if (!NT_SUCCESS(status)) { free(print); free(substitute); return fail_nt(status); }
        substituteName = converted.Buffer;
        substituteBytes = converted.Length;
    }
    USHORT printBytes = (USHORT)(wcslen(print) * sizeof(wchar_t));
    DWORD size = (DWORD)(offsetof(symlink_reparse, PathBuffer) + substituteBytes + printBytes);
    symlink_reparse *reparse = calloc(1, size);
    int outcome = -1;
    if (reparse) {
        reparse->ReparseTag = IO_REPARSE_TAG_SYMLINK;
        reparse->ReparseDataLength = (USHORT)(size - offsetof(symlink_reparse, SubstituteNameOffset));
        reparse->SubstituteNameOffset = 0;
        reparse->SubstituteNameLength = substituteBytes;
        reparse->PrintNameOffset = substituteBytes;
        reparse->PrintNameLength = printBytes;
        reparse->Flags = relative ? SYMLINK_RELATIVE : 0;
        memcpy(reparse->PathBuffer, substituteName, substituteBytes);
        memcpy((BYTE *)reparse->PathBuffer + substituteBytes, print, printBytes);
        enable_symlink_privilege();
        HANDLE handle;
        NTSTATUS status = open_handle(folder, path, FILE_WRITE_ATTRIBUTES | FILE_READ_ATTRIBUTES | DELETE, FILE_CREATE,
                                      FILE_OPEN_REPARSE_POINT | (isFolder ? FILE_DIRECTORY_FILE : FILE_NON_DIRECTORY_FILE),
                                      NULL, &handle);
        if (!NT_SUCCESS(status)) {
            outcome = fail_nt(status);
        } else {
            DWORD returned;
            if (DeviceIoControl(handle, FSCTL_SET_REPARSE_POINT, reparse, size, NULL, 0, &returned, NULL)) {
                outcome = 0;
            } else {
                DWORD error = GetLastError();
                FILE_DISPOSITION_INFO removal = { TRUE };
                SetFileInformationByHandle(handle, FileDispositionInfo, &removal, sizeof(removal));
                outcome = fail_win32(error);
                // Without the right, Developer Mode still lets a path-based call make the link.
                if (error == ERROR_PRIVILEGE_NOT_HELD && root) {
                    char *base = final_path(root);
                    wchar_t *wideBase = base ? widen(base) : NULL;
                    wchar_t *name = widen(path);
                    free(base);
                    if (wideBase && name && is_safe_relative(name)) {
                        size_t length = wcslen(wideBase) + wcslen(name) + 2;
                        wchar_t *joined = malloc(sizeof(wchar_t) * length);
                        if (joined) {
                            swprintf(joined, length, L"%ls\\%ls", wideBase, name);
                            CloseHandle(handle);
                            handle = NULL;
                            DWORD flags = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE | (isFolder ? SYMBOLIC_LINK_FLAG_DIRECTORY : 0);
                            outcome = CreateSymbolicLinkW(joined, substitute, flags) ? 0 : fail_win32(GetLastError());
                            free(joined);
                        }
                    }
                    free(wideBase);
                    free(name);
                }
            }
            if (handle) CloseHandle(handle);
        }
        free(reparse);
    } else {
        errno = ENOMEM;
    }
    if (converted.Buffer) RtlFreeUnicodeString(&converted);
    free(print);
    free(substitute);
    return outcome;
}

long long noodle_readlinkat(int folder, const char *path, char *buffer, size_t size) {
    HANDLE handle;
    NTSTATUS status = open_handle(folder, path, FILE_READ_ATTRIBUTES, FILE_OPEN, FILE_OPEN_REPARSE_POINT, NULL, &handle);
    if (!NT_SUCCESS(status)) return fail_nt(status);
    BYTE data[MAXIMUM_REPARSE_DATA_BUFFER_SIZE];
    DWORD returned = 0;
    BOOL done = DeviceIoControl(handle, FSCTL_GET_REPARSE_POINT, NULL, 0, data, sizeof(data), &returned, NULL);
    DWORD error = done ? 0 : GetLastError();
    CloseHandle(handle);
    if (!done) { errno = error == ERROR_NOT_A_REPARSE_POINT ? EINVAL : errno_from_win32(error); return -1; }
    symlink_reparse *reparse = (symlink_reparse *)data;
    const wchar_t *name;
    USHORT bytes;
    if (reparse->ReparseTag == IO_REPARSE_TAG_SYMLINK) {
        name = (const wchar_t *)((BYTE *)reparse->PathBuffer + reparse->PrintNameOffset);
        bytes = reparse->PrintNameLength;
    } else if (reparse->ReparseTag == IO_REPARSE_TAG_MOUNT_POINT) {
        // A junction's buffer has no Flags field, so its names start four bytes earlier.
        BYTE *names = (BYTE *)&reparse->Flags;
        name = (const wchar_t *)(names + reparse->PrintNameOffset);
        bytes = reparse->PrintNameLength;
    } else {
        errno = EINVAL;
        return -1;
    }
    int length = WideCharToMultiByte(CP_UTF8, 0, name, bytes / (int)sizeof(wchar_t), buffer, (int)size, NULL, NULL);
    if (length <= 0 && bytes > 0) { errno = ENAMETOOLONG; return -1; }
    return length;
}

// MARK: Processes

static BOOL terminate(DWORD process, UINT code) {
    HANDLE handle = OpenProcess(PROCESS_TERMINATE, FALSE, process);
    if (!handle) return FALSE;
    BOOL done = TerminateProcess(handle, code);
    CloseHandle(handle);
    return done;
}

// Children first, found by parent number among processes started after their parent, so a reused number
// never pulls in a stranger.
static void terminate_children(DWORD parent, ULONGLONG parentStart, UINT code, int depth) {
    if (depth > 64) return;
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return;
    PROCESSENTRY32W entry = { sizeof(entry) };
    for (BOOL more = Process32FirstW(snapshot, &entry); more; more = Process32NextW(snapshot, &entry)) {
        if (entry.th32ParentProcessID != parent || entry.th32ProcessID == parent) continue;
        HANDLE child = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID);
        if (!child) continue;
        FILETIME created, exited, kernel, user;
        BOOL younger = GetProcessTimes(child, &created, &exited, &kernel, &user)
            && (((ULONGLONG)created.dwHighDateTime << 32) | created.dwLowDateTime) >= parentStart;
        ULONGLONG start = ((ULONGLONG)created.dwHighDateTime << 32) | created.dwLowDateTime;
        CloseHandle(child);
        if (!younger) continue;
        terminate_children(entry.th32ProcessID, start, code, depth + 1);
        terminate(entry.th32ProcessID, code);
    }
    CloseHandle(snapshot);
}

static BOOL running(DWORD process, ULONGLONG *start) {
    HANDLE handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process);
    if (!handle) { errno = GetLastError() == ERROR_ACCESS_DENIED ? EPERM : ESRCH; return FALSE; }
    DWORD code = 0;
    FILETIME created, exited, kernel, user;
    BOOL alive = GetExitCodeProcess(handle, &code) && code == STILL_ACTIVE;
    if (start && GetProcessTimes(handle, &created, &exited, &kernel, &user)) {
        *start = ((ULONGLONG)created.dwHighDateTime << 32) | created.dwLowDateTime;
    }
    CloseHandle(handle);
    if (!alive) errno = ESRCH;
    return alive;
}

int noodle_kill(int process, int signal) {
    if (process == 0 || process == -1) { errno = EINVAL; return -1; }
    DWORD target = (DWORD)(process < 0 ? -process : process);
    ULONGLONG start = 0;
    if (!running(target, &start)) return -1;
    if (signal == 0) return 0;
    UINT code = 128 + (UINT)signal;
    if (process < 0) terminate_children(target, start, code, 0);
    return terminate(target, code) ? 0 : fail_win32(GetLastError());
}

int noodle_getpgid(int process) { return running((DWORD)process, NULL) ? process : -1; }

int noodle_getpid(void) { return (int)GetCurrentProcessId(); }

int noodle_usleep(unsigned int microseconds) { Sleep((microseconds + 999) / 1000); return 0; }

int noodle_mkstemp(char *template_) {
    size_t length = strlen(template_);
    if (length < 6 || strcmp(template_ + length - 6, "XXXXXX") != 0) { errno = EINVAL; return -1; }
    static const char letters[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    for (int attempt = 0; attempt < 100; attempt++) {
        for (size_t i = length - 6; i < length; i++) {
            unsigned int random = 0;
            rand_s(&random);
            template_[i] = letters[random % (sizeof(letters) - 1)];
        }
        int descriptor = noodle_open(template_, _O_RDWR | _O_CREAT | _O_EXCL | O_NOFOLLOW, 0600);
        if (descriptor >= 0 || errno != EEXIST) return descriptor;
    }
    errno = EEXIST;
    return -1;
}

// MARK: Paths

static char *final_path(HANDLE handle) {
    DWORD count = GetFinalPathNameByHandleW(handle, NULL, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (!count) { fail_win32(GetLastError()); return NULL; }
    wchar_t *wide = malloc(sizeof(wchar_t) * (count + 1));
    if (!wide) { errno = ENOMEM; return NULL; }
    count = GetFinalPathNameByHandleW(handle, wide, count + 1, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    const wchar_t *start = wide;
    if (wcsncmp(start, L"\\\\?\\UNC\\", 8) == 0) { start += 6; wide[6] = L'\\'; }
    else if (wcsncmp(start, L"\\\\?\\", 4) == 0) start += 4;
    char *text = narrow(start, (int)wcslen(start));
    free(wide);
    for (char *c = text; text && *c; c++) if (*c == '\\') *c = '/';
    return text;
}

char *noodle_descriptor_path(int descriptor) {
    HANDLE handle = handle_of(descriptor);
    if (handle == INVALID_HANDLE_VALUE) { errno = EBADF; return NULL; }
    return final_path(handle);
}

char *noodle_realpath(const char *path) {
    HANDLE handle;
    NTSTATUS status = open_handle(AT_FDCWD, path, FILE_READ_ATTRIBUTES, FILE_OPEN, 0, NULL, &handle);
    if (!NT_SUCCESS(status)) { fail_nt(status); return NULL; }
    char *resolved = final_path(handle);
    CloseHandle(handle);
    return resolved;
}

#endif
