module PullSpecHelpers
  extend self

  def to_any(source : String, *, max_nesting : Int = 512, cache_keys : Bool = false) : JSON::Any
    pull = FusedJSON::PullParser.new(source, max_nesting: max_nesting, cache_keys: cache_keys)
    value = read_any(pull)
    pull.finish
    value
  end

  def read_any(pull : FusedJSON::PullParser) : JSON::Any
    case pull.kind
    when .null?
      JSON::Any.new(pull.read_null)
    when .bool?
      JSON::Any.new(pull.read_bool)
    when .int?
      JSON::Any.new(pull.read_int)
    when .float?
      JSON::Any.new(pull.read_float)
    when .string?
      JSON::Any.new(pull.read_string)
    when .begin_array?
      values = [] of JSON::Any
      pull.read_array do
        values << read_any(pull)
      end
      JSON::Any.new(values)
    when .begin_object?
      values = {} of String => JSON::Any
      pull.read_object do |key|
        values[key] = read_any(pull)
      end
      JSON::Any.new(values)
    else
      raise "expected a value, found #{pull.kind}"
    end
  end

  def skip(source : String, *, max_nesting : Int = 512) : Nil
    pull = FusedJSON::PullParser.new(source, max_nesting: max_nesting)
    pull.skip_value
    pull.finish
  end
end
