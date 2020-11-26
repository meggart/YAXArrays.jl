module DAT
export mapCube
import ..Cubes
using ..YAXTools
using Distributed: RemoteChannel, nworkers,pmap,
  @everywhere, workers, remotecall_fetch,
  remote_do, myid, nprocs, RemoteException, remotecall
import ..Cubes: cubechunks, iscompressed, chunkoffset,
  CubeAxis, YAXArray,
  caxes, YAXSlice
import ..Cubes.Axes: AxisDescriptor, axname, ByInference, axsym,
  getOutAxis, getAxis, findAxis
import ..Datasets: Dataset, createdataset
import ...YAXArrays
import ...YAXArrays.workdir
import ProgressMeter: Progress, next!, progress_pmap
using YAXArrayBase
using Dates
global const debugDAT=[false]
#TODO use a logging package
macro debug_print(e)
  debugDAT[1] && return(:(println($e)))
  :()
end

include("registration.jl")

"""
Internal representation of an input cube for DAT operations
"""
mutable struct InputCube{N}
  cube::Any   #The input data cube
  desc::InDims               #The input description given by the user/registration
  axesSmall::Vector{CubeAxis} #List of axes that were actually selected through the desciption
  icolon::Vector{Int}
  colonperm::Union{Vector{Int},Nothing}
  loopinds::Vector{Int}        #Indices of loop axes that this cube does not contain, i.e. broadcasts
  cachesize::Vector{Int}     #Number of elements to keep in cache along each axis
end

function InputCube(c, desc::InDims)
  iaxessmall = findAxis.(desc.axisdesc,Ref(c))
  axlist = caxes(c)
  axesSmall = map(i->axlist[i], iaxessmall)
  colonperm = issorted(iaxessmall) ? nothing : collect(Base.invperm(sortperm(collect(iaxessmall))))
  iaxessmall = collect(iaxessmall)
  any(isequal(nothing),axesSmall) && error("One of the input axes not found in input cubes")
  InputCube{ndims(c)}(c,desc,collect(CubeAxis,axesSmall),iaxessmall,colonperm,Int[],Int[])
end
geticolon(ic::InputCube) = ic.icolon
createworkarrays(T,s,ntr)=[Array{T}(undef,s...) for i=1:ntr]




"""
Internal representation of an output cube for DAT operations
"""
mutable struct OutputCube
  cube::Any #The actual outcube cube, once it is generated
  desc::OutDims                 #The description of the output axes as given by users or registration
  axesSmall::Array{CubeAxis}       #The list of output axes determined through the description
  allAxes::Vector{CubeAxis}        #List of all the axes of the cube
  loopinds::Vector{Int}              #Index of the loop axes that are broadcasted for this output cube
  innerchunks
  outtype
end

const InOutCube = Union{InputCube,OutputCube}

getsmallax(c::InOutCube)=c.axesSmall
geticolon(c::OutputCube)=1:length(c.axesSmall)
getAxis(desc,c::InOutCube) = getAxis(desc,c.cube)

function getworkarray(c::InOutCube,ntr)
  wa = createworkarrays(eltype(c.cube),length.(c.axesSmall),ntr)
  map(wa) do w
    wrapWorkArray(c.desc.artype,w,c.axesSmall)
  end
end

function interpretoutchunksizes(desc,axesSmall,incubes)
  if desc.chunksize == :max
    map(ax->axname(ax)=>length(ax),axesSmall)
  elseif desc.chunksize == :input
    map(axesSmall) do ax
      for cc in incubes
        i = findAxis(axname(ax),cc)
        if i !== nothing
          return axname(ax)=>min(length(ax),cubechunks(cc)[i])
        end
      end
      return axname(ax)=>length(ax)
    end
  else
    desc.chunksize
  end
end

getOutAxis(desc::Tuple,inAxes,incubes,pargs,f)=map(i->getOutAxis(i,inAxes,incubes,pargs,f),desc)
function OutputCube(desc::OutDims,inAxes::Vector{CubeAxis},incubes,pargs,f)
  axesSmall     = getOutAxis(desc.axisdesc,inAxes,incubes,pargs,f)
  outtype       = getOuttype(desc.outtype,incubes)
  innerchunks   = interpretoutchunksizes(desc,axesSmall,incubes)
  OutputCube(nothing,desc,collect(CubeAxis,axesSmall),CubeAxis[],Int[],innerchunks,outtype)
