record DocExample, path : String, line : Int32, source : String

files = ["README.md"] + Dir["docs/**/*.md"].sort
examples = [] of DocExample

files.each do |path|
  opening_line = nil
  source = String::Builder.new

  File.open(path) do |file|
    file.each_line.with_index(1) do |line, line_number|
      if opening_line
        if line.starts_with?("```")
          examples << DocExample.new(path, opening_line.not_nil!, source.to_s)
          opening_line = nil
          source = String::Builder.new
        else
          source << line << '\n'
        end
      elsif line.strip == "```crystal"
        opening_line = line_number
      end
    end
  end

  abort "unterminated Crystal fence in #{path}:#{opening_line}" if opening_line
end

abort "no Crystal documentation examples found" if examples.empty?

crystal_path = IO::Memory.new
status = Process.run(
  "crystal",
  ["env", "CRYSTAL_PATH"],
  output: crystal_path,
  error: Process::Redirect::Inherit
)
abort "could not determine CRYSTAL_PATH" unless status.success?

search_path = [File.expand_path("src"), crystal_path.to_s.strip].join(Process::PATH_DELIMITER)

examples.each_with_index(1) do |example, index|
  tempfile = File.tempfile("fused-json-doc-#{index}-", ".cr")
  begin
    tempfile << example.source
    tempfile.flush

    output = IO::Memory.new
    status = Process.run(
      "crystal",
      ["build", "--no-codegen", "--error-on-warnings", tempfile.path],
      env: {"CRYSTAL_PATH" => search_path},
      output: output,
      error: output
    )
    unless status.success?
      STDERR.puts "documentation example failed: #{example.path}:#{example.line}"
      STDERR.print output.to_s
      exit 1
    end
  ensure
    tempfile.delete
  end
end

puts "Compiled #{examples.size} documentation examples"
