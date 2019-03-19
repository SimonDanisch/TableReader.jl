module TableReader

export readdlm, readcsv, readtsv

using Dates:
    Date,
    DateTime,
    @dateformat_str
using Unicode:
    isletter
using DataFrames:
    DataFrame
using TranscodingStreams:
    TranscodingStreams,
    TranscodingStream,
    NoopStream,
    Memory,
    Buffer,
    State,
    Noop,
    fillbuffer,
    makemargin!,
    buffermem
using CodecZlib:
    GzipDecompressorStream
using CodecZstd:
    ZstdDecompressorStream
using CodecXz:
    XzDecompressorStream

const SP = UInt8(' ')
const CR = UInt8('\r')
const LF = UInt8('\n')

include("stringcache.jl")
include("tokenizer.jl")
include("parser.jl")

const DEFAULT_CHUNK_SIZE =  1 * 2^20  #  1 MiB
const MINIMUM_CHUNK_SIZE = 16 * 2^10  # 16 KiB

# Printable characters
const CHARS_PRINT = ' ':'~'

# Whitelist of delimiters and quotation marks
const ALLOWED_DELIMITERS = tuple(['\t'; CHARS_PRINT[.!(isletter.(CHARS_PRINT) .| isdigit.(CHARS_PRINT))]]...)
const ALLOWED_QUOTECHARS = tuple(CHARS_PRINT[.!(isletter.(CHARS_PRINT) .| isdigit.(CHARS_PRINT))]...)

"""
    readdlm(filename, command, or IO object;
            delim,
            quot = '"',
            trim = true,
            skip = 0,
            header = nothing,
            chunksize = 1 MiB)

Read a character delimited text file.

[`readcsv`](@ref) and [`readtsv`](@ref) call this function behind. To read a
CSV or TSV file, consider to use these dedicated function instead.


## Data source

The first (and the only positional) argument specifies the source to read data
from there.

If the argument is a string, it is considered as a local file name or the URL
of a remote file. If the name matches with `r"^\\w+://.*"` in regular
expression, it is handled as a URL. For example,
`"https://example.com/path/to/file.csv"` is regarded as a URL and its content
is streamed using the `curl` command.

If the argument is a command object, it is considered as a source whose
standard output is text data to read. For example, `unzip -p path/to/file.zip
somefile.csv` can be used to extract a file from a zipped archive. It is also
possible to pipeline several commands using `pipeline`.

If the arguments is an object of the `IO` type, it is considered as a direct
data source. The content is read using `read` or other similar functions. For
example, passing `IOBuffer(text)` makes it possible to read data from the raw
text object.

The data source is transparently decompressed if the compression format is
detectable. Currently, gzip, zstd, and xz are supported. The format is detected
by the magic bytes of the stream header, and therefore other information such
as file names does not affect the detection.


## Parser parameters

`delim` specifies the field delimiter in a line.  This cannot be the same
character as `quot`.  Currently, the following delimiters are allowed:
$(join(repr.(ALLOWED_DELIMITERS), ", ")).

`quot` specifies the quotation character to enclose a field. This cannot be the
same character as `delim`. Currently, the following quotation characters are
allowed: $(join(repr.(ALLOWED_QUOTECHARS), ", ")).

`trim` specifies whether the parser trims space (0x20) characters around a field.
If `trim` is true, `delim` and `quot` cannot be a space character.

`skip` specifies the number of lines to skip before reading data.  The next
line just after the skipped lines is considered as a header line if the
`header` parameter is not specified.


## Column names

`header` specifies the column names. If `header` is `nothing` (default), the
column names are read from the first line of the text file. Any iterable object
is allowed.

If unnamed columns are found in the header, they are renamed to `UNNAMED_{j}`
for ease of access, where `{j}` is replaced by the column number. If the number
of header columns in a file is less than the number of data columns by one, a
column name `UNNAMED_0` will be inserted into the column names as the first
column.  This is useful to read files written by the `write.table` function of
R with `row.names = TRUE`.


## Parsing behavior

The only supported text encoding of a file is UTF-8, which is the default
character encoding scheme of many functions in Julia.  If you need to read text
encoded other than UTF-8, it is required to wrap the data stream with an
encoding conversion tool such as the `iconv` command or StringEncodings.jl.

```julia
# Convert text encoding from Shift JIS (Japanese) to UTF8.
readcsv(`iconv -f sjis -t utf8 somefile.csv`)
```

A text file will be read chunk by chunk to save memory. The chunk size is
specified by the `chunksize` parameter, which is set to 1 MiB by default.  The
data type of each column is guessed from the values in the first chunk.  If
`chunksize` is set to zero, it disables chunking and the data types are guessed
from all rows.
"""
function readdlm end