end

"""
Configuration object of a DAT process. This holds all necessary information to perform the calculations.
It contains the following fields:

- `incubes::NTuple{NIN,InputCube}` The input data cubes
- `outcube::NTuple{NOUT,OutputCube}` The output data cubes
allInAxes     :: Vector
LoopAxes      :: Vector
ispar         :: Bool
loopcachesize :: Vector{Int}
max_cache
fu
inplace      :: Bool
include_loopvars:: Bool
ntr
addargs
kwargs
"""
mutable struct DATConfig{NIN,NOUT}
  "The input data cubes"
  incubes       :: NTuple{NIN,InputCube}

  outcubes      :: NTuple{NOUT,OutputCube}
  allInAxes     :: Vector
  LoopAxes      :: Vector
  ispar         :: Bool
  loopcachesize :: Vector{Int}
  max_cache
  fu
  inplace      :: Bool
  include_loopvars:: Bool
  ntr
  addargs
  kwargs
end
function DATConfig(cdata,indims,outdims,inplace,max_cache,fu,ispar,include_loopvars,nthreads,addargs,kwargs)

  isa(indims,InDims) && (indims=(indims,))
  isa(outdims,OutDims) && (outdims=(outdims,))
  length(cdata)==length(indims) || error("Number of input cubes ($(length(cdata))) differs from registration ($(length(indims)))")
  incubes  = ([InputCube(o[1],o[2]) for o in zip(cdata,indims)]...,)
  allInAxes = vcat([ic.axesSmall for ic in incubes]...)
  outcubes = ((map(1:length(outdims),outdims) do i,desc
     OutputCube(desc,allInAxes,cdata,addargs,fu)
  end)...,)

  DATConfig(
    incubes,
    outcubes,
    allInAxes,
    CubeAxis[],                                 # LoopAxes
    ispar,
    Int[],
    max_cache,                                  # max_cache
    fu,                                         # fu                                      # loopcachesize
    inplace,                                    # inplace
    include_loopvars,
    nthreads,
    addargs,                                    # addargs
    kwargs
  )
end


getOuttype(outtype::Int,cdata)=eltype(cdata[outtype])
function getOuttype(outtype::DataType,cdata)
  outtype
end

mapCube(fu::Function,cdata,addargs...;kwargs...)=mapCube(fu,(cdata,),addargs...;kwargs...)

function mapCube(f, in_ds::Dataset, addargs...; indims=InDims(), outdims=OutDims(), inplace=true, kwargs...)
    allars = values(in_ds.cubes)
    allaxes = collect(values(in_ds.axes))
    arnames = keys(in_ds.cubes)
    sarnames = (arnames...,)
    any(ad->findAxis(ad,allaxes)===nothing,indims.axisdesc) && error("One of the Dimensions does not exist in Dataset")

    idar = collect(indims.axisdesc)
    allindims = map(allars) do c
        idshort = filter(idar) do ad
            findAxis(ad,c)!==nothing
        end
        InDims((idshort...,), indims.artype, indims.procfilter)
    end
    isa(outdims, OutDims) || error("Only one output cube currently supported for datasets")
    isempty(addargs) || error("Additional arguments currently not supported for datasets, use kwargs instead")
    if inplace
        fnew = let arnames=collect(arnames), f=f
            function dsfun(xout,xin...; kwargs...)
                incubes = NamedTuple{sarnames, typeof(xin)}(xin)
                f(xout,incubes; kwargs...)
            end
        end
    else
        fnew = let arnames=collect(arnames), f=f
            function dsfun(xin...; kwargs...)
                incubes = NamedTuple{sarnames, typeof(xin)}(xin)
                f(incubes; kwargs...)
            end
        end
    end
    allcubes = collect(values(in_ds.cubes))
    mapCube(fnew,(allcubes...,);indims=allindims,outdims=outdims, inplace=inplace, kwargs...)
end

import Base.mapslices
function mapslices(f,d::Union{YAXArray, Dataset},addargs...;dims,kwargs...)
    isa(dims,String) && (dims=(dims,))
    mapCube(f,d,addargs...;indims = InDims(dims...),outdims = OutDims(ByInference()),inplace=false,kwargs...)
end



