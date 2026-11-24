"""
Reader: convert parsed s-expression forms into Julia expressions.

The reader is the "language" part of the package. A list is a function call
unless its head is one of the special forms below; vectors, maps and sets
become Julia literals; quoted forms become data.

Supported special forms
=======================

Core      `do if when when-not cond let def fn defn defn- defmacro`
Binding   `fn`/`defn` parameter vectors support `& rest` varargs,
          defaults `(name value)`, type annotations `x::T`, and
          vector destructuring `[a b]`
Control   `for doseq while try break continue return`
Data      `aget aset! tuple dict set kw`
Types     `:: curly deftype defmutable where`
Modules   `module import use using export`
Macros    `quote syntax-quote unquote unquote-splice @name`
Threading `-> ->>`
Other     `and or && || const global local comprehension generator
           broadcast do-call splat`
"""

# ---------------------------------------------------------------------------
# symbol handling
# ---------------------------------------------------------------------------

# Julia operators (and a few reserved tokens) that must not be escaped or
# split on `/` and `.`.
const OPERATORS = Set([
    "+", "-", "*", "/", "\\", "^", "%", "//", "&", "|", "\$", ">>", "<<",
    ">>>", "==", "!=", "<", ">", "<=", ">=", "<:", ">:", "=>", "=", "!", "~", ":",
    ".", "::", "...", "?", "∘", "⊗", "->",
])

# Clojure names that have a natural Julia counterpart.
const BUILTIN_SYMBOLS = Dict{String,Any}(
    "="    => Symbol("=="),
    "not=" => Symbol("!="),
    "not"  => Symbol("!"),
    "mod"  => :mod,
    "str"  => :string,
)


const SPECIAL_FORMS = Set([
    "do", "if", "when", "when-not", "cond", "let", "def", "defn", "defn-",
    "fn", "lambda", "defmacro", "deftype", "defmutable", "defstruct",
    "for", "doseq", "while", "try", "break", "continue", "return",
    "module", "baremodule", "import", "use", "using", "export", "public",
    "outer", "aget", "aset!",
    "::", ":", "curly", "<:", ">:", "abstract", "primitive", "and", "or", "&&", "||", "quote", "syntax-quote",
    "tuple", "dict", "set", "kw", "parameters", "comprehension", "generator",
    "typed_comprehension",
    "broadcast", "do-call", "macrocall", "toplevel", "elseif", "splat", "where", "const", "global", "local",
    "->", "->>",
])

const COMPOUND_ASSIGN_OPS = Set(["+=", "-=", "*=", "/=", "\\=", "^=", "%=", "&=",
    "|=", "⊻=", "<<=", ">>=", ">>>=", "÷="])

const DOT_ASSIGN_OPS = Set([".=", ".+=", ".-=", ".*=", "./=", ".\\=", ".^=",
    ".%=", ".&=", ".|=", ".⊻=", ".<<=", ".>>=", ".>>>=", ".÷="])

"A dotted operator such as `.-`, `.==` or `.=` (not a `.method` call)."
isdot_operator(name::AbstractString) = length(name) > 1 && startswith(name, ".") &&
    !(isletter(name[2]) || name[2] == '_')

const LINE0 = LineNumberNode(0, :none)

"Is `name` a Julia operator rather than an identifier to be escaped?"
is_operator_name(name::AbstractString) =
    name in OPERATORS || Base.isoperator(String(name))

"The Julia symbol for a field name: operators stay verbatim, names are escaped."
field_symbol(name::AbstractString) =
    Symbol(is_operator_name(name) ? String(name) : escapesym(name))

"Build a `.` access for `obj` and an unescaped field name."
dot_field(obj, name::AbstractString) = Expr(:., obj, QuoteNode(field_symbol(name)))

"Dotted/namespaced symbol such as `Base.show`, `..GMP` or `module/fn`."
function dotted_symbol(name::AbstractString)
    segs = split(name, r"[./]")
    ndots = 0
    while ndots < length(segs) && isempty(segs[ndots+1])
        ndots += 1
    end
    if ndots > 0
        rest = segs[ndots+1:end]
        isempty(rest) && return Expr(:., map(_ -> Symbol("."), 1:ndots)...)
        e = Expr(:., map(_ -> Symbol("."), 1:ndots)...,
                Symbol(escapesym(rest[1])))
        for seg in rest[2:end]
            e = dot_field(e, seg)
        end
        return e
    end
    e = Symbol(escapesym(segs[1]))
    for seg in segs[2:end]
        isempty(seg) && continue
        e = if startswith(seg, "\$") && length(seg) > 1
            Expr(:., e, QuoteNode(Expr(:$, Symbol(seg[2:end]))))
        else
            dot_field(e, seg)
        end
    end
    e
end