"""
    readcsv(filename or IO object; delim = ',', <keyword arguments>)

Read a CSV (comma-separated values) text file.

This function is the same as [`readdlm`](@ref) but with `delim = ','`.
See `readdlm` for details.
"""
function readcsv end

"""
    readtsv(filename or IO object; delim = '\\t', <keyword arguments>)

Read a TSV (tab-separated values) text file.

This function is the same as [`readdlm`](@ref) but with `delim = '\\t'`.
See `readdlm` for details.
"""
function readtsv end

for (fname, delim) in [(:readdlm, nothing), (:readcsv, ','), (:readtsv, '\t')]
    # prepare keyword arguments
    kwargs = Expr[]
    if delim === nothing
        push!(kwargs, :(delim::Char))
    else
        push!(kwargs, Expr(:kw, :(delim::Char), delim))
    end
    push!(kwargs, Expr(:kw, :(quot::Char), '"'))  # quot::Char = '"'
    push!(kwargs, Expr(:kw, :(trim::Bool), true))  # trim::Bool = true
    push!(kwargs, Expr(:kw, :(skip::Integer), 0))  # skip::Integer = 0
    push!(kwargs, Expr(:kw, :(header), nothing))  # header = nothing
    push!(kwargs, Expr(:kw, :(chunksize::Integer), DEFAULT_CHUNK_SIZE))  # chunksize::Integer = DEFAULT_CHUNK_SIZE

    # generate methods
    @eval begin
        function $(fname)(filename::AbstractString; $(kwargs...))
            params = ParserParameters(delim, quot, trim, skip, header, chunksize)
            if occursin(r"^\w+://", filename)  # URL-like filename
                if Sys.which("curl") === nothing
                    throw(ArgumentError("the curl command is not available"))
                end
                # read a remote file using curl
                return open(proc -> readdlm_internal(wrapstream(proc, params), params), `curl --silent $(filename)`)
            end
            # read a local file
            return open(file -> readdlm_internal(wrapstream(file, params), params), filename)
        end

        function $(fname)(cmd::Base.AbstractCmd; $(kwargs...))
            params = ParserParameters(delim, quot, trim, skip, header, chunksize)
            return open(proc -> readdlm_internal(wrapstream(proc, params), params), cmd)
        end

        function $(fname)(file::IO; $(kwargs...))
            params = ParserParameters(delim, quot, trim, skip, header, chunksize)
            return readdlm_internal(wrapstream(file, params), params)
        end
    end
end

# Wrap a stream by TranscodingStream.
function wrapstream(stream::IO, params::ParserParameters)
    bufsize = max(params.chunksize, MINIMUM_CHUNK_SIZE)
    if !applicable(mark, stream) || !applicable(reset, stream)
        stream = NoopStream(stream, bufsize = bufsize)
    end
    format = checkformat(stream)
    if params.chunksize != 0
        # with chunking
        if format == :gzip
            return GzipDecompressorStream(stream, bufsize = bufsize)
        elseif format == :zstd
            return ZstdDecompressorStream(stream, bufsize = bufsize)
        elseif format == :xz
            return XzDecompressorStream(stream, bufsize = bufsize)
        elseif stream isa TranscodingStream
            return stream
        else
            return NoopStream(stream, bufsize = bufsize)
        end
    end
    # without chunking
    if format == :gzip
        data = read(GzipDecompressorStream(stream))
    elseif format == :zstd
        data = read(ZstdDecompressorStream(stream))
    elseif format == :xz
        data = read(XzDecompressorStream(stream))
    else
        data = read(stream)
    end
    buffer = Buffer(data)
    return TranscodingStream(Noop(), devnull, State(buffer, buffer))
