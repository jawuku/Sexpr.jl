# Julia and Sexpr.jl syntax side by side

A quick reference for the s-expression surface syntax and the Julia it
produces. See the [README](../README.md) for the full description.

## Atoms

```clojure
nil                          ; nothing
true false                   ; booleans
42  -7                       ; integers
0xff  0b1010  16r1ef         ; hex, binary, radix
1.5  1e3                     ; floats
3/5                          ; 3//5
"text\n"                     ; string with escapes
\a  \newline  \u03bb         ; characters
:foo                         ; keyword
foo/bar                      ; foo.bar
x::Int                       ; x::Int
xs...                        ; splat
```

```julia
nothing
true, false
42, -7
0xff, 0b1010, 0x1ef
1.5, 1000.0
3//5
"text\n"
'a', '\n', 'λ'
:foo
foo.bar
x::Int
xs...
```

## Collections and calls

```clojure
(+ 1 2)                      ; 1 + 2
[1 2 3]                      ; [1, 2, 3]
{:a 1 :b 2}                  ; Dict(:a => 1, :b => 2)
#{1 2 3}                     ; Set([1, 2, 3])
(aget a 1)                   ; a[1]
'(a b)                       ; :(a(b))   (quoted call data)
```

## Definitions

```clojure
(def x 1)
(const y 2)
(defn add [a b] (+ a b))
(defn greet [(name "world")] (str "hello " name))
(defn total [& xs] (+ xs...))
(defn fst [[a b]] a)
(deftype Point [x::Float64 y::Float64])
(defmutable Counter [n])
```

```julia
x = 1
const y = 2
function add(a, b)
    a + b
end
greet(name = "world") = string("hello ", name)
total(xs...) = +(xs...)
fst((a, b)) = a
struct Point
    x::Float64
    y::Float64
end
mutable struct Counter
    n
end
```

## Control flow

```clojure
(if (> x 0) x (- x))
(when ready? (run))
(cond (< n 0) :negative
      (= n 0) :zero
      :else  :positive)
(let [a 1 b 2] (+ a b))
(for [x xs] (println x))
(while (> x 0) (def x (- x 1)))
(try (f) (catch e (g e)) (finally (h)))
(-> x (f 1) g)
(->> x (f 1) g)
```

```julia
if x > 0
    x
else
    -x
end
if ready?
    run()
end
if n < 0
    :negative
elseif n == 0
    :zero
else
    :positive
end
let a = 1, b = 2
    a + b
end
for x in xs
    println(x)
end
while x > 0
    x = x - 1
end
try
    f()
catch e
    g(e)
finally
    h()
end
g(f(x, 1))
g(f(1, x))
```

`(toplevel …)`, `(macrocall …)`, `(catch false …)` and the `(call (where …))`
and `(fn (where [params] T) …)` header forms are described in the README
section *Low-level and round-trip forms*.

## Macros

```clojure
(defmacro twice [x] `(+ ~x ~x))
(defn quad [a] (@twice (@twice a)))
```

```julia
macro twice(x)
    :(+($(esc(x)), $(esc(x))))
end
quad(a) = @twice(@twice(a))
```
