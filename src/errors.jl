"""
Error types used by the reader and parser.

Every error knows where in the source it happened (1-based line and column),
because a transpiler without source positions is no better than a segfault.
"""
abstract type SexprError <: Exception end

"An unexpected closing parenthesis/bracket/brace was found."
struct ExtraError <: SexprError
    line::Int
    col::Int
    c::Char
end

"A closing delimiter did not match the opening one."
struct MismatchedError <: SexprError
    line::Int
    col::Int
    expected::Char
    found::Char
end

"A form was opened but never closed."
struct UnclosedError <: SexprError
    line::Int
    col::Int
    c::Char
end

"A token could not be interpreted as any known atom."
struct InvalidTokenError <: SexprError
    line::Int
    col::Int
    token::AbstractString
end

"A form has the wrong number of elements."
struct InvalidFormCountError <: SexprError
    line::Int
    col::Int
    kind::AbstractString
    expected::AbstractString
    found::Int
    form::Any
end

"A form is structurally not valid (wrong nesting, wrong clause, ...)."
struct InvalidFormStructureError <: SexprError
    line::Int
    col::Int
    kind::AbstractString
    message::AbstractString
    form::Any
end

function Base.showerror(io::IO, e::ExtraError)
    print(io, "syntax error at line $(e.line):$(e.col): unexpected '$(e.c)'")
end

function Base.showerror(io::IO, e::MismatchedError)
    print(io, "syntax error at line $(e.line):$(e.col): expected '$(e.expected)', ",
          "found '$(e.found)'")
end

function Base.showerror(io::IO, e::UnclosedError)
    print(io, "syntax error: missing closing '$(e.c)' for form opened at line ",
          "$(e.line):$(e.col)")
end

function Base.showerror(io::IO, e::InvalidTokenError)
    print(io, "syntax error at line $(e.line):$(e.col): invalid token ",
          repr(e.token))
end

function Base.showerror(io::IO, e::InvalidFormCountError)
    print(io, "syntax error at line $(e.line):$(e.col): `$(e.kind)` takes ",
          "$(e.expected), got $(e.found) in $(e.form)")
end

function Base.showerror(io::IO, e::InvalidFormStructureError)
    print(io, "syntax error at line $(e.line):$(e.col): invalid `$(e.kind)` ",
          "form: $(e.message) in $(e.form)")
end