end

# Check the file format of a stream.
function checkformat(stream::IO)
    mark(stream)
    magic = zeros(UInt8, 6)
    nb = readbytes!(stream, magic, 6)
    reset(stream)
    if nb != 6
        return :unknown
    elseif magic[1:6] == b"\xFD\x37\x7A\x58\x5A\x00"
        return :xz
    elseif magic[1:2] == b"\x1f\x8b"
        return :gzip
    elseif magic[1:4] == b"\x28\xb5\x2f\xfd"
        return :zstd
    else
        return :unknown
    end
end

function readdlm_internal(stream::TranscodingStream, params::ParserParameters)
    # Determine column names
    delim, quot, trim = params.delim, params.quot, params.trim
    line = skiplines(stream, params.skip) + 1
    mem, lastnl = bufferlines(stream)
    @assert lastnl > 0
    if params.colnames === nothing
        # Scan the header line to get the column names
        n, headertokens = scanheader(mem, 0, lastnl, delim, quot, trim)
        skip(stream, n)
        if length(headertokens) == 1 && location(headertokens[1])[2] == 0  # zero-length token
            throw(ReadError("found no column names in the header at line $(line)"))
        end
        line += 1
        colnames = Symbol[]
        for (i, token) in enumerate(headertokens)
            start, length = location(token)
            if (kind(token) & QSTRING) != 0
                name = qstring(mem, start, length, quot)
            else
                name = unsafe_string(mem.ptr + start - 1, length)
            end
            if isempty(name)  # unnamed column
                name = "UNNAMED_$(i)"
            end
            push!(colnames, Symbol(name))
        end
    else
        colnames = params.colnames
    end
    ncols = length(colnames)

    # Scan the next line to get the number of data columns
    mem, lastnl = bufferlines(stream)
    @assert lastnl > 0
    tokens = Array{Token}(undef, (ncols + 1, 1))
    _, i = scanline!(tokens, 1, mem, 0, lastnl, line, delim, quot, trim)
    if i == 1 && location(tokens[1,1])[2] == 0
        # no data
        return DataFrame([[] for _ in 1:length(colnames)], colnames)
    elseif i == ncols
        # the header and the first row have the same number of columns
    elseif i == ncols + 1
        # the first column is supposed to be unnamed
        ncols += 1
        pushfirst!(colnames, :UNNAMED_0)
    else
        throw(ReadError("unexpected number of columns at line $(line)"))
    end

    # Estimate the number of rows.
    nrows_estimated = countbytes(mem, LF)
    if nrows_estimated == 0
        nrows_estimated = countbytes(mem, CR)
    end
    n_chunk_rows = max(nrows_estimated, 5)  # allocate at least five rows

    # Read data.
    tokens = Array{Token}(undef, (ncols, n_chunk_rows))
    columns = Vector[]
    while !eof(stream)
        # Tokenize data.
        mem, lastnl = bufferlines(stream)
        @assert lastnl > 0
        pos = 0
        chunk_begin = line
        while pos < lastnl && line - chunk_begin + 1 ≤ n_chunk_rows
            pos, i = scanline!(tokens, line - chunk_begin + 1, mem, pos, lastnl, line, delim, quot, trim)
            if pos == 0
                break
            elseif i != ncols
                throw(ReadError("unexpected number of columns at line $(line)"))
            end
            line += 1
        end
        n_new_records = line - chunk_begin
        if n_new_records == 0
            # the buffer is too short (TODO: or no records?)
            expandbuffer!(stream)
            continue
        end

        # Parse data.
        bitmaps = aggregate_columns(tokens, n_new_records)
        if isempty(columns)
            # infer data types of columns
            resize!(columns, ncols)
            for i in 1:ncols
                T = (bitmaps[i] & INTEGER) != 0 ? Int :
                    (bitmaps[i] & FLOAT) != 0 ? Float64 :
                    (bitmaps[i] & BOOL) != 0 ? Bool : String
                if (bitmaps[i] & 0b10000) != 0
                    T = Union{T,Missing}
                end
                @debug "Filling $(colnames[i])::$(T) column"
                columns[i] = fillcolumn!(
                    Vector{T}(undef, n_new_records),
                    n_new_records, mem, tokens, i, quot)
            end
        else
            # check existing columns
            for i in 1:ncols
                col = columns[i]
                T = eltype(col)
                if T <: Union{Int,Missing}
                    (bitmaps[i] & INTEGER) == 0 && throw_typeguess_error(i)
                elseif T <: Union{Float64,Missing}
                    (bitmaps[i] & FLOAT) == 0 && throw_typeguess_error(i)
                elseif T <: Union{Bool,Missing}
                    (bitmaps[i] & BOOL) == 0 && throw_typeguess_error(i)
                else
                    @assert T <: Union{String,Missing}
                end
                if (bitmaps[i] & 0b10000) != 0 && !(T >: Union{T,Missing})
                    # copy data to a new column
                    col = copyto!(Vector{Union{T,Missing}}(undef, length(col) + n_new_records), 1, col, 1, length(col))
                else
                    # resize the column for new records
                    resize!(col, length(col) + n_new_records)
                end
                @debug "Filling $(colnames[i])::$(T) column"
                columns[i] = fillcolumn!(col, n_new_records, mem, tokens, i, quot)
            end
        end
        skip(stream, pos)
        if params.chunksize == 0
            # Without chunking, reading data must finish in a pass.
            @assert eof(stream)
        end
    end

    # Parse strings as date or datetime objects.
    for i in 1:ncols
        col = columns[i]
        if eltype(col) <: Union{String,Missing}
            if is_date_like(col)
                try
                    columns[i] = parse_date(col)
                catch
                    # not a date column
                end
            elseif is_datetime_like(col)
                try
                    columns[i] = parse_datetime(col)
                catch
                    # not a datetime column
                end
            end
        end
    end

    return DataFrame(columns, colnames)
