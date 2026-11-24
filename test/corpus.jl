#!/usr/bin/env julia
"""
Round-trip corpus harness for Sexpr.jl.

For every file it checks the full round trip

    Julia source --detranspile--> s-expressions --transpile--> Julia --format--> text

and reports three things:

  * reparse: the generated Julia text must parse again, including cases
    where `Meta.parseall` returns an `Expr(:error)` node instead of throwing;
  * AST equivalence: the round-tripped expressions must equal the originals
    modulo source locations, blocks and the lowerings this package documents
    (short-form functions, `+=`, chained comparisons, ...);
  * idempotence: detranspiling the generated text must reproduce the same
    s-expression source.

Usage:
    julia --project=. test/corpus.jl                     # Julia's base/ tree
    julia --project=. test/corpus.jl --budget 120
    julia --project=. test/corpus.jl --limit 20
    julia --project=. test/corpus.jl --dir path/to/src
    julia --project=. test/corpus.jl --self              # built-in snippets only

This is a diagnostic tool, not part of the test suite: it reports how far the
transpiler gets on real code instead of asserting that it gets everything.
`test/runtests.jl` checks the shared snippet list (`--self`) on every run; the
base/ corpus is only ever run from here.
"""

using Sexpr

const BASE_DIR = normpath(joinpath(Sys.BINDIR, "..", "share", "julia", "base"))

# ---------------------------------------------------------------------------
# AST canonicalisation
#
# The equivalence rules (and the snippet corpus) are shared with the test
# suite, so they live in `roundtrip.jl`; only the diagnostic harness is here.
# ---------------------------------------------------------------------------

include(joinpath(@__DIR__, "roundtrip.jl"))

hstr(h) = h isa Colon ? ":" : string(h)

# ---------------------------------------------------------------------------
# structural diff
# ---------------------------------------------------------------------------

shortstr(x) = (s = sprint(show, x); length(s) > 90 ? first(s, 87) * "..." : s)

function first_diff(a, b, path::String="ast", ctx::String="top")
    isequal(a, b) && return nothing
    if a isa Expr && b isa Expr
        if !isequal(a.head, b.head)
            return ("head $(hstr(a.head))->$(hstr(b.head))",
                    "$path: head $(hstr(a.head)) vs $(hstr(b.head))")
        end
        if length(a.args) != length(b.args)
            return ("arity $(hstr(a.head))",
                    "$path: $(length(a.args)) vs $(length(b.args)) args")
        end
        for i in eachindex(a.args)
            d = first_diff(a.args[i], b.args[i], "$path.$(hstr(a.head))[$i]",
                           hstr(a.head))
            d === nothing || return d
        end
    end
    return ("value in $ctx", "$path: $(shortstr(a)) vs $(shortstr(b))")
end

# ---------------------------------------------------------------------------
# statistics
# ---------------------------------------------------------------------------

mutable struct Stats
    processed::Int
    skipped::Int
    files_failed::Int
    aborted::Int
    forms::Int
    ast_checked::Int
    ast_equal::Int
    reparse_checked::Int
    reparse_ok::Int
    idem_checked::Int
    idem_ok::Int
    failures::Dict{String,Int}
    examples::Dict{String,Vector{String}}
    lowerings::Dict{String,Int}
end
Stats() = Stats(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, Dict{String,Int}(),
                Dict{String,Vector{String}}(), Dict{String,Int}())

function record!(s::Stats, cat::AbstractString, example::AbstractString)
    s.failures[cat] = get(s.failures, cat, 0) + 1
    ex = get!(s.examples, cat, String[])
    length(ex) < 3 && push!(ex, String(example))
end

bump!(s::Stats, key::AbstractString) = (s.lowerings[key] = get(s.lowerings, key, 0) + 1)

"Count the documented (lossy) lowerings exercised by an expression."
function count_lowerings(x, s::Stats)
    x isa Expr || return
    h = x.head
    if h == :(=) && length(x.args) == 2 && x.args[1] isa Expr && x.args[1].head == :call
        bump!(s, "short-form function")
    elseif h in (:+=, :-=, :*=, :/=, :%=, :^=, :&=, :|=)
        bump!(s, "operator assignment")
    elseif h == :comparison
        bump!(s, "chained comparison")
    elseif h == :string
        bump!(s, "string interpolation")
    elseif h == :->
        bump!(s, "anonymous function")
    elseif h == :call && x.args[1] === :tuple
        bump!(s, "tuple constructor call")
    elseif h == :macrocall && any(a -> a isa GlobalRef && a.name == Symbol("@doc"),
                                  x.args[1:1])
        bump!(s, "docstring")
    elseif h == :quote && any(a -> a isa Expr && a.head == :$, x.args)
        bump!(s, "quote interpolation")
    elseif h in ARRAY_LITERAL_HEADS
        bump!(s, "array literal (vcat/hcat family)")
    end
    for a in x.args
        count_lowerings(a, s)
    end
end

