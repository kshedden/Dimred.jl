using StatsBase
using LinearAlgebra
using Printf
using Distributions

"""
    SlicedInverseRegression

A multi-index regression model fit using sliced inverse
regression (SIR).
"""
mutable struct SlicedInverseRegression <: DimensionReductionModel

    "`y`: the response variable, sorted"
    y::AbstractVector

    "`X`: the centered explanatory variables, sorted to align with `y`.  The observations (variables) are in rows (columns) of `X`."
    X::AbstractMatrix

    "`Z`: the whitened explanatory variables, same shape as `X`"
    Z::AbstractMatrix

    "`Xmean`: the means of the columns of `X`"
    Xmean::AbstractVector

    "`sm`: the slice means of whitened data `Z` (each column contains one slice mean)"
    sm::AbstractMatrix

    "`M`: the covariance of the decorrelated slice means"
    M::AbstractMatrix

    "`fw`: the proportion of the observations in each slice"
    fw::AbstractVector

    "`dirs`: the columns are a basis for the estimated effective dimension reduction (EDR) space"
    dirs::AbstractMatrix

    "`eigs`: the eigenvalues of `M`, sorted by decreasing eigenvalue"
    eigs::AbstractVector

    "`eigv`: the eigenvectors of `M`, sorted by decreasing eigenvalue"
    eigv::AbstractMatrix

    "`trans`: map data coordinates to orthogonalized coordinates"
    trans::AbstractMatrix

    "`bd`: slice bounds"
    bd::AbstractVector

    "`slice_assignments`: the slice indicator for each observation, aligns with data supplied by user"
    slice_assignments::AbstractVector

    "`nslice`: the number of slices"
    nslice::Int
end

function SlicedInverseRegression(
    y::AbstractVector,
    X::AbstractMatrix,
    nslice::Int;
    slicer = slicer,
)
    @assert issorted(y)
    @assert length(y) == size(X, 1)
    n, p = size(X)

    # Transform to orthogonal coordinates
    y = copy(y)
    X, mn = center(X)
    Z, trans = whiten(X)

    # Storage for values to be set during fit.
    sm = zeros(0, 0)
    fw = zeros(0)
    dirs = zeros(0, 0)
    eigs = zeros(0)
    eigv = zeros(0, 0)

    # Set up the slices
    bd = slicer(y, nslice)
    sa = expand_slice_bounds(bd, length(y))

    # Actual number of slices, may differ from nslice
    h = length(bd) - 1

    # Estimate E[X | Y]
    sm = slice_means(Z, bd)

    # Slice frequencies
    ns = diff(bd)
    fw = Float64.(ns)
    fw ./= sum(fw)

    return SlicedInverseRegression(
        y,
        X,
        Z,
        mn,
        sm,
        zeros(0, 0),
        fw,
        dirs,
        eigs,
        eigv,
        trans,
        bd,
        sa,
        h
    )
end

function coef(r::SlicedInverseRegression)
    return r.dirs
end

# Find slice bounds, placing each distinct value of y into its own slice.
# This function assumes that y is sorted.  This matches the slice1 function
# in the R dr package.
function slice1(y, u)
    bds = Int[]
    for j in eachindex(u)
        ii = searchsortedfirst(y, u[j])
        push!(bds, ii)
    end
    push!(bds, length(y) + 1)
    return bds
end

# The main slicing function, matches slice2 in the R dr package.
function slice2(y, u, nslice)

    myfind = function (x, v)
        ii = findfirst(x .<= v)
        return ifelse(isnothing(ii), length(v), ii)
    end

    # Cumulative counts of distinct values
    bds = slice1(y, u)
    cty = cumsum(diff(bds))

    n = length(y)
    m = floor(n / nslice) # nominal number of obs per slice
    bds = Int[]
    jj, j = 0, 0
    while jj < n - 2
        jj += m
        j += 1
        s = myfind(jj, cty)
        jj = cty[s]
        push!(bds, s)
    end
    return vcat(1, 1 .+ cty[bds])
end

# Return the slice boundaries for approximately 'nslice' slices.
function slicer(y::AbstractVector, nslice::Integer)
    u = sort(unique(y))
    if length(u) > nslice
        return slice2(y, u, nslice)
    else
        return slice1(y, u)
    end
end

# Calculate means of blocks of consecutive rows of x.  bd contains
# the slice boundaries.  The slice means are in the columns of
# the returned matrix.
function slice_means(X::AbstractMatrix, bd::AbstractVector)

    n, p = size(X)
    h = length(bd) - 1 # number of slices

    # Slice means and sample sizes
    sm = zeros(Float64, p, h)

    for i = 1:h
        sm[:, i] = mean(X[bd[i]:bd[i+1]-1, :], dims = 1)
    end

    return sm
end

# Center the columns of the matrix X.
function center(X)
    X = copy(X)
    mn = mean(X, dims=1)[:]
    for j = 1:size(X, 2)
        X[:, j] .-= mn[j]
    end
    return X, mn
end

# Whiten the array X, which has already been centered.
# When sym=true, the data are whitened using a symmetric
# square root.  sym should always be set to true when
# using coordinate tests.
function whiten(X; sym = true)
    n = size(X, 1)
    qrx = qr(X)
    if sym
        R = Matrix(qrx.R)
        S = R' * R / n
        T = ssqrti(Symmetric(S))
        W = X * T
        return W, inv(T)
    else
        # This is what the R dr package uses.
        W, T = Matrix(qrx.Q), Matrix(qrx.R)
        k = sqrt(n)
        W *= k
        T /= k
        return W, T
    end
end

function dof(dt::DimensionTest)
    return dt.dof
