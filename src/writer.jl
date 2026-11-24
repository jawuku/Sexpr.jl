"""
Writer: convert Julia expressions back into s-expressions.

The output is a small tree of `SList`/`SVec`/`SMap`/`SSet` nodes plus atoms,
which [`print_sexp`](@ref) renders as Clojure-flavoured source and
[`rehydrate`](@ref) turns back into Julia expressions.

This direction is deliberately lossy for a few Julia constructs that have no
natural s-expression spelling (type piracy on `where` clauses is preserved,
`abstract type`/`primitive type` declarations and `ccall` fall back to a
generic call form).
"""

# ---------------------------------------------------------------------------
# data types
# ---------------------------------------------------------------------------

struct SList
    items::Vector{Any}
end

struct SVec
    items::Vector{Any}
end

struct SMap
    items::Vector{Any}      # flattened k, v, k, v ...
end

struct SSet
    items::Vector{Any}
end

"An unescaped symbol name."
struct SSym
    name::String
end

"A keyword such as `:foo`."
struct SKeyword
    name::String
end

Base.:(==)(a::SList, b::SList) = a.items == b.items
Base.:(==)(a::SVec, b::SVec) = a.items == b.items
Base.:(==)(a::SMap, b::SMap) = a.items == b.items
Base.:(==)(a::SSet, b::SSet) = a.items == b.items
Base.:(==)(a::SSym, b::SSym) = a.name == b.name
Base.:(==)(a::SKeyword, b::SKeyword) = a.name == b.name
Base.hash(a::SList, h::UInt) = hash(a.items, hash(:SList, h))
Base.hash(a::SVec, h::UInt) = hash(a.items, hash(:SVec, h))
Base.hash(a::SMap, h::UInt) = hash(a.items, hash(:SMap, h))
Base.hash(a::SSet, h::UInt) = hash(a.items, hash(:SSet, h))
Base.hash(a::SSym, h::UInt) = hash(a.name, hash(:SSym, h))
Base.hash(a::SKeyword, h::UInt) = hash(a.name, hash(:SKeyword, h))

# Multi-argument convenience constructors. (One-argument calls use Julia's
# generated constructor and must pass a `Vector{Any}`.)
SList(items...) = SList(Any[items...])
SVec(items...) = SVec(Any[items...])

# ---------------------------------------------------------------------------
# names
# ---------------------------------------------------------------------------

"""
    symbol_text(x) -> String

Render a symbol-ish expression (`Symbol`, dotted access, `::`, `curly`) as the
single Clojure symbol that reads back to it.
"""
symbol_text(s::Symbol) = unescapesym(string(s))
symbol_text(q::QuoteNode) = unescapesym_raw(string(q.value))
symbol_text(e::Expr) = _symbol_text(e)
function _symbol_text(e::Expr)
    if e.head == :.
        args = e.args
        if !isempty(args) && args[1] === Symbol(".")
            n = 0
            i = 1
            while i <= length(args) && args[i] === Symbol(".")
                n += 1
                i += 1
            end
            tail = join(map(symbol_text, args[i:end]), ".")
            return string("."^n, tail)
        end
        # A flat `.` (Julia's `using`/`import` module path) and a nested value
        # access both print as their dotted name.
        return join(map(symbol_text, e.args), ".")
    elseif e.head == :(::)
        return string(symbol_text(e.args[1]), "::", symbol_text(e.args[2]))
    elseif e.head == :curly
        return string(symbol_text(e.args[1]), "{",
                      join(map(symbol_text, e.args[2:end]), ", "), "}")
    elseif e.head == :quote && length(e.args) == 1
        return string(":", symbol_text(e.args[1]))
    else
        return sexp_string(sexp(e))
    end
end
symbol_text(x) = sexp_string(sexp(x))

# ---------------------------------------------------------------------------
# expression -> sexp data
# ---------------------------------------------------------------------------

