"""
The public pipeline: s-expression source to Julia expressions and back.
"""

# ---------------------------------------------------------------------------
# s-expression -> Julia
# ---------------------------------------------------------------------------

"""
    transpile(source::AbstractString) -> Vector{Any}

Translate s-expression source into a vector of top-level Julia expressions.

```julia
julia> transpile("(defn add [a b] (+ a b))")
1-element Vector{Any}:
 function add(a, b)
     a + b
 end
```
"""
function transpile(source::AbstractString)
    forms = parse_source(source)
    # A `(toplevel …)` form is data: it stands for the group of statements one
    # `;`-joined top-level line parsed into, not for a wrapper to split.
    return Any[read_form(f) for f in forms]
end

"""
    transpile_expr(source) -> Any

Translate a source string that contains exactly one form.
"""
function transpile_expr(source::AbstractString)
    exprs = transpile(source)
    length(exprs) == 1 ? exprs[1] : Expr(:block, exprs...)
end

# ---------------------------------------------------------------------------
# Julia -> s-expression
# ---------------------------------------------------------------------------

"""
    detranspile(input) -> String

Translate Julia source (or an already parsed `Expr`) into s-expression source.

```julia
julia> print(detranspile("function add(a, b)\n a + b\nend"))
(defn add [a b] (+ a b))
```
"""
function detranspile(source::AbstractString)
    detranspile(Meta.parseall(source))
end

function detranspile(ex::Expr)
    ex.head == :toplevel || return print_sexp(sexp(ex))
    parts = [print_sexp(sexp(a)) for a in ex.args if !(a isa LineNumberNode)]
    return join(parts, "\n\n")
end

detranspile(x) = print_sexp(sexp(x))

"""
    to_sexpr(x)

Convert a Julia value or expression into s-expression data (nested
`SList`/`SVec`/`SMap`/`SSet`/`SSym`/`SKeyword` nodes). Useful for macros and
for inspecting what [`detranspile`](@ref) will print.
"""
to_sexpr(x) = sexp(x)

# ---------------------------------------------------------------------------
# data -> Julia (for macros)
# ---------------------------------------------------------------------------

"""
    rehydrate(data) -> Expr

Turn s-expression *data* back into a Julia expression. This is the function to
use when a macro or a script builds a form programmatically:

```julia
julia> Sexpr.rehydrate(Sexpr.SList(Sexpr.SSym("+"), 1, 2))
:(1 + 2)
```

`SList` and Julia tuples are lists, `SVec` and `Vector` are vectors, `Dict` is
a map, `Set` is a set, and plain `Symbol`s are symbols.
"""
rehydrate(x::Expr) = x
rehydrate(data) = read_form(data_to_form(data))

data_to_form(x::SSym) = Atom(:symbol, x.name, 0, 0)
data_to_form(x::SKeyword) = Atom(:keyword, x.name, 0, 0)
data_to_form(::Nothing) = Atom(:nil, nothing, 0, 0)
data_to_form(x::Bool) = Atom(:bool, x, 0, 0)
data_to_form(x::Number) = Atom(:number, x, 0, 0)
data_to_form(x::AbstractString) = Atom(:string, String(x), 0, 0)
data_to_form(x::Char) = Atom(:char, x, 0, 0)
data_to_form(x::Symbol) = Atom(:symbol, string(x), 0, 0)
data_to_form(x::SList) = Form(:list, Any[data_to_form(i) for i in x.items], 0, 0)
data_to_form(x::SVec) = Form(:vect, Any[data_to_form(i) for i in x.items], 0, 0)
data_to_form(x::SMap) = Form(:map, Any[data_to_form(i) for i in x.items], 0, 0)
data_to_form(x::SSet) = Form(:set, Any[data_to_form(i) for i in x.items], 0, 0)
data_to_form(x::Tuple) = Form(:list, Any[data_to_form(i) for i in x], 0, 0)
data_to_form(x::AbstractVector) = Form(:vect, Any[data_to_form(i) for i in x], 0, 0)
function data_to_form(x::AbstractDict)
    items = Any[]
    for (k, v) in x
        push!(items, data_to_form(k), data_to_form(v))
    end
    Form(:map, items, 0, 0)
end
function data_to_form(x::AbstractSet)
    Form(:set, Any[data_to_form(i) for i in x], 0, 0)
end

# ---------------------------------------------------------------------------
# macros
# ---------------------------------------------------------------------------

"""
    @clj_str "..."
    clj"..."

Compile s-expression source at macro-expansion time.

```julia
julia> clj"(+ 1 2)"
3
```
"""
macro clj_str(str)
    str isa AbstractString || error("@clj_str expects a string literal")
    transpile_expr(str)
end
