"""
Small helpers shared by the reader and the writer: symbol name escaping.
"""

# ---------------------------------------------------------------------------
# symbol name escaping
# ---------------------------------------------------------------------------

# Clojure is much more permissive about symbol characters than Julia. We map
# the extra characters onto Unicode lookalikes (readable), or onto ASCII
# escape sequences (for downstream tooling that only speaks ASCII).
const UNICODE_ESCAPES = Dict{Char,Char}(
    '*' => '°',
    '?' => 'ʔ',
    '+' => '⁺',
    '-' => '¯',
    '\'' => '′',
    '<' => '∠',
    '>' => '▻',
    ':' => '¦',
)

const UNICODE_UNESCAPES = Dict{Char,Char}(v => k for (k, v) in UNICODE_ESCAPES)

# Julia identifier → Clojure name, except that `′` stays a literal prime:
# `deps′` is a legal Julia identifier in its own right, and mapping it to `'`
# would make it indistinguishable from the (escaped) apostrophe `’`.
const NAME_UNESCAPES =
    Dict{Char,Char}(v => k for (k, v) in UNICODE_ESCAPES if k != '\'')

# `var"..."` names may contain characters that are syntax in s-expressions
# (spaces separate forms, `#` starts discard/dispatch, `'` quotes). The writer
# spells them with lookalikes; only these positions decode them back. The
# apostrophe uses `’`, not the usual lookalike `′`: the latter is a legal
# Julia identifier character (`deps′`), so escaping `'` to it would make the
# two names indistinguishable when reading the s-expression back.
const SYMBOL_ESCAPES = Dict{Char,Char}(' ' => '␣', '#' => '♯', '\'' => '’')
const SYMBOL_UNESCAPES = Dict{Char,Char}(v => k for (k, v) in SYMBOL_ESCAPES)

# Keyword atoms (`:name`) name a Julia symbol, so they are written verbatim
# rather than through the Clojure-name escapes; only characters that are
# s-expression syntax get a lookalike. A leading `:` is escaped too, so the
# keyword `:¦` (the symbol `Symbol(":")`) is distinct from the atom `::` (the
# symbol `Symbol("::")`). The empty symbol, which has no atom spelling, is
# written `:␀`.
const KEYWORD_ESCAPES = Dict{Char,Char}(' ' => '␣', '\'' => '’')
const KEYWORD_UNESCAPES = Dict{Char,Char}(
    '␣' => ' ', '’' => '\'', '♯' => '#', '¦' => ':')
const EMPTY_KEYWORD = "␀"

const ASCII_CODES = Dict{Char,Char}(
    '*' => 's',
    '?' => 'q',
    '+' => 'p',
    '-' => 'd',
    '\'' => 'a',
    '<' => 'l',
    '>' => 'g',
    ':' => 'c',
)

const ASCII_UNCODES = Dict{Char,Char}(v => k for (k, v) in ASCII_CODES)

# `str` is the Clojure alias for `string`, so a Julia variable literally named
# `str` needs a distinct spelling. The private-use marker cannot collide with a
# normal Julia identifier and is only produced when writing such a symbol.
const ESCAPED_STR_SYMBOL = "str\ue000"

"Whether symbols are escaped to ASCII-only names. See [`set_ascii_names!`](@ref)."
const ASCII_NAMES = Ref(false)

"""
    set_ascii_names!(flag::Bool)

Choose how Clojure symbol characters that Julia does not allow are encoded.
With `false` (the default) they become Unicode lookalikes (`foo?` → `fooʔ`);
with `true` they become ASCII escapes (`foo?` → `foo_q`, `foo_bar` → `foo__bar`).

Returns the previous setting.
"""
set_ascii_names!(flag::Bool) = (old = ASCII_NAMES[]; ASCII_NAMES[] = flag; old)

ascii_names() = ASCII_NAMES[]

"""
    escapesym(s) -> String

Encode a Clojure symbol segment as a valid Julia identifier segment.
"""
function escapesym(s::AbstractString)
    s == ESCAPED_STR_SYMBOL && return "str"
    io = IOBuffer()
    if ASCII_NAMES[]
        for c in s
            if c == '_'
                write(io, "__")
            elseif haskey(ASCII_CODES, c)
                write(io, '_')
                write(io, ASCII_CODES[c])
            else
                write(io, c)
            end
        end
    else
        # A syntax escape (`␣`, `♯`, `’`) is decoded as-is, so `’` becomes the
        # literal apostrophe; other characters go through the name escapes.
        for c in s
            write(io, get(SYMBOL_UNESCAPES, c, get(UNICODE_ESCAPES, c, c)))
        end
    end
    String(take!(io))
end

"""
    unescapesym(s) -> String

Inverse of [`escapesym`](@ref): recover the Clojure spelling of a Julia
symbol segment.
"""
function unescapesym(s::AbstractString)
    s == "str" && return ESCAPED_STR_SYMBOL
    return unescapesym_raw(s)
end

"Unescape without reserving `str`; for keyword and property-name positions."
function unescapesym_raw(s::AbstractString; syntax::Bool=true)
    io = IOBuffer()
    chars = collect(s)
    i = 1
    if ASCII_NAMES[]
        while i <= length(chars)
            c = chars[i]
            if c == '_' && i < length(chars)
                n = chars[i+1]
                if n == '_'
                    write(io, '_')
                    i += 2
                    continue
                elseif haskey(ASCII_UNCODES, n)
                    write(io, ASCII_UNCODES[n])
                    i += 2
                    continue
                end
            end
            write(io, c)
            i += 1
        end
    else
        while i <= length(chars)
            write(io, get(NAME_UNESCAPES, chars[i], chars[i]))
            i += 1
        end
    end
    s = String(take!(io))
    syntax || return s
    String(map(c -> get(SYMBOL_ESCAPES, c, c), s))
end
