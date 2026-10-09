#include "NeptunePOSIX.h"
#include <sys/mman.h>
int noodle_neptune_shm_open(const char *name, int flags) {
    return shm_open(name, flags, 0600);
}
