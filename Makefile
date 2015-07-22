BIN = interpreter compiler-x64 compiler-arm jit0 jit

CROSS_COMPILE = arm-linux-gnueabihf-
QEMU_ARM = qemu-arm -L /usr/arm-linux-gnueabihf

all: $(BIN)

CFLAGS = -Wall -Werror -std=gnu99 -I.

interpreter: interpreter.c util.c
	$(CC) $(CFLAGS) -o $@ $^

compiler-x64: compiler-x64.c util.c stack.c
	$(CC) $(CFLAGS) -o $@ $^

compiler-arm: compiler-arm.c util.c stack.c
	$(CC) $(CFLAGS) -o $@ $^

hello: compiler-x64 compiler-arm
	./compiler-x64 progs/hello.b > hello.s
	$(CC) -o hello-x64 hello.s
	@echo 'x64: ' `./hello-x64`
	./compiler-arm progs/hello.b > hello.s
	$(CROSS_COMPILE)gcc -o hello-arm hello.s
	@echo 'arm: ' `$(QEMU_ARM) hello-arm`

jit0: jit0.c
	$(CC) $(CFLAGS) -o $@ $^

jit: dynasm-driver.c jit.h util.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ -DJIT=\"jit.h\" \
		dynasm-driver.c util.c
jit.h: jit.dasc
	        lua dynasm/dynasm.lua -o $@ jit.dasc
run-jit: jit
	./jit progs/hello.b && objdump -D -b binary \
		-mi386 -Mx86-64 /tmp/jitcode

test: test_vector test_stack
	./test_vector && ./test_stack

test_vector: tests/test_vector.c vector.c
	$(CC) $(CFLAGS) -o $@ $^
test_stack: tests/test_stack.c stack.c
	$(CC) $(CFLAGS) -o $@ $^

clean:
	$(RM) $(BIN) \
	      hello-x64 hello-arm hello.s \
	      test_vector test_stack \
	      jit.h
