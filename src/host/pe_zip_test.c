/*
 * Host driver for pe_info and zip, so both can be tested off-device.
 *
 * The launcher's routing decision (native / FEX / refuse) and its handling of
 * a hostile archive are exactly the two things that cannot be debugged on a
 * phone: the first surfaces as a loader failure deep inside Wine, the second
 * as a file appearing somewhere it should not, which nothing on the device
 * would report at all. Both are pure functions of a file on disk, so both
 * belong in a host test.
 *
 * Subcommands are single-purpose and print one machine-checkable line each.
 */
#include "../ios/pe_info.h"
#include "../ios/zip.h"

#include <stdio.h>
#include <pthread.h>
#include <string.h>

static int cmd_pe(const char *path) {
  pe_info info;
  char err[128] = "";

  if (pe_info_read(path, &info, err, sizeof(err)) != 0) {
    printf("pe: ERROR %s\n", err);
    return 1;
  }
  printf("pe: machine=0x%04x arch=%s bits=%d dll=%d subsystem=%d\n",
         info.machine, pe_arch_name(info.arch), info.is_64bit ? 64 : 32,
         info.is_dll, (int)info.subsystem);
  return 0;
}

static int cmd_path(const char *name) {
  char out[4096];

  if (zip_safe_path(name, out, sizeof(out)) != 0) {
    printf("path: REJECT %s\n", name);
    return 0;
  }
  printf("path: ACCEPT %s -> %s\n", name, out);
  return 0;
}

static int cmd_list(const char *archive) {
  zip_reader *z;
  char err[256] = "";
  size_t i;

  if (zip_open(archive, &z, err, sizeof(err)) != 0) {
    printf("zip: ERROR %s\n", err);
    return 1;
  }
  printf("zip: entries=%zu\n", zip_count(z));
  for (i = 0; i < zip_count(z); i++)
    printf("zip: entry %s size=%llu dir=%d\n", zip_entry_name(z, i),
           (unsigned long long)zip_entry_size(z, i), zip_entry_is_dir(z, i));
  zip_close(z);
  return 0;
}

static int cmd_unzip(const char *archive, const char *dest) {
  zip_reader *z;
  char err[256] = "";
  size_t skipped = 0;

  if (zip_open(archive, &z, err, sizeof(err)) != 0) {
    printf("zip: ERROR %s\n", err);
    return 1;
  }
  if (zip_extract_all(z, dest, NULL, NULL, &skipped, err, sizeof(err)) != 0) {
    printf("zip: ERROR %s\n", err);
    zip_close(z);
    return 1;
  }
  printf("zip: extracted entries=%zu skipped=%zu\n", zip_count(z), skipped);
  zip_close(z);
  return 0;
}

/*
 * The same extraction, on a thread with a 512 KB stack.
 *
 * This is not a hypothetical limit. The app imports off the main thread so a
 * large archive does not freeze the UI, and a secondary thread on iOS gets
 * 512 KB. The extractor originally held two 256 KB I/O buffers as LOCALS, so
 * it overflowed that stack on the first deflated entry and killed the app --
 * while passing every test here, because this binary's main thread has 8 MB.
 *
 * Any future change that puts a large buffer back on the stack fails here
 * instead of on a phone.
 */
struct small_stack_args {
  const char *archive, *dest;
  int rc;
};

static void *unzip_on_small_stack(void *p) {
  struct small_stack_args *a = p;

  a->rc = cmd_unzip(a->archive, a->dest);
  return NULL;
}

static int cmd_unzip_smallstack(const char *archive, const char *dest) {
  pthread_attr_t attr;
  pthread_t th;
  struct small_stack_args a = { archive, dest, 1 };

  if (pthread_attr_init(&attr) != 0) return 1;
  /* Match iOS's secondary-thread default exactly. */
  if (pthread_attr_setstacksize(&attr, 512 * 1024) != 0) return 1;
  if (pthread_create(&th, &attr, unzip_on_small_stack, &a) != 0) {
    printf("zip: ERROR could not create the 512 KB-stack thread\n");
    return 1;
  }
  pthread_join(th, NULL);
  pthread_attr_destroy(&attr);
  return a.rc;
}

int main(int argc, char **argv) {
  if (argc >= 4 && !strcmp(argv[1], "unzip-smallstack"))
    return cmd_unzip_smallstack(argv[2], argv[3]);
  if (argc >= 3 && !strcmp(argv[1], "pe"))   return cmd_pe(argv[2]);
  if (argc >= 3 && !strcmp(argv[1], "path")) return cmd_path(argv[2]);
  if (argc >= 3 && !strcmp(argv[1], "list")) return cmd_list(argv[2]);
  if (argc >= 4 && !strcmp(argv[1], "unzip")) return cmd_unzip(argv[2], argv[3]);
  fprintf(stderr, "usage: pe_zip_test pe|path|list <arg> | unzip <zip> <dir>\n");
  return 2;
}
