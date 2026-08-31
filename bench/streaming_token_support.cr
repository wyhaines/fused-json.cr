require "json"

require "../src/fused_json"

module StreamingTokenCost
  FNV_OFFSET = 14_695_981_039_346_656_037_u64
  FNV_PRIME  =          1_099_511_628_211_u64

  PROFILES = [
    "integers",
    "floats",
    "plain-short",
    "plain-long",
    "raw-utf8",
    "escape-sparse",
    "escape-dense",
    "unicode-escape",
    "surrogate-escape",
    "key-repeated-plain",
    "key-repeated-escaped",
    "key-unique-plain",
    "key-unique-escaped",
  ]

  CONSUMERS = [
    "pull-materialize",
    "pull-skip",
    "dynamic-tree",
    "typed",
    "document-dynamic",
    "document-typed",
  ]

  TRANSPORTS = [
    "string",
    "io-memory",
    "chunked-memory",
  ]

  LIMIT_POLICIES = [
    "none",
    "token",
    "document",
    "duplicate-keys",
  ]

  record SemanticResult, values : Int64, checksum : UInt64

  record RunResult,
    semantic : SemanticResult,
    source_bytes : Int64,
    bytes_read : Int64,
    read_calls : Int64,
    closed_called : Bool

  record Fixture,
    profile : String,
    array_source : String,
    document_source : String,
    values : Int32,
    token_bytes : Int32,
    leading_padding : Int32,
    largest_token_bytes : Int32,
    largest_document_bytes : Int64,
    expected : SemanticResult

  record RunConfig,
    consumer : String,
    transport : String,
    buffer_size : Int32,
    chunks : Array(Int32),
    cache_keys : Bool,
    limit_policy : String

  private record GeneratedValue, source : String, largest_token_bytes : Int32

  struct TokenRecord
    include JSON::Serializable

    getter field : String
  end

  class CountingMemoryIO < IO
    getter bytes_read : Int64
    getter read_calls : Int64
    getter? closed_called : Bool

    @memory : IO::Memory
    @chunk_index : Int32

    def initialize(source : String, @chunks : Array(Int32) = [] of Int32)
      raise ArgumentError.new("chunk sizes must be positive") unless @chunks.all?(&.positive?)

      @memory = IO::Memory.new(source)
      @bytes_read = 0_i64
      @read_calls = 0_i64
      @closed_called = false
      @chunk_index = 0
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("read after close") if @closed_called
      raise IO::Error.new("empty read request") if slice.empty?

      target = slice
      unless @chunks.empty?
        chunk = @chunks[@chunk_index]
        @chunk_index = (@chunk_index + 1) % @chunks.size
        target = slice[0, Math.min(slice.size, chunk)]
      end
      count = @memory.read(target)
      @bytes_read += count
      @read_calls += 1
      count
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("streaming token input is read-only")
    end

    def close : Nil
      @closed_called = true
    end

    def closed? : Bool
      @closed_called
    end
  end

  extend self

  def generate(profile : String, values : Int32, token_bytes : Int32,
               leading_padding : Int32 = 0) : Fixture
    validate_profile(profile)
    raise ArgumentError.new("values must be positive") unless values > 0
    raise ArgumentError.new("token_bytes must be positive") unless token_bytes > 0
    raise ArgumentError.new("leading_padding must not be negative") unless leading_padding >= 0

    generated = Array(GeneratedValue).new(values) do |index|
      generated_value(profile, index, token_bytes)
    end
    padding = " " * leading_padding
    array_source = String.build do |io|
      io << '[' << padding
      generated.each_with_index do |value, index|
        io << ',' unless index == 0
        io << value.source
      end
      io << ']'
    end
    document_source = String.build do |io|
      generated.each_with_index do |value, index|
        io << padding if index == 0
        io << value.source << '\n'
      end
    end

    expected = semantic_from_tree(FusedJSON.load(array_source))
    largest_token_bytes = generated.max_of(&.largest_token_bytes)
    largest_document_bytes = generated.each_with_index.max_of do |value, index|
      value.source.bytesize.to_i64 + (index == 0 ? leading_padding : 0)
    end

    Fixture.new(
      profile,
      array_source,
      document_source,
      values,
      token_bytes,
      leading_padding,
      largest_token_bytes,
      largest_document_bytes,
      expected
    )
  end

  def validate_config(fixture : Fixture, config : RunConfig) : Nil
    validate_choice(config.consumer, CONSUMERS, "consumer")
    validate_choice(config.transport, TRANSPORTS, "transport")
    validate_choice(config.limit_policy, LIMIT_POLICIES, "limit policy")
    unless 0 < config.buffer_size <= FusedJSON::StreamingPullParser::MAX_BUFFER_SIZE
      raise ArgumentError.new("buffer size is outside the supported range")
    end

    validate_transport(config)
    validate_consumer(fixture, config)
  end

  private def validate_choice(value : String, choices : Array(String), label : String) : Nil
    return if choices.includes?(value)
    raise ArgumentError.new("unknown #{label} #{value.inspect}")
  end

  private def validate_transport(config : RunConfig) : Nil
    if config.transport == "chunked-memory"
      raise ArgumentError.new("chunked transport requires chunks") if config.chunks.empty?
      raise ArgumentError.new("chunk sizes must be positive") unless config.chunks.all?(&.positive?)
    elsif !config.chunks.empty?
      raise ArgumentError.new("chunks apply only to chunked transport")
    end
  end

  private def validate_consumer(fixture : Fixture, config : RunConfig) : Nil
    if document_consumer?(config.consumer) && config.transport == "string"
      raise ArgumentError.new("document consumers require an IO transport")
    end
    if typed_consumer?(config.consumer) && !typed_profile?(fixture.profile)
      raise ArgumentError.new("#{config.consumer} does not support #{fixture.profile}")
    end
  end

  def run(fixture : Fixture, config : RunConfig) : RunResult
    validate_config(fixture, config)
    case config.consumer
    when "pull-materialize"
      run_pull(fixture, config, skip: false)
    when "pull-skip"
      run_pull(fixture, config, skip: true)
    when "dynamic-tree"
      run_dynamic_tree(fixture, config)
    when "typed"
      run_typed(fixture, config)
    when "document-dynamic"
      run_dynamic_documents(fixture, config)
    when "document-typed"
      run_typed_documents(fixture, config)
    else
      raise ArgumentError.new("unknown consumer #{config.consumer.inspect}")
    end
  end

  def expected_for(fixture : Fixture, config : RunConfig) : SemanticResult
    if config.consumer == "pull-skip"
      reference = config.copy_with(transport: "string", chunks: [] of Int32)
      run(fixture, reference).semantic
    else
      fixture.expected
    end
  end

  def boundary_preflight(profile : String, consumer : String, buffer_size : Int32,
                         token_bytes : Int32, cache_keys : Bool,
                         limit_policy : String) : Nil
    fixture = generate(profile, 7, Math.min(token_bytes, 256), 3)
    reference_transport = document_consumer?(consumer) ? "io-memory" : "string"
    reference = RunConfig.new(
      consumer,
      reference_transport,
      buffer_size,
      [] of Int32,
      cache_keys,
      limit_policy
    )
    expected = run(fixture, reference).semantic
    patterns = [
      [1],
      [1, 2, 1, 7, 3, 1, 11],
      [Math.max(1, buffer_size - 1)],
      [buffer_size],
      [buffer_size + 1],
    ].uniq

    patterns.each do |chunks|
      config = reference.copy_with(transport: "chunked-memory", chunks: chunks)
      actual = run(fixture, config)
      unless actual.semantic == expected
        raise "boundary preflight mismatch for chunk pattern #{chunks}"
      end
      verify_input(actual)
    end
  end

  def document_consumer?(consumer : String) : Bool
    consumer == "document-dynamic" || consumer == "document-typed"
  end

  def typed_consumer?(consumer : String) : Bool
    consumer == "typed" || consumer == "document-typed"
  end

  def typed_profile?(profile : String) : Bool
    string_profile?(profile) || profile == "integers" || profile == "floats" ||
      profile == "key-repeated-plain" || profile == "key-repeated-escaped"
  end

  def source_for(fixture : Fixture, consumer : String) : String
    document_consumer?(consumer) ? fixture.document_source : fixture.array_source
  end

  def verify_input(result : RunResult) : Nil
    return if result.read_calls == 0
    unless result.bytes_read == result.source_bytes
      raise "streaming parser read #{result.bytes_read} of #{result.source_bytes} bytes"
    end
    raise "streaming parser closed caller-owned IO" if result.closed_called
  end

  private def run_pull(fixture : Fixture, config : RunConfig, *, skip : Bool) : RunResult
    source = fixture.array_source
    input = input_for(source, config)
    pull = pull_for(fixture, source, input, config)
    checksum = FNV_OFFSET
    values = 0_i64
    pull.read_array do
      if skip
        checksum = mix_u64(checksum, pull.byte_offset.to_u64)
        pull.skip_value
      else
        checksum = read_profile_value(pull, fixture.profile, checksum)
      end
      values += 1
    end
    pull.finish
    result_for(SemanticResult.new(values, checksum), source, input)
  end

  private def run_dynamic_tree(fixture : Fixture, config : RunConfig) : RunResult
    source = fixture.array_source
    input = input_for(source, config)
    tree = input ? FusedJSON.load(
      input,
      buffer_size: config.buffer_size,
      cache_keys: config.cache_keys,
      limits: limits_for(fixture, config)
    ) : FusedJSON.load(
      source,
      cache_keys: config.cache_keys,
      limits: limits_for(fixture, config)
    )
    result_for(semantic_from_tree(tree), source, input)
  end

  private def run_typed(fixture : Fixture, config : RunConfig) : RunResult
    source = fixture.array_source
    input = input_for(source, config)
    pull = pull_for(fixture, source, input, config)
    checksum = FNV_OFFSET
    values = 0_i64

    case fixture.profile
    when "integers"
      pull.read_array(Int64) do |value|
        checksum = mix_int(checksum, value)
        values += 1
      end
    when "floats"
      pull.read_array(Float64) do |value|
        checksum = mix_float(checksum, value)
        values += 1
      end
    when "key-repeated-plain", "key-repeated-escaped"
      pull.read_array(TokenRecord) do |record|
        checksum = mix_record(checksum, record)
        values += 1
      end
    else
      pull.read_array(String) do |value|
        checksum = mix_string_value(checksum, value)
        values += 1
      end
    end
    pull.finish
    result_for(SemanticResult.new(values, checksum), source, input)
  end

  private def run_dynamic_documents(fixture : Fixture, config : RunConfig) : RunResult
    source = fixture.document_source
    input = required_input(source, config)
    reader = FusedJSON.documents(
      input,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: config.buffer_size,
      cache_keys: config.cache_keys,
      limits: limits_for(fixture, config)
    )
    checksum = FNV_OFFSET
    values = 0_i64
    reader.each do |value|
      checksum = mix_any(checksum, value)
      values += 1
    end
    reader.finish
    result_for(SemanticResult.new(values, checksum), source, input)
  end

  private def run_typed_documents(fixture : Fixture, config : RunConfig) : RunResult
    source = fixture.document_source
    input = required_input(source, config)
    limits = limits_for(fixture, config)
    checksum = FNV_OFFSET
    values = 0_i64

    case fixture.profile
    when "integers"
      reader = FusedJSON.documents(
        input,
        Int64,
        framing: FusedJSON::DocumentFraming::NDJSON,
        buffer_size: config.buffer_size,
        cache_keys: config.cache_keys,
        limits: limits
      )
      reader.each do |value|
        checksum = mix_int(checksum, value)
        values += 1
      end
      reader.finish
    when "floats"
      reader = FusedJSON.documents(
        input,
        Float64,
        framing: FusedJSON::DocumentFraming::NDJSON,
        buffer_size: config.buffer_size,
        cache_keys: config.cache_keys,
        limits: limits
      )
      reader.each do |value|
        checksum = mix_float(checksum, value)
        values += 1
      end
      reader.finish
    when "key-repeated-plain", "key-repeated-escaped"
      reader = FusedJSON.documents(
        input,
        TokenRecord,
        framing: FusedJSON::DocumentFraming::NDJSON,
        buffer_size: config.buffer_size,
        cache_keys: config.cache_keys,
        limits: limits
      )
      reader.each do |record|
        checksum = mix_record(checksum, record)
        values += 1
      end
      reader.finish
    else
      reader = FusedJSON.documents(
        input,
        String,
        framing: FusedJSON::DocumentFraming::NDJSON,
        buffer_size: config.buffer_size,
        cache_keys: config.cache_keys,
        limits: limits
      )
      reader.each do |value|
        checksum = mix_string_value(checksum, value)
        values += 1
      end
      reader.finish
    end
    result_for(SemanticResult.new(values, checksum), source, input)
  end

  private def input_for(source : String, config : RunConfig) : CountingMemoryIO?
    case config.transport
    when "string"
      nil
    when "io-memory"
      CountingMemoryIO.new(source)
    when "chunked-memory"
      CountingMemoryIO.new(source, config.chunks)
    else
      raise ArgumentError.new("unknown transport #{config.transport.inspect}")
    end
  end

  private def required_input(source : String, config : RunConfig) : CountingMemoryIO
    input_for(source, config) || raise ArgumentError.new("document readers require IO")
  end

  private def pull_for(fixture : Fixture, source : String, input : CountingMemoryIO?,
                       config : RunConfig) : FusedJSON::PullParser
    if input
      FusedJSON::PullParser.new(
        input,
        buffer_size: config.buffer_size,
        cache_keys: config.cache_keys,
        limits: limits_for(fixture, config)
      )
    else
      FusedJSON::PullParser.new(
        source,
        cache_keys: config.cache_keys,
        limits: limits_for(fixture, config)
      )
    end
  end

  private def limits_for(fixture : Fixture, config : RunConfig) : FusedJSON::Limits
    case config.limit_policy
    when "none"
      FusedJSON::Limits::DEFAULT
    when "token"
      FusedJSON::Limits.new(max_token_bytes: fixture.largest_token_bytes)
    when "document"
      maximum = document_consumer?(config.consumer) ? fixture.largest_document_bytes : source_for(fixture, config.consumer).bytesize.to_i64
      FusedJSON::Limits.new(max_document_bytes: maximum)
    when "duplicate-keys"
      FusedJSON::Limits.new(reject_duplicate_keys: true)
    else
      raise ArgumentError.new("unknown limit policy #{config.limit_policy.inspect}")
    end
  end

  private def result_for(semantic : SemanticResult, source : String,
                         input : CountingMemoryIO?) : RunResult
    result = if input
               RunResult.new(
                 semantic,
                 source.bytesize.to_i64,
                 input.bytes_read,
                 input.read_calls,
                 input.closed_called?
               )
             else
               RunResult.new(semantic, source.bytesize.to_i64, 0_i64, 0_i64, false)
             end
    verify_input(result)
    result
  end

  private def read_profile_value(pull : FusedJSON::PullParser, profile : String,
                                 checksum : UInt64) : UInt64
    case profile
    when "integers"
      mix_int(checksum, pull.read_int)
    when "floats"
      mix_float(checksum, pull.read_float)
    when "key-repeated-plain", "key-repeated-escaped", "key-unique-plain", "key-unique-escaped"
      value = mix_u64(mix_byte(checksum, 7_u8), 1_u64)
      entries = 0
      pull.read_object do |key|
        value = mix_string(value, key)
        value = mix_string_value(value, pull.read_string)
        entries += 1
      end
      raise "generated object must contain one entry" unless entries == 1
      value
    else
      mix_string_value(checksum, pull.read_string)
    end
  end

  private def semantic_from_tree(tree : JSON::Any) : SemanticResult
    values = tree.as_a
    checksum = FNV_OFFSET
    values.each { |value| checksum = mix_any(checksum, value) }
    SemanticResult.new(values.size.to_i64, checksum)
  end

  private def mix_any(checksum : UInt64, value : JSON::Any) : UInt64
    case raw = value.raw
    when Nil
      mix_byte(checksum, 0_u8)
    when Bool
      mix_byte(checksum, raw ? 2_u8 : 1_u8)
    when Int64
      mix_int(checksum, raw)
    when Float64
      mix_float(checksum, raw)
    when String
      mix_string_value(checksum, raw)
    when Array(JSON::Any)
      mixed = mix_u64(mix_byte(checksum, 6_u8), raw.size.to_u64)
      raw.each { |item| mixed = mix_any(mixed, item) }
      mixed
    when Hash(String, JSON::Any)
      mixed = mix_u64(mix_byte(checksum, 7_u8), raw.size.to_u64)
      raw.each do |key, item|
        mixed = mix_string(mixed, key)
        mixed = mix_any(mixed, item)
      end
      mixed
    else
      raise "unknown JSON::Any value #{raw.class}"
    end
  end

  private def mix_record(checksum : UInt64, record : TokenRecord) : UInt64
    value = mix_u64(mix_byte(checksum, 7_u8), 1_u64)
    value = mix_string(value, "field")
    mix_string_value(value, record.field)
  end

  private def mix_string_value(checksum : UInt64, string : String) : UInt64
    mix_string(mix_byte(checksum, 5_u8), string)
  end

  private def mix_int(checksum : UInt64, value : Int64) : UInt64
    mix_u64(mix_byte(checksum, 3_u8), value.unsafe_as(UInt64))
  end

  private def mix_float(checksum : UInt64, value : Float64) : UInt64
    mix_u64(mix_byte(checksum, 4_u8), value.unsafe_as(UInt64))
  end

  # Sampling keeps the benchmark from spending more time hashing long decoded
  # strings than parsing them. Full decoding parity belongs to the specs and the
  # one-time tree preflight performed by `generate`.
  private def mix_string(checksum : UInt64, string : String) : UInt64
    bytes = string.to_slice
    value = mix_u64(checksum, bytes.size.to_u64)
    return value if bytes.empty?

    indexes = [
      0,
      Math.min(1, bytes.size - 1),
      bytes.size // 4,
      bytes.size // 2,
      (bytes.size * 3) // 4,
      Math.max(0, bytes.size - 2),
      bytes.size - 1,
    ].uniq
    indexes.each { |index| value = mix_byte(value, bytes[index]) }
    value
  end

  private def mix_u64(checksum : UInt64, integer : UInt64) : UInt64
    value = checksum
    8.times do |index|
      value = mix_byte(value, ((integer >> (index * 8)) & 0xff_u64).to_u8)
    end
    value
  end

  private def mix_byte(checksum : UInt64, byte : UInt8) : UInt64
    (checksum ^ byte.to_u64) &* FNV_PRIME
  end

  private def generated_value(profile : String, index : Int32,
                              token_bytes : Int32) : GeneratedValue
    if profile == "integers" || profile == "floats"
      scalar_generated_value(profile, index)
    elsif string_profile?(profile)
      string_generated_value(profile, index, token_bytes)
    else
      object_generated_value(profile, index, token_bytes)
    end
  end

  private def scalar_generated_value(profile : String, index : Int32) : GeneratedValue
    case profile
    when "integers"
      source = (1_000_000_000_000_000_i64 + index).to_s
      GeneratedValue.new(source, source.bytesize)
    when "floats"
      source = "#{1_000_000 + index}.125e-3"
      GeneratedValue.new(source, source.bytesize)
    else
      raise ArgumentError.new("unknown scalar profile #{profile.inspect}")
    end
  end

  private def string_generated_value(profile : String, index : Int32,
                                     token_bytes : Int32) : GeneratedValue
    case profile
    when "plain-short"
      string_value("short-#{index % 1024}")
    when "plain-long"
      string_value(ascii_value("plain-", token_bytes, index))
    when "raw-utf8"
      string_value(unit_value("λ𝄞x", token_bytes, index))
    when "escape-sparse"
      string_value(unit_value("plain-segment-0123456789\n\t\"\\λ𝄞/", token_bytes, index))
    when "escape-dense"
      string_value(unit_value("\n\t\"\\/λ", token_bytes, index))
    when "unicode-escape"
      escaped_codepoint_value("\\u03bb", token_bytes, index)
    when "surrogate-escape"
      escaped_codepoint_value("\\ud834\\udd1e", token_bytes, index)
    else
      raise ArgumentError.new("unknown string profile #{profile.inspect}")
    end
  end

  private def object_generated_value(profile : String, index : Int32,
                                     token_bytes : Int32) : GeneratedValue
    case profile
    when "key-repeated-plain"
      object_value(%("field"), token_bytes, index)
    when "key-repeated-escaped"
      object_value(%("\\u0066ield"), token_bytes, index)
    when "key-unique-plain"
      object_value(%("field#{index}"), token_bytes, index)
    when "key-unique-escaped"
      object_value(%("\\u0066ield#{index}"), token_bytes, index)
    else
      raise ArgumentError.new("unknown object profile #{profile.inspect}")
    end
  end

  private def string_value(value : String) : GeneratedValue
    source = value.to_json
    GeneratedValue.new(source, source.bytesize)
  end

  private def object_value(key : String, token_bytes : Int32,
                           index : Int32) : GeneratedValue
    value = ascii_value("value-", Math.max(16, token_bytes), index).to_json
    source = "{#{key}:#{value}}"
    GeneratedValue.new(source, Math.max(key.bytesize, value.bytesize))
  end

  private def ascii_value(prefix : String, target_bytes : Int32, index : Int32) : String
    suffix = "-#{index}"
    target = Math.max(target_bytes, prefix.bytesize + suffix.bytesize)
    prefix + ("x" * (target - prefix.bytesize - suffix.bytesize)) + suffix
  end

  private def unit_value(unit : String, target_bytes : Int32, index : Int32) : String
    suffix = "-#{index}"
    target = Math.max(target_bytes, suffix.bytesize)
    available = target - suffix.bytesize
    repeats = available // unit.bytesize
    remainder = available - repeats * unit.bytesize
    (unit * repeats) + ("x" * remainder) + suffix
  end

  private def escaped_codepoint_value(unit : String, target_bytes : Int32,
                                      index : Int32) : GeneratedValue
    suffix = "-#{index}"
    content_target = Math.max(target_bytes - 2, unit.bytesize + suffix.bytesize)
    available = content_target - suffix.bytesize
    repeats = Math.max(1, available // unit.bytesize)
    remainder = Math.max(0, available - repeats * unit.bytesize)
    source = %("#{unit * repeats}#{"x" * remainder}#{suffix}")
    GeneratedValue.new(source, source.bytesize)
  end

  private def string_profile?(profile : String) : Bool
    case profile
    when "plain-short", "plain-long", "raw-utf8", "escape-sparse", "escape-dense",
         "unicode-escape", "surrogate-escape"
      true
    else
      false
    end
  end

  private def validate_profile(profile : String) : Nil
    return if PROFILES.includes?(profile)
    raise ArgumentError.new("unknown profile #{profile.inspect}")
  end
end