"""
    mapCube(fun, cube, addargs...;kwargs)

Map a given function `fun` over slices of the data cube `cube`.

### Keyword arguments

* `max_cache=1e7` maximum size of blocks that are read into memory, defaults to approx 10Mb
* `indims::InDims` List of input cube descriptors of type [`InDims`](@ref) for each input data cube
* `outdims::OutDims` List of output cube descriptors of type [`OutDims`](@ref) for each output cube
* `inplace` does the function write to an output array inplace or return a single value> defaults to `true`
* `ispar` boolean to determine if parallelisation should be applied, defaults to `true` if workers are available.
* `showprog` boolean indicating if a ProgressMeter shall be shown
* `include_loopvars` boolean to indicate if the varoables looped over should be added as function arguments
* `loopchunksize` determines the chunk sizes of variables which are looped over, a dict
* `kwargs` additional keyword arguments passed to the inner function

The first argument is always the function to be applied, the second is the input cube or
a tuple input cubes if needed.
"""
function mapCube(fu::Function,
    cdata::Tuple,addargs...;
    max_cache=YAXArrays.YAXDefaults.max_cache[],
    indims=InDims(),
    outdims=OutDims(),
    inplace=true,
    ispar=nprocs()>1,
    debug=false,
    include_loopvars=false,
    showprog=true,
    nthreads=ispar ? Dict(i=>remotecall_fetch(Threads.nthreads,i) for i in workers()) : [Threads.nthreads()] ,
    loopchunksize = Dict(),
    kwargs...)

  #Translate slices
  if any(i->isa(i,YAXSlice),cdata)
    inew = map(cdata) do d
      isa(d,YAXSlice) ? InDims(axname.(d.sliceaxes[2])...) : InDims()
    end
    cnew = map(i->isa(i,YAXSlice) ? i.c : i, cdata)
    return mapCube(fu, cnew, addargs...;
      indims=inew, outdims=outdims, inplace=inplace, ispar=ispar,
      debug=debug, include_loopvars=include_loopvars, showprog=showprog,
      nthreads=nthreads, kwargs...)
  end
  @debug_print "Generating DATConfig"
  dc=DATConfig(cdata,indims,outdims,inplace,
    max_cache,fu,ispar,include_loopvars,nthreads,addargs,kwargs)
  @debug_print "Analysing Axes"
  analyzeAxes(dc)
  @debug_print "Calculating Cache Sizes"
  getCacheSizes(dc,loopchunksize)
  @debug_print "Generating Output Cube"
  generateOutCubes(dc)
  @debug_print "Running main Loop"
  debug && return(dc)
  runLoop(dc,showprog)
  @debug_print "Finalizing Output Cube"

  if length(dc.outcubes)==1
    return dc.outcubes[1].cube
  else
    return (map(i->i.cube,dc.outcubes)...,)
  end

end

function makeinplace(f)
  (args...;kwargs...)->begin
    first(args).=f(Base.tail(args)...;kwargs...)
    nothing
  end
end


function getchunkoffsets(dc::DATConfig)
  co = zeros(Int,length(dc.LoopAxes))
  lc = dc.loopcachesize
  for ic in dc.incubes
    for (ax,cocur,cs) in zip(caxes(ic.cube),chunkoffset(ic.cube),cubechunks(ic.cube))
      ii = findAxis(ax,dc.LoopAxes)
      if !isa(ii,Nothing) && iszero(co[ii]) && cocur>0 && mod(lc[ii],cs)==0
        co[ii]=cocur
      end
    end
  end
  (co...,)
end

updatears(clist,r,f,caches) = foreach(clist, caches) do ic, ca
  updatear(f,r, ic.cube,geticolon(ic),ic.loopinds, ca )
end
getindsall(indscol, loopinds, rfunc, colfunc = _->Colon()) = getindsall((),1,(sort(indscol)...,),(loopinds...,),rfunc,colfunc)
function getindsall(indsall,inow,indscol,loopinds,rfunc,colfunc)
  if !isempty(indscol) && first(indscol) == inow
    getindsall((indsall..., colfunc(inow)),inow+1,Base.tail(indscol),loopinds,rfunc,colfunc)
  else
    getindsall((indsall..., rfunc(first(loopinds))),inow+1,indscol,Base.tail(loopinds),rfunc,colfunc)
  end
end
getindsall(indsall,inow,::Tuple{},::Tuple{},r,c) = indsall


