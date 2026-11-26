// The few POSIX threads and clock calls NoodleQUIC.c makes, over Windows's own. Windows's critical
// sections are recursive, as the streams' locks must be.
#ifndef NOODLE_QUIC_WINDOWS_H
#define NOODLE_QUIC_WINDOWS_H
#ifdef _WIN32

#include <windows.h>
#include <errno.h>
#include <time.h>

typedef CRITICAL_SECTION pthread_mutex_t;
typedef CONDITION_VARIABLE pthread_cond_t;
typedef int pthread_mutexattr_t;
typedef INIT_ONCE pthread_once_t;
#define PTHREAD_ONCE_INIT INIT_ONCE_STATIC_INIT
#define PTHREAD_MUTEX_RECURSIVE 1
#define CLOCK_REALTIME 0

static inline int pthread_mutexattr_init(pthread_mutexattr_t *attributes) { *attributes = 0; return 0; }
static inline int pthread_mutexattr_settype(pthread_mutexattr_t *attributes, int type) { *attributes = type; return 0; }
static inline int pthread_mutexattr_destroy(pthread_mutexattr_t *attributes) { (void)attributes; return 0; }
static inline int pthread_mutex_init(pthread_mutex_t *lock, const pthread_mutexattr_t *attributes) {
    (void)attributes;
    InitializeCriticalSection(lock);
    return 0;
}
static inline int pthread_mutex_destroy(pthread_mutex_t *lock) { DeleteCriticalSection(lock); return 0; }
static inline int pthread_mutex_lock(pthread_mutex_t *lock) { EnterCriticalSection(lock); return 0; }
static inline int pthread_mutex_unlock(pthread_mutex_t *lock) { LeaveCriticalSection(lock); return 0; }

static inline int pthread_cond_init(pthread_cond_t *condition, const void *attributes) {
    (void)attributes;
    InitializeConditionVariable(condition);
    return 0;
}
static inline int pthread_cond_destroy(pthread_cond_t *condition) { (void)condition; return 0; }
static inline int pthread_cond_broadcast(pthread_cond_t *condition) { WakeAllConditionVariable(condition); return 0; }
static inline int pthread_cond_wait(pthread_cond_t *condition, pthread_mutex_t *lock) {
    return SleepConditionVariableCS(condition, lock, INFINITE) ? 0 : EINVAL;
}

static inline int clock_gettime(int clock, struct timespec *now) {
    (void)clock;
    return timespec_get(now, TIME_UTC) == TIME_UTC ? 0 : -1;
}

/// Waits until `deadline`, a time on the realtime clock as POSIX takes it.
static inline int pthread_cond_timedwait(pthread_cond_t *condition, pthread_mutex_t *lock,
                                         const struct timespec *deadline) {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    long long remaining = (long long)(deadline->tv_sec - now.tv_sec) * 1000
        + (deadline->tv_nsec - now.tv_nsec) / 1000000;
    if (remaining <= 0) return ETIMEDOUT;
    if (SleepConditionVariableCS(condition, lock, (DWORD)remaining)) return 0;
    return GetLastError() == ERROR_TIMEOUT ? ETIMEDOUT : EINVAL;
}

static inline BOOL CALLBACK noodle_quic_once(PINIT_ONCE once, PVOID routine, PVOID *context) {
    (void)once;
    (void)context;
    ((void (*)(void))routine)();
    return TRUE;
}
static inline int pthread_once(pthread_once_t *once, void (*routine)(void)) {
    return InitOnceExecuteOnce(once, noodle_quic_once, (PVOID)routine, NULL) ? 0 : EINVAL;
}

#endif
#endif
