"""
Printing Julia expressions as source code.

Julia 0.4's hand-written formatter is no longer needed: modern Julia ships a
printer (`Base.show_unquoted`) that emits parseable source for every
expression the reader can build. We only normalise the tree first so that
incidental line markers and one-expression `begin ... end` wrappers do not
show up in the output.
"""

"""
    normalize(ex)

Drop `LineNumberNode`s and unwrap one-expression `begin ... end` blocks.
"""
normalize(x) = x
normalize(::LineNumberNode) = nothing
function normalize(ex::Expr)
    args = Any[]
    for (i, a) in enumerate(ex.args)
        if a isa LineNumberNode
            # `Base.show_unquoted` expects the line marker right after a macro
            # name; without it it prints the macro with no arguments.
            ex.head == :macrocall && i == 2 && push!(args, a)
            continue
        end
        push!(args, normalize(a))
    end
    out = Expr(ex.head, args...)
    # Leave blocks (function bodies, let bodies, lambda bodies and
    # `x = begin ... end`) alone: the printer needs them and dropping a
    # one-expression block changes the round trip.
    if out.head == :-> && length(out.args) == 2
        body = out.args[2]
        if body isa Expr && body.head == :block && length(body.args) == 1
            return Expr(:->, out.args[1], body.args[1])
        end
    end
    # `do` syntax needs a block-bodied lambda; an expression body is printed
    # as a statement list by the stock printer.
    if out.head == :do && length(out.args) == 2
        l = out.args[2]
        if l isa Expr && l.head == :-> && length(l.args) == 2 &&
           !(l.args[2] isa Expr && l.args[2].head == :block)
            out.args[2] = Expr(:->, l.args[1], Expr(:block, l.args[2]))
        end
    end
    return out
end

"""
    format(ex) -> String

Render a Julia expression as source code.
"""
const FUNCTION_NAME_PLACEHOLDERS = Dict{Any,String}(
    Symbol("&") => "__SEXPR_OP_FN_AMP__",
    Symbol("::") => "__SEXPR_OP_FN_COLONS__",
    Symbol("...") => "__SEXPR_OP_FN_SPLAT__",
    Symbol(":") => "__SEXPR_OP_FN_COLON__",
    Symbol(".") => "__SEXPR_OP_FN_DOT__",
)

"The literal text of a big-number builtin macro (`@uint128_str`, …), or `nothing`."
function literal_macro_text(ex::Expr)
    ex.head == :macrocall || return nothing
    macro_name(ex.args[1]) in ("@int128_str", "@uint128_str", "@big_str") ||
        return nothing
    # The literal's flags argument is `nothing` (a LineNumberNode on older
    # Julia versions); only the literal text itself remains.
    args = [a for a in ex.args[2:end]
            if !(a isa LineNumberNode) && a !== nothing && a !== :nothing]
    (length(args) == 1 && args[1] isa AbstractString) || return nothing
    return String(args[1])
end

function format(ex)
    ex = fix_operator_function_names(normalize(ex))
    # A wide literal is a builtin macro call that `is_special` renders as the
    # literal itself, which is what parses and evaluates to the same value.
    s = if ex isa Expr && ex.head == :toplevel
        format_toplevel(ex)
    elseif ex isa Expr && ex.head == :macrocall && !is_wide_literal(ex)
        format_macrocall(ex)
    elseif ex isa Expr && ex.head in (:import, :using, :export)
        # the stock printer does not render these at top level
        format_directive(ex)
    else
        # `show_unquoted` prints quoted expressions, raw interpolation nodes
        # and nested directives as `$(Expr(...))`, so render them ourselves.
        render_substituted(ex, is_special, format_special)
    end
    return restore_operator_function_names(s)
end

function restore_operator_function_names(s)
    for (name, token) in FUNCTION_NAME_PLACEHOLDERS
        s = replace(s, token => string("(", name, ")"))
    end
    return s
end

"Let Base print operator-named functions with a placeholder, then parenthesize."
function fix_operator_function_names(x)
    x isa Expr || return x
    out = Expr(x.head, Any[fix_operator_function_names(a) for a in x.args]...)
    if out.head == :function && !isempty(out.args)
        out.args[1] = fix_signature_name(out.args[1])
    end
    return out
end

function fix_signature_name(sig)
    token = get(FUNCTION_NAME_PLACEHOLDERS, _signature_name(sig), nothing)
    token === nothing && return sig
    return replace_signature_name(sig, Symbol(token))
end

function _signature_name(sig)
    while sig isa Expr && sig.head in (:where, :(::)) && !isempty(sig.args)
        sig = sig.args[1]
    end
    sig isa Symbol && return sig
    sig isa Expr && sig.head == :call && !isempty(sig.args) && return sig.args[1]
    return nothing
end

function replace_signature_name(sig, name)
    if sig isa Expr && sig.head == :call
        return Expr(:call, name, sig.args[2:end]...)
    elseif sig isa Expr && sig.head in (:where, :(::)) && !isempty(sig.args)
        return Expr(sig.head, replace_signature_name(sig.args[1], name),
                    sig.args[2:end]...)
    end
    return name