"""
    parse_symbol(name) -> Union{Symbol, Expr}

Turn a Clojure symbol name into a Julia symbol, honouring dotted names
(`Base.show`) and type annotations (`x::Int`, `x::Int::Float64`).
"""
function parse_symbol(name::AbstractString)
    name in OPERATORS && return Symbol(name)
    # A bare broadcasted operator such as `.-` (as in `map(.-, xs)`).
    if isdot_operator(name) && !startswith(name[2:end], ".")
        return Expr(:., Symbol(name[2:end]))
    end
    # Any other Julia operator (e.g. `|>`) is a symbol, not an escaped name.
    Base.isoperator(String(name)) && return Symbol(name)
    # Julia splatting written as an atom: xs... -> xs...
    if endswith(name, "...") && length(name) > 3
        return Expr(:..., parse_symbol(name[1:end-3]))
    end
    parts = split(name, "::")
    base = dotted_symbol(parts[1])
    if length(parts) == 1
        return base
    elseif length(parts) == 2
        return Expr(:(::), base, parse_symbol(parts[2]))
    else
        return Expr(:(::), base,
                    Expr(:curly, :Union, map(parse_symbol, parts[2:end])...))
    end
end

"Decode the s-expression syntax escapes in a keyword atom body."
keyword_name(s::AbstractString) =
    String(map(c -> get(KEYWORD_UNESCAPES, c, c), s))

function read_atom(a::Atom)
    if a.kind == :nil
        return nothing
    elseif a.kind == :bool || a.kind == :number || a.kind == :string || a.kind == :char
        return a.value
    elseif a.kind == :keyword
        # A keyword names a Julia symbol, so its body is read back verbatim:
        # operator keywords stay operators (`:+=` is `Symbol("+=")`), and only
        # the s-expression syntax escapes are decoded (`:¦` is `Symbol(":")`).
        a.value == EMPTY_KEYWORD && return QuoteNode(Symbol(""))
        name = keyword_name(a.value)
        # An operator name like `:/=` has no namespace; any other `/` is the
        # Clojure namespace separator: :foo/bar -> Symbol("foo.bar").
        return QuoteNode(Symbol(is_operator_name(name) ? name :
                                replace(name, '/' => '.')))
    elseif a.kind == :symbol
        name = a.value
        haskey(BUILTIN_SYMBOLS, name) && return BUILTIN_SYMBOLS[name]
        if isempty(name) || (isdigit(first(name)))
            throw(InvalidTokenError(a.line, a.col, name))
        end
        return parse_symbol(name)
    end
    throw(InvalidTokenError(a.line, a.col, string(a.value)))
end

# ---------------------------------------------------------------------------
# entry points
# ---------------------------------------------------------------------------

quoted(inner) = inner isa QuoteNode ? inner : Meta.quot(inner)

"`~x` (or `~@x` with `splice`) interpolates; a syntax-quote also escapes."
function read_unquote(f::Form, item, splice::Bool, q)
    inner = read_form(item, :normal)
    # Clojure's syntax-quote (`...`) inserts caller code; Julia's quote
    # (:(...)) does not escape it.
    # `~(esc x)` is already escaped; adding another `esc` would double it.
    q === :syntax && !(inner isa Expr && inner.head == :call &&
                       !isempty(inner.args) && inner.args[1] == :esc) &&
        (inner = Expr(:call, :esc, inner))
    return splice ? Expr(:..., Expr(:$, inner)) : Expr(:$, inner)
end

"`Dict` pairs from a flat sequence of keys and values."
function read_pairs(f::Form, items, name::AbstractString,     q)
    isodd(length(items)) && throw(InvalidFormCountError(
        f.line, f.col, name, "an even number of forms", length(items), f))
    Any[Expr(:call, :(=>), read_form(items[i], q), read_form(items[i+1], q))
        for i in 1:2:length(items)]
end

build_set(items,     q) =
    Expr(:call, :Set, Expr(:vect, map(x -> read_form(x, q), items)...))

read_block(items,     q) = Expr(:block, map(x -> read_form(x, q), items)...)

"""
    read_form(x, mode=:normal) -> Any

Convert one parsed form (or atom) into a Julia expression. `~`/`~@`
interpolate; inside a syntax-quote (`mode == :syntax`) they are also escaped.
"""
read_form(a::Atom, q=:normal) = read_atom(a)

function read_form(f::Form, q=:normal)
    if f.kind == :list
        return read_list(f, q)
    elseif f.kind == :vect
        return Expr(:vect, map(x -> read_form(x, q), f.items)...)
    elseif f.kind == :map
        return Expr(:call, :Dict, read_pairs(f, f.items, "map", q)...)
    elseif f.kind == :set
        return build_set(f.items, q)
    elseif f.kind == :quote
        return quoted(read_form(f.items[1], :normal))
    elseif f.kind == :syntax_quote
        return Expr(:quote, read_form(f.items[1], :syntax))
    elseif f.kind == :unquote || f.kind == :unquote_splice
        return read_unquote(f, f.items[1], f.kind == :unquote_splice, q)
    end
    throw(InvalidFormStructureError(f.line, f.col, string(f.kind),
          "unknown form kind", f))
