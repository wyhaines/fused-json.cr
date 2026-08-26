# The table layout and probing sequence in this file are adapted from
# Crystal's StringPool at Crystal 1.21.0. Growth is performed before computing
# the insertion slot in the new table.
module FusedJSON
  # Per-parser decoded object-key interning.
  private class KeyCache
    getter size : Int32

    def initialize(initial_capacity : Int32 = 8)
      @capacity = initial_capacity >= 8 ? Math.pw2ceil(initial_capacity) : 8
      @hashes = Pointer(UInt64).malloc(@capacity, 0_u64)
      @values = Pointer(String).malloc(@capacity, "")
      @size = 0
    end

    def get(string : String) : String
      get(string.to_unsafe, string.bytesize)
    end

    def get?(string : String) : String?
      get?(string.to_unsafe, string.bytesize)
    end

    def get(bytes : UInt8*, size : Int32) : String
      hash = hash(bytes, size)
      mask = (@capacity - 1).to_u64
      index = hash & mask
      next_probe_offset = 1_u64

      while (stored_hash = @hashes[index]) != 0
        if stored_hash == hash && @values[index].bytesize == size &&
           bytes.memcmp(@values[index].to_unsafe, size) == 0
          return @values[index]
        end
        index = (index + next_probe_offset) & mask
        next_probe_offset += 1
      end

      if @size >= @capacity // 4 * 3
        grow
        mask = (@capacity - 1).to_u64
        index = hash & mask
        next_probe_offset = 1_u64
        while @hashes[index] != 0
          index = (index + next_probe_offset) & mask
          next_probe_offset += 1
        end
      end

      @size += 1
      entry = String.new(bytes, size)
      @hashes[index] = hash
      @values[index] = entry
      entry
    end

    def get?(bytes : UInt8*, size : Int32) : String?
      hash = hash(bytes, size)
      mask = (@capacity - 1).to_u64
      index = hash & mask
      next_probe_offset = 1_u64

      while (stored_hash = @hashes[index]) != 0
        if stored_hash == hash && @values[index].bytesize == size &&
           bytes.memcmp(@values[index].to_unsafe, size) == 0
          return @values[index]
        end
        index = (index + next_probe_offset) & mask
        next_probe_offset += 1
      end

      nil
    end

    private def grow : Nil
      raise "key cache is too large" if @capacity * 2 <= 0

      old_capacity = @capacity
      old_hashes = @hashes
      old_values = @values

      @capacity *= 2
      @hashes = Pointer(UInt64).malloc(@capacity, 0_u64)
      @values = Pointer(String).malloc(@capacity, "")

      old_capacity.times do |old_index|
        hash = old_hashes[old_index]
        insert_rehashed(hash, old_values[old_index]) unless hash == 0
      end
    end

    private def insert_rehashed(hash : UInt64, value : String) : Nil
      mask = (@capacity - 1).to_u64
      index = hash & mask
      next_probe_offset = 1_u64
      while @hashes[index] != 0
        index = (index + next_probe_offset) & mask
        next_probe_offset += 1
      end

      @hashes[index] = hash
      @values[index] = value
    end

    private def hash(bytes : UInt8*, size : Int32) : UInt64
      hasher = Crystal::Hasher.new
      hasher = bytes.to_slice(size).hash(hasher)
      hasher.result | 0x8000000000000000_u64
    end
  end
end
