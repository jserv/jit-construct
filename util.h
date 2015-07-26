#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

// prints to stderr than exits with code 1
static inline
void err(const char * const msg)
{
	fprintf(stderr, "%s\n", msg);
	exit(1);
}

// returns a heap allocated string, caller needs to free
static inline
char *read_file(const char * const filename)
{
	if (filename == NULL) return NULL;

	FILE *fp = fopen(filename, "r");
	if (fp == NULL) return NULL;

	assert(!fseek(fp, 0, SEEK_END));
	long file_size = ftell(fp);
	rewind(fp);
	size_t code_size = sizeof(char) * file_size;
	char *code = malloc(code_size);
	if (code == NULL) return NULL;

	fread(code, 1, file_size, fp);
	assert(!fclose(fp));
	return code;
}
