require "digest/sha256"
require "json"

module TICBench
  MANIFEST_FORMAT               = "fused-json-tic-fixture"
  MANIFEST_VERSION              = 1
  PROJECTION_FORMAT             = "fused-json-tic-prices-jsonl"
  PROJECTION_VERSION            = 1
  PROJECTION_CHECKSUM_ALGORITHM = "fnv1a64-fields-v1"
  FNV_OFFSET                    = 14_695_981_039_346_656_037_u64
  FNV_PRIME                     =          1_099_511_628_211_u64

  class Counts
    include JSON::Serializable

    property provider_references : Int64
    property provider_groups : Int64
    property in_network : Int64
    property negotiated_rates : Int64
    property negotiated_prices : Int64

    def initialize(@provider_references = 0_i64, @provider_groups = 0_i64,
                   @in_network = 0_i64, @negotiated_rates = 0_i64,
                   @negotiated_prices = 0_i64)
    end

    def ==(other : self) : Bool
      provider_references == other.provider_references &&
        provider_groups == other.provider_groups &&
        in_network == other.in_network &&
        negotiated_rates == other.negotiated_rates &&
        negotiated_prices == other.negotiated_prices
    end
  end

  class SourceMaximum
    include JSON::Serializable

    getter bytes : Int64
    getter kind : String
    getter path : String

    def initialize(@bytes, @kind, @path)
    end
  end

  class UnicodeSplit
    include JSON::Serializable

    getter path : String
    getter codepoint : String
    getter start_byte : Int64
    getter boundary_byte : Int64

    def initialize(@path, @codepoint, @start_byte, @boundary_byte)
    end
  end

  class ProjectionMetadata
    include JSON::Serializable

    getter format : String
    getter version : Int32
    getter algorithm : String
    getter lines : Int64
    getter sha256 : String
    getter checksum_algorithm : String
    getter checksum : String

    def initialize(@lines, @sha256, @checksum,
                   @format = PROJECTION_FORMAT,
                   @version = PROJECTION_VERSION,
                   @algorithm = "sha256",
                   @checksum_algorithm = PROJECTION_CHECKSUM_ALGORITHM)
    end
  end

  class GzipMetadata
    include JSON::Serializable

    getter bytes : Int64
    getter sha256 : String
    getter level : Int32
    getter modification_time : Int64
    getter os : UInt8
    getter zlib_version : String

    def initialize(@bytes, @sha256, @level, @zlib_version,
                   @modification_time = 0_i64, @os = 255_u8)
    end
  end

  class Manifest
    include JSON::Serializable

    getter format : String
    getter version : Int32
    getter profile : String
    getter seed : String
    getter requested_bytes : Int64
    getter decompressed_bytes : Int64
    getter document_sha256 : String
    getter root_key_order : Array(String)
    getter boundary_bytes : Int32?
    getter counts : Counts
    getter maximum_nesting : Int32
    getter largest_token : SourceMaximum
    getter largest_item : SourceMaximum
    getter unicode_splits : Array(UnicodeSplit)
    getter projection : ProjectionMetadata
    getter gzip : GzipMetadata?

    def initialize(@profile, @seed, @requested_bytes, @decompressed_bytes,
                   @document_sha256, @root_key_order, @boundary_bytes,
                   @counts, @maximum_nesting, @largest_token, @largest_item,
                   @unicode_splits, @projection, @gzip = nil,
                   @format = MANIFEST_FORMAT, @version = MANIFEST_VERSION)
    end

    def validate! : Nil
      raise ArgumentError.new("unsupported fixture manifest format #{format.inspect}") unless format == MANIFEST_FORMAT
      raise ArgumentError.new("unsupported fixture manifest version #{version}") unless version == MANIFEST_VERSION
      raise ArgumentError.new("requested_bytes must be positive") unless requested_bytes > 0
      validate_document
      validate_projection
      validate_gzip
    end

    private def validate_document : Nil
      unless decompressed_bytes == requested_bytes
        raise ArgumentError.new("fixture size #{decompressed_bytes} does not match requested size #{requested_bytes}")
      end
      validate_sha256(document_sha256, "document_sha256")
      unless root_key_order.includes?("provider_references") && root_key_order.includes?("in_network")
        raise ArgumentError.new("root_key_order must include both TiC arrays")
      end
    end

    private def validate_projection : Nil
      unless projection.format == PROJECTION_FORMAT && projection.version == PROJECTION_VERSION &&
             projection.algorithm == "sha256"
        raise ArgumentError.new("unsupported fixture projection")
      end
      unless projection.lines == counts.negotiated_prices
        raise ArgumentError.new("projection line count does not match negotiated price count")
      end
      validate_sha256(projection.sha256, "projection.sha256")
      unless projection.checksum_algorithm == PROJECTION_CHECKSUM_ALGORITHM &&
             projection.checksum.matches?(/\A0x[0-9a-f]{16}\z/)
        raise ArgumentError.new("unsupported fixture projection checksum")
      end
    end

    private def validate_gzip : Nil
      if compressed = gzip
        raise ArgumentError.new("gzip byte count must be positive") unless compressed.bytes > 0
        validate_sha256(compressed.sha256, "gzip.sha256")
      end
    end

    private def validate_sha256(value : String, name : String) : Nil
      unless value.matches?(/\A[0-9a-f]{64}\z/)
        raise ArgumentError.new("#{name} is not a lowercase SHA-256 digest")
      end
    end
  end

  record ProjectionRow,
    sequence : Int64,
    item_index : Int64,
    price_index : Int64,
    billing_code : String,
    name : String,
    code_type : String,
    arrangement : String,
    description : String,
    provider_group_id : Int64,
    negotiated_type : String,
    negotiated_rate_cents : Int64,
    billing_class : String,
    service_code : String

  class ProjectionDigest
    getter lines : Int64

    def initialize
      @digest = Digest::SHA256.new
      @writer = DigestWriter.new(@digest)
      @builder = JSON::Builder.new(@writer)
      @lines = 0_i64
      @finished = false
    end

    def add(row : ProjectionRow) : Nil
      raise "projection digest is finalized" if @finished
      unless row.sequence == @lines
        raise ArgumentError.new("projection sequence #{row.sequence} does not follow #{@lines - 1}")
      end

      @builder.document do
        @builder.object do
          @builder.field "v", PROJECTION_VERSION
          @builder.field "sequence", row.sequence
          @builder.field "item_index", row.item_index
          @builder.field "price_index", row.price_index
          @builder.field "billing_code", row.billing_code
          @builder.field "name", row.name
          @builder.field "code_type", row.code_type
          @builder.field "arrangement", row.arrangement
          @builder.field "description", row.description
          @builder.field "provider_group_id", row.provider_group_id
          @builder.field "negotiated_type", row.negotiated_type
          @builder.field "negotiated_rate_cents", row.negotiated_rate_cents
          @builder.field "billing_class", row.billing_class
          @builder.field "service_code", row.service_code
        end
      end
      @writer << '\n'
      @lines += 1
    end

    def hexfinal : String
      raise "projection digest is already finalized" if @finished
      @finished = true
      @digest.hexfinal
    end

    private class DigestWriter < IO
      def initialize(@digest : Digest::SHA256)
      end

      def read(slice : Bytes) : NoReturn
        raise IO::Error.new("projection digest is write-only")
      end

      def write(slice : Bytes) : Nil
        @digest.update(slice)
      end
    end
  end

  class ProjectionChecksum
    getter lines : Int64
    getter value : UInt64

    def initialize
      @lines = 0_i64
      @value = FNV_OFFSET
    end

    def add(row : ProjectionRow) : Nil
      unless row.sequence == @lines
        raise ArgumentError.new("projection sequence #{row.sequence} does not follow #{@lines - 1}")
      end

      mix_i64(PROJECTION_VERSION)
      mix_i64(row.sequence)
      mix_i64(row.item_index)
      mix_i64(row.price_index)
      mix_string(row.billing_code)
      mix_string(row.name)
      mix_string(row.code_type)
      mix_string(row.arrangement)
      mix_string(row.description)
      mix_i64(row.provider_group_id)
      mix_string(row.negotiated_type)
      mix_i64(row.negotiated_rate_cents)
      mix_string(row.billing_class)
      mix_string(row.service_code)
      @lines += 1
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

  record TraversalResult,
    counts : Counts,
    projection_sha256 : String?,
    projection_checksum : String,
    first_item_seconds : Float64?

  def self.file_sha256(path : String) : String
    Digest::SHA256.new.file(path).hexfinal
  end

  def self.parse_manifest(path : String) : Manifest
    manifest = Manifest.from_json(File.read(path))
    manifest.validate!
    manifest
  end
end
