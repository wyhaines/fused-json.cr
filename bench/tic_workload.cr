require "compress/gzip"
require "json"

require "../src/fused_json"
require "./tic_support"

module TICBench
  record DrainResult, bytes : Int64, checksum : UInt64
  record ContentDigest, bytes : Int64, sha256 : String

  PROVIDER_CHECKSUM_ALGORITHM = "fnv1a64-provider-fields-v1"
  RETAINED_OUTPUT_POLICY      = "all-selected-typed-values-v1"

  struct TypedTin
    include JSON::Serializable

    @[JSON::Field(key: "type")]
    getter kind : String
    getter value : String
  end

  struct TypedProviderGroup
    include JSON::Serializable

    getter npi : Array(Int64)
    getter tin : TypedTin
  end

  struct TypedProviderReference
    include JSON::Serializable

    getter provider_group_id : Int64
    getter provider_groups : Array(TypedProviderGroup)
  end

  struct TypedNegotiatedPrice
    include JSON::Serializable

    getter negotiated_type : String
    getter negotiated_rate : Float64
    getter expiration_date : String
    getter billing_class : String
    getter service_code : Array(String)

    def initialize(@negotiated_type, @negotiated_rate, @expiration_date,
                   @billing_class, @service_code)
    end
  end

  class RetainedTypedOutput
    getter provider_records : Array(TypedProviderReference)
    getter scalar_values : Array(Int64)
    getter price_records : Array(TypedNegotiatedPrice)

    def initialize
      @provider_records = [] of TypedProviderReference
      @scalar_values = [] of Int64
      @price_records = [] of TypedNegotiatedPrice
    end

    def total_values : Int64
      provider_records.size.to_i64 + scalar_values.size + price_records.size
    end
  end

  class TypedTraversalResult
    getter traversal : TraversalResult
    getter provider_records : Int64
    getter price_records : Int64
    getter scalar_values : Int64
    getter provider_checksum : String
    getter input_passes : Int32
    getter pass_wall_seconds : Array(Float64)
    getter retained_output : RetainedTypedOutput?

    def initialize(@traversal, @provider_records, @price_records,
                   @scalar_values, @provider_checksum, @input_passes,
                   @pass_wall_seconds, @retained_output = nil)
    end

    def typed_records : Int64
      provider_records + price_records
    end

    def typed_values : Int64
      typed_records + scalar_values
    end
  end

  private class TypedTraversalStats
    getter provider_records : Int64
    getter price_records : Int64
    getter scalar_values : Int64
    getter retained_output : RetainedTypedOutput?

    def initialize(*, retain_output = false)
      @provider_records = 0_i64
      @price_records = 0_i64
      @scalar_values = 0_i64
      @provider_checksum = ProviderChecksum.new
      @retained_output = retain_output ? RetainedTypedOutput.new : nil
    end

    def add_provider(reference : TypedProviderReference) : Nil
      @provider_checksum.add(@provider_records, reference)
      @provider_records += 1
      @retained_output.try(&.provider_records.<<(reference))
    end

    def add_price(price : TypedNegotiatedPrice) : Nil
      @price_records += 1
      @retained_output.try(&.price_records.<<(price))
    end

    def add_scalar(value : Int64) : Nil
      @scalar_values += 1
      @retained_output.try(&.scalar_values.<<(value))
    end

    def provider_checksum : String
      @provider_checksum.hex
    end
  end

  private enum TypedSelection
    Both
    Providers
    Rates
  end

  private class ProviderChecksum
    def initialize
      @value = FNV_OFFSET
    end

    def add(sequence : Int64, reference : TypedProviderReference) : Nil
      mix_i64(1)
      mix_i64(sequence)
      mix_i64(reference.provider_group_id)
      mix_i64(reference.provider_groups.size)
      reference.provider_groups.each do |group|
        mix_i64(group.npi.size)
        group.npi.each { |npi| mix_i64(npi) }
        mix_string(group.tin.kind)
        mix_string(group.tin.value)
      end
    end

    def hex : String
      sprintf("0x%016x", @value)
    end

    private def mix_string(value : String) : Nil
      mix_u64(value.bytesize.to_u64)
      value.each_byte { |byte| mix_byte(byte) }
    end

    private def mix_i64(value : Int) : Nil
      mix_u64(value.to_i64.unsafe_as(UInt64))
    end

    private def mix_u64(value : UInt64) : Nil
      8.times do |index|
        mix_byte(((value >> (index * 8)) & 0xff_u64).to_u8)
      end
    end

    private def mix_byte(byte : UInt8) : Nil
      @value = (@value ^ byte) &* FNV_PRIME
    end
  end

  class NormalizedTraversalProjection
    def initialize(strong_digest : Bool)
      @digest = strong_digest ? ProjectionDigest.new : nil
      @checksum = ProjectionChecksum.new
    end

    def read_rate(pull : P) : Float64 forall P
      pull.read_float
    end

    def add(sequence : Int64, item_index : Int64, price_index : Int64,
            provider_group_id : Int64, metadata, negotiated_type : String,
            negotiated_rate : Float64, billing_class : String,
            service_code : String) : Nil
      row = ProjectionRow.new(
        sequence,
        item_index,
        price_index,
        metadata[:billing_code],
        metadata[:name],
        metadata[:code_type],
        metadata[:arrangement],
        metadata[:description],
        provider_group_id,
        negotiated_type,
        cents(negotiated_rate),
        billing_class,
        service_code
      )
      @digest.try(&.add(row))
      @checksum.add(row)
    end

    def result(counts : Counts, first_item_seconds : Float64?) : TraversalResult
      TraversalResult.new(
        counts,
        @digest.try(&.hexfinal),
        @checksum.hex,
        first_item_seconds
      )
    end

    private def cents(value : Float64) : Int64
      raise "fixture negotiated rate is not finite" unless value.finite?
      scaled = value * 100.0
      rounded = scaled.round.to_i64
      unless (scaled - rounded).abs <= 1e-7
        raise "fixture negotiated rate has more than two decimal places"
      end
      rounded
    end
  end

  class RawNumberTraversalProjection
    def initialize
      @checksum = RawNumberProjectionChecksum.new
    end

    def read_rate(pull : FusedJSON::PullParser) : String
      pull.read_raw_number
    end

    def read_rate(pull : JSON::PullParser) : String
      pull.raw_value.tap { pull.read_next }
    end

    def add(sequence : Int64, item_index : Int64, price_index : Int64,
            provider_group_id : Int64, metadata, negotiated_type : String,
            negotiated_rate : String, billing_class : String,
            service_code : String) : Nil
      @checksum.add(RawNumberProjectionRow.new(
        sequence,
        item_index,
        price_index,
        metadata[:billing_code],
        metadata[:name],
        metadata[:code_type],
        metadata[:arrangement],
        metadata[:description],
        provider_group_id,
        negotiated_type,
        negotiated_rate,
        billing_class,
        service_code
      ))
    end

    def result(counts : Counts, _first_item_seconds : Float64?) : RawNumberTraversalResult
      RawNumberTraversalResult.new(counts, @checksum.hex)
    end
  end

  extend self

  def fused_pull(path : String, buffer_size : Int32,
                 max_nesting : Int32 = 512,
                 strong_digest : Bool = true) : TraversalResult
    started = Time.instant
    File.open(path) do |file|
      file.read_buffering = false
      pull = FusedJSON::PullParser.new(
        file,
        buffer_size: buffer_size,
        max_nesting: max_nesting,
        cache_keys: false
      )
      traverse(pull, started, NormalizedTraversalProjection.new(strong_digest))
    end
  end

  def crystal_pull(path : String, buffer_size : Int32,
                   max_nesting : Int32 = 512,
                   strong_digest : Bool = true) : TraversalResult
    started = Time.instant
    File.open(path) do |file|
      file.buffer_size = buffer_size
      pull = JSON::PullParser.new(file)
      pull.max_nesting = max_nesting
      traverse(pull, started, NormalizedTraversalProjection.new(strong_digest))
    end
  end

  def fused_raw_number_pull(path : String, buffer_size : Int32,
                            max_nesting : Int32 = 512) : RawNumberTraversalResult
    started = Time.instant
    File.open(path) do |file|
      file.read_buffering = false
      pull = FusedJSON::PullParser.new(
        file,
        buffer_size: buffer_size,
        max_nesting: max_nesting,
        cache_keys: false
      )
      traverse(pull, started, RawNumberTraversalProjection.new)
    end
  end

  def crystal_raw_number_pull(path : String, buffer_size : Int32,
                              max_nesting : Int32 = 512) : RawNumberTraversalResult
    started = Time.instant
    File.open(path) do |file|
      file.buffer_size = buffer_size
      pull = JSON::PullParser.new(file)
      pull.max_nesting = max_nesting
      traverse(pull, started, RawNumberTraversalProjection.new)
    end
  end

  def fused_typed_pull(path : String, buffer_size : Int32,
                       max_nesting : Int32 = 512,
                       strong_digest : Bool = true,
                       retain_output : Bool = false) : TypedTraversalResult
    started = Time.instant
    projection = NormalizedTraversalProjection.new(strong_digest)
    stats = TypedTraversalStats.new(retain_output: retain_output)
    pass_started = Time.instant
    counts, first_item_seconds = File.open(path) do |file|
      file.read_buffering = false
      pull = FusedJSON::PullParser.new(
        file,
        buffer_size: buffer_size,
        max_nesting: max_nesting,
        cache_keys: false
      )
      traverse_typed(pull, started, projection, stats, TypedSelection::Both)
    end
    typed_result(
      projection,
      counts,
      first_item_seconds,
      stats,
      1,
      [(Time.instant - pass_started).total_seconds]
    )
  end

  def crystal_typed_pull(path : String, buffer_size : Int32,
                         max_nesting : Int32 = 512,
                         strong_digest : Bool = true,
                         retain_output : Bool = false) : TypedTraversalResult
    started = Time.instant
    projection = NormalizedTraversalProjection.new(strong_digest)
    stats = TypedTraversalStats.new(retain_output: retain_output)
    pass_started = Time.instant
    counts, first_item_seconds = File.open(path) do |file|
      file.buffer_size = buffer_size
      pull = JSON::PullParser.new(file)
      pull.max_nesting = max_nesting
      traverse_typed(pull, started, projection, stats, TypedSelection::Both)
    end
    typed_result(
      projection,
      counts,
      first_item_seconds,
      stats,
      1,
      [(Time.instant - pass_started).total_seconds]
    )
  end

  def fused_gzip_typed_pull(path : String, buffer_size : Int32,
                            max_nesting : Int32 = 512,
                            strong_digest : Bool = true) : TypedTraversalResult
    started = Time.instant
    projection = NormalizedTraversalProjection.new(strong_digest)
    stats = TypedTraversalStats.new
    pass_started = Time.instant
    counts, first_item_seconds = File.open(path) do |file|
      file.read_buffering = false
      Compress::Gzip::Reader.open(file) do |gzip|
        pull = FusedJSON::PullParser.new(
          gzip,
          buffer_size: buffer_size,
          max_nesting: max_nesting,
          cache_keys: false
        )
        traverse_typed(pull, started, projection, stats, TypedSelection::Both)
      end
    end
    typed_result(
      projection,
      counts,
      first_item_seconds,
      stats,
      1,
      [(Time.instant - pass_started).total_seconds]
    )
  end

  def crystal_gzip_typed_pull(path : String, buffer_size : Int32,
                              max_nesting : Int32 = 512,
                              strong_digest : Bool = true) : TypedTraversalResult
    started = Time.instant
    projection = NormalizedTraversalProjection.new(strong_digest)
    stats = TypedTraversalStats.new
    pass_started = Time.instant
    counts, first_item_seconds = File.open(path) do |file|
      file.read_buffering = false
      Compress::Gzip::Reader.open(file) do |gzip|
        pull = JSON::PullParser.new(gzip)
        pull.max_nesting = max_nesting
        traverse_typed(pull, started, projection, stats, TypedSelection::Both)
      end
    end
    typed_result(
      projection,
      counts,
      first_item_seconds,
      stats,
      1,
      [(Time.instant - pass_started).total_seconds]
    )
  end

  def fused_two_pass_typed_pull(path : String, buffer_size : Int32,
                                max_nesting : Int32 = 512,
                                strong_digest : Bool = true) : TypedTraversalResult
    started = Time.instant
    projection = NormalizedTraversalProjection.new(strong_digest)
    stats = TypedTraversalStats.new
    pass_wall_seconds = [] of Float64

    pass_started = Time.instant
    provider_counts, _ = File.open(path) do |file|
      file.read_buffering = false
      pull = FusedJSON::PullParser.new(
        file,
        buffer_size: buffer_size,
        max_nesting: max_nesting,
        cache_keys: false
      )
      traverse_typed(pull, started, projection, stats, TypedSelection::Providers)
    end
    pass_wall_seconds << (Time.instant - pass_started).total_seconds

    pass_started = Time.instant
    rate_counts, first_item_seconds = File.open(path) do |file|
      file.read_buffering = false
      pull = FusedJSON::PullParser.new(
        file,
        buffer_size: buffer_size,
        max_nesting: max_nesting,
        cache_keys: false
      )
      traverse_typed(pull, started, projection, stats, TypedSelection::Rates)
    end
    pass_wall_seconds << (Time.instant - pass_started).total_seconds

    typed_result(
      projection,
      merge_counts(provider_counts, rate_counts),
      first_item_seconds,
      stats,
      2,
      pass_wall_seconds
    )
  end

  def crystal_two_pass_typed_pull(path : String, buffer_size : Int32,
                                  max_nesting : Int32 = 512,
                                  strong_digest : Bool = true) : TypedTraversalResult
    started = Time.instant
    projection = NormalizedTraversalProjection.new(strong_digest)
    stats = TypedTraversalStats.new
    pass_wall_seconds = [] of Float64

    pass_started = Time.instant
    provider_counts, _ = File.open(path) do |file|
      file.buffer_size = buffer_size
      pull = JSON::PullParser.new(file)
      pull.max_nesting = max_nesting
      traverse_typed(pull, started, projection, stats, TypedSelection::Providers)
    end
    pass_wall_seconds << (Time.instant - pass_started).total_seconds

    pass_started = Time.instant
    rate_counts, first_item_seconds = File.open(path) do |file|
      file.buffer_size = buffer_size
      pull = JSON::PullParser.new(file)
      pull.max_nesting = max_nesting
      traverse_typed(pull, started, projection, stats, TypedSelection::Rates)
    end
    pass_wall_seconds << (Time.instant - pass_started).total_seconds

    typed_result(
      projection,
      merge_counts(provider_counts, rate_counts),
      first_item_seconds,
      stats,
      2,
      pass_wall_seconds
    )
  end

  def plain_drain(path : String, buffer_size : Int32) : DrainResult
    File.open(path) do |file|
      file.read_buffering = false
      drain(file, buffer_size)
    end
  end

  def gzip_drain(path : String, buffer_size : Int32) : DrainResult
    File.open(path) do |file|
      file.read_buffering = false
      Compress::Gzip::Reader.open(file) do |gzip|
        drain(gzip, buffer_size)
      end
    end
  end

  def plain_content_digest(path : String, buffer_size : Int32) : ContentDigest
    File.open(path) do |file|
      file.read_buffering = false
      content_digest(file, buffer_size)
    end
  end

  def gzip_content_digest(path : String, buffer_size : Int32) : ContentDigest
    File.open(path) do |file|
      file.read_buffering = false
      Compress::Gzip::Reader.open(file) do |gzip|
        content_digest(gzip, buffer_size)
      end
    end
  end

  def verify_result(result : TraversalResult, manifest : Manifest,
                    implementation : String,
                    require_strong : Bool = true) : Nil
    unless result.counts == manifest.counts
      raise "#{implementation} counts do not match the fixture manifest"
    end
    unless result.projection_checksum == manifest.projection.checksum
      raise "#{implementation} projection checksum does not match the fixture manifest"
    end
    if require_strong && result.projection_sha256 != manifest.projection.sha256
      raise "#{implementation} projection SHA-256 does not match the fixture manifest"
    end
  end

  def verify_raw_number_result(result : RawNumberTraversalResult,
                               manifest : Manifest,
                               implementation : String) : Nil
    unless result.counts == manifest.counts
      raise "#{implementation} raw-number counts do not match the fixture manifest"
    end
    expected = manifest.projection.raw_number_checksum ||
               raise("fixture manifest does not contain a raw-number checksum")
    unless result.raw_number_checksum == expected
      raise "#{implementation} raw-number checksum does not match the fixture manifest"
    end
  end

  def verify_typed_result(result : TypedTraversalResult,
                          manifest : Manifest,
                          implementation : String,
                          require_strong : Bool = true) : Nil
    verify_result(result.traversal, manifest, implementation, require_strong: require_strong)
    unless result.provider_records == result.traversal.counts.provider_references
      raise "#{implementation} typed provider count does not match traversal counts"
    end
    unless result.price_records == result.traversal.counts.negotiated_prices
      raise "#{implementation} typed price count does not match traversal counts"
    end
    unless result.scalar_values == result.traversal.counts.negotiated_rates
      raise "#{implementation} typed scalar count does not match traversal counts"
    end
    unless result.provider_checksum.matches?(/\A0x[0-9a-f]{16}\z/)
      raise "#{implementation} typed provider checksum is malformed"
    end
    unless 1 <= result.input_passes <= 2 &&
           result.pass_wall_seconds.size == result.input_passes
      raise "#{implementation} typed pass metadata is inconsistent"
    end
    if retained = result.retained_output
      unless retained.provider_records.size == result.provider_records &&
             retained.price_records.size == result.price_records &&
             retained.scalar_values.size == result.scalar_values &&
             retained.total_values == result.typed_values
        raise "#{implementation} retained output is inconsistent"
      end
    end
  end

  private def typed_result(projection : NormalizedTraversalProjection,
                           counts : Counts, first_item_seconds : Float64?,
                           stats : TypedTraversalStats, input_passes : Int32,
                           pass_wall_seconds : Array(Float64)) : TypedTraversalResult
    TypedTraversalResult.new(
      projection.result(counts, first_item_seconds),
      stats.provider_records,
      stats.price_records,
      stats.scalar_values,
      stats.provider_checksum,
      input_passes,
      pass_wall_seconds,
      stats.retained_output
    )
  end

  private def merge_counts(first : Counts, second : Counts) : Counts
    Counts.new(
      first.provider_references + second.provider_references,
      first.provider_groups + second.provider_groups,
      first.in_network + second.in_network,
      first.negotiated_rates + second.negotiated_rates,
      first.negotiated_prices + second.negotiated_prices
    )
  end

  private def traverse_typed(pull : P, started : Time::Instant,
                             projection : NormalizedTraversalProjection,
                             stats : TypedTraversalStats,
                             selection : TypedSelection) forall P
    counts = Counts.new
    first_item_seconds = nil.as(Float64?)

    read_object_fields(pull) do |key|
      case key
      when "provider_references"
        if selection.both? || selection.providers?
          read_provider_references_typed(pull, counts, stats)
        else
          pull.skip
        end
      when "in_network"
        if selection.both? || selection.rates?
          read_in_network_typed(pull, counts, projection, stats, started) do |seconds|
            first_item_seconds ||= seconds
          end
        else
          pull.skip
        end
      when "_fixture_unicode_boundary"
        raise "fixture Unicode boundary value is empty" if pull.read_string.empty?
      else
        pull.skip
      end
    end
    finish(pull)

    {counts, first_item_seconds}
  end

  private def read_provider_references_typed(pull : P, counts : Counts,
                                             stats : TypedTraversalStats) : Nil forall P
    read_typed_array(pull, TypedProviderReference) do |reference|
      raise "fixture provider reference has no provider groups" if reference.provider_groups.empty?
      reference.provider_groups.each do |group|
        raise "fixture provider group has no NPI" if group.npi.empty?
        raise "fixture provider TIN type is empty" if group.tin.kind.empty?
        raise "fixture provider TIN value is empty" if group.tin.value.empty?
      end
      counts.provider_references += 1
      counts.provider_groups += reference.provider_groups.size
      stats.add_provider(reference)
    end
  end

  private def read_in_network_typed(pull : P, counts : Counts,
                                    projection : NormalizedTraversalProjection,
                                    stats : TypedTraversalStats,
                                    started : Time::Instant, &) : Nil forall P
    pull.read_array do
      item_index = counts.in_network
      counts.in_network += 1
      arrangement = nil.as(String?)
      name = nil.as(String?)
      code_type = nil.as(String?)
      billing_code = nil.as(String?)
      description = nil.as(String?)

      read_object_fields(pull) do |key|
        case key
        when "negotiation_arrangement"
          arrangement = pull.read_string
        when "name"
          name = pull.read_string
        when "billing_code_type"
          code_type = pull.read_string
        when "billing_code"
          billing_code = pull.read_string
        when "description"
          description = pull.read_string
        when "negotiated_rates"
          metadata = {
            arrangement:  required(arrangement, "negotiation_arrangement"),
            name:         required(name, "name"),
            code_type:    required(code_type, "billing_code_type"),
            billing_code: required(billing_code, "billing_code"),
            description:  required(description, "description"),
          }
          read_negotiated_rates_typed(
            pull,
            counts,
            projection,
            stats,
            started,
            item_index,
            metadata
          ) do |seconds|
            yield seconds
          end
        else
          pull.skip
        end
      end
    end
  end

  private def read_negotiated_rates_typed(pull : P, counts : Counts,
                                          projection : NormalizedTraversalProjection,
                                          stats : TypedTraversalStats,
                                          started : Time::Instant,
                                          item_index : Int64, metadata, &) : Nil forall P
    pull.read_array do
      counts.negotiated_rates += 1
      provider_group_id = nil.as(Int64?)
      references = 0_i32

      read_object_fields(pull) do |key|
        case key
        when "provider_references"
          read_typed_array(pull, Int64) do |reference|
            provider_group_id = reference
            references += 1
            stats.add_scalar(reference)
          end
          raise "fixture rate must contain exactly one provider reference" unless references == 1
        when "negotiated_prices"
          provider_id = required(provider_group_id, "provider_references")
          read_prices_typed(
            pull,
            counts,
            projection,
            stats,
            started,
            item_index,
            provider_id,
            metadata
          ) do |seconds|
            yield seconds
          end
        else
          pull.skip
        end
      end
    end
  end

  private def read_prices_typed(pull : P, counts : Counts,
                                projection : NormalizedTraversalProjection,
                                stats : TypedTraversalStats,
                                started : Time::Instant,
                                item_index : Int64,
                                provider_group_id : Int64, metadata, &) : Nil forall P
    price_index = 0_i64
    read_typed_array(pull, TypedNegotiatedPrice) do |price|
      unless price.expiration_date == "2027-12-31"
        raise "fixture price has an unexpected expiration date"
      end
      unless price.service_code.size == 1
        raise "fixture price must contain exactly one service code"
      end

      sequence = counts.negotiated_prices
      projection.add(
        sequence,
        item_index,
        price_index,
        provider_group_id,
        metadata,
        price.negotiated_type,
        price.negotiated_rate,
        price.billing_class,
        price.service_code.first
      )
      counts.negotiated_prices += 1
      stats.add_price(price)
      yield (Time.instant - started).total_seconds if sequence == 0
      price_index += 1
    end
  end

  private def read_typed_array(pull : FusedJSON::PullParser,
                               type : T.class, & : T ->) : Nil forall T
    pull.read_array(type) { |value| yield value }
  end

  private def read_typed_array(pull : JSON::PullParser,
                               type : T.class, & : T ->) : Nil forall T
    pull.read_array { yield T.new(pull) }
  end

  private def read_object_fields(pull : P, & : String ->) : Nil forall P
    pull.read_begin_object
    until pull.kind.end_object?
      yield pull.read_object_key
    end
    pull.read_end_object
  end

  private def traverse(pull : P, started : Time::Instant,
                       projection : S) forall P, S
    counts = Counts.new
    first_item_seconds = nil.as(Float64?)

    read_object_fields(pull) do |key|
      case key
      when "provider_references"
        read_provider_references(pull, counts)
      when "in_network"
        read_in_network(pull, counts, projection, started) do |seconds|
          first_item_seconds ||= seconds
        end
      when "_fixture_unicode_boundary"
        raise "fixture Unicode boundary value is empty" if pull.read_string.empty?
      else
        pull.skip
      end
    end
    finish(pull)

    projection.result(counts, first_item_seconds)
  end

  private def read_provider_references(pull : P, counts : Counts) : Nil forall P
    pull.read_array do
      counts.provider_references += 1
      read_object_fields(pull) do |key|
        case key
        when "provider_groups"
          pull.read_array do
            counts.provider_groups += 1
            pull.skip
          end
        else
          pull.skip
        end
      end
    end
  end

  private def read_in_network(pull : P, counts : Counts,
                              projection : S,
                              started : Time::Instant, &) : Nil forall P, S
    pull.read_array do
      item_index = counts.in_network
      counts.in_network += 1
      arrangement = nil.as(String?)
      name = nil.as(String?)
      code_type = nil.as(String?)
      billing_code = nil.as(String?)
      description = nil.as(String?)

      read_object_fields(pull) do |key|
        case key
        when "negotiation_arrangement"
          arrangement = pull.read_string
        when "name"
          name = pull.read_string
        when "billing_code_type"
          code_type = pull.read_string
        when "billing_code"
          billing_code = pull.read_string
        when "description"
          description = pull.read_string
        when "negotiated_rates"
          metadata = {
            arrangement:  required(arrangement, "negotiation_arrangement"),
            name:         required(name, "name"),
            code_type:    required(code_type, "billing_code_type"),
            billing_code: required(billing_code, "billing_code"),
            description:  required(description, "description"),
          }
          read_negotiated_rates(
            pull,
            counts,
            projection,
            started,
            item_index,
            metadata
          ) do |seconds|
            yield seconds
          end
        else
          pull.skip
        end
      end
    end
  end

  private def read_negotiated_rates(pull : P, counts : Counts,
                                    projection : S,
                                    started : Time::Instant,
                                    item_index : Int64, metadata, &) : Nil forall P, S
    pull.read_array do
      counts.negotiated_rates += 1
      provider_group_id = nil.as(Int64?)

      read_object_fields(pull) do |key|
        case key
        when "provider_references"
          references = 0_i32
          pull.read_array do
            provider_group_id = pull.read_int
            references += 1
          end
          raise "fixture rate must contain exactly one provider reference" unless references == 1
        when "negotiated_prices"
          provider_id = required(provider_group_id, "provider_references")
          read_prices(
            pull,
            counts,
            projection,
            started,
            item_index,
            provider_id,
            metadata
          ) do |seconds|
            yield seconds
          end
        else
          pull.skip
        end
      end
    end
  end

  private def read_prices(pull : P, counts : Counts,
                          projection : S,
                          started : Time::Instant,
                          item_index : Int64,
                          provider_group_id : Int64, metadata, &) : Nil forall P, S
    price_index = 0_i64
    pull.read_array do
      negotiated_type = nil.as(String?)
      negotiated_rate = nil
      billing_class = nil.as(String?)
      service_code = nil.as(String?)

      read_object_fields(pull) do |key|
        case key
        when "negotiated_type"
          negotiated_type = pull.read_string
        when "negotiated_rate"
          negotiated_rate = projection.read_rate(pull)
        when "billing_class"
          billing_class = pull.read_string
        when "service_code"
          codes = 0_i32
          pull.read_array do
            service_code = pull.read_string
            codes += 1
          end
          raise "fixture price must contain exactly one service code" unless codes == 1
        else
          pull.skip
        end
      end

      sequence = counts.negotiated_prices
      projection.add(
        sequence,
        item_index,
        price_index,
        provider_group_id,
        metadata,
        required(negotiated_type, "negotiated_type"),
        required(negotiated_rate, "negotiated_rate"),
        required(billing_class, "billing_class"),
        required(service_code, "service_code")
      )
      counts.negotiated_prices += 1
      yield (Time.instant - started).total_seconds if sequence == 0
      price_index += 1
    end
  end

  private def required(value : T?, name : String) : T forall T
    value || raise "fixture is missing #{name} before its dependent value"
  end

  private def finish(pull : FusedJSON::PullParser) : Nil
    pull.finish
  end

  private def finish(pull : JSON::PullParser) : Nil
    raise "Crystal pull parser did not reach document EOF" unless pull.kind.eof?
  end

  private def drain(io : IO, buffer_size : Int32) : DrainResult
    buffer = Bytes.new(buffer_size)
    bytes = 0_i64
    checksum = FNV_OFFSET
    while (count = io.read(buffer)) > 0
      bytes += count
      checksum = (checksum ^ count.to_u64) &* FNV_PRIME
      checksum = (checksum ^ buffer[0].to_u64) &* FNV_PRIME
      checksum = (checksum ^ buffer[count - 1].to_u64) &* FNV_PRIME
    end
    DrainResult.new(bytes, checksum)
  end

  private def content_digest(io : IO, buffer_size : Int32) : ContentDigest
    buffer = Bytes.new(buffer_size)
    digest = Digest::SHA256.new
    bytes = 0_i64
    while (count = io.read(buffer)) > 0
      digest.update(buffer[0, count])
      bytes += count
    end
    ContentDigest.new(bytes, digest.hexfinal)
  end
end