function updatear(f,r,cube,indscol,loopinds,cache)
  indsall = getindsall(indscol,loopinds,i->r[i])
  l2 = map((i,s)->isa(i,Colon) ? s : length(i),indsall,size(cache))
  if size(cache) != l2
    hinds = map((i,s)->isa(i,Colon) ? (1:s) : 1:length(i),indsall,size(cache))
    if f == :read
      cache[hinds...] = getdata(cube)[indsall...]
    else
      getdata(cube)[indsall...] = cache[hinds...]
    end
  else
    if f == :read
      d = getdata(cube)[indsall...]
      cache[:] = d
    else
      getdata(cube)[indsall...] = cache
    end
  end
end
updateinars(dc,r,incaches)=updatears(dc.incubes,r,:read,incaches)
writeoutars(dc,r, outcaches)=updatears(dc.outcubes,r,:write,outcaches)

function loopworker(dcchan::RemoteChannel, ranchan, reschan)
    dc = try 
      take!(dcchan)
    catch e
      println("Error serializing DATConfig, make sure all required package are loaded on all workers. ")
      put!(reschan,e)
      return
    end
    loopworker(dc, ranchan, reschan)
    return 
end
function loopworker(dc::DATConfig, ranchan, reschan)
  incaches, outcaches, args = try
    getallargs(dc)
  catch e
    println("Error during initialization: ", e)
    put!(reschan, e)
  end
  try
    loopworker(dc,ranchan, reschan, incaches, outcaches, args)
  catch e
    if e isa InvalidStateException
      return nothing
    elseif e isa RemoteException && e.captured.ex isa InvalidStateException
      return nothing
    else
      println("Error during running loop: ", e)
      put!(reschan, e)
    end
  end
end

function loopworker(dc,ranchan, reschan, incaches, outcaches, args)
  while true
    r = take!(ranchan)
    updateinars(dc,r,incaches)
    innerLoop(r,args...)
    writeoutars(dc,r,outcaches)
    @async put!(reschan,r)
  end
end

function moduleloadedeverywhere()
  try 
    isloaded = map(workers()) do w
      #We try calling a function defined inside this module, thi will error when YAXArrays is not loaded on the remote workers
      remotecall(()->true,w)
    end
    fetch.(isloaded)
  catch e
      return false
  end
  return true
end

function runLoop(dc::DATConfig,showprog)
  allRanges=distributeLoopRanges((dc.loopcachesize...,),(map(length,dc.LoopAxes)...,),getchunkoffsets(dc))
  chnlfunc() = Channel{Union{eltype(allRanges),Nothing}}(length(allRanges))
  outchanfunc() = Channel(length(allRanges))
  inchan, outchan, dcpass = if dc.ispar
    #Test if YAXArrays is loaded on all workers:
    moduleloadedeverywhere() || error("YAXArrays is not loaded on all workers. Please run `@everywhere using YAXArrays` to fix.")
    dcpass = RemoteChannel(()->Channel{DATConfig}(nworkers()))
    for i=1:nworkers()
      put!(dcpass, dc)
    end
    RemoteChannel(chnlfunc), RemoteChannel(outchanfunc), dcpass
  else
    chnlfunc(), outchanfunc(), dc
  end
  #Now distribute the jobs
  for r in allRanges
    put!(inchan,r)
  end
  #And start the workers
  if dc.ispar
    for p in workers()
      remote_do(YAXArrays.DAT.loopworker, p, dcpass, inchan, outchan)
    end
  else
    @async loopworker(dc, inchan, outchan)
  end
  showprog && (pm=Progress(length(allRanges)))
  for i in 1:length(allRanges)
    r = take!(outchan)
    if isa(r,Exception)
      throw(r)
    end
    showprog && next!(pm)
  end
  close(inchan)
  dc.outcubes
end

abstract type AxValCreator end
struct NoLoopAxes <:AxValCreator end
struct AllLoopAxes{S,V} <:AxValCreator
  loopsyms::S
  loopaxvals::V
end
AllLoopAxes(a) = AllLoopAxes(map(axsym,a), map(i->i.values,a))
getlaxvals(::NoLoopAxes,cI,offscur) = ()
getlaxvals(a::AllLoopAxes,cI,offscur) = (NamedTuple{a.loopsyms}(map((ax,i,of)->(i+of,ax[i+of]),a.loopaxvals,cI.I, offscur)),)