sexp(::Nothing) = nothing
sexp(x::Bool) = x
sexp(x::Number) = x
sexp(x::Char) = x
sexp(x::AbstractString) = String(x)
sexp(x::Symbol) = SSym(unescapesym(string(x)))
sexp(::LineNumberNode) = nothing

"A keyword atom body for a quoted symbol, with s-expression syntax escaped."
function keyword_text(name::AbstractString)
    isempty(name) && return EMPTY_KEYWORD
    # A leading `:` must not turn the atom into a plain symbol (`::` for `:`),
    # except for an all-colon name, which keeps the shorter `::` spelling.
    if startswith(name, ":") &&
       !(length(name) > 1 && all(c -> c == ':', name))
        name = string("¦", name[2:end])
    end
    io = IOBuffer()
    for c in name
        write(io, get(KEYWORD_ESCAPES, c, c))
    end
    return String(take!(io))
end

function sexp(q::QuoteNode)
    return q.value isa Symbol ? SKeyword(keyword_text(string(q.value))) :
                                SList(SSym("quote"), sexp(q.value))
end

# atoms that are syntactically valid but not plain values
sexp(x) = SSym(string(x))

function sexp(ex::Expr)
    h = ex.head
    a = ex.args

    # ---- literals and collections -----------------------------------------
    if h == :call
        if length(a) == 3 && a[1] == :// && a[2] isa Integer && a[3] isa Integer
            # rational literal: 3//5 -> 3/5
            return SSym(string(sexp_string(sexp(a[2])), "/", sexp_string(sexp(a[3]))))
        elseif a[1] == COLON_HEAD && (length(a) == 3 || length(a) == 4)
            # range: 1:3 -> (: 1 3)
            return SList(Any[SSym(":"); map(sexp, a[2:end])...])
        elseif a[1] == :Dict && all(x -> x isa Expr && x.head == :call &&
                                    x.args[1] == :(=>), a[2:end])
            # Dict(k => v, ...) prints as a map literal
            items = Any[]
            for p in a[2:end]
                push!(items, sexp(p.args[2]), sexp(p.args[3]))
            end
            return SMap(items)
        elseif a[1] == :Set && length(a) == 2 && a[2] isa Expr && a[2].head == :vect
            return SSet(map(sexp, a[2].args))
        elseif a[1] == :string
            # interpolation and `string(...)` share the documented `(str …)` form
            return SList(Any[SSym("str"), map(sexp, a[2:end])...])
        end
        return SList(Any[sexp(a[1]), map(arg_sexp, a[2:end])...])
    elseif h == :tuple
        return SList(Any[SSym("tuple"), map(sexp, a)...])
    elseif h == :vect
        return SVec(map(sexp, a))
    elseif h == :ref
        return SList(Any[SSym("aget"), map(arg_sexp, a)...])
    elseif h == :(=)
        lhs = a[1]
        # short-form function definition, including `f(x)::T` and `where`
        is_function_signature(lhs) && return sexp_function(Any[lhs, a[2]])
        return SList(SSym("def"), sexp(a[1]), sexp(a[2]))
    elseif h == :(+=) || h == :(-=) || h == :(*=) || h == :(/=) || h == :(%=) ||
           h == :(^=) || h == :(&=) || h == :(|=)
        op = Symbol(string(h)[1:end-1])
        return SList(SSym("def"), sexp(a[1]),
                     SList(sexp(op), sexp(a[1]), sexp(a[2])))
    elseif h == :string
        return SList(Any[SSym("str"), map(sexp, a)...])

    # ---- definitions -------------------------------------------------------
    elseif h == :function
        return sexp_function(a)
    elseif h == :-> 
        return SList(Any[SSym("fn"), sexp_params(a[1]), body_forms(a[2])...])
    elseif h == :macro
        sig = a[1]
        # a body-less declaration `macro f end` parses as one-arg `Expr(:macro, :f)`
        length(a) >= 2 || return SList(Any[SSym("defmacro"), sexp_name(sig)])
        body = a[2]
        params = sig isa Expr && sig.head == :call ? sig.args[2:end] : Any[]
        name = sig isa Expr && sig.head == :call ? sig.args[1] : sig
        return SList(Any[SSym("defmacro"), sexp_name(name), SVec(map(param_sexp, params)),
                         body_forms(body)...])
    elseif h == :struct
        mutable, name, block = a[1], a[2], a[3]
        # keep fields, @atomic fields and inner constructors in source order;
        # only fields use parameter syntax (`=` there means a constructor)
        members = Any[(x isa Symbol || (x isa Expr && x.head == :(::))) ?
                      param_sexp(x) : sexp(x)
                      for x in block.args if !(x isa LineNumberNode)]
        return SList(Any[SSym(mutable ? "defmutable" : "deftype"),
                         type_sexp(name), SVec(members)])

    # ---- control flow ------------------------------------------------------
    elseif h == :block
        return SList(Any[SSym("do"), body_forms(ex)...])
    elseif h == :if
        items = Any[SSym("if"), branch(a[1]), branch(a[2])]
        length(a) >= 3 && push!(items, branch(a[3]))
        return SList(items)
    elseif h == :while
        return SList(Any[SSym("while"), sexp(a[1]), body_forms(a[2])...])
    elseif h == :for
        binds = Any[]
        for x in (a[1] isa Expr && a[1].head == :block ? a[1].args : Any[a[1]])
            x isa LineNumberNode && continue
            if x isa Expr && x.head == :(=)
                push!(binds, param_sexp(x.args[1]), sexp(x.args[2]))
            end
        end
        return SList(Any[SSym("for"), SVec(binds), body_forms(a[2])...])
    elseif h == :let
        b = a[1]
        items = Any[y for y in (b isa Expr && b.head == :block ? b.args : Any[b])
                      if !(y isa LineNumberNode)]
        # `[lhs rhs …]` pairs spell ordinary bindings; a binding built at run
        # time (`let $(args...)`, only in quoted code) has no pair spelling,
        # so the whole bindings block keeps its structure instead of vanishing.
        if !all(y -> y isa Expr && y.head == :(=), items)
            return SList(Any[SSym("let"), sexp(Expr(:block, items...)),
                             body_forms(a[end])...])
        end
        binds = Any[]
        for y in items
            push!(binds, param_sexp(y.args[1]), sexp(y.args[2]))
        end
        return SList(Any[SSym("let"), SVec(binds), body_forms(a[end])...])
    elseif h == :try
        items = Any[SSym("try"), body_forms(a[1])...]
        if length(a) >= 3 && a[3] !== false
            # the variable slot stays explicit, because `(catch y)` alone means
            # the *variable* `y`; a bare `catch` writes Julia's own `false`
            clause = Any[SSym("catch"),
                         sexp(a[2] !== false && a[2] !== nothing ? a[2] : false)]
            append!(clause, body_forms(a[3]))
            push!(items, SList(clause))
        end
        if length(a) >= 4 && a[4] !== false
            push!(items, SList(Any[SSym("finally"), body_forms(a[4])...]))
        end
        return SList(items)
    elseif h == :return
        return length(a) == 0 || a[1] === nothing ? SList(Any[SSym("return")]) :
                                                    SList(SSym("return"), sexp(a[1]))
    elseif h == :break
        return SList(Any[SSym("break")])
    elseif h == :continue
        return SList(Any[SSym("continue")])

    # ---- modules and declarations -----------------------------------------
    elseif h == :module
        # the first argument is the `baremodule` flag
        return SList(Any[SSym(a[1] === false ? "baremodule" : "module"),
                         sexp_name(a[2]), body_forms(a[3])...])
    elseif h in (:import, :using)
        return sexp_import(h, a)
    elseif h == :export
        return SList(Any[SSym("export"), map(sexp, a)...])
    elseif h == :const
        x = a[1]
        if x isa Expr && x.head == :(=)
            return SList(SSym("const"), sexp(x.args[1]), sexp(x.args[2]))
        end
        return SList(Any[SSym("const"), map(sexp, a)...])
    elseif h == :global || h == :local
        return SList(Any[SSym(string(h)), map(sexp, a)...])

    # ---- types -------------------------------------------------------------
    elseif h == :(::)
        # Only the two-name form fuses into the `x::T` atom. `(:: T)` is an
        # anonymous typed argument (not `T::Any`) and `(:: x A B)` a `Union`
        # shorthand, so both keep their argument count.
        if length(a) == 2 && a[1] isa Symbol && a[2] isa Symbol
            return SSym(string(unescapesym(string(a[1])), "::", string(a[2])))
        end
        return SList(Any[SSym("::"), map(sexp, a)...])
    elseif h == :curly
        return SList(Any[SSym("curly"), map(sexp, a)...])
    elseif h == :<:
        return SList(Any[SSym("<:"), map(sexp, a)...])
    elseif h == :where
        return SList(Any[SSym("where"), map(sexp, a)...])

    # ---- macros and quoting ------------------------------------------------
    elseif h == :macrocall
        name = macro_name(a[1])
        rest = Any[x for x in a[2:end] if !(x isa LineNumberNode)]
        if name in ("@int128_str", "@uint128_str") && !isempty(rest) &&
           rest[end] isa AbstractString
            # Julia prints large integer literals through these macros
            return SSym(rest[end])
        end
        if (name == "@doc" || endswith(name, ".@doc")) && length(rest) >= 2
            doc, target = rest[1], rest[2]
            sdoc, s = sexp(doc), sexp(target)
            # The reader stores a definition's docstring as a string atom,
            # so only a literal string can move into the `defn` body. An
            # interpolated docstring keeps the explicit `@doc` call so its
            # `(str …)` parts are not flattened into a plain string.
            if sdoc isa AbstractString && s isa SList && !isempty(s.items) &&
               s.items[1] isa SSym && s.items[1].name in ("defn", "deftype", "defmutable") &&
               length(s.items) >= 3
                items = Any[s.items[1], s.items[2], sdoc]
                append!(items, s.items[3:end])
                return SList(items)
            end
            return SList(SSym("@doc"), sdoc, s)
        end
        if !is_atom_macro_name(a[1])
            # `@$(Base).@__doc__` breaks into several atoms, so keep the name
            # as its own form and let the reader rebuild the macrocall
            return SList(Any[SSym("macrocall"), sexp(a[1]), map(sexp, rest)...])
        end
        return SList(Any[SSym(name), map(sexp, rest)...])
    elseif h == :quote
        # `$`-interpolation that came from Clojure's `~` carries `esc`. The
        # reader escapes *every* unquote inside a syntax-quote, so only a quote
        # whose interpolations are all `$(esc(...))` may be tagged that way; a
        # mixed quote stays a plain `quote`, which keeps each interpolation
        # exactly as it is.
        if has_interp(a[1]) && only_esc_interp(a[1])
            return SList(SSym("syntax-quote"), sexp_quoted(a[1]))
        end
        return SList(SSym("quote"), sexp(a[1]))
    elseif h == :$
        return SList(SSym("unquote"), sexp(a[1]))
    elseif h == :...
        return SList(SSym("splat"), sexp(a[1]))

    # ---- dot syntax --------------------------------------------------------
    elseif h == :.
        if length(a) == 2 && a[2] isa Expr && a[2].head == :tuple
            return SList(Any[SSym("broadcast"), sexp(a[1]),
                             map(sexp, a[2].args)...])
        end
        # `(.-)`, `(.+)`, … are broadcasted operators used as values. Import
        # lists (`import A: b`) use the same shape, but go through
        # `sexp_import`, so they never reach here.
        if length(a) == 1 && a[1] isa Symbol
            return SSym(string(".", unescapesym(string(a[1]))))
        end
        fields = Any[]
        obj = ex
        while obj isa Expr && obj.head == :. && length(obj.args) == 2
            field = dot_field_value(obj.args[2])
            field === nothing && break
            pushfirst!(fields, SSym(unescapesym_raw(string(field))))
            obj = obj.args[1]
        end
        # A field that is not a plain name (for example a quoted
        # interpolation) stays generic instead of recursing on itself.
        obj === ex && return SList(Any[SSym("."), map(sexp, a)...])
        return SList(Any[SSym("."), sexp(obj), fields...])

    # ---- operators ---------------------------------------------------------
    elseif h == :&& || h == :||
        items = Any[SSym(h == :&& ? "and" : "or"), map(sexp, a)...]
        return SList(items)
    elseif h == :comparison
        # a < b < c -> (and (< a b) (< b c))
        parts = Any[]
        i = 1
        while i + 2 <= length(a)
            push!(parts, SList(sexp(a[i+1]), sexp(a[i]), sexp(a[i+2])))
            i += 2
        end
        length(parts) == 1 && return parts[1]
        return SList(Any[SSym("and"); parts...])

    # ---- calls with special argument structure ----------------------------
    elseif h == :kw
        return SList(SSym("kw"), sexp(a[1]), sexp(a[2]))
    elseif h == :parameters
        return SList(Any[SSym("parameters"), map(sexp, a)...])
    elseif h == :generator || h == :comprehension || h == :typed_comprehension
        gen = h == :generator ? ex : (h == :comprehension ? a[1] : a[2])
        if gen isa Expr && gen.head == :generator
            binds, conds = Any[], Any[]
            function collect!(x)
                if x isa Expr && x.head == :filter
                    foreach(collect!, x.args)
                elseif x isa Expr && x.head == :(=)
                    push!(binds, param_sexp(x.args[1]), sexp(x.args[2]))
                else
                    push!(conds, sexp(x))
                end
            end
            foreach(collect!, gen.args[2:end])
            body = sexp(gen.args[1])
            tail = Any[SVec(binds), body, map(sexp, conds)...]
            h == :generator && return SList(Any[SSym("generator"), tail...])
            h == :comprehension && return SList(Any[SSym("comprehension"), tail...])
            form = SList(Any[SSym("generator"), tail...])
            return SList(SSym("typed_comprehension"), sexp(a[1]), form)
        end
        return SList(Any[SSym(string(h)), map(sexp, a)...])
    elseif h == :do
        return SList(SSym("do-call"), sexp(a[1]), sexp(a[2]))
    end

    # ---- fallback ----------------------------------------------------------
    return SList(Any[SSym(string(h)), map(sexp, a)...])
