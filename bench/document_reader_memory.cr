require "json"

require "../src/fused_json"

module DocumentReaderMemory
  RECORD = %({"id":7,"name":"repeated","active":true,"tags":["json","stream"]}\n)

  struct Event
    include JSON::Serializable

    getter id : Int64
    getter name : String
    getter? active : Bool
    getter tags : Array(String)
  end

  class RepeatedRecordIO < IO
    getter read_calls : Int64

    @record_source : String
    @record : Bytes
    @total_bytes : Int64
    @position : Int64

    def initialize(@record_source : String, records : Int64)
      if records > Int64::MAX // @record_source.bytesize
        raise ArgumentError.new("generated stream is too large")
      end
      @record = @record_source.to_slice
      @total_bytes = @record.size.to_i64 * records
      @position = 0_i64
      @read_calls = 0_i64
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("empty read request") if slice.empty?
      @read_calls += 1
      return 0 if @position == @total_bytes

      count = Math.min(slice.size.to_i64, @total_bytes - @position).to_i32
      written = 0
      while written < count
        record_position = (@position % @record.size).to_i32
        copied = Math.min(count - written, @record.size - record_position)
        slice[written, copied].copy_from(@record[record_position, copied])
        written += copied
        @position += copied
      end
      count
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("DocumentReaderMemory::RepeatedRecordIO is read-only")
    end
  end

  extend self

  def run_typed(records : Int64, buffer_size : Int32, cache_keys : Bool,
                retain : Bool) : Tuple(Int64, Int64, UInt64)
    input = RepeatedRecordIO.new(RECORD, records)
    reader = FusedJSON.documents(
      input,
      Event,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: buffer_size,
      cache_keys: cache_keys
    )
    retained = [] of Event if retain
    count = 0_i64
    checksum = 0_u64
    reader.each do |event|
      raise "unexpected generated event" unless event.id == 7 && event.active?
      retained.try &.<< event
      checksum &+= event.id.to_u64 &+ event.name.bytesize.to_u64 &+ event.tags.size.to_u64
      count += 1
    end
    reader.finish
    raise "retained result was lost" if retained && retained.size != count
    {count, input.read_calls, checksum}
  end

  def run_dynamic(records : Int64, buffer_size : Int32, cache_keys : Bool,
                  retain : Bool) : Tuple(Int64, Int64, UInt64)
    input = RepeatedRecordIO.new(RECORD, records)
    reader = FusedJSON.documents(
      input,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: buffer_size,
      cache_keys: cache_keys
    )
    retained = [] of JSON::Any if retain
    count = 0_i64
    checksum = 0_u64
    reader.each do |value|
      raise "unexpected generated value" unless value["active"].as_bool
      retained.try &.<< value
      checksum &+= value["id"].as_i64.to_u64
      checksum &+= value["name"].as_s.bytesize.to_u64
      checksum &+= value["tags"].as_a.size.to_u64
      count += 1
    end
    reader.finish
    raise "retained result was lost" if retained && retained.size != count
    {count, input.read_calls, checksum}
  end
end

{% unless flag?(:release) %}
  STDERR.puts "warning: build this benchmark with --release for meaningful results"
{% end %}

records = (ENV["FUSED_JSON_DOCUMENT_RECORDS"]? || "1000000").to_i64
buffer_size = (ENV["FUSED_JSON_DOCUMENT_BUFFER"]? || (32 * 1024).to_s).to_i
mode = ENV["FUSED_JSON_DOCUMENT_MODE"]? || "typed"
cache_keys = ENV["FUSED_JSON_DOCUMENT_CACHE_KEYS"]? == "1"
retain = ENV["FUSED_JSON_DOCUMENT_RETAIN"]? == "1"

abort "FUSED_JSON_DOCUMENT_RECORDS must be positive" unless records > 0
abort "FUSED_JSON_DOCUMENT_BUFFER must be positive" unless buffer_size > 0

count, read_calls, checksum = case mode
                              when "typed"
                                DocumentReaderMemory.run_typed(records, buffer_size, cache_keys, retain)
                              when "dynamic"
                                DocumentReaderMemory.run_dynamic(records, buffer_size, cache_keys, retain)
                              else
                                abort "FUSED_JSON_DOCUMENT_MODE must be typed or dynamic"
                              end
abort "wrong generated document count" unless count == records

puts({
  mode:         mode,
  records:      records,
  source_bytes: DocumentReaderMemory::RECORD.bytesize.to_i64 * records,
  buffer_size:  buffer_size,
  cache_keys:   cache_keys,
  retain:       retain,
  read_calls:   read_calls,
  checksum:     checksum,
}.to_json)