function getallargs(dc::DATConfig)
  incache, outcache = getCubeCache(dc)
  filters = map(ic->ic.desc.procfilter,dc.incubes)
  inworkar, outworkar = generateworkarrays(dc)
  axvals = if dc.include_loopvars
    lax = (dc.LoopAxes...,)
    AllLoopAxes(lax)
  else
    NoLoopAxes()
  end
  adda = dc.addargs
  kwa = dc.kwargs
  fu = if !dc.inplace
    makeinplace(dc.fu)
  else
    dc.fu
  end
  inarsbc = map(dc.incubes, incache) do ic, cache
    allax = getindsall(geticolon(ic), ic.loopinds, i->true)
    if ic.colonperm === nothing
      pa = PickAxisArray(cache,allax)
    else
      pa = PickAxisArray(cache,allax,ic.colonperm)
    end
  end
  outarsbc = map(dc.outcubes, outcache) do oc, cache
    allax = getindsall(1:length(oc.axesSmall), oc.loopinds, i->true)
    pa = PickAxisArray(cache,allax)
    pa
  end
  incache, outcache, (fu,inarsbc,outarsbc,filters,inworkar,outworkar,
  axvals,adda,kwa)
end


function getbackend(oc,ispar,max_cache)
  eltype=Union{oc.outtype,Missing}
  outsize=sizeof(eltype)*(length(oc.allAxes)>0 ? prod(map(length,oc.allAxes)) : 1)
  rt = oc.desc.backend
  if rt == :auto
    if ispar[] || outsize>max_cache
      rt = :zarr
    else
      rt = :array
    end
  end
  b = YAXArrayBase.backendlist[Symbol(rt)]
  if !allow_parallel_write(b)
    ispar[] = false
  end
  eltype,b
end

function generateOutCube(::Type{T},eltype,oc::OutputCube,loopcachesize,co;kwargs...) where T
  cs_inner = (map(length,oc.axesSmall)...,)
  cs = (cs_inner..., loopcachesize...)
  for (i,cc) in enumerate(oc.innerchunks)
    if cc !== nothing
      cs = Base.setindex(cs,cc,i)
    end
  end
  oc.cube=createdataset(T, oc.allAxes; chunksize=cs, chunkoffset=co, kwargs...)
end
function generateOutCube(::Type{T},eltype,oc::OutputCube,loopcachesize,co;kwargs...) where T<:Array
  newsize=map(length,oc.allAxes)
  outar=Array{eltype}(undef,newsize...)
  map!(_->_zero(eltype),outar,1:length(outar))
  oc.cube = YAXArray(oc.allAxes,outar)
end
_zero(T) = zero(T)
_zero(T::Type{<:AbstractString}) = convert(T,"")


function generateOutCubes(dc::DATConfig)
  co = getchunkoffsets(dc)
  foreach(dc.outcubes) do c
    co2 = (zeros(Int,length(c.axesSmall))...,co...)
    generateOutCube(c,Ref(dc.ispar),dc.max_cache,dc.loopcachesize,co2)
  end
end
function generateOutCube(oc::OutputCube,ispar::Ref{Bool},max_cache,loopcachesize,co)
  eltype,cubetype = getbackend(oc,ispar,max_cache)
  generateOutCube(cubetype,eltype,oc,loopcachesize,co;oc.desc.backendargs...)
end

function getCubeCache(dc::DATConfig)
  outcaches = map(i->allocatecachebuf(i,dc.loopcachesize),dc.outcubes)
  incaches = map(i->allocatecachebuf(i,dc.loopcachesize),dc.incubes)
  incaches, outcaches
end

function allocatecachebuf(ic::Union{InputCube,OutputCube},loopcachesize)
  s = size(ic.cube)
  indsall = getindsall(geticolon(ic), ic.loopinds, i->loopcachesize[i], i->s[i])
  zeros(eltype(ic.cube),indsall...)
end

function init_DATworkers()
  freshworkermodule()
end

