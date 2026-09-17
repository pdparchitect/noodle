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
NS_ASSUME_NONNULL_END
