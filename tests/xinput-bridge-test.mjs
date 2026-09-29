import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
const root = path.resolve(import.meta.dirname, '..');
const scratch = path.join(root, '.deploy/tests/xinput');
fs.mkdirSync(scratch, {recursive:true});
const wine = path.join(root, 'third_party/wine');
let source = fs.readFileSync(process.env.IOSWINE_XINPUT_SOURCE ?? path.join(wine, 'dlls/xinput1_3/main.c'), 'utf8');
const host = fs.readFileSync(path.join(root, 'src/ios/game_controller.m'), 'utf8');
const sys = fs.readFileSync(path.join(wine, 'dlls/ntdll/unix/system.c'), 'utf8');
function between(text, a, b) {
  const begin=text.indexOf(a), end=text.indexOf(b, begin);
  assert(begin>=0 && end>begin, a); return text.slice(begin,end);
}
function fn(name, text=source) {
  const re=new RegExp('^(?:static |void |DWORD |BOOL )[^\\n]*\\b'+name+'\\([^;]*?\\)\\n\\{','m');
  const m=re.exec(text); assert(m, name);
  let p=text.indexOf('{',m.index), depth=1, end=p+1;
  // These functions contain no unmatched literal braces in strings/comments.
  while(depth) { if(text[end]==='{') ++depth; if(text[end]==='}') --depth; ++end; }
  return text.slice(m.index,end);
}
// Optional negative control uses the actual previous GetState implementation.
if (process.env.IOSWINE_XINPUT_GET_STATE_BASELINE) {
  const old = fs.readFileSync(process.env.IOSWINE_XINPUT_GET_STATE_BASELINE,'utf8');
  source = source.replace(fn('ios_get_state'),fn('ios_get_state',old));
}
// A private local game copy is optional, never redistributed by this test.
const gamePath=path.join(root,'.deploy/input-20260924/DarkSoulsRemastered.exe');
if(fs.existsSync(gamePath)) {
  const game=fs.readFileSync(gamePath), pe=game.readUInt32LE(60);
  assert.equal(game.readUInt32LE(pe+8),0x6344ca56);
  assert.equal(game.readUInt32LE(pe+80),0x319b000);
  const sectionCount=game.readUInt16LE(pe+6), sections=pe+24+game.readUInt16LE(pe+20);
  function readRva(rva,n) {
    for(let i=0;i<sectionCount;++i) {
      const p=sections+i*40, va=game.readUInt32LE(p+12), rawSize=game.readUInt32LE(p+16);
      if(rva>=va && rva+n<=va+rawSize) {
        const file=game.readUInt32LE(p+20)+rva-va;return game.subarray(file,file+n);
      }
    }
    assert.fail(`Unmapped fingerprint RVA ${rva.toString(16)}`);
  }
  let count=0;
  for(const m of source.matchAll(/ios_dsr_match\( base \+ (0x[0-9a-f]+), "([^"]+)", (\d+) \)/g)) {
    const bytes=Buffer.from([...m[2].matchAll(/\\x([0-9a-f]{2})/g)].map(x=>parseInt(x[1],16)));
    assert.equal(bytes.length,Number(m[3]));assert.deepEqual(readRva(Number(m[1]),bytes.length),bytes);++count;
  }
  assert.equal(count,3);console.log('DSR executable fingerprints PASS: match the unmodified phone game');
}
function nativeOnly(name, marker) {
  const f=fn(name), p=f.indexOf(marker); assert(p>0,name);
  let body=f.slice(0,p);
  // Drop only declarations belonging to the excluded desktop HID branch.
  if (name==='XInputEnable') body=body.replace('    int index;','');
  if (name==='XInputSetState' || name==='xinput_get_state') body=body.replace('    DWORD ret;','');
  if (name==='XInputGetCapabilitiesEx') body=body.replace('    HIDD_ATTRIBUTES attr;','');
  return body+(name==='XInputEnable' ? '\n}' : '\nreturn ERROR_NOT_SUPPORTED;\n}');
}
const xheader=fs.readFileSync(path.join(wine,'include/xinput.h'),'utf8').replace('#include <windef.h>','');
const code=`
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <dlfcn.h>
#include "${wine}/include/wine/ios_gamepad.h"
typedef uint32_t DWORD,ULONG; typedef int32_t LONG; typedef uint16_t WORD,WCHAR;
typedef int16_t SHORT; typedef uint8_t BYTE; typedef int BOOL,SYSTEM_INFORMATION_CLASS,NTSTATUS;
typedef size_t SIZE_T;
typedef struct {uint32_t data[4];} GUID;
#define WINAPI
#define DECLSPEC_HOTPATCH
#define TRUE 1
#define FALSE 0
#define ERROR_SUCCESS 0
#define ERROR_NOT_ENOUGH_MEMORY 8
#define ERROR_NOT_SUPPORTED 50
#define ERROR_BAD_ARGUMENTS 160
#define ERROR_DEVICE_NOT_CONNECTED 1167
#define ERROR_EMPTY 4306
#define STATUS_SUCCESS 0
#define STATUS_INFO_LENGTH_MISMATCH ((NTSTATUS)0xc0000004)
#define STATUS_ACCESS_VIOLATION ((NTSTATUS)0xc0000005)
#define STATUS_NOT_SUPPORTED ((NTSTATUS)0xc00000bb)
#define WINE_IOS_JIT_ARENA 1
#define TRACE(...) ((void)0)
#define FIXME(...) ((void)0)
static unsigned test_messages;
static void test_message(const char *format, ...) { (void)format; ++test_messages; }
#define WINE_MESSAGE(...) test_message(__VA_ARGS__)
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define XINPUT_GAMEPAD_GUIDE 0x0400
typedef pthread_mutex_t SRWLOCK;
#define SRWLOCK_INIT PTHREAD_MUTEX_INITIALIZER
#define AcquireSRWLockExclusive(x) pthread_mutex_lock(x)
#define ReleaseSRWLockExclusive(x) pthread_mutex_unlock(x)
static LONG InterlockedCompareExchange(LONG*p,LONG n,LONG old) {return __sync_val_compare_and_swap(p,old,n);}
static LONG InterlockedExchange(LONG*p,LONG n) {return __atomic_exchange_n(p,n,__ATOMIC_SEQ_CST);}
static LONG InterlockedIncrement(LONG*p) {return __atomic_add_fetch(p,1,__ATOMIC_SEQ_CST);}
static DWORD test_pid=10;
static DWORD GetCurrentProcessId(void) {return test_pid;}
static void *test_image;
static void *GetModuleHandleW(void *name) {(void)name;return test_image;}
static void *GetCurrentProcess(void) {return (void*)-1;}
static struct {uintptr_t start; size_t size;} readable[8];
static unsigned readable_count;
static void allow_read(void *p,size_t size) {readable[readable_count].start=(uintptr_t)p;readable[readable_count++].size=size;}
static NTSTATUS NtReadVirtualMemory(void *process,const void *address,void *data,size_t size,size_t *read) {
 (void)process;*read=0;
 for(unsigned i=0;i<readable_count;++i) {
  uintptr_t p=(uintptr_t)address;
  if(p>=readable[i].start && p-readable[i].start<=readable[i].size && size<=readable[i].size-(p-readable[i].start)) {
   memcpy(data,address,size);*read=size;return 0;
  }
 }
 return STATUS_ACCESS_VIOLATION;
}
static void put32(unsigned char *p,uint32_t value) {memcpy(p,&value,4);}
static void put16(unsigned char *p,uint16_t value) {memcpy(p,&value,2);}
${xheader}
${between(host,'static pthread_mutex_t g_pad_lock','@interface IOSWineGamepadBridge')}
// dlsym is exercised for real against the exported production snapshot reader.
${between(sys,'#if defined(__APPLE__) && defined(WINE_IOS_JIT_ARENA)\nstatic pthread_once_t ios_gamepad_once','/******************************************************************************\n *              NtQuerySystemInformation')}
static NTSTATUS NtQuerySystemInformation(SYSTEM_INFORMATION_CLASS cls,void*p,ULONG n,ULONG*len) {
 assert(cls==IOSWINE_GAMEPAD_INFO_CLASS); return ios_query_gamepads(p,n,len);
}
${between(source,'static BOOL ios_backend;','static void set_current_state')}
${nativeOnly('XInputEnable','    /* Setting to false')}
${nativeOnly('XInputSetState','    start_update_thread();')}
${nativeOnly('xinput_get_state','    start_update_thread();')}
${fn('XInputGetState')}
${fn('XInputGetStateEx')}
${between(source,'static const int JS_STATE_OFF','DWORD WINAPI DECLSPEC_HOTPATCH XInputGetCapabilities(')}
${fn('XInputGetCapabilities')}
${nativeOnly('XInputGetDSoundAudioDeviceGuids','    EnterCriticalSection(')}
${nativeOnly('XInputGetBatteryInformation','    EnterCriticalSection(')}
${nativeOnly('XInputGetCapabilitiesEx','    start_update_thread();')}
int main(void) {
 ios_backend=1;
 struct ios_gamepad_info info;
 ULONG length=0;
 assert(ios_query_gamepads(&info,0,&length)==STATUS_INFO_LENGTH_MISMATCH && length==100);
 assert(ios_query_gamepads(NULL,100,NULL)==STATUS_ACCESS_VIOLATION);
 assert(!ios_query_gamepads(&info,100,NULL) && info.version==1);
 assert(ios_gamepad_snapshot);
 XINPUT_STATE state,ex;
 assert(XInputGetState(0,&state)==ERROR_DEVICE_NOT_CONNECTED);
 assert(XInputGetState(4,&state)==ERROR_BAD_ARGUMENTS);
 assert(XInputGetState(0,NULL)==ERROR_BAD_ARGUMENTS);
 g_pads.pads[0]=(struct ios_gamepad_state){.connected=1,.packet=42,.buttons=0x1401,
   .left_trigger=37,.right_trigger=255,.lx=-32768,.ly=32767,.rx=-12345,.ry=5432,.battery_type=1};
 assert(!XInputGetState(0,&state));
 assert(state.dwPacketNumber==42 && state.Gamepad.wButtons==0x1001);
 assert(state.Gamepad.sThumbLX==-32768 && state.Gamepad.sThumbLY==32767);
 assert(state.Gamepad.sThumbRX==-12345 && state.Gamepad.sThumbRY==5432);
 assert(state.Gamepad.bLeftTrigger==37 && state.Gamepad.bRightTrigger==255);
 assert(!XInputGetStateEx(0,&ex) && ex.Gamepad.wButtons==0x1401);
 assert(!XInputGetState(0,&ex) && ex.dwPacketNumber==42);
 XInputEnable(FALSE);
 assert(!XInputGetState(0,&state) && state.Gamepad.wButtons==0 && state.Gamepad.sThumbLX==0 && state.dwPacketNumber==43);
 test_pid=20; assert(!XInputGetState(0,&state) && state.Gamepad.wButtons==0x1001);
 test_pid=10; XInputEnable(TRUE);
 assert(!XInputGetState(0,&state) && state.Gamepad.wButtons==0x1001 && state.dwPacketNumber==44);
 XINPUT_CAPABILITIES caps;
 assert(!XInputGetCapabilities(0,XINPUT_FLAG_GAMEPAD,&caps));
 assert(caps.Type==1 && caps.SubType==1 && caps.Flags==0 && caps.Gamepad.wButtons==0xf3ff);
 assert(caps.Gamepad.bRightTrigger==255 && caps.Gamepad.sThumbRX==32767 && !caps.Vibration.wLeftMotorSpeed);
 assert(XInputGetCapabilities(0,0,NULL)==ERROR_BAD_ARGUMENTS);
 XINPUT_VIBRATION vib={65535,65535};
 assert(!XInputSetState(0,&vib) && XInputSetState(1,&vib)==ERROR_DEVICE_NOT_CONNECTED);
 assert(XInputSetState(0,NULL)==ERROR_BAD_ARGUMENTS);
 XINPUT_BATTERY_INFORMATION battery;
 assert(!XInputGetBatteryInformation(0,0,&battery) && battery.BatteryType==1);
 assert(XInputGetBatteryInformation(0,1,&battery)==ERROR_DEVICE_NOT_CONNECTED);
 GUID render,capture;
 assert(!XInputGetDSoundAudioDeviceGuids(0,&render,&capture) && !render.data[0]);
 g_pads.pads[0].buttons=0x1000;
 g_pads.pads[0].left_trigger=g_pads.pads[0].right_trigger=0;
 g_pads.pads[0].lx=g_pads.pads[0].ly=g_pads.pads[0].rx=g_pads.pads[0].ry=0;
 XINPUT_KEYSTROKE key;
 assert(!XInputGetKeystroke(0,0,&key) && key.VirtualKey==VK_PAD_A && key.Flags==XINPUT_KEYSTROKE_KEYDOWN);
 assert(XInputGetKeystroke(0,0,&key)==ERROR_EMPTY);
 test_pid=20; assert(!XInputGetKeystroke(0,0,&key) && key.VirtualKey==VK_PAD_A);
 g_pads.pads[0].buttons=0;
 assert(!XInputGetKeystroke(XUSER_INDEX_ANY,0,&key) && key.Flags==XINPUT_KEYSTROKE_KEYUP);
 assert(XInputGetKeystroke(0,0,NULL)==ERROR_BAD_ARGUMENTS);
 for (int i=1;i<4;++i) {
   g_pads.pads[i]=(struct ios_gamepad_state){.connected=1,.packet=1,.buttons=(uint16_t)(1<<i)};
   assert(!XInputGetState(i,&state) && state.Gamepad.wButtons==(1<<i));
 }
 g_pads.pads[0].connected=0;
 assert(XInputGetState(0,&state)==ERROR_DEVICE_NOT_CONNECTED);
 // Diagnostics must not change input or grow without bound while a stick moves.
 test_pid=30; ios_trace=1; test_messages=0;
 g_pads.pads[0].connected=1;
 for (unsigned i=1;i<=300;++i) {
   g_pads.pads[0].packet=i; g_pads.pads[0].buttons=(i&1)?0x1000:0;
   assert(!XInputGetState(0,&state) && state.dwPacketNumber==i);
   assert(state.Gamepad.wButtons==g_pads.pads[0].buttons);
   unsigned after_change=test_messages;
   assert(!XInputGetState(0,&ex) && ex.dwPacketNumber==i);
   assert(test_messages==after_change);
 }
 assert(test_messages==128 && ios_client()->trace_count==128);

 // A faithful fixture of the verified executable's header/signatures and
 // binding layout, not a fake clock-based "wait enough" test. Memory reads
 // reject all addresses outside explicitly registered regions.
 unsigned char *image=calloc(1,0x319b000), entries[3][0x148]={0};
 uint64_t manager[3]={0}, manager_address=(uintptr_t)manager;
 assert(image);allow_read(image,0x319b000);allow_read(manager,sizeof(manager));allow_read(entries,sizeof(entries));
 test_image=image;
 put16(image,0x5a4d);put32(image+0x3c,0x180);put32(image+0x180,0x4550);
 put16(image+0x184,0x8664);put32(image+0x188,0x6344ca56);put16(image+0x198,0x20b);put32(image+0x1d0,0x319b000);
 memcpy(image+0x54c3bb,"\\x48\\x8b\\x0d\\x5e\\x90\\x76\\x01\\xe8\\x79\\x58\\x74\\x00",12);
 memcpy(image+0xc91c8c,"\\x48\\x8b\\x5e\\x08\\x4c\\x89\\x74\\x24\\x50\\x48\\x3b\\x5e\\x10",13);
 memcpy(image+0xc96330,"\\x48\\x89\\x5c\\x24\\x08\\x48\\x89\\x6c\\x24\\x10\\x48\\x89\\x74\\x24\\x18\\x57\\x48\\x83\\xec\\x20",20);
 assert(ios_dsr_image()==(uintptr_t)image);
 image[0x188]^=1;assert(!ios_dsr_image());image[0x188]^=1;
 image[0x184]^=1;assert(!ios_dsr_image());image[0x184]^=1;
 image[0x198]^=1;assert(!ios_dsr_image());image[0x198]^=1;
 image[0x1d0]^=1;assert(!ios_dsr_image());image[0x1d0]^=1;
 for(unsigned i=0;i<3;++i) {unsigned offsets[]={0x54c3bb,0xc91c8c,0xc96330};
  image[offsets[i]]^=1;assert(!ios_dsr_image());image[offsets[i]]^=1;}
 assert(!ios_dsr_bindings_ready((uintptr_t)image)); // no manager yet
 memcpy(image+0x1cb5420,&manager_address,8);
 manager[0]=(uintptr_t)image+0x12d2fd0;
 manager[1]=manager[2]=(uintptr_t)entries;
 assert(!ios_dsr_bindings_ready((uintptr_t)image)); // empty vector
 manager[2]+=0x148;
 assert(!ios_dsr_bindings_ready((uintptr_t)image)); // keyboard only
 test_pid=40;ios_trace=0;
 g_pads.pads[0]=(struct ios_gamepad_state){.connected=1,.packet=400,.buttons=0x1000,.left_trigger=255,.lx=-28000};
 assert(!XInputGetState(0,&state));
 assert(state.Gamepad.wButtons==0 && !state.Gamepad.bLeftTrigger && !state.Gamepad.sThumbLX);
 DWORD neutral_packet=state.dwPacketNumber;
 for(unsigned i=0;i<10000;++i) { // arbitrarily delayed notification/rebuild stays safe
  assert(!XInputGetState(0,&ex) && !memcmp(&state,&ex,sizeof(state)));
 }
 assert(XInputGetKeystroke(0,0,&key)==ERROR_EMPTY);
 // GetState's SUCCESS lets the game's connection probe create its bindings.
 // Once that happens, held physical input is released unchanged, immediately,
 // with a new packet even when no new native callback arrives.
 manager[2]+=0x148;put32(entries[1]+0x88,1);
 assert(ios_dsr_bindings_ready((uintptr_t)image));
 assert(!XInputGetState(0,&ex) && ex.dwPacketNumber!=neutral_packet);
 assert(ex.Gamepad.wButtons==0x1000 && ex.Gamepad.bLeftTrigger==255 && ex.Gamepad.sThumbLX==-28000);
 assert(!XInputGetKeystroke(0,0,&key) && key.VirtualKey==VK_PAD_A);
 // Deleting/rebuilding bindings re-arms the guard, including reconnects
 // between polls. No cached lifetime "ready" bit or physical-neutral test.
 manager[2]-=0x148;
 assert(!XInputGetState(0,&state) && !state.Gamepad.wButtons && state.dwPacketNumber!=ex.dwPacketNumber);
 g_pads.pads[0].connected=0;assert(XInputGetState(0,&state)==ERROR_DEVICE_NOT_CONNECTED);
 g_pads.pads[0].connected=1;assert(!XInputGetState(0,&state) && !state.Gamepad.wButtons);
 g_pads.pads[1]=(struct ios_gamepad_state){.connected=1,.packet=500,.buttons=0x2000};
 assert(!XInputGetState(1,&state) && !state.Gamepad.wButtons);
 XInputEnable(FALSE);manager[2]+=0x148;
 assert(!XInputGetState(0,&state) && !state.Gamepad.wButtons);
 XInputEnable(TRUE);assert(!XInputGetState(0,&state) && state.Gamepad.wButtons==0x1000);
 assert(!XInputGetState(1,&state) && state.Gamepad.wButtons==0x2000);
 // Invalid/unreadable guest layouts must never crash the input DLL.
 uint64_t saved=manager[0];manager[0]=0;assert(!ios_dsr_bindings_ready((uintptr_t)image));manager[0]=saved;
 saved=manager[2];manager[2]=manager[1]-8;assert(!ios_dsr_bindings_ready((uintptr_t)image));
 manager[2]=manager[1]+1;assert(!ios_dsr_bindings_ready((uintptr_t)image));
 manager[2]=manager[1]+257*0x148;assert(!ios_dsr_bindings_ready((uintptr_t)image));manager[2]=saved;
 saved=manager_address;manager_address=0xdeadbeef;memcpy(image+0x1cb5420,&manager_address,8);
 assert(!XInputGetState(0,&state) && !state.Gamepad.wButtons);
 memcpy(image+0x1cb5420,&saved,8);
 // A different process/image must not inherit DSR's guard. A mismatched DSR
 // build likewise does not follow unverified offsets.
 test_pid=50;test_image=NULL;
 assert(!XInputGetState(0,&state) && state.Gamepad.wButtons==0x1000 && state.dwPacketNumber==400);
 test_pid=60;test_image=image;image[0xc96330]^=1;
 assert(!XInputGetState(0,&state) && state.Gamepad.wButtons==0x1000 && !ios_client()->dsr_image);
 test_image=NULL;free(image);
 puts("DSR BINDING GUARD PASS: version/signature gating, connected-neutral until real bindings, delayed rebuild, held-input release/packet, removal/reconnect, four-slot/process isolation, invalid-memory safety");
 puts("XINPUT ABI/API PASS: native symbol/syscall snapshot, four slots, state/Ex/caps/battery, per-owner Enable and keystrokes, no fake rumble");
}
`;
fs.writeFileSync(path.join(scratch,'xinput-test.c'),code);
for (const [input, output] of [
  [path.join(root,'tests/gamepad_state_test.c'),path.join(scratch,'gamepad-state')],
  [path.join(scratch,'xinput-test.c'),path.join(scratch,'xinput-api')],
]) {
  execFileSync('xcrun',['--sdk','macosx','clang','-std=c11','-Wall','-Wextra',
    '-Wno-unused-parameter','-Wno-sign-compare','-Werror','-fsanitize=address,undefined',
    '-Wl,-export_dynamic',input,'-o',output],{stdio:'inherit'});
  execFileSync(output,[],{stdio:'inherit',timeout:30000});
}
const preset=JSON.parse(fs.readFileSync(path.join(root,'assets/dsr-rendering-launch.json')));
assert.equal(preset.env.IOSWINE_GAME_INPUT,'1');
assert(host.includes('c.handlerQueue = self->_queue'));
assert(!host.includes('SetKeySink') && !host.includes('VK_'));
assert(!host.includes('dlsym('));
console.log('XINPUT integration policy PASS: DSR game-input preset, dedicated native queue, XInput only (no keyboard fallback)');
