__precompile__()

module PortAudio

using SampledSignals
using RingBuffers
using Suppressor

using Base: AsyncCondition

# Get binary dependencies loaded from BinDeps
include("../deps/deps.jl")
include("pa_shim.jl")
include("libportaudio.jl")

function __init__()
    init_pa_shim()
    global const notifycb_c = cfunction(notifycb, Cint, (Ptr{Void}, ))
    # initialize PortAudio on module load
    @suppress_err Pa_Initialize()
end


export PortAudioStream

# These sizes are all in frames

# the block size is what we request from portaudio if no blocksize is given.
# The ringbuffer and pre-fill will be twice the blocksize
const DEFAULT_BLOCKSIZE=4096

# data is passed to and from the ringbuffer in chunks with this many frames
# it should be at most the ringbuffer size, and must evenly divide into the
# the underlying portaudio buffer size. E.g. if PortAudio is running with a
# 2048-frame buffer period, the chunk size can be 2048, 1024, 512, 256, etc.
const CHUNKSIZE=128

# ringbuffer to receive errors from the audio processing thread
const ERR_BUFSIZE=512

function versioninfo(io::IO=STDOUT)
    println(io, Pa_GetVersionText())
    println(io, "Version: ", Pa_GetVersion())
    println(io, "Shim Version: ", shimversion())
end

type PortAudioDevice
    name::String
    hostapi::String
    maxinchans::Int
    maxoutchans::Int
    defaultsamplerate::Float64
    idx::PaDeviceIndex
end

PortAudioDevice(info::PaDeviceInfo, idx) = PortAudioDevice(
        unsafe_string(info.name),
        unsafe_string(Pa_GetHostApiInfo(info.host_api).name),
        info.max_input_channels,
        info.max_output_channels,
        info.default_sample_rate,
        idx)

function devices()
    ndevices = Pa_GetDeviceCount()
    infos = PaDeviceInfo[Pa_GetDeviceInfo(i) for i in 0:(ndevices - 1)]
    PortAudioDevice[PortAudioDevice(info, idx-1) for (idx, info) in enumerate(infos)]
end

# not for external use, used in error message printing
devnames() = join(["\"$(dev.name)\"" for dev in devices()], "\n")

##################
# PortAudioStream
##################

type PortAudioStream{T}
    samplerate::Float64
    blocksize::Int
    stream::PaStream
    sink # untyped because of circular type definition
    source # untyped because of circular type definition
    errbuf::RingBuffer{pa_shim_errmsg_t} # used to send errors from the portaudio callback
    bufinfo::pa_shim_info_t # data used in the portaudio callback

    # this inner constructor is generally called via the top-level outer
    # constructor below
    function PortAudioStream{T}(indev::PortAudioDevice, outdev::PortAudioDevice,
                                inchans, outchans, sr, blocksize, synced) where {T}
        inchans = inchans == -1 ? indev.maxinchans : inchans
        outchans = outchans == -1 ? outdev.maxoutchans : outchans
        inparams = (inchans == 0) ?
            Ptr{Pa_StreamParameters}(0) :
            Ref(Pa_StreamParameters(indev.idx, inchans, type_to_fmt[T], 0.0, C_NULL))
        outparams = (outchans == 0) ?
            Ptr{Pa_StreamParameters}(0) :
            Ref(Pa_StreamParameters(outdev.idx, outchans, type_to_fmt[T], 0.0, C_NULL))
        this = new(sr, blocksize, C_NULL)
        finalizer(this, close)
        this.sink = PortAudioSink{T}(outdev.name, this, outchans, blocksize*2)
        this.source = PortAudioSource{T}(indev.name, this, inchans, blocksize*2)
        this.errbuf = RingBuffer{pa_shim_errmsg_t}(1, ERR_BUFSIZE)
        if synced && inchans > 0 && outchans > 0
            # we've got a synchronized duplex stream. initialize with the output buffer full
            write(this.sink, SampleBuf(zeros(T, blocksize*2, outchans), sr))
        end
        this.bufinfo = pa_shim_info_t(bufpointer(this.source),
                                      bufpointer(this.sink),
                                      pointer(this.errbuf),
                                      synced, notifycb_c,
                                      getnotifyhandle(this.sink),
                                      getnotifyhandle(this.source),
                                      getnotifyhandle(this.errbuf))
        this.stream = @suppress_err Pa_OpenStream(inparams, outparams,
                                                  float(sr), blocksize,
                                                  paNoFlag, shim_processcb_c,
                                                  this.bufinfo)

        Pa_StartStream(this.stream)
        @async handle_errors(this)

        this
    end
