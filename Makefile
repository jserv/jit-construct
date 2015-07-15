BIN = interpreter compiler-x64 compiler-arm jit

CROSS_COMPILE = arm-linux-gnueabihf-

all: $(BIN)

CFLAGS = -Wall -Werror -std=c99 -I.

interpreter: interpreter.c util.c
	$(CC) $(CFLAGS) -o $@ $^

compiler-x64: compiler-x64.c util.c stack.c
	$(CC) $(CFLAGS) -o $@ $^

compiler-arm: compiler-arm.c util.c stack.c
	$(CC) $(CFLAGS) -o $@ $^

hello: compiler-x64 compiler-arm
	./compiler-x64 progs/hello.b > hello.s
	$(CC) -o hello-x64 hello.s
	./compiler-arm progs/hello.b > hello.s
	$(CROSS_COMPILE)gcc -o hello-arm hello.s

jit: jit.c util.c vector.c stack.c
	$(CC) $(CFLAGS) -o $@ $^

test: test_vector test_stack
	./test_vector && ./test_stack

test_vector: tests/test_vector.c vector.c
	$(CC) $(CFLAGS) -o $@ $^
test_stack: tests/test_stack.c stack.c
	$(CC) $(CFLAGS) -o $@ $^

clean:
	$(RM) $(BIN) \
	      hello-x64 hello-arm hello.s \
	      test_vector test_stack
