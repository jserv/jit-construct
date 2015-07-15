BIN = interpreter compiler jit
all: $(BIN)

CFLAGS = -Wall -Werror -std=c99 -I.

interpreter: interpreter.c util.c
	$(CC) $(CFLAGS) -o $@ $^

compiler: compiler.c util.c stack.c
	$(CC) $(CFLAGS) -o $@ $^

hello: compiler
	./compiler samples/hello_world.bf > hello.s
	$(CC) -o hello hello.s

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
	      hello hello.s \
	      test_vector test_stack
