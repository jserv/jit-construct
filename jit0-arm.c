#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

int main(int argc, char *argv[]) {
  // Machine code for:
  // 000082e0 <main>:
  // 82e0:      e3a00000        mov     r0, #0
  // 82e4:      e12fff1e        bx      lr

  char code[] = {
    0x00, 0x00, 0xa0, 0xe3, // 0xe3a00000
    0x1e, 0xff, 0x2f, 0xe1  // 0xe12fff1e
  };

  if (argc < 2) {
    fprintf(stderr, "Usage: jit0-arm <integer>\n");
    return 1;
  }

  // Overwrite immediate value "0" in the instruction
  // with the user's value.  This will make our code:
  //   mov r0, <user's value>
  //   bx lr
  int num = atoi(argv[1]);
  memcpy(&code[0], &num, 2);

  // Allocate writable/executable memory.
  // Note: real programs should not map memory both writable
  // and executable because it is a security risk.
  void *mem = mmap(NULL, sizeof(code), PROT_WRITE | PROT_EXEC,
                   MAP_ANON | MAP_PRIVATE, -1, 0);
  memcpy(mem, code, sizeof(code));

  // The function will return the user's value.
  int (*func)() = mem;
  return func();
}
