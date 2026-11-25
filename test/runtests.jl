using Test
using Sexpr

# The AST equivalence rules (the documented lowerings) and the snippet corpus
# are shared with the standalone diagnostic `test/corpus.jl`, which stays a
# script: it is not run from here.
include(joinpath(@__DIR__, "roundtrip.jl"))

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

tr(src) = transpile_expr(src)

"Canonical source text of an expression, ignoring line metadata."
canon(ex) = format(Base.remove_linenums!(deepcopy(ex)))

"Evaluate every form of `src` in a fresh module that has Base available."
function eval_program(src)
    m = Module(gensym(:SexprTest))
    Core.eval(m, :(using Base))
    for ex in transpile(src)
        Core.eval(m, ex)
    end
    m
end

# ---------------------------------------------------------------------------
# atoms
# ---------------------------------------------------------------------------

@testset "atoms" begin
    @test tr("nil") === nothing
    @test tr("true") === true
    @test tr("false") === false

    @test tr("42") === 42
    @test tr("-7") === -7
    @test tr("0xff") == 0xff
    @test tr("0b1010") == 0b1010
    @test tr("0o17") == 0o17
    @test tr("2r1010") == 10
    @test tr("16r1ef1346bafdc") == 0x1ef1346bafdc
    @test tr("12N") == big(12)
    # a base-prefixed literal too wide for UInt64 is Julia's `@uint128_str`
    # call, which still prints and evaluates as the literal
    @test tr("0xb77e0a4cd29157a090e88db25a27a240") ==
          Base.remove_linenums!(Meta.parse("0xb77e0a4cd29157a090e88db25a27a240"))
    # beyond UInt128 Julia switches the builtin to `@big_str`
    @test tr("0xffffffffffffffffffffffffffffffffff") ==
          Base.remove_linenums!(Meta.parse("0xffffffffffffffffffffffffffffffffff"))
    @test format(tr("0xffffffffffffffffffffffffffffffffff")) ==
          "0xffffffffffffffffffffffffffffffffff"
    @test format(tr("0xb77e0a4cd29157a090e88db25a27a240")) ==
          "0xb77e0a4cd29157a090e88db25a27a240"
    @test detranspile("0xb77e0a4cd29157a090e88db25a27a240") ==
          "0xb77e0a4cd29157a090e88db25a27a240"
    @test tr("3/5") == 3 // 5
    @test tr("-3/5") == -3 // 5
    @test tr("1.5") === 1.5
    @test tr("1e3") === 1000.0
    @test tr("1.5e-3") === 0.0015

    @test tr("\"hello\"") == "hello"
    @test tr("\"a\\nb\"") == "a\nb"
    @test tr("\"tab\\there\"") == "tab\there"
    @test tr("\"quote\\\"inside\"") == "quote\"inside"

    @test tr("\\a") == 'a'
    @test tr("\\newline") == '\n'
    @test tr("\\space") == ' '
    @test tr("\\tab") == '\t'
    @test tr("\\u03bb") == 'λ'
    @test tr("\\o101") == 'A'

    @test tr(":foo") == QuoteNode(:foo)
    @test tr(":foo/bar") == QuoteNode(Symbol("foo.bar"))
    # keyword names are Julia symbols read verbatim, so operator names stay
    # operators and the `:` and empty symbols have their own spellings
    @test tr(":+=") == QuoteNode(Symbol("+="))
    @test tr(":-->") == QuoteNode(Symbol("-->"))
    @test tr(":<|") == QuoteNode(Symbol("<|"))
    @test tr(":¦") == QuoteNode(Symbol(":"))
    @test tr(":¦:") == QuoteNode(Symbol("::"))
    @test tr(":␀") == QuoteNode(Symbol(""))
    @test tr(":/=") == QuoteNode(Symbol("/="))
    @test detranspile(QuoteNode(Symbol("+="))) == ":+="
    @test detranspile(QuoteNode(Symbol(":"))) == ":¦"
    @test detranspile(QuoteNode(Symbol("::"))) == ":::"
    @test detranspile(QuoteNode(Symbol(""))) == ":␀"
    @test detranspile(QuoteNode(Symbol("hygienic-scope"))) == ":hygienic-scope"

    @test tr("x") === :x
    @test tr("foo/bar") == Expr(:., :foo, QuoteNode(:bar))
    @test tr("Base.show") == Expr(:., :Base, QuoteNode(:show))
    @test tr("x::Int") == Expr(:(::), :x, :Int)
    @test tr("x::Int::Float64") ==
          Expr(:(::), :x, Expr(:curly, :Union, :Int, :Float64))
    @test tr("xs...") == Expr(:..., :xs)

    # Clojure spellings of common functions
    @test tr("(= 1 1)") == Expr(:call, Symbol("=="), 1, 1)
    @test tr("(not x)") == Expr(:call, Symbol("!"), :x)
    @test tr("(not= a b)") == Expr(:call, Symbol("!="), :a, :b)
    @test tr("(str a b)") == Expr(:call, :string, :a, :b)
    @test tr("(map str xs)") == Expr(:call, :map, :string, :xs)
    @test tr(":str") == QuoteNode(:str)
    @test detranspile(":str") == ":str"
    @test tr("str") === :string
    @test tr(detranspile("str = 1")) == Expr(:(=), :str, 1)
end

# ---------------------------------------------------------------------------
# collections
# ---------------------------------------------------------------------------

