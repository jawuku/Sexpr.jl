"""
Tokenizer and parser for the s-expression surface syntax.

Source text becomes a tree of [`Atom`](@ref) and [`Form`](@ref) nodes, keeping
line/column information for error reporting. The reader (`reader.jl`) then
turns that tree into Julia expressions.

The concrete syntax is Clojure-flavoured:

    (defn add [a b] (+ a b))   ; a list is a call or a special form
    [1 2 3]                    ; a vector
    {:a 1 :b 2}                ; a map
    #{1 2 3}                   ; a set
    'x  `(~a ~@b)              ; quote / syntax-quote
    \\u03bb                    ; character literal
    #_ignored                  ; discard the next form
"""

# ---------------------------------------------------------------------------
# tokens
# ---------------------------------------------------------------------------

# `Expr(:(:), ...)` uses the `Colon()` object, not the symbol the parser puts
# in range expressions, so spell it out explicitly.
const COLON_HEAD = Symbol(":")

struct Token
    kind::Symbol   # :lparen :rparen :lbrack :rbrack :lbrace :rbrace :lset
                   # :quote :syntax_quote :unquote :unquote_splice
                   # :string :char :atom :discard
    text::String
    line::Int
    col::Int
end

# ---------------------------------------------------------------------------
# parsed forms
# ---------------------------------------------------------------------------

"""
    Atom(kind, value, line, col)

A leaf of the s-expression tree. `kind` is one of `:symbol`, `:keyword`,
`:number`, `:string`, `:char`, `:bool` or `:nil`; `value` is the already
converted Julia value (a `String` name for keywords, a `Char`, etc.).
"""
struct Atom
    kind::Symbol
    value::Any
    line::Int
    col::Int
end

"""
    Form(kind, items, line, col)

A compound s-expression. `kind` is one of `:list`, `:vect`, `:map`, `:set`,
`:quote`, `:syntax_quote`, `:unquote` or `:unquote_splice`.
"""
struct Form
    kind::Symbol
    items::Vector{Any}
    line::Int
    col::Int
end

# ---------------------------------------------------------------------------
# scanner
# ---------------------------------------------------------------------------

mutable struct Scanner
    chars::Vector{Char}
    i::Int
    line::Int
    col::Int
end

Scanner(s::AbstractString) = Scanner(collect(s), 1, 1, 1)

isdone(sc::Scanner) = sc.i > length(sc.chars)
peekc(sc::Scanner) = isdone(sc) ? '\0' : sc.chars[sc.i]
peekc2(sc::Scanner) = sc.i + 1 > length(sc.chars) ? '\0' : sc.chars[sc.i + 1]

function takec!(sc::Scanner)
    c = sc.chars[sc.i]
    sc.i += 1
    if c == '\n'
        sc.line += 1
        sc.col = 1
    else
        sc.col += 1
    end
    c
end

"Characters that end an atom."
# `~` is not one: it only marks unquote when it *starts* a token, so
# `:~` stays one atom instead of becoming `:` and `~`.
isdelim(c::Char) = isspace(c) || c == ',' || c == '(' || c == ')' ||
                   c == '[' || c == ']' || c == '{' || c == '}' ||
                   c == '"' || c == ';' || c == '`'

# ---------------------------------------------------------------------------
# tokenizer
# ---------------------------------------------------------------------------

"""
    tokenize(src) -> Vector{Token}

Split source text into structural tokens, atoms, strings and character
literals. Comments (`;` to end of line) and commas count as whitespace.
"""
const DELIMITER_TOKENS = Dict('(' => :lparen, ')' => :rparen,
                               '[' => :lbrack, ']' => :rbrack,
                               '{' => :lbrace, '}' => :rbrace)

