#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "oj"
require "open3"
require "optparse"
require "set"
require "stringio"
require "tempfile"
require "zlib"

sunlight_root = ENV["SUNLIGHT_ROOT"]
abort "SUNLIGHT_ROOT must name a Sunlight checkout (for example, SUNLIGHT_ROOT=/path/to/sunlight)" \
  if sunlight_root.nil? || sunlight_root.empty?
SUNLIGHT_ROOT = File.realpath(sunlight_root)
require File.join(SUNLIGHT_ROOT, "lib/sunlight/reconcile/doc_stream")

module FusedJSONSunlightCompat
  FORMAT = "fused-json-sunlight-tic-compat-v2"
  PROJECTION = "sunlight-oj-selection-tagged-jsonl-v1"
  SCANNER_PROTOCOL = 1
  DEFAULT_LIMIT = 64 * 1024 * 1024
  SHA256_RE = /\A[0-9a-f]{64}\z/

  class ClassificationError < StandardError; end
  class ScannerProtocolError < StandardError; end

  class SajBuilder < Oj::Saj
    attr_reader :root

    def initialize
      super
      @stack = []
      @root = nil
    end

    def hash_start(key)
      value = {}
      attach(value, key)
      @stack << value
    end

    def hash_end(_key) = @stack.pop

    def array_start(key)
      value = []
      attach(value, key)
      @stack << value
    end

    def array_end(_key) = @stack.pop
    def add_value(value, key) = attach(value, key)

    private

    def attach(value, key)
      if @stack.empty?
        @root = value
      elsif @stack.last.is_a?(Hash)
        @stack.last[key.to_s] = value
      else
        @stack.last << value
      end
    end
  end

  # Records only root-object member names. Oj still validates the complete
  # source, but no array element or nested object is retained.
  class TopLevelShape < Oj::Saj
    attr_reader :keys

    def initialize
      super
      @depth = 0
      @root_object = false
      @keys = Set.new
    end

    def hash_start(key)
      observe(key)
      @root_object = true if @depth.zero?
      @depth += 1
    end

    def hash_end(_key) = @depth -= 1

    def array_start(key)
      observe(key)
      @depth += 1
    end

    def array_end(_key) = @depth -= 1
    def add_value(_value, key) = observe(key)
    def root_object? = @root_object

    private

    def observe(key)
      @keys << key.to_s if @depth == 1 && !key.nil?
    end
  end

  class Projection
    attr_reader :reference_count, :price_count

    def initialize(path = nil)
      @reference = Digest::SHA256.new
      @price = Digest::SHA256.new
      @semantic = Digest::SHA256.new
      @reference_count = 0
      @price_count = 0
      @path = path
      if path
        raise "projection already exists: #{path}" if File.exist?(path)
        raise "partial projection already exists: #{path}.partial" if File.exist?("#{path}.partial")
      end
      @io = path && File.open(
        "#{path}.partial", File::WRONLY | File::CREAT | File::EXCL, 0o644
      )
      @io&.binmode
    end

    def meta(value)
      add({"kind" => "meta", "value" => {"reporting_entity_name" => value}}, @semantic)
    end

    def reference(value)
      line = canonical({"kind" => "reference", "value" => value})
      write(line, @reference, @semantic)
      @reference_count += 1
    end

    def price(price, matched_ids, inline_groups)
      line = canonical({"kind" => "price", "value" => [price, matched_ids, inline_groups]})
      write(line, @price, @semantic)
      @price_count += 1
    end

    def finish
      if @io
        @io.flush
        @io.fsync
        @io.close
        File.rename("#{@path}.partial", @path)
      end
      {
        "reference_sha256" => @reference.hexdigest,
        "price_sha256" => @price.hexdigest,
        "semantic_sha256" => @semantic.hexdigest
      }
    end

    def abort
      @io&.close
      FileUtils.rm_f("#{@path}.partial") if @path
    end

    private

    def canonical(value)
      # This is the normalization already used by Sunlight's crystal:verify:
      # Oj SAJ values cross Ruby JSON once, then object keys are sorted.
      normalized = JSON.parse(JSON.generate(value, max_nesting: false), max_nesting: false)
      JSON.generate(sort_objects(normalized), max_nesting: false)
    end

    def sort_objects(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, out| out[key] = sort_objects(value[key]) }
      when Array
        value.map { |item| sort_objects(item) }
      else
        value
      end
    end

    def add(value, *digests)
      write(canonical(value), *digests)
    end

    def write(line, *digests)
      bytes = "#{line}\n"
      digests.each { |digest| digest.update(bytes) }
      @io&.write(bytes)
    end
  end

  module_function

  def saj_parse(line)
    handler = SajBuilder.new
    parser = Oj::Parser.new(:saj)
    parser.handler = handler
    parser.load(StringIO.new(line))
    handler.root
  rescue Oj::ParseError, EncodingError => e
    raise ScannerProtocolError, "scanner emitted invalid JSON: #{e.class}: #{e.message}"
  end

  def file_sha(path) = Digest::SHA256.file(path).hexdigest

  def capture_command(*command)
    stdout, stderr, status = Open3.capture3(*command)
    raise "#{command.join(' ')} failed: #{stderr.strip}" unless status.success?
    stdout.strip
  end

  def git_identity(root)
    {
      "commit" => capture_command("git", "-C", root, "rev-parse", "HEAD"),
      "tracked_dirty" => !capture_command(
        "git", "-C", root, "status", "--porcelain", "--untracked-files=no"
      ).empty?
    }
  end

  def sunlight_identity
    files = %w[
      lib/sunlight/reconcile/doc_stream.rb
      lib/sunlight/tic/row_handler.rb
      lib/sunlight/mrf/json_row_handler.rb
    ].to_h do |relative|
      path = File.join(SUNLIGHT_ROOT, relative)
      raise "missing Sunlight contract source: #{path}" unless File.file?(path)
      [relative, file_sha(path)]
    end
    git_identity(SUNLIGHT_ROOT).merge("source_sha256" => files)
  end

  def provenance_paths(corpus, explicit)
    env_paths = ENV.fetch("FUSED_JSON_TIC_PROVENANCE", "").split(File::PATH_SEPARATOR)
    (explicit + env_paths + [
      File.join(corpus, "manifest.json"),
      File.join(File.dirname(corpus), "manifest.json")
    ]).reject(&:empty?).map { |path| File.expand_path(path) }.select { |path| File.file?(path) }.uniq
  end

  def load_provenance(paths)
    paths.map do |path|
      {
        "path" => File.realpath(path),
        "sha256" => file_sha(path),
        "document" => JSON.parse(File.read(path), max_nesting: false)
      }
    end
  end

  def provenance_identity(manifests)
    manifests.map { |manifest| manifest.slice("path", "sha256") }
  end

  def allowed_evidence(name, sha256, manifests)
    return "filename:#{name}" if name.match?(/allowed[-_ ]?amount/i)

    identity = [name, name.sub(/\.json\.gz\z/, ""), sha256]
    manifests.each do |manifest|
      return "manifest:#{manifest.fetch('sha256')}" if allowed_record?(manifest.fetch("document"), identity)
    end
    nil
  end

  def allowed_record?(value, identity)
    case value
    when Hash
      direct = value.keys + value.values.grep(String)
      same_record = identity.any? { |token| direct.any? { |text| text.include?(token) } }
      allowed = direct.any? { |text| text.match?(/allowed[-_ ]?amount/i) }
      (same_record && allowed) || value.values.any? { |child| allowed_record?(child, identity) }
    when Array
      value.any? { |child| allowed_record?(child, identity) }
    else
      false
    end
  end

  def with_source(path)
    if File.binread(path, 2) == Sunlight::Reconcile::DocStream::GZIP_MAGIC
      Zlib::GzipReader.open(path) { |io| yield io }
    else
      File.open(path, "rb") { |io| yield io }
    end
  end

  def top_level_shape(path)
    handler = TopLevelShape.new
    parser = Oj::Parser.new(:saj)
    parser.handler = handler
    with_source(path) { |io| parser.load(io) }
    raise ClassificationError, "#{path}: TiC source root is not an object" unless handler.root_object?
    handler.keys
  rescue Zlib::Error, EOFError, EncodingError, Oj::ParseError
    nil
  end

  def classification(path, sha256, manifests)
    base = File.basename(path)
    index_hint = base.start_with?("wy-index")
    allowed_hint = allowed_evidence(base, sha256, manifests)
    keys = top_level_shape(path)

    unless keys
      return ["excluded_index", "filename-prefix:wy-index"] if index_hint
      return ["unsupported_allowed_amount", allowed_hint] if allowed_hint
      # Preserve the source parser's own unparseable verdict. Classification
      # cannot inspect malformed JSON, so it must not hide that data verdict.
      return ["accepted_in_network", "source-unparseable:deferred"]
    end

    in_network = keys.include?("in_network")
    allowed = keys.include?("out_of_network")
    index = keys.include?("reporting_structure")
    if [in_network, allowed, index].count(true) > 1
      raise ClassificationError, "#{path}: conflicting TiC root shapes #{keys.to_a.sort.inspect}"
    end
    if in_network
      raise ClassificationError, "#{path}: allowed-amount provenance conflicts with in_network" if allowed_hint
      raise ClassificationError, "#{path}: index filename conflicts with in_network" if index_hint
      return ["accepted_in_network", "top-level:in_network"]
    end
    if allowed
      raise ClassificationError, "#{path}: index filename conflicts with out_of_network" if index_hint
      return ["unsupported_allowed_amount", "top-level:out_of_network"]
    end
    if index
      raise ClassificationError, "#{path}: allowed-amount provenance conflicts with index" if allowed_hint
      return ["excluded_index", "top-level:reporting_structure"]
    end
    return ["excluded_index", "filename-prefix:wy-index"] if index_hint
    return ["unsupported_allowed_amount", allowed_hint] if allowed_hint

    raise ClassificationError,
          "#{path}: valid JSON is neither in-network, allowed-amount, nor index; provide authoritative provenance"
  end

  def projection_path(dir, engine, name)
    return nil unless dir
    FileUtils.mkdir_p(dir)
    File.join(dir, "#{name}.#{engine}.jsonl")
  end

  def parse_oj(path, limit, projection)
    refs = []
    stream = Sunlight::Reconcile::DocStream.new(path, item_limit: limit)
    stream.reference_pass { |ref| refs << ref }
    projection.meta(stream.reporting_entity_name)
    ids = []
    id_set = Set.new
    refs.each do |ref|
      projection.reference(ref)
      next unless ref.is_a?(Hash) && ref.key?("provider_group_id")
      id = ref["provider_group_id"]
      next unless id
      ids << id
      id_set << id
    end
    stream.each_price(group_ids: ids) do |price, rate_ids, inline|
      matched = rate_ids.select { |id| id_set.include?(id) }
      next if matched.empty? && inline.empty?
      projection.price(price, matched, inline)
    end
  end

  def parse_fused(path, limit, projection, scanner)
    id_set = Set.new
    item = nil
    rate_ids = nil
    inline = nil
    phase = :start
    stderr_text = +""
    status = nil
    Open3.popen3(scanner, "--item-limit-bytes", limit.to_s, path) do |stdin, stdout, stderr, wait|
      stdin.close
      stdout.each_line do |raw|
        event = saj_parse(raw)
        case event.fetch("scan_event")
        when "meta"
          raise ScannerProtocolError, "meta must be the scanner's first and only meta event" unless phase == :start
          unless event["scan_protocol"] == SCANNER_PROTOCOL
            raise ScannerProtocolError,
                  "scanner protocol #{event['scan_protocol'].inspect} != #{SCANNER_PROTOCOL}"
          end
          projection.meta(event["reporting_entity_name"])
          phase = :references
        when "reference"
          raise ScannerProtocolError, "reference outside the reference phase" unless phase == :references
          ref = event.fetch("value")
          projection.reference(ref)
          if ref.is_a?(Hash) && ref.key?("provider_group_id") && (id = ref["provider_group_id"])
            id_set << id
          end
        when "item"
          unless %i[references items].include?(phase) && item.nil? && rate_ids.nil? && inline.nil?
            raise ScannerProtocolError, "nested or out-of-order item event"
          end
          phase = :items
          item = event
        when "rate"
          raise ScannerProtocolError, "rate outside an item" if item.nil? || !rate_ids.nil? || !inline.nil?
          rate_ids = Array(event["provider_references"])
          inline = Array(event["provider_groups"])
        when "price"
          raise ScannerProtocolError, "price outside a rate" if item.nil? || rate_ids.nil? || inline.nil?
          price = event.fetch("value")
          next unless price.is_a?(Hash)
          matched = rate_ids.select { |id| id_set.include?(id) }
          next if matched.empty? && inline.empty?
          merged = price.merge(
            "code" => item["billing_code"].to_s,
            "code_type" => item["billing_code_type"],
            "negotiation_arrangement" => item["negotiation_arrangement"]
          )
          projection.price(merged, matched, inline)
        when "rate_end"
          raise ScannerProtocolError, "rate_end without a rate" if rate_ids.nil? || inline.nil?
          rate_ids = inline = nil
        when "item_end"
          raise ScannerProtocolError, "item_end without a complete item" if item.nil? || rate_ids || inline
          item = nil
        else
          raise "unknown scanner event #{event.inspect}"
        end
      end
      stderr_text = stderr.read
      status = wait.value
    end
    if status.success?
      unless phase != :start && item.nil? && rate_ids.nil? && inline.nil?
        raise ScannerProtocolError, "scanner ended with an incomplete event stream"
      end
      return
    end
    raise Sunlight::Reconcile::DocStream::ItemTooLarge, stderr_text if status.exitstatus == 3
    raise Sunlight::Reconcile::DocStream::Unparseable, stderr_text if status.exitstatus == 4
    raise "scanner exited #{status.exitstatus}: #{stderr_text}"
  end

  def one_file(path, engine:, limit:, scanner:, projection_dir:, manifests:, frozen: nil)
    name = File.basename(path)
    sha256 = file_sha(path)
    base = {
      "name" => name,
      "compressed_bytes" => File.size(path),
      "compressed_sha256" => sha256
    }
    if frozen
      unless frozen["name"] == name && frozen["compressed_bytes"] == base["compressed_bytes"] &&
             frozen["compressed_sha256"] == sha256
        raise "#{path}: corpus identity changed after the Oj receipt was frozen"
      end
      klass = frozen.fetch("classification")
      evidence = frozen["classification_evidence"]
    else
      klass, evidence = classification(path, sha256, manifests)
    end
    base["classification"] = klass
    base["classification_evidence"] = evidence if evidence
    return base.merge("status" => "not_scanned") unless klass == "accepted_in_network"

    output_path = projection_path(projection_dir, engine, name)
    projection = Projection.new(output_path)
    begin
      engine == "oj" ? parse_oj(path, limit, projection) : parse_fused(path, limit, projection, scanner)
      base.merge(
        "status" => "accepted",
        "counts" => {"references" => projection.reference_count, "prices" => projection.price_count},
        "digests" => projection.finish,
        "projection_path" => output_path
      ).compact
    rescue Sunlight::Reconcile::DocStream::ItemTooLarge
      projection.abort
      base.merge("status" => "item_too_large")
    rescue Sunlight::Reconcile::DocStream::Unparseable
      projection.abort
      base.merge("status" => "unparseable")
    end
  end

  def corpus_digest(files)
    digest = Digest::SHA256.new
    files.each do |entry|
      comparable = entry.reject { |key, _| key == "projection_path" }
      normalized = JSON.parse(JSON.generate(comparable, max_nesting: false), max_nesting: false)
      sorted = normalized.keys.sort.each_with_object({}) { |key, out| out[key] = normalized[key] }
      digest.update(JSON.generate(sorted, max_nesting: false) << "\n")
    end
    digest.hexdigest
  end

  def contract_identity(manifests)
    {
      "driver_sha256" => file_sha(File.realpath(__FILE__)),
      "ruby" => RUBY_DESCRIPTION,
      "json_version" => JSON::VERSION,
      "oj_version" => Oj::VERSION,
      "sunlight" => sunlight_identity,
      "provenance" => provenance_identity(manifests)
    }
  end

  def engine_identity(engine, scanner:, scanner_source:, fused_root:)
    return {"name" => "oj", "version" => Oj::VERSION} if engine == "oj"

    raise "scanner is not executable: #{scanner}" unless File.executable?(scanner)
    raise "scanner source does not exist: #{scanner_source}" unless File.file?(scanner_source)
    root = File.realpath(fused_root)
    source = File.realpath(scanner_source)
    relative_source = source.start_with?("#{root}/") ? source.delete_prefix("#{root}/") : source
    {
      "name" => "fused_json",
      "repository" => git_identity(root),
      "scanner" => {
        "path" => File.realpath(scanner),
        "bytes" => File.size(scanner),
        "sha256" => file_sha(scanner),
        "source" => relative_source,
        "source_sha256" => file_sha(source)
      }
    }
  end

  def receipt(engine:, corpus:, limit:, scanner:, projection_dir:, explicit_provenance:,
              scanner_source:, fused_root:, frozen_oracle: nil)
    raise "FUSED_JSON_TIC_CORPUS is not a directory: #{corpus}" unless File.directory?(corpus)
    corpus = File.realpath(corpus)
    manifests = load_provenance(provenance_paths(corpus, explicit_provenance))
    contract = contract_identity(manifests)
    names = Dir.children(corpus).grep(/\.json\.gz\z/).sort
    frozen_files = nil
    if frozen_oracle
      raise "only the fused_json pass can consume a frozen Oj receipt" unless engine == "fused_json"
      validate_receipt(frozen_oracle, "oj")
      raise "frozen Oj corpus path differs" unless frozen_oracle["corpus"] == corpus
      raise "frozen Oj item limit differs" unless frozen_oracle["item_limit_bytes"] == limit
      raise "runtime or provenance changed after the Oj receipt was frozen" unless
        frozen_oracle["contract_identity"] == contract
      frozen_names = frozen_oracle.fetch("files").map { |file| file.fetch("name") }
      raise "corpus file list changed after the Oj receipt was frozen" unless names == frozen_names
      frozen_files = frozen_oracle.fetch("files").to_h { |file| [file.fetch("name"), file] }
    elsif engine == "fused_json"
      raise "fused_json receipt requires the frozen Oj receipt"
    end
    files = names.map do |name|
      one_file(File.join(corpus, name), engine: engine, limit: limit,
               scanner: scanner, projection_dir: projection_dir, manifests: manifests,
               frozen: frozen_files && frozen_files.fetch(name))
    end
    {
      "format" => FORMAT,
      "projection_format" => PROJECTION,
      "engine" => engine,
      "engine_identity" => engine_identity(
        engine, scanner: scanner, scanner_source: scanner_source, fused_root: fused_root
      ),
      "contract_identity" => contract,
      "corpus" => corpus,
      "item_limit_bytes" => limit,
      "selection" => "Sunlight::Reconcile::DocStream + crystal:verify matched-id gate",
      "files" => files,
      "corpus_sha256" => corpus_digest(files)
    }
  end

  def comparable(receipt)
    copy = JSON.parse(JSON.generate(receipt, max_nesting: false), max_nesting: false)
    copy.delete("engine")
    copy.delete("engine_identity")
    copy.fetch("files").each { |file| file.delete("projection_path") }
    copy
  end

  def validate_receipt(receipt, expected_engine)
    raise "receipt format #{receipt['format'].inspect} != #{FORMAT}" unless receipt["format"] == FORMAT
    unless receipt["projection_format"] == PROJECTION
      raise "projection format #{receipt['projection_format'].inspect} != #{PROJECTION}"
    end
    raise "receipt engine #{receipt['engine'].inspect} != #{expected_engine}" unless receipt["engine"] == expected_engine
    unless receipt.dig("engine_identity", "name") == expected_engine
      raise "engine identity does not name #{expected_engine}"
    end
    raise "missing contract identity" unless receipt["contract_identity"].is_a?(Hash)
    unless receipt["item_limit_bytes"].is_a?(Integer) && receipt["item_limit_bytes"] >= 0
      raise "invalid item limit"
    end
    unless receipt["selection"] == "Sunlight::Reconcile::DocStream + crystal:verify matched-id gate"
      raise "unknown selection contract"
    end
    if expected_engine == "fused_json"
      scanner = receipt.dig("engine_identity", "scanner")
      unless scanner.is_a?(Hash) && scanner["bytes"].is_a?(Integer) && scanner["bytes"].positive? &&
             scanner["sha256"].to_s.match?(SHA256_RE) &&
             scanner["source_sha256"].to_s.match?(SHA256_RE)
        raise "invalid scanner identity"
      end
    end
    files = receipt.fetch("files")
    names = files.map { |file| file.fetch("name") }
    raise "receipt files are not sorted and unique" unless names == names.sort.uniq
    expected_digest = corpus_digest(files)
    unless receipt["corpus_sha256"] == expected_digest
      raise "receipt corpus digest #{receipt['corpus_sha256']} != recomputed #{expected_digest}"
    end
    files.each do |file|
      unless File.basename(file.fetch("name")) == file["name"] && file["name"].end_with?(".json.gz")
        raise "unsafe corpus filename #{file['name'].inspect}"
      end
      unless file["compressed_bytes"].is_a?(Integer) && file["compressed_bytes"] >= 0 &&
             file["compressed_sha256"].to_s.match?(SHA256_RE)
        raise "#{file['name']}: invalid compressed identity"
      end
      klass = file.fetch("classification")
      status = file.fetch("status")
      if klass == "accepted_in_network"
        unless %w[accepted item_too_large unparseable].include?(status)
          raise "#{file['name']}: invalid accepted-file status #{status.inspect}"
        end
        if status == "accepted"
          counts = file.fetch("counts")
          digests = file.fetch("digests")
          unless counts.keys.sort == %w[prices references] &&
                 counts.values.all? { |count| count.is_a?(Integer) && count >= 0 }
            raise "#{file['name']}: invalid counts"
          end
          unless digests.keys.sort == %w[price_sha256 reference_sha256 semantic_sha256] &&
                 digests.values.all? { |value| value.match?(SHA256_RE) }
            raise "#{file['name']}: invalid semantic digest"
          end
        end
      elsif %w[excluded_index unsupported_allowed_amount].include?(klass)
        raise "#{file['name']}: excluded file was scanned" unless status == "not_scanned"
      else
        raise "#{file['name']}: unknown classification #{klass.inspect}"
      end
    end
    true
  end

  def comparison_difference(left, right)
    return "shared receipt fields differ" unless left.keys.sort == right.keys.sort
    left.each_key do |key|
      next if left[key] == right[key]
      next unless key == "files"
      left_files = left[key].to_h { |file| [file["name"], file] }
      right_files = right[key].to_h { |file| [file["name"], file] }
      name = (left_files.keys | right_files.keys).sort.find { |candidate| left_files[candidate] != right_files[candidate] }
      return "file differs: #{name}"
    end
    "shared receipt field differs: #{left.keys.find { |key| left[key] != right[key] }}"
  end

  def write_atomic(path, string)
    path = File.expand_path(path)
    raise "output already exists: #{path}" if File.exist?(path)
    directory = File.dirname(path)
    raise "output directory does not exist: #{directory}" unless File.directory?(directory)
    partial = "#{path}.partial.#{$$}"
    File.open(partial, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |io|
      io.binmode
      io.write(string)
      io.flush
      io.fsync
    end
    File.rename(partial, path)
  ensure
    FileUtils.rm_f(partial) if defined?(partial) && partial && File.exist?(partial)
  end

  def write_gzip(path, source)
    Zlib::GzipWriter.open(path) do |gz|
      gz.mtime = 0
      gz.write(source)
    end
  end

  def self_test(scanner, scanner_source, fused_root)
    Dir.mktmpdir("fused-json-m6-self-test") do |dir|
      doc = <<~JSON.delete("\n")
        {"in_network":[
          {"billing_code":"OLD","negotiated_rates":[
            {"provider_references":[7,7,"7",99],"negotiated_prices":[
              {"negotiated_rate":123456789012345678901234567890,"nested":{"z":1,"a":2}},
              {"negotiated_rate":1.2300e2}
            ]},
            {"provider_groups":[{"npi":["123"]}],"negotiated_prices":[{"negotiated_rate":-0.0}]},
            {"provider_references":[null,false],"negotiated_prices":[{"negotiated_rate":8}]},
            {"provider_references":[404],"negotiated_prices":[{"negotiated_rate":9}]}
          ],"billing_code":"70553","billing_code_type":"CPT","negotiation_arrangement":"ffs"}
        ],"provider_references":[
          {"provider_group_id":7,"provider_groups":[{"npi":["1","1"]}]},
          "drop",{"provider_group_id":"7"},{"provider_group_id":null},{"provider_group_id":false}
        ],"reporting_entity_name":"Fixture Plan"}
      JSON
      write_gzip(File.join(dir, "a-in-network.json.gz"), doc)
      write_gzip(File.join(dir, "b-allowed-amounts.json.gz"), '{"out_of_network":[]}')
      write_gzip(File.join(dir, "c-opaque.json.gz"), '{"out_of_network":[]}')
      write_gzip(File.join(dir, "wy-index-2026-08-01.json.gz"), '{"reporting_structure":[]}')
      File.write(File.join(dir, "z-malformed.json.gz"), '{"in_network":[')
      projections = File.join(dir, "projections")
      oj = receipt(engine: "oj", corpus: dir, limit: DEFAULT_LIMIT,
                   scanner: scanner, projection_dir: projections, explicit_provenance: [],
                   scanner_source: scanner_source, fused_root: fused_root)
      fused = receipt(engine: "fused_json", corpus: dir, limit: DEFAULT_LIMIT,
                      scanner: scanner, projection_dir: projections, explicit_provenance: [],
                      scanner_source: scanner_source, fused_root: fused_root, frozen_oracle: oj)
      validate_receipt(oj, "oj")
      validate_receipt(fused, "fused_json")
      unless comparable(oj) == comparable(fused)
        warn JSON.pretty_generate({"oracle" => oj, "fused" => fused})
        raise "self-test mismatch"
      end
      in_network = oj.fetch("files").find { |file| file["name"] == "a-in-network.json.gz" }
      raise "truthy provider-id selection drift" unless in_network.dig("counts", "references") == 4 &&
                                                        in_network.dig("counts", "prices") == 3
      opaque = oj.fetch("files").find { |file| file["name"] == "c-opaque.json.gz" }
      unless opaque["classification"] == "unsupported_allowed_amount" &&
             opaque["classification_evidence"] == "top-level:out_of_network"
        raise "opaque allowed-amount classification drift"
      end

      cap_dir = File.join(dir, "cap")
      FileUtils.mkdir_p(cap_dir)
      write_gzip(File.join(cap_dir, "cap.json.gz"),
                 '{"provider_references":[{"npi":["1","2","3"]}],"in_network":[]}')
      cap_results = [310, 309].to_h do |cap|
        cap_oj = receipt(engine: "oj", corpus: cap_dir, limit: cap,
                         scanner: scanner, projection_dir: nil, explicit_provenance: [],
                         scanner_source: scanner_source, fused_root: fused_root)
        cap_fused = receipt(engine: "fused_json", corpus: cap_dir, limit: cap,
                            scanner: scanner, projection_dir: nil, explicit_provenance: [],
                            scanner_source: scanner_source, fused_root: fused_root,
                            frozen_oracle: cap_oj)
        raise "cap #{cap} mismatch" unless comparable(cap_oj) == comparable(cap_fused)
        [cap, cap_oj.dig("files", 0, "status")]
      end
      raise "310-byte cap should pass" unless cap_results[310] == "accepted"
      raise "309-byte cap should fail" unless cap_results[309] == "item_too_large"
      puts JSON.pretty_generate({"ok" => true, "corpus" => dir,
                                 "corpus_sha256" => oj["corpus_sha256"],
                                 "cap_status" => cap_results,
                                 "files" => oj["files"]})
    end
  end
end

command = ARGV.shift || abort("usage: #{$PROGRAM_NAME} oracle|fused|compare|self-test [options]")
default_fused_root = ENV.fetch("FUSED_JSON_ROOT", File.expand_path("..", __dir__))
options = {
  corpus: ENV["FUSED_JSON_TIC_CORPUS"],
  scanner: ENV["FUSED_JSON_SCAN_BIN"],
  scanner_source: ENV["FUSED_JSON_SCAN_SOURCE"],
  fused_root: default_fused_root,
  limit: FusedJSONSunlightCompat::DEFAULT_LIMIT,
  output: nil,
  projection_dir: nil,
  oracle_receipt: nil,
  provenance: []
}
OptionParser.new do |opts|
  opts.on("--corpus DIR") { |v| options[:corpus] = v }
  opts.on("--scanner PATH") { |v| options[:scanner] = v }
  opts.on("--scanner-source PATH") { |v| options[:scanner_source] = v }
  opts.on("--fused-root DIR") { |v| options[:fused_root] = v }
  opts.on("--provenance PATH") { |v| options[:provenance] << v }
  opts.on("--item-limit-bytes N", Integer) { |v| options[:limit] = v }
  opts.on("--output PATH") { |v| options[:output] = v }
  opts.on("--projection-dir DIR") { |v| options[:projection_dir] = v }
  opts.on("--oracle-receipt PATH") { |v| options[:oracle_receipt] = v }
end.parse!(ARGV)
options[:scanner_source] ||= File.join(options[:fused_root], "bench", "sunlight_compat_scan.cr")

case command
when "oracle", "fused"
  corpus = options[:corpus] || abort("set FUSED_JSON_TIC_CORPUS or pass --corpus")
  engine = command == "oracle" ? "oj" : "fused_json"
  frozen_oracle = nil
  if engine == "fused_json"
    options[:scanner] ||= abort("fused requires --scanner BIN or FUSED_JSON_SCAN_BIN")
    receipt_path = options[:oracle_receipt] || abort("fused requires --oracle-receipt OJ_JSON")
    frozen_oracle = JSON.parse(File.read(receipt_path), max_nesting: false)
  end
  receipt = FusedJSONSunlightCompat.receipt(
    engine: engine, corpus: corpus, limit: options[:limit], scanner: options[:scanner],
    projection_dir: options[:projection_dir], explicit_provenance: options[:provenance],
    scanner_source: options[:scanner_source], fused_root: options[:fused_root],
    frozen_oracle: frozen_oracle
  )
  FusedJSONSunlightCompat.validate_receipt(receipt, engine)
  json = JSON.pretty_generate(receipt, max_nesting: false)
  if options[:output]
    FusedJSONSunlightCompat.write_atomic(options[:output], "#{json}\n")
  else
    puts(json)
  end
when "compare"
  left, right = ARGV
  abort("compare requires ORACLE_JSON FUSED_JSON") unless left && right
  a = JSON.parse(File.read(left))
  b = JSON.parse(File.read(right))
  FusedJSONSunlightCompat.validate_receipt(a, "oj")
  FusedJSONSunlightCompat.validate_receipt(b, "fused_json")
  left_comparable = FusedJSONSunlightCompat.comparable(a)
  right_comparable = FusedJSONSunlightCompat.comparable(b)
  ok = left_comparable == right_comparable
  puts JSON.generate({"ok" => ok, "oracle_corpus_sha256" => a["corpus_sha256"],
                      "fused_corpus_sha256" => b["corpus_sha256"],
                      "difference" => ok ? nil : FusedJSONSunlightCompat.comparison_difference(
                        left_comparable, right_comparable
                      )})
  exit 1 unless ok
when "self-test"
  options[:scanner] ||= abort("self-test requires --scanner BIN or FUSED_JSON_SCAN_BIN")
  FusedJSONSunlightCompat.self_test(
    options[:scanner], options[:scanner_source], options[:fused_root]
  )
else
  abort("unknown command #{command}")
end