end

# ---------------------------------------------------------------------------
# lists: calls and special forms
# ---------------------------------------------------------------------------

function read_list(f::Form,     q=:normal)
    isempty(f.items) && return Expr(:tuple)

    head = f.items[1]
    if head isa Form && head.kind == :unquote
        return Expr(:call, read_unquote(head, head.items[1], false, q),
                    map(x -> read_form(x, q), f.items[2:end])...)
    end

    if head isa Atom && head.kind == :symbol
        name = head.value
        if name == "."
            return read_dot_access(f, q)
        elseif isdot_operator(name)
            args = map(x -> read_form(x, q), f.items[2:end])
            return name in DOT_ASSIGN_OPS ? Expr(Symbol(name), args...) :
                                               Expr(:call, Symbol(name), args...)
        elseif name in COMPOUND_ASSIGN_OPS
            need(f, name, 3)
            return Expr(Symbol(name), read_form(f.items[2], q),
                        read_form(f.items[3], q))
        elseif startswith(name, ".")
            return read_dot_call(f, q)
        elseif startswith(name, "@")
            return read_macrocall(f, q)
        elseif name == "unquote" || name == "unquote-splice"
            need(f, name, 2)
            return read_unquote(f, f.items[2], name == "unquote-splice", q)
        elseif name in SPECIAL_FORMS
            return read_special(name, f, q)
        end
        return Expr(:call, read_atom(head), map(x -> read_form(x, q), f.items[2:end])...)
    elseif head isa Atom && head.kind == :keyword
        throw(InvalidFormStructureError(f.line, f.col, "call",
              "a keyword cannot be called", f))
    else
        return Expr(:call, read_form(head, q),
                    map(x -> read_form(x, q), f.items[2:end])...)
    end
end

# helpers -------------------------------------------------------------------

function need(f, name, n)
    length(f.items) == n && return
    throw(InvalidFormCountError(f.line, f.col, name, "$n forms",
                                length(f.items), f))
end
function need_min(f, name, n)
    length(f.items) >= n && return
    throw(InvalidFormCountError(f.line, f.col, name,
                                "at least $n form(s)", length(f.items), f))
end
function need_between(f, name, lo, hi)
    lo <= length(f.items) <= hi && return
    throw(InvalidFormCountError(f.line, f.col, name,
                                "$lo to $hi forms", length(f.items), f))
end

