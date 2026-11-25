# Sexpr.jl — s-expressions ⇄ Julia

Sexpr reads Clojure-flavoured s-expressions and produces Julia expressions, and
turns Julia expressions back into s-expressions. It is a port of
[Sexpr.jl](https://github.com/vshesh/Sexpr.jl) by **Vishesh Gupta**, originally
written for Julia 0.4. The original project is his: the s-expression dialect,
the special-form vocabulary and the `sjulia` command-line interface all come
from it. This port rewrites the reader, printer and CLI for modern Julia and
adds a number of previously missing forms.

* Works on Julia 1.6 and later (tested on 1.6.7, 1.10.14, 1.12.7 and 1.13.4).
* No external dependencies — only the standard library.
* Both directions: s-expression → Julia **and** Julia → s-expression.
* Source positions in every parse error.

```julia
julia> using Sexpr

julia> transpile("(defn add [a b] (+ a b))") |> only |> format |> print
function add(a, b)
    a + b
end

julia> print(detranspile("function add(a, b)\n    a + b\nend"))
(defn add [a b] (+ a b))
```

## Quick start

```julia
julia> using Sexpr

julia> transpile_expr("(if (> x 0) x (- x))")
:(if x > 0
      x
  else
      -x
  end)

julia> eval(clj"(+ 1 2)")      # compile at macro-expansion time
3
```

The package can be used from the REPL with `julia --project=path/to/Sexpr.jl`,
or installed with `Pkg.develop(path="path/to/Sexpr.jl")`.

## API

| function | meaning |
| --- | --- |
| `transpile(source)::Vector{Any}` | all top-level forms of an s-expression program as Julia expressions |
| `transpile_expr(source)` | a single form (wrapped in a `block` if the source has several) |
| `format(expr)::String` | pretty-print a Julia expression as source code |
| `detranspile(source_or_expr)::String` | Julia source/`Expr` → s-expression source |
| `to_sexpr(x)` | Julia value/`Expr` → s-expression data (`SList`, `SVec`, `SMap`, `SSet`, `SSym`, `SKeyword`) |
| `print_sexp(data; width=88)` | render s-expression data as source text |
| `rehydrate(data)` | s-expression data → Julia `Expr` (for macros) |
| `@clj_str` / `clj"..."` | compile s-expression source at macro-expansion time |
| `set_ascii_names!(flag)` | switch symbol escaping between Unicode and ASCII |
| `main(args=ARGS)` | command-line entry point; returns an exit code |

`transpile` accepts several forms and returns one expression per form:

```julia
julia> transpile("(def x 1)\n(defn f [] x)")
2-element Vector{Any}:
 :(x = 1)
 :(function f()
       x
   end)
```

## Command line

```console
$ julia --project=. bin/sjulia -h
usage: sjulia [-i] [-c] [-l LINES] [-o OUTPUT] [-e EXTENSION] [-h] [files...]

$ julia --project=. bin/sjulia program.clj        # Julia to stdout
$ julia --project=. bin/sjulia -i program.jl      # s-expression to stdout
$ julia --project=. bin/sjulia -o out/ src/       # whole directories
```

`-i/--invert` flips the direction, `-c/--cat` reads STDIN, `-l/--lines` sets
the blank lines between top-level forms, `-o/--output` chooses the output
directory, and `-e/--extension` adds extensions to treat as source files.
Errors are reported with line and column and give a nonzero exit code.

## Syntax

### Atoms

| s-expression | Julia |
| --- | --- |
| `nil`, `true`, `false` | `nothing`, `true`, `false` |
| `42`, `-7` | `Int` (widening to `Int128`/`BigInt`) |
| `0xff`, `0x01ff`, `0b1010`, `0o17`, `16r1ef`, `12N` | hex, binary, octal, radix and `BigInt`; the width picks the type as in Julia (`0xff` is a `UInt8`, `0x01ff` a `UInt16`) |
| `1.5`, `1e3`, `1.5e-3` | `Float64` |
| `3/5` | `3//5` |
| `"text"`, `"a\nb"` | strings with escapes and embedded newlines |
| `\a`, `\newline`, `\space`, `\tab`, `\u03bb`, `\o101` | characters |
| `:foo`, `:ns/name` | keywords (`QuoteNode`), namespaces become `foo.bar` |
| `symbol`, `foo/bar`, `Base.show` | symbols / dotted access |
| `x::Int`, `x::Int::Float64` | type annotation / union |
| `xs...` | splat |

Comments run from `;` to the end of the line. Commas count as whitespace, as in
Clojure. `#_ form` discards the next form.

### Collections

| syntax | Julia |
| --- | --- |
| `(f a b)` | call |
| `[1 2 3]` | `[1, 2, 3]` |
| `{:a 1 :b 2}` | `Dict(:a => 1, :b => 2)` |
| `#{1 2 3}` | `Set([1, 2, 3])` |
| `'(a b)`, `` `(f ~x) `` | quoted expression data |

### Special forms

| form | Julia |
| --- | --- |
| `(do a b)` | `begin a; b end` |
| `(if c t e?)`, `(when c body…)`, `(when-not c body…)`, `(cond t1 e1 :else e2)` | conditionals |
| `(let [a 1 b 2] body…)` | `let a = 1, b = 2 … end`; runtime-built bindings keep `(let (do …) body…)` |
| `(def x v)`, `(const x v)` | assignment / `const` |
| `(fn [x] body…)`, `(fn name [x] body…)` | anonymous function / named function |
| `(fn (where [x] T) body…)` | anonymous function with type parameters |
| `(defn name [x] body…)`, `(defn- …)` | function definition |
| `(defn name "doc" [x] body…)` | function with docstring |
| `(defn (returns f T) [x] body…)` | function with a return type |
| `(defn (:: f T) [x] body…)` | typed callable object |
| `(defn (where f T) [x::T] body…)` | function with type parameters |
| `(defn (where (returns f T) T) [x::T] body…)` | nested type parameters and return type |
| `(defn (call (where (curly A T) T)) [x] body…)` | method of a callable type, which keeps its own parameters |
| `(defmacro name [x] body…)` | macro definition |
| `(deftype Name [fields…] body…)`, `(defmutable …)` | `struct` / `mutable struct` |
| `(deftype (curly Name T) [fields…])` | parametric struct |
| `(deftype (<: (curly Name T) Super) [fields…])` | parametric struct with supertype |
| `(for [x xs] body…)`, `(doseq …)` | loop |
| `(while c body…)` | while loop |
| `(try body… (catch e h…) (finally c…))` | exception handling; `(catch false h…)` is a `catch` with no variable |
| `(throw e)`, `(return x)`, `(break)`, `(continue)` | control flow |
| `(and a b)`, `(or a b)`, `(&& …)`, `(|| …)` | short-circuit operators |
| `(aget a i j)`, `(aset! a i v)` | indexing / indexed assignment |
| `(tuple 1 2)` | `(1, 2)`; a `tuple(1, 2)` call reads the same |
| `(: a b)` | `a:b` range |
| `(curly Array Int)` | `Array{Int}` |
| `(:: x T1 T2)` | `x::Union{T1, T2}` |
| `(. obj field)`, `(. obj (method a))`, `(.method obj a)` | property access / method call |
| `(broadcast f x y)` | `f.(x, y)` |
| `(comprehension [x xs] e)`, `(generator …)` | comprehensions |
| `(module Name body…)`, `(baremodule …)`, `(import …)`, `(use …)`, `(export …)`, `(public …)` | modules and declarations |
| `(-> x (f a) g)`, `(->> x (f a) g)` | thread-first / thread-last |
| `(kw name value)`, `(parameters …)`, `(splat x)`, `(do-call f g)` | low-level call structure |
| `(@macro args…)` | macro call (the `@` is required) |

Parameter vectors support defaults, varargs, type annotations and
destructuring:

```clojure
(defn greet [(name "world")] (str "hello " name))   ; default argument
(defn total [& xs] (+ xs...))                       ; varargs
(defn fst   [[a b]] a)                              ; destructuring
(defn typed [x::Int y::Float64] (+ x y))            ; types
(defn pat   [(:: (tuple a b) Tuple{Int,Int})] a)    ; typed destructuring
```

### Low-level and round-trip forms

Two Julia nodes have no high-level spelling of their own, so the reader accepts
one form per AST head and the writer emits that same spelling back:

| form | Julia |
| --- | --- |
| `(toplevel form…)` | `Expr(:toplevel, …)`: the statements of one `;`-joined line |
| `(macrocall name args…)` | a macro whose name is not one `@…` atom, e.g. a computed or interpolated name |

The remaining low-level spellings are listed with the forms they modify:
`(catch false body…)` under `try`, `(call (where …))` under `defn`, and
`(fn (where [params] T…) body…)` under `fn`. A colon call whose arguments
carry annotations keeps Julia's functional spelling, `(:)(::Any, ::Any)`, since
`::Any:::Any` parses back as chained type annotations.

```clojure
(toplevel (def a 1) (call g))                     ; a :toplevel node, cf. `a = 1; g()`
(try (f) (catch false (g)))                       ; try f() catch; g() end
(defn (call (where (curly Array T) T)) [x] x)     ; (Array{T} where T)(x) = x
(fn (where [(:: xs (curly Vararg Any N))] N) xs)  ; function (xs::Vararg{Any,N},) where N; xs; end
```

A `:toplevel` node is what a `;`-joined line parses into, so `transpile` accepts
`(toplevel …)` and `to_sexpr` writes it. The text API keeps file semantics,
though: `detranspile` unfolds the node into its separate top-level forms, and a
single-element one is just that form. `format` is what preserves the node — it
prints `a = 1; g();`, which parses back into `Expr(:toplevel, …)`. A macro name
that *can* be written as one `@` atom keeps the short spelling, as in
`(@Base.@inline x)`; `(macrocall …)` is for computed names such as
`(macrocall (. (unquote m) @foo) x)`.

## Macros and quoting

`defmacro` defines an ordinary Julia macro. A syntax-quote (backtick) builds
the returned code; `~` inserts caller code and automatically applies `esc`, so
macro hygiene works the way Clojure users expect:

```clojure
(defmacro twice [x] `(+ ~x ~x))

(defn quad [a] (@twice (@twice a)))     ; quad(2) == 8
```

Quoting follows Julia's model rather than Clojure's cons cells:

* `'x` and `:x` are the symbol `x`;
* `'(a b)` is the *expression* `a(b)` quoted, i.e. `:(a(b))`;
* `` `(f ~x) `` is ``:(f($(esc(x))))``;
* `~x` is Julia's interpolation node `$(x)` in any quote; only a
  syntax-quote adds `esc`, and `~x` also works in raw `@eval` code.

`rehydrate` converts s-expression data built at runtime back into expressions:

```julia
julia> rehydrate((:if, :c, 1, 2))
:(if c
      1
  else
      2
  end)

julia> rehydrate(Sexpr.SList(Sexpr.SSym("+"), 1, 2))
:(1 + 2)
```

Lists can be written as `SList` or tuples, vectors as `SVec` or `Vector`, maps as
`SMap` or `Dict`, sets as `SSet` or `Set`, and symbols as `SSym` or `Symbol`.

## Julia → s-expressions

`detranspile` handles the forms above plus common Julia constructs: `where`
clauses, short-form function definitions, string interpolation, chained
comparisons, keyword arguments, `do` blocks, comprehensions, `const`, and
`import`/`using`. Arguments of `function f(x)::T` are preserved as `f::T`.
Constructs that only a low-level form covers keep that spelling; see
*Low-level and round-trip forms* below.

```julia
julia> print(detranspile("""
       struct Point
           x::Float64
           y::Float64
       end
       """))
(deftype Point [x::Float64 y::Float64])
```

Julia constructs with no natural s-expression spelling (for example
`ccall`) fall back to a generic `(head args…)` call form rather than being
silently dropped.

## Symbol names

Clojure allows characters that Julia does not (`?`, `!`, `*`, `-`, …). By
default they are encoded as Unicode lookalikes, which keeps names readable:

| Clojure | Julia (default) | Julia (ASCII mode) |
| --- | --- | --- |
| `empty?` | `emptyʔ` | `empty_q` |
| `foo-bar` | `foo¯bar` | `foo_dbar` |
| `foo*` | `foo°` | `foo_s` |

```julia
julia> format(transpile_expr("(defn empty? [xs] xs)"))
"function emptyʔ(xs)\n    xs\nend"

julia> set_ascii_names!(true);

julia> format(transpile_expr("(defn empty? [xs] xs)"))
"function empty_q(xs)\n    xs\nend"
```

`detranspile` reverses whichever mode is active.

## Changes from the Julia 0.4 release

* Runs on Julia 1.6+ instead of 0.4; the parser, reader, writer and printer were
  rewritten for the modern AST (e.g. `LineNumberNode`-free output, `:struct`,
  `:where`, `:let` binding order, `Expr(:call, :(:), …)` ranges).
* `detranspile` returns s-expression **source text** instead of an internal
  nested-tuple structure; use `to_sexpr` if you want the data tree.
* Quoted lists are quoted expressions, not tuples.
* Docstrings on `defn` are emitted as `Core.@doc` instead of being ignored.
* Macro calls still need the `@` prefix, but syntax-quote now interpolates
  hygienically.
* New forms: `try`/`catch`/`finally`, `for`/`doseq`/`while`, `deftype`/
  `defmutable`, `cond`/`when`/`when-not`, sets `#{}`, comprehensions, ranges,
  threading macros, varargs, defaults, parameter destructuring, `#_` discard,
  ASCII symbol escaping and `aset!`.
* Dropped the `ArgParse` and `FactCheck` dependencies; the CLI and test suite
  use only the standard library.
* Errors are a small typed hierarchy (`SexprError` and subtypes) that always
  report line and column.

## Limitations

* No `loop`/`recur`: Clojure's immutable loop has no direct Julia equivalent.
* No multi-arity `defn`; use optional arguments or separate methods.
* No reader metadata (`^`), auto-gensym (`name#`) or reader conditionals.
* `where` clauses are supported in function signatures, named or anonymous,
  not on arbitrary expressions.
* Reader macros are limited to the forms listed above; `#(...)`, `@(...)` and
  other dispatch forms are rejected with an error.
* Julia's printer (`Base.show_unquoted`) is used for output, so indentation is
  Julia's four-space style rather than Clojure's.

## Development

```console
$ julia --project=. -e 'using Pkg; Pkg.test()'
```

The test suite covers both directions, round-trips, evaluated semantics, macro
expansion, symbol escaping and the CLI. It runs green on Julia 1.6.7, 1.10.14,
1.12.7 and 1.13.4.

## Credits and license

The original [Sexpr.jl](https://github.com/vshesh/Sexpr.jl) is by **Vishesh
Gupta**. This port keeps its s-expression dialect and its `sjulia` interface and
rewrites the implementation for Julia 1.6+.

The upstream project ships no license file, so no upstream terms are carried
over; the credit above is for the original work, not a license grant.

This port is licensed under the [MIT License](LICENSE), copyright (c) 2026
jawuku.
