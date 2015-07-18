#include <stdio.h>
#include <stdlib.h>
#include "util.h"
#include "stack.h"

void compile(const char * const text_body)
{
	int num_brackets = 0;
	int matching_bracket = 0;
	struct stack stack = { .size = 0, .items = { 0 } };
	const char * const prologue =
	    ".text\n"
	    ".global main\n"
	    "main:\n"
	    "    pushq %rbp\n"
	    "    movq %rsp, %rbp\n"
	    "    pushq %r12\n"        // store callee saved register
	    "    subq $30008, %rsp\n" // allocate 30,008 B on stack, and realign
	    "    leaq (%rsp), %rdi\n" // address of beginning of tape
	    "    movl $0, %esi\n"     // fill with 0's
	    "    movq $30000, %rdx\n" // length 30,000 B
	    "    call memset\n"       // memset
	    "    movq %rsp, %r12";
	puts(prologue);

	for (unsigned long i = 0; text_body[i] != '\0'; ++i) {
		switch (text_body[i]) {
		case '>':
			puts("    inc %r12");
			break;
		case '<':
			puts("    dec %r12");
			break;
		case '+':
			puts("    incb (%r12)");
			break;
		case '-':
			puts("    decb (%r12)");
			break;
		case '.':
			// move byte to double word and zero upper bits
			// since putchar takes an int.
			puts("    movzbl (%r12), %edi");
			puts("    call putchar");
			break;
		case ',':
			puts("    call getchar");
			puts("    movb %al, (%r12)");
			break;
		case '[':
			if (stack_push(&stack, num_brackets) == 0) {
				puts  ("    cmpb $0, (%r12)");
				printf("    je bracket_%d_end\n", num_brackets);
				printf("bracket_%d_start:\n", num_brackets++);
			} else {
				err("out of stack space, too much nesting");
			}
			break;
		case ']':
			if (stack_pop(&stack, &matching_bracket) == 0) {
				puts("    cmpb $0, (%r12)");
				printf("    jne bracket_%d_start\n", matching_bracket);
				printf("bracket_%d_end:\n", matching_bracket);
			} else {
				err("stack underflow, unmatched brackets");
			}
			break;
		}
	}
	const char *const epilogue =
	    "    addq $30008, %rsp\n" // clean up tape from stack.
	    "    popq %r12\n" // restore callee saved register
	    "    popq %rbp\n"
	    "    ret\n";
	puts(epilogue);
}

int main(int argc, char *argv[])
{
	if (argc != 2) err("Usage: compile inputfile");
	char *text_body = read_file(argv[1]);
	if (text_body == NULL) err("Unable to read file");
	compile(text_body);
	free(text_body);
}
