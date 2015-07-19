/*
** DynASM AArch64 encoding engine.
** Copyright (C) 2005-2014 Mike Pall. All rights reserved.
** Released under the MIT license. See dynasm.lua for full copyright notice.
** Modification:
** 3.12.2014 Zenk Ju      Initial port to arm arch64
*/

#include <stddef.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>

#define DASM_ARCH                "a64"

#ifndef DASM_EXTERN
#define DASM_EXTERN(a,b,c,d)        0
#endif

/* the following two functions assume double and long are all 64 bits */
static long d2l(double d) {
    return *(long*)&d;
}

/* Action definitions. */
enum {
    DASM_STOP, DASM_SECTION, DASM_ESC, DASM_REL_EXT,
    /* The following actions need a buffer position. */
    DASM_ALIGN, DASM_REL_LG, DASM_LABEL_LG,
    /* The following actions also have an argument. */
    DASM_REL_PC, DASM_LABEL_PC,
    DASM_IMM,       /* NOT 64 bit */
    DASM_IMMADDROFF,/* -256 ~ 65520, if (negative or unaligned) and in [-256,255], need reset bit 24 for unscaled address offset*/
    DASM_IMMNSR,    /**may be 64 bit */
    DASM_IMMLSB,    /* 0~31 or 0~63 */
    DASM_IMMWIDTH1, /* 1~32-lsb or 1~64-lsb */
    DASM_IMMWIDTH2, /* 1~32-lsb or 1~64-lsb */
    DASM_IMMSHIFT,  /* 0~31 or 0~63 */
    DASM_IMMMOV,    /**may be 64 bit */
    DASM_IMMTBN,    /* 0~63 */
    DASM_IMMA2H,    /* 0~255 */
    DASM_IMMA2H64,  /**64 bit */
    DASM_IMMA2HFP,  /* floating point number */
    DASM_IMM8FP,    /* floating point number */
    DASM_IMMHLM,    /* 0 ~ 7 */
    DASM_IMMQSS,    /* 0 ~ 15 */
    DASM_IMMHB,     /* 1~64 */
    DASM_IMMSCALE,  /* 1~32 or 1~64 */
    DASM__MAX
};

/* Maximum number of section buffer positions for a single dasm_put() call. */
#define DASM_MAXSECPOS                25

/* DynASM encoder status codes. Action list offset or number are or'ed in. */
#define DASM_S_OK                0x00000000
#define DASM_S_NOMEM                0x01000000
#define DASM_S_PHASE                0x02000000
#define DASM_S_MATCH_SEC        0x03000000
#define DASM_S_RANGE_I                0x11000000
#define DASM_S_RANGE_SEC        0x12000000
#define DASM_S_RANGE_LG                0x13000000
#define DASM_S_RANGE_PC                0x14000000
#define DASM_S_RANGE_REL        0x15000000
#define DASM_S_UNDEF_LG                0x21000000
#define DASM_S_UNDEF_PC                0x22000000

/* Macros to convert positions (8 bit section + 24 bit index). */
#define DASM_POS2IDX(pos)        ((pos)&0x00ffffff)
#define DASM_POS2BIAS(pos)        ((pos)&0xff000000)
#define DASM_SEC2POS(sec)        ((sec)<<24)
#define DASM_POS2SEC(pos)        ((pos)>>24)
#define DASM_POS2PTR(D, pos)        (D->sections[DASM_POS2SEC(pos)].rbuf + (pos))

/* Action list type. */
typedef const unsigned int *dasm_ActList;

/* Per-section structure. */
typedef struct dasm_Section {
  int *rbuf;                /* Biased buffer pointer (negative section bias). */
  int *buf;                /* True buffer pointer. */
  size_t bsize;                /* Buffer size in bytes. */
  int pos;                /* Biased buffer position. */
  int epos;                /* End of biased buffer position - max single put. */
  int ofs;                /* Byte offset into section. */
} dasm_Section;

