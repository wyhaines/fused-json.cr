require "benchmark"

require "./tic_workload"

module TypedCursorCost
  record Result, count : Int64, checksum : UInt64
  alias Operation = Tuple(String, Proc(Result))

  struct EmptyRecord
    include JSON::Serializable

    def initialize
    end
  end

  struct IntRecord
    include JSON::Serializable

    getter value : Int64

    def initialize(@value : Int64)
    end
  end

  struct StringRecord
    include JSON::Serializable

    getter value : String

    def initialize(@value : String)
    end
  end

  struct NestedLeaf
    include JSON::Serializable

    getter name : String

    def initialize(@name : String)
    end
  end

  struct NestedRecord
    include JSON::Serializable

    getter id : Int64
    getter leaf : NestedLeaf
    getter values : Array(Int64)

    def initialize(@id : Int64, @leaf : NestedLeaf, @values : Array(Int64))
    end
  end

  struct KeyProbeRecord
    include JSON::Serializable

    getter value : Int64

    def initialize(@value : Int64)
    end
  end

  class Sink
    @@result = Result.new(0_i64, 0_u64)

    def self.store(result : Result) : Nil
      @@result = result
    end

    def self.verify(expected : Result) : Nil
      raise "benchmark result was lost" unless @@result == expected
    end
  end

  extend self

  def scalar_source(count : Int32) : String
    String.build do |io|
      io << '['
      count.times do |index|
        io << ',' unless index == 0
        io << 10_000_000 + index
      end
      io << ']'
    end
  end

  def empty_source(count : Int32) : String
    repeated_source(count) { |_, io| io << "{}" }
  end

  def int_source(count : Int32) : String
    repeated_source(count) do |index, io|
      io << %({"value":) << index << '}'
    end
  end

  def string_source(count : Int32) : String
    repeated_source(count) do |index, io|
      io << %({"value":")
      io << (index.even? ? "repeated-alpha" : "repeated-beta")
      io << %("})
    end
  end

  def nested_source(count : Int32) : String
    repeated_source(count) do |index, io|
      io << %({"id":) << index
      io << %(,"leaf":{"name":"leaf-) << index % 8
      io << %("},"values":[) << index << ',' << index + 1 << ',' << index + 2
      io << "]}"
    end
  end

  def key_probe_source(count : Int32, cardinality : Int32) : String
    repeated_source(count) do |index, io|
      io << %({"value":) << index << %(,"extra_)
      io << index % cardinality << %(":) << index << '}'
    end
  end

  def decoded_equivalent_key_source(count : Int32) : String
    repeated_source(count) do |index, io|
      if index.even?
        io << %({"value":) << index << %(,"λ":true})
      else
        io << %q({"\u0076alue":) << index << %q(,"\u03bb":true})
      end
    end
  end

  def price_source(count : Int32) : String
    String.build do |io|
      io << '['
      count.times do |index|
        io << ',' unless index == 0
        io << %({"negotiated_type":"negotiated","negotiated_rate":)
        io << 100 + index % 10_000 << ".25"
        io << %(,"expiration_date":"2027-12-31","billing_class":")
        io << (index.even? ? "professional" : "institutional")
        io << %(","service_code":["01"]})
      end
      io << ']'
    end
  end

  private def repeated_source(count : Int32, &) : String
    String.build do |io|
      io << '['
      count.times do |index|
        io << ',' unless index == 0
        yield index, io
      end
      io << ']'
    end
  end

  def scalar_native_string(source : String) : Result
    scalar_native(in_memory_pull(source, cache_keys: false))
  end

  def scalar_read_string(source : String) : Result
    scalar_read(in_memory_pull(source, cache_keys: false))
  end

  def scalar_read_array_string(source : String) : Result
    scalar_read_array(in_memory_pull(source, cache_keys: false))
  end

  def scalar_native_stream(source : String, buffer_size : Int32) : Result
    scalar_native(streaming_pull(source, buffer_size, cache_keys: false))
  end

  def scalar_read_stream(source : String, buffer_size : Int32) : Result
    scalar_read(streaming_pull(source, buffer_size, cache_keys: false))
  end

  def scalar_read_array_stream(source : String, buffer_size : Int32) : Result
    scalar_read_array(streaming_pull(source, buffer_size, cache_keys: false))
  end

  def price_native_string(source : String, cache_keys : Bool,
                          limits : FusedJSON::Limits = FusedJSON::Limits::DEFAULT) : Result
    price_native(in_memory_pull(source, cache_keys: cache_keys, limits: limits))
  end

  def price_read_string(source : String, cache_keys : Bool,
                        limits : FusedJSON::Limits = FusedJSON::Limits::DEFAULT) : Result
    price_read(in_memory_pull(source, cache_keys: cache_keys, limits: limits))
  end

  def price_read_array_string(source : String, cache_keys : Bool,
                              limits : FusedJSON::Limits = FusedJSON::Limits::DEFAULT) : Result
    price_read_array(in_memory_pull(source, cache_keys: cache_keys, limits: limits))
  end

  def price_native_stream(source : String, buffer_size : Int32,
                          cache_keys : Bool,
                          limits : FusedJSON::Limits = FusedJSON::Limits::DEFAULT) : Result
    price_native(streaming_pull(source, buffer_size, cache_keys: cache_keys, limits: limits))
  end

  def price_read_stream(source : String, buffer_size : Int32,
                        cache_keys : Bool,
                        limits : FusedJSON::Limits = FusedJSON::Limits::DEFAULT) : Result
    price_read(streaming_pull(source, buffer_size, cache_keys: cache_keys, limits: limits))
  end

  def price_read_array_stream(source : String, buffer_size : Int32,
                              cache_keys : Bool,
                              limits : FusedJSON::Limits = FusedJSON::Limits::DEFAULT) : Result
    price_read_array(streaming_pull(source, buffer_size, cache_keys: cache_keys, limits: limits))
  end

  def record_native_string(source : String, type : T.class, cache_keys : Bool,
                           limits : FusedJSON::Limits = FusedJSON::Limits::DEFAULT) : Result forall T
    record_native(in_memory_pull(source, cache_keys: cache_keys, limits: limits), type)
  end

  def record_read_string(source : String, type : T.class, cache_keys : Bool,
                         limits : FusedJSON::Limits = FusedJSON::Limits::DEFAULT) : Result forall T
    record_read(in_memory_pull(source, cache_keys: cache_keys, limits: limits), type)
  end

  def record_read_array_string(source : String, type : T.class, cache_keys : Bool,
                               limits : FusedJSON::Limits = FusedJSON::Limits::DEFAULT) : Result forall T
    record_read_array(in_memory_pull(source, cache_keys: cache_keys, limits: limits), type)
  end

  def record_native_stream(source : String, buffer_size : Int32, type : T.class,
                           cache_keys : Bool,
                           limits : FusedJSON::Limits = FusedJSON::Limits::DEFAULT) : Result forall T
    record_native(streaming_pull(source, buffer_size, cache_keys: cache_keys, limits: limits), type)
  end

  def record_read_stream(source : String, buffer_size : Int32, type : T.class,
                         cache_keys : Bool,
                         limits : FusedJSON::Limits = FusedJSON::Limits::DEFAULT) : Result forall T
    record_read(streaming_pull(source, buffer_size, cache_keys: cache_keys, limits: limits), type)
  end

  def record_read_array_stream(source : String, buffer_size : Int32, type : T.class,
                               cache_keys : Bool,
                               limits : FusedJSON::Limits = FusedJSON::Limits::DEFAULT) : Result forall T
    record_read_array(streaming_pull(source, buffer_size, cache_keys: cache_keys, limits: limits), type)
  end

  private def scalar_native(pull : P) : Result forall P
    count = 0_i64
    checksum = TICBench::FNV_OFFSET
    pull.read_array do
      checksum = mix_i64(checksum, pull.read_int)
      count += 1
    end
    pull.finish
    Result.new(count, checksum)
  end

  private def scalar_read(pull : P) : Result forall P
    count = 0_i64
    checksum = TICBench::FNV_OFFSET
    pull.read_begin_array
    until pull.kind.end_array?
      checksum = mix_i64(checksum, pull.read(Int64))
      count += 1
    end
    pull.read_end_array
    pull.finish
    Result.new(count, checksum)
  end

  private def scalar_read_array(pull : P) : Result forall P
    count = 0_i64
    checksum = TICBench::FNV_OFFSET
    pull.read_array(Int64) do |value|
      checksum = mix_i64(checksum, value)
      count += 1
    end
    pull.finish
    Result.new(count, checksum)
  end

  private def record_native(pull : P, type : T.class) : Result forall P, T
    count = 0_i64
    checksum = TICBench::FNV_OFFSET
    pull.read_array do
      checksum = mix_record(checksum, read_native_record(pull, type))
      count += 1
    end
    pull.finish
    Result.new(count, checksum)
  end

  private def record_read(pull : P, type : T.class) : Result forall P, T
    count = 0_i64
    checksum = TICBench::FNV_OFFSET
    pull.read_begin_array
    until pull.kind.end_array?
      checksum = mix_record(checksum, pull.read(type))
      count += 1
    end
    pull.read_end_array
    pull.finish
    Result.new(count, checksum)
  end

  private def record_read_array(pull : P, type : T.class) : Result forall P, T
    count = 0_i64
    checksum = TICBench::FNV_OFFSET
    pull.read_array(type) do |value|
      checksum = mix_record(checksum, value)
      count += 1
    end
    pull.finish
    Result.new(count, checksum)
  end

  private def price_native(pull : P) : Result forall P
    count = 0_i64
    checksum = TICBench::FNV_OFFSET
    pull.read_array do
      checksum = mix_price(checksum, read_native_price(pull))
      count += 1
    end
    pull.finish
    Result.new(count, checksum)
  end

  private def price_read(pull : P) : Result forall P
    count = 0_i64
    checksum = TICBench::FNV_OFFSET
    pull.read_begin_array
    until pull.kind.end_array?
      checksum = mix_price(checksum, pull.read(TICBench::TypedNegotiatedPrice))
      count += 1
    end
    pull.read_end_array
    pull.finish
    Result.new(count, checksum)
  end

  private def price_read_array(pull : P) : Result forall P
    count = 0_i64
    checksum = TICBench::FNV_OFFSET
    pull.read_array(TICBench::TypedNegotiatedPrice) do |price|
      checksum = mix_price(checksum, price)
      count += 1
    end
    pull.finish
    Result.new(count, checksum)
  end

  def run_shape(name : String, source : String, elements : Int32,
                operations : Array(Operation), warmup : Time::Span,
                calculation : Time::Span, allocation_iterations : Int32,
                reverse_order : Bool, unique_keys : Int32? = nil) : Nil
    expected = operations.first[1].call
    operations.each do |label, operation|
      result = operation.call
      unless result == expected && result.count == elements
        raise "#{name} semantic mismatch for #{label}"
      end
    end
    Sink.store(expected)

    ordered = reverse_order ? operations.reverse : operations
    job = Benchmark::IPS::Job.new(calculation, warmup, false)
    ordered.each do |label, operation|
      job.report(label) { Sink.store(operation.call) }
    end
    job.execute

    puts
    puts "#{name}: #{elements} elements, #{source.bytesize} source bytes"
    puts "  Unique decoded keys: #{unique_keys}" if unique_keys
    puts "  Time per element"
    job.items.each do |item|
      nanoseconds = 1_000_000_000.0 / item.mean / elements
      printf "    %-16s %10.2f ns/element  (RSD %5.2f%%)\n",
        item.label, nanoseconds, item.relative_stddev
    end

    puts "  Managed allocation per element"
    allocations = {} of String => Float64
    operations.each do |label, operation|
      GC.collect
      bytes = Benchmark.memory do
        allocation_iterations.times { Sink.store(operation.call) }
      end
      per_element = bytes.to_f / allocation_iterations / elements
      allocations[label] = per_element
      printf "    %-16s %10.2f B/element\n", label, per_element
    end
    native = allocations["native cursor"]
    {"read(T) loop", "read_array(T)"}.each do |label|
      printf "    %-16s %+10.2f B/element vs native\n",
        "#{label} delta", allocations[label] - native
    end
    Sink.verify(expected)
  end

  def run_record_profile(name : String, source : String, elements : Int32,
                         unique_keys : Int32, type : T.class, buffer_size : Int32,
                         warmup : Time::Span, calculation : Time::Span,
                         allocation_iterations : Int32, reverse_order : Bool) : Nil forall T
    cache_profiles = [
      {"uncached keys", false, FusedJSON::Limits::DEFAULT},
      {"cached keys", true, FusedJSON::Limits::DEFAULT},
      {
        "cached keys / max_cached_keys=#{unique_keys}",
        true,
        FusedJSON::Limits.new(max_cached_keys: unique_keys),
      },
    ]

    cache_profiles.each do |cache_label, cache_keys, limits|
      run_shape(
        "#{name} / String / #{cache_label}",
        source,
        elements,
        [
          {"native cursor", -> { record_native_string(source, type, cache_keys, limits) }},
          {"read(T) loop", -> { record_read_string(source, type, cache_keys, limits) }},
          {"read_array(T)", -> { record_read_array_string(source, type, cache_keys, limits) }},
        ] of Operation,
        warmup,
        calculation,
        allocation_iterations,
        reverse_order,
        unique_keys
      )
      run_shape(
        "#{name} / streaming IO::Memory / #{cache_label}",
        source,
        elements,
        [
          {"native cursor", -> { record_native_stream(source, buffer_size, type, cache_keys, limits) }},
          {"read(T) loop", -> { record_read_stream(source, buffer_size, type, cache_keys, limits) }},
          {"read_array(T)", -> { record_read_array_stream(source, buffer_size, type, cache_keys, limits) }},
        ] of Operation,
        warmup,
        calculation,
        allocation_iterations,
        reverse_order,
        unique_keys
      )
    end

    verify_cache_limit_failures(source, type, buffer_size, unique_keys) if unique_keys > 0
  end

  private def in_memory_pull(source : String, *, cache_keys : Bool,
                             limits : FusedJSON::Limits = FusedJSON::Limits::DEFAULT)
    FusedJSON::PullParser.new(
      source,
      max_nesting: 512,
      cache_keys: cache_keys,
      limits: limits
    )
  end

  private def streaming_pull(source : String, buffer_size : Int32, *, cache_keys : Bool,
                             limits : FusedJSON::Limits = FusedJSON::Limits::DEFAULT)
    FusedJSON::PullParser.new(
      IO::Memory.new(source),
      buffer_size: buffer_size,
      max_nesting: 512,
      cache_keys: cache_keys,
      limits: limits
    )
  end

  private def verify_cache_limit_failures(source : String, type : T.class,
                                          buffer_size : Int32,
                                          unique_keys : Int32) : Nil forall T
    [0, unique_keys - 1].uniq.each do |limit|
      limits = FusedJSON::Limits.new(max_cached_keys: limit)
      operations = [
        -> { record_read_array_string(source, type, true, limits) },
        -> { record_read_array_stream(source, buffer_size, type, true, limits) },
      ]
      operations.each do |operation|
        begin
          operation.call
          raise "max_cached_keys=#{limit} unexpectedly accepted #{unique_keys} decoded keys"
        rescue error : FusedJSON::ParseError
          unless error.message.try(&.includes?(%Q(max_cached_keys of #{limit})))
            raise "unexpected max_cached_keys=#{limit} error: #{error.message}"
          end
        end
      end
    end
  end

  private def read_native_record(pull : P, _type : EmptyRecord.class) : EmptyRecord forall P
    pull.read_object { |_| pull.skip }
    EmptyRecord.new
  end

  private def read_native_record(pull : P, _type : IntRecord.class) : IntRecord forall P
    value = nil.as(Int64?)
    pull.read_object do |key|
      if key == "value"
        value = pull.read_int
      else
        pull.skip
      end
    end
    IntRecord.new(value || raise("missing value"))
  end

  private def read_native_record(pull : P, _type : StringRecord.class) : StringRecord forall P
    value = nil.as(String?)
    pull.read_object do |key|
      if key == "value"
        value = pull.read_string
      else
        pull.skip
      end
    end
    StringRecord.new(value || raise("missing value"))
  end

  private def read_native_record(pull : P, _type : NestedRecord.class) : NestedRecord forall P
    id = nil.as(Int64?)
    leaf = nil.as(NestedLeaf?)
    values = nil.as(Array(Int64)?)
    pull.read_object do |key|
      case key
      when "id"
        id = pull.read_int
      when "leaf"
        name = nil.as(String?)
        pull.read_object do |leaf_key|
          if leaf_key == "name"
            name = pull.read_string
          else
            pull.skip
          end
        end
        leaf = NestedLeaf.new(name || raise("missing leaf name"))
      when "values"
        items = [] of Int64
        pull.read_array { items << pull.read_int }
        values = items
      else
        pull.skip
      end
    end
    NestedRecord.new(
      id || raise("missing id"),
      leaf || raise("missing leaf"),
      values || raise("missing values")
    )
  end

  private def read_native_record(pull : P, _type : KeyProbeRecord.class) : KeyProbeRecord forall P
    value = nil.as(Int64?)
    pull.read_object do |key|
      if key == "value"
        value = pull.read_int
      else
        pull.skip
      end
    end
    KeyProbeRecord.new(value || raise("missing value"))
  end

  private def read_native_record(pull : P,
                                 _type : TICBench::TypedNegotiatedPrice.class) : TICBench::TypedNegotiatedPrice forall P
    read_native_price(pull)
  end

  private def mix_record(value : UInt64, _record : EmptyRecord) : UInt64
    mix_i64(value, 0)
  end

  private def mix_record(value : UInt64, record : IntRecord) : UInt64
    mix_i64(value, record.value)
  end

  private def mix_record(value : UInt64, record : StringRecord) : UInt64
    mix_string(value, record.value)
  end

  private def mix_record(value : UInt64, record : NestedRecord) : UInt64
    checksum = mix_i64(value, record.id)
    checksum = mix_string(checksum, record.leaf.name)
    checksum = mix_i64(checksum, record.values.size)
    record.values.each { |item| checksum = mix_i64(checksum, item) }
    checksum
  end

  private def mix_record(value : UInt64, record : KeyProbeRecord) : UInt64
    mix_i64(value, record.value)
  end

  private def mix_record(value : UInt64,
                         record : TICBench::TypedNegotiatedPrice) : UInt64
    mix_price(value, record)
  end

  private def read_native_price(pull : FusedJSON::PullParser) : TICBench::TypedNegotiatedPrice
    negotiated_type = nil.as(String?)
    negotiated_rate = nil.as(Float64?)
    expiration_date = nil.as(String?)
    billing_class = nil.as(String?)
    service_code = nil.as(Array(String)?)

    pull.read_object do |key|
      case key
      when "negotiated_type"
        negotiated_type = pull.read_string
      when "negotiated_rate"
        negotiated_rate = pull.read_float
      when "expiration_date"
        expiration_date = pull.read_string
      when "billing_class"
        billing_class = pull.read_string
      when "service_code"
        codes = [] of String
        pull.read_array { codes << pull.read_string }
        service_code = codes
      else
        pull.skip
      end
    end

    TICBench::TypedNegotiatedPrice.new(
      negotiated_type || raise("missing negotiated_type"),
      negotiated_rate || raise("missing negotiated_rate"),
      expiration_date || raise("missing expiration_date"),
      billing_class || raise("missing billing_class"),
      service_code || raise("missing service_code")
    )
  end

  private def mix_price(value : UInt64,
                        price : TICBench::TypedNegotiatedPrice) : UInt64
    checksum = mix_string(value, price.negotiated_type)
    checksum = mix_u64(checksum, price.negotiated_rate.unsafe_as(UInt64))
    checksum = mix_string(checksum, price.expiration_date)
    checksum = mix_string(checksum, price.billing_class)
    checksum = mix_i64(checksum, price.service_code.size)
    price.service_code.each { |code| checksum = mix_string(checksum, code) }
    checksum
  end

  private def mix_string(value : UInt64, string : String) : UInt64
    checksum = mix_u64(value, string.bytesize.to_u64)
    string.each_byte { |byte| checksum = mix_byte(checksum, byte) }
    checksum
  end

  private def mix_i64(value : UInt64, integer : Int) : UInt64
    mix_u64(value, integer.to_i64.unsafe_as(UInt64))
  end

  private def mix_u64(value : UInt64, integer : UInt64) : UInt64
    checksum = value
    8.times do |index|
      checksum = mix_byte(checksum, ((integer >> (index * 8)) & 0xff_u64).to_u8)
    end
    checksum
  end

  private def mix_byte(value : UInt64, byte : UInt8) : UInt64
    (value ^ byte) &* TICBench::FNV_PRIME
  end
end

{% unless flag?(:release) %}
  abort "build this benchmark with --release --no-debug"
{% end %}

commit = ENV["FUSED_JSON_BENCH_COMMIT"]? || abort "FUSED_JSON_BENCH_COMMIT is required"
unless commit.matches?(/\A[0-9a-f]{40}\z/)
  abort "FUSED_JSON_BENCH_COMMIT must be a full 40-character commit SHA"
end

scalar_count = (ENV["FUSED_JSON_CURSOR_SCALARS"]? || "10000").to_i
record_count = (ENV["FUSED_JSON_CURSOR_RECORDS"]? || "2000").to_i
partial_key_cardinality = (ENV["FUSED_JSON_CURSOR_PARTIAL_KEYS"]? || "16").to_i
buffer_size = (ENV["FUSED_JSON_CURSOR_BUFFER"]? || "16384").to_i
warmup = (ENV["FUSED_JSON_BENCH_WARMUP"]? || "1").to_f.seconds
calculation = (ENV["FUSED_JSON_BENCH_TIME"]? || "3").to_f.seconds
allocation_iterations = (ENV["FUSED_JSON_BENCH_ALLOCATIONS"]? || "20").to_i
reverse_order = ENV["FUSED_JSON_BENCH_REVERSE"]? == "1"
valid_shape_names = [
  "scalar",
  "empty",
  "integer",
  "string",
  "nested",
  "price",
  "partial-keys",
  "unique-keys",
  "equivalent-keys",
]
shape_setting = ENV["FUSED_JSON_CURSOR_SHAPES"]? || "all"
selected_shapes = shape_setting == "all" ? [] of String : shape_setting.split(',').map(&.strip)
if selected_shapes.empty? && shape_setting != "all"
  abort "FUSED_JSON_CURSOR_SHAPES must be 'all' or a comma-separated shape list"
end
if invalid_shape = selected_shapes.find { |name| !valid_shape_names.includes?(name) }
  abort "unknown cursor shape #{invalid_shape.inspect}; expected #{valid_shape_names.join(", ")}"
end
run_shape = ->(name : String) { selected_shapes.empty? || selected_shapes.includes?(name) }

abort "FUSED_JSON_CURSOR_SCALARS must be positive" unless scalar_count > 0
abort "FUSED_JSON_CURSOR_RECORDS must be positive" unless record_count > 0
abort "FUSED_JSON_CURSOR_PARTIAL_KEYS must be positive" unless partial_key_cardinality > 0
abort "FUSED_JSON_CURSOR_BUFFER must be positive" unless buffer_size > 0
abort "FUSED_JSON_BENCH_WARMUP must not be negative" unless warmup >= 0.seconds
abort "FUSED_JSON_BENCH_TIME must be positive" unless calculation > 0.seconds
abort "FUSED_JSON_BENCH_ALLOCATIONS must be positive" unless allocation_iterations > 0

scalar_source = TypedCursorCost.scalar_source(scalar_count)
empty_source = TypedCursorCost.empty_source(record_count)
int_source = TypedCursorCost.int_source(record_count)
string_source = TypedCursorCost.string_source(record_count)
nested_source = TypedCursorCost.nested_source(record_count)
price_source = TypedCursorCost.price_source(record_count)
partial_key_source = TypedCursorCost.key_probe_source(record_count, partial_key_cardinality)
unique_key_source = TypedCursorCost.key_probe_source(record_count, record_count)
equivalent_key_source = TypedCursorCost.decoded_equivalent_key_source(record_count)
partial_unique_keys = 1 + Math.min(record_count, partial_key_cardinality)

record_shapes = [
  {"empty", empty_source, 0},
  {"integer", int_source, 1},
  {"string", string_source, 1},
  {"nested", nested_source, 4},
  {"price", price_source, 5},
  {"partial-keys", partial_key_source, partial_unique_keys},
  {"unique-keys", unique_key_source, record_count + 1},
  {"equivalent-keys", equivalent_key_source, 2},
]

receipt = JSON.build do |json|
  json.object do
    json.field "receipt", "fused-json-typed-cursor-cost"
    json.field "version", 4
    json.field "recorded_at", Time.utc.to_rfc3339
    json.field "fused_json_version", FusedJSON::VERSION
    json.field "fused_json_commit", commit
    json.field "crystal_version", Crystal::VERSION
    json.field "crystal_build_commit", Crystal::BUILD_COMMIT
    json.field "llvm_version", Crystal::LLVM_VERSION
    json.field "target", Crystal::TARGET_TRIPLE
    json.field "release_build", true
    json.field "transports", [
      "String through PullParser",
      "IO::Memory through StreamingPullParser",
    ]
    json.field "cache_keys_profiles", [false, true]
    json.field "bounded_cache_policy", "exact decoded unique-key count"
    json.field "selected_shapes", selected_shapes.empty? ? valid_shape_names : selected_shapes
    json.field "partial_key_cardinality", partial_key_cardinality
    json.field "buffer_size", buffer_size
    json.field "scalar_elements", scalar_count
    json.field "scalar_source_bytes", scalar_source.bytesize
    json.field "scalar_source_sha256", Digest::SHA256.hexdigest(scalar_source)
    json.field "record_elements", record_count
    json.field "record_shapes" do
      json.array do
        record_shapes.each do |name, source, unique_keys|
          json.object do
            json.field "name", name
            json.field "source_bytes", source.bytesize
            json.field "source_sha256", Digest::SHA256.hexdigest(source)
            json.field "unique_decoded_keys", unique_keys
          end
        end
      end
    end
    json.field "warmup_seconds", warmup.total_seconds
    json.field "calculation_seconds", calculation.total_seconds
    json.field "allocation_iterations", allocation_iterations
    json.field "reverse_order", reverse_order
  end
end
puts receipt

if run_shape.call("scalar")
  TypedCursorCost.run_shape(
    "scalar array / String",
    scalar_source,
    scalar_count,
    [
      {"native cursor", -> { TypedCursorCost.scalar_native_string(scalar_source) }},
      {"read(T) loop", -> { TypedCursorCost.scalar_read_string(scalar_source) }},
      {"read_array(T)", -> { TypedCursorCost.scalar_read_array_string(scalar_source) }},
    ] of TypedCursorCost::Operation,
    warmup,
    calculation,
    allocation_iterations,
    reverse_order
  )
  TypedCursorCost.run_shape(
    "scalar array / streaming IO::Memory",
    scalar_source,
    scalar_count,
    [
      {"native cursor", -> { TypedCursorCost.scalar_native_stream(scalar_source, buffer_size) }},
      {"read(T) loop", -> { TypedCursorCost.scalar_read_stream(scalar_source, buffer_size) }},
      {"read_array(T)", -> { TypedCursorCost.scalar_read_array_stream(scalar_source, buffer_size) }},
    ] of TypedCursorCost::Operation,
    warmup,
    calculation,
    allocation_iterations,
    reverse_order
  )
end

if run_shape.call("empty")
  TypedCursorCost.run_record_profile(
    "empty records", empty_source, record_count, 0,
    TypedCursorCost::EmptyRecord, buffer_size, warmup, calculation,
    allocation_iterations, reverse_order
  )
end
if run_shape.call("integer")
  TypedCursorCost.run_record_profile(
    "one-integer records", int_source, record_count, 1,
    TypedCursorCost::IntRecord, buffer_size, warmup, calculation,
    allocation_iterations, reverse_order
  )
end
if run_shape.call("string")
  TypedCursorCost.run_record_profile(
    "one-string records", string_source, record_count, 1,
    TypedCursorCost::StringRecord, buffer_size, warmup, calculation,
    allocation_iterations, reverse_order
  )
end
if run_shape.call("nested")
  TypedCursorCost.run_record_profile(
    "nested records", nested_source, record_count, 4,
    TypedCursorCost::NestedRecord, buffer_size, warmup, calculation,
    allocation_iterations, reverse_order
  )
end
if run_shape.call("price")
  TypedCursorCost.run_record_profile(
    "negotiated-price records", price_source, record_count, 5,
    TICBench::TypedNegotiatedPrice, buffer_size, warmup, calculation,
    allocation_iterations, reverse_order
  )
end
if run_shape.call("partial-keys")
  TypedCursorCost.run_record_profile(
    "partially repeated keys", partial_key_source, record_count,
    partial_unique_keys, TypedCursorCost::KeyProbeRecord, buffer_size,
    warmup, calculation, allocation_iterations, reverse_order
  )
end
if run_shape.call("unique-keys")
  TypedCursorCost.run_record_profile(
    "unique high-cardinality keys", unique_key_source, record_count,
    record_count + 1, TypedCursorCost::KeyProbeRecord, buffer_size,
    warmup, calculation, allocation_iterations, reverse_order
  )
end
if run_shape.call("equivalent-keys")
  TypedCursorCost.run_record_profile(
    "decoded-equivalent keys", equivalent_key_source, record_count, 2,
    TypedCursorCost::KeyProbeRecord, buffer_size, warmup, calculation,
    allocation_iterations, reverse_order
  )
end