end

# ---------------------------------------------------------------------------
# helpers used by sexp
# ---------------------------------------------------------------------------

sexp_name(x::Symbol) = SSym(unescapesym(string(x)))
sexp_name(x) = SSym(symbol_text(x))

"Is `x` the left side of a short-form function definition?"
function is_function_signature(x)
    x isa Expr || return false
    x.head == :call && return true
    x.head in (:where, :(::)) && !isempty(x.args) &&
        return is_function_signature(x.args[1])
    return false
end

const COMPOUND_ASSIGN_HEADS = (:+=, :-=, :*=, :/=, :\=, :^=, :%=, :&=, :|=,
                               :<<=, :>>=)

"Keep the compound spelling where `(def …)` is not a valid expression."
function arg_sexp(x)
    x isa Expr && x.head in COMPOUND_ASSIGN_HEADS || return sexp(x)
    return SList(Any[SSym(string(x.head)), map(sexp, x.args)...])
end

"A name with type parameters and/or a supertype, in structured form."
type_sexp(x) = x isa Expr && x.head in (:curly, :<:) ? sexp(x) : sexp_name(x)

"Is every field of this dotted name an identifier, so it reads back as one atom?"
function is_atom_dotted_name(x)
    x isa Symbol && return true
    x isa GlobalRef && return true
    if x isa Expr && x.head == :. && !isempty(x.args)
        field = dot_field_value(x.args[end])
        field isa Symbol && Base.isidentifier(string(field)) || return false
        return is_atom_dotted_name(x.args[1])
    end
    return false