end

# this is the top-level outer constructor that all the other outer constructors
# end up calling
function PortAudioStream(indev::PortAudioDevice, outdev::PortAudioDevice,
        inchans=2, outchans=2; eltype=Float32, samplerate=-1, blocksize=DEFAULT_BLOCKSIZE, synced=false)
    if samplerate == -1
        sampleratein = indev.defaultsamplerate
        samplerateout = outdev.defaultsamplerate
        if inchans > 0 && outchans > 0 && sampleratein != samplerateout
            error("""
            Can't open duplex stream with mismatched samplerates (in: $sampleratein, out: $samplerateout).
                   Try changing your sample rate in your driver settings or open separate input and output
                   streams""")
        elseif inchans > 0
            samplerate = sampleratein
        else
            samplerate = samplerateout
        end
    end
    PortAudioStream{eltype}(indev, outdev, inchans, outchans, samplerate, blocksize, synced)
end

# handle device names given as streams
function PortAudioStream(indevname::AbstractString, outdevname::AbstractString, args...; kwargs...)
    indev = nothing
    outdev = nothing
    for d in devices()
        if d.name == indevname
            indev = d
        end
        if d.name == outdevname
            outdev = d
        end
    end
    if indev == nothing
        error("No device matching \"$indevname\" found.\nAvailable Devices:\n$(devnames())")
    end
    if outdev == nothing
        error("No device matching \"$outdevname\" found.\nAvailable Devices:\n$(devnames())")
    end

    PortAudioStream(indev, outdev, args...; kwargs...)
end

# if one device is given, use it for input and output, but set inchans=0 so we
# end up with an output-only stream
function PortAudioStream(device::PortAudioDevice, inchans=2, outchans=2; kwargs...)
    PortAudioStream(device, device, inchans, outchans; kwargs...)
end
function PortAudioStream(device::AbstractString, inchans=2, outchans=2; kwargs...)
    PortAudioStream(device, device, inchans, outchans; kwargs...)
end

# use the default input and output devices
function PortAudioStream(inchans=2, outchans=2; kwargs...)
    inidx = Pa_GetDefaultInputDevice()
    indevice = PortAudioDevice(Pa_GetDeviceInfo(inidx), inidx)
    outidx = Pa_GetDefaultOutputDevice()
    outdevice = PortAudioDevice(Pa_GetDeviceInfo(outidx), outidx)
    PortAudioStream(indevice, outdevice, inchans, outchans; kwargs...)
end

function Base.close(stream::PortAudioStream)
    if stream.stream != C_NULL
        Pa_StopStream(stream.stream)
        Pa_CloseStream(stream.stream)
        close(stream.source)
        close(stream.sink)
        stream.stream = C_NULL
    end

    nothing
end

Base.isopen(stream::PortAudioStream) = stream.stream != C_NULL

SampledSignals.samplerate(stream::PortAudioStream) = stream.samplerate
Base.eltype{T}(stream::PortAudioStream{T}) = T

Base.read(stream::PortAudioStream, args...) = read(stream.source, args...)
Base.read!(stream::PortAudioStream, args...) = read!(stream.source, args...)
Base.write(stream::PortAudioStream, args...) = write(stream.sink, args...)
Base.write(sink::PortAudioStream, source::PortAudioStream, args...) = write(sink.sink, source.source, args...)
Base.flush(stream::PortAudioStream) = flush(stream.sink)

function Base.show(io::IO, stream::PortAudioStream)
    println(io, typeof(stream))
    println(io, "  Samplerate: ", samplerate(stream), "Hz")
    print(io, "  Buffer Size: ", stream.blocksize, " frames")
    if nchannels(stream.sink) > 0
        print(io, "\n  ", nchannels(stream.sink), " channel sink: \"", name(stream.sink), "\"")
    end
    if nchannels(stream.source) > 0
        print(io, "\n  ", nchannels(stream.source), " channel source: \"", name(stream.source), "\"")
    end
end

