#include <stdio.h>
#include <stdlib.h>
#include "util.h"
#include "stack.h"

void compile(const char * const text_body)
{
	int num_brackets = 0;
	int matching_brackets = 0;
	struct stack stack = { .size = 0, .items = {0}};
	const char * const prologue = 
	    ".section .text\n"
	    ".global main\n"
	    "main:\n"
	    "    pushl %ebp\n"
	    "    movl  %esp, %ebp\n"
	    "    addl  $-3008, %esp\n"
	    "    leal  (%esp), %edi\n"
	    "    movl $0, %esi\n"
	    "    movl $3000, %edx\n"
	    "    call memset\n"
	    "    movl %esp, %ecx";
	puts(prologue);

	for(unsigned long i = 0; text_body[i] != '\0'; ++i)
	{
		switch (text_body[i]){
		case '>':
			puts("    inc %ecx");
			break;
		case '<':
			puts("    dec %ecx");
			break;
		case '+':
			puts("    incb (%ecx)");
			break;
		case '-':
			puts("    decb (%ecx)");
			break;
		case '.':
			puts("    call putchar");
			break;
		case ',':
			puts("    call getchar");
			puts("    movb %al, (%ecx)");
			break;
		case '[':
			if(stack_push(&stack, num_brackets)==0){
				puts  ("    cmpb $0, (%ecx)");
			
	printf("    je bracket_%d_end\n", num_brackets);	
	printf("bracket_%d_start:\n", num_brackets++);
			} else {
				err("out of stack space");
			}
			break;
		case ']':
			if(stack_pop(&stack, &matching_brackets)==0){
				puts  ("cmpb $0, (%ecx)");
				printf("    jne bracket_%d_start\n", matching_brackets);
				printf("bracket_%d_end:\n", matching_brackets);
			} else {
				err("stack underflow, unmatched");
			}
			break;
		}
	}
	const char * const epilogue =
	    "    addl $3008, %esp\n"
	    "    popl %ebp\n"
	    "    ret\n"
	    "putchar:\n"
	    "    mov $4, %eax\n"
	    "    mov $1, %ebx\n"
	    "    mov $1, %edx\n"
	    "    int $0x80\n";
	puts(epilogue);
}

int main(int argc, char *argv[])
{
	if(argc != 2) err("Usage: compile inputfile");
	char *text_body = read_file(argv[1]);
	if(text_body == NULL) err("unable to read file");
	compile(text_body);
	free(text_body);
}