end

"A function name, including typed callable objects like `(:: f T)`."
function name_sexp(x)
    if x isa Expr && x.head == :(::) && length(x.args) <= 2
        return SList(Any[SSym("::"), map(name_sexp, x.args)...])
    elseif x isa Expr && x.head == :. && !is_atom_dotted_name(x)
        # `Base.//` is no symbol atom: keep the property access structured
        return sexp(x)
    end
    return type_sexp(x)
end

macro_name(s::Symbol) = string(s)
macro_name(g::GlobalRef) = string(g.name)
macro_name(e::Expr) = string("@", symbol_text(e))
macro_name(x) = string(x)

"Can this macro name be written as one `@…` atom, like `Base.@__doc__`?"
function is_atom_macro_name(x)
    x isa Symbol && return true
    x isa GlobalRef && return true
    x isa Expr && x.head == :. && length(x.args) == 2 || return false
    return is_atom_macro_name(x.args[1])
end

"Render one function parameter (or destructuring pattern)."
function param_sexp(x)
    if x isa Symbol
        return SSym(unescapesym(string(x)))
    elseif x isa Expr && (x.head == :kw || x.head == :(=))
        return SList(param_sexp(x.args[1]), sexp(x.args[2]))
    elseif x isa Expr && x.head == :(::)
        # `(::T)` is an anonymous typed argument: one argument, not two
        length(x.args) == 1 && return SList(SSym("::"), sexp(x.args[1]))
        name, t = x.args[1], x.args[2]
        if name isa Symbol && t isa Symbol
            return SSym(string(unescapesym(string(name)), "::", string(t)))
        elseif name isa Symbol
            return SList(SSym("::"), SSym(unescapesym(string(name))), sexp(t))
        else
            # `(:: …)` reads its name with the ordinary reader rather than
            # binding rules, so a destructuring pattern keeps the unambiguous
            # `(tuple …)` spelling instead of the `[…]` binding shorthand.
            return SList(Any[SSym("::"), sexp(name), sexp(t)])
        end
    elseif x isa Expr && x.head == :...
        return SList(SSym("&"), param_sexp(x.args[1]))
    elseif x isa Expr && x.head == :tuple
        return SVec(map(param_sexp, x.args))
    elseif x isa Expr && x.head == :parameters
        # Inside `(parameters …)` a two-item list is a keyword default and
        # `(& x)` is a keyword splat, exactly as in a positional parameter list.
        return SList(Any[SSym("parameters"), map(param_sexp, x.args)...])
    else
        return sexp(x)
    end
