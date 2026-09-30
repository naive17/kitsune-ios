// Kitsune JIT script for StikDebug.
//
// Serves the app's brk #0xf00d requests: x16 is the command, x0 and x1 the
// arguments, and the answer goes back in x0.
//   0  detach
//   1  prepare x1 bytes at x0 for JIT, allocating them first when x0 is 0
//   3  allocate x1 bytes RX without preparing them; the app then prepares the
//      region in steps, so it can run and show progress in between
//
// Unlike StikDebug's universal.js, a fault that is not ours is handed to the
// app with vCont;S and the reply to that is taken as the next stop. Resuming
// again after it desyncs the packet stream and deadlocks, and the app relies
// on its own fault handlers. Logging is sparse: each line is a round trip.

const CMD_DETACH = 0;
const CMD_PREPARE_REGION = 1;
const CMD_ALLOCATE_REGION = 3;

const BRK_JIT = 0xf00d;

let detached = false;
let pid = get_pid();
log(`Kitsune JIT script: attaching to ${pid}`);

// Signals worth handing back to the app. Everything else (notably the SIGSTOP
// that vAttach itself produces, and SIGTRAP from our own brk) must be resumed
// plainly -- re-delivering them wedges the process immediately.
const FORWARD_SIGNALS = new Set([
    0x04, // SIGILL
    0x08, // SIGFPE
    0x0a, // SIGBUS
    0x0b, // SIGSEGV
]);

// The reply to vAttach is the attach's own stop. Resume it plainly; forwarding
// it as a signal hangs the app.
send_command(`vAttach;${pid.toString(16)}`);
let stop = send_command('c');

while (!detached) {
    if (!stop || stop.length === 0) {
        log('empty stop reply; aborting');
        break;
    }

    // Process exited/terminated -> nothing left to drive.
    if (stop[0] === 'W' || stop[0] === 'X') {
        log(`inferior exited: ${stop}`);
        break;
    }

    const tid = matchGroup(stop, /T[0-9a-f]+thread:(?<v>[0-9a-f]+);/);
    const pcHex = matchGroup(stop, /20:(?<v>[0-9a-f]{16});/);
    if (!tid || !pcHex) {
        // Unparseable stop: resume plainly rather than hanging.
        stop = send_command('c');
        continue;
    }
    const pc = leHexToBig(pcHex);

    // Is the trapping instruction one of OUR brk calls?
    const instr = leHexToU32(send_command(`m${pc.toString(16)},4`));
    const isBrk = ((instr & 0xffe0001f) >>> 0) === 0xd4200000;
    const imm = (instr >> 5) & 0xffff;

    if (!isBrk || imm !== BRK_JIT) {
        // Not ours. If it is a genuine fault, hand it to the app's handler and
        // use the reply as the next stop -- that is the part universal.js gets
        // wrong. Anything else is resumed plainly rather than re-injected.
        const sigHex = matchGroup(stop, /^T(?<v>[0-9a-f]{2})/);
        const sig = sigHex ? parseInt(sigHex, 16) : -1;
        if (sigHex && FORWARD_SIGNALS.has(sig)) {
            stop = send_command(`vCont;S${sigHex}:${tid}`);
        } else {
            stop = send_command('c');
        }
        continue;
    }

    // One of ours: dispatch on x16, with args in x0/x1.
    const x16 = leHexToBig(matchGroup(stop, /10:(?<v>[0-9a-f]{16});/) || '0'.repeat(16));
    const x0 = leHexToBig(matchGroup(stop, /00:(?<v>[0-9a-f]{16});/) || '0'.repeat(16));
    const x1 = leHexToBig(matchGroup(stop, /01:(?<v>[0-9a-f]{16});/) || '0'.repeat(16));

    // Step over the brk before resuming, or we trap on it forever.
    send_command(`P20=${bigToLeHex(pc + 4n)};thread:${tid};`);

    const cmd = Number(x16);
    if (cmd === CMD_DETACH) {
        log('detach requested');
        send_command('D');
        detached = true;
        break;
    }

    if (cmd === CMD_ALLOCATE_REGION) {
        const rx = send_command(`_M${x1.toString(16)},rx`);
        const addr = rx && rx.length ? BigInt(`0x${rx}`) : 0n;
        if (addr === 0n) log('RX allocation failed');
        send_command(`P0=${bigToLeHex(addr)};thread:${tid};`);
        stop = send_command('c');
        continue;
    }

    if (cmd === CMD_PREPARE_REGION) {
        let addr = x0;
        if (addr === 0n) {
            const rx = send_command(`_M${x1.toString(16)},rx`);
            if (!rx || rx.length === 0) {
                log('RX allocation failed');
                send_command(`P0=${bigToLeHex(0n)};thread:${tid};`);
                stop = send_command('c');
                continue;
            }
            addr = BigInt(`0x${rx}`);
        }
        prepare_memory_region(addr, x1);
        send_command(`P0=${bigToLeHex(addr)};thread:${tid};`);
        stop = send_command('c');
        continue;
    }

    log(`unknown command ${cmd}`);
    stop = send_command('c');
}

log('Kitsune JIT script: done');

// A PID attach comes from the running app itself (Enable JIT or Play). Switch
// back to it once it has detached; otherwise it stays in the background behind
// StikDebug, and the boot waits for the foreground.
if (typeof resume_app === 'function') {
    log(`resume app: ${resume_app()}`);
}

// ---- helpers ----
function matchGroup(s, re) {
    const m = re.exec(s);
    return m ? m.groups['v'] : null;
}

function leHexToBig(hexStr) {
    let num = 0n;
    for (let i = 4; i >= 0; i--) {
        num = (num << 8n) | BigInt(parseInt(hexStr.substr(i * 2, 2), 16));
    }
    return num;
}

function bigToLeHex(num) {
    const bytes = [];
    for (let i = 0; i < 5; i++) {
        bytes.push(Number(num & 0xffn));
        num >>= 8n;
    }
    while (bytes.length < 8) bytes.push(0);
    return bytes.map(b => b.toString(16).padStart(2, '0')).join('');
}

function leHexToU32(hexStr) {
    return parseInt(hexStr.match(/../g).reverse().join(''), 16);
}
