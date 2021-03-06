## PARAMETER RANGES


#     Scale = SCALE()

# Object for dispatching on scales and functions when generating
# parameter ranges. We require different behaviour for scales and
# functions:

#      transform(Scale, scale(:log10), 100) = 2
#      inverse_transform(Scale, scale(:log10), 2) = 100

# but
#     transform(Scale, scale(log10), 100) = 100       # identity
#     inverse_transform(Scale, scale(log10), 100) = 2


struct SCALE end
Scale = SCALE()
scale(s::Symbol) = Val(s)
scale(f::Function) = f
MLJ.transform(::SCALE, ::Val{:linear}, x) = x
MLJ.inverse_transform(::SCALE, ::Val{:linear}, x) = x
MLJ.transform(::SCALE, ::Val{:log}, x) = log(x)
MLJ.inverse_transform(::SCALE, ::Val{:log}, x) = exp(x)
MLJ.transform(::SCALE, ::Val{:log10}, x) = log10(x)
MLJ.inverse_transform(::SCALE, ::Val{:log10}, x) = 10^x
MLJ.transform(::SCALE, ::Val{:log2}, x) = log2(x)
MLJ.inverse_transform(::SCALE, ::Val{:log2}, x) = 2^x
MLJ.transform(::SCALE, f::Function, x) = x            # not a typo!
MLJ.inverse_transform(::SCALE, f::Function, x) = f(x) # not a typo!

abstract type ParamRange <: MLJType end

Base.isempty(::ParamRange) = false

struct NominalRange{T} <: ParamRange
    field::Union{Symbol,Expr}
    values::Tuple{Vararg{T}}
end

struct NumericRange{T,D} <: ParamRange
    field::Union{Symbol,Expr}
    lower::T
    upper::T
    scale::D
end

# function Base.show(stream::IO, object::ParamRange)
#     id = objectid(object)
#     T = typeof(object).parameters[1]
#     description = string(typeof(object).name.name, "{$T}")
#     str = "$description @ $(MLJBase.handle(object))"
#     printstyled(IOContext(stream, :color=> MLJBase.SHOW_COLOR),
#                 str, color=:blue)
#     print(stream, " for $(object.field)")


MLJBase.show_as_constructed(::Type{<:ParamRange}) = true

"""
    r = range(model, :hyper; values=nothing)

Defines a `NominalRange` object for a field `hyper` of `model`,
assuming the field is a not a subtype of `Real`. Note that `r` is not
directly iterable but `iterator(r)` iterates over `values`.

A nested hyperparameter is specified using dot notation. For example,
`:(atom.max_depth)` specifies the `:max_depth` hyperparameter of the hyperparameter `:atom` of `model`.

    r = range(model, :hyper; upper=nothing, lower=nothing, scale=:linear)

Defines a `NumericRange` object for a `Real` field `hyper` of `model`.
Note that `r` is not directly iteratable but `iterator(r, n)` iterates
over `n` values between `lower` and `upper` values, according to the
specified `scale`. The supported scales are `:linear, :log, :log10,
:log2`. Values for `Integer` types are rounded (with duplicate values
removed, resulting in possibly less than `n` values).

Alternatively, if a function `f` is provided as `scale`, then
`iterator(r, n)` iterates over the values `[f(x1), f(x2), ... ,
f(xn)]`, where `x1, x2, ..., xn` are linearly spaced between `lower`
and `upper`.


"""
function Base.range(model, field::Union{Symbol,Expr}; values=nothing,
                    lower=nothing, upper=nothing, scale::D=:linear) where D
    value = recursive_getproperty(model, field)
    T = typeof(value)
    if T <: Real
        (lower === nothing || upper === nothing) &&
            error("You must specify lower=... and upper=... .")
        return NumericRange{T,D}(field, lower, upper, scale)
    else
        values === nothing && error("You must specify values=... .")
        return NominalRange{T}(field, Tuple(values))
    end
end

"""
    MLJ.scale(r::ParamRange)

Return the scale associated with the `ParamRange` object `r`. The
possible return values are: `:none` (for a `NominalRange`), `:linear`,
`:log`, `:log10`, `:log2`, or `:custom` (if `r.scale` is function).

"""
scale(r::NominalRange) = :none
scale(r::NumericRange) = :custom
scale(r::NumericRange{T,Symbol}) where T =
    r.scale


## ITERATORS FROM A PARAMETER RANGE

iterator(param_range::NominalRange) = collect(param_range.values)

function iterator(param_range::NumericRange{T}, n::Int) where {T<:Real}
    s = scale(param_range.scale)
    transformed = range(transform(Scale, s, param_range.lower),
                stop=transform(Scale, s, param_range.upper),
                length=n)
    inverse_transformed = map(transformed) do value
        inverse_transform(Scale, s, value)
    end
    return unique(inverse_transformed)
end

# in special case of integers, round to nearest integer:
function iterator(param_range::NumericRange{I}, n::Int) where {I<:Integer}
    s = scale(param_range.scale)
    transformed = range(transform(Scale, s, param_range.lower),
                stop=transform(Scale, s, param_range.upper),
                length=n)
    inverse_transformed =  map(transformed) do value
        round(I, inverse_transform(Scale, s, value))
    end
    return unique(inverse_transformed)
end


## GRID GENERATION

"""
    unwind(iterators...)

Represent all possible combinations of values generated by `iterators`
as rows of a matrix `A`. In more detail, `A` has one column for each
iterator in `iterators` and one row for each distinct possible
combination of values taken on by the iterators. Elements in the first
column cycle fastest, those in the last clolumn slowest.

### Example

````julia
julia> iterators = ([1, 2], ["a","b"], ["x", "y", "z"]);
julia> MLJ.unwind(iterators...)
12×3 Array{Any,2}:
 1  "a"  "x"
 2  "a"  "x"
 1  "b"  "x"
 2  "b"  "x"
 1  "a"  "y"
 2  "a"  "y"
 1  "b"  "y"
 2  "b"  "y"
 1  "a"  "z"
 2  "a"  "z"
 1  "b"  "z"
 2  "b"  "z"
````

"""
function unwind(iterators...)
    n_iterators = length(iterators)
    iterator_lengths = map(length, iterators)

    # product of iterator lengths:
    L = reduce(*, iterator_lengths)
    L != 0 || error("Parameter iterator of length zero encountered.")

    A = Array{Any}(undef, L, n_iterators)
    n_iterators != 0 || return A

    inner = 1
    outer = L
    for j in 1:n_iterators
        outer = outer ÷ iterator_lengths[j]
        A[:,j] = repeat(iterators[j], inner=inner, outer=outer)
        inner *= iterator_lengths[j]
    end
    return A
end
