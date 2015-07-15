BIN = interpreter compiler jit
all: $(BIN)

CFLAGS = -Wall -std=c99

interpreter: interpreter.c util.c
	gcc $(CFLAGS) -o $@ $^

compiler: compiler.c util.c stack.c
	gcc $(CFLAGS) -o $@ $^

hello: compiler
	./compiler samples/hello_world.bf > hello.s
	gcc -o hello hello.s

jit: jit.c util.c vector.c stack.c
	gcc $(CFLAGS) -o $@ $^

test: test_vector test_stack
	./test_vector && ./test_stack

test_vector: tests/test_vector.c vector.c
	gcc $(CFLAGS) -o $@ $^
test_stack: tests/test_stack.c stack.c
	gcc $(CFLAGS) -o $@ $^

clean:
	$(RM) $(BIN) \
	      hello hello.s \
	      test_vector test_stack
