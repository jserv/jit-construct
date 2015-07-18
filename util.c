#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "util.h"

#define GUARD(expr) assert(!(expr))

void err(const char * const msg)
{
	fprintf(stderr, "%s\n", msg);
	exit(1);
}

char *read_file(const char * const filename)
{
	if (filename == NULL)
		return NULL;

	FILE *fp = fopen(filename, "r");
	if (fp == NULL)
		return NULL;

	GUARD(fseek(fp, 0, SEEK_END));
	long file_size = ftell(fp);
	rewind(fp);
	size_t code_size = sizeof(char) * file_size;
	char *code = malloc(code_size);
	if (code == NULL)
		return NULL;
	fread(code, 1, file_size, fp);
	GUARD(fclose(fp));
	return code;
}