function tokenize(src::AbstractString)
    sc = Scanner(src)
    toks = Token[]
    while !isdone(sc)
        line, col = sc.line, sc.col
        c = peekc(sc)

        if c == '\n' || isspace(c) || c == ','
            takec!(sc)
        elseif c == ';'
            while !isdone(sc) && peekc(sc) != '\n'
                takec!(sc)
            end
        elseif haskey(DELIMITER_TOKENS, c)
            takec!(sc)
            push!(toks, Token(DELIMITER_TOKENS[c], string(c), line, col))
        elseif c == '#' && peekc2(sc) == '{'
            takec!(sc); takec!(sc)
            push!(toks, Token(:lset, "#{", line, col))
        elseif c == '#' && peekc2(sc) == '_'
            takec!(sc); takec!(sc)
            push!(toks, Token(:discard, "#_", line, col))
        elseif c == '\''
            takec!(sc); push!(toks, Token(:quote, "'", line, col))
        elseif c == '`'
            takec!(sc); push!(toks, Token(:syntax_quote, "`", line, col))
        elseif c == '~'
            takec!(sc)
            nxt = isdone(sc) ? '\0' : peekc(sc)
            if nxt == '@'
                takec!(sc)
                push!(toks, Token(:unquote_splice, "~@", line, col))
            elseif nxt == '\0' || isspace(nxt) || nxt in (',', ')', ']', '}', ';')
                # `~` as the bitwise-not operator, as in the list `(~ a)`;
                # Clojure's unquote is the prefix form `~x`.
                push!(toks, Token(:atom, "~", line, col))
            else
                push!(toks, Token(:unquote, "~", line, col))
            end
        elseif c == '"'
            push!(toks, scan_string!(sc, line, col))
        elseif c == '\\'
            # `\` alone is the left-division operator; a character literal is
            # a backslash followed by any other character. A bare operator is
            # spaced by the writer, so `\)` in particular is the char `')'`.
            nxt = peekc2(sc)
            if isdone(sc) || isspace(nxt)
                takec!(sc)
                push!(toks, Token(:atom, "\\", line, col))
            else
                push!(toks, scan_char!(sc, line, col))
            end
        elseif c == '#'
            # unknown dispatch macro: point the error at the offending char
            takec!(sc)
            buf = IOBuffer()
            while !isdone(sc) && !isdelim(peekc(sc))
                write(buf, takec!(sc))
            end
            throw(InvalidTokenError(line, col, string('#', String(take!(buf)))))
        else
            buf = IOBuffer()
            while !isdone(sc)
                ch = peekc(sc)
                isdelim(ch) && break
                # `#` opens a set/discard only at a token boundary; inside a
                # symbol it is just a character (as in gensym-ish names)
                ch == '#' && (peekc2(sc) == '{' || peekc2(sc) == '_') && break
                write(buf, takec!(sc))
            end
            push!(toks, Token(:atom, String(take!(buf)), line, col))
        end
    end
    toks
end

function scan_string!(sc::Scanner, line::Int, col::Int)
    buf = IOBuffer()
    write(buf, takec!(sc))              # opening quote
    closed = false
    while !isdone(sc)
        c = peekc(sc)
        if c == '\\'
            write(buf, takec!(sc))
            isdone(sc) && break
            write(buf, takec!(sc))
        elseif c == '"'
            write(buf, takec!(sc))
            closed = true
            break
        else
            write(buf, takec!(sc))
        end
    end
    closed || throw(UnclosedError(line, col, '"'))
    Token(:string, String(take!(buf)), line, col)
end

function scan_char!(sc::Scanner, line::Int, col::Int)
    buf = IOBuffer()
    write(buf, takec!(sc))              # the backslash
    isdone(sc) && throw(InvalidTokenError(line, col, "\\"))
    c = peekc(sc)
    if isletter(c) || isdigit(c) || c == '\\'
        while !isdone(sc) && !isdelim(peekc(sc))
            write(buf, takec!(sc))
        end
    else
        # a literal punctuation character, e.g. \(
        write(buf, takec!(sc))
    end
    Token(:char, String(take!(buf)), line, col)
end

# ---------------------------------------------------------------------------
# numbers
# ---------------------------------------------------------------------------

# The sign is stripped before matching, except for floats which keep it.
const RE_INT    = r"^[0-9]+$"
const RE_BASED  = r"^0(?:[xX][0-9a-fA-F]+|[bB][01]+|[oO][0-7]+)$"
const RE_RADIX  = r"^([0-9]+)[rR]([0-9a-zA-Z]+)$"
const RE_RATIO  = r"^([0-9]+)/([0-9]+)$"
const RE_BIGINT = r"^[0-9]+[nN]$"
const RE_FLOAT  = r"^-?(?:[0-9]+\.[0-9]+(?:[eE][+-]?[0-9]+)?|\.[0-9]+(?:[eE][+-]?[0-9]+)?|[0-9]+[eE][+-]?[0-9]+)$"
# `Float32` literals carry an `f` exponent (`1.0f0`, `6.1f-5`), which
# `parse(Float64, …)` rejects.
const RE_FLOAT32 = r"^-?(?:[0-9]+\.[0-9]*|\.[0-9]+|[0-9]+)f[+-]?[0-9]+$"

