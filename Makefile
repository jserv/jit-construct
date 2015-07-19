BIN = interpreter compiler-x64 compiler-arm \
      jit0-x64 jit0-arm jit-x64 jit-a64

CROSS_COMPILE = aarch64-linux-gnu-
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

jit-a64: jit-a64.c
	$(CROSS_COMPILE)gcc -g -O2 -o $@ $<
jit-a64.c: jit-a64.dasc
	lua dynasm/dynasm.lua -o $@ $<
dump-a64: jit-a64.dasc
	lua dynasm/dynasm.lua --dumparch a64 $< >dump.a64
qemu-a64: jit-a64
	qemu-aarch64 -L /usr/aarch64-linux-gnu $< progs/mandelbrot.b

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
	      jit-x64.h jit-a64.c
