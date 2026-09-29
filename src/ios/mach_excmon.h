#ifndef IOSWINE_MACH_EXCMON_H
#define IOSWINE_MACH_EXCMON_H

#ifdef __cplusplus
extern "C" {
#endif

/* Log BAD_ACCESS, BAD_INSTRUCTION, ARITHMETIC, GUARD, CORPSE_NOTIFY and
 * RESOURCE exceptions, with registers, to log_fd; the kernel's default action
 * still follows. Also logs exit/_exit/_Exit/abort calls with a backtrace. */
int MachExcMon_Install(int log_fd);

#ifdef __cplusplus
}
#endif

#endif