function read_special(name::AbstractString, f::Form,     q)
    if name == "do"
        return Expr(:block, map(x -> read_form(x, q), f.items[2:end])...)

    elseif name == "if"
        need_between(f, "if", 3, 4)
        cond = read_form(f.items[2], q)
        then = read_form(f.items[3], q)
        length(f.items) == 4 ? Expr(:if, cond, then, read_form(f.items[4], q)) :
                               Expr(:if, cond, then)

    elseif name == "when"
        need_min(f, "when", 2)
        Expr(:if, read_form(f.items[2], q), read_block(f.items[3:end], q))

    elseif name == "when-not"
        need_min(f, "when-not", 2)
        Expr(:if, Expr(:call, :!, read_form(f.items[2], q)),
             read_block(f.items[3:end], q))

    elseif name == "cond"
        read_cond(f, q)

    elseif name == "let"
        read_let(f, q)

    elseif name == "def"
        need(f, "def", 3)
        Expr(:(=), read_binding(f.items[2], q), read_form(f.items[3], q))

    elseif name in ("defn", "defn-", "fn", "lambda")
        read_fn(f, q, name != "fn" && name != "lambda")

    elseif name == "defmacro"
        read_defmacro(f, q)

    elseif name in ("deftype", "defmutable", "defstruct")
        read_struct(f, name == "defmutable")

    elseif name in ("for", "doseq")
        read_for(f, q)

    elseif name == "while"
        need_min(f, "while", 2)
        Expr(:while, read_form(f.items[2], q), read_block(f.items[3:end], q))

    elseif name == "toplevel"
        # the group of statements one `;`-joined top-level line parsed into
        return Expr(:toplevel, map(x -> read_form(x, q), f.items[2:end])...)

    elseif name == "try"
        read_try(f, q)

    elseif name == "break"
        Expr(:break)

    elseif name == "continue"
        Expr(:continue)

    elseif name == "return"
        Expr(:return, length(f.items) >= 2 ? read_form(f.items[2], q) : nothing)

    elseif name == "module" || name == "baremodule"
        need_min(f, name, 2)
        mname = read_atom(f.items[2])
        mname isa Symbol || throw(InvalidFormStructureError(f.line, f.col,
            name, "module name must be a symbol", f))
        Expr(:module, name == "module", mname, read_block(f.items[3:end], q))

    elseif name in ("import", "use", "using", "export")
        read_import(name, f, q)

    elseif name == "public"
        Expr(:public, map(read_atom, f.items[2:end])...)

    elseif name == "aget"
        need_min(f, name, 2)
        Expr(:ref, map(x -> read_form(x, q), f.items[2:end])...)

    elseif name == "aset!"
        need_min(f, name, 4)
        target = Expr(:ref, map(x -> read_form(x, q), f.items[2:end-1])...)
        Expr(:(=), target, read_form(f.items[end], q))

    elseif name == "::"
        need_min(f, "::", 2)
        lhs = read_form(f.items[2], q)
        if length(f.items) == 2
            return Expr(:(::), lhs)
        elseif length(f.items) == 3
            Expr(:(::), lhs, read_form(f.items[3], q))
        else
            Expr(:(::), lhs,
                 Expr(:curly, :Union, map(x -> read_form(x, q), f.items[3:end])...))
        end

    elseif name == ":"
        need_between(f, ":", 2, 4)
        # `(: x)` is `x:end`, except that a single splatted argument can only
        # be a call to the `(:)` function itself, as in `(:)(xs...)`.
        splat = length(f.items) == 2 && f.items[2] isa Form &&
                f.items[2].kind == :list && !isempty(f.items[2].items) &&
                f.items[2].items[1] isa Atom &&
                f.items[2].items[1].kind == :symbol &&
                f.items[2].items[1].value == "splat"
        if length(f.items) == 2 && !splat
            return Expr(:call, COLON_HEAD, read_form(f.items[2], q), :end)
        elseif length(f.items) == 3 && f.items[3] isa Atom &&
               f.items[3].kind == :symbol && f.items[3].value == "end"
            return Expr(:call, COLON_HEAD, read_form(f.items[2], q), :end)
        end
        Expr(:call, COLON_HEAD, map(x -> read_form(x, q), f.items[2:end])...)

    elseif name == "curly"
        need_min(f, "curly", 2)
        Expr(:curly, map(x -> read_form(x, q), f.items[2:end])...)

    elseif name in ("and", "&&")
        fold_bool(:&&, f, q, true)

    elseif name in ("or", "||")
        fold_bool(:||, f, q, false)

    elseif name == "quote"
        need(f, "quote", 2)
        quoted(read_form(f.items[2], :normal))

    elseif name == "syntax-quote"
        need(f, "syntax-quote", 2)
        Expr(:quote, read_form(f.items[2], :syntax))

    elseif name == "tuple"
        Expr(:tuple, map(x -> read_form(x, q), f.items[2:end])...)

    elseif name == "dict"
        Expr(:call, :Dict, read_pairs(f, f.items[2:end], "dict", q)...)

    elseif name == "set"
        build_set(f.items[2:end], q)

    elseif name == "kw"
        need(f, "kw", 3)
        Expr(:kw, read_form(f.items[2], q), read_form(f.items[3], q))

    elseif name == "parameters"
        Expr(:parameters, read_params(f, q, 2)...)

    elseif name in ("comprehension", "generator")
        read_comprehension(f, q, name == "comprehension")

    elseif name == "typed_comprehension"
        need(f, name, 3)
        Expr(:typed_comprehension, read_form(f.items[2], q),
             read_form(f.items[3], q))

    elseif name == "broadcast"
        need_min(f, "broadcast", 2)
        Expr(:., read_form(f.items[2], q),
             Expr(:tuple, map(x -> read_form(x, q), f.items[3:end])...))

    elseif name == "do-call"
        need(f, "do-call", 3)
        Expr(:do, read_form(f.items[2], q), read_form(f.items[3], q))

    elseif name == "elseif"
        need_between(f, "elseif", 3, 4)
        Expr(:elseif, map(x -> read_form(x, q), f.items[2:end])...)

    elseif name == "splat"
        need(f, "splat", 2)
        Expr(:..., read_form(f.items[2], q))

    elseif name == "where"
        need_min(f, "where", 2)
        Expr(:where, map(x -> read_form(x, q), f.items[2:end])...)

    elseif name == "macrocall"
        # a macro name that is not one `@…` atom, e.g. `@$(Base).@__doc__`
        need_min(f, "macrocall", 2)
        return Expr(:macrocall, read_form(f.items[2], q), LINE0,
                    Any[read_form(x, q) for x in f.items[3:end]]...)

    elseif name == "outer"
        # `for outer i = …` (Julia 1.11) assigns to an existing variable
        need(f, "outer", 2)
        Expr(:outer, read_form(f.items[2], q))

    elseif name == "<:"
        need_between(f, "<:", 2, 3)
        Expr(:<:, map(x -> read_form(x, q), f.items[2:end])...)

    elseif name == ">:"
        # `A >: B` has its own AST head, like `<:`; Julia even normalises
        # the call spelling `(>:)(A, B)` to it. The one-argument form is the
        # bound shorthand in `Type{>:Nothing}`.
        need_between(f, ">:", 2, 3)
        Expr(:>:, map(x -> read_form(x, q), f.items[2:end])...)

    elseif name == "abstract"
        need(f, "abstract", 2)
        Expr(:abstract, read_form(f.items[2], q))

    elseif name == "primitive"
        need(f, "primitive", 3)
        Expr(:primitive, read_form(f.items[2], q), read_form(f.items[3], q))

    elseif name == "const"
        # `(const (global (def x 1)))` and a `const` struct field wrap a
        # single declaration instead of spelling `name value` directly.
        length(f.items) == 2 && return Expr(:const, read_form(f.items[2], q))
        need(f, "const", 3)
        Expr(:const, Expr(:(=), read_binding(f.items[2], q), read_form(f.items[3], q)))

    elseif name == "global"
        Expr(:global, map(x -> read_form(x, q), f.items[2:end])...)

    elseif name == "local"
        Expr(:local, map(x -> read_form(x, q), f.items[2:end])...)

    elseif name == "->"
        read_thread(f, q, false)

    elseif name == "->>"
        read_thread(f, q, true)
    else
        throw(InvalidFormStructureError(f.line, f.col, name,
              "not implemented as a special form", f))
    end
