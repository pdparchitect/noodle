#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
NS_ASSUME_NONNULL_BEGIN
/// Undocumented macOS session interfaces are confined to this module.
NSArray<NSDictionary *> *NLMCopySessions(void);
NSDictionary *NLMCopyCurrentSession(void);
int NLMCreateSession(NSData *payload, uint32_t *identifier);
BOOL NLMReleaseSession(uint32_t identifier);
BOOL NLMPIDBelongsToUser(pid_t pid, uid_t uid);
/// Re-exec this standard-user helper so TCC checks its own signed app identity.
/// Returns zero when already responsible for itself, or an errno on failure.
int NLMClaimDesktopResponsibility(NSString *executable, NSString *sessionPayload, BOOL reexecuted);
pid_t NLMSpawnTerminal(NSString *home, int *masterFD);
/// Remove the exact managed home through no-follow, directory-relative I/O.
BOOL NLMRemoveHome(NSString *name, uid_t uid, NSError * _Nullable * _Nullable error);
/// Descriptor-based implementation, also used by unprivileged temporary-home tests.
/// The lifecycle service supplies only /Users; this is not exposed over XPC.
BOOL NLMRemoveManagedHomeAt(int parent, NSString *name, uid_t uid, NSError * _Nullable * _Nullable error);
/// Bounds of nontransparent pixels in a top-left-origin BGRA buffer, or CGRectNull.
CGRect NLMVisiblePixelBounds(const uint8_t *pixels, size_t width, size_t height, size_t bytesPerRow);

// Frame memory and the descriptors that carry it, which Swift cannot reach directly.
/// An unnamed POSIX shared memory object of `size` bytes, or -1 with errno set.
int NLMCreateSharedMemory(size_t size);
/// Whether `fd` is a POSIX shared memory object of at least `size` bytes. Such an object
/// cannot be resized once sized, so a mapping of it can never fault.
BOOL NLMIsSharedMemory(int fd, size_t size);
/// Writes all `length` bytes; `descriptor`, unless -1, travels with the first of them.
/// Returns 0, or an errno on failure.
int NLMSendAll(int socket, const void *bytes, size_t length, int descriptor);
/// Reads up to `length` bytes, adding any descriptors that arrived with them to `descriptors`
/// (closing those beyond `capacity`). Falls back to read() when `fd` is not a socket.
ssize_t NLMReceive(int fd, void *buffer, size_t length, int *descriptors, int capacity, int *count);
NS_ASSUME_NONNULL_END
