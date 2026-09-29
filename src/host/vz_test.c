/* Host driver for vz.c: vz_test <package> <dir> prints one line. */
#include "../ios/vz.h"

#include <stdio.h>

int main(int argc, char **argv) {
  char err[256] = "";

  if (argc != 3) {
    fprintf(stderr, "usage: vz_test <package> <dir>\n");
    return 2;
  }
  if (vz_extract(argv[1], argv[2], NULL, NULL, err, sizeof(err)) != 0) {
    printf("vz: ERROR %s\n", err);
    return 1;
  }
  printf("vz: ok\n");
  return 0;
}