end

function throw_typeguess_error(column::Int)
    throw(ReadError("type guessing failed at column $(column); try larger chunksize or chunksize = 0 to disable chunking"))
end

function expandbuffer!(stream::TranscodingStream)
    buffer = stream.state.buffer1
    makemargin!(buffer, length(buffer) * 2)
    return stream
end

# Count the number of lines in a memory block.
function countbytes(mem::Memory, byte::UInt8)
    n = 0
    @inbounds @simd for i in 1:length(mem)
        n += mem[i] == byte
    end
    return n
end

function aggregate_columns(tokens::Matrix{Token}, nrows::Int)
    ncols = size(tokens, 1)
    bitmaps = Vector{UInt8}(undef, ncols)
    fill!(bitmaps, 0b1111)
    @inbounds for j in 1:nrows, i in 1:ncols
        # Note that the tokens matrix is transposed.
        x = kind(tokens[i,j])
        y = bitmaps[i]
        bitmaps[i] = ((y & 0b10000) | ifelse(x == 0b1111, 0b10000, 0b00000)) | ((x & y) & 0b1111)
    end
    return bitmaps
end

# Skip the number of lines specified by `skip`.
function skiplines(stream::TranscodingStream, skip::Int)
    buffer = stream.state.buffer1
    n = skip
    while n > 0
        fillbuffer(stream, eager = true)
        mem = buffermem(buffer)
        nl = find_first_newline(mem, 1)
        if nl == 0  # no newline
            if eof(stream)
                break
            end
            # expand buffer
            makemargin!(buffer, length(buffer) * 2)
        else
            Base.skip(stream, nl)
            n -= 1
        end
    end
    return skip - n
end

function find_first_newline(mem::Memory, i::Int)
    last = lastindex(mem)
    @inbounds while i ≤ last
        x = mem[i]
        if x == CR
            if i + 1 ≤ last && mem[i+1] == LF
                i += 1
            end
            break
        elseif x == LF
            break
        end
        i += 1
    end
    if i > last
        return 0
    end
    return i
