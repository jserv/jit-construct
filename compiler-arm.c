#include <stdio.h>
#include <stdlib.h>
#include "util.h"
#include "stack.h"

void compile(const char * const file_contents)
{
	int num_brackets = 0;
	int matching_bracket = 0;
	struct stack stack = { .size = 0, .items = { 0 } };
	const char * const prologue =
	    ".globl main\n"
	    "main:\n"
	    "LDR R4 ,= _array\n"
	    "push {lr}\n";
	puts(prologue);

	for (unsigned long i = 0; file_contents[i] != '\0'; ++i) {
		switch (file_contents[i]) {
		case '>':
			puts("    ADD R4, R4, #1");
			break;
		case '<':
			puts("    SUB R4, R4, #1");
			break;
		case '+':
			puts("    LDRB R5, [R4]");
			puts("    ADD R5, R5, #1");
			puts("    STRB R5, [R4]");
			break;
		case '-':
			puts("    LDRB R5, [R4]");
			puts("    SUB R5, R5, #1");
			puts("    STRB R5, [R4]");
			break;
		case '.':
			puts("    LDR R0 ,= _char ");
			puts("    LDRB R1, [R4]");
			puts("    BL printf");
			break;
		case ',':
			puts("    BL getchar");
			puts("    STRB R0, [R4]");
			break;
		case '[':
			if (stack_push(&stack, num_brackets) == 0) {
#if 0
				puts  ("    cmpb $0, (%r12)");
				printf("    je bracket_%d_end\n", num_brackets);
				printf("bracket_%d_start:\n", num_brackets++);
#endif
				printf("_in_%d:\n", num_brackets);
				puts  ("    LDRB R5, [R4]");
				puts  ("    CMP R5, #0");
				printf("    BEQ _out_%d\n", num_brackets);
				num_brackets++;
			} else {
				err("out of stack space, too much nesting");
			}
			break;
		case ']':
			if (stack_pop(&stack, &matching_bracket) == 0) {
#if 0
				puts("    cmpb $0, (%r12)");
				printf("    jne bracket_%d_start\n", matching_bracket);
				printf("bracket_%d_end:\n", matching_bracket);
#endif
				printf("_out_%d:\n", matching_bracket);
				puts  ("    LDRB R5, [R4]");
				puts  ("    CMP R5, #0");
				printf("    BNE _in_%d\n", matching_bracket);
			} else {
				err("stack underflow, unmatched brackets");
			}
			break;
		}
	}
	const char *const epilogue =
	    "    pop {pc}\n"
	    ".data\n"
	    ".align 4\n"
	    "_char: .asciz \"%c\"\n"
	    "_array: .space 30000\n";
	puts(epilogue);
}

int main(int argc, char *argv[])
{
	if (argc != 2) err("Usage: compile inputfile");
	char *file_contents = read_file(argv[1]);
	if (file_contents == NULL) err("Unable to read file");
	compile(file_contents);
	free(file_contents);
}