end

is_interp(x) = x isa Expr && length(x.args) == 1 &&
               (x.head == :quote || x.head == :$)
is_directive(x) = x isa Expr && x.head in (:import, :using, :export)
is_quote_symbol(x) = x isa QuoteNode && x.value isa Symbol
is_dot_interp(x) = x isa Expr && x.head == :. && length(x.args) == 2 &&
    x.args[2] isa QuoteNode && x.args[2].value isa Expr &&
    x.args[2].value.head == :$
is_ref(x) = x isa Expr && x.head == :ref
is_colon_symbol(x) = x === Symbol(":")
is_outer(x) = x isa Expr && x.head == :outer && length(x.args) == 1
is_unary_minus(x) = x isa Expr && x.head == :call && length(x.args) == 2 &&
                    x.args[1] === Symbol("-")
is_wide_literal(x) = x isa Expr && literal_macro_text(x) !== nothing

is_special(x) = is_interp(x) || is_directive(x) || is_quote_symbol(x) ||
                is_dot_interp(x) || is_ref(x) || is_colon_symbol(x) ||
                is_outer(x) || is_unary_minus(x) || is_wide_literal(x)

format_interp(x) = x.head == :quote ? format_quoted(x.args[1]) :
                   string("\$(", format(x.args[1]), ")")

format_colon_symbol(::Symbol) = "(:)"
format_outer(x) = string("outer ", format(x.args[1]))
# `-(x)` still binds looser than `^`, so keep parentheses around the whole
# negation: `(-(x))^p` must not print as `-(x)^p`. The inner call parentheses
# also keep `-(f(x)...)` a splat argument rather than a splatted call.
format_unary_minus(x) = string("(-(", format(x.args[2]), "))")

function format_quote_symbol(x)
    name = string(x.value)
    Base.isidentifier(name) && return string(":", name)
    # An operator keeps Julia's own spelling: `:\=`, `:~`, but `:(=)` and
    # `:(::)` for the operators that are also syntax. `escape_string` into
    # `:var\"…\"` would double a backslash and change the symbol.
    is_operator_name(name) && return sprint(Base.show_unquoted, x)
    return string(":var\"", escape_string(name), "\"")
end

function format_dot_interp(x)
    field = x.args[2].value
    return string(format(x.args[1]), ".", format_interp(field))
end

is_assignment(x) = x isa Expr && x.head == :(=) && length(x.args) == 2
is_range(x) = x isa Expr && x.head == :call && !isempty(x.args) &&
    x.args[1] === Symbol(":") && 2 <= length(x.args) <= 4
"Would Base parenthesize `x` when it is the target of an index expression?"
function ref_object_parenthesized(x)
    (x isa Expr || x isa QuoteNode) || return false
    return startswith(sprint(Base.show_unquoted, Expr(:ref, x, 0)), "(")
end

function format_ref(x)
    target = x.args[1]
    obj = format(target)
    # `(a::T)[i]`, `(a -> b)[i]` and ranges need the parentheses Base adds.
    if (is_range(target) || ref_object_parenthesized(target)) &&
       !startswith(obj, "(")
        obj = string("(", obj, ")")
    end
    args = map(x.args[2:end]) do a
        is_assignment(a) ? string(format(a.args[1]), " = ",
                                  format(a.args[2])) : format(a)
    end
    return string(obj, "[", join(args, ", "), "]")
end

format_special(x) = is_directive(x) ? format_directive(x) :
    is_wide_literal(x) ? literal_macro_text(x) :
    is_quote_symbol(x) ? format_quote_symbol(x) :
    is_dot_interp(x) ? format_dot_interp(x) :
    is_ref(x) ? format_ref(x) :
    is_colon_symbol(x) ? format_colon_symbol(x) :
    is_outer(x) ? format_outer(x) :
    is_unary_minus(x) ? format_unary_minus(x) : format_interp(x)

format(forms::AbstractVector) = join(map(format, forms), "\n\n")

print_unquoted(ex) = sprint(Base.show_unquoted, ex)

"Print `ex`, replacing nodes selected by `select` with `render`ed text."
function render_substituted(ex, select, render)
    subs = String[]
    s = strip_line_markers(print_unquoted(_substitute(ex, subs, select, render)))
    for (i, t) in enumerate(subs)
        s = replace(s, "__SEXPR_SUB_$(i)__()" => t)
    end
    return s
end

function _substitute(x::Expr, subs::Vector{String}, select, render, in_cond::Bool=false)
    # Julia's printer omits the parentheses an assignment condition needs.
    if in_cond && x.head == :(=)
        push!(subs, string("(", render_substituted(x, select, render), ")"))
        return Expr(:call, Symbol("__SEXPR_SUB_", length(subs), "__"))
    end
    if select(x)
        push!(subs, render(x))
        return Expr(:call, Symbol("__SEXPR_SUB_", length(subs), "__"))
    end
    # A `QuoteNode` in field position is part of `a.b`; the stock printer
    # handles it and it must not acquire the standalone `:b` spelling.
    if x.head == :. && length(x.args) == 2 && x.args[2] isa QuoteNode
        return Expr(:., _substitute(x.args[1], subs, select, render), x.args[2])
    end
    # `1:n` needs its colon head left alone; `(:)` is only for value positions.
    if x.head == :call && !isempty(x.args) && x.args[1] === Symbol(":")
        return Expr(:call, x.args[1],
                    Any[_substitute(a, subs, select, render) for a in x.args[2:end]]...)
    end
    return Expr(x.head, Any[_substitute(a, subs, select, render,
        x.head in (:if, :while) && i == 1) for (i, a) in enumerate(x.args)]...)
