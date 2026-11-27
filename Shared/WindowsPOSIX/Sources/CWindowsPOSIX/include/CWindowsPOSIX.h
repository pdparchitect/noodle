// POSIX file calls over Windows handles. A descriptor is the C runtime's, wrapping a Windows handle, so
// read, write and close work on it as usual. Where POSIX names a folder descriptor (openat and the like),
// the path is opened relative to that folder's handle by the kernel, so a link put in its place is never
// followed. Permissions are reduced to the one distinction the engine makes: a mode with no group or other
// bits (0600, 0700) gives a protected ACL for the owner, SYSTEM and Administrators alone; any other mode
// leaves what the folder passes down.
#ifndef C_WINDOWS_POSIX_H
#define C_WINDOWS_POSIX_H
#ifdef _WIN32

#include <stdint.h>
#include <stddef.h>
#include <time.h>

typedef int pid_t;
typedef int uid_t;
typedef int gid_t;
typedef int mode_t;

// Open flags the C runtime lacks, clear of its own _O_ bits.
#define O_NOFOLLOW 0x01000000
#define O_DIRECTORY 0x02000000
#define O_CLOEXEC 0x04000000
#define O_NONBLOCK 0x08000000

#define AT_FDCWD (-100)
#define AT_SYMLINK_NOFOLLOW 0x100
#define AT_REMOVEDIR 0x200

#define LOCK_SH 1
#define LOCK_EX 2
#define LOCK_NB 4
#define LOCK_UN 8

#define S_IFLNK 0120000
#define S_IRWXU 0700
#define S_IRUSR 0400
#define S_IWUSR 0200
#define S_IXUSR 0100
#define S_IRWXG 0070
#define S_IRGRP 0040
#define S_IWGRP 0020
#define S_IXGRP 0010
#define S_IRWXO 0007
#define S_IROTH 0004
#define S_IWOTH 0002
#define S_IXOTH 0001

#define PATH_MAX 4096

// Windows ends a process outright whatever the signal; these are the ones the engine sends.
#define SIGKILL 9

struct noodle_stat {
    uint64_t st_dev;
    uint64_t st_ino;
    int32_t st_mode;
    int32_t st_nlink;
    // 0 when the current user owns the item, as getuid() reports; -2 otherwise.
    int32_t st_uid;
    int32_t st_gid;
    int64_t st_size;
    struct timespec st_atim;
    struct timespec st_mtim;
    struct timespec st_ctim;
};

struct noodle_dirent {
    uint64_t d_ino;
    uint8_t d_type;
    char d_name[1024];
};

typedef struct noodle_dir noodle_DIR;

int noodle_open(const char *path, int flags, int mode);
int noodle_openat(int folder, const char *path, int flags, int mode);
int noodle_fstat(int descriptor, struct noodle_stat *status);
int noodle_fstatat(int folder, const char *path, struct noodle_stat *status, int flags);
int noodle_unlinkat(int folder, const char *path, int flags);
// Replaces what is at the target, as rename(2) does.
int noodle_renameat(int fromFolder, const char *from, int toFolder, const char *to);
// Fails with EEXIST when the target exists.
int noodle_renameat_exclusive(int fromFolder, const char *from, int toFolder, const char *to);
int noodle_mkdirat(int folder, const char *path, int mode);
int noodle_fchmod(int descriptor, int mode);
int noodle_fchmodat(int folder, const char *path, int mode);
int noodle_flock(int descriptor, int operation);
long long noodle_pread(int descriptor, void *buffer, size_t count, long long offset);
int noodle_fsync(int descriptor);
int noodle_ftruncate(int descriptor, long long length);
// Takes over the descriptor, as fdopendir(3) does.
noodle_DIR *noodle_fdopendir(int descriptor);
struct noodle_dirent *noodle_readdir(noodle_DIR *folder);
int noodle_closedir(noodle_DIR *folder);
void noodle_rewinddir(noodle_DIR *folder);
// A symbolic link below a folder. The target is kept as given, and readlinkat returns it unchanged. Needs
// the right to create symbolic links, or Developer Mode.
int noodle_symlinkat(const char *target, int folder, const char *path);
long long noodle_readlinkat(int folder, const char *path, char *buffer, size_t size);
// Ends the process, or with a negative number the process and everything it started, with exit code
// 128 + signal; signal 0 only checks it is running.
int noodle_kill(int process, int signal);
// Windows has no process groups: a process stands for its own, so this is the process's number when it runs.
int noodle_getpgid(int process);
int noodle_getpid(void);
int noodle_usleep(unsigned int microseconds);
int noodle_mkstemp(char *template_);
// The security descriptor that 0600 and 0700 stand for: the current user, SYSTEM and Administrators alone.
// For other objects only this process's account should reach, such as a named pipe.
void *noodle_private_security(void);
// The full path of what a descriptor has open, in UTF-8 with forward slashes; free() it.
char *noodle_descriptor_path(int descriptor);
// The canonical path of an existing item, links resolved; free() it.
char *noodle_realpath(const char *path);

#endif
#endif
