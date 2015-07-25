BIN = interpreter \
      compiler-x86 compiler-x64 compiler-arm \
      jit0-x64 jit0-arm \
      jit-x64 jit-arm

CROSS_COMPILE = arm-linux-gnueabihf-
QEMU_ARM = qemu-arm -L /usr/arm-linux-gnueabihf

all: $(BIN)

#CFLAGS = -Wall -Werror -std=gnu99 -I.
CFLAGS = -Werror -std=gnu99 -I.

interpreter: interpreter.c util.c
	$(CC) $(CFLAGS) -o $@ $^

compiler-x86: compiler-x86.c util.c stack.c
	$(CC) $(CFLAGS) -o $@ $^

compiler-x64: compiler-x64.c util.c stack.c
	$(CC) $(CFLAGS) -o $@ $^

compiler-arm: compiler-arm.c util.c stack.c
	$(CC) $(CFLAGS) -o $@ $^

hello: compiler-x86 compiler-x64 compiler-arm
	./compiler-x86 progs/hello.b > hello.s
	$(CC) -m32 -o hello-x86 hello.s
	@echo 'x86: ' `./hello-x86`
	./compiler-x64 progs/hello.b > hello.s
	$(CC) -o hello-x64 hello.s
	@echo 'x64: ' `./hello-x64`
	./compiler-arm progs/hello.b > hello.s
	$(CROSS_COMPILE)gcc -o hello-arm hello.s
	@echo 'arm: ' `$(QEMU_ARM) hello-arm`

jit0-x64: jit0-x64.c
	$(CC) $(CFLAGS) -o $@ $^

jit-x64: dynasm-driver.c jit-x64.h util.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ -DJIT=\"jit-x64.h\" \
		dynasm-driver.c util.c
jit-x64.h: jit-x64.dasc
	        lua dynasm/dynasm.lua -o $@ jit-x64.dasc
run-jit-x64: jit-x64
	./jit-x64 progs/hello.b && objdump -D -b binary \
		-mi386 -Mx86-64 /tmp/jitcode

jit0-arm: jit0-arm.c
	$(CROSS_COMPILE)gcc $(CFLAGS) -o $@ $^

jit-arm: dynasm-driver.c jit-arm.h util.c
	$(CROSS_COMPILE)gcc $(CFLAGS) $(CPPFLAGS) -o $@ \
		-DJIT=\"jit-arm.h\" dynasm-driver.c util.c
jit-arm.h: jit-arm.dasc
	lua dynasm/dynasm.lua -o $@ jit-arm.dasc
run-jit-arm: jit-arm
	$(QEMU_ARM) jit-arm progs/hello.b && \
	$(CROSS_COMPILE)objdump -D -b binary -marm /tmp/jitcode

test: test_vector test_stack
	./test_vector && ./test_stack

test_vector: tests/test_vector.c vector.c
	$(CC) $(CFLAGS) -o $@ $^
test_stack: tests/test_stack.c stack.c
	$(CC) $(CFLAGS) -o $@ $^

clean:
	$(RM) $(BIN) \
	      hello-x86 hello-x64 hello-arm hello.s \
	      test_vector test_stack \
	      jit-x64.h jit-arm.h