@testset "collections" begin
    @test tr("[]") == Expr(:vect)
    @test tr("[1 2 3]") == Expr(:vect, 1, 2, 3)
    @test tr("(aget a 1 2)") == Expr(:ref, :a, 1, 2)
    @test tr("(aset! a 1 2)") == Expr(:(=), Expr(:ref, :a, 1), 2)

    @test tr("{:a 1 :b 2}") ==
          Expr(:call, :Dict,
               Expr(:call, :(=>), QuoteNode(:a), 1),
               Expr(:call, :(=>), QuoteNode(:b), 2))
    @test tr("#{1 2 3}") == Expr(:call, :Set, Expr(:vect, 1, 2, 3))
    @test tr("(set 1 2)") == Expr(:call, :Set, Expr(:vect, 1, 2))
    @test_throws Sexpr.InvalidFormCountError tr("{:a 1 :b}")

    @test tr("(tuple 1 2)") == Expr(:tuple, 1, 2)
    # a call to `tuple` shares that spelling and builds the same tuple
    @test detranspile("f(x) = tuple(x, 2x)") == "(defn f [x] (tuple x (* 2 x)))"
    @test tr(detranspile("f(x) = tuple(x, 2x)")) ==
          Expr(:function, Expr(:call, :f, :x),
               Expr(:block, Expr(:tuple, :x, Expr(:call, :*, 2, :x))))
    @test tr("(splat xs)") == Expr(:..., :xs)
    # a typed destructuring parameter keeps its tuple pattern: `(:: …)` reads
    # its name with the ordinary reader, not the `[…]` binding shorthand
    @test detranspile("f((a, b)::Tuple{Int,Int}) = a") ==
          "(defn f [(:: (tuple a b) (curly Tuple Int Int))] a)"
    @test tr("(defn f [(:: (tuple a b) T)] a)") ==
          Expr(:function, Expr(:call, :f, Expr(:(::), Expr(:tuple, :a, :b), :T)),
               Expr(:block, :a))
    @test tr("(defn f [(:: [1 2] T)] a)") ==
          Expr(:function, Expr(:call, :f, Expr(:(::), Expr(:vect, 1, 2), :T)),
               Expr(:block, :a))

    # quote keeps expressions as data
    @test tr("'x") == Expr(:quote, :x)
    @test tr("':x") == QuoteNode(:x)
    @test tr("'(a b)") == Expr(:quote, Expr(:call, :a, :b))
    @test tr("`(f ~x)") ==
          Expr(:quote, Expr(:call, :f, Expr(:$, Expr(:call, :esc, :x))))
    @test tr("~x") == Expr(:$, :x)
end

# ---------------------------------------------------------------------------
# special forms
# ---------------------------------------------------------------------------

