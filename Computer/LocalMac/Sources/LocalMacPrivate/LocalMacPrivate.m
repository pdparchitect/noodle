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
#include <mach-o/dyld.h>
#include <crt_externs.h>

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
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawnattr_t attrs; posix_spawnattr_init(&attrs);
    posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT);
    posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0);
    posix_spawn_file_actions_adddup2(&actions, 0, 1);
    posix_spawn_file_actions_adddup2(&actions, 0, 2);
    posix_spawn_file_actions_addchdir(&actions, [home stringByAppendingPathComponent:@"workspace"].fileSystemRepresentation);
    char *arguments[] = {"/bin/zsh", "-l", "-i", NULL};
    NSString *user = NSUserName();
    NSArray *environment = @[[ @"HOME=" stringByAppendingString:home], [@"USER=" stringByAppendingString:user],
        [@"LOGNAME=" stringByAppendingString:user], @"SHELL=/bin/zsh", @"TERM=xterm-256color", @"PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", @"LANG=en_US.UTF-8"];
    char *env[8]; for (NSUInteger i = 0; i < environment.count; i++) env[i] = (char *)[environment[i] UTF8String]; env[7] = NULL;
    pid_t pid = -1;
    int result = posix_spawn(&pid, "/bin/zsh", &actions, &attrs, arguments, env);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attrs); close(slave);
    if (result) { close(master); return -1; }
    *masterFD = master; return pid;
}
static int removeContents(int fd, dev_t device, int depth) {
    if (depth > 128) return ELOOP;
    DIR *directory = fdopendir(dup(fd));
    if (!directory) return errno;
    int result = 0; struct dirent *entry;
    while ((entry = readdir(directory))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        struct stat info;
        if (fstatat(fd, entry->d_name, &info, AT_SYMLINK_NOFOLLOW)) { if (errno == ENOENT) continue; result = errno; break; }
        if (S_ISDIR(info.st_mode)) {
            int child = openat(fd, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (child < 0) { result = errno; break; }
            struct stat opened; fstat(child, &opened);
            if (opened.st_dev != device || opened.st_ino != info.st_ino) result = EXDEV;
            else result = removeContents(child, device, depth + 1);
            close(child);
            if (result) break;
            if (unlinkat(fd, entry->d_name, AT_REMOVEDIR)) { result = errno; break; }
        } else if (unlinkat(fd, entry->d_name, 0)) { result = errno; break; }
    }
    closedir(directory); return result;
}
int NLMRemoveHome(NSString *name, uid_t uid) {
    if (geteuid() != 0 || uid < 501 || ![name hasPrefix:@"noodle_"] || [name containsString:@"/"] || [name containsString:@".."] || name.length != 27) return EINVAL;
    int users = open("/Users", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (users < 0) return errno;
    int home = openat(users, name.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (home < 0) { int result = errno == ENOENT ? 0 : errno; close(users); return result; }
    struct stat info;
    int result = fstat(home, &info) ? errno : info.st_uid != uid ? EPERM : removeContents(home, info.st_dev, 0);
    close(home);
    if (!result && unlinkat(users, name.fileSystemRepresentation, AT_REMOVEDIR)) result = errno;
    close(users); return result;
}