end

# ---------------------------------------------------------------------------
# individual special forms
# ---------------------------------------------------------------------------

function fold_bool(op::Symbol, f::Form,     q, empty::Bool)
    length(f.items) == 1 && return empty
    exprs = map(x -> read_form(x, q), f.items[2:end])
    reduce((a, b) -> Expr(op, a, b), exprs)
end

function read_cond(f::Form,     q)
    clauses = f.items[2:end]
    isodd(length(clauses)) && throw(InvalidFormCountError(
        f.line, f.col, "cond", "an even number of test/expression forms",
        length(clauses), f))
    out = nothing
    for i in length(clauses)-1:-2:1
        test = clauses[i]
        val = clauses[i+1]
        is_else = (test isa Atom && test.kind == :keyword && test.value == "else") ||
                  (test isa Atom && test.kind == :symbol && test.value == "else")
        if is_else
            out = read_form(val, q)
        else
            out = Expr(:if, read_form(test, q), read_form(val, q), out)
        end
    end
    out
end

read_binding(x, q=:normal) = x isa Form && x.kind == :vect ?
    Expr(:tuple, map(y -> read_binding(y, q), x.items)...) : read_form(x, q)

"Parse the `[binding value ...]` vector at `f.items[idx]` into assignments."
function read_bindings(f::Form, name::AbstractString, idx::Int,     q)
    v = f.items[idx]
    (v isa Form && v.kind == :vect) || throw(InvalidFormStructureError(
        f.line, f.col, name, "expected a vector of bindings", f))
    isodd(length(v.items)) && throw(InvalidFormCountError(
        v.line, v.col, name, "an even number of binding forms", length(v.items), f))
    Any[Expr(:(=), read_binding(v.items[i], q), read_form(v.items[i+1], q))
        for i in 1:2:length(v.items)]
end

"Let bindings: `[lhs rhs …]` pairs, or a block for bindings built at run time."
function read_let_bindings(f::Form, q)
    v = f.items[2]
    if v isa Form && v.kind == :vect
        return Expr(:block, read_bindings(f, "let", 2, q)...)
    end
    b = read_form(v, q)
    return b isa Expr && b.head == :block ? b : Expr(:block, b)
end

function read_let(f::Form,     q)
    # A trailing body is optional: `let x = 1 end` has an empty block.
    need_min(f, "let", 2)
    # Julia stores let bindings first, then the body block.
    Expr(:let, read_let_bindings(f, q), read_block(f.items[3:end], q))
end

# function definitions ------------------------------------------------------

"Does `x` hold the parameter vector of a function form?"
is_params_slot(x) = x isa Form && (x.kind == :vect ||
    (x.kind == :list && length(x.items) >= 2 && x.items[1] isa Atom &&
     x.items[1].kind == :symbol && x.items[1].value == "where" &&
     x.items[2] isa Form && x.items[2].kind == :vect))

