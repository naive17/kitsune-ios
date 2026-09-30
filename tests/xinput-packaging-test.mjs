// Exercise Wine's real load_builtin architecture selection, then check the
// packaged PE payloads. This catches the native x64 game-local DLL override
// case that API-only XInput tests do not cover.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
const root = path.resolve(import.meta.dirname, '..');
const runtime = path.resolve(process.argv[2] ?? path.join(root, 'build/xc-out/Kitsune.app/lib/wine'));
const scratch = path.join(root, '.deploy/tests/xinput');
fs.mkdirSync(scratch, {recursive:true});
const loader = fs.readFileSync(path.join(root, 'third_party/wine/dlls/ntdll/unix/loader.c'), 'utf8');
function fn(signature) {
  const start = loader.indexOf(signature); assert(start >= 0);
  let end = loader.indexOf('\n}\n', start); assert(end > start);
  return loader.slice(start, end + 3);
}
const code = `
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
typedef int BOOL,NTSTATUS; typedef unsigned short USHORT,WORD;
typedef unsigned long SIZE_T,ULONG_PTR; typedef int SECTION_IMAGE_INFORMATION;
typedef int UNICODE_STRING,ANSI_STRING;
#define FALSE 0
#define TRUE 1
#define IMAGE_FILE_MACHINE_I386 0x14c
#define IMAGE_FILE_MACHINE_AMD64 0x8664
#define IMAGE_FILE_MACHINE_ARMNT 0x1c4
#define IMAGE_FILE_MACHINE_ARM64 0xaa64
#define STATUS_DLL_NOT_FOUND ((int)0xc0000135)
#define STATUS_NOT_SUPPORTED ((int)0xc00000bb)
#define STATUS_IMAGE_ALREADY_LOADED 0x4000000e
#define TRACE(...) ((void)0)
enum loadorder {LO_DISABLED,LO_NATIVE,LO_NATIVE_BUILTIN,LO_BUILTIN,LO_BUILTIN_NATIVE,LO_DEFAULT};
struct pe_mapping_info {struct {USHORT machine; int wine_builtin,wine_fakedll,is_hybrid;} image;
 UNICODE_STRING nt_name; ANSI_STRING exp_name;};
static WORD current_machine=IMAGE_FILE_MACHINE_ARM64;
static const char *runtime,*dll;
static BOOL is_arm64ec(void) {return TRUE;}
static BOOL is_system_dir_path(UNICODE_STRING *n,USHORT *m) {*m=current_machine; return FALSE;}
static enum loadorder get_load_order(UNICODE_STRING *n,BOOL s,struct pe_mapping_info *p) {return LO_BUILTIN;}
${fn('static const char *get_pe_dir(')}
static NTSTATUS find_builtin_dll(UNICODE_STRING*n,ANSI_STRING*e,void**m,SIZE_T*s,
 SECTION_IMAGE_INFORMATION*i,ULONG_PTR lo,ULONG_PTR hi,USHORT search,USHORT load,BOOL prefer,off_t off) {
 char file[4096]; snprintf(file,sizeof(file),"%s%s/%s.dll",runtime,get_pe_dir(search),dll);
 return access(file,R_OK) ? STATUS_DLL_NOT_FOUND : 0;
}
${fn('NTSTATUS load_builtin(')}
int main(int argc,char**argv) {
 assert(argc==2); runtime=argv[1];
 const char *variants[]={"xinput1_1","xinput1_2","xinput1_3","xinput1_4","xinput9_1_0","xinputuap","sechost"};
 for(unsigned j=0;j<sizeof(variants)/sizeof(variants[0]);++j) {
  dll=variants[j]; struct pe_mapping_info p={.image.machine=IMAGE_FILE_MACHINE_AMD64};
  // DSR's game-local Microsoft DLL is pure AMD64, not hybrid/builtin.
  assert(!load_builtin(&p,IMAGE_FILE_MACHINE_AMD64,NULL,NULL,NULL,0,0,0));
  p.image.is_hybrid=1; // Hybrid AMD64 candidates select the native directory.
  assert(!load_builtin(&p,IMAGE_FILE_MACHINE_AMD64,NULL,NULL,NULL,0,0,0));
  p.image.machine=IMAGE_FILE_MACHINE_ARM64; p.image.wine_builtin=1;
  assert(!load_builtin(&p,IMAGE_FILE_MACHINE_AMD64,NULL,NULL,NULL,0,0,0));
 }
 puts("XINPUT LOADER PATH PASS: production load_builtin resolves native x64 and hybrid candidates");
}
`;
const input=path.join(scratch,'xinput-loader-test.c'), output=path.join(scratch,'xinput-loader');
fs.writeFileSync(input,code);
execFileSync('xcrun',['--sdk','macosx','clang','-Wall','-Wextra','-Werror','-Wno-unused-parameter',
  '-fsanitize=undefined',input,'-o',output],{stdio:'inherit'});
execFileSync(output,[runtime],{stdio:'inherit',timeout:30000});
for (const name of ['xinput1_1','xinput1_2','xinput1_3','xinput1_4','xinput9_1_0','xinputuap','sechost']) {
  const native=fs.readFileSync(path.join(runtime,'aarch64-windows',name+'.dll'));
  assert.equal(native.subarray(64,81).toString(),'Wine builtin DLL\0');
  // ARM64X's on-disk COFF header is AA64; its load config/dynamic relocations
  // identify the EC view. Do not confuse llvm-readobj's synthetic ARM64X ID
  // with the file's raw Machine field.
  assert.equal(native.readUInt16LE(native.readUInt32LE(60)+4),0xaa64);
  const metadata=execFileSync(path.join(root,'toolchains/llvm-mingw-20260812/bin/llvm-readobj'),
    ['--file-headers',path.join(runtime,'aarch64-windows',name+'.dll')],{encoding:'utf8'});
  assert(metadata.includes('Format: COFF-ARM64X') && metadata.includes('Format: COFF-ARM64EC'),
    'must contain both ARM64 and EC views, not a desktop-only image');
  assert.deepEqual(fs.readFileSync(path.join(runtime,'x86_64-windows',name+'.dll')),native);
}
console.log('XINPUT PACKAGING PASS: six XInput images plus sechost ARM64X byte-identical in both lookup directories');
