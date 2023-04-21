module Dimred

using Distributions: cdf, Beta

import StatsAPI: fit, fit!, coef, response, RegressionModel, modelmatrix, nobs, HypothesisTest, pvalue, dof

import Statistics, Random

export SlicedInverseRegression,
    PrincipalHessianDirections,
    SlicedAverageVarianceEstimation,
    MPSIR,
    CORE,
    core,
    dimension_test,
    coordinate_test,
    slicer,
    eig,
    mpsir,
    teststat,

    # Add methods to StatsAPI
    coef,
    nvar,
    fit,
    fit!,
    coef,
    response,
    modelmatrix,
    pvalue,
    dof

include("sir.jl")
include("phd.jl")
include("save.jl")
include("core.jl")
include("mpsir.jl")
include("diva.jl")

end