@testset "special forms" begin
    @test tr("(if c 1 2)") == Expr(:if, :c, 1, 2)
    @test tr("(if c 1)") == Expr(:if, :c, 1)
    @test tr("(when c (f) (g))") ==
          Expr(:if, :c, Expr(:block, Expr(:call, :f), Expr(:call, :g)))
    @test tr("(when-not c (f))") ==
          Expr(:if, Expr(:call, :!, :c), Expr(:block, Expr(:call, :f)))

    @test tr("(cond a 1 b 2 :else 3)") ==
          Expr(:if, :a, 1, Expr(:if, :b, 2, 3))

    @test tr("(do (f) (g))") == Expr(:block, Expr(:call, :f), Expr(:call, :g))
    @test tr("(def x 1)") == Expr(:(=), :x, 1)
    @test tr("(const x 1)") == Expr(:const, Expr(:(=), :x, 1))
    @test tr("(def [a b] t)") == Expr(:(=), Expr(:tuple, :a, :b), :t)

    let ex = tr("(let [a 1 b 2] (+ a b))")
        @test ex.head == :let
        @test ex.args[1] == Expr(:block, Expr(:(=), :a, 1), Expr(:(=), :b, 2))
        @test ex.args[2] == Expr(:block, Expr(:call, :+, :a, :b))
    end
    # a bindings block built at run time has no `[lhs rhs]` pair spelling, so
    # it keeps its block structure instead of being dropped
    let ex = tr("(let (do (def a 1)) a)")
        @test ex.head == :let
        @test [x for x in ex.args[1].args if !(x isa LineNumberNode)] ==
              Any[Expr(:(=), :a, 1)]
    end
    let ex = tr("(let (do (unquote (splat xs))) 1)")
        @test [x for x in ex.args[1].args if !(x isa LineNumberNode)] ==
              Any[Expr(:$, Expr(:..., :xs))]
    end

    @test tr("(fn [x] (+ x 1))") ==
          Expr(:->, Expr(:tuple, :x), Expr(:block, Expr(:call, :+, :x, 1)))
    @test tr("(fn [x] (f x) (g x))").args[2].head == :block
    @test tr("(fn twice [x] (+ x x))") ==
          Expr(:function, Expr(:call, :twice, :x), Expr(:block, Expr(:call, :+, :x, :x)))

    # one-argument `::` parameters (anonymous typed arguments)
    @test tr("(defn f [(:: Int)] 1)") ==
          Expr(:function, Expr(:call, :f, Expr(:(::), :Int)), Expr(:block, 1))
    @test tr("(defn (:: (curly Type T)) [x] x)") ==
          Expr(:function,
               Expr(:call, Expr(:(::), Expr(:curly, :Type, :T)), :x),
               Expr(:block, :x))
    @test tr("(defn (:: f T) [x] x)") ==
          Expr(:function, Expr(:call, Expr(:(::), :f, :T), :x), Expr(:block, :x))
    @test tr("(defn (returns f Int) [x] x)") ==
          Expr(:function, Expr(:(::), Expr(:call, :f, :x), :Int), Expr(:block, :x))
    @test tr("(defn (where (returns f Int) T) [x] x)") ==
          Expr(:function,
               Expr(:where, Expr(:(::), Expr(:call, :f, :x), :Int), :T),
               Expr(:block, :x))
    @test tr("(defn f [(parameters (b 1)) a] a)") ==
          Expr(:function,
               Expr(:call, :f, Expr(:parameters, Expr(:kw, :b, 1)), :a),
               Expr(:block, :a))
    @test tr("(defn f [(parameters (& kwargs))] kwargs)") ==
          Expr(:function,
               Expr(:call, :f, Expr(:parameters, Expr(:..., :kwargs))),
               Expr(:block, :kwargs))
    @test tr("(f (parameters (splat kwargs)))") ==
          Expr(:call, :f, Expr(:parameters, Expr(:..., :kwargs)))
    @test tr("(defn f [(@nospecialize x)] x)").args[1].args[2].head == :macrocall

    # method-less function declarations
    @test tr("(defn show)") == Expr(:function, :show)
    @test format(tr("(defn show)")) == "function show end"

    # global/local declarations may hold assignments
    @test tr("(global (def x 1))") == Expr(:global, Expr(:(=), :x, 1))
    @test tr("(local (def y 2))") == Expr(:local, Expr(:(=), :y, 2))

    # plain quote interpolates without macro hygiene escaping
    @test tr("(quote (f (unquote x)))") ==
          Expr(:quote, Expr(:call, :f, Expr(:$, :x)))
    @test tr("(syntax-quote (f (unquote x)))") ==
          Expr(:quote, Expr(:call, :f, Expr(:$, Expr(:call, :esc, :x))))
    # unquote is Julia interpolation everywhere (used by `@eval`)
    @test tr("(unquote x)") == Expr(:$, :x)
    @test tr("(fn [x (y 1)] (+ x y))") ==
          Expr(:->, Expr(:tuple, :x, Expr(:(=), :y, 1)),
               Expr(:block, Expr(:call, :+, :x, :y)))
    @test tr("(fn [x & rest] rest)") ==
          Expr(:->, Expr(:tuple, :x, Expr(:..., :rest)), Expr(:block, :rest))
    @test tr("(fn [[a b]] a)") ==
          Expr(:->, Expr(:tuple, Expr(:tuple, :a, :b)), Expr(:block, :a))

    let ex = tr("(defn add [a b] (+ a b))")
        @test ex.head == :function
        @test ex.args[1] == Expr(:call, :add, :a, :b)
        @test ex.args[2] == Expr(:block, Expr(:call, :+, :a, :b))
    end
    @test tr("(defn add [a b] (+ a b))") ==
          Expr(:function, Expr(:call, :add, :a, :b),
               Expr(:block, Expr(:call, :+, :a, :b)))
    @test tr("(defn f [] 1)").args[1] == Expr(:call, :f)
    @test tr("(defn g::Int [x] x)").args[1] ==
          Expr(:(::), Expr(:call, :g, :x), :Int)

    let ex = tr("(defn foo \"docs\" [x] x)")
        @test ex.head == :macrocall
        @test ex.args[3] == "docs"
        @test ex.args[4].head == :function
    end

    let ex = tr("(defmacro twice [x] `(+ ~x ~x))")
        @test ex.head == :macro
        @test ex.args[1] == Expr(:call, :twice, :x)
    end

    @test tr("(deftype Point [x::Float64 y])") ==
          Expr(:struct, false, :Point,
               Expr(:block, Expr(:(::), :x, :Float64), :y))
    @test tr("(defmutable Point [x])") ==
          Expr(:struct, true, :Point, Expr(:block, :x))
    @test tr("(deftype (curly L T) [x::T])") ==
          Expr(:struct, false, Expr(:curly, :L, :T),
               Expr(:block, Expr(:(::), :x, :T)))
    @test tr("(deftype (<: (curly D K V) (curly AbstractDict K V)) [x])") ==
          Expr(:struct, false,
               Expr(:<:, Expr(:curly, :D, :K, :V),
                          Expr(:curly, :AbstractDict, :K, :V)),
               Expr(:block, :x))
    @test tr("(abstract (<: (curly Foo T) Bar))") ==
          Expr(:abstract, Expr(:<:, Expr(:curly, :Foo, :T), :Bar))
    # `A >: B` has its own AST head (Julia normalises the call spelling too)
    @test tr("(>: A B)") == Expr(:>:, :A, :B)
    @test format(tr("(>: A B)")) == "A >: B"
    @test tr(detranspile("A >: B")) == Expr(:>:, :A, :B)
    # the one-argument bound shorthand: Type{>:Nothing}
    @test tr(detranspile("Type{>:Nothing}")) == Meta.parse("Type{>:Nothing}")
    # xor-assignment keeps its own AST head (it is not lowered like `+=`)
    @test tr("(⊻= a b)") == Expr(:⊻=, :a, :b)
    @test format(tr("(⊻= a b)")) == "a ⊻= b"
    @test tr(detranspile("a ⊻= b")) == Expr(:⊻=, :a, :b)
    @test tr("(.⊻= a b)") == Expr(Symbol(".⊻="), :a, :b)
    @test tr("(primitive Foo 8)") == Expr(:primitive, :Foo, 8)

    @test tr("(for [x xs] (f x))") ==
          Expr(:for, Expr(:(=), :x, :xs), Expr(:block, Expr(:call, :f, :x)))
    let ex = tr("(for [x xs y ys] (+ x y))")
        @test ex.args[1] ==
              Expr(:block, Expr(:(=), :x, :xs), Expr(:(=), :y, :ys))
    end
    @test tr("(while c (f))") ==
          Expr(:while, :c, Expr(:block, Expr(:call, :f)))
    @test tr("(break)") == Expr(:break)
    @test tr("(continue)") == Expr(:continue)
    @test tr("(return 1)") == Expr(:return, 1)

    @test tr("(try (f) (catch e (g e)))") ==
          Expr(:try, Expr(:block, Expr(:call, :f)), :e,
               Expr(:block, Expr(:call, :g, :e)))
    @test tr("(try (f) (finally (h)))") ==
          Expr(:try, Expr(:block, Expr(:call, :f)), false, false,
               Expr(:block, Expr(:call, :h)))
    @test_throws Sexpr.InvalidFormStructureError tr("(try (f))")

    # char literals for closing punctuation, nested const declarations, an
    # empty let body, and the `(:)` call versus `x:end`
    @test tr("(print \\))") == Expr(:call, :print, ')')
    @test tr("(const (global (def x 1)))") ==
          Expr(:const, Expr(:global, Expr(:(=), :x, 1)))
    @test tr("(let [x 1])") ==
          Expr(:let, Expr(:block, Expr(:(=), :x, 1)), Expr(:block))
    @test tr("(fn [] 1)") == Expr(:->, Expr(:tuple), Expr(:block, 1))
    @test tr("(: (splat xs))") == Expr(:call, :(:), Expr(:..., :xs))

    @test tr("(and a b c)") == Expr(:&&, Expr(:&&, :a, :b), :c)
    @test tr("(or a b)") == Expr(:||, :a, :b)
    @test tr("(and)") === true
    @test tr("(or)") === false

    @test tr("(-> x (f 1) g)") == Expr(:call, :g, Expr(:call, :f, :x, 1))
    @test tr("(->> x (f 1) g)") == Expr(:call, :g, Expr(:call, :f, 1, :x))

    @test tr("(comprehension [x xs] (* x x))") ==
          Expr(:comprehension,
               Expr(:generator, Expr(:call, :*, :x, :x), Expr(:(=), :x, :xs)))
    @test tr("(broadcast f x)") ==
          Expr(:., :f, Expr(:tuple, :x))

    @test tr("(.b a 1 2)") ==
          Expr(:call, Expr(:., :a, QuoteNode(:b)), 1, 2)
    @test tr("(. a b c)") ==
          Expr(:., Expr(:., :a, QuoteNode(:b)), QuoteNode(:c))
    @test tr("(. a (b 1))") ==
          Expr(:call, Expr(:., :a, QuoteNode(:b)), 1)

    @test tr("(: 1 3)") == Expr(:call, Symbol(":"), 1, 3)
    @test tr("(: a)") == Expr(:call, Symbol(":"), :a, :end)
    @test tr("(curly Array Int64)") == Expr(:curly, :Array, :Int64)
    @test tr("(:: x)") == Expr(:(::), :x)
    @test tr("(:: T)") == Expr(:(::), :T)
    # `(:: x A B)` is the documented `x::Union{A, B}` shorthand
    @test tr("(:: x A B)") == Expr(:(::), :x, Expr(:curly, :Union, :A, :B))
    @test_throws Sexpr.InvalidFormCountError tr("(::)")

    @test tr("(module M (f))") ==
          Expr(:module, true, :M, Expr(:block, Expr(:call, :f)))
    # the module flag distinguishes `baremodule`
    @test tr("(baremodule M (f))") ==
          Expr(:module, false, :M, Expr(:block, Expr(:call, :f)))
    @test tr("(public a b)") == Expr(:public, :a, :b)
    @test tr("(public @inline a)") == Expr(:public, Symbol("@inline"), :a)
    @test tr("(export a b)") == Expr(:export, :a, :b)
    # `using`/`import` module paths use Julia's flat `.` with plain symbols
    @test tr("(import A.b)") == Expr(:import, Expr(:., :A, :b))
    @test tr("(import A.b.c)") == Expr(:import, Expr(:., :A, :b, :c))
    @test tr("(use A)") == Expr(:using, Expr(:., :A))
    @test tr("(use A b c)") ==
          Expr(:using, Expr(Symbol(":"), Expr(:., :A), Expr(:., :b), Expr(:., :c)))
    # a dotted operator field stays an operator, not an escaped identifier
    @test tr("(. Base +)") == Expr(:., :Base, QuoteNode(:+))
    @test tr("(. Base <=)") == Expr(:., :Base, QuoteNode(:<=))
