#import "LocalMacPrivate.h"
#include <dlfcn.h>
#include <libproc.h>
#include <unistd.h>
#include <spawn.h>
#include <util.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <mach-o/dyld.h>
#include <crt_externs.h>

CGRect NLMVisiblePixelBounds(const uint8_t *pixels, size_t width, size_t height, size_t bytesPerRow) {
    if (!width || !height || width > SIZE_MAX / 4 || bytesPerRow < width * 4 || height > SIZE_MAX / bytesPerRow) return CGRectNull;
    size_t left = width, top = height, right = 0, bottom = 0;
    for (size_t y = 0; y < height; y++) {
        const uint8_t *row = pixels + y * bytesPerRow;
        size_t x = 0;
        while (x < width && row[x * 4 + 3] == 0) x++;
        if (x == width) continue;
        if (x < left) left = x;
        if (y < top) top = y;
        bottom = y + 1;
        size_t end = width;
        while (end > x && row[(end - 1) * 4 + 3] == 0) end--;
        if (end > right) right = end;
    }
    return left == width ? CGRectNull : CGRectMake(left, top, right - left, bottom - top);
}

static void *library(void) {
    static void *handle; static dispatch_once_t once;
    dispatch_once(&once, ^{ handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LOCAL | RTLD_NOW); });
    return handle;
}
NSArray<NSDictionary *> *NLMCopySessions(void) {
    CFArrayRef (*copy)(void) = library() ? dlsym(library(), "SLSCopySessionList") : NULL;
    return copy ? CFBridgingRelease(copy()) : @[];
}
NSDictionary *NLMCopyCurrentSession(void) { return CFBridgingRelease(CGSessionCopyCurrentDictionary()) ?: @{}; }
int NLMCreateSession(NSData *payload, uint32_t *identifier) {
    int (*create)(const void *, long, unsigned int, uint32_t *, void *) = library() ? dlsym(library(), "SLSCreateLoginSessionWithDataAndVisibility") : NULL;
    if (geteuid() != 0 || !create) return -1;
    // ABI verified in the original macOS 26.6.2 investigation. Zero visibility
    // requests an off-console login; this does not enable Screen Sharing.
    return create(payload.bytes, (long)payload.length, 0, identifier, NULL);
}
BOOL NLMReleaseSession(uint32_t identifier) {
    void (*release)(uint32_t) = library() ? dlsym(library(), "SLSSessionReleaseSessionID") : NULL;
    if (geteuid() != 0 || !release || !identifier) return NO;
    release(identifier); return YES;
}
BOOL NLMPIDBelongsToUser(pid_t pid, uid_t uid) {
    struct proc_bsdinfo info = {0};
    return pid > 0 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) && info.pbi_uid == uid;
}
int NLMClaimDesktopResponsibility(NSString *executable, NSString *sessionPayload, BOOL reexecuted) {
    if (getuid() < 501 || geteuid() != getuid()) return EPERM;
    pid_t (*responsible)(pid_t) = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    int (*disclaim)(posix_spawnattr_t *, int) = dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    if (!responsible || !disclaim) return ENOSYS;
    if (reexecuted) return responsible(getpid()) == getpid() ? 0 : EPERM;
    const char *path = executable.fileSystemRepresentation;
    posix_spawnattr_t attrs;
    int result = posix_spawnattr_init(&attrs);
    if (result) return result;
    posix_spawn_file_actions_t actions;
    result = posix_spawn_file_actions_init(&actions);
    if (result) { posix_spawnattr_destroy(&attrs); return result; }
    // Keep the same PID, account, audit session and inherited desktop pipes.
    // This changes attribution only: the desktop app still needs its own grants.
    result = disclaim(&attrs, 1);
    if (!result) result = posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT);
    for (int fd = 0; fd < 3 && !result; fd++) result = posix_spawn_file_actions_addinherit_np(&actions, fd);
    char *arguments[] = { (char *)path, (char *)sessionPayload.UTF8String, "--own-responsibility", NULL };
    pid_t pid = -1;
    if (!result) result = posix_spawn(&pid, path, &actions, &attrs, arguments, *_NSGetEnviron());
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attrs);
    return result ?: EIO; // Successful SETEXEC never returns.
}
pid_t NLMSpawnTerminal(NSString *home, int *masterFD) {
    if (getuid() < 501 || geteuid() != getuid()) return -1;
    int master = -1, slave = -1; char name[1024];
    struct winsize size = { .ws_row = 24, .ws_col = 80 };
    if (openpty(&master, &slave, name, NULL, &size)) return -1;
    fcntl(master, F_SETFD, FD_CLOEXEC);
    NSString *workspace = [home stringByAppendingPathComponent:@"workspace"];
    const char *directory = workspace.fileSystemRepresentation;
    char *arguments[] = {"/bin/zsh", "-l", "-i", NULL};
    NSString *user = NSUserName();
    NSArray *environment = @[[ @"HOME=" stringByAppendingString:home], [@"USER=" stringByAppendingString:user],
        [@"LOGNAME=" stringByAppendingString:user], @"SHELL=/bin/zsh", @"TERM=xterm-256color", @"PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", @"LANG=en_US.UTF-8"];
    char *env[8]; for (NSUInteger i = 0; i < environment.count; i++) env[i] = (char *)[environment[i] UTF8String]; env[7] = NULL;
    // The shell must lead a session on its own terminal, as in Terminal: then the terminal sends
    // Control-C to the command in front, and says which command that is. posix_spawn cannot make
    // a terminal controlling, so fork. The exec pipe reports a failed start, and returning only
    // once it closes means the shell already owns its terminal.
    int exec[2];
    if (pipe(exec)) { close(master); close(slave); return -1; }
    fcntl(exec[0], F_SETFD, FD_CLOEXEC); fcntl(exec[1], F_SETFD, FD_CLOEXEC);
    int limit = getdtablesize();
    pid_t pid = fork();
    if (pid == 0) {
        // Only async-signal-safe calls until exec: the helper has other threads.
        if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0 || dup2(slave, 0) < 0 || dup2(slave, 1) < 0 || dup2(slave, 2) < 0
            || chdir(directory) < 0) {
            int code = errno; (void)write(exec[1], &code, sizeof code); _exit(127);
        }
        for (int fd = 3; fd < limit; fd++) if (fd != exec[1]) close(fd);
        execve("/bin/zsh", arguments, env);
        int code = errno; (void)write(exec[1], &code, sizeof code); _exit(127);
    }
    close(slave); close(exec[1]);
    if (pid < 0) { close(exec[0]); close(master); return -1; }
    int code = 0; ssize_t got;
    while ((got = read(exec[0], &code, sizeof code)) < 0 && errno == EINTR) {}
    close(exec[0]);
    if (got != 0) { int status; while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {} close(master); return -1; }
    *masterFD = master; return pid;
}
static BOOL removalFailure(NSError **error, int code, NSString *path, NSString *operation, BOOL preflight) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{
        @"LocalMacRemovalPath": path, @"LocalMacRemovalOperation": operation,
        @"LocalMacRemovalPreflight": @(preflight)
    }];
    return NO;
}
static BOOL sameEntry(int parent, const char *name, const struct stat *expected, NSString *path,
                      BOOL preflight, NSError **error) {
    struct stat current;
    if (fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW))
        return removalFailure(error, errno, path, @"inspect", preflight);
    if (current.st_dev != expected->st_dev || current.st_ino != expected->st_ino ||
        (current.st_mode & S_IFMT) != (expected->st_mode & S_IFMT))
        return removalFailure(error, ESTALE, path, @"identity", preflight);
    return YES;
}
static BOOL walkHome(int fd, dev_t device, int depth, NSString *path, BOOL preflight, NSError **error) {
    if (depth > 128) return removalFailure(error, ELOOP, path, @"depth", preflight);
    // A fresh open file description is required: dup() shares the directory
    // offset, which would make the deletion pass skip the preflight's entries.
    int iterator = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (iterator < 0) return removalFailure(error, errno, path, @"open", preflight);
    DIR *directory = fdopendir(iterator);
    if (!directory) { int code = errno; close(iterator); return removalFailure(error, code, path, @"read", preflight); }
    BOOL result = YES;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (!entry) {
            if (errno) result = removalFailure(error, errno, path, @"read", preflight);
            break;
        }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        NSString *childPath = [path stringByAppendingPathComponent:name];
        struct stat info;
        if (fstatat(fd, entry->d_name, &info, AT_SYMLINK_NOFOLLOW)) {
            if (errno == ENOENT) continue;
            result = removalFailure(error, errno, childPath, @"inspect", preflight); break;
        }
        if (info.st_dev != device) { result = removalFailure(error, EXDEV, childPath, @"boundary", preflight); break; }
        if (info.st_flags & (UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)) {
            result = removalFailure(error, EPERM, childPath, @"locked", preflight); break;
        }
        if (S_ISDIR(info.st_mode)) {
            int child = openat(fd, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (child < 0) { result = removalFailure(error, errno, childPath, @"open", preflight); break; }
            struct stat opened;
            if (fstat(child, &opened)) result = removalFailure(error, errno, childPath, @"inspect", preflight);
            else if (opened.st_dev != device || opened.st_ino != info.st_ino)
                result = removalFailure(error, ESTALE, childPath, @"identity", preflight);
            else result = walkHome(child, device, depth + 1, childPath, preflight, error);
            close(child);
            if (!result) break;
        }
        if (!preflight) {
            if (!sameEntry(fd, entry->d_name, &info, childPath, NO, error)) { result = NO; break; }
            if (unlinkat(fd, entry->d_name, S_ISDIR(info.st_mode) ? AT_REMOVEDIR : 0)) {
                result = removalFailure(error, errno, childPath, @"remove", NO); break;
            }
        }
    }
    closedir(directory); return result;
}
BOOL NLMRemoveManagedHomeAt(int parent, NSString *name, uid_t uid, NSError **error) {
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    if (uid < 501 || name.length != 27 || ![name hasPrefix:@"noodle_"] ||
        [[name substringFromIndex:7] rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound)
        return removalFailure(error, EINVAL, @"", @"identity", YES);
    int home = openat(parent, name.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (home < 0) {
        if (errno == ENOENT) return YES;
        return removalFailure(error, errno, @"", @"open", YES);
    }
    struct stat info, parentInfo;
    BOOL result;
    if (fstat(home, &info)) result = removalFailure(error, errno, @"", @"inspect", YES);
    else if (fstat(parent, &parentInfo)) result = removalFailure(error, errno, @"", @"inspect", YES);
    else if (info.st_dev != parentInfo.st_dev) result = removalFailure(error, EXDEV, @"", @"boundary", YES);
    else if (info.st_uid != uid) result = removalFailure(error, EPERM, @"", @"identity", YES);
    else if (info.st_flags & (UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND))
        result = removalFailure(error, EPERM, @"", @"locked", YES);
    // Discover protected folders before unlinking anything. This cannot promise
    // atomic deletion: permissions/content can change between the two passes.
    else result = walkHome(home, info.st_dev, 0, @"", YES, error) &&
                  sameEntry(parent, name.fileSystemRepresentation, &info, @"", YES, error) &&
                  walkHome(home, info.st_dev, 0, @"", NO, error);
    if (result) result = sameEntry(parent, name.fileSystemRepresentation, &info, @"", NO, error);
    if (result && unlinkat(parent, name.fileSystemRepresentation, AT_REMOVEDIR))
        result = removalFailure(error, errno, @"", @"remove", NO);
    close(home); return result;
}
BOOL NLMRemoveHome(NSString *name, uid_t uid, NSError **error) {
    if (geteuid() != 0) return removalFailure(error, EPERM, @"", @"identity", YES);
    int users = open("/Users", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (users < 0) return removalFailure(error, errno, @"", @"open", YES);
    BOOL result = NLMRemoveManagedHomeAt(users, name, uid, error);
    close(users); return result;
}

int NLMCreateSharedMemory(size_t size) {
    if (size == 0 || size > (size_t)OFF_MAX) { errno = EINVAL; return -1; }
    for (int attempt = 0; attempt < 8; attempt++) {
        char name[32];
        snprintf(name, sizeof name, "/nlm.%08x%08x", arc4random(), arc4random());
        // shm_open refuses O_CLOEXEC.
        int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
        if (fd < 0) { if (errno == EEXIST) continue; return -1; }
        shm_unlink(name);
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        if (ftruncate(fd, (off_t)size) != 0) { int error = errno; close(fd); errno = error; return -1; }
        return fd;
    }
    errno = EEXIST;
    return -1;
}

BOOL NLMIsSharedMemory(int fd, size_t size) {
    // POSIX shared memory reports no file type; files, pipes and sockets all do.
    struct stat info;
    return fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == 0 && info.st_size >= 0 && (size_t)info.st_size >= size;
}

int NLMSendAll(int socket, const void *bytes, size_t length, int descriptor) {
    const uint8_t *next = bytes;
    if (descriptor >= 0) {
        union { struct cmsghdr header; char space[CMSG_SPACE(sizeof(int))]; } control;
        memset(&control, 0, sizeof control);
        struct iovec part = { (void *)next, length };
        struct msghdr message = { .msg_iov = &part, .msg_iovlen = 1, .msg_control = control.space, .msg_controllen = sizeof control.space };
        struct cmsghdr *header = CMSG_FIRSTHDR(&message);
        header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS; header->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(header), &descriptor, sizeof(int));
        ssize_t sent;
        do { sent = sendmsg(socket, &message, 0); } while (sent < 0 && errno == EINTR);
        if (sent < 0) return errno;
        next += sent; length -= (size_t)sent;
    }
    while (length > 0) {
        ssize_t sent = write(socket, next, length);
        if (sent < 0) { if (errno == EINTR) continue; return errno; }
        next += sent; length -= (size_t)sent;
    }
    return 0;
}

ssize_t NLMReceive(int fd, void *buffer, size_t length, int *descriptors, int capacity, int *count) {
    union { struct cmsghdr header; char space[CMSG_SPACE(4 * sizeof(int))]; } control;
    struct iovec part = { buffer, length };
    struct msghdr message = { .msg_iov = &part, .msg_iovlen = 1, .msg_control = control.space, .msg_controllen = sizeof control.space };
    ssize_t received;
    do { received = recvmsg(fd, &message, 0); } while (received < 0 && errno == EINTR);
    if (received < 0 && errno == ENOTSOCK) {
        do { received = read(fd, buffer, length); } while (received < 0 && errno == EINTR);
        return received;
    }
    if (received < 0) return received;
    for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header; header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) continue;
        size_t found = (header->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        for (size_t index = 0; index < found; index++) {
            int descriptor;
            memcpy(&descriptor, CMSG_DATA(header) + index * sizeof(int), sizeof(int));
            if (*count < capacity) descriptors[(*count)++] = descriptor; else close(descriptor);
        }
    }
    return received;
}
