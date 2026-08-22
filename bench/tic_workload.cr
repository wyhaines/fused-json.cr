require "compress/gzip"
require "json"

require "../src/fused_json"
require "./tic_support"

module TICBench
  record DrainResult, bytes : Int64, checksum : UInt64
  record ContentDigest, bytes : Int64, sha256 : String

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

  private def traverse(pull : P, started : Time::Instant,
                       projection : S) forall P, S
    counts = Counts.new
    first_item_seconds = nil.as(Float64?)

    pull.read_object do |key|
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
      pull.read_object do |key|
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

      pull.read_object do |key|
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

      pull.read_object do |key|
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

      pull.read_object do |key|
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