end

# ---------------------------------------------------------------------------
# parser details
# ---------------------------------------------------------------------------

@testset "parser" begin
    # comments, commas and multiple top level forms
    @test transpile("(+ 1 2) ; comment\n(* 3 4)") ==
          Any[Expr(:call, :+, 1, 2), Expr(:call, :*, 3, 4)]
    @test tr("(+ 1, 2)") == Expr(:call, :+, 1, 2)
    @test tr("#_ignored 42") === 42
    @test tr("(+ 1 #_2 3)") == Expr(:call, :+, 1, 3)
    @test tr("#_[ignored] 7") === 7

    # multiline strings keep their newlines
    @test tr("\"a\nb\"") == "a\nb"

    @test_throws Sexpr.UnclosedError tr("(+ 1")
    @test_throws Sexpr.MismatchedError tr("(+ 1]")
    @test_throws Sexpr.ExtraError tr(")")
    @test_throws Sexpr.InvalidTokenError tr("#(foo)")
    @test_throws Sexpr.InvalidTokenError tr("\\nosuchchar")

    e = try
        transpile("(+ 1\n  2")
    catch err
        err
    end
    @test occursin("1:1", sprint(showerror, e))
end

# ---------------------------------------------------------------------------
# running transpiled code
# ---------------------------------------------------------------------------

@testset "semantics" begin
    m = eval_program("""
        (defn add [a b] (+ a b))
        (defn fst [[a b]] a)
        (defn total [& xs] (+ xs...))
        (defn greet [(name "world")] (str "hello " name))
        (defmutable Point [x y])
        (deftype Typed [x::Float64])
        (defmacro twice [x] `(+ ~x ~x))
        (defn quad [a] (@twice (@twice a)))
        (def s #{1 2 2 3})
        (def d {:a 1 :b 2})
        (defn classify [n]
          (cond (< n 0) :negative
                (= n 0) :zero
                :else :positive))
    """)

    @test Core.eval(m, :(add(2, 3))) == 5
    @test Core.eval(m, :(fst((7, 8)))) == 7
    @test Core.eval(m, :(total(1, 2, 3))) == 6
    @test Core.eval(m, :(greet())) == "hello world"
    @test Core.eval(m, :(quad(2))) == 8
    @test Core.eval(m, :(s)) == Set([1, 2, 3])
    @test Core.eval(m, :(d)) == Dict(:a => 1, :b => 2)
    @test Core.eval(m, :(classify(-3))) == :negative
    @test Core.eval(m, :(classify(0))) == :zero
    @test Core.eval(m, :(classify(4))) == :positive

    p = Core.eval(m, :(Point(1, 2)))
    setfield!(p, :x, 3)
    @test p.x == 3
    @test Core.eval(m, :(Typed(1.5))).x == 1.5

    @test Core.eval(m, tr("(if (> 3 2) :yes :no)")) == :yes
    @test Core.eval(m, tr("(let [a 1 b 2] (+ a b))")) == 3
    @test Core.eval(m, tr("(try (error \"boom\") (catch e :caught))")) == :caught
    @test Core.eval(m, tr("(try (error \"boom\") (catch e :caught) (finally :done))")) ==
          :caught
    @test Core.eval(m, tr("(-> 5 (+ 1) (* 2))")) == 12
    @test Core.eval(m, tr("(->> 5 (+ 1) (* 2))")) == 12
    @test Core.eval(m, tr("(comprehension [i [1 2 3]] (* i i))")) == [1, 4, 9]
    @test Core.eval(m, tr("(for [i [1 2 3]] (println i))")) === nothing

    # a whole for-loop accumulation, inside a function so scoping is clean
    m2 = eval_program("""
        (defn sumto [n]
          (let [total 0]
            (do
              (for [i (: 1 n)] (def total (+ total i)))
              total)))
    """)
    @test Core.eval(m2, :(sumto(4))) == 10
end

# ---------------------------------------------------------------------------
# Julia -> s-expression
# ---------------------------------------------------------------------------