describe(e) = string(nameof(typeof(e)), ": ",
                     first(split(sprint(showerror, e), '\n')))

firstline(s) = first(split(s, '\n'))


function describe_parse_error(node::Expr)
    isempty(node.args) && return string(node.head)
    a = node.args[1]
    if a isa Base.Meta.ParseError
        # `ParseError.msg` looks like
        #
        #     ParseError:
        #     # Error @ none:3:25
        #     <source line>
        #     #   ╙ ── message
        #
        # so keep the location and the diagnostic, not the source line.
        lines = split(a.msg, '\n')
        loc = findfirst(l -> startswith(l, "# Error @"), lines)
        loc === nothing && return replace(a.msg, "\n" => " ")
        where_ = strip(lstrip(lines[loc], '#'))
        diag = findnext(l -> startswith(l, "# ") && occursin("──", l),
                        lines, loc + 1)
        diag === nothing && return where_
        parts = split(lines[diag], "──", limit=2)
        return length(parts) == 2 ? "$where_: $(strip(parts[2]))" : where_
    end
    return shortstr(a)
end

"The first frame inside this package, for attributing a failure."
function sexpr_frame(bt)
    for fr in stacktrace(bt)
        f = string(fr.file)
        occursin("/src/", f) && return string(basename(f), ":", fr.line)
    end
    return ""
end

"Group errors by what actually broke and where, not just \"transpile error\"."
function error_category(prefix::AbstractString, e, bt=nothing)
    cat = if e isa MethodError
        "$prefix: MethodError $(e.f)"
    elseif e isa BoundsError
        "$prefix: BoundsError (malformed form)"
    elseif e isa Sexpr.InvalidFormStructureError
        "$prefix: invalid $(e.kind) form"
    elseif e isa Sexpr.InvalidFormCountError
        "$prefix: arity ($(e.kind))"
    else
        "$prefix: $(nameof(typeof(e)))"
    end
    frame = bt === nothing ? "" : sexpr_frame(bt)
    return isempty(frame) ? cat : "$cat @ $frame"
end

"Find the first form that fails `f`, for a useful error location."
function locate(forms, f)
    for (i, form) in enumerate(forms)
        try
            f(form)
        catch e
            kind = form isa Expr ? hstr(form.head) : string(typeof(form))
            return "form $i ($kind): $(describe(e))"
        end
    end
    return "not reproducible per form"
end

# ---------------------------------------------------------------------------
# one round trip
# ---------------------------------------------------------------------------

function check_source(src::AbstractString, label::AbstractString, s::Stats)
    failed = false
    compared = false
    fail(cat, detail) = (failed = true; record!(s, cat, label * ": " * detail))
    function finish()
        if failed
            s.files_failed += 1
            compared || (s.aborted += 1)
        end
        return failed
    end

    ex = try
        Meta.parseall(src)
    catch e
        fail("input does not parse", describe(e))
        s.processed += 1
        return finish()
    end
    s.processed += 1

    bad = parse_error_node(ex)
    if bad !== nothing
        fail("input does not parse", describe_parse_error(bad))
        return finish()
    end

    forms = ex isa Expr && ex.head == :toplevel ?
        Any[a for a in ex.args if !(a isa LineNumberNode)] : Any[ex]
    s.forms += length(forms)
    count_lowerings(ex, s)

    clj = try
        detranspile(ex)
    catch e
        fail(error_category("detranspile", e, catch_backtrace()),
             locate(forms, detranspile))
        return finish()
    end

    back = try
        transpile(clj)
    catch e
        fail(error_category("transpile", e, catch_backtrace()),
             locate(forms, form -> transpile(detranspile(form))))
        return finish()
    end

    text = try
        join(map(format, back), "\n\n")
    catch e
        fail(error_category("format", e, catch_backtrace()), locate(back, format))
        return finish()
    end

    s.reparse_checked += 1
    # `Meta.parseall` embeds parse errors as `Expr(:error, ...)` nodes
    # rather than throwing, so inspect the result instead of relying on
    # an exception.
    reparsed_ok = try
        bad = parse_error_node(Meta.parseall(text))
        if bad === nothing
            s.reparse_ok += 1
            true
        else
            fail("generated text does not parse", describe_parse_error(bad))
            false
        end
    catch e
        fail("generated text does not parse", describe(e))
        false
    end

    if reparsed_ok
        s.idem_checked += 1
        idem = try
            detranspile(text)
        catch e
            fail("idempotence error", describe(e))
            nothing
        end
        if idem !== nothing
            if idem == clj
                s.idem_ok += 1
            else
                a = split(clj, '\n')
                b = split(idem, '\n')
                i = findfirst(j -> j > length(a) || j > length(b) || a[j] != b[j],
                              1:max(length(a), length(b)))
                want = i === nothing ? "" :
                       "line $i: expected $(shortstr(a[i])) got $(shortstr(b[i]))"
                fail("not idempotent", want)
            end
        end
    end

    if length(back) != length(forms)
        fail("form count changed", "$(length(forms)) -> $(length(back))")
        return finish()
    end
    for (i, (orig, rt)) in enumerate(zip(forms, back))
        s.ast_checked += 1
        co, cb = canon_ast(orig), canon_ast(rt)
        if isequal(co, cb)
            s.ast_equal += 1
        else
            d = first_diff(co, cb)
            fail("AST: " * d[1], "form $i " * d[2])
        end
    end
    compared = true
    return finish()
