#define STACKSIZE 100

struct stack {
	int size;
	int items [STACKSIZE];
};

static inline int
stack_push(struct stack * const p, const int x)
{
	if (p->size == STACKSIZE)
		return -1;

	p->items[p->size++] = x;
	return 0;
}

static inline int
stack_pop(struct stack * const p, int *x)
{
	if (p->size == 0)
		return -1;

	*x = p->items[--p->size];
	return 0;
}
