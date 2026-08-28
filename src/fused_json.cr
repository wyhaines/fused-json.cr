require "json"

require "./fused_json/limits"
require "./fused_json/float64_decoder"
require "./fused_json/ascii_string_scanner"
require "./fused_json/key_cache"
require "./fused_json/byte_scanner"
require "./fused_json/parser"
require "./fused_json/pull_parser"
require "./fused_json/streaming_pull_parser"
require "./fused_json/streaming_parser"
require "./fused_json/json_pull_adapter"
require "./fused_json/document_reader"

# A fast, strict JSON parser for Crystal.
module FusedJSON
  VERSION = "0.3.0"

  # Parses *source* into Crystal's standard `JSON::Any` representation.
  def self.load(source : String, *, max_nesting : Int = 512,
                cache_keys : Bool = false, limits : Limits = Limits::DEFAULT) : JSON::Any
    Parser.new(source, max_nesting: max_nesting, cache_keys: cache_keys, limits: limits).parse
  end

  # Parses strict JSON incrementally from caller-owned IO. `max_token_bytes`
  # optionally limits each raw string or number in the decoded stream.
  def self.load(source : IO, *, buffer_size : Int = 32 * 1024,
                max_nesting : Int = 512, cache_keys : Bool = false,
                max_token_bytes : Int? = nil,
                limits : Limits = Limits::DEFAULT) : JSON::Any
    StreamingParser.new(
      source,
      buffer_size: buffer_size,
      max_nesting: max_nesting,
      cache_keys: cache_keys,
      max_token_bytes: max_token_bytes,
      limits: limits
    ).parse
  end

  # Alias for `.load`.
  def self.parse(source : String, *, max_nesting : Int = 512,
                 cache_keys : Bool = false, limits : Limits = Limits::DEFAULT) : JSON::Any
    load(source, max_nesting: max_nesting, cache_keys: cache_keys, limits: limits)
  end

  # Alias for the streaming `.load` overload.
  def self.parse(source : IO, *, buffer_size : Int = 32 * 1024,
                 max_nesting : Int = 512, cache_keys : Bool = false,
                 max_token_bytes : Int? = nil,
                 limits : Limits = Limits::DEFAULT) : JSON::Any
    load(
      source,
      buffer_size: buffer_size,
      max_nesting: max_nesting,
      cache_keys: cache_keys,
      max_token_bytes: max_token_bytes,
      limits: limits
    )
  end

  # Decodes *source* directly into *type* through Crystal's standard JSON
  # constructors, without first building a `JSON::Any` tree.
  def self.from_json(source : String, type : T.class, *, max_nesting : Int = 512,
                     cache_keys : Bool = false, limits : Limits = Limits::DEFAULT) : T forall T
    pull = JSONPullAdapter.build(
      source,
      max_nesting: max_nesting,
      cache_keys: cache_keys,
      limits: limits
    )
    value = T.new(pull)
    pull.finish
    value
  end

  # Decodes one complete JSON document incrementally from caller-owned IO.
  # `max_token_bytes` optionally limits each raw string or number.
  def self.from_json(source : IO, type : T.class, *, buffer_size : Int = 32 * 1024,
                     max_nesting : Int = 512, cache_keys : Bool = false,
                     max_token_bytes : Int? = nil,
                     limits : Limits = Limits::DEFAULT) : T forall T
    pull = StreamingJSONPullAdapter.build(
      source,
      buffer_size: buffer_size,
      max_nesting: max_nesting,
      cache_keys: cache_keys,
      max_token_bytes: max_token_bytes,
      limits: limits
    )
    value = T.new(pull)
    pull.finish
    value
  end
end
