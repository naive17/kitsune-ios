// Compile the actual host sampler with controlled Mach/symbol-lookup results.
// In particular a failed dladdr may leave unusable pointers in its output.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const scratch = path.join(root, '.deploy/tests/guest-sampler');
fs.mkdirSync(scratch, {recursive:true});
const source = fs.readFileSync(process.argv[2] ?? path.join(root, 'src/ios/wine_boot.m'), 'utf8');
const start = source.indexOf('void WineBootSampleGuest(char *out, size_t outlen) {');
const end = source.indexOf('\n}\n', start);
assert(start >= 0 && end > start);
const fn = source.slice(start, end + 3);
const code = `
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>
#include <dlfcn.h>
#include <fcntl.h>
typedef unsigned mach_port_t, mach_msg_type_number_t;
typedef void *thread_state_t;
typedef struct { uint64_t pc,lr,sp,fp,__x[29]; } arm_thread_state64_t;
#define MACH_PORT_NULL 0
#define ARM_THREAD_STATE64_COUNT 1
#define ARM_THREAD_STATE64 1
#define KERN_SUCCESS 0
#define arm_thread_state64_get_pc(s) ((s).pc)
#define arm_thread_state64_get_lr(s) ((s).lr)
#define arm_thread_state64_get_sp(s) ((s).sp)
#define arm_thread_state64_get_fp(s) ((s).fp)
static mach_port_t wine_guest_thread;
static int mode, bad_state, lookups, fd_calls, symbol_queries;
static unsigned inflight=~0u, calls=42;
static int sample_state(mach_port_t t, int flavor, thread_state_t result, mach_msg_type_number_t *n) {
 (void)t; (void)flavor; (void)n;
 *(arm_thread_state64_t *)result=(arm_thread_state64_t){.pc=0x120004000,.lr=0x1234,.sp=0x4567,.fp=0x6789,.__x={21}};
 return bad_state;
}
static int sample_dladdr(const void *pc, Dl_info *info) {
 (void)pc; ++lookups;
 if (!mode) {
   // Stronger than leaving uninitialized storage: failure fields must NEVER
   // be inspected, even if the resolver populated invalid/stale addresses.
   memset(info, 0xa5, sizeof(*info)); return 0;
 }
 *info=(Dl_info){0};
 if (mode==1) {info->dli_fname="/usr/lib/libsystem_kernel.dylib"; info->dli_sname="read";}
 if (mode==2) {info->dli_fname="/usr/lib/libsystem_kernel.dylib";}
 if (mode==3) {info->dli_sname="read";}
 return 1;
}
static int sample_fcntl(int fd, int cmd, char *path) {
 (void)path; assert(fd==21 && cmd==F_GETPATH); ++fd_calls; return -1;
}
static void *sample_dlsym(void *handle, const char *name) {
 assert(handle==RTLD_DEFAULT); ++symbol_queries;
 if (!strcmp(name,"ios_server_req_in_flight")) return &inflight;
 if (!strcmp(name,"ios_server_call_count")) return &calls;
 assert(0); return NULL;
}
#define thread_get_state sample_state
#define dladdr sample_dladdr
#define dlsym sample_dlsym
#define fcntl sample_fcntl
${fn}
int main(void) {
 char out[512];
 WineBootSampleGuest(out,sizeof(out)); assert(!strcmp(out,"guest=not-started") && !lookups);
 wine_guest_thread=1; bad_state=1;
 WineBootSampleGuest(out,sizeof(out)); assert(!strcmp(out,"guest=unreadable") && !lookups);
 bad_state=0; mode=0;
 for (int i=0;i<1000;++i) {
   WineBootSampleGuest(out,sizeof(out));
   assert(strstr(out,"guest pc=0x120004000 (unsymbolised!?)"));
 }
 assert(!fd_calls && !symbol_queries);
 mode=1; WineBootSampleGuest(out,sizeof(out));
 assert(strstr(out,"libsystem_kernel.dylib!read") && strstr(out,"fd=21(socket/pipe) srv=idle calls=42"));
 mode=2; WineBootSampleGuest(out,sizeof(out)); assert(strstr(out,"libsystem_kernel.dylib!?") && fd_calls==1);
 mode=3; inflight=9; WineBootSampleGuest(out,sizeof(out));
 assert(strstr(out,"unsymbolised!read") && strstr(out,"srv=req9(unanswered) calls=42"));
 assert(fd_calls==2 && symbol_queries==4);
 char tiny[4]; WineBootSampleGuest(tiny,sizeof(tiny)); assert(tiny[3]==0);
 puts("GUEST SAMPLER PASS: failed dladdr poison ignored, repeated JIT samples, partial symbols, fd details and bounded output");
}
`;
const input = path.join(scratch, 'guest-sampler.c');
const output = path.join(scratch, 'guest-sampler');
fs.writeFileSync(input, code);
execFileSync('xcrun', ['--sdk','macosx','clang','-std=c11','-D_DARWIN_C_SOURCE',
  '-Wall','-Wextra','-Werror','-fsanitize=address,undefined',input,'-o',output], {stdio:'inherit'});
execFileSync(output, [], {stdio:'inherit',timeout:30000});
