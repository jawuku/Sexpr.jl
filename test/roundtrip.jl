"""
Shared round-trip fixtures: the AST equivalence rules and the snippet corpus.

`canon_ast` folds only the equivalences this package documents or that are pure
notation (short-form functions, `+=`, chained comparisons, array literals, the
`tuple` call spelling, …). `SNIPPETS` is the small corpus that
`test/runtests.jl` checks on every run and that `test/corpus.jl` reports on
with `--self`.

This is a fixture, not a test: `test/corpus.jl` stays a standalone diagnostic
and includes it, and `test/runtests.jl` includes the same file, so the rules
and the snippets have exactly one definition.
"""

"The first parse-error node inside a parsed expression, if any."
function parse_error_node(x)
    x isa Expr || return nothing
    x.head in (:error, :incomplete) && return x
    for a in x.args
        n = parse_error_node(a)
        n === nothing || return n
    end
    return nothing
end

"Top-level forms of `src`, or `nothing` when this Julia cannot parse it."
function snippet_forms(src)
    ex = try
        Meta.parseall(src)
    catch
        return nothing
    end
    parse_error_node(ex) === nothing || return nothing
    return ex isa Expr && ex.head == :toplevel ?
        Any[a for a in ex.args if !(a isa LineNumberNode)] : Any[ex]
end

is_colon(h) = h isa Colon || h == Symbol(":")

canon_ast(::LineNumberNode) = nothing
canon_ast(x) = x

# Array literals have no s-expression spelling: `[a; b]` prints as the
# vcat/hcat family of calls, so the literal and the call compare equal.
const ARRAY_LITERAL_HEADS = (:vcat, :hcat, :row, :typed_vcat, :typed_hcat,
                             :ncat, :nrow)

is_block(x) = x isa Expr && x.head == :block
block_items(x) = is_block(x) ? Any[a for a in x.args if a !== nothing] : Any[x]

# `using A: b` stores names as `A.b` expressions; the reader produces
# symbols/QuoteNodes for the same thing.
function import_item(x)
    if x isa QuoteNode
        return x.value
    elseif x isa Expr && x.head == :. && length(x.args) == 1
        return import_item(x.args[1])
    elseif x isa Expr && is_colon(x.head)
        return Expr(x.head, import_item(x.args[1]),
                    map(import_item, x.args[2:end])...)
    end
    return x
end

"Is `x` the left side of a short-form function definition?"
function is_function_signature(x)
    x isa Expr || return false
    x.head == :call && return true
    x.head in (:where, :(::)) && !isempty(x.args) &&
        return is_function_signature(x.args[1])
    return false
end