end

function sexp_params(x)
    if x isa Expr && x.head == :tuple
        return SVec(map(param_sexp, x.args))
    elseif x isa Expr && x.head == :parameters
        return SVec(map(param_sexp, x.args))
    else
        return SVec(Any[param_sexp(x)])
    end
end

"The expressions of `x`, splicing a `begin ... end` block."
function block_forms(x)
    x isa Expr && x.head == :block || return Any[x]
    return Any[a for a in x.args if !(a isa LineNumberNode)]
end

"Body forms of a block."
body_forms(x) = x === nothing ? Any[] : map(sexp, block_forms(x))

"One branch of an `if`: inline single expressions, `do` for sequences."
function branch(x)
    forms = block_forms(x)
    length(forms) == 1 && return sexp(forms[1])
    return SList(Any[SSym("do"), map(sexp, forms)...])
end

"Header of a function signature, preserving nested `where`/return types."
function function_header(sig)
    if sig isa Expr && sig.head == :where
        return SList(Any[SSym("where"), function_header(sig.args[1]),
                         map(sexp, sig.args[2:end])...])
    elseif sig isa Expr && sig.head == :(::) && length(sig.args) == 2
        return SList(Any[SSym("returns"), function_header(sig.args[1]),
                         sexp(sig.args[2])])
    elseif sig isa Expr && sig.head == :call
        callee = sig.args[1]
        if callee isa Expr && callee.head == :where
            # `(A{T} where T)(x) where S`: the inner `where` qualifies the
            # callee, so spell the call out instead of nesting it in `where`
            return SList(Any[SSym("call"), name_sexp(callee)])
        end
        return name_sexp(callee)
    end
    return name_sexp(sig)