@testset "detranspile" begin
    @test detranspile("function add(a, b)\n a + b\nend") ==
          "(defn add [a b] (+ a b))"
    @test detranspile("struct Point\n x::Float64\n y::Float64\nend") ==
          "(deftype Point [x::Float64 y::Float64])"
    @test detranspile("struct L{T}\n x::T\nend") ==
          "(deftype (curly L T) [x::T])"
    @test detranspile("struct D{K,V} <: AbstractDict{K,V}\n x\nend") ==
          "(deftype (<: (curly D K V) (curly AbstractDict K V)) [x])"
    @test detranspile("abstract type A{T} <: B end") ==
          "(abstract (<: (curly A T) B))"
    @test detranspile("primitive type P 8 end") == "(primitive P 8)"
    @test detranspile("baremodule M\n f()\nend") == "(baremodule M (f))"
    if VERSION >= v"1.11.0-DEV"
        # `public` is a keyword only from Julia 1.11
        @test detranspile("public a, b") == "(public a b)"
    end
    @test detranspile("x = 1") == "(def x 1)"
    @test detranspile("string(a, b)") == "(str a b)"
    @test detranspile("x = 9223372036854775808") ==
          "(def x 9223372036854775808)"
    @test detranspile("x = 1\ny = 2") == "(def x 1)\n\n(def y 2)"
    @test detranspile("function show end") == "(defn show)"
    @test detranspile("let a = 1; a; end") == "(let [a 1] a)"
    # an anonymous function expression keeps its body
    @test detranspile("f = function(x)\n x + 1\nend") == "(def f (fn [x] (+ x 1)))"
    # runtime-built let bindings keep the block spelling in a macro template
    @test detranspile("macro m(xs)\n quote\n let \$(xs...)\n y\n end\n end\nend") ==
          "(defmacro m [xs] (quote (do (let (do (unquote (splat xs))) y))))"
    @test detranspile("f(::Int) = 1") == "(defn f [(:: Int)] 1)"
    # an anonymous typed argument keeps one argument instead of gaining `Any`
    @test detranspile("get(::Callable, d, k)") == "(get (:: Callable) d k)"
    @test detranspile(Expr(:call, :f, Expr(:(::), :x, :A, :B))) == "(f (:: x A B))"
    @test detranspile("global x = 1") == "(global (def x 1))"
    @test detranspile("x = :(f(\$y))") == "(def x (quote (f (unquote y))))"
    @test detranspile("function (::Type{T})(x)\n x\nend") ==
          "(defn (:: (curly Type T)) [x] x)"
    @test detranspile("function (f::T)(x)\n x\nend") ==
          "(defn (:: f T) [x] x)"
    @test detranspile("function f(x)::Int\n x\nend") ==
          "(defn (returns f Int) [x] x)"
    @test detranspile("function f(fn, x)\n fn(x)\nend") ==
          "(defn f [fn x] (fn x))"
    @test detranspile("f(x) = 2x") == "(defn f [x] (* 2 x))"
    @test detranspile("x -> x + 1") == "(fn [x] (+ x 1))"
    @test detranspile("Dict(:a => 1)") == "{:a 1}"
    @test detranspile("Set([1, 2])") == "#{1 2}"
    @test detranspile("x[1, 2]") == "(aget x 1 2)"
    @test detranspile("@time f(x)") == "(@time (f x))"

    @test detranspile("f(a; b = 1)") == "(f (parameters (kw b 1)) a)"
    @test detranspile("using ..GMP: BigInt") == "(using ..GMP BigInt)"
    @test detranspile("import .Base: +, -, *, (:)") ==
          "(import .Base + - * :)"
    @test detranspile("Base.@assume_effects :terminates_locally function f(x)\n x\nend") ==
          "(@Base.@assume_effects :terminates_locally (defn f [x] x))"
    @test detranspile("\"\"\"a \$(x)\"\"\"\nf(y) = y") ==
          "(@doc (str \"a \" x) (defn f [y] y))"
    @test detranspile("\"docs\"\nmutable struct M\n x\nend") ==
          "(defmutable M \"docs\" [x])"
    @test detranspile("\"a \$(x)\"\nmutable struct M\n x\nend") ==
          "(@doc (str \"a \" x) (defmutable M [x]))"
    @test detranspile("x = (:-)") == "(def x :-)"
    @test detranspile("p .= p .- p") == "(.= p (.- p p))"
    @test detranspile("p .= .-p") == "(.= p (.- p))"
    @test detranspile("x = .-") == "(def x .-)"
    @test detranspile("x = :(Base.FastMath.\$(fast_symb))") ==
          "(def x (quote (. Base FastMath \$fast_symb)))"
    @test detranspile("p .+= 1") == "(.+= p 1)"
    @test detranspile("isexpr(x, :(::))") == "(isexpr x :::)"
    @test detranspile("something(x, :)") == "(something x :)"
    @test format(Meta.parse("f(:)")) == "f((:))"
    @test detranspile("A[i+=1]") == "(aget A (+= i 1))"
    @test detranspile("axes(res1, din[] += 1)") == "(axes res1 (+= (aget din) 1))"
    @test detranspile("x = begin\n 1\nend") == "(def x (do 1))"
    @test detranspile("sym === :var\"#unused#\"") == "(=== sym :#unused#)"
    @test detranspile(":(\$(esc(old)) = 1)") ==
          "(syntax-quote (def (unquote old) 1))"
    # only a quote whose interpolations are all `$(esc(...))` is a
    # syntax-quote; a mixed quote keeps each interpolation as written
    @test detranspile("macro m(x, y)\n :(\$(esc(x)) + \$(y))\nend") ==
          "(defmacro m [x y] (quote (+ (unquote (esc x)) (unquote y))))"
    @test detranspile("(&)(x::Bool, y::Bool) = and_int(x, y)") ==
          "(defn & [x::Bool y::Bool] (and_int x y))"
    @test detranspile("f(a; b = 1) = a") ==
          "(defn f [(parameters (b 1)) a] a)"
    @test detranspile("f(; kwargs...) = kwargs") ==
          "(defn f [(parameters (& kwargs))] kwargs)"
    @test detranspile("f(@nospecialize(x)) = x") ==
          "(defn f [(@nospecialize x)] x)"
    @test detranspile("f() do x\n g(x)\nend") ==
          "(do-call (f) (fn [x] (g x)))"
    @test tr("(elseif a b c)") == Expr(:elseif, :a, :b, :c)
    @test tr("(elseif a b)") == Expr(:elseif, :a, :b)
    @test detranspile("try\n f()\ncatch e\n g(e)\nend") ==
          "(try (f) (catch e (g e)))"
    @test detranspile("for i in 1:3\n println(i)\nend") ==
          "(for [i (: 1 3)] (println i))"
    @test detranspile("[i^2 for i in 1:3]") ==
          "(comprehension [i (: 1 3)] (^ i 2))"
    @test detranspile("module M\nf() = 1\nend") == "(module M (defn f [] 1))"
    @test detranspile("1 < x <= 10") == "(and (< 1 x) (<= x 10))"

    # formatting breaks long forms over several lines
    data = to_sexpr(Meta.parse("function f(aaaaaaaaaa, bbbbbbbbbb, cccccccccc)\n aaaaaaaaaa + bbbbbbbbbb + cccccccccc\nend"))
    @test occursin("\n", print_sexp(data; width=40))
    @test !occursin("\n", print_sexp(data; width=200))
end