function canon_ast(ex::Expr)
    h = is_colon(ex.head) ? Symbol(":") : ex.head
    a = Any[]
    for x in ex.args
        c = canon_ast(x)
        c === nothing && continue
        push!(a, c)
    end

    if h == :block
        return length(a) == 1 ? a[1] : Expr(:block, a...)
    elseif h == :function
        length(a) == 1 && return Expr(:function, a[1])   # method-less declaration
        # `function (x) ... end` and `x -> ...` are the same thing here
        if a[1] isa Expr && a[1].head == :tuple
            return Expr(:->, a[1], a[2])
        end
        return Expr(:function, a[1], a[2])
    elseif h == :->
        length(a) < 2 && return Expr(:->, a...)   # malformed, compare as-is
        params = a[1] isa Expr && a[1].head == :tuple ? a[1] : Expr(:tuple, a[1])
        return Expr(:->, params, a[2])
    elseif h == :(=) && is_function_signature(a[1])
        # documented: f(x) = body prints as (defn f [x] ...), including
        # return types and `where` parameters
        return Expr(:function, a[1], a[2])
    elseif h in (:+=, :-=, :*=, :/=, :%=, :^=, :&=, :|=)
        # documented: x += 1 prints as (def x (+ x 1))
        return Expr(:(=), a[1], Expr(:call, Symbol(string(h)[1:end-1]), a[1], a[2]))
    elseif h == :comparison
        # documented: a < b < c prints as (and (< a b) (< b c))
        parts = Any[]
        i = 1
        while i + 2 <= length(a)
            push!(parts, Expr(:call, a[i+1], a[i], a[i+2]))
            i += 2
        end
        return length(parts) == 1 ? parts[1] :
               reduce((x, y) -> Expr(:&&, x, y), parts)
    elseif h == :elseif
        # `elseif` is stored as a nested :if with a block-wrapped condition
        return length(a) == 2 ? Expr(:if, a[1], a[2]) :
                                Expr(:if, a[1], a[2], a[3])
    elseif h == :<:
        # `A <: B` is the operator call `(<: A B)`
        return Expr(:call, :<:, a...)
    elseif h == :let
        # the reader groups bindings into a block; Julia allows a bare
        # assignment for a single binding
        binds = Any[]
        for x in a[1:end-1]
            append!(binds, block_items(x))
        end
        return Expr(:let, Expr(:block, binds...), a[end])
    elseif h == :using || h == :import
        items = [import_item(x) for x in a]
        return length(items) == 1 ? Expr(h, items[1]) :
               Expr(:block, [Expr(h, x) for x in items]...)
    elseif h == :string
        # documented: "a$b" prints as (str "a" b)
        return Expr(:call, :string, a...)
    elseif h == :macrocall
        # the reader names @doc's Core binding by symbol
        head = a[1] isa GlobalRef ? Symbol(a[1].name) : a[1]
        return Expr(:macrocall, head, a[2:end]...)
    elseif h == :call && a[1] === :tuple
        # documented: `(tuple …)` spells both the tuple literal and the call
        # that builds it, so `tuple(x)` and `(x,)` denote the same expression
        return Expr(:tuple, a[2:end]...)
    elseif h == :call && length(a) == 3 && a[1] == :// &&
           a[2] isa Integer && a[3] isa Integer
        # `1//2` and the literal 1//2 denote the same value
        return a[2] // a[3]
    elseif h == :quote && length(a) == 1 && a[1] isa Symbol
        # `Meta.quot(:x)` and `QuoteNode(:x)` both evaluate to the symbol
        return QuoteNode(a[1])
    elseif h in ARRAY_LITERAL_HEADS
        # documented: `[a; b]` prints as the call `(vcat a b)`
        return Expr(:call, h, a...)
    end
    return Expr(h, a...)
end

# The snippets every round trip must handle.
const SNIPPETS = [
    "x = 1",
    "f(x) = 2x",
    "x += 1",
    "if c; x; else; y; end",
    "let a = 1, b = 2; a + b; end",
    "x -> x + 1",
    "1 < x <= 10",
    "1:3",
    "f(x) do y; y; end",
    "using A: b, c",
    "using A, B",
    "import A.B",
    "export a, b",
    "struct P; x::Int; P() = new(1); end",
    "mutable struct M; x; end",
    "for (i, x) in enumerate(xs); println(i); end",
    "[x for x in xs]",
    "Int[x for x in xs]",
    "(a = 1, b = 2)",
    "f(x) = tuple(x, 2x)",
    "g(xs) = tuple(xs...)",
    "f((a, b)::Tuple{Int,Int}) = a",
    "get(::Callable, d, k)",
    "f = function(x); x + 1; end",
    "macro m(xs); quote let \$(xs...); y; end end; end",
    "public a, b",
    "a && b || c",
    "function f(x)::Int; x; end",
    "function f(x) where T; x; end",
    "\"doc\"\nf(x) = 1",
    "x = [1 2; 3 4]",
    "T[a; b]",
    "global x = 1",
    "baremodule M; end",
    "0xff",
    "1.0f0",
    "\"a\$b\"",
    "macro m(x); :(\$(esc(x))); end",
    "try; f(); catch e; g(e); finally; h(); end",
    "@time f(x)",
    "x = :(a + b)",
    "dict = Dict(:a => 1)",
    "s = \"plain\"",
    "c = 'x'",
    "r = 1//2",
    "`ls -l`",
    # shapes that needed an s-expression spelling of their own
    "quote\n    @\$(Base).@__doc__ \$(expr)\nend",   # interpolated macro name
    "const LOCK = 1;\nconst OTHER = 2",                # a `;`-joined `(toplevel …)`
    "try; f(); catch; g(); end",                       # bare `catch` -> `(catch false …)`
    "(Array{T} where T)(x::Vector{S}) where {S} = x",   # callable-type `where` header
    "function (args::Vararg{Any, N},) where N; args; end",  # anonymous-function `where`
]