end

function sexp_function(a)
    if length(a) == 1
        # `function f end` declares a method-less function
        return SList(Any[SSym("defn"), name_sexp(a[1])])
    end
    sig, body = a[1], a[2]
    base = sig
    while base isa Expr && base.head in (:where, :(::)) && !isempty(base.args)
        base = base.args[1]
    end
    if !(base isa Expr && base.head == :call)
        # anonymous function expression: `function (x) … end`
        return SList(Any[SSym("fn"), anon_params(sig, base), body_forms(body)...])
    end
    items = Any[SSym("defn"), function_header(sig),
                SVec(map(param_sexp, base.args[2:end]))]
    append!(items, body_forms(body))
    return SList(items)
end

function sexp_import(h, args)
    forms = Any[]
    for a in args
        if a isa Expr && a.head == COLON_HEAD
            mod = sexp_name(a.args[1])
            names = Any[SSym(symbol_text(x isa QuoteNode ? x.value : x))
                        for x in a.args[2:end]]
            push!(forms, SList(Any[SSym(string(h)), mod, names...]))
        else
            push!(forms, SList(SSym(string(h)), sexp_name(a)))
        end
    end
    length(forms) == 1 && return forms[1]
    return SList(Any[SSym("do"); forms...])
end

"Anonymous-function parameters, keeping a `where` clause: `[x]` or `(where [x] T)`."
function anon_params(sig, base)
    params = sexp_params(base)
    wheres = Any[]
    node = sig
    while node isa Expr && node.head == :where && length(node.args) >= 2
        append!(wheres, map(sexp, node.args[2:end]))
        node = node.args[1]
    end
    isempty(wheres) && return params
    return SList(Any[SSym("where"), params, wheres...])
