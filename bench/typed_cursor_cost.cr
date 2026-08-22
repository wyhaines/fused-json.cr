require "benchmark"

require "./tic_workload"

module TypedCursorCost
  record Result, count : Int64, checksum : UInt64
  alias Operation = Tuple(String, Proc(Result))

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

  def scalar_native(source : String, buffer_size : Int32) : Result
    pull = streaming_pull(source, buffer_size)
    count = 0_i64
    checksum = TICBench::FNV_OFFSET
    pull.read_array do
      checksum = mix_i64(checksum, pull.read_int)
      count += 1
    end
    pull.finish
    Result.new(count, checksum)
  end

  def scalar_read(source : String, buffer_size : Int32) : Result
    pull = streaming_pull(source, buffer_size)
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

  def scalar_read_array(source : String, buffer_size : Int32) : Result
    pull = streaming_pull(source, buffer_size)
    count = 0_i64
    checksum = TICBench::FNV_OFFSET
    pull.read_array(Int64) do |value|
      checksum = mix_i64(checksum, value)
      count += 1
    end
    pull.finish
    Result.new(count, checksum)
  end

  def price_native(source : String, buffer_size : Int32) : Result
    pull = streaming_pull(source, buffer_size)
    count = 0_i64
    checksum = TICBench::FNV_OFFSET
    pull.read_array do
      checksum = mix_price(checksum, read_native_price(pull))
      count += 1
    end
    pull.finish
    Result.new(count, checksum)
  end

  def price_read(source : String, buffer_size : Int32) : Result
    pull = streaming_pull(source, buffer_size)
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

  def price_read_array(source : String, buffer_size : Int32) : Result
    pull = streaming_pull(source, buffer_size)
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
                reverse_order : Bool) : Nil
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

  private def streaming_pull(source : String, buffer_size : Int32)
    FusedJSON::PullParser.new(
      IO::Memory.new(source),
      buffer_size: buffer_size,
      max_nesting: 512,
      cache_keys: false
    )
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
price_count = (ENV["FUSED_JSON_CURSOR_RECORDS"]? || "2000").to_i
buffer_size = (ENV["FUSED_JSON_CURSOR_BUFFER"]? || "16384").to_i
warmup = (ENV["FUSED_JSON_BENCH_WARMUP"]? || "1").to_f.seconds
calculation = (ENV["FUSED_JSON_BENCH_TIME"]? || "3").to_f.seconds
allocation_iterations = (ENV["FUSED_JSON_BENCH_ALLOCATIONS"]? || "20").to_i
reverse_order = ENV["FUSED_JSON_BENCH_REVERSE"]? == "1"

abort "FUSED_JSON_CURSOR_SCALARS must be positive" unless scalar_count > 0
abort "FUSED_JSON_CURSOR_RECORDS must be positive" unless price_count > 0
abort "FUSED_JSON_CURSOR_BUFFER must be positive" unless buffer_size > 0
abort "FUSED_JSON_BENCH_WARMUP must not be negative" unless warmup >= 0.seconds
abort "FUSED_JSON_BENCH_TIME must be positive" unless calculation > 0.seconds
abort "FUSED_JSON_BENCH_ALLOCATIONS must be positive" unless allocation_iterations > 0

scalar_source = TypedCursorCost.scalar_source(scalar_count)
price_source = TypedCursorCost.price_source(price_count)

receipt = JSON.build do |json|
  json.object do
    json.field "receipt", "fused-json-typed-cursor-cost"
    json.field "version", 1
    json.field "recorded_at", Time.utc.to_rfc3339
    json.field "fused_json_version", FusedJSON::VERSION
    json.field "fused_json_commit", commit
    json.field "crystal_version", Crystal::VERSION
    json.field "crystal_build_commit", Crystal::BUILD_COMMIT
    json.field "llvm_version", Crystal::LLVM_VERSION
    json.field "target", Crystal::TARGET_TRIPLE
    json.field "release_build", true
    json.field "transport", "IO::Memory through StreamingPullParser"
    json.field "buffer_size", buffer_size
    json.field "scalar_elements", scalar_count
    json.field "scalar_source_bytes", scalar_source.bytesize
    json.field "scalar_source_sha256", Digest::SHA256.hexdigest(scalar_source)
    json.field "record_elements", price_count
    json.field "record_source_bytes", price_source.bytesize
    json.field "record_source_sha256", Digest::SHA256.hexdigest(price_source)
    json.field "warmup_seconds", warmup.total_seconds
    json.field "calculation_seconds", calculation.total_seconds
    json.field "allocation_iterations", allocation_iterations
    json.field "reverse_order", reverse_order
  end
end
puts receipt

scalar_operations = [
  {"native cursor", -> { TypedCursorCost.scalar_native(scalar_source, buffer_size) }},
  {"read(T) loop", -> { TypedCursorCost.scalar_read(scalar_source, buffer_size) }},
  {"read_array(T)", -> { TypedCursorCost.scalar_read_array(scalar_source, buffer_size) }},
] of TypedCursorCost::Operation
price_operations = [
  {"native cursor", -> { TypedCursorCost.price_native(price_source, buffer_size) }},
  {"read(T) loop", -> { TypedCursorCost.price_read(price_source, buffer_size) }},
  {"read_array(T)", -> { TypedCursorCost.price_read_array(price_source, buffer_size) }},
] of TypedCursorCost::Operation

TypedCursorCost.run_shape(
  "scalar array",
  scalar_source,
  scalar_count,
  scalar_operations,
  warmup,
  calculation,
  allocation_iterations,
  reverse_order
)
TypedCursorCost.run_shape(
  "negotiated-price records",
  price_source,
  price_count,
  price_operations,
  warmup,
  calculation,
  allocation_iterations,
  reverse_order
)