end
function _substitute(s::Symbol, subs::Vector{String}, select, render, in_cond::Bool=false)
    select(s) || return s
    push!(subs, render(s))
    return Expr(:call, Symbol("__SEXPR_SUB_", length(subs), "__"))
end

function _substitute(q::QuoteNode, subs::Vector{String}, select, render, in_cond::Bool=false)
    select(q) || return q
    push!(subs, render(q))
    return Expr(:call, Symbol("__SEXPR_SUB_", length(subs), "__"))
end
# Strings are always substituted verbatim: `strip_line_markers` must not
# rewrite their contents (a docstring can legitimately contain `#= … =#`).
function _substitute(x::AbstractString, subs::Vector{String}, select, render, in_cond::Bool=false)
    push!(subs, sprint(Base.show_unquoted, String(x)))
    return Expr(:call, Symbol("__SEXPR_SUB_", length(subs), "__"))
end
_substitute(x, subs::Vector{String}, select, render, in_cond::Bool=false) = x

"Render the inside of a quoted expression, including `\$` interpolation."
function format_quoted(inner)
    inner isa Symbol && return string(":", inner)
    inner isa QuoteNode && return string(":", symbol_text(inner))
    # Always keep the `:(...)` wrapper: `:($x)` and `$x` parse differently.
    # Dotted interpolation inside a quote (`Base.FastMath.$(f)`) needs the
    # same `$field` spelling as a top-level dot access.
    s = render_substituted(inner, x -> is_interp(x) || is_dot_interp(x),
                           x -> is_dot_interp(x) ? format_dot_interp(x) :
                                                   format_interp(x))
    return string(":(", s, ")")
end

strip_line_markers(s::AbstractString) = replace(s, r"#=[^=]*=#\s*" => "")

"`Expr(:toplevel, …)` is one `;`-joined line, and only the trailing `;` parses back as a `:toplevel`."
function format_toplevel(ex::Expr)
    stmts = [format(a) for a in ex.args if !(a isa LineNumberNode)]
    return string(join(stmts, "; "), ";")
end

function format_macrocall(ex::Expr)
    name = macro_name_string(ex.args[1])
    args = Any[a for a in ex.args[2:end] if !(a isa LineNumberNode)]
    isempty(args) && return name
    return string(name, "(", join(map(format, args), ", "), ")")
end

macro_name_string(s::Symbol) = string(s)
macro_name_string(g::GlobalRef) = string(g.mod, ".", g.name)
function macro_name_string(e::Expr)
    if e.head == :. && length(e.args) == 2 && e.args[2] isa QuoteNode
        # `Base.@__doc__` prefixes the module with `@`, but an interpolation is
        # Julia's own spelling already: `$(Base).@__doc__`
        mod = e.args[1]
        head = mod isa Symbol || mod isa GlobalRef ? macro_name_string(mod) : string(mod)
        return string(head, ".", e.args[2].value)
    end
    return string("@", e)
end
macro_name_string(x) = string(x)

"An imported name; `:` must stay parenthesized so it is not quoting."
function directive_name(x)
    value = x isa QuoteNode ? x.value :
            (x isa Expr && x.head == :. && length(x.args) == 1 ? x.args[1] : x)
    value === Symbol(":") && return "(:)"
    x isa QuoteNode && return directive_name(x.value)
    if x isa Symbol
        s = string(x)
        # Operators and macro names stay bare; only names that are syntax
        # characters need Julia's `var"..."` spelling.
        if any(c -> isspace(c) || c in ('\'', '#', ',', ';', '(', ')', '[', ']',
                                       '{', '}', '"'), s)
            return sprint(Base.show_unquoted, x)
        end
        # A bare prime (`′`) is neither an identifier nor an operator token,
        # so the lexer rejects it here and it needs `var"..."` too.
        Base.isidentifier(s) || Base.isoperator(s) || startswith(s, "@") ||
            return sprint(Base.show_unquoted, x)
        return s
    end
    return symbol_text(x)
end

function format_directive(ex::Expr)
    kw = string(ex.head)
    parts = String[]
    for a in ex.args
        if a isa GlobalRef
            push!(parts, string(a.mod, ".", a.name))
        elseif a isa Expr && a.head == COLON_HEAD
            names = join(map(directive_name, a.args[2:end]), ", ")
            push!(parts, string(symbol_text(a.args[1]), ": ", names))
        else
            push!(parts, directive_name(a))
        end
    end
    return string(kw, " ", join(parts, ", "))
end
