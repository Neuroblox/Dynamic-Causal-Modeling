# apply spectral DCM to LFP data

using LinearAlgebra
using MKL
using FFTW
using ToeplitzMatrices
using MAT
using ExponentialUtilities
using Serialization
using OrderedCollections

function Base.vec(x::T) where (T <: Real)
    return x*ones(1)
end

include("src/hemodynamic_response.jl")     # hemodynamic and BOLD signal model
include("src/VariationalBayes_spm12.jl")      # this can be switched between _spm12 and _AD version. There is also a separate ADVI version in VariationalBayes_ADVI.jl
include("src/mar.jl")                      # multivariate auto-regressive model functions



### get data and compute cross spectral density which is the actual input to the spectral DCM ###
vars = matread("/home/david/Projects/neuroblox/codes/Spectral-DCM/speedandaccuracy/matlab0.01_3regions.mat");
y = vars["data"];
nd = size(y, 2);
dt = vars["dt"];
freqs = vec(vars["Hz"]);
p = 8;                               # order of MAR, it is hard-coded in SPM12 with this value. We will just use the same for now.
mar = mar_ml(y, p);                  # compute MAR from time series y and model order p
y_csd = mar2csd(mar, freqs, dt^-1);  # compute cross spectral densities from MAR parameters at specific frequencies freqs, dt^-1 is sampling rate of data
# y_csd = vars["data_csd"][1]
### Define priors and initial conditions ###
x = vars["x"];                       # initial condition of dynamic variabls
Adj = vars["pE"]["A"];                 # initial values of connectivity matrix
θΣ = vars["pC"];                     # prior covariance of parameter values 
λμ = vec(vars["hE"]);                # prior mean of hyperparameters
Πλ_p = vars["ihC"];                  # prior precision matrix of hyperparameters
if typeof(Πλ_p) <: Number            # typically Πλ_p is a matrix, however, if only one hyperparameter is used it will turn out to be a scalar -> transform that to matrix
    Πλ_p *= ones(1,1)
end

########## assembel the model ##########

regions = []
connex = Num[]
@parameters κ=0.0
for ii = 1:nd
    @named nmm = linearneuralmass()
    @named hemo = hemodynamicsMTK(;κ=κ, τ=0.0)
    eqs = [nmm.x ~ hemo.x]
    region = ODESystem(eqs, systems=[nmm, hemo], name=Symbol("r$ii"))

    push!(connex, region.nmm.x)
    push!(regions, region)
end

@parameters A[1:length(Adj)] = vec(Adj)
@named model = linearconnectionssymbolic(sys=regions, adj_matrix=A, connector=connex)
f = structural_simplify(model)
jac_f = calculate_jacobian(f)
jac_f = substitute(jac_f, Dict([p for p in parameters(f) if occursin("κ", string(p))] .=> κ))

measurements = []
@named bold = boldsignal()
grad_g = calculate_jacobian(bold)[2:3]

# define values of states
all_s = states(f)
sts = Dict{typeof(all_s[1]), eltype(x)}()
for i in 1:nd
    for (j, s) in enumerate(all_s[occursin.("r$i", string.(all_s))])
        sts[s] = x[i, j]
    end
end

bolds = states(bold)
statesubs = merge.([Dict(bolds[2] => s) for s in all_s if occursin(string(bolds[2]), string(s))],
                   [Dict(bolds[3] => s) for s in all_s if occursin(string(bolds[3]), string(s))])

grad_g_full = Num.(zeros(nd, length(all_s)))
for (i, s) in enumerate(all_s)
    dim = parse(Int64, string(s)[2])
    if occursin.(string(bolds[2]), string(s))
        grad_g_full[dim, i] = substitute(grad_g[1], statesubs[dim])
    elseif occursin.(string(bolds[3]), string(s))
        grad_g_full[dim, i] = substitute(grad_g[2], statesubs[dim])
    end
end
derivatives = Dict(:∂f => jac_f, :∂g => grad_g_full)


modelparam = OrderedDict{Any, Any}()
for par in parameters(f)
    while Symbolics.getdefaultval(par) isa Num
        par = Symbolics.getdefaultval(par)
    end
    modelparam[par] = Symbolics.getdefaultval(par)
end
# Noise parameter mean
modelparam[:lnα] = [0.0, 0.0];           # intrinsic fluctuations, ln(α) as in equation 2 of Friston et al. 2014 
modelparam[:lnβ] = [0.0, 0.0];           # global observation noise, ln(β) as above
modelparam[:lnγ] = zeros(Float64, nd);   # region specific observation noise
modelparam[:C] = ones(Float64, nd);     # C as in equation 3. NB: whatever C is defined to be here, it will be replaced in csd_approx. Another strange thing of SPM12...

for par in parameters(bold)
    modelparam[par] = Symbolics.getdefaultval(par)
end

# define prior variances
paramvariance = copy(modelparam)
paramvariance[:C] = zeros(Float64, nd);
paramvariance[:lnγ] = ones(Float64, nd)./64.0;
paramvariance[:lnα] = ones(Float64, length(modelparam[:lnα]))./64.0; 
paramvariance[:lnβ] = ones(Float64, length(modelparam[:lnβ]))./64.0;
for (k, v) in paramvariance
    if occursin("A[", string(k))
        paramvariance[k] = θΣ[1,1]
    elseif occursin("κ", string(k))
        paramvariance[k] = ones(length(v))./256.0;
    elseif occursin("ϵ", string(k))
        paramvariance[k] = 1/256.0;
    elseif occursin("τ", string(k))
        paramvariance[k] = 1/256.0;
    end
end
θΣ = diagm(vecparam(paramvariance))

# depending on the definition of the priors (note that we take it from the SPM12 code), some dimensions are set to 0 and thus are not changed.
# Extract these dimensions and remove them from the remaining computation. I find this a bit odd and further thoughts would be necessary to understand
# to what extend this is a the most reasonable approach. 
idx = findall(x -> x != 0, θΣ);
V = zeros(size(θΣ, 1), length(idx));
order = sortperm(θΣ[idx], rev=true);
idx = idx[order];
for i = 1:length(idx)
    V[idx[i][1], i] = 1.0
end
θΣ = V'*θΣ*V;       # reduce dimension by removing columns and rows that are all 0
Πθ_p = inv(θΣ);

Q = csd_Q(y_csd);                 # compute prior of Q, the precision (of the data) components. See Friston etal. 2007 Appendix A

priors = Dict(:Πθ_pr => Πθ_p, :Πλ_pr => Πλ_p, :μλ_pr => λμ, :Q => Q);
### Compute the DCM ###
@time results = variationalbayes(sts, y_csd, derivatives, freqs, V, p, modelparam, priors, 128)