function analyzeAxes(dc::DATConfig{NIN,NOUT}) where {NIN,NOUT}

  for cube in dc.incubes
    for a in caxes(cube.cube)
      in(a,cube.axesSmall) || in(a,dc.LoopAxes) || push!(dc.LoopAxes,a)
    end
  end
  length(dc.LoopAxes)==length(unique(map(typeof,dc.LoopAxes))) || error("Make sure that cube axes of different cubes match")
  for cube=dc.incubes
    myAxes = caxes(cube.cube)
    for (il,loopax) in enumerate(dc.LoopAxes)
      in(typeof(loopax),map(typeof,myAxes)) && push!(cube.loopinds,il)
    end
  end
  #Add output broadcast axes
  for outcube=dc.outcubes
    LoopAxesAdd=CubeAxis[]
    for (il,loopax) in enumerate(dc.LoopAxes)
      push!(outcube.loopinds,il)
      push!(LoopAxesAdd,loopax)
    end
    outcube.allAxes=CubeAxis[outcube.axesSmall;LoopAxesAdd]
    dold = outcube.innerchunks
    newchunks = Union{Int,Nothing}[nothing for _ in 1:length(outcube.allAxes)]
    for (k,v) in dold
      ii = findAxis(k,outcube.allAxes)
      if ii !== nothing
        newchunks[ii] = v
      end
    end
    outcube.innerchunks = newchunks
  end
  #And resolve names in chunk size dicts
  return dc
end

mysizeof(x)=sizeof(x)
mysizeof(x::Type{String})=1

"""
Function that compares two cache miss specifiers by their importance
"""
function cmpcachmisses(x1,x2)
  #First give preference to compressed misses
  if xor(x1.iscompressed,x2.iscompressed)
    return x1.iscompressed
  #Now compare the size of the miss multiplied with the inner size
  else
    return x1.cs * x1.innerleap > x2.cs * x2.innerleap
  end
end

function getCacheSizes(dc::DATConfig,loopchunksizes)

  inAxlengths      = Vector{Int}[Int.(length.(cube.axesSmall)) for cube in dc.incubes]
  inblocksizes     = map((x,T)->isempty(x) ? mysizeof(eltype(T.cube)) : prod(x)*mysizeof(eltype(T.cube)),inAxlengths,dc.incubes)
  inblocksize,imax = findmax(inblocksizes)
  outblocksizes    = map(C->length(C.axesSmall)>0 ? sizeof(C.outtype)*prod(map(Int∘length,C.axesSmall)) : 1,dc.outcubes)
  outblocksize     = length(outblocksizes) > 0 ? findmax(outblocksizes)[1] : 1
  #Now add cache miss information for each input cube to every loop axis
  cmisses= NamedTuple{(:iloopax,:cs, :iscompressed, :innerleap,:preventpar),Tuple{Int64,Int64,Bool,Int64,Bool}}[]
  userchunks = Dict{Int,Int}()
  for (k,v) in loopchunksizes
    ii = findAxis(k,dc.LoopAxes)
    if ii !== nothing
      userchunks[ii] = v
    end
  end
  foreach(dc.LoopAxes,1:length(dc.LoopAxes)) do lax,ilax
    haskey(userchunks,ilax) && return nothing
    for ic in dc.incubes
      ii = findAxis(lax,ic.cube)
      if !isa(ii,Nothing)
        inax = isempty(ic.axesSmall) ? 1 : prod(map(length,ic.axesSmall))
        push!(cmisses,(iloopax = ilax,cs = cubechunks(ic.cube)[ii],iscompressed = iscompressed(ic.cube), innerleap=inax,preventpar=false))
      end
    end
    for oc in dc.outcubes
      cs = oc.innerchunks
      ii = findAxis(lax,oc.allAxes)
      if !isa(ii,Nothing) && !isa(cs[ii],Nothing)
        innerleap = isempty(oc.axesSmall) ? 1 : prod(map(length,oc.axesSmall))
        push!(cmisses,(iloopax = ilax,cs = cs[ii],iscompressed = iscompressed(oc.cube), innerleap=innerleap, preventpar=true))
      end
    end
  end
  sort!(cmisses,lt=cmpcachmisses)
  loopcachesize,nopar    = getLoopCacheSize(max(inblocksize,outblocksize),map(length,dc.LoopAxes),dc.max_cache, cmisses, userchunks)
  for cube in dc.incubes
    cube.cachesize = map(length,cube.axesSmall)
    for (cs,loopAx) in zip(loopcachesize,dc.LoopAxes)
      in(typeof(loopAx),map(typeof,caxes(cube.cube))) && push!(cube.cachesize,cs)
    end
  end
  nopar && (dc.ispar = false)
  dc.loopcachesize=loopcachesize
  return dc
end

