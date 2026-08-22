module FusedJSON
  # :nodoc:
  # Converts a validated JSON number byte range to Float64.
  module Float64Decoder
    # Crystal's internal pointer-range fast_float API is not public. Keep its
    # use isolated here and fall back to the public String API outside the
    # compiler versions whose implementation has been reviewed. Builds can use
    # `-Dfused_json_force_portable_float` to select the fallback explicitly.
    {% if !flag?(:fused_json_force_portable_float) &&
            compare_versions(Crystal::VERSION, "1.21.0") >= 0 &&
            compare_versions(Crystal::VERSION, "1.23.0-dev") < 0 %}
      BACKEND        = :fast_float_range
      ZERO_SUBSTRING = true

      def self.parse?(bytes : Bytes, start : Int32, finish : Int32) : Float64?
        value = uninitialized Float64
        first = bytes.to_unsafe + start
        last = bytes.to_unsafe + finish
        options = Float::FastFloat::ParseOptions.new(format: :json)
        result = Float::FastFloat::BinaryFormat_Float64.new.from_chars_advanced(
          first,
          last,
          pointerof(value),
          options
        )

        value if result.ec == Errno::NONE && result.ptr == last
      end
    {% else %}
      BACKEND        = :string
      ZERO_SUBSTRING = false

      def self.parse?(bytes : Bytes, start : Int32, finish : Int32) : Float64?
        String.new(bytes.to_unsafe + start, finish - start).to_f64?(
          whitespace: false,
          strict: true
        )
      end
    {% end %}
  end
end