parse_int(s, base) = try
    parse(Int, s; base=base)
catch e
    e isa OverflowError ? parse(BigInt, s; base=base) : rethrow(e)
end

# The second argument of the builtin literal macro is version-specific
# (`:nothing` in 1.11); copy whatever the running parser produces.
const WIDE_LITERAL_FLAGS =
    let e = Meta.parse("0x1" * "0"^16)      # 65 bits: does not fit UInt64
        e isa Expr && e.head == :macrocall && length(e.args) >= 3 ?
            e.args[2] : LineNumberNode(0, :none)
    end

"""
    based_wide_literal(s) -> Union{Expr,Nothing}

Julia parses a base-prefixed literal that does not fit `UInt64` as a call to
its `@uint128_str` builtin (and prints that call back as the literal), so the
reader produces the same expression instead of an integer value.
"""
function based_wide_literal(s::AbstractString)
    occursin(RE_BASED, s) || return nothing
    base = s[2] in ('x', 'X') ? 16 : s[2] in ('b', 'B') ? 2 : 8
    v = try
        parse_int(s[3:end], base)
    catch
        return nothing
    end
    v isa Integer && v > typemax(UInt64) || return nothing
    # Julia names the builtin macro by width.
    name = v > typemax(UInt128) ? "@big_str" : "@uint128_str"
    return Expr(:macrocall, GlobalRef(Core, Symbol(name)),
                WIDE_LITERAL_FLAGS, String(s))
end

"""
    parse_number(s) -> Union{Number, Nothing}

Interpret `s` as a number using Clojure-ish literal forms (`42`, `-1.5`,
`0xff`, `2r1010`, `3/5`, `12N`). Returns `nothing` when `s` is not a number.
"""
function parse_number(s::AbstractString)
    isempty(s) && return nothing
    occursin(RE_FLOAT32, s) && return parse(Float32, replace(s, 'f' => 'e'))
    occursin(RE_FLOAT, s) && return parse(Float64, s)
    neg = startswith(s, "-")
    body = neg ? s[2:end] : s
    v = if occursin(RE_INT, body)
        parse_int(body, 10)
    elseif occursin(RE_BASED, body)
        b = body[2] in ('x', 'X') ? 16 : body[2] in ('b', 'B') ? 2 : 8
        parse_int(body[3:end], b)
    elseif occursin(RE_RADIX, body)
        m = match(RE_RADIX, body)
        base = parse(Int, m[1])
        (2 <= base <= 62) || return nothing
        parse_int(m[2], base)
    elseif occursin(RE_RATIO, body)
        m = match(RE_RATIO, body)
        den = parse_int(m[2], 10)
        den == 0 && return nothing
        parse_int(m[1], 10) // den
    elseif occursin(RE_BIGINT, body)
        parse(BigInt, body[1:end-1])
    else
        return nothing
    end
    return neg ? -v : v
end

# ---------------------------------------------------------------------------
# atoms
# ---------------------------------------------------------------------------

const CHAR_NAMES = Dict(
    "newline"   => '\n',
    "space"     => ' ',
    "tab"       => '\t',
    "formfeed"  => '\f',
    "vtab"      => '\v',
    "comma"     => ',',
    "backspace" => '\b',
    "return"    => '\r',
    "nul"       => '\0',
)

function parse_char_literal(tok::Token)
    s = tok.text[2:end]                 # drop the backslash
    if haskey(CHAR_NAMES, s)
        return CHAR_NAMES[s]
    elseif startswith(s, "u") && length(s) == 5
        return Char(parse(UInt32, s[2:end]; base=16))
    elseif startswith(s, "o") && length(s) > 1
        return Char(parse(UInt32, s[2:end]; base=8))
    elseif length(s) == 1
        return s[1]
    else
        throw(InvalidTokenError(tok.line, tok.col,
              "character literal $(tok.text) (use a named or single-character escape)"))
    end
end

const STRING_ESCAPES = Dict{Char,Char}('n' => '\n', 't' => '\t', 'r' => '\r',
                                      'b' => '\b', 'f' => '\f', '"' => '"',
                                      '\\' => '\\', '/' => '/', '$' => '$')

