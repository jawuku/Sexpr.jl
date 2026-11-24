"""
Command-line interface: `sjulia [options] [files...]`.
"""

const HELP_TEXT = """
usage: sjulia [-i] [-c] [-l LINES] [-o OUTPUT] [-e EXTENSION] [-h] [files...]

A program to port Clojure-like s-expression syntax to and from Julia.
By default it reads s-expressions and writes Julia; use -i to flip direction.

positional arguments:
  files                 If given one file and no output directory, the result
                        is written to stdout. If given a directory or multiple
                        files, an output directory must be specified with
                        -o/--output.

optional arguments:
  -i, --invert          take Julia code and print out s-expression code instead
  -c, --cat             read from STDIN rather than from files
  -l, --lines LINES     blank lines between top-level forms (default: 1)
  -o, --output OUTPUT   directory for the generated files
  -e, --extension EXT   extra file extension to treat as lisp source
                        (may be given more than once); default: clj cljs cl
                        lisp wisp hy
  -h, --help            show this help message and exit
"""

const DEFAULT_EXTENSIONS = ["clj", "cljs", "cl", "lisp", "wisp", "hy"]

mutable struct Options
    invert::Bool
    cat::Bool
    lines::Int
    output::Union{Nothing,String}
    extensions::Vector{String}
    files::Vector{String}
    help::Bool
end

Options() = Options(false, false, 1, nothing, String[], String[], false)

function parse_args(args)
    o = Options()
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("-h", "--help")
            o.help = true
        elseif a in ("-i", "--invert")
            o.invert = true
        elseif a in ("-c", "--cat")
            o.cat = true
        elseif a in ("-l", "--lines", "-o", "--output", "-e", "--extension")
            i == length(args) && throw(ArgumentError("$a expects a value"))
            val = args[i+1]
            if a in ("-l", "--lines")
                o.lines = parse(Int, val)
            elseif a in ("-o", "--output")
                o.output = val
            else
                push!(o.extensions, val)
            end
            i += 1
        elseif startswith(a, "-") && a != "-"
            throw(ArgumentError("unknown option $a"))
        else
            push!(o.files, a)
        end
        i += 1
    end
    o
end

"Translate one chunk of source text."
function translate(source::AbstractString, invert::Bool)
    src = String(source)
    invert && return detranspile(src)
    return join(map(format, transpile(src)), "\n\n")
end

function write_result(io::IO, source::AbstractString, invert::Bool, lines::Int)
    out = translate(source, invert)
    println(io, out)
    print(io, repeat("\n", max(lines, 0)))
end

function source_files(dir::AbstractString, extensions::Vector{String})
    files = String[]
    for (root, _, names) in walkdir(dir)
        for n in names
            ext = lowercase(splitext(n)[2])
            if isempty(ext) || ext[2:end] in extensions
                push!(files, joinpath(root, n))
            end
        end
    end
    sort!(files)
    files
end

"""
    main(args=ARGS) -> Int

Run the command-line tool. Returns a process exit code instead of exiting so
that it can be called from tests.
"""
function main(args=ARGS)
    o = try
        parse_args(args)
    catch e
        println(stderr, "error: ", sprint(showerror, e))
        print(stderr, HELP_TEXT)
        return 1
    end
    if o.help
        print(HELP_TEXT)
        return 0
    end

    # when inverting, a directory of Julia files is the natural input
    default_exts = o.invert ? ["jl"] : DEFAULT_EXTENSIONS
    extensions = isempty(o.extensions) ? default_exts : o.extensions
    outext = o.invert ? ".clj" : ".jl"
    status = 0

    try
        if o.cat || isempty(o.files)
            write_result(stdout, read(stdin, String), o.invert, o.lines)
            return 0
        end

        if length(o.files) == 1 && isfile(o.files[1]) && o.output === nothing
            write_result(stdout, read(o.files[1], String), o.invert, o.lines)
            return 0
        end

        if o.output === nothing
            println(stderr, "error: an output directory is required for multiple files")
            return 1
        end

        inputs = String[]
        for f in o.files
            if isfile(f)
                push!(inputs, f)
            elseif isdir(f)
                append!(inputs, source_files(f, extensions))
            else
                println(stderr, "error: no such file or directory: $f")
                status = 1
            end
        end

        mkpath(o.output)
        for f in inputs
            base = splitext(basename(f))[1]
            outpath = joinpath(o.output, string(base, outext))
            open(outpath, "w") do io
                write_result(io, read(f, String), o.invert, o.lines)
            end
            println(stderr, "wrote $outpath")
        end
        return status
    catch e
        if e isa SexprError
            println(stderr, "error: ", sprint(showerror, e))
            return 1
        end
        rethrow(e)
    end
end