end

# ---------------------------------------------------------------------------
# built-in snippets (self check of the harness): the list is in roundtrip.jl
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------

function print_report(s::Stats, root::AbstractString, budget::Float64,
                      elapsed::Float64)
    println()
    println("== Sexpr.jl round-trip corpus ==")
    println("root:     $root")
    println("julia:    $(VERSION)")
    println("time:     $(round(elapsed, digits=1))s (budget ",
            isinf(budget) ? "none" : "$(budget)s", ", ",
            "$(s.skipped) files not reached)")
    println("files:    $(s.processed)/$(s.processed + s.skipped) processed, ",
            "$(s.files_failed) with at least one failure,",
            " $(s.aborted) aborted before comparison")
    println("generated text re-parses: $(s.reparse_ok)/$(s.reparse_checked)")
    println("idempotent s-expressions:  $(s.idem_ok)/$(s.idem_checked)")
    println("forms:    $(s.forms) total, $(s.ast_checked) compared, ",
            "AST-equal $(s.ast_equal) ",
            "($(round(100 * s.ast_equal / max(s.ast_checked, 1), digits=1))% of compared)")

    if !isempty(s.lowerings)
        println()
        println("documented lowerings exercised:")
        for k in sort(collect(keys(s.lowerings)))
            println("  $(rpad(k, 34)) $(s.lowerings[k])")
        end
    end

    println()
    if isempty(s.failures)
        println("no failures")
    else
        println("failures by category:")
        for (cat, n) in sort(collect(s.failures); by = x -> (-x[2], x[1]))
            println("  $(rpad(cat, 38)) $n")
            for ex in s.examples[cat]
                println("      ", replace(ex, "\n" => " | "))
            end
        end
    end
    if s.skipped > 0
        println()
        println("incomplete run: $(s.skipped) files not reached; only a full walk exits 0")
    end
end

"""
    exit_code(s) -> Int

`1` if anything failed, or if the run stopped before every file was compared,
so a green run means the whole tree was walked; `0` otherwise. An aborted file
is always recorded as a failure, so it needs no case of its own.
"""
exit_code(s::Stats) = (!isempty(s.failures) || s.skipped > 0) ? 1 : 0

function parse_options(args)
    opts = Dict{String,Any}("dir" => BASE_DIR, "limit" => typemax(Int),
                            "budget" => 240.0, "self" => false)
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--self"
            opts["self"] = true
        elseif a in ("--dir", "--limit", "--budget")
            i == length(args) && error("$a expects a value")
            v = args[i+1]
            opts[String(a[3:end])] = a == "--dir" ? v :
                a == "--limit" ? parse(Int, v) : parse(Float64, v)
            i += 1
        elseif a in ("-h", "--help")
            println("usage: julia --project=. test/corpus.jl [--self] [--dir DIR] [--limit N] [--budget SECONDS]")
            println("only a run that reaches every file exits 0; --limit and --budget make it incomplete")
            exit(0)
            exit(0)
        else
            error("unknown option $a")
        end
        i += 1
    end
    opts
end

function main(args=ARGS)
    opts = parse_options(args)
    s = Stats()
    t0 = time()

    if opts["self"]
        for (i, src) in enumerate(SNIPPETS)
            # a snippet may use syntax this Julia does not know (`public` before
            # 1.11); only snippets that parse here are round-tripped
            snippet_forms(src) === nothing && continue
            check_source(src, "snippet $i ($(firstline(src)))", s)
        end
        print_report(s, "built-in snippets", Inf, time() - t0)
        return s
    end

    dir = opts["dir"]
    isdir(dir) || error("no such directory: $dir")
    all_files = sort([joinpath(dir, f) for f in readdir(dir) if endswith(f, ".jl")];
                     by = f -> filesize(f))
    # `--limit` reads only a prefix of the tree, so the rest still counts as not
    # reached: a run is green only when it walked every file
    listed = min(length(all_files), opts["limit"])
    files = all_files[1:listed]
    skipped = length(all_files) - listed
    budget = opts["budget"]
    for (i, f) in enumerate(files)
        if time() - t0 > budget
            skipped = length(all_files) - i + 1
            break
        end
        src = try
            read(f, String)
        catch e
            record!(s, "unreadable file", "$(basename(f)): $(describe(e))")
            continue
        end
        check_source(src, basename(f), s)
    end
    s.skipped = skipped
    print_report(s, dir, budget, time() - t0)
    return s
end

if abspath(PROGRAM_FILE) == @__FILE__
    # nonzero on any failure, so CI can gate on the full round trip
    exit(exit_code(main()))
end