function read_fn(f::Form, q, named::Bool)
    # a call to a function literally named `fn` has no parameter vector
    if !named && !any(is_params_slot, f.items[2:end])
        callee = f.items[1] isa Atom ? Symbol(f.items[1].value) : :fn
        return Expr(:call, callee, map(x -> read_form(x, q), f.items[2:end])...)
    end
    # `(fn name [x] ...)` is a named function even without `defn`
    if !named && length(f.items) >= 3 && f.items[2] isa Atom &&
       f.items[2].kind == :symbol
        named = true
    end
    # `(defn name)` declares a function with no methods: `function name end`
    if named && length(f.items) == 2
        return Expr(:function, read_form(f.items[2], q))
    end
    header = nothing
    i = 2
    if named
        length(f.items) < 3 && throw(InvalidFormStructureError(f.line, f.col,
            "function definition", "expected `name [params] body`", f))
        header = read_fn_header(f.items[2], q)
        i = 3
    end
    doc = nothing
    if i <= length(f.items) && f.items[i] isa Atom && f.items[i].kind == :string
        doc = f.items[i].value
        i += 1
    end
    slot = i <= length(f.items) ? f.items[i] : nothing
    wheres = Any[]
    if !named && slot isa Form && slot.kind == :list && !isempty(slot.items) &&
       slot.items[1] isa Atom && slot.items[1].kind == :symbol &&
       slot.items[1].value == "where"
        # `(fn (where [x] T) …)`: an anonymous function with `where` parameters
        need_min(slot, "where", 3)
        wheres = Any[read_form(x, q) for x in slot.items[3:end]]
        slot = slot.items[2]
    end
    (slot isa Form && slot.kind == :vect) ||
        throw(InvalidFormStructureError(f.line, f.col, "function definition",
            "expected a parameter vector", f))
    params = read_params(slot, q)
    bodyforms = map(x -> read_form(x, q), f.items[i+1:end])

    if named
        body = Expr(:block, bodyforms...)
        def = Expr(:function, add_fn_params(header, params), body)
    else
        # `->` parameter defaults are `x = 1`, not keyword arguments
        tparams = Any[p isa Expr && p.head == :kw ? Expr(:(=), p.args...) : p
                      for p in params]
        # Julia's parser always stores an arrow body as a block, including a
        # single expression; Base's printer relies on that shape for `do`.
        tuple = Expr(:tuple, tparams...)
        body = Expr(:block, bodyforms...)
        # a `where` clause needs the `function` shape: `(args…) where T` has no
        # arrow spelling
        def = isempty(wheres) ? Expr(:->, tuple, body) :
              Expr(:function, Expr(:where, tuple, wheres...), body)
    end

    if doc !== nothing
        return Expr(:macrocall, GlobalRef(Core, Symbol("@doc")), LINE0, doc, def)
    end
    return def
end

"Read a function header into a parameterless call, with `where`/return wrappers."
function read_fn_header(raw, q)
    if raw isa Form && raw.kind == :list && !isempty(raw.items) &&
       raw.items[1] isa Atom && raw.items[1].kind == :symbol
        kind = raw.items[1].value
        if kind == "where"
            need_min(raw, "where", 3)
            return Expr(:where, read_fn_header(raw.items[2], q),
                        map(x -> read_form(x, q), raw.items[3:end])...)
        elseif kind == "returns"
            need(raw, "returns", 3)
            return Expr(:(::), read_fn_header(raw.items[2], q),
                        read_form(raw.items[3], q))
        elseif kind == "call"
            # an explicit call header, for a callee that carries its own
            # `where`: `(call (where (curly A T) T))`
            need(raw, "call", 2)
            return Expr(:call, read_form(raw.items[2], q))
        end
    end
    name = read_form(raw, q)
    if raw isa Atom && name isa Expr && name.head == :(::) && length(name.args) == 2
        # legacy `(defn f::T ...)` spelling of a return type
        return Expr(:(::), Expr(:call, name.args[1]), name.args[2])
    end
    Expr(:call, name)
end

"Insert parameter expressions into the innermost call of a header."
function add_fn_params(x, params)
    x isa Expr || return x
    if x.head == :call
        return Expr(:call, x.args[1], params...)
    elseif x.head in (:where, :(::)) && length(x.args) >= 2
        return Expr(x.head, add_fn_params(x.args[1], params), x.args[2:end]...)
    end
    return x
end

"Is this list a `(name default)` optional-parameter form?"
function is_default_param(it)
    (it isa Form && it.kind == :list && length(it.items) == 2) || return false
    first = it.items[1]
    if first isa Atom && first.kind == :symbol
        v = first.value
        # anonymous typed parameters, nested parameter lists, call-site
        # keyword splats and unquotes are parameters themselves; `@macro`
        # wraps a name
        return !(v in ("::", "parameters", "splat", "unquote") ||
                 startswith(v, "@"))
    end
    # a form in the name slot is a pattern, e.g. `((:: T) default)`
    return first isa Form
end

function read_params(v::Form, q=:normal, from::Int=1)
    args = Any[]
    i = from
    while i <= length(v.items)
        it = v.items[i]
        if it isa Atom && it.kind == :symbol && it.value == "&"
            i == length(v.items) && throw(InvalidFormStructureError(
                v.line, v.col, "parameters", "`&` must be followed by a name", v))
            push!(args, Expr(:..., read_binding(v.items[i+1], q)))
            i += 2
        elseif it isa Form && it.kind == :list && !isempty(it.items) &&
               it.items[1] isa Atom && it.items[1].kind == :symbol &&
               it.items[1].value == "&"
            need(it, "&", 2)
            push!(args, Expr(:..., read_binding(it.items[2], q)))
            i += 1
        elseif is_default_param(it)
            # (name default) -> optional argument
            push!(args, Expr(:kw, read_binding(it.items[1], q),
                             read_form(it.items[2], q)))
            i += 1
        else
            push!(args, read_binding(it, q))
            i += 1
        end
    end
    args
