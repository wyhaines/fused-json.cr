module StreamSpecSupport
  # A deliberately awkward read-only IO for exercising streaming parsers.
  # It can impose source boundaries, return short reads, inject a premature
  # zero-length read, and fail on a selected read call.
  class ChunkedIO < IO
    getter read_calls : Int32
    getter bytes_read : Int32
    getter position : Int32
    getter closed_called : Bool

    @source : String
    @bytes : Bytes
    @cuts : Array(Int32)
    @cut_index : Int32
    @max_chunk : Int32
    @fail_on_read : Int32?
    @zero_on_read : Int32?
    @read_budget : Int32?

    def initialize(
      @source : String,
      *,
      chunks : Array(Int32) = [] of Int32,
      max_chunk : Int32 = Int32::MAX,
      @fail_on_read : Int32? = nil,
      @zero_on_read : Int32? = nil,
      @read_budget : Int32? = nil,
    )
      raise ArgumentError.new("max_chunk must be positive") unless max_chunk > 0

      @bytes = @source.to_slice
      @cuts = [] of Int32
      @cut_index = 0
      @max_chunk = max_chunk
      @read_calls = 0
      @bytes_read = 0
      @position = 0
      @closed_called = false

      cumulative = 0_i64
      chunks.each do |size|
        raise ArgumentError.new("chunk sizes must be positive") unless size > 0
        cumulative += size
        if cumulative > @bytes.size
          raise ArgumentError.new("chunk sizes exceed the source length")
        end
        @cuts << cumulative.to_i32
      end
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("read after close") if @closed_called
      raise IO::Error.new("empty read request") if slice.empty?

      @read_calls += 1
      if (budget = @read_budget) && @read_calls > budget
        raise IO::Error.new("read budget exceeded")
      end

      # Bytes outside the returned count are intentionally not trustworthy.
      # A parser must only consume the prefix reported by #read.
      slice.fill(0xa5_u8)

      if @fail_on_read == @read_calls
        raise IO::Error.new("injected read failure")
      end
      return 0 if @zero_on_read == @read_calls
      return 0 if @position >= @bytes.size

      while (cut = @cuts[@cut_index]?) && cut <= @position
        @cut_index += 1
      end

      count = Math.min(slice.size, @max_chunk)
      count = Math.min(count, @bytes.size - @position)
      if cut = @cuts[@cut_index]?
        count = Math.min(count, cut - @position)
      end

      slice[0, count].copy_from(@bytes[@position, count])
      @position += count
      @bytes_read += count
      count
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("ChunkedIO is read-only")
    end

    def close : Nil
      @closed_called = true
    end

    def closed? : Bool
      @closed_called
    end
  end

  # A deliberately invalid IO for exercising defensive read-count checks.
  class InvalidReadCountIO < IO
    getter read_calls : Int32

    def initialize(@count : Int32)
      @read_calls = 0
    end

    def read(slice : Bytes) : Int32
      @read_calls += 1
      @count
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("InvalidReadCountIO is read-only")
    end
  end
end