/* Core structure holding the DynASM encoding state. */
struct dasm_State {
  size_t psize;                        /* Allocated size of this structure. */
  dasm_ActList actionlist;        /* Current actionlist pointer. */
  int *lglabels;                /* Local/global chain/pos ptrs. */
  size_t lgsize;
  int *pclabels;                /* PC label chains/pos ptrs. */
  size_t pcsize;
  void **globals;                /* Array of globals (bias -10). */
  dasm_Section *section;        /* Pointer to active section. */
  size_t codesize;                /* Total size of all code sections. */
  int maxsection;                /* 0 <= sectionidx < maxsection. */
  int status;                        /* Status code. */
  dasm_Section sections[1];        /* All sections. Alloc-extended. */
};

/* ------------------- IMMNSR related operations -------------------- */
/*
N   imms    immr   datasize len  esize   S+1    R      
1  ssssss  rrrrrr    64      6    64     1~63  0~63
0  0sssss  0rrrrr    64/32   5    32     1~31  0~31
0  10ssss  00rrrr    64/32   4    16     1~15  0~15
0  110sss  000rrr    64/32   3    8      1~7   0~7
0  1110ss  0000rr    64/32   2    4      1~3   0~3
0  11110s  00000r    64/32   1    2      1     0~1

local immediate32 = Duplicate(ROR(Zeros(esize-S-1):Ones(S+1), R), 32)
local immediate64 = Duplicate(ROR(Zeros(esize-S-1):Ones(S+1), R), 64)

for 64bit data, total number is 64*63 + 32*31 + 16*15 + 8*7 + 4*3 + 2*1 = 5334
for 32bit data, total number is 32*31 + 16*15 + 8*7 + 4*3 + 2*1 = 1302
*/

struct nsrpair {
    unsigned long imm;
    unsigned int  encode;
} nsrmap32[1302], nsrmap64[5334];

static int nsrpaircompare(const void *left, const void *right) {
    unsigned long imml = ((struct nsrpair*)left)->imm;
    unsigned long immr = ((struct nsrpair*)right)->imm;
    
    if (imml == immr)
        return 0;
    else if (imml < immr)
        return -1;
    else
        return 1;
}

static void generatensrmap() {
    int s, r, len;
    unsigned long one = 1;
    unsigned long u64;
    unsigned int  u32;
    int esize = 64;
    int S1; /*max S+1*/
    int R; /*max R*/
    unsigned int imms;
    unsigned int encode;
    int p32, p64;
    p32 = p64 = 0;
    for (len=1; len<6; len++) {
        esize = (1<<len);
        S1 = (1<<len) - 1;
        R = (1<<len) -1;
        imms = (~((1<<(len+1))-1)) & 0x3f;
        for (s=1; s<=S1; s++) {
            unsigned long t = (one<<s) - 1;
            for (r=0; r<=R; r++) {
                int es;
                unsigned long t1;
                if (r == 0)
                    t1 = t;
                else
                    t1 = ((t>>r) | ((t&((one<<r)-1))<<(esize-r)));
                es = 0;
                u32 = 0;
                while (es < 32) {
                    u32 |= (t1<<es);
                    es += esize;
                }
                es = 0;
                u64 = 0;
                while (es < 64) {
                    u64 |= (t1<<es);
                    es += esize;
                }
                encode = ((imms | (s-1)) << 10) | (r<<16);
                nsrmap32[p32].imm = u32;
                nsrmap32[p32].encode = encode;
                nsrmap64[p64].imm = u64;
                nsrmap64[p64].encode = encode;
                p32++;
                p64++;
            }
        }
    }
    for (s=1; s<=63; s++) {
        unsigned long t = (one<<s) - 1;
        for (r=0; r<=63; r++) {
            if (r == 0)
                u64 = t;
            else
                u64 = ((t>>r) | ((t&((one<<r)-1))<<(64-r)));
            encode = (0x400000 | ((s-1) << 10) | (r<<16));
            nsrmap64[p64].imm = u64;
            nsrmap64[p64].encode = encode;
            p64++;
        }
    }
    qsort(nsrmap32, p32, sizeof(nsrmap32[0]), nsrpaircompare);
    qsort(nsrmap64, p64, sizeof(nsrmap64[0]), nsrpaircompare);
}

