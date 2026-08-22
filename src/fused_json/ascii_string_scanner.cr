module FusedJSON
  # :nodoc:
  private module ASCIIStringScanner
    WORD_BYTES = 8

    private ONES        = 0x0101_0101_0101_0101_u64
    private HIGH_BITS   = 0x8080_8080_8080_8080_u64
    private CONTROLS    = 0x2020_2020_2020_2020_u64
    private QUOTES      = 0x2222_2222_2222_2222_u64
    private BACKSLASHES = 0x5c5c_5c5c_5c5c_5c5c_u64

    {% if flag?(:fused_json_force_scalar_string_scan) %}
      BACKEND = :scalar

      # Returns the first quote, backslash, control byte, or non-ASCII byte in
      # the bounded range, or *finish* when every byte is ordinary ASCII.
      def self.find_special(bytes : Bytes, start : Int32, finish : Int32) : Int32
        scalar_find_special(bytes, start, finish)
      end
    {% else %}
      BACKEND = :word

      # Loads only complete words, then uses the scalar path for the tail.
      def self.find_special(bytes : Bytes, start : Int32, finish : Int32) : Int32
        index = start
        while finish - index >= WORD_BYTES
          word = load_word(bytes.to_unsafe + index)
          mask = special_mask(word)
          return index + (mask.trailing_zeros_count // 8).to_i32 unless mask == 0
          index += WORD_BYTES
        end

        scalar_find_special(bytes, index, finish)
      end
    {% end %}

    @[AlwaysInline]
    private def self.scalar_find_special(bytes : Bytes, start : Int32, finish : Int32) : Int32
      index = start
      while index < finish
        byte = bytes[index]
        return index if byte == 0x22_u8 || byte == 0x5c_u8 || byte < 0x20_u8 || byte >= 0x80_u8
        index += 1
      end
      finish
    end

    @[AlwaysInline]
    private def self.load_word(pointer : UInt8*) : UInt64
      word = uninitialized UInt64
      pointerof(word).as(UInt8*).copy_from(pointer, WORD_BYTES)
      # Normalize memory order so trailing zeros identify the earliest byte.
      {% if IO::ByteFormat::SystemEndian == IO::ByteFormat::BigEndian %}
        word.byte_swap
      {% else %}
        word
      {% end %}
    end

    @[AlwaysInline]
    private def self.special_mask(word : UInt64) : UInt64
      # The subtraction masks can also mark bytes after a true match because
      # of borrows. They cannot mark an earlier byte, so the first set byte is
      # always the first byte that needs full JSON handling.
      (word & HIGH_BITS) |
        zero_byte_mask(word ^ QUOTES) |
        zero_byte_mask(word ^ BACKSLASHES) |
        ((word &- CONTROLS) & ~word & HIGH_BITS)
    end

    @[AlwaysInline]
    private def self.zero_byte_mask(word : UInt64) : UInt64
      (word &- ONES) & ~word & HIGH_BITS
    end
  end
end