"Calculate optimal Cache size to DAT operation"
function getLoopCacheSize(preblocksize,loopaxlengths,max_cache,cmisses,userchunks)
  totcachesize=max_cache
  loopcachesize = ones(Int,length(loopaxlengths))
  #Go through user definitions
  incfac=totcachesize/preblocksize/prod(loopcachesize)
  incfac<1 && error("The requested slices do not fit into the specified cache. Please consider increasing max_cache")

  # Go through list of cache misses first and decide
  imiss = 1
  while imiss<=length(cmisses)
    il = cmisses[imiss].iloopax
    s = min(cmisses[imiss].cs,loopaxlengths[il])/loopcachesize[il]
    #Check if cache size is already set for this axis
    if loopcachesize[il]==1
      if s<incfac
        loopcachesize[il]=min(cmisses[imiss].cs,loopaxlengths[il])
        incfac=totcachesize/preblocksize/prod(loopcachesize)
      else
        ii=floor(Int,incfac)
        while ii>1 && rem(s,ii)!=0
          ii=ii-1
        end
        loopcachesize[il]=ii
        break
      end
    end
    imiss+=1
  end
  #Now second run to read multiple blocks at once
  if incfac >= 2
    for i=1:length(loopcachesize)
      haskey(userchunks,i) && continue
      imul = min(floor(Int,incfac),loopaxlengths[i]÷loopcachesize[i])
      loopcachesize[i] = loopcachesize[i] * imul
      incfac = incfac/imul
      incfac < 2 && break
    end
  end
  if imiss<length(cmisses)+1
    @warn "There are still cache misses"
    cmisses[imiss].iscompressed && @warn "There are compressed caches misses, you may want to use a different cube chunking"
  else
    #TODO continue increasing cache sizes on by one...
  end
  nopar = any(i->i.preventpar,cmisses[imiss:end])
  return loopcachesize, nopar
end

function distributeLoopRanges(block_size::NTuple{N,Int},loopR::NTuple{N,Int},co) where N
    allranges = map(block_size,loopR,co) do bs,lr,cocur
      collect(filter(!isempty,[max(1,i):min(i+bs-1,lr) for i in (1-cocur):bs:lr]))
    end
    Iterators.product(allranges...)
end

function generateworkarrays(dc::DATConfig)
  inwork = map(i->getworkarray(i,dc.ntr[myid()]),dc.incubes)
  outwork = map(i->getworkarray(i,dc.ntr[myid()]),dc.outcubes)
  inwork, outwork
end

macro innercode()
  esc(quote
    ithr = Threads.threadid()
    #Pick the correct array according to thread
    myinwork = map(i->i[ithr],inwork)
    myoutwork = map(i->i[ithr],outwork)
    #Copy data into work arrays
    foreach(myinwork,xinBC) do iw,x
      iw.=view(x,cI.I...)
    end
    #Apply filters
    mvs = map(docheck,filters,myinwork)
    if any(mvs)
      # Set all outputs to missing
      foreach(ow->fill!(ow,missing),myoutwork)
    else
      #Compute loop axis values if necessary
      laxval = getlaxvals(axvalcreator,cI,offscur)
      #Finally call the function
      f(myoutwork...,myinwork...,laxval...,addargs...;kwargs...)
    end
    #Copy data into output array
    foreach((iw,x)->view(x,cI.I...).=iw,myoutwork,xoutBC)
  end)
end

using DataStructures: OrderedDict
using Base.Cartesian
@noinline function innerLoop(loopRanges,f,xinBC,xoutBC,filters,
  inwork,outwork,axvalcreator,addargs,kwargs)
  offscur = map(i->(first(i)-1), loopRanges)
  if length(inwork[1])==1
    for cI in CartesianIndices(map(i->1:length(i),loopRanges))
      @innercode
    end
  else
    Threads.@threads for cI in CartesianIndices(map(i->1:length(i),loopRanges))
      @innercode
    end
  end
end


"Calculate an axis permutation that brings the wanted dimensions to the front"
function getFrontPerm(dc,dims)
  ax=caxes(dc)
  N=length(ax)
  perm=Int[i for i=1:length(ax)];
  iold=Int[]
  for i=1:length(dims) push!(iold,findAxis(dims[i],ax)) end
  iold2=sort(iold,rev=true)
  for i=1:length(iold) splice!(perm,iold2[i]) end
  perm=Int[iold;perm]
  return ntuple(i->perm[i],N)
end

include("dciterators.jl")
include("tablestats.jl")
include("CubeIO.jl")
end