static int getnsrencode(unsigned long imm, int bit64, unsigned int *encode) {
    struct nsrpair p = {imm, 0};
    struct nsrpair *base = bit64 ? nsrmap64 : nsrmap32;
    size_t nmember = bit64 ? sizeof(nsrmap64)/sizeof(nsrmap64[0])
                           : sizeof(nsrmap32)/sizeof(nsrmap32[0]);
    
    void *result = bsearch(&p, base, nmember, sizeof(p), nsrpaircompare);

    if (!result) return 0;
    if (encode) *encode = ((struct nsrpair*)result)->encode;
    return 1;
}


/* The size of the core structure depends on the max. number of sections. */
#define DASM_PSZ(ms)        (sizeof(dasm_State)+(ms-1)*sizeof(dasm_Section))


/* Initialize DynASM state. */
void dasm_init(Dst_DECL, int maxsection) {
    dasm_State *D;
    size_t psz = 0;
    int i;
    Dst_REF = NULL;
    DASM_M_GROW(Dst, struct dasm_State, Dst_REF, psz, DASM_PSZ(maxsection));
    D = Dst_REF;
    D->psize = psz;
    D->lglabels = NULL;
    D->lgsize = 0;
    D->pclabels = NULL;
    D->pcsize = 0;
    D->globals = NULL;
    D->maxsection = maxsection;
    for (i = 0; i < maxsection; i++) {
        D->sections[i].buf = NULL;  /* Need this for pass3. */
        D->sections[i].rbuf = D->sections[i].buf - DASM_SEC2POS(i);
        D->sections[i].bsize = 0;
        D->sections[i].epos = 0;  /* Wrong, but is recalculated after resize. */
    }

    generatensrmap();
}

/* Free DynASM state. */
void dasm_free(Dst_DECL) {
    dasm_State *D = Dst_REF;
    int i;
    for (i = 0; i < D->maxsection; i++) {
        if (D->sections[i].buf)
            DASM_M_FREE(Dst, D->sections[i].buf, D->sections[i].bsize);
    }
    if (D->pclabels) DASM_M_FREE(Dst, D->pclabels, D->pcsize);
    if (D->lglabels) DASM_M_FREE(Dst, D->lglabels, D->lgsize);
    DASM_M_FREE(Dst, D, D->psize);
}

/* Setup global label array. Must be called before dasm_setup(). */
void dasm_setupglobal(Dst_DECL, void **gl, unsigned int maxgl) {
    dasm_State *D = Dst_REF;
    D->globals = gl - 10;  /* Negative bias to compensate for locals. */
    DASM_M_GROW(Dst, int, D->lglabels, D->lgsize, (10+maxgl)*sizeof(int));
}

/* Grow PC label array. Can be called after dasm_setup(), too. */
void dasm_growpc(Dst_DECL, unsigned int maxpc) {
    dasm_State *D = Dst_REF;
    size_t osz = D->pcsize;
    DASM_M_GROW(Dst, int, D->pclabels, D->pcsize, maxpc*sizeof(int));
    memset((void *)(((unsigned char *)D->pclabels)+osz), 0, D->pcsize-osz);
}

/* Setup encoder. */
void dasm_setup(Dst_DECL, const void *actionlist) {
    dasm_State *D = Dst_REF;
    int i;
    D->actionlist = (dasm_ActList)actionlist;
    D->status = DASM_S_OK;
    D->section = &D->sections[0];
    memset((void *)D->lglabels, 0, D->lgsize);
    if (D->pclabels) memset((void *)D->pclabels, 0, D->pcsize);
    for (i = 0; i < D->maxsection; i++) {
        D->sections[i].pos = DASM_SEC2POS(i);
        D->sections[i].ofs = 0;
    }
}

static int wide_imm(unsigned long l, int bit64, unsigned int *encode) {
    int n = bit64 ? 4 : 2;
    int i;
    unsigned long m = 0xffff;

    if (l == 0L) {
        if (encode) *encode = 0;
        return 1;
    }

    for (i=0; i<n; i++) {
        if ((l&m) && !(l&~m)) {
            if (encode) *encode = (unsigned int)(((l>>(i*16)) << 5) | (i<<21));
            return 1;
        }
        m <<= 16;
    }

    return 0;
}