@testset "formatting" begin
    # quotes, including nested ones and interpolation, must print as code
    @test format(Meta.parse("x = :(a + b)")) == "x = :(a + b)"
    @test format(transpile_expr("(def q (quote (f 1)))")) == "q = :(f(1))"
    @test format(Meta.parse("f(:sym, :(1 + 2))")) == "f(:sym, :(1 + 2))"
    @test Meta.parse(format(Meta.parse(":(if \$c; 1; else; 2; end)"))) !== nothing

    let macro_src = format(transpile_expr("(defmacro twice [x] `(+ ~x ~x))"))
        @test occursin("macro twice(x)", macro_src)
        @test occursin("\$(esc(x))", macro_src)
        @test Meta.parse(macro_src) !== nothing
    end

        @test format(Meta.parse("import .Base: +, -, *, (:)")) == "import .Base: +, -, *, (:)"
    @test format(Meta.parse("export var\"'\", @view")) ==
          "export var\"'\", @view"
    # a bare prime is not a readable name in a directive
    @test format(Meta.parse("export var\"′\", adjoint")) ==
          "export var\"′\", adjoint"
    @test format(Meta.parse("if (x = f()); y; end")) ==
          "if (x = f())\n    y\nend"
    @test format(Meta.parse("Base.@assume_effects :terminates_locally function f(x)\n x\nend")) ==
          "Base.@assume_effects(:terminates_locally, function f(x)\n    x\nend)"
    @test format(transpile_expr("(import A.b)")) == "import A.b"
    @test format(transpile_expr("(import A b)")) == "import A: b"
    @test format(transpile_expr("(using A b c)")) == "using A: b, c"
    @test format(transpile_expr("(use A)")) == "using A"
    @test format(transpile_expr("(export a b)")) == "export a, b"
end