end

function read_defmacro(f::Form,     q)
    need_min(f, "defmacro", 2)
    name = read_form(f.items[2], q)
    # `(defmacro f)` is a body-less declaration: `macro f end`
    length(f.items) == 2 && return Expr(:macro, name)
    pidx = findfirst(x -> x isa Form && x.kind == :vect, f.items[3:end])
    pidx === nothing && throw(InvalidFormStructureError(f.line, f.col,
        "defmacro", "expected a parameter vector", f))
    pidx += 2
    params = read_params(f.items[pidx], q)
    bodyforms = Any[read_form(x, q) for x in f.items[pidx+1:end]]
    body = Expr(:block, bodyforms...)
    Expr(:macro, Expr(:call, name, params...), body)
end

# data types ----------------------------------------------------------------

function read_struct(f::Form, mutable::Bool)
    length(f.items) >= 2 || throw(InvalidFormStructureError(f.line, f.col,
        "deftype", "expected `Name [fields] body...`", f))
    name = f.items[2] isa Atom ? read_atom(f.items[2]) : read_form(f.items[2], :normal)
    (name isa Symbol || (name isa Expr && name.head in (:curly, :<:))) ||
        throw(InvalidFormStructureError(f.line, f.col,
            "deftype", "type name must be a symbol or type expression", f))
    i = 3
    doc = nothing
    if i <= length(f.items) && f.items[i] isa Atom && f.items[i].kind == :string
        doc = f.items[i].value
        i += 1
    end
    fields = Any[]
    if i <= length(f.items) && f.items[i] isa Form && f.items[i].kind == :vect
        fields = Any[read_binding(x) for x in f.items[i].items]
        i += 1
    end
    body = map(x -> read_form(x, :normal), f.items[i:end])
    def = Expr(:struct, mutable, name, Expr(:block, fields..., body...))
    doc === nothing && return def
    Expr(:macrocall, GlobalRef(Core, Symbol("@doc")), LINE0, doc, def)
end

# loops ---------------------------------------------------------------------

function read_for(f::Form,     q)
    # the body is optional: `for i = 1:3 end` has an empty block
    need_min(f, "for", 2)
    assigns = read_bindings(f, "for", 2, q)
    iter = length(assigns) == 1 ? assigns[1] : Expr(:block, assigns...)
    Expr(:for, iter, read_block(f.items[3:end], q))
end

function read_comprehension(f::Form,     q, wrap::Bool)
    name = wrap ? "comprehension" : "generator"
    need_min(f, name, 3)
    binds = read_bindings(f, name, 2, q)
    conds = map(x -> read_form(x, q), f.items[4:end])
    genargs = isempty(conds) ? binds : Any[Expr(:filter, conds..., binds...)]
    gen = Expr(:generator, read_form(f.items[3], q), genargs...)
    wrap ? Expr(:comprehension, gen) : gen
end

# error handling ------------------------------------------------------------

function read_try(f::Form,     q)
    items = f.items[2:end]
    isempty(items) && throw(InvalidFormStructureError(f.line, f.col, "try",
        "expected a body and a catch/finally clause", f))

    is_clause(x, name) = x isa Form && x.kind == :list && !isempty(x.items) &&
        x.items[1] isa Atom && x.items[1].kind == :symbol && x.items[1].value == name
    catchidx = findfirst(x -> is_clause(x, "catch"), items)
    finallyidx = findfirst(x -> is_clause(x, "finally"), items)
    (catchidx === nothing && finallyidx === nothing) && throw(
        InvalidFormStructureError(f.line, f.col, "try",
            "expected a (catch ...) and/or (finally ...) clause", f))

    # catch/finally must be the trailing clauses
    finallyidx !== nothing && finallyidx != length(items) && throw(
        InvalidFormStructureError(f.line, f.col, "try",
            "catch/finally must be the last clauses", f))
    catchidx !== nothing && catchidx != length(items) &&
        catchidx != length(items) - 1 && throw(
        InvalidFormStructureError(f.line, f.col, "try",
            "catch/finally must be the last clauses", f))

    bodyend = min(catchidx === nothing ? length(items) : catchidx,
                  finallyidx === nothing ? length(items) : finallyidx) - 1
    body = read_block(items[1:bodyend], q)
    cvar = false
    cbody = false
    fbody = false
    if catchidx !== nothing
        clause = items[catchidx]
        start = 2
        slot = length(clause.items) >= 2 ? clause.items[2] : nothing
        if slot isa Atom && slot.kind == :symbol
            cvar = read_atom(slot)
            start = 3
        elseif slot isa Atom && slot.kind == :bool && slot.value === false
            # the explicit "no catch variable" slot of a bare `catch`
            start = 3
        end
        cbody = read_block(clause.items[start:end], q)
    end
    if finallyidx !== nothing
        clause = items[finallyidx]
        fbody = read_block(clause.items[2:end], q)
    end
    # Julia's parser omits the trailing `finally` slot for a catch-only
    # `try`, and comparison against parsed source is shape-sensitive.
    fbody === false && return Expr(:try, body, cvar, cbody)
    Expr(:try, body, cvar, cbody, fbody)