end

# Buffer lines into memory and return the memory view and the last newline
# position. The newline position is zero if no newlines are found.
function bufferlines(stream::TranscodingStream)
    # TODO: handle when a line is too long to store in the current buffer
    fillbuffer(stream, eager = true)
    buffer = stream.state.buffer1
    mem = buffermem(buffer)
    # find the last newline
    lastnl = lastindex(mem)
    while lastnl > 0
        @inbounds x = mem[lastnl]
        if x == LF
            break
        elseif x == CR
            if lastnl != lastindex(mem)
                # CR
                break
            end
            # CR or CR+LF
            makemargin!(buffer, 1)
            fillbuffer(stream, eager = true)
            mem = buffermem(buffer)
            lastnl = lastindex(mem)
            while lastnl > 0
                @inbounds x = mem[lastnl]
                if x == LF || x == CR
                    break
                end
                lastnl -= 1
            end
            break
        end
        lastnl -= 1
    end
    # TODO: Handle a situation where marginsize(buffer) == 0 and it is
    # accidentally the EOF without trailing newlines.
    if lastnl == 0 && TranscodingStreams.marginsize(buffer) > 0
        # Terminate the buffered data with LF.
        TranscodingStreams.writebyte!(buffer, LF)
        mem = buffermem(buffer)
        lastnl = lastindex(mem)
        @assert mem[lastnl] == LF
    end
    return mem, lastnl
end

# Generated from tools/snoop.jl.
function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    precompile(Tuple{typeof(TableReader.scanline!), Array{TableReader.Token, 2}, Int64, TranscodingStreams.Memory, Int64, Int64, Int64, UInt8, UInt8, Bool})
    precompile(Tuple{typeof(TableReader.scanheader), TranscodingStreams.Memory, Int64, Int64, UInt8, UInt8, Bool})
    precompile(Tuple{typeof(TableReader.checkformat), Base.IOStream})
    precompile(Tuple{typeof(TableReader.find_first_newline), TranscodingStreams.Memory, Int64})
    precompile(Tuple{typeof(TableReader.ParserParameters), Char, Char, Bool, Nothing, Int64})
    precompile(Tuple{typeof(TableReader.checkformat), TranscodingStreams.TranscodingStream{TranscodingStreams.Noop, Base.IOStream}})
    precompile(Tuple{typeof(TableReader.readdlm_internal), TranscodingStreams.TranscodingStream{TranscodingStreams.Noop, Base.IOStream}, TableReader.ParserParameters})
    precompile(Tuple{typeof(TableReader.fillcolumn!), Array{Int64, 1}, Int64, TranscodingStreams.Memory, Array{TableReader.Token, 2}, Int64, UInt8})
    precompile(Tuple{typeof(TableReader.fillcolumn!), Array{String, 1}, Int64, TranscodingStreams.Memory, Array{TableReader.Token, 2}, Int64, UInt8})
    precompile(Tuple{typeof(TableReader.qstring), TranscodingStreams.Memory, Int64, Int64, UInt8})
    precompile(Tuple{typeof(TableReader.aggregate_columns), Array{TableReader.Token, 2}, Int64})
    precompile(Tuple{typeof(TableReader.checkformat), TranscodingStreams.TranscodingStream{TranscodingStreams.Noop, Base.Process}})
    precompile(Tuple{typeof(TableReader.fillcolumn!), Array{Float64, 1}, Int64, TranscodingStreams.Memory, Array{TableReader.Token, 2}, Int64, UInt8})
    precompile(Tuple{typeof(TableReader.wrapstream), Base.IOStream, TableReader.ParserParameters})
    precompile(Tuple{typeof(TableReader.wrapstream), Base.Process, TableReader.ParserParameters})
    precompile(Tuple{typeof(TableReader.checkformat), Base.Process})
    precompile(Tuple{typeof(TableReader.readcsv), String})
    precompile(Tuple{typeof(TableReader.readtsv), String})
end
_precompile_()

end # module