"Unescape the body of a double-quoted string literal."
function unescape_string_body(s::AbstractString)
    buf = IOBuffer()
    i = firstindex(s)
    while i <= lastindex(s)
        c = s[i]
        if c == '\\'
            i = nextind(s, i)
            i > lastindex(s) && break
            e = s[i]
            if haskey(STRING_ESCAPES, e)
                write(buf, STRING_ESCAPES[e])
            elseif e == 'u'
                if i < lastindex(s) && s[nextind(s, i)] == '{'
                    close = findnext('}', s, i)
                    close === nothing && throw(ArgumentError("unterminated \\u{...} escape"))
                    write(buf, Char(parse(UInt32, s[nextind(s, i, 2):prevind(s, close)]; base=16)))
                    i = close
                else
                    j = min(lastindex(s), nextind(s, i, 4))
                    write(buf, Char(parse(UInt32, s[nextind(s, i):j]; base=16)))
                    i = j
                end
            elseif e == 'x'
                j = min(lastindex(s), nextind(s, i, 2))
                write(buf, Char(parse(UInt32, s[nextind(s, i):j]; base=16)))
                i = j
            else
                throw(ArgumentError("unknown string escape \\$e"))
            end
        else
            write(buf, c)
        end
        i = nextind(s, i)
    end
    String(take!(buf))
end

function atom_from_token(tok::Token)
    s = tok.text
    if tok.kind == :string
        body = s[2:prevind(s, lastindex(s))]
        return Atom(:string, unescape_string_body(body), tok.line, tok.col)
    elseif tok.kind == :char
        return Atom(:char, parse_char_literal(tok), tok.line, tok.col)
    elseif s == "nil"
        return Atom(:nil, nothing, tok.line, tok.col)
    elseif s == "true"
        return Atom(:bool, true, tok.line, tok.col)
    elseif s == "false"
        return Atom(:bool, false, tok.line, tok.col)
    elseif s == ":"
        # the range operator, not an empty keyword
        return Atom(:symbol, s, tok.line, tok.col)
    elseif startswith(s, ":") &&
           (!startswith(s, "::") || (length(s) > 2 && all(c -> c == ':', s)))
        return Atom(:keyword, String(s[2:end]), tok.line, tok.col)
    end
    wide = based_wide_literal(s)
    wide === nothing || return Atom(:number, wide, tok.line, tok.col)
    n = parse_number(s)
    n === nothing || return Atom(:number, n, tok.line, tok.col)
    Atom(:symbol, String(s), tok.line, tok.col)
end

# ---------------------------------------------------------------------------
# parser
# ---------------------------------------------------------------------------

"""
    parse_source(src) -> Vector{Any}

Parse a whole source string into top-level `Atom`/`Form` nodes.
"""
function parse_source(src::AbstractString)
    toks = tokenize(src)
    i = Ref(1)
    forms = Any[]
    while i[] <= length(toks)
        f = parse_form(toks, i)
        f === nothing || push!(forms, f)
    end
    forms
end

"Parse one form; returns `nothing` for a discarded form."
function parse_form(toks::Vector{Token}, i::Ref{Int})
    i[] > length(toks) && return nothing
    tok = toks[i[]]
    i[] += 1

    if tok.kind == :lparen
        return Form(:list, parse_until(toks, i, :rparen, ')', tok), tok.line, tok.col)
    elseif tok.kind == :lbrack
        return Form(:vect, parse_until(toks, i, :rbrack, ']', tok), tok.line, tok.col)
    elseif tok.kind == :lbrace
        return Form(:map, parse_until(toks, i, :rbrace, '}', tok), tok.line, tok.col)
    elseif tok.kind == :lset
        return Form(:set, parse_until(toks, i, :rbrace, '}', tok), tok.line, tok.col)
    elseif tok.kind in (:quote, :syntax_quote, :unquote, :unquote_splice)
        inner = parse_form(toks, i)
        return Form(tok.kind, Any[inner], tok.line, tok.col)
    elseif tok.kind in (:rparen, :rbrack, :rbrace)
        throw(ExtraError(tok.line, tok.col, tok.text[1]))
    elseif tok.kind == :discard
        parse_form(toks, i)             # discard this form
        return nothing
    else
        return atom_from_token(tok)
    end
end

function parse_until(toks::Vector{Token}, i::Ref{Int}, close::Symbol, expected::Char,
                     open::Token)
    items = Any[]
    while true
        if i[] > length(toks)
            throw(UnclosedError(open.line, open.col, expected))
        end
        tok = toks[i[]]
        if tok.kind == close
            i[] += 1
            return items
        elseif tok.kind in (:rparen, :rbrack, :rbrace)
            throw(MismatchedError(tok.line, tok.col, expected, tok.text[1]))
        else
            f = parse_form(toks, i)
            f === nothing || push!(items, f)
        end
    end
end
