# frozen_string_literal: true

oj_root = ENV.fetch('OJ_ROOT')
$LOAD_PATH.unshift(File.join(oj_root, 'lib'), File.join(oj_root, 'ext'))
require 'oj'

unless $LOADED_FEATURES.grep(/oj\.so\z/).any? { |path| path.start_with?(oj_root) }
  abort "expected Oj extension from #{oj_root}, loaded: #{$LOADED_FEATURES.grep(/oj\.so\z/).inspect}"
end

abort "usage: #{PROGRAM_NAME} JSON_FILE [JSON_FILE ...]" if ARGV.empty?

Oj.default_options = Oj.default_options.merge(
  mode: :strict,
  cache_keys: false,
  cache_str: -1,
  bigdecimal_load: :float,
  symbol_keys: false
)

warmup = ENV.fetch('FUSED_JSON_BENCH_WARMUP', '1').to_f
duration = ENV.fetch('FUSED_JSON_BENCH_TIME', '3').to_f

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def measure(warmup, duration)
  deadline = now + warmup
  sink = nil
  sink = yield while now < deadline

  GC.start
  allocated_before = GC.stat(:total_allocated_objects)
  count = 0
  started = now
  deadline = started + duration
  while now < deadline
    sink = yield
    count += 1
  end
  elapsed = now - started
  allocated = GC.stat(:total_allocated_objects) - allocated_before

  raise 'benchmark result was lost' if sink.nil?

  [count / elapsed, allocated.to_f / count]
end

warn "Ruby #{RUBY_VERSION}; Oj #{Oj::VERSION}; #{$LOADED_FEATURES.grep(/oj\.so\z/).first}"

usual_parser = Oj::Parser.usual
usual_parser.just_one = true
usual_parser.cache_keys = false
usual_parser.cache_strings = 0
usual_parser.decimal = :float

ARGV.each do |path|
  source = File.binread(path)
  expected = Oj.strict_load(source)
  actual = usual_parser.parse(source)
  abort "Oj parser semantic mismatch for #{path}" unless actual == expected

  puts
  puts "#{File.basename(path)}: #{source.bytesize} bytes"
  {
    'Oj.strict_load'       => -> { Oj.strict_load(source) },
    'Oj::Parser.usual'     => -> { usual_parser.parse(source) },
  }.each do |label, action|
    ips, objects_per_op = measure(warmup, duration, &action)
    mib_per_second = ips * source.bytesize / 1_048_576.0
    printf "  %-18s %9.2f MiB/s  %9.2f ops/s  %9.0f objects/op\n",
           label, mib_per_second, ips, objects_per_op
  end
end