end

# modules / imports ---------------------------------------------------------

"""
    import_path(x) -> Expr

Julia's shape for a `using`/`import` name: one flat `.` expression whose
arguments are plain symbols, e.g. `using A.B` is `(using (. A B))` (not the
nested `(. (. A b) c)` used for value-position property access).
"""
function import_path(x)
    segs = Any[]
    collect_path_segments!(segs, x)
    return Expr(:., segs...)
end

function collect_path_segments!(segs::Vector{Any}, x)
    if x isa Expr && x.head == :.
        for a in x.args
            collect_path_segments!(segs, a)
        end
    else
        push!(segs, x isa QuoteNode ? x.value : x)
    end
    return segs
end

function read_import(name::AbstractString, f::Form,     q)
    items = f.items[2:end]
    if name == "export"
        return Expr(:export, map(read_atom, items)...)
    end
    isempty(items) && throw(InvalidFormStructureError(f.line, f.col, name,
        "expected a module name", f))
    head = name in ("use", "using") ? :using : :import
    mod = import_path(read_form(items[1], q))
    if length(items) == 1
        return Expr(head, mod)
    end
    names = Any[import_path(read_atom(x)) for x in items[2:end]]
    return Expr(head, Expr(COLON_HEAD, mod, names...))
end

# macros --------------------------------------------------------------------

function read_macrocall(f::Form,     q)
    head = f.items[1]::Atom
    mname = parse_macro_name(head.value)   # includes the leading @
    args = Any[read_form(x, q) for x in f.items[2:end]]
    Expr(:macrocall, mname, LINE0, args...)
end

"`@Base.@foo` names `@foo` in module `Base`, not a symbol with dots."
function parse_macro_name(name::AbstractString)
    startswith(name, "@") || return Symbol(name)
    rest = name[2:end]
    occursin(".", rest) || return Symbol(name)
    return dotted_symbol(rest)
end

# dot forms -----------------------------------------------------------------

"`(. obj field)` / `(. obj field1 field2)` property access."
function read_dot_access(f::Form,     q)
    length(f.items) >= 3 || throw(InvalidFormStructureError(f.line, f.col, ".",
        "expected an object and at least one field", f))
    obj = read_form(f.items[2], q)
    rest = f.items[3:end]
    # (. obj (method arg...)) is a method call
    if length(rest) == 1 && rest[1] isa Form && rest[1].kind == :list &&
       !isempty(rest[1].items) && rest[1].items[1] isa Atom &&
       rest[1].items[1].kind == :symbol
        m = rest[1]
        field = dot_field(obj, m.items[1].value)
        return Expr(:call, field, map(x -> read_form(x, q), m.items[2:end])...)
    end
    for x in rest
        (x isa Atom && x.kind == :symbol) || throw(InvalidFormStructureError(
            f.line, f.col, ".", "property names must be symbols", f))
        name = x.value
        obj = if startswith(name, "\$") && length(name) > 1
            # `.NAME.$field` is a quoted interpolation, not a literal `$field`
            Expr(:., obj, QuoteNode(Expr(:$, Symbol(name[2:end]))))
        else
            dot_field(obj, name)
        end
    end
    obj
end

function read_dot_call(f::Form,     q)
    head = f.items[1].value
    length(f.items) >= 2 || throw(InvalidFormStructureError(f.line, f.col, head,
        "expected an object", f))
    base = read_form(f.items[2], q)
    field = dot_field(base, head[2:end])
    return Expr(:call, field, map(x -> read_form(x, q), f.items[3:end])...)
end

# threading macros ----------------------------------------------------------

function read_thread(f::Form,     q, last::Bool)
    length(f.items) >= 2 || throw(InvalidFormCountError(f.line, f.col,
        last ? "->>" : "->", "at least 2 forms", length(f.items), f))
    x = f.items[2]
    for step in f.items[3:end]
        if step isa Form && step.kind == :list && !isempty(step.items)
            items = if last
                Any[step.items...; x]
            else
                Any[step.items[1]; x; step.items[2:end]...]
            end
            x = Form(:list, items, step.line, step.col)
        else
            x = Form(:list, Any[step, x], f.line, f.col)
        end
    end
    read_form(x, q)
end