@testset "round trip" begin
    snippets = [
        "x + 1",
        "x[1, 2]",
        "Dict(:a => 1, :b => 2)",
        "Set([1, 2, 3])",
        "function add(a, b)\n a + b\nend",
        "function f(x::Int, y = 2)\n x + y\nend",
        "function g(x)::Int\n x\nend",
        "struct P\n x::Float64\n y\nend",
        "mutable struct L{T}\n x::T\nend",
        "struct D{K,V} <: AbstractDict{K,V}\n x\nend",
        "abstract type A{T} <: B end",
        "primitive type P 8 end",
        "for i in 1:3\n println(i)\nend",
        "for (i, x) in enumerate(xs)\n println(i)\nend",
        "while x > 0\n x -= 1\nend",
        "if x > 0\n y = 1\nelse\n y = 2\nend",
        "try\n f()\ncatch e\n g(e)\nfinally\n h()\nend",
        "let a = 1, b = 2\n a + b\nend",
        "x = [1, 2, 3]",
        "a.b(c)",
        "f(a; b = 1)",
        "f(a; b = 1) = a",
        "f(; kwargs...) = kwargs",
        "f(x...; k...) = (x, k)",
        "f(@nospecialize(x)) = x",
        "f(x; y = @time(1)) = y",
        "f() do x\n g(x)\nend",
        "if a\n 1\nelseif b\n 2\nelse\n 3\nend",
        "\"doc\"\nf(x) = x",
        "string(a, b)",
        ":str",
        "str = 1",
        "using ..GMP: BigInt",
        "import .Base: +, -, *, (:)",
        "Base.@assume_effects :terminates_locally function f(x)\n x\nend",
        "\"\"\"a \$(x)\"\"\"\nf(y) = y",
        "\"a \$(x)\"\nmutable struct M\n x\nend",
        "x = (:-)",
        "p .= p .- p",
        "p .= .-p",
        "x = .-",
        "x = :(Base.FastMath.\$(fast_symb))",
        "p .+= 1",
        "isexpr(x, :(::))",
        "A[i+=1]",
        "axes(res1, din[] += 1)",
        "x = begin\n 1\nend",
        "sym === :var\"#unused#\"",
        "(&)(x::Bool, y::Bool) = and_int(x, y)",
        "x = 9223372036854775808",
        "[i^2 for i in 1:3]",
        "module M\nf() = 1\nend",
        "x -> x + 1",
        "x = :(a + b)",
        "x = :(f(\$y))",
        "x = \$(y)",
        "@eval const \$(h) = \$(i)",
        "macro m(x)\n :(\$(esc(x)))\nend",
        "macro m(x)\n :(1 + \$(esc(x)))\nend",
        "macro m(xs)\n :(f(\$(esc(xs))...))\nend",
        "f(::Int) = 1",
        "function show end",
        "function (::Type{T})(x)\n x\nend",
        "function (f::T)(x)\n x\nend",
        "function f(x)::Int\n x\nend",
        "function (Ref{P}(a::Array{T}) where P <: Union{Ptr,Cstring}) where T\n a\nend",
        "function mktemp(fn::Function)\n fn(1)\nend",
        "global x = 1",
        "local y = 2",
        "using A: b, c",
        "a && b || c",
        "1 < x <= 10",
        "x::Int = 1",
        "@time f(x)",
        "1//2",
    ]
    for src in snippets
        @testset "$(first(split(src, '\n')))" begin
            clj = detranspile(src)
            back = transpile(clj)
            @test !isempty(back)
            # the printed Julia must parse again
            text = join(map(format, back), "\n")
            @test Meta.parse(text) !== nothing
            # and converting back once more must be stable
            @test detranspile(text) == detranspile(src)
        end
    end

    @test canon(tr(detranspile("function add(a, b)\n a + b\nend"))) ==
          canon(Meta.parse("function add(a, b)\n a + b\nend"))
    @test canon(tr(detranspile("struct P\n x::Float64\nend"))) ==
          canon(Meta.parse("struct P\n x::Float64\nend"))
    @test canon(tr(detranspile("try\n f()\ncatch e\n g(e)\nend"))) ==
          canon(Meta.parse("try\n f()\ncatch e\n g(e)\nend"))
    @test canon(tr(detranspile("try\n f()\ncatch e\n g(e)\nfinally\n h()\nend"))) ==
          canon(Meta.parse("try\n f()\ncatch e\n g(e)\nfinally\n h()\nend"))
    # a quoted operator symbol keeps a spelling that parses back exactly
    @test format(QuoteNode(Symbol("\\="))) == ":\\="
    @test format(QuoteNode(Symbol("~"))) == ":~"
    @test tr("[:~]") == Expr(:vect, QuoteNode(Symbol("~")))
    @test tr("[:\\=]") == Expr(:vect, QuoteNode(Symbol("\\=")))
    # an unquote in a parameter list is a parameter, not a `(name default)` pair
    @test tr("(parameters (unquote sym))") == Expr(:parameters, Expr(:$, :sym))
    # a body-less `for i = 1:3 end` prints without body forms and reads back
    @test tr("(for [i (: 1 3)])") ==
          Expr(:for, Expr(:(=), :i, Expr(:call, Symbol(":"), 1, 3)), Expr(:block))
    # a callable type expression keeps its own `where` inside the call:
    # `(Array{T, N} where T)(x) where {S, N}` defines a method on the type
    wsrc = "function (Array{T, N} where T)(x::AbstractArray{S, N}) where {S, N}\n Array{S, N}(x)\nend"
    @test canon_ast(tr(detranspile(wsrc))) == canon_ast(Meta.parse(wsrc))
    # chained `where`s over a callable type keep their order: the call is innermost
    csrc = "function (::Type{T})(x) where {T} where {S}\n x\nend"
    @test canon_ast(tr(detranspile(csrc))) == canon_ast(Meta.parse(csrc))
    # a Float32 literal keeps the `f0` that `string` would drop
    @test detranspile(Expr(:call, :f, 1.0000305f0)) == "(f 1.0000305f0)"
    @test tr("(f 1.0000305f0)") == Expr(:call, :f, 1.0000305f0)
    # an anonymous function keeps its `where` parameters
    wfn = Expr(:function, Expr(:where, Expr(:tuple, :x), :T), Expr(:block, :x))
    @test detranspile(wfn) == "(fn (where [x] T) x)"
    @test canon_ast(tr("(fn (where [x] T) x)")) == canon_ast(wfn)
    # Known limitation: a non-finite float cannot round-trip. Julia's only
    # spelling is the global name `NaN`/`Inf`, and the reader must keep that
    # atom a *symbol* (`:NaN` is an ordinary identifier in quoted code), so
    # the value and the width are both lost -- `NaN32` prints as `NaN` too.
    @test detranspile(Expr(:call, :f, NaN)) == "(f NaN)"
    @test detranspile(Expr(:call, :f, NaN32)) == "(f NaN)"
    @test detranspile(Expr(:call, :f, -Inf32)) == "(f -Inf)"
    @test tr("(f NaN)") == Expr(:call, :f, :NaN)
    # a dotted operator method name is a property access, not one atom
    # (spelled as an AST: `function Base.//(x)` does not parse before 1.9)
    opname = Expr(:., :Base, QuoteNode(Symbol("//")))
    opdef = Expr(:function, Expr(:call, opname, :x), Expr(:block, :x))
    @test detranspile(opdef) == "(defn (. Base //) [x] x)"
    @test canon_ast(tr("(defn (. Base //) [x] x)")) == canon_ast(opdef)
    # a bare `catch` writes its variable slot explicitly, so `(catch y)` stays
    # unambiguously "catch variable y"
    @test detranspile(Meta.parse("try\n x\ncatch\n y\nend")) == "(try x (catch false y))"
    @test canon_ast(tr("(try x (catch false y))")) ==
          canon_ast(Meta.parse("try\n x\ncatch\n y\nend"))
    # one `;`-joined top-level line is a nested `Expr(:toplevel)` and survives
    tl = Expr(:toplevel, Expr(:const, Expr(:(=), :X, 1)))
    @test transpile(detranspile(Expr(:toplevel, tl, Expr(:(=), :y, 2)))) ==
          Any[tl, Expr(:(=), :y, 2)]
    @test format(tl) == "const X = 1;"
    # a macro name that is not a plain dotted symbol gets a form of its own:
    # `@$(Base).@__doc__` would split into several atoms
    uname = Expr(:., Expr(:$, :Base), QuoteNode(Symbol("@__doc__")))
    usrc = "quote\n        @\$(Base).@__doc__ \$(expr)\n    end"
    @test canon_ast(tr(detranspile(usrc))) == canon_ast(Meta.parse(usrc))
    @test tr("(macrocall (. (unquote Base) @__doc__) (unquote expr))") ==
          Expr(:macrocall, uname, LineNumberNode(0, :none), Expr(:$, :expr))
    let r = Meta.parse(format(Expr(:macrocall, uname, LineNumberNode(0, :none), :x)))
        @test r isa Expr && r.head == :macrocall && r.args[1] == uname
    end
    # a body-less declaration `macro f end` is a one-arg `Expr(:macro)` and
    # keeps that shape, unlike `macro f() end` with an empty body
    @test tr("(defmacro cmd)") == Expr(:macro, :cmd)
    @test detranspile(Expr(:macro, :cmd)) == "(defmacro cmd)"
    @test detranspile(Expr(:macro, Expr(:call, :m), Expr(:block))) == "(defmacro m [])"
    if VERSION >= v"1.11.0-DEV"
        # `for outer i = …` keeps its `outer` node and prints as `outer i`
        @test detranspile("for outer i = 1:3\n println(i)\nend") ==
              "(for [(outer i) (: 1 3)] (println i))"
        @test canon(tr("(for [(outer i) (: 1 3)] (println i))")) ==
              canon(Meta.parse("for outer i = 1:3\n println(i)\nend"))
    end
end

# ---------------------------------------------------------------------------
# snippet round trips
#
# The snippet list is the diagnostic's `--self` corpus; checking it on every
# run keeps a fixed round trip from regressing silently.
# ---------------------------------------------------------------------------

"What the round trip of `forms` breaks, or `nothing` if it holds."
function snippet_problem(forms)
    sexp = detranspile(length(forms) == 1 ? forms[1] : Expr(:toplevel, forms...))
    back = transpile(sexp)
    length(back) == length(forms) ||
        return "form count $(length(forms)) -> $(length(back))"
    text = join(map(format, back), "\n\n")
    bad = try
        parse_error_node(Meta.parseall(text))
    catch e
        e
    end
    bad === nothing || return "generated text does not parse"
    for (orig, rt) in zip(forms, back)
        isequal(canon_ast(orig), canon_ast(rt)) || return "AST changed"
    end
    idem = try
        detranspile(text)
    catch
        return "generated text cannot be de-transpiled"
    end
    idem == sexp || return "not idempotent"
    return nothing
end

@testset "snippets" begin
    problems = String[]
    checked = 0
    for src in SNIPPETS
        forms = snippet_forms(src)
        # a snippet may use syntax this Julia does not know (`public` before
        # 1.11), so only snippets that parse here are round-tripped
        forms === nothing && continue
        checked += 1
        why = snippet_problem(forms)
        why === nothing || push!(problems, first(split(src, '\n')) * ": " * why)
    end
    @test checked >= length(SNIPPETS) - 1
    @test isempty(problems)