"""
    handle_errors(stream::PortAudioStream)

Handle errors coming over the error stream from PortAudio. This is run as an
independent task while the stream is active.
"""
function handle_errors(stream::PortAudioStream)
    err = Vector{pa_shim_errmsg_t}(1)
    while true
        nread = read!(stream.errbuf, err)
        nread == 1 || break
        if err[1] == PA_SHIM_ERRMSG_ERR_OVERFLOW
            warn("Error buffer overflowed on stream $(stream.name)")
        elseif err[1] == PA_SHIM_ERRMSG_OVERFLOW
            # warn("Input overflowed from $(name(stream.source))")
        elseif err[1] == PA_SHIM_ERRMSG_UNDERFLOW
            # warn("Output underflowed to $(name(stream.sink))")
        else
            error("""
                Got unrecognized error code $(err[1]) from audio thread for
                stream "$(stream.name)". Please file an issue at
                https://github.com/juliaaudio/portaudio.jl/issues""")
        end
    end
end

##################################
# PortAudioSink & PortAudioSource
##################################

# Define our source and sink types
for (TypeName, Super) in ((:PortAudioSink, :SampleSink),
                          (:PortAudioSource, :SampleSource))
    @eval type $TypeName{T} <: $Super
        name::String
        stream::PortAudioStream{T}
        chunkbuf::Array{T, 2}
        ringbuf::RingBuffer{T}
        nchannels::Int

        function $TypeName{T}(name, stream, channels, ringbufsize) where {T}
            # portaudio data comes in interleaved, so we'll end up transposing
            # it back and forth to julia column-major
            chunkbuf = zeros(T, channels, CHUNKSIZE)
            ringbuf = RingBuffer{T}(channels, ringbufsize)
            new(name, stream, chunkbuf, ringbuf, channels)
        end
    end
end

SampledSignals.nchannels(s::Union{PortAudioSink, PortAudioSource}) = s.nchannels
SampledSignals.samplerate(s::Union{PortAudioSink, PortAudioSource}) = samplerate(s.stream)
SampledSignals.blocksize(s::Union{PortAudioSink, PortAudioSource}) = s.stream.blocksize
Base.eltype(::Union{PortAudioSink{T}, PortAudioSource{T}}) where {T} = T
Base.close(s::Union{PortAudioSink, PortAudioSource}) = close(s.ringbuf)
Base.isopen(s::Union{PortAudioSink, PortAudioSource}) = isopen(s.ringbuf)
RingBuffers.getnotifyhandle(s::Union{PortAudioSink, PortAudioSource}) = getnotifyhandle(s.ringbuf)
bufpointer(s::Union{PortAudioSink, PortAudioSource}) = pointer(s.ringbuf)
name(s::Union{PortAudioSink, PortAudioSource}) = s.name

function Base.show(io::IO, stream::T) where {T <: Union{PortAudioSink, PortAudioSource}}
    println(io, T, "(\"", stream.name, "\")")
    print(io, nchannels(stream), " channels")
end

# function Base.flush(sink::PortAudioSink)
#     while nwritable(sink.ringbuf) < length(sink.ringbuf)
#         wait(sink.ringbuf)
#     end
# end

function SampledSignals.unsafe_write(sink::PortAudioSink, buf::Array, frameoffset, framecount)
    nwritten = 0
    while nwritten < framecount
        towrite = min(framecount-nwritten, CHUNKSIZE)
        # make a buffer of interleaved samples
        transpose!(view(sink.chunkbuf, :, 1:towrite),
                   view(buf, (1:towrite)+nwritten+frameoffset, :))
        n = write(sink.ringbuf, sink.chunkbuf, towrite)
        nwritten += n
        # break early if the stream is closed
        n < towrite && break
    end

    nwritten
end

function SampledSignals.unsafe_read!(source::PortAudioSource, buf::Array, frameoffset, framecount)
    nread = 0
    while nread < framecount
        toread = min(framecount-nread, CHUNKSIZE)
        n = read!(source.ringbuf, source.chunkbuf, toread)
        # de-interleave the samples
        transpose!(view(buf, (1:toread)+nread+frameoffset, :),
                   view(source.chunkbuf, :, 1:toread))

        nread += toread
        # break early if the stream is closed
        n < toread && break
    end

    nread
end

# this is called by the shim process callback to notify that there is new data.
# it's run in the audio context so don't do anything besides wake up the
# AsyncCondition
notifycb(handle) = ccall(:uv_async_send, Cint, (Ptr{Void}, ), handle)

end # module PortAudio
