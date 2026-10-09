// Run against the Neptune renderer without a guest or graphics device. A second
// blob creation is a synchronous protocol barrier; no sleeps or polling are used.
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include "virglrenderer.h"
#include "neptune/npt_transport_defs.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL: %s at %d\n", #x, __LINE__); exit(1); } } while (0)

typedef int (*create_at_fn)(const struct virgl_renderer_resource_create_blob_args *, void *);
static create_at_fn create_at;
static uint64_t retired_fence;
static void retire(void *cookie, uint32_t context, uint32_t ring, uint64_t fence) {
    (void)cookie;
    CHECK(context == 1 && ring == 0);
    retired_fence = fence;
}

static void submit(uint32_t ctx, void *cmd, size_t size) {
    CHECK(virgl_renderer_submit_cmd(cmd, ctx, (int)(size / 4)) == 0);
}

static void write_from_context(uint32_t ctx, uint32_t resource, uint32_t value) {
    struct npt_cmd_create_ring create = {
        .header = { .cmd_type = NPT_TRANSPORT_CMD_TYPE(NPT_TRANSPORT_SUBGROUP_RING, NPT_TRANSPORT_RING_CREATE), .cmd_size = sizeof(create) },
        .ring_id = ctx + resource * 16, .res_id = resource, .head_offset = 0, .tail_offset = 4,
        .status_offset = 8, .buffer_offset = 64, .buffer_size = 1024,
        .extra_offset = 2048, .extra_size = 64, .idle_timeout = 0,
    };
    submit(ctx, &create, sizeof(create));
    struct npt_cmd_write_ring_extra write = {
        .header = { .cmd_type = NPT_TRANSPORT_CMD_TYPE(NPT_TRANSPORT_SUBGROUP_RING, NPT_TRANSPORT_RING_WRITE_EXTRA), .cmd_size = sizeof(write) },
        .ring_id = ctx + resource * 16, .offset = 0, .value = value,
    };
    submit(ctx, &write, sizeof(write));
    struct npt_cmd_destroy_ring destroy = {
        .header = { .cmd_type = NPT_TRANSPORT_CMD_TYPE(NPT_TRANSPORT_SUBGROUP_RING, NPT_TRANSPORT_RING_DESTROY), .cmd_size = sizeof(destroy) },
        .ring_id = ctx + resource * 16,
    };
    submit(ctx, &destroy, sizeof(destroy));
    struct virgl_renderer_resource_create_blob_args barrier = {
        .res_handle = 100 + ctx, .ctx_id = ctx, .blob_mem = VIRGL_RENDERER_BLOB_MEM_HOST3D,
        .blob_flags = VIRGL_RENDERER_BLOB_FLAG_USE_MAPPABLE, .size = 4096,
    };
    CHECK(virgl_renderer_resource_create_blob(&barrier) == 0);
    virgl_renderer_resource_unref(barrier.res_handle);
}

int main(void) {
    setbuf(stdout, NULL);
    struct virgl_renderer_callbacks callbacks = { .version = 3, .write_context_fence = retire };
    int cookie;
    // The old app requested ASYNC_FENCE_CB without THREAD_SYNC. This reproduces
    // the first real guest submit waiting forever, without sleeps or a guest.
    const int async = getenv("NEPTUNE_TEST_ASYNC_FENCES") ? VIRGL_RENDERER_ASYNC_FENCE_CB : 0;
    CHECK(virgl_renderer_init(&cookie, VIRGL_RENDERER_NO_VIRGL | VIRGL_RENDERER_RENDER_SERVER | VIRGL_RENDERER_NEPTUNE | async, &callbacks) == 0);
    create_at = (create_at_fn)dlsym(RTLD_DEFAULT, "virgl_renderer_resource_create_blob_at");
    void *arena = mmap(NULL, 65536, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    CHECK(arena != MAP_FAILED);
    unsigned char *slice = (unsigned char *)arena + 4096;
    for (uint32_t ctx = 1; ctx <= 2; ctx++)
        CHECK(virgl_renderer_context_create_with_flags(ctx, 7, 5, "arena") == 0);
    CHECK(virgl_renderer_context_create_fence(1, 0, 0, 0x100000009ULL) == 0);
    struct virgl_renderer_resource_create_blob_args args = {
        .res_handle = 1, .ctx_id = 1, .blob_mem = VIRGL_RENDERER_BLOB_MEM_HOST3D,
        .blob_flags = VIRGL_RENDERER_BLOB_FLAG_USE_MAPPABLE, .size = 4096,
    };
    CHECK((create_at ? create_at(&args, slice) : virgl_renderer_resource_create_blob(&args)) == 0);
    // Blob creation waits for the worker reply, after the fence on the same
    // socket. Polling must now deliver the complete 64-bit fence cookie.
    virgl_renderer_poll();
    CHECK(retired_fence == 0x100000009ULL);
    puts("PASS: polling retires Neptune context fences after the worker barrier");
    write_from_context(1, 1, 0x12345678);
    uint32_t value;
    memcpy(&value, slice + 2048, 4);
    if (value != 0x12345678) {
        fprintf(stderr, "FAIL: renderer write missed the 4 KiB arena slice (got %08x)\n", value);
        return 1;
    }
    puts("PASS: renderer writes into the caller's 4 KiB-offset slice");
    virgl_renderer_ctx_attach_resource(2, 1);
    write_from_context(2, 1, 0x87654321);
    memcpy(&value, slice + 2048, 4);
    CHECK(value == 0x87654321);
    puts("PASS: another context shares the same arena bytes");
    args.res_handle = 2;
    CHECK(create_at(&args, slice + 4096) == 0);
    write_from_context(1, 2, 0xaabbccdd);
    memcpy(&value, slice + 4096 + 2048, 4);
    CHECK(value == 0xaabbccdd);
    memcpy(&value, slice + 2048, 4);
    CHECK(value == 0x87654321);
    puts("PASS: adjacent slices within a 16 KiB page stay independent");
    void *mapped = NULL;
    uint64_t size = 0;
    CHECK(virgl_renderer_resource_map(1, &mapped, &size) == 0);
    CHECK(mapped == slice && size == 4096);
    CHECK(virgl_renderer_resource_unmap(1) == 0);
    CHECK(slice[2048] == 0x21);
    uint32_t fd_type = 0;
    int fd = -1;
    CHECK(virgl_renderer_resource_export_blob(1, &fd_type, &fd) != 0);
    void *fixed = mmap(NULL, 16384, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    CHECK(fixed != MAP_FAILED);
    CHECK(virgl_renderer_resource_map_fixed(1, fixed) != 0);
    munmap(fixed, 16384);
    puts("PASS: mapping borrows the slice; the transport token cannot be exported as data");
    virgl_renderer_resource_unref(2);
    memset(slice + 4096, 0, 4096);
    CHECK(create_at(&args, slice + 4096) == 0);
    virgl_renderer_resource_unref(2);
    puts("PASS: unref releases borrowed storage before the resource ID is reused");
    virgl_renderer_context_destroy(2);
    virgl_renderer_context_destroy(1);
    virgl_renderer_resource_unref(1);
    memset(slice, 0x5a, 4096);
    CHECK(slice[0] == 0x5a && slice[4095] == 0x5a);
    puts("PASS: resource/context destruction leaves caller-owned memory mapped");
    virgl_renderer_cleanup(&cookie);
    munmap(arena, 65536);
    return 0;
}