end

"The name stored in an `a.b` node, or `nothing` for a non-name field."
function dot_field_value(f)
    f isa QuoteNode && return f.value
    f isa Expr && f.head == :quote && length(f.args) == 1 && return f.args[1]
    return nothing
end

"Does `x` contain a `\$` interpolation (outside nested quotes)?"
function has_interp(x)
    x isa Expr || return false
    x.head == :quote && return false          # nested quotes pick their own tag
    x.head == :$ && return true
    return any(has_interp, x.args)
end

"Is every `\$` interpolation in `x` exactly `\$(esc(...))`?"
function only_esc_interp(x)
    x isa Expr || return true
    x.head == :quote && return true           # nested quotes pick their own tag
    if x.head == :$ && length(x.args) == 1
        inner = x.args[1]
        return inner isa Expr && inner.head == :call &&
               length(inner.args) == 2 && inner.args[1] == :esc
    end
    return all(only_esc_interp, x.args)
end

"Sexps for the inside of a `quote`, where `\$`/`...` mean interpolation."
sexp_quoted(x) = fix_quoted_interp(sexp(x))

# Generic writing turns every interpolation into `(unquote (esc x))`, so undo
# the syntax-quote escaping and fold splatted interpolation back into `~@`.
strip_esc(x) = x isa SList && length(x.items) == 2 &&
               x.items[1] isa SSym && x.items[1].name == "esc" ? x.items[2] : x

fix_quoted_interp(x) = x
fix_quoted_interp(x::SVec) = SVec(Any[fix_quoted_interp(i) for i in x.items])
fix_quoted_interp(x::SSet) = SSet(Any[fix_quoted_interp(i) for i in x.items])
fix_quoted_interp(x::SMap) = SMap(Any[fix_quoted_interp(i) for i in x.items])
function fix_quoted_interp(x::SList)
    items = Any[fix_quoted_interp(i) for i in x.items]
    (length(items) == 2 && items[1] isa SSym) || return SList(items)
    head, arg = items[1].name, items[2]
    if head == "unquote"
        return SList(Any[items[1], strip_esc(arg)])
    elseif head == "splat"
        inner = strip_esc(arg)
        if inner isa SList && length(inner.items) == 2 &&
           inner.items[1] isa SSym && inner.items[1].name == "unquote"
            return SList(Any[SSym("unquote-splice"), inner.items[2]])
        end
    end
    return SList(items)