static int a2h64_imm(unsigned long l, unsigned int *encode) {
    int i;
    unsigned int e = 0;

    for (i=0; i<8; i++) {
        int b = ((l>>(i*8))&0xff);
        if (b == 0xff)
            e |= (1<<i);
        else if (b != 0)
            return 0;
    }

    if (encode) *encode = ((e>>5)<<16) | ((e&0x1f)<<5);
    return 1;
}


#ifdef DASM_CHECKS
#define CK(x, st) \
  do { if (!(x)) { \
    D->status = DASM_S_##st|(p-D->actionlist-1); return; } } while (0)
#define CKPL(kind, st) \
  do { if ((size_t)((char *)pl-(char *)D->kind##labels) >= D->kind##size) { \
    D->status = DASM_S_RANGE_##st|(p-D->actionlist-1); return; } } while (0)
#else
#define CK(x, st)        ((void)0)
#define CKPL(kind, st)        ((void)0)
#endif

/* Pass 1: Store actions and args, link branches/labels, estimate offsets. */
void dasm_put(Dst_DECL, int start, ...) {
    va_list ap;
    dasm_State *D = Dst_REF;
    dasm_ActList p = D->actionlist + start;
    dasm_Section *sec = D->section;
    int pos = sec->pos, ofs = sec->ofs;
    int *b;

    if (pos >= sec->epos) {
        DASM_M_GROW(Dst, int, sec->buf, sec->bsize,
                    sec->bsize + 2*DASM_MAXSECPOS*sizeof(int));
        sec->rbuf = sec->buf - DASM_POS2BIAS(pos);
        sec->epos = (int)sec->bsize/sizeof(int) - DASM_MAXSECPOS
                    + DASM_POS2BIAS(pos);
    }

    b = sec->rbuf;
    b[pos++] = start;

    va_start(ap, start);
    while (1) {
        unsigned int ins = *p++;
        unsigned int action = (ins >> 16);
        int *pl;
        long l;
        int n;

        if (action >= DASM__MAX) {
            ofs += 4;
            continue;
        }

        l = action >= DASM_REL_PC ? va_arg(ap, long) : 0;
        n = (int)l;

        switch (action) {
            case DASM_STOP: goto stop;
            case DASM_SECTION:
                n = (ins & 255); CK(n < D->maxsection, RANGE_SEC);
                D->section = &D->sections[n]; goto stop;
            case DASM_ESC: p++; ofs += 4; break;
            case DASM_REL_EXT: break;
            case DASM_ALIGN: ofs += (ins & 255); b[pos++] = ofs; break;
            case DASM_REL_LG:
                n = (ins & 2047) - 10; pl = D->lglabels + n;
                /* Bkwd rel or global. */
                if (n >= 0) { CK(n>=10||*pl<0, RANGE_LG); CKPL(lg, LG); goto putrel; }
                pl += 10; n = *pl;
                if (n < 0) n = 0;  /* Start new chain for fwd rel if label exists. */
                goto linkrel;
            case DASM_REL_PC:
                pl = D->pclabels + n; CKPL(pc, PC);
            putrel:
                n = *pl;
                if (n < 0) {  /* Label exists. Get label pos and store it. */
                    b[pos] = -n;
                } else {
            linkrel:
                    b[pos] = n;  /* Else link to rel chain, anchored at label. */
                    *pl = pos;
                }
                pos++;
                break;
            case DASM_LABEL_LG:
                pl = D->lglabels + (ins & 2047) - 10; CKPL(lg, LG); goto putlabel;
            case DASM_LABEL_PC:
                pl = D->pclabels + n; CKPL(pc, PC);
            putlabel:
                n = *pl;  /* n > 0: Collapse rel chain and replace with label pos. */
                while (n > 0) { int *pb = DASM_POS2PTR(D, n); n = *pb; *pb = pos;
                }
                *pl = -pos;  /* Label exists now. */
                b[pos++] = ofs;  /* Store pass1 offset estimate. */
                break;
            case DASM_IMM:
    #ifdef DASM_CHECKS
                CK((n & ((1<<((ins>>10)&31))-1)) == 0, RANGE_I);
                if ((ins & 0x8000))
                    CK(((n + (1<<(((ins>>5)&31)-1)))>>((ins>>5)&31)) == 0, RANGE_I);
                else
                    CK((n>>((ins>>5)&31)) == 0, RANGE_I);
    #endif  
                b[pos++] = ((n>>((ins>>10)&31)) & ((1<<((ins>>5)&31))-1)) << (ins&31);
                break;
            case DASM_IMMADDROFF:
                if ((n>=-256 && n < 0) || (n <= 255 && (n & ((1<<((ins>>10)&31))-1)) != 0))
                    b[pos++] = 1 | ((n & ((1<<9)-1)) << 12);
                else
                    b[pos++] = ((n>>((ins>>10)&31)) & ((1<<12)-1)) << 10;
                break;
            case DASM_IMMNSR: {   /**may be 64 bit */
                int ok;
                unsigned int encode;
                CK((ins&0xffff)<=1, RANGE_I);
                ok = getnsrencode(l, ins&1, &encode);
                CK(ok, RANGE_I);
                b[pos++] = encode;
                break;
            }
            case DASM_IMMLSB: {    /* immr. 0~31 or 0~63 */
                int max;
                CK((ins&0xffff)<=1, RANGE_I);
                max = (ins&1) ? 63 : 31;
                CK(n>=0 && n<=max, RANGE_I);
                b[pos++] = (((unsigned int)-n) & max) << 16;
                break;
            }            
            case DASM_IMMWIDTH1: { /* imms. <immr, 1~32-lsb or 1~64-lsb */
                int max;
                CK((ins&0xffff)<=1, RANGE_I);
                max = (ins&1) ? 63 : 31;
                CK(n-1>=0 && n-1<(b[pos-1]>>16), RANGE_I);
                b[pos++] = ((n-1) & max) << 10;
                break;
            }
            case DASM_IMMWIDTH2: { /* imms. >= immr, 1~32-lsb or 1~64-lsb */
                int max, imms, immr;
                CK((ins&0xffff)<=1, RANGE_I);
                max = (ins&1) ? 63 : 31;
                immr = (b[pos-1]>>16);
                imms = immr + n - 1;
                CK(imms>=immr && imms <= max, RANGE_I);
                b[pos++] = (imms & max) << 10;
                break;
            }
            case DASM_IMMSHIFT: { /* 0~31 or 0~63 */
                int max;
                CK((ins&0xffff)<=1, RANGE_I);
                max = (ins&1) ? 63 : 31;
                CK(n >= 0 && n <= max, RANGE_I);
                b[pos++] = (((-n & max)<<16) | (((max-n)&max)<<10));
                break;
            }
            case DASM_IMMMOV: {   /**may be 64 bit */
                unsigned int encode;
                CK((ins&0xffff)<=1, RANGE_I);
                if (wide_imm(l, ins&1, &encode))
                    b[pos++] = encode|0x52800000;
                else if(wide_imm(~l, ins&1, &encode) &&
                    !((ins&1)==0 && (l==0xffff0000 || l==0x0000ffff)))
                    b[pos++] = encode|0x12800000;
                else if (getnsrencode(l, ins&1, &encode))
                    b[pos++] = encode|0x32000000;
                else
                    CK(0, RANGE_I);
                break;
            }
            case DASM_IMMTBN:    /* 0~63 */
                CK((ins&0xffff)<=1, RANGE_I);
                CK(((ins&1) && n>=32 && n<=63) ||
                   (!(ins&1) && n>=0 && n<=31), RANGE_I);
                b[pos++] = (n&0x1f) << 19;
                break;
            case DASM_IMMA2H:    /* 0~255 */
                CK(n>=0 && n<=255, RANGE_I);
                b[pos++] = ((n>>5)<<16) | ((n&0x1f)<<5);
                break;
            case DASM_IMMA2H64: { /**64 bit */
                int ok;
                unsigned int encode;
                ok = a2h64_imm(l, &encode);
                CK(ok, RANGE_I);
                b[pos++] = encode;
                break;
            }
            case DASM_IMMA2HFP:{  /* floating point number */
                unsigned int s = (unsigned int)(l>>63);
                unsigned int e = (unsigned int)((l>>52) & 0x7ff);
                unsigned int sig = (unsigned int)((l>>48) & 0xf);
                CK(((e&0x400)&&!(e&0x3fc))||(!(e&0x400)&&((e&0x3fc)==0x3fc)), RANGE_I);
                b[pos++] = (s<<18) |               /* a */
                           ((e>>10)<<17) |         /* b */
                           (((e>>1)&1)<<16) |      /* c */
                           ((e&1)<<9) |            /* d */
                           (sig<<5);                 /* efgh */
                break;
            }
            case DASM_IMM8FP:{    /* floating point number */
                unsigned int s = (unsigned int)(l>>63);
                unsigned int e = (unsigned int)((l>>52) & 0x7ff);
                unsigned int sig = (unsigned int)((l>>48) & 0xf);
                CK(((e&0x400)&&!(e&0x3fc))||(!(e&0x400)&&((e&0x3fc)==0x3fc)), RANGE_I);
                b[pos++] = (s<<20) |        /* a */
                           ((e>>10)<<19) |  /* b */
                           ((e&3)<<17) |    /* cd */
                           (sig<<13);         /* efgh */
                break;
            }
            case DASM_IMMHLM: {   /* 0 ~ 7 */
                unsigned int encode = 0;
                int bits = (ins&0xffff);
                CK(bits>=1 && bits <=3 && n >= 0 && n < (1<<bits), RANGE_I);
                if (bits == 3)
                    encode = (((n>>2)&1)<<11) | ((n&3)<<20);
                else if (bits == 2)
                    encode = (((n>>1)&1)<<11) | ((n&1)<<21);
                else if (bits == 1)
                    encode = (n&1)<<11;
                b[pos++] = encode;
                break;
            }
            case DASM_IMMQSS: {   /* 0 ~ 15 */
                unsigned int encode = 0;
                int bits = (ins&0xffff);
                CK(bits>=1 && bits <=4 && n >= 0 && n < (1<<bits), RANGE_I);
                if (bits == 4)
                    encode = (((n>>3)&1)<<30) | ((n&7)<<10);
                else if (bits == 3)
                    encode = (((n>>2)&1)<<30) | ((n&3)<<11);
                else if (bits == 2)
                    encode = (((n>>1)&1)<<30) | ((n&1)<<12);
                else if (bits == 1)
                    encode = (n&1)<<30;
                b[pos++] = encode;
                break;
            }
            case DASM_IMMHB: {    /* 1~64 */
                unsigned int max;
                int bits = (ins&0xffff);
                CK(bits>=3 && bits<=6 && n>=1 && n<=(1<<bits), RANGE_I);
                max = (1<<bits);
                b[pos++] = ((max-n)&(max-1)) << 16;
                break;
            }
            case DASM_IMMSCALE: { /* 1~32 or 1~64 */
                unsigned int max;
                CK((ins&0xffff)<=1, RANGE_I);
                max = (ins&1) ? 64 : 32;
                CK(n>=1 && n<=max, RANGE_I);
                b[pos++] = ((max-n)&(max-1))<<10;
                break;
            }
        }
    }
stop:
    va_end(ap);
    sec->pos = pos;
    sec->ofs = ofs;
}
#undef CK

/* Pass 2: Link sections, shrink aligns, fix label offsets. */
int dasm_link(Dst_DECL, size_t *szp)
{
  dasm_State *D = Dst_REF;
  int secnum;
  int ofs = 0;

#ifdef DASM_CHECKS
  *szp = 0;
  if (D->status != DASM_S_OK) return D->status;
  {
    int pc;
    for (pc = 0; pc*sizeof(int) < D->pcsize; pc++)
      if (D->pclabels[pc] > 0) return DASM_S_UNDEF_PC|pc;
  }
#endif

  { /* Handle globals not defined in this translation unit. */
    int idx;
    for (idx = 20; idx*sizeof(int) < D->lgsize; idx++) {
      int n = D->lglabels[idx];
      /* Undefined label: Collapse rel chain and replace with marker (< 0). */
      while (n > 0) { int *pb = DASM_POS2PTR(D, n); n = *pb; *pb = -idx; }
    }
  }

  /* Combine all code sections. No support for data sections (yet). */
  for (secnum = 0; secnum < D->maxsection; secnum++) {
    dasm_Section *sec = D->sections + secnum;
    int *b = sec->rbuf;
    int pos = DASM_SEC2POS(secnum);
    int lastpos = sec->pos;

    while (pos != lastpos) {
      dasm_ActList p = D->actionlist + b[pos++];
      while (1) {
        unsigned int ins = *p++;
        unsigned int action = (ins >> 16);
        switch (action) {
        case DASM_STOP: case DASM_SECTION: goto stop;
        case DASM_ESC: p++; break;
        case DASM_REL_EXT: break;
        case DASM_ALIGN: ofs -= (b[pos++] + ofs) & (ins & 255); break;
        case DASM_REL_LG: case DASM_REL_PC: pos++; break;
        case DASM_LABEL_LG: case DASM_LABEL_PC: b[pos++] += ofs; break;
        case DASM_IMM:
        case DASM_IMMADDROFF:
        case DASM_IMMNSR:    /**may be 64 bit */
        case DASM_IMMLSB:    /* 0~31 or 0~63 */
        case DASM_IMMWIDTH1: /* 1~32-lsb or 1~64-lsb */
        case DASM_IMMWIDTH2: /* 1~32-lsb or 1~64-lsb */
        case DASM_IMMSHIFT:  /* 0~31 or 0~63 */
        case DASM_IMMMOV:    /**may be 64 bit */
        case DASM_IMMTBN:    /* 0~63 */
        case DASM_IMMA2H:    /* 0~255 */
        case DASM_IMMA2H64:  /**64 bit */
        case DASM_IMMA2HFP:  /* floating point number */
        case DASM_IMM8FP:    /* floating point number */
        case DASM_IMMHLM:    /* 0 ~ 7 */
        case DASM_IMMQSS:    /* 0 ~ 15 */
        case DASM_IMMHB:     /* 1~64 */
        case DASM_IMMSCALE:  /* 1~32 or 1~64 */
            pos++; break;
        }
      }
      stop: (void)0;
    }
    ofs += sec->ofs;  /* Next section starts right after current section. */
  }

  D->codesize = ofs;  /* Total size of all code sections */
  *szp = ofs;
  return DASM_S_OK;
}


#ifdef DASM_CHECKS
#define CK(x, st) \
  do { if (!(x)) return DASM_S_##st|(p-D->actionlist-1); } while (0)
#else
#define CK(x, st)        ((void)0)
#endif

/* Pass 3: Encode sections. */
int dasm_encode(Dst_DECL, void *buffer)
{
  dasm_State *D = Dst_REF;
  char *base = (char *)buffer;
  unsigned int *cp = (unsigned int *)buffer;
  int secnum;

  /* Encode all code sections. No support for data sections (yet). */
  for (secnum = 0; secnum < D->maxsection; secnum++) {
    dasm_Section *sec = D->sections + secnum;
    int *b = sec->buf;
    int *endb = sec->rbuf + sec->pos;

    while (b != endb) {
      dasm_ActList p = D->actionlist + *b++;
      while (1) {
        unsigned int ins = *p++;
        unsigned int action = (ins >> 16);
        long n = (action >= DASM_ALIGN && action < DASM__MAX) ? *b++ : 0;
        switch (action) {
        case DASM_STOP: case DASM_SECTION: goto stop;
        case DASM_ESC: *cp++ = *p++; break;
        case DASM_REL_EXT:
          n = DASM_EXTERN(Dst, (unsigned char *)cp, (ins&2047), !(ins&2048));
          goto patchrel;
        case DASM_ALIGN:
          ins &= 255; while ((((char *)cp - base) & ins)) *cp++ = 0xe1a00000;
          break;
        case DASM_REL_LG:
          CK(n >= 0, UNDEF_LG);
        case DASM_REL_PC:
          CK(n >= 0, UNDEF_PC);
          n = *DASM_POS2PTR(D, n) - (int)((char *)cp - base) + 4;
        patchrel:
          if ((ins & 0xf000) == 0) { //page label21 in [5:23]:[29:30] -4G ~ 4G
            long n1 = (n >> 12);
            CK((n&0xfff) == 0 && -0x100000 < n1 && n1 < 0x100000, RANGE_REL);
            cp[-1] |= (((n1&3)<<29) | (((n1>>2)&0x7ffff)<<5));
          } else if ((ins & 0xf000) == 0x1000) { //byte label21 in [5:23]:[29:30] -1M ~ 1M
            CK(-0x100000 < n && n < 0x100000, RANGE_REL);
            cp[-1] |= (((n&3)<<29) | (((n>>2)&0x7ffff)<<5));
          } else if ((ins & 0xf000) == 0x2000) { //word label14 in [5:18] -32K ~ 32K
            CK((n & 3) == 0 && -0x8000 < n && n < 0x8000, RANGE_REL);
            cp[-1] |= (((n>>2)&0x7fff)<<5);
          } else if ((ins & 0xf000) == 0x3000) { // word label19 in [5:23] -1M ~ 1M
            CK((n&3) == 0 && n>-0x100000 && n < 0x100000, RANGE_REL);
            cp[-1] |= (((n>>2)&0x7ffff)<<5);
          } else { //word label26 in [0:25] -128M ~ 128M
            CK((n&3) == 0 && n>-0x8000000 && n < 0x8000000, RANGE_REL);
            cp[-1] |= ((n>>2)&0x03ffffff);
          }
          break;
        case DASM_LABEL_LG:
          ins &= 2047; if (ins >= 20) D->globals[ins-10] = (void *)(base + n);
          break;
        case DASM_LABEL_PC: break;
        case DASM_IMMADDROFF:
          if (n&1 == 1) cp[-1] &= 0xfeffffff;
          cp[-1] |= (n & ~1);
          break;
        case DASM_IMM:
        case DASM_IMMNSR:    /**may be 64 bit */
        case DASM_IMMLSB:    /* 0~31 or 0~63 */
        case DASM_IMMWIDTH1: /* 1~32-lsb or 1~64-lsb */
        case DASM_IMMWIDTH2: /* 1~32-lsb or 1~64-lsb */
        case DASM_IMMSHIFT:  /* 0~31 or 0~63 */
        case DASM_IMMMOV:    /**may be 64 bit */
        case DASM_IMMTBN:    /* 0~63 */
        case DASM_IMMA2H:    /* 0~255 */
        case DASM_IMMA2H64:  /**64 bit */
        case DASM_IMMA2HFP:  /* floating point number */
        case DASM_IMM8FP:    /* floating point number */
        case DASM_IMMHLM:    /* 0 ~ 7 */
        case DASM_IMMQSS:    /* 0 ~ 15 */
        case DASM_IMMHB:     /* 1~64 */
        case DASM_IMMSCALE:  /* 1~32 or 1~64 */
          cp[-1] |= n;
          break;
        default: *cp++ = ins; break;
        }
      }
      stop: (void)0;
    }
  }

  if (base + D->codesize != (char *)cp)  /* Check for phase errors. */
    return DASM_S_PHASE;
  return DASM_S_OK;
}
#undef CK

/* Get PC label offset. */
int dasm_getpclabel(Dst_DECL, unsigned int pc)
{
  dasm_State *D = Dst_REF;
  if (pc*sizeof(int) < D->pcsize) {
    int pos = D->pclabels[pc];
    if (pos < 0) return *DASM_POS2PTR(D, -pos);
    if (pos > 0) return -1;  /* Undefined. */
  }
  return -2;  /* Unused or out of range. */
}

#ifdef DASM_CHECKS
/* Optional sanity checker to call between isolated encoding steps. */
int dasm_checkstep(Dst_DECL, int secmatch)
{
  dasm_State *D = Dst_REF;
  if (D->status == DASM_S_OK) {
    int i;
    for (i = 1; i <= 9; i++) {
      if (D->lglabels[i] > 0) { D->status = DASM_S_UNDEF_LG|i; break; }
      D->lglabels[i] = 0;
    }
  }
  if (D->status == DASM_S_OK && secmatch >= 0 &&
      D->section != &D->sections[secmatch])
    D->status = DASM_S_MATCH_SEC|(D->section-D->sections);
  return D->status;
}
#endif