end

# ---------------------------------------------------------------------------
# macros and programmatic forms
# ---------------------------------------------------------------------------

@testset "macros and rehydrate" begin
    @test clj"(+ 1 2)" == 3
    @test clj"[1 2 3]" == [1, 2, 3]

    @test rehydrate(Sexpr.SList(Sexpr.SSym("+"), 1, 2)) == Expr(:call, :+, 1, 2)
    @test rehydrate((:if, :c, 1, 2)) == Expr(:if, :c, 1, 2)
    @test rehydrate(Sexpr.SVec(1, 2)) == Expr(:vect, 1, 2)
    @test rehydrate(Sexpr.SSym("x")) === :x
    @test rehydrate(Sexpr.SKeyword("k")) == QuoteNode(:k)
    @test rehydrate("text") == "text"
    @test rehydrate(nothing) === nothing

    tree = to_sexpr(Meta.parse("f(x, 1)"))
    @test tree == Sexpr.SList(Sexpr.SSym("f"), Sexpr.SSym("x"), 1)
    @test rehydrate(tree) == Meta.parse("f(x, 1)")

    @test to_sexpr(Meta.parse("Dict(:a => 1)")) ==
          Sexpr.SMap([Sexpr.SKeyword("a"), 1])
end

# ---------------------------------------------------------------------------
# symbol escaping
# ---------------------------------------------------------------------------

@testset "symbol escaping" begin
    try
        set_ascii_names!(false)
        @test format(tr("(defn empty? [xs] xs)")) ==
              "function emptyʔ(xs)\n    xs\nend"
        @test detranspile("function emptyʔ(xs)\n xs\nend") ==
              "(defn empty? [xs] xs)"
        @test ascii_names() == false
        # a Julia prime identifier is a plain name, not an escaped apostrophe
        @test transpile("(def npath′ 1)")[1] == :(npath′ = 1)
        @test detranspile(:npath′) == "npath′"
        @test detranspile("npath′") == "npath′"
        # an apostrophe in a name is still escaped so it cannot start a quote
        @test transpile("(def npath’ 1)")[1] == :(var"npath'" = 1)
        @test detranspile(Symbol("npath'")) == "npath’"
        @test Sexpr.unescapesym("deps′") == "deps′"

        set_ascii_names!(true)
        @test ascii_names() == true
        @test format(tr("(defn empty? [xs] xs)")) ==
              "function empty_q(xs)\n    xs\nend"
        @test detranspile("function empty_q(xs)\n xs\nend") ==
              "(defn empty? [xs] xs)"
        @test Sexpr.unescapesym(Sexpr.escapesym("a_b?*+<>:")) == "a_b?*+<>:"
    finally
        set_ascii_names!(false)
    end
end

# ---------------------------------------------------------------------------
# command line
# ---------------------------------------------------------------------------

@testset "command line" begin
    mktempdir() do dir
        src = joinpath(dir, "prog.clj")
        write(src, "(defn add [a b]\n  (+ a b))\n")
        out = joinpath(dir, "out")
        @test main([src, "-o", out]) == 0
        jl = joinpath(out, "prog.jl")
        @test isfile(jl)
        @test occursin("function add", read(jl, String))

        # inverse direction, including a directory input
        out2 = joinpath(dir, "out2")
        @test main(["-i", out, "-o", out2]) == 0
        clj = joinpath(out2, "prog.clj")
        @test isfile(clj)
        @test occursin("(defn add [a b]", read(clj, String))

        # extensions filter
        write(joinpath(dir, "notes.txt"), "(+ 1 2)")
        out3 = joinpath(dir, "out3")
        @test main([dir, "-o", out3]) == 0
        @test !isfile(joinpath(out3, "notes.jl"))

        # a syntax error is reported, not thrown
        bad = joinpath(dir, "bad.clj")
        write(bad, "(+ 1")
        @test redirect_stderr(devnull) do
            main([bad]) == 1
        end
    end

    @test redirect_stdout(devnull) do
        main(["-h"]) == 0
    end
    @test redirect_stderr(devnull) do
        main(["--nonsense"]) == 1
    end
end

@testset "literal types" begin
    # a based literal takes its type from its width, as in Julia, so the type
    # survives the round trip instead of decaying to Int
    @test tr("(def a 0xff)") == Expr(:(=), :a, UInt8(0xff))
    @test tr("(def a 0x01ff)") == Expr(:(=), :a, UInt16(0x01ff))
    @test tr("(def a 0x0000000a)") == Expr(:(=), :a, UInt32(10))
    @test tr("(def a 0x0000000000000001)") == Expr(:(=), :a, UInt64(1))
    @test tr("(def a 0b1010)") == Expr(:(=), :a, UInt8(0b1010))
    @test tr("(def a 0o17)") == Expr(:(=), :a, UInt8(0o17))
    @test detranspile(Expr(:(=), :a, UInt16(0x01ff))) == "(def a 0x01ff)"
    # the sign belongs to the literal: typemin(Int) is an Int, not an Int128
    @test tr("(def a -9223372036854775808)") == Expr(:(=), :a, typemin(Int64))
    # a decimal literal wider than Int is the builtin literal call Julia makes
    # of it, sign inside the literal, so the node itself round-trips
    for lit in ("9223372036854775808", "-9223372036854775809",
                "170141183460469231731687303715884105728")
        ex = Expr(:(=), :a, Meta.parse(lit))
        @test detranspile(ex) == "(def a " * lit * ")"
        @test tr(detranspile(ex)) == ex
    end
    # `-0x01` is the negation of an unsigned literal, as in Julia: the parsed
    # node is a call (its *value* would be the wrapping 0xff)
    let neg = Expr(:call, :-, UInt8(0x01))
        @test tr("(def a -0x01)") == Expr(:(=), :a, neg)
        @test detranspile(Expr(:(=), :a, neg)) == "(def a (- 0x01))"
    end
    # BigInt keeps its own spelling; `Expr` equality cannot compare a mutable
    # field on 1.13, so compare the rebuilt type and value instead
    let back = tr(detranspile(Expr(:(=), :a, big(12))))
        @test back.args[1] === :a
        @test back.args[2] isa BigInt
        @test back.args[2] == 12
    end
    # a colon call with annotated arguments keeps the spelling that re-parses
    let ex = Expr(:call, Symbol(":"), Expr(:(::), :Any), Expr(:(::), :Any))
        text = format(transpile_expr(detranspile(ex)))
        @test text == "(:)(::Any, ::Any)"
        @test transpile_expr(detranspile(text)) == ex
    end
end