end

# ---------------------------------------------------------------------------
# printing
# ---------------------------------------------------------------------------

const CHAR_NAMES_OUT = Dict{Char,String}(v => k for (k, v) in CHAR_NAMES)

function char_string(c::Char)
    haskey(CHAR_NAMES_OUT, c) ? string("\\", CHAR_NAMES_OUT[c]) : string("\\", c)
end

function string_string(s::AbstractString)
    io = IOBuffer()
    write(io, '"')
    for c in s
        if c == '"'
            write(io, "\\\"")
        elseif c == '\\'
            write(io, "\\\\")
        elseif c == '\n'
            write(io, "\\n")
        elseif c == '\t'
            write(io, "\\t")
        elseif c == '\r'
            write(io, "\\r")
        else
            write(io, c)
        end
    end
    write(io, '"')
    String(take!(io))
end

function number_string(x::Number)
    x isa Rational && return string(x.num, "/", x.den)
    if x isa AbstractFloat && !isfinite(x)
        return isnan(x) ? "NaN" : x > 0 ? "Inf" : "-Inf"
    end
    # `string` drops the `f0` of a Float32, which would read back as a Float64
    return x isa Float32 ? repr(x) : string(x)
end

sexp_string(x::SList) = string("(", join(map(sexp_string, x.items), " "), ")")
sexp_string(x::SVec) = string("[", join(map(sexp_string, x.items), " "), "]")
sexp_string(x::SMap) = string("{", join(map(sexp_string, x.items), " "), "}")
sexp_string(x::SSet) = string("#{", join(map(sexp_string, x.items), " "), "}")
sexp_string(x::SSym) = x.name == "\\" ? "\\ " : x.name
sexp_string(x::SKeyword) = string(":", x.name)
sexp_string(::Nothing) = "nil"
sexp_string(x::Bool) = string(x)
sexp_string(x::Number) = number_string(x)
sexp_string(x::Char) = char_string(x)
sexp_string(x::AbstractString) = string_string(x)
sexp_string(x) = string(x)

# readable REPL display: `(defn f [x] (+ x 1))` instead of a nested struct dump
Base.show(io::IO, x::Union{SList,SVec,SMap,SSet,SSym,SKeyword}) =
    print(io, print_sexp(x))

"""
    print_sexp(data; width=88) -> String

Pretty-print s-expression data. Forms longer than `width` columns are broken
over several lines with two-space indentation.
"""
print_sexp(data; width::Int=88) = pretty(data, 0, width)

function pretty(x, indent::Int, width::Int)
    s = sexp_string(x)
    (indent + textwidth(s) <= width) && return s

    if x isa SList && !isempty(x.items)
        items = x.items
        firstline = string("(", sexp_string(items[1]))
        idx = 2
        if length(items) >= 2 && items[2] isa SVec
            v = sexp_string(items[2])
            if textwidth(firstline) + 1 + textwidth(v) <= width
                firstline = string(firstline, " ", v)
                idx = 3
            end
        end
        parts = String[firstline]
        for i in idx:length(items)
            push!(parts, string(repeat(" ", indent + 2),
                                pretty(items[i], indent + 2, width)))
        end
        return string(join(parts, "\n"), ")")
    elseif x isa SVec || x isa SMap || x isa SSet
        open, close = x isa SVec ? ("[", "]") :
                      x isa SMap ? ("{", "}") : ("#{", "}")
        parts = String[open]
        for (i, it) in enumerate(x.items)
            push!(parts, string(repeat(" ", indent + 2),
                                pretty(it, indent + 2, width)))
        end
        return string(join(parts, "\n"), close)
    end
    return s
end
