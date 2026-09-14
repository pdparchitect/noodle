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
int NLMRemoveHome(NSString *name, uid_t uid);
NS_ASSUME_NONNULL_END
