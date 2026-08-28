module FusedJSON
  # Selects how `DocumentReader` separates JSON documents in one IO.
  enum DocumentFraming
    # One complete JSON value per LF- or CRLF-terminated record.
    NDJSON

    # Complete JSON values separated by one or more JSON whitespace bytes.
    WhitespaceSeparated
  end

  # :nodoc:
  private abstract class RepeatedStreamingPullParser < StreamingPullParser
    @source_exhausted : Bool

    def initialize(input : IO, *, buffer_size : Int, max_nesting : Int, cache_keys : Bool,
                   max_token_bytes : Int?, limits : Limits,
                   enforce_dynamic_numbers : Bool)
      @source_exhausted = false
      super(
        input,
        buffer_size: buffer_size,
        max_nesting: max_nesting,
        cache_keys: cache_keys,
        max_token_bytes: max_token_bytes,
        limits: limits,
        enforce_dynamic_numbers: enforce_dynamic_numbers,
        prime: false
      )
    end

    abstract def begin_document : Bool
    abstract def finish_sequence : Nil

    protected def source_exhausted? : Bool
      @source_exhausted
    end

    protected def mark_source_exhausted : Nil
      @source_exhausted = true
    end

    protected def exhaust : Bool
      @source_exhausted = true
      false
    end
  end

  # :nodoc:
  private class NDJSONStreamingPullParser < RepeatedStreamingPullParser
    def begin_document : Bool
      return false if source_exhausted?
      return exhaust unless current_byte?

      start = current_offset
      reset_document_state
      return true if prime_reader?

      if current_offset > start
        raise_error("expected a JSON value", current_offset)
      end
      exhaust
    end

    def finish_sequence : Nil
      return if source_exhausted?
      unless kind.eof?
        raise_error("expected end of document stream", byte_offset)
      end

      if eof?
        mark_source_exhausted
        return
      end
      raise_error("expected end of document stream", current_offset)
    end

    protected def finish_root_unlimited : Nil
      finish_ndjson_record(limited: false)
    end

    protected def finish_root : Nil
      finish_ndjson_record(limited: true)
    end

    protected def skip_whitespace : Nil
      while (byte = current_byte?) && inline_whitespace?(byte)
        advance_byte
      end
    end

    protected def skip_whitespace_unlimited : Nil
      while (byte = current_byte?) && inline_whitespace?(byte)
        advance_byte_unlimited
      end
    end

    private def finish_ndjson_record(*, limited : Bool) : Nil
      limited ? skip_whitespace : skip_whitespace_unlimited

      case current_byte?
      when nil
        mark_source_exhausted
      when 0x0a_u8
        advance_byte_unlimited
      when 0x0d_u8
        carriage_return = current_offset
        advance_byte_unlimited
        unless current_byte? == 0x0a_u8
          raise_error("expected LF after CR in NDJSON", carriage_return)
        end
        advance_byte_unlimited
      else
        raise_error("unexpected trailing content", current_offset)
      end

      publish_eof
    end

    @[AlwaysInline]
    private def inline_whitespace?(byte : UInt8) : Bool
      byte == 0x20_u8 || byte == 0x09_u8
    end
  end

  # :nodoc:
  private class WhitespaceSeparatedStreamingPullParser < RepeatedStreamingPullParser
    @first_document : Bool

    def initialize(input : IO, *, buffer_size : Int, max_nesting : Int, cache_keys : Bool,
                   max_token_bytes : Int?, limits : Limits,
                   enforce_dynamic_numbers : Bool)
      @first_document = true
      super
    end

    def begin_document : Bool
      return false if source_exhausted?

      unless @first_document
        return exhaust if eof?
        unless json_whitespace?(current_byte)
          raise_error("expected JSON whitespace between documents", current_offset)
        end
      end

      reset_document_state
      unless prime_reader?
        return exhaust
      end

      @first_document = false
      true
    end

    def finish_sequence : Nil
      return if source_exhausted?
      unless kind.eof?
        raise_error("expected end of document stream", byte_offset)
      end

      if !@first_document && !eof? && !json_whitespace?(current_byte)
        raise_error("expected JSON whitespace between documents", current_offset)
      end

      reset_document_state
      skip_configured_whitespace
      unless eof?
        raise_error("expected end of document stream", current_offset)
      end
      mark_source_exhausted
    end

    protected def finish_root_unlimited : Nil
      publish_eof
    end

    protected def finish_root : Nil
      publish_eof
    end

    private def skip_configured_whitespace : Nil
      @limits_active ? skip_whitespace : skip_whitespace_unlimited
    end

    @[AlwaysInline]
    private def json_whitespace?(byte : UInt8) : Bool
      byte == 0x20_u8 || byte == 0x09_u8 || byte == 0x0a_u8 || byte == 0x0d_u8
    end
  end

  # A forward-only iterator over strict JSON documents in a caller-owned IO.
  # The reader reuses its input and token buffers and never closes the IO.
  class DocumentReader(T)
    include Iterator(T)

    getter documents_read : Int64

    @pull : RepeatedStreamingPullParser
    @tree : StreamingTreeBuilder
    @exhausted : Bool
    @failed : Bool

    # Creates a reader whose result type is inferred from *type*.
    def initialize(source : IO, type : T.class, *, framing : DocumentFraming,
                   buffer_size : Int = 32 * 1024,
                   max_nesting : Int = PullParser::MAX_NESTING,
                   cache_keys : Bool = false, max_token_bytes : Int? = nil,
                   limits : Limits = Limits::DEFAULT)
      enforce_dynamic_numbers = {{ T == JSON::Any }}
      @pull = case framing
              when .ndjson?
                NDJSONStreamingPullParser.new(
                  source,
                  buffer_size: buffer_size,
                  max_nesting: max_nesting,
                  cache_keys: cache_keys,
                  max_token_bytes: max_token_bytes,
                  limits: limits,
                  enforce_dynamic_numbers: enforce_dynamic_numbers
                )
              when .whitespace_separated?
                WhitespaceSeparatedStreamingPullParser.new(
                  source,
                  buffer_size: buffer_size,
                  max_nesting: max_nesting,
                  cache_keys: cache_keys,
                  max_token_bytes: max_token_bytes,
                  limits: limits,
                  enforce_dynamic_numbers: enforce_dynamic_numbers
                )
              else
                raise ArgumentError.new("unsupported document framing #{framing}")
              end
      @tree = StreamingTreeBuilder.new(@pull)
      @documents_read = 0_i64
      @exhausted = false
      @failed = false
    end

    # Decodes and returns the next document, or `Iterator::Stop` at clean EOF.
    def next : T | Iterator::Stop
      raise "document reader cannot be reused after an error" if @failed
      return stop if @exhausted

      begin
        unless @pull.begin_document
          @exhausted = true
          return stop
        end

        value = read_document
        @documents_read += 1
        value
      rescue error
        @failed = true
        raise error
      end
    end

    # Returns whether clean end of input has been established.
    def exhausted? : Bool
      @exhausted
    end

    # Requires that no unread documents remain. It does not drain documents.
    def finish : Nil
      raise "document reader cannot be reused after an error" if @failed
      return if @exhausted

      begin
        @pull.finish_sequence
        @exhausted = true
      rescue error
        @failed = true
        raise error
      end
    end

    private def read_document : T
      {% if T == JSON::Any %}
        @tree.read
      {% else %}
        @pull.read(T)
      {% end %}
    end
  end

  # Creates a reusable dynamic reader over framed JSON documents.
  def self.documents(source : IO, *, framing : DocumentFraming,
                     buffer_size : Int = 32 * 1024,
                     max_nesting : Int = PullParser::MAX_NESTING,
                     cache_keys : Bool = false, max_token_bytes : Int? = nil,
                     limits : Limits = Limits::DEFAULT) : DocumentReader(JSON::Any)
    DocumentReader.new(
      source,
      JSON::Any,
      framing: framing,
      buffer_size: buffer_size,
      max_nesting: max_nesting,
      cache_keys: cache_keys,
      max_token_bytes: max_token_bytes,
      limits: limits
    )
  end

  # Creates a reusable typed reader over framed JSON documents.
  def self.documents(source : IO, type : T.class, *, framing : DocumentFraming,
                     buffer_size : Int = 32 * 1024,
                     max_nesting : Int = PullParser::MAX_NESTING,
                     cache_keys : Bool = false, max_token_bytes : Int? = nil,
                     limits : Limits = Limits::DEFAULT) : DocumentReader(T) forall T
    DocumentReader.new(
      source,
      type,
      framing: framing,
      buffer_size: buffer_size,
      max_nesting: max_nesting,
      cache_keys: cache_keys,
      max_token_bytes: max_token_bytes,
      limits: limits
    )
  end
end