end

"""
    dimension_test(sir)

Test the null hypotheses that only the largest k eigenvalues are non-null.

If method is ':chisq' use the chi-square test of Li (1991).  If method
is ':diva' use the DIVA approach:

"Inference for the dimension of a regression relationship using pseudo‐covariates"
SH Huang, K Shedden, H Chang - Biometrics, 2022.
"""
function dimension_test(sir::SlicedInverseRegression; maxdim::Int=nvar(sir), method=:chisq, args...)

    if !(method in [:chisq, :diva])
        @error("Unknown dimension test method '$(method)'")
    end

    if method == :diva
        return _dimension_test_diva(sir; maxdim=maxdim, args...)
    end

    # Only test when there are positive degrees of freedom
    p = length(sir.eigs)
    maxdim = maxdim < 0 ? min(p - 1, sir.nslice - 2) : maxdim
    maxdim = min(maxdim, min(p - 1, sir.nslice - 2))

    stat = nobs(sir) * cumsum(reverse(sir.eigs)) |> reverse
    k = 0:maxdim
    dof = (p .- k) .* (sir.nslice .- k .- 1)

    return DimensionTest(stat, dof)
end

function getC1(c)
    p = length(c)
    C1 = zeros(p, p)
    for i = 1:p
        for j = 1:p
            if i == j
                C1[i, j] = -0.5 * c[i]^-1.5
            else
                C1[i, j] = (c[i]^-0.5 - c[j]^-0.5) / (c[i] - c[j])
            end
        end
    end
    return C1
end

function _coord_test(sir::SlicedInverseRegression, H0::AbstractMatrix; pmethod::Symbol=:bx,
                     method::Symbol=:chisq)

    if method == :chisq
        return _coord_test_chisq(sir, H0; pmethod=pmethod)
    elseif method == :diva
        return _coord_test_diva(sir, H0; kwargs...)
    else
        error("Unknown coordinate test method='$(method)'")
    end
end

# SIR-specific coordinate testing.
function _coord_test_chisq(sir::SlicedInverseRegression, Hyp::AbstractMatrix; pmethod=:bx)

    (; y, X, Z, M, eigs, eigv, trans, fw, bd, slice_assignments, nslice) = sir

    r = size(Hyp, 2)
    n, p = size(X)
    h = length(bd) - 1

    # Slice frequencies
    ns = diff(bd)
    fw = Float64.(ns)
    fw ./= sum(fw)

    # cov(X) and its inverted symmetric square root
    Sigma = Symmetric(cov(X))
    Sri = ssqrti(Sigma)

    # An orthogonal basis for the null hypothesis in the whitened coordinates
    A = Sri * Hyp
    alpha = A * ssqrti(Symmetric(A' * A))

    # The test statistic
    u = alpha' * sir.sm * Diagonal(sqrt.(sir.fw))
    tstat = n * sum(abs2, u)

    # OLS residuals of the slice indicators.
    J = zeros(n)
    Q = Matrix(qr(X).Q)
    eps = zeros(n, h)
    for i in 1:h
        J .= 0
        J[bd[i]:bd[i+1]-1] .= 1
        eps[:, i] .= J .- fw[i] - Q * (Q' * J)
    end

    # The null distribution of the test statistic is a weighted
    # sum of chisquare(1) distributions with weights equal to
    # the eigenvalues of Omega, constructed below.
    Omega = zeros(h*r, h*r)
    for i in 1:n
        u = alpha' * Z[i, :]
        c = u * u'
        b = eps[i, :] ./ sqrt.(fw)
        b = b * b'
        Omega .+= kron(b, c)
    end
    Omega ./= n
    T, degf, pval = ct_pvalues(Omega, tstat, 1, pmethod)

    return CoordinateTest(T, degf, tstat, pval)
end

# Convert the array of slice boundaries to an array of slice indicators.
function expand_slice_bounds(bd, n)
    z = zeros(Int, n)
    for i = 1:length(bd)-1
        z[bd[i]:bd[i+1]-1] .= i
    end
    return z
end

function fit!(sir::SlicedInverseRegression; ndir::Integer = 2)

    # Get the SIR directions
    sir.M = StatsBase.cov(copy(sir.sm'), fweights(sir.fw); corrected = false)
    eg = eigen(sir.M)

    # Raw eigenvalues and eigenvectors, sorted by decreasing eigenvalue
    sir.eigs = eg.values[end:-1:1]
    sir.eigv = eg.vectors[:, end:-1:1]

    if ndir > length(sir.eigs)
        @warn(@sprintf("Can only estimate %d factors", length(sir.eigs)))
        ndir = length(sir.eigs)
    end

    # Map back to the original coordinates
    dirs = eg.vectors[:, end:-1:1]
    sir.dirs = dirs[:, 1:ndir]
    sir.dirs = sir.trans \ sir.dirs

    # Scale to unit length
    for j = 1:size(sir.dirs, 2)
        sir.dirs[:, j] ./= norm(sir.dirs[:, j])
    end
end

"""
    sir(y, x; nslice, ndir)

Use Sliced Inverse Regression (SIR) to estimate the effective dimension reduction (EDR) space.

'y' must be sorted before calling 'fit'.
"""
function fit(
    ::Type{SlicedInverseRegression},
    X::AbstractMatrix,
    y::AbstractVector;
    nslice = max(8, size(X, 2) + 3),
    ndir = min(5, size(X, 2))
)
    if !issorted(y)
        error("y must be sorted")
    end
    sm = SlicedInverseRegression(y, X, nslice)
    fit!(sm; ndir = ndir)
    return sm
end
