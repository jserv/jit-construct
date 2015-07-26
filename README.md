# Interpreter, Compiler, JIT
This repository contains the programs used in Nick Desaulniers' [blog post](https://nickdesaulniers.github.io/blog/2015/05/25/interpreter-compiler-jit/); an interpreter, a compiler, and a Just In Time (JIT) compiler for the brainfuck language.  It is meant to show how similar these techniques are, and then improved by several students who learnt system programming to bring X86/ARM backend along with [DynASM](http://luajit.org/dynasm.html) support.

###Portability
While all three are written in C, only the interpreter should be portable, even to emscripten.  The compiler and JIT is highly dependant on the specific Instruction Set Architecture (ISA), and Linux style calling convention.

##Building
```
make
```

##Running
###The Interpreter
```
./interpreter progs/hello.bf
```

###The Compiler
```
make hello
```

###The JIT
```
make run-jit-x64
make run-jit-arm
make bench-jit-x64
```

##License

_Except_ the code in `progs/` and `dynasm/`, the JIT-Construct source files are distributed
BSD-style license found in the LICENSE file.

External sources:
* [DynASM](http://luajit.org/dynasm.html) is a tiny preprocessor and runtime for generating machine code at runtime and copyrighted by Mike Pall, released under the MIT license.
* `progs/mandelbrot.b` is a mandelbrot set fractal viewer in brainfuck written by Erik Bosman.
* `progs/sierpinski.b` is written by [NYYRIKKI](http://www.iwriteiam.nl/Ha_vs_bf_inter.html).
* `progs/awib.b` is written by [Mats Linander](https://github.com/matslina/awib).
* `progs/hanoi.b` is written by [Clifford Wolf](http://www.clifford.at/bfcpu/hanoi.html).
