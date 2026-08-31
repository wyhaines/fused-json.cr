#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {spawnSync} from "node:child_process";

const RECEIPT = "fused-json-streaming-performance-campaign";
const VERSION = 1;
const TASKSET = "/usr/bin/taskset";
const QUIET_SAMPLE_MILLISECONDS = 1_000;

class UsageError extends Error {}

function entry(id, profile, consumer, transport, options = {}) {
  return Object.freeze({
    id,
    profile,
    consumer,
    transport,
    values: options.values ?? 1_000,
    token_bytes: options.token_bytes ?? 512,
    leading_padding: options.leading_padding ?? 0,
    buffer_size: options.buffer_size ?? 32 * 1024,
    chunk_size: options.chunk_size ?? 4 * 1024,
    cache_keys: options.cache_keys ?? false,
    limit_policy: options.limit_policy ?? "none",
  });
}

const MATRICES = Object.freeze({
  attribution: Object.freeze([
    entry("integers-string", "integers", "pull-materialize", "string", {values: 20_000}),
    entry("integers-io", "integers", "pull-materialize", "io-memory", {values: 20_000}),
    entry("integers-chunked", "integers", "pull-materialize", "chunked-memory", {values: 20_000}),
    entry("floats-string", "floats", "pull-materialize", "string", {values: 20_000}),
    entry("floats-io", "floats", "pull-materialize", "io-memory", {values: 20_000}),
    entry("floats-chunked", "floats", "pull-materialize", "chunked-memory", {values: 20_000}),
    entry("plain-short-string", "plain-short", "pull-materialize", "string", {values: 10_000}),
    entry("plain-short-io", "plain-short", "pull-materialize", "io-memory", {values: 10_000}),
    entry("plain-short-chunked", "plain-short", "pull-materialize", "chunked-memory", {values: 10_000}),

    entry("plain-long-string", "plain-long", "pull-materialize", "string"),
    entry("plain-long-io", "plain-long", "pull-materialize", "io-memory"),
    entry("plain-long-chunked", "plain-long", "pull-materialize", "chunked-memory"),
    entry("raw-utf8-string", "raw-utf8", "pull-materialize", "string"),
    entry("raw-utf8-io", "raw-utf8", "pull-materialize", "io-memory"),
    entry("raw-utf8-chunked", "raw-utf8", "pull-materialize", "chunked-memory"),
    entry("escape-sparse-string", "escape-sparse", "pull-materialize", "string"),
    entry("escape-sparse-io", "escape-sparse", "pull-materialize", "io-memory"),
    entry("escape-sparse-chunked", "escape-sparse", "pull-materialize", "chunked-memory"),
    entry("escape-dense-string", "escape-dense", "pull-materialize", "string"),
    entry("escape-dense-io", "escape-dense", "pull-materialize", "io-memory"),
    entry("escape-dense-chunked", "escape-dense", "pull-materialize", "chunked-memory"),
    entry("unicode-escape-string", "unicode-escape", "pull-materialize", "string"),
    entry("unicode-escape-io", "unicode-escape", "pull-materialize", "io-memory"),
    entry("unicode-escape-chunked", "unicode-escape", "pull-materialize", "chunked-memory"),
    entry("surrogate-escape-string", "surrogate-escape", "pull-materialize", "string"),
    entry("surrogate-escape-io", "surrogate-escape", "pull-materialize", "io-memory"),
    entry("surrogate-escape-chunked", "surrogate-escape", "pull-materialize", "chunked-memory"),

    entry("plain-boundary-io", "plain-long", "pull-materialize", "io-memory", {values: 8, token_bytes: 65_536}),
    entry("plain-boundary-chunked", "plain-long", "pull-materialize", "chunked-memory", {values: 8, token_bytes: 65_536}),
    entry("sparse-boundary-io", "escape-sparse", "pull-materialize", "io-memory", {values: 8, token_bytes: 65_536}),
    entry("sparse-boundary-chunked", "escape-sparse", "pull-materialize", "chunked-memory", {values: 8, token_bytes: 65_536}),
    entry("dense-boundary-io", "escape-dense", "pull-materialize", "io-memory", {values: 8, token_bytes: 65_536}),
    entry("dense-boundary-chunked", "escape-dense", "pull-materialize", "chunked-memory", {values: 8, token_bytes: 65_536}),
    entry("unicode-boundary-io", "unicode-escape", "pull-materialize", "io-memory", {values: 8, token_bytes: 65_536}),
    entry("unicode-boundary-chunked", "unicode-escape", "pull-materialize", "chunked-memory", {values: 8, token_bytes: 65_536}),
    entry("surrogate-boundary-io", "surrogate-escape", "pull-materialize", "io-memory", {values: 8, token_bytes: 65_536}),
    entry("surrogate-boundary-chunked", "surrogate-escape", "pull-materialize", "chunked-memory", {values: 8, token_bytes: 65_536}),

    entry("sparse-skip", "escape-sparse", "pull-skip", "io-memory"),
    entry("sparse-tree", "escape-sparse", "dynamic-tree", "io-memory"),
    entry("sparse-typed", "escape-sparse", "typed", "io-memory"),
    entry("sparse-doc-dynamic", "escape-sparse", "document-dynamic", "io-memory"),
    entry("sparse-doc-typed", "escape-sparse", "document-typed", "io-memory"),

    entry("key-repeated-plain", "key-repeated-plain", "dynamic-tree", "io-memory", {values: 2_000, token_bytes: 96}),
    entry("key-repeated-plain-cached", "key-repeated-plain", "dynamic-tree", "io-memory", {values: 2_000, token_bytes: 96, cache_keys: true}),
    entry("key-repeated-escaped", "key-repeated-escaped", "dynamic-tree", "io-memory", {values: 2_000, token_bytes: 96}),
    entry("key-repeated-escaped-cached", "key-repeated-escaped", "dynamic-tree", "io-memory", {values: 2_000, token_bytes: 96, cache_keys: true}),
    entry("key-unique-plain", "key-unique-plain", "dynamic-tree", "io-memory", {values: 2_000, token_bytes: 96}),
    entry("key-unique-escaped", "key-unique-escaped", "dynamic-tree", "io-memory", {values: 2_000, token_bytes: 96}),

    entry("sparse-token-limit", "escape-sparse", "pull-materialize", "io-memory", {limit_policy: "token"}),
    entry("sparse-document-limit", "escape-sparse", "pull-materialize", "io-memory", {limit_policy: "document"}),
    entry("sparse-duplicate-check", "escape-sparse", "pull-materialize", "io-memory", {limit_policy: "duplicate-keys"}),
  ]),

  escaped: Object.freeze([
    entry("sparse-string", "escape-sparse", "pull-materialize", "string"),
    entry("sparse-io", "escape-sparse", "pull-materialize", "io-memory"),
    entry("sparse-chunked", "escape-sparse", "pull-materialize", "chunked-memory"),
    entry("dense-string", "escape-dense", "pull-materialize", "string"),
    entry("dense-io", "escape-dense", "pull-materialize", "io-memory"),
    entry("dense-chunked", "escape-dense", "pull-materialize", "chunked-memory"),
    entry("unicode-string", "unicode-escape", "pull-materialize", "string"),
    entry("unicode-io", "unicode-escape", "pull-materialize", "io-memory"),
    entry("unicode-chunked", "unicode-escape", "pull-materialize", "chunked-memory"),
    entry("surrogate-string", "surrogate-escape", "pull-materialize", "string"),
    entry("surrogate-io", "surrogate-escape", "pull-materialize", "io-memory"),
    entry("surrogate-chunked", "surrogate-escape", "pull-materialize", "chunked-memory"),
    entry("sparse-tree", "escape-sparse", "dynamic-tree", "io-memory"),
    entry("sparse-typed", "escape-sparse", "typed", "io-memory"),
    entry("sparse-doc-dynamic", "escape-sparse", "document-dynamic", "io-memory"),
    entry("sparse-doc-typed", "escape-sparse", "document-typed", "io-memory"),
  ]),

  boundary: Object.freeze([
    entry("plain-io", "plain-long", "pull-materialize", "io-memory", {values: 8, token_bytes: 65_536}),
    entry("plain-chunked", "plain-long", "pull-materialize", "chunked-memory", {values: 8, token_bytes: 65_536}),
    entry("utf8-io", "raw-utf8", "pull-materialize", "io-memory", {values: 8, token_bytes: 65_536}),
    entry("utf8-chunked", "raw-utf8", "pull-materialize", "chunked-memory", {values: 8, token_bytes: 65_536}),
    entry("sparse-io", "escape-sparse", "pull-materialize", "io-memory", {values: 8, token_bytes: 65_536}),
    entry("sparse-chunked", "escape-sparse", "pull-materialize", "chunked-memory", {values: 8, token_bytes: 65_536}),
    entry("dense-io", "escape-dense", "pull-materialize", "io-memory", {values: 8, token_bytes: 65_536}),
    entry("dense-chunked", "escape-dense", "pull-materialize", "chunked-memory", {values: 8, token_bytes: 65_536}),
    entry("number-io", "floats", "pull-materialize", "io-memory", {values: 20_000}),
    entry("number-chunked", "floats", "pull-materialize", "chunked-memory", {values: 20_000}),
  ]),

  smoke: Object.freeze([
    entry("plain", "plain-long", "pull-materialize", "io-memory", {values: 16, token_bytes: 96}),
    entry("escaped", "escape-dense", "typed", "chunked-memory", {values: 16, token_bytes: 96, chunk_size: 7}),
    entry("documents", "key-repeated-escaped", "document-typed", "io-memory", {values: 16, token_bytes: 96, cache_keys: true}),
  ]),
});

function usage() {
  return [
    "usage:",
    "  scripts/streaming_performance_campaign.mjs --mode=collect --output=DIR",
    "    --binary=PATH --commit=40hex [--matrix=attribution] [--samples=3]",
    "  scripts/streaming_performance_campaign.mjs --mode=compare --output=DIR",
    "    --baseline=PATH --baseline-commit=40hex --candidate=PATH",
    "    --candidate-commit=40hex [--matrix=escaped] [--pairs=5]",
    "  All campaigns require one-minute load <= --max-load (default 2)",
    "    and selected-core sibling idle >= --min-core-idle-percent (default 90).",
    "  scripts/streaming_performance_campaign.mjs --self-audit",
  ].join("\n");
}

function parseArgs(args) {
  if (args.length === 1 && args[0] === "--self-audit") return {self_audit: true};

  const values = {};
  for (const arg of args) {
    const match = arg.match(/^--([a-z-]+)=(.+)$/);
    if (match === null) throw new UsageError(`invalid argument: ${arg}`);
    if (Object.hasOwn(values, match[1])) throw new UsageError(`duplicate --${match[1]}`);
    values[match[1]] = match[2];
  }

  const mode = values.mode;
  if (mode !== "collect" && mode !== "compare") {
    throw new UsageError("--mode must be collect or compare");
  }
  const common = new Set([
    "allocations", "cpu", "latency-iterations", "matrix", "mode", "output",
    "max-load", "min-core-idle-percent", "time", "warmup",
  ]);
  const permitted = mode === "collect" ?
    new Set([...common, "binary", "commit", "samples"]) :
    new Set([...common, "baseline", "baseline-commit", "candidate", "candidate-commit", "pairs"]);
  for (const key of Object.keys(values)) {
    if (!permitted.has(key)) throw new UsageError(`--${key} is not valid in ${mode} mode`);
  }

  if (!values.output) throw new UsageError("--output is required");
  const matrix = values.matrix ?? (mode === "collect" ? "attribution" : "escaped");
  if (!Object.hasOwn(MATRICES, matrix)) {
    throw new UsageError(`--matrix must be one of ${Object.keys(MATRICES).join(", ")}`);
  }

  const parsed = {
    self_audit: false,
    mode,
    output: path.resolve(values.output),
    matrix,
    cpu: nonnegativeInteger(values.cpu ?? "4", "--cpu"),
    max_load: nonnegativeNumber(values["max-load"] ?? "2", "--max-load"),
    min_core_idle_percent: percentage(
      values["min-core-idle-percent"] ?? "90",
      "--min-core-idle-percent",
    ),
    warmup: nonnegativeNumber(values.warmup ?? "0.5", "--warmup"),
    time: positiveNumber(values.time ?? "1", "--time"),
    allocations: positiveInteger(values.allocations ?? "3", "--allocations"),
    latency_iterations: positiveInteger(values["latency-iterations"] ?? "50", "--latency-iterations"),
  };
  if (parsed.cpu >= os.cpus().length) {
    throw new UsageError(`--cpu must be below the ${os.cpus().length} available logical CPUs`);
  }

  if (mode === "collect") {
    if (!values.binary || !values.commit) {
      throw new UsageError("collect mode requires --binary and --commit");
    }
    parsed.binary = executablePath(values.binary, "--binary");
    parsed.commit = commit(values.commit, "--commit");
    parsed.samples = positiveInteger(values.samples ?? "3", "--samples");
  } else {
    for (const key of ["baseline", "baseline-commit", "candidate", "candidate-commit"]) {
      if (!values[key]) throw new UsageError(`compare mode requires --${key}`);
    }
    parsed.baseline = executablePath(values.baseline, "--baseline");
    parsed.baseline_commit = commit(values["baseline-commit"], "--baseline-commit");
    parsed.candidate = executablePath(values.candidate, "--candidate");
    parsed.candidate_commit = commit(values["candidate-commit"], "--candidate-commit");
    parsed.pairs = positiveInteger(values.pairs ?? "5", "--pairs");
  }
  return parsed;
}

function positiveInteger(value, name) {
  if (!/^\d+$/.test(value) || Number(value) < 1 || !Number.isSafeInteger(Number(value))) {
    throw new UsageError(`${name} must be a positive integer`);
  }
  return Number(value);
}

function nonnegativeInteger(value, name) {
  if (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value))) {
    throw new UsageError(`${name} must be a nonnegative integer`);
  }
  return Number(value);
}

function positiveNumber(value, name) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0) throw new UsageError(`${name} must be positive`);
  return number;
}

function nonnegativeNumber(value, name) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) throw new UsageError(`${name} must not be negative`);
  return number;
}

function percentage(value, name) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0 || number > 100) {
    throw new UsageError(`${name} must be between 0 and 100`);
  }
  return number;
}

function executablePath(value, name) {
  const resolved = fs.realpathSync(value);
  try {
    fs.accessSync(resolved, fs.constants.X_OK);
  } catch {
    throw new UsageError(`${name} is not executable: ${resolved}`);
  }
  return resolved;
}

function commit(value, name) {
  if (!/^[0-9a-f]{40}$/.test(value)) throw new UsageError(`${name} must be a full lowercase SHA`);
  return value;
}

function sha256(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function optionalText(file) {
  try {
    return fs.readFileSync(file, "utf8").trim();
  } catch {
    return null;
  }
}

function expandCpuList(value) {
  const cpus = [];
  for (const segment of value.split(",")) {
    const match = segment.match(/^(\d+)(?:-(\d+))?$/);
    if (match === null) throw new Error(`invalid CPU list: ${value}`);
    const first = Number(match[1]);
    const last = Number(match[2] ?? match[1]);
    if (last < first) throw new Error(`invalid CPU range: ${segment}`);
    for (let cpu = first; cpu <= last; cpu += 1) cpus.push(cpu);
  }
  return [...new Set(cpus)];
}

function coreLogicalCpus(cpu) {
  const siblings = optionalText(
    `/sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list`,
  );
  return siblings === null ? [cpu] : expandCpuList(siblings);
}

function cpuTimeSnapshots(cpus) {
  const lines = fs.readFileSync("/proc/stat", "utf8").split("\n");
  return Object.fromEntries(cpus.map((cpu) => {
    const prefix = `cpu${cpu}`;
    const line = lines.find((candidate) => candidate.startsWith(`${prefix} `));
    if (!line) throw new Error(`/proc/stat has no ${prefix} entry`);
    const fields = line.trim().split(/\s+/).slice(1).map(Number);
    if (fields.length < 5 || fields.some((field) => !Number.isFinite(field))) {
      throw new Error(`/proc/stat has invalid ${prefix} counters`);
    }
    return [cpu, {total: fields.reduce((sum, field) => sum + field, 0), idle: fields[3] + fields[4]}];
  }));
}

function idlePercent(before, after) {
  const total = after.total - before.total;
  const idle = after.idle - before.idle;
  if (total <= 0 || idle < 0 || idle > total) throw new Error("invalid CPU utilization interval");
  return idle * 100 / total;
}

function blockFor(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function quietHostGate(options) {
  const load = os.loadavg()[0];
  const logicalCpus = coreLogicalCpus(options.cpu);
  const before = cpuTimeSnapshots(logicalCpus);
  blockFor(QUIET_SAMPLE_MILLISECONDS);
  const after = cpuTimeSnapshots(logicalCpus);
  const idle = logicalCpus.map((cpu) => ({
    cpu,
    idle_percent: idlePercent(before[cpu], after[cpu]),
  }));
  const issues = [];
  if (load > options.max_load) {
    issues.push(`one-minute load ${load.toFixed(2)} exceeds ${options.max_load}`);
  }
  for (const sample of idle) {
    if (sample.idle_percent < options.min_core_idle_percent) {
      issues.push(`CPU ${sample.cpu} idle ${sample.idle_percent.toFixed(1)}% is below ${options.min_core_idle_percent}%`);
    }
  }
  if (issues.length > 0) throw new Error(`quiet-host gate failed: ${issues.join("; ")}`);

  const cpufreq = `/sys/devices/system/cpu/cpu${options.cpu}/cpufreq`;
  return {
    one_minute_load: load,
    maximum_one_minute_load: options.max_load,
    sample_milliseconds: QUIET_SAMPLE_MILLISECONDS,
    minimum_core_idle_percent: options.min_core_idle_percent,
    logical_cpu_idle: idle,
    scaling_driver: optionalText(`${cpufreq}/scaling_driver`),
    scaling_governor: optionalText(`${cpufreq}/scaling_governor`),
    energy_performance_preference: optionalText(`${cpufreq}/energy_performance_preference`),
  };
}

function fileIdentity(file) {
  const contents = fs.readFileSync(file);
  const stats = fs.statSync(file);
  return {
    realpath: fs.realpathSync(file),
    bytes: stats.size,
    sha256: sha256(contents),
  };
}

function writeJson(file, value) {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, {encoding: "utf8", flag: "wx"});
}

function updatePartial(file, value) {
  const temporary = `${file}.new`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  fs.renameSync(temporary, file);
}

function appendJournal(file, value) {
  fs.appendFileSync(file, `${JSON.stringify(value)}\n`, "utf8");
}

function childEnvironment(entryValue, options, commitValue, pairId, orderPosition) {
  return {
    PATH: "/usr/bin:/bin",
    LANG: "C",
    LC_ALL: "C",
    TZ: "UTC",
    GC_NPROCS: "1",
    GC_MARKERS: "1",
    FUSED_JSON_BENCH_COMMIT: commitValue,
    FUSED_JSON_BENCH_PAIR_ID: pairId,
    FUSED_JSON_BENCH_ORDER_POSITION: orderPosition,
    FUSED_JSON_BENCH_WARMUP: String(options.warmup),
    FUSED_JSON_BENCH_TIME: String(options.time),
    FUSED_JSON_BENCH_ALLOCATIONS: String(options.allocations),
    FUSED_JSON_TOKEN_LATENCY_ITERATIONS: String(options.latency_iterations),
    FUSED_JSON_TOKEN_PROFILE: entryValue.profile,
    FUSED_JSON_TOKEN_CONSUMER: entryValue.consumer,
    FUSED_JSON_TOKEN_TRANSPORT: entryValue.transport,
    FUSED_JSON_TOKEN_LIMITS: entryValue.limit_policy,
    FUSED_JSON_TOKEN_CACHE_KEYS: entryValue.cache_keys ? "1" : "0",
    FUSED_JSON_TOKEN_VALUES: String(entryValue.values),
    FUSED_JSON_TOKEN_BYTES: String(entryValue.token_bytes),
    FUSED_JSON_TOKEN_LEADING_PADDING: String(entryValue.leading_padding),
    FUSED_JSON_TOKEN_BUFFER: String(entryValue.buffer_size),
    FUSED_JSON_TOKEN_CHUNK: String(entryValue.chunk_size),
  };
}

function parseReceipt(stdout) {
  const lines = stdout.trim().split("\n").reverse();
  const line = lines.find((candidate) => candidate.startsWith("{"));
  if (!line) throw new Error("benchmark output has no JSON receipt");
  let receipt;
  try {
    receipt = JSON.parse(line);
  } catch (error) {
    throw new Error(`benchmark receipt is invalid JSON: ${error.message}`);
  }
  return receipt;
}

function receiptIssues(receipt, entryValue, options, commitValue, pairId, orderPosition) {
  const issues = [];
  const check = (condition, message) => { if (!condition) issues.push(message); };
  check(receipt?.receipt === "fused-json-streaming-token-cost" && receipt?.version === 1,
    "wrong receipt identity");
  check(receipt?.release_build === true, "benchmark was not a release build");
  check(receipt?.fused_json_commit === commitValue, "commit mismatch");
  check(receipt?.profile === entryValue.profile && receipt?.consumer === entryValue.consumer &&
    receipt?.transport === entryValue.transport, "workload identity mismatch");
  check(receipt?.values === entryValue.values && receipt?.requested_token_bytes === entryValue.token_bytes &&
    receipt?.leading_padding === entryValue.leading_padding, "fixture parameters differ");
  check(receipt?.buffer_size === entryValue.buffer_size, "buffer size differs");
  const expectedChunks = entryValue.transport === "chunked-memory" ? [entryValue.chunk_size] : [];
  check(JSON.stringify(receipt?.chunk_pattern) === JSON.stringify(expectedChunks), "chunk pattern differs");
  check(receipt?.cache_keys === entryValue.cache_keys && receipt?.limit_policy === entryValue.limit_policy,
    "cache or limit policy differs");
  check(receipt?.warmup_seconds === options.warmup && receipt?.calculation_seconds === options.time &&
    receipt?.allocation_iterations === options.allocations &&
    receipt?.latency_iterations === options.latency_iterations, "measurement parameters differ");
  check(receipt?.pair_id === pairId && receipt?.order_position === orderPosition,
    "pair identity differs");
  check(receipt?.gc_nprocs === "1" && receipt?.gc_markers === "1", "GC settings differ");
  check(Number.isFinite(receipt?.iterations_per_second) && receipt.iterations_per_second > 0,
    "invalid throughput");
  check(Number.isFinite(receipt?.relative_stddev_percent) && receipt.relative_stddev_percent >= 0,
    "invalid RSD");
  check(Number.isSafeInteger(receipt?.managed_bytes_per_operation) &&
    receipt.managed_bytes_per_operation >= 0, "invalid allocation result");
  check(Number.isFinite(receipt?.one_value_microseconds) && receipt.one_value_microseconds > 0,
    "invalid one-value latency");
  check(/^[0-9a-f]{64}$/.test(receipt?.source_sha256 ?? "") &&
    /^[0-9a-f]{64}$/.test(receipt?.benchmark_source_sha256 ?? "") &&
    /^[0-9a-f]{64}$/.test(receipt?.benchmark_support_sha256 ?? ""), "invalid source identity");
  if (entryValue.transport === "string") {
    check(receipt?.preflight_read_calls === 0 && receipt?.preflight_bytes_read === 0,
      "String transport unexpectedly read an IO");
  } else {
    check(receipt?.preflight_read_calls > 0 && receipt?.preflight_bytes_read === receipt?.source_bytes,
      "streaming preflight did not consume its IO");
  }
  return issues;
}

function runChild(binary, commitValue, entryValue, options, pairId, orderPosition, directory) {
  const stem = `${pairId}--${entryValue.id}--${orderPosition}`;
  const stdoutFile = path.join(directory, `${stem}.stdout.txt`);
  const stderrFile = path.join(directory, `${stem}.stderr.txt`);
  const receiptFile = path.join(directory, `${stem}.receipt.json`);
  const command = [TASKSET, "-c", String(options.cpu), binary];
  const startedAt = new Date().toISOString();
  const loadBefore = os.loadavg();
  const result = spawnSync(command[0], command.slice(1), {
    encoding: "utf8",
    env: childEnvironment(entryValue, options, commitValue, pairId, orderPosition),
    maxBuffer: 32 * 1024 * 1024,
    timeout: Math.ceil((options.warmup + options.time) * 1_000) + 120_000,
  });
  const finishedAt = new Date().toISOString();
  fs.writeFileSync(stdoutFile, result.stdout ?? "", {encoding: "utf8", flag: "wx"});
  fs.writeFileSync(stderrFile, result.stderr ?? "", {encoding: "utf8", flag: "wx"});
  if (result.error) throw new Error(`${stem} failed to start: ${result.error.message}`);
  if (result.status !== 0) throw new Error(`${stem} exited with status ${result.status}`);

  const receipt = parseReceipt(result.stdout);
  const issues = receiptIssues(receipt, entryValue, options, commitValue, pairId, orderPosition);
  if (issues.length > 0) throw new Error(`${stem} receipt failed validation: ${issues.join("; ")}`);
  writeJson(receiptFile, receipt);
  return {
    pair_id: pairId,
    entry_id: entryValue.id,
    order_position: orderPosition,
    started_at: startedAt,
    finished_at: finishedAt,
    load_average_before: loadBefore,
    load_average_after: os.loadavg(),
    stdout: path.basename(stdoutFile),
    stderr: path.basename(stderrFile),
    receipt: path.basename(receiptFile),
    measurement: receipt,
  };
}

function median(values) {
  if (values.length === 0) throw new Error("median requires values");
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle];
}

function geometricMean(values) {
  if (values.length === 0 || values.some((value) => !Number.isFinite(value) || value <= 0)) {
    throw new Error("geometric mean requires positive finite values");
  }
  return Math.exp(values.reduce((sum, value) => sum + Math.log(value), 0) / values.length);
}

function collectSummary(entries, observations) {
  const profiles = entries.map((entryValue) => {
    const selected = observations.filter((item) => item.entry_id === entryValue.id);
    return {
      entry_id: entryValue.id,
      samples: selected.length,
      median_mib_per_second: median(selected.map((item) => item.measurement.mib_per_second)),
      median_nanoseconds_per_byte: median(selected.map((item) => item.measurement.nanoseconds_per_byte)),
      median_managed_bytes_per_operation: median(selected.map((item) =>
        item.measurement.managed_bytes_per_operation)),
      median_one_value_microseconds: median(selected.map((item) =>
        item.measurement.one_value_microseconds)),
      maximum_rsd_percent: Math.max(...selected.map((item) => item.measurement.relative_stddev_percent)),
    };
  });
  return {
    mode: "collect",
    profiles,
    noisy_observations: observations.filter((item) =>
      item.measurement.relative_stddev_percent > 10).map((item) => ({
        pair_id: item.pair_id,
        entry_id: item.entry_id,
        rsd_percent: item.measurement.relative_stddev_percent,
      })),
  };
}

function compareSummary(entries, observations) {
  const profiles = entries.map((entryValue) => {
    const selected = observations.filter((item) => item.entry_id === entryValue.id);
    const pairs = new Map();
    for (const item of selected) {
      const pair = pairs.get(item.pair_id) ?? {};
      pair[item.order_position] = item.measurement;
      pairs.set(item.pair_id, pair);
    }
    const ratios = [...pairs.values()].map((pair) => {
      if (!pair.baseline || !pair.candidate) throw new Error(`${entryValue.id} has an incomplete pair`);
      return pair.candidate.mib_per_second / pair.baseline.mib_per_second;
    });
    return {
      entry_id: entryValue.id,
      pairs: ratios.length,
      ratios,
      median_throughput_ratio: median(ratios),
      geometric_mean_throughput_ratio: geometricMean(ratios),
      minimum_throughput_ratio: Math.min(...ratios),
      median_allocation_delta_bytes: median([...pairs.values()].map((pair) =>
        pair.candidate.managed_bytes_per_operation - pair.baseline.managed_bytes_per_operation)),
      median_latency_ratio: median([...pairs.values()].map((pair) =>
        pair.candidate.one_value_microseconds / pair.baseline.one_value_microseconds)),
    };
  });
  const matrixRatio = geometricMean(profiles.map((profile) => profile.geometric_mean_throughput_ratio));
  const lower = bootstrapLowerBound(profiles.map((profile) => profile.ratios), 10_000, 0x5eed2026);
  return {
    mode: "compare",
    profiles,
    matrix_geometric_mean_throughput_ratio: matrixRatio,
    matrix_paired_bootstrap_lower_95: lower,
    minimum_profile_median: Math.min(...profiles.map((profile) => profile.median_throughput_ratio)),
    screening: {
      target_geometric_mean_at_least_1_05: matrixRatio >= 1.05,
      every_profile_median_at_least_0_98: profiles.every((profile) =>
        profile.median_throughput_ratio >= 0.98),
    },
  };
}

function bootstrapLowerBound(profileRatios, samples, seed) {
  let state = seed >>> 0;
  const random = () => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state >>> 0) / 0x1_0000_0000;
  };
  const estimates = [];
  for (let sample = 0; sample < samples; sample += 1) {
    const profileMeans = profileRatios.map((ratios) => {
      const drawn = [];
      for (let index = 0; index < ratios.length; index += 1) {
        drawn.push(ratios[Math.floor(random() * ratios.length)]);
      }
      return geometricMean(drawn);
    });
    estimates.push(geometricMean(profileMeans));
  }
  estimates.sort((left, right) => left - right);
  return estimates[Math.floor(samples * 0.05)];
}

function crossObservationIssues(entries, observations, mode) {
  const issues = [];
  const benchmarkSources = new Set(observations.map((item) =>
    `${item.measurement.benchmark_source_sha256}:${item.measurement.benchmark_support_sha256}`));
  if (benchmarkSources.size !== 1) issues.push("benchmark source hashes differ across observations");

  for (const entryValue of entries) {
    const selected = observations.filter((item) => item.entry_id === entryValue.id);
    const sources = new Set(selected.map((item) =>
      `${item.measurement.source_sha256}:${item.measurement.expected_checksum}`));
    if (sources.size !== 1) issues.push(`${entryValue.id} source or semantic identity differs`);
    const compilers = new Set(selected.map((item) =>
      `${item.measurement.crystal_version}:${item.measurement.crystal_build_commit}:${item.measurement.llvm_version}:${item.measurement.target}`));
    if (compilers.size !== 1) issues.push(`${entryValue.id} compiler identity differs`);
    if (mode === "compare") {
      const roles = new Set(selected.map((item) => item.order_position));
      if (!roles.has("baseline") || !roles.has("candidate")) {
        issues.push(`${entryValue.id} is missing a comparison role`);
      }
    }
  }
  return issues;
}

function artifactManifest(output) {
  const files = [];
  const visit = (directory) => {
    for (const name of fs.readdirSync(directory).sort()) {
      const file = path.join(directory, name);
      const relative = path.relative(output, file);
      if (relative === "artifact-manifest.json" || relative === "SHA256SUMS") continue;
      if (fs.statSync(file).isDirectory()) visit(file);
      else files.push({path: relative, ...fileIdentity(file)});
    }
  };
  visit(output);
  return {
    artifact: "fused-json-streaming-performance-artifact-manifest",
    version: 1,
    files: files.map(({path: relative, bytes, sha256: digest}) => ({path: relative, bytes, sha256: digest})),
  };
}

function writeChecksums(output) {
  const manifestFile = path.join(output, "artifact-manifest.json");
  writeJson(manifestFile, artifactManifest(output));
  const files = [];
  const visit = (directory) => {
    for (const name of fs.readdirSync(directory).sort()) {
      const file = path.join(directory, name);
      const relative = path.relative(output, file);
      if (relative === "SHA256SUMS") continue;
      if (fs.statSync(file).isDirectory()) visit(file);
      else files.push(relative);
    }
  };
  visit(output);
  const contents = files.map((relative) =>
    `${fileIdentity(path.join(output, relative)).sha256}  ${relative}`).join("\n") + "\n";
  fs.writeFileSync(path.join(output, "SHA256SUMS"), contents, {encoding: "utf8", flag: "wx"});
}

function initialCampaign(options, entries, environmentGate) {
  const runner = fileIdentity(fs.realpathSync(process.argv[1]));
  const binaries = options.mode === "collect" ? {
    measured: fileIdentity(options.binary),
  } : {
    baseline: fileIdentity(options.baseline),
    candidate: fileIdentity(options.candidate),
  };
  return {
    receipt: RECEIPT,
    version: VERSION,
    status: "running",
    started_at: new Date().toISOString(),
    mode: options.mode,
    matrix: options.matrix,
    options,
    host: {
      platform: os.platform(),
      release: os.release(),
      architecture: os.arch(),
      cpu_model: os.cpus()[0]?.model ?? null,
      logical_cpus: os.cpus().length,
      environment_gate: environmentGate,
    },
    runner,
    binaries,
    entries,
    observations: [],
  };
}

function runCampaign(options) {
  if (!fs.existsSync(TASKSET)) throw new Error(`${TASKSET} is required`);
  if (fs.existsSync(options.output)) throw new Error(`output path already exists: ${options.output}`);
  const environmentGate = quietHostGate(options);
  fs.mkdirSync(options.output, {recursive: true});
  const receiptsDirectory = path.join(options.output, "receipts");
  fs.mkdirSync(receiptsDirectory);
  const partialFile = path.join(options.output, "campaign.partial.json");
  const journalFile = path.join(options.output, "journal.jsonl");
  const entries = MATRICES[options.matrix];
  const campaign = initialCampaign(options, entries, environmentGate);
  updatePartial(partialFile, campaign);

  try {
    const rounds = options.mode === "collect" ? options.samples : options.pairs;
    for (let round = 0; round < rounds; round += 1) {
      const orderedEntries = round % 2 === 0 ? entries : [...entries].reverse();
      for (const entryValue of orderedEntries) {
        const pairId = `${options.mode}-${String(round + 1).padStart(2, "0")}`;
        const roles = options.mode === "collect" ? ["measured"] :
          (round % 2 === 0 ? ["baseline", "candidate"] : ["candidate", "baseline"]);
        for (const role of roles) {
          const binary = options.mode === "collect" ? options.binary : options[role];
          const commitValue = options.mode === "collect" ? options.commit : options[`${role}_commit`];
          const observation = runChild(
            binary,
            commitValue,
            entryValue,
            options,
            pairId,
            role,
            receiptsDirectory,
          );
          campaign.observations.push(observation);
          appendJournal(journalFile, {
            event: "observation-complete",
            at: new Date().toISOString(),
            pair_id: pairId,
            entry_id: entryValue.id,
            role,
          });
          updatePartial(partialFile, campaign);
        }
      }
    }

    const issues = crossObservationIssues(entries, campaign.observations, options.mode);
    if (issues.length > 0) throw new Error(`campaign identity checks failed: ${issues.join("; ")}`);
    const summary = options.mode === "collect" ?
      collectSummary(entries, campaign.observations) : compareSummary(entries, campaign.observations);
    writeJson(path.join(options.output, "summary.json"), summary);
    campaign.status = "complete";
    campaign.finished_at = new Date().toISOString();
    campaign.summary = summary;
    const campaignFile = path.join(options.output, "campaign.json");
    updatePartial(partialFile, campaign);
    fs.renameSync(partialFile, campaignFile);
    appendJournal(journalFile, {event: "campaign-complete", at: campaign.finished_at});
    writeChecksums(options.output);
    process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
  } catch (error) {
    campaign.status = "failed";
    campaign.finished_at = new Date().toISOString();
    campaign.failure = error.message;
    updatePartial(partialFile, campaign);
    appendJournal(journalFile, {event: "campaign-failed", at: campaign.finished_at, error: error.message});
    throw error;
  }
}

function selfAudit() {
  const ids = new Set();
  for (const [matrix, entries] of Object.entries(MATRICES)) {
    for (const entryValue of entries) {
      const key = `${matrix}:${entryValue.id}`;
      if (ids.has(key)) throw new Error(`duplicate matrix entry ${key}`);
      ids.add(key);
      if (!Number.isSafeInteger(entryValue.values) || entryValue.values < 1 ||
          !Number.isSafeInteger(entryValue.token_bytes) || entryValue.token_bytes < 1) {
        throw new Error(`invalid fixture size in ${key}`);
      }
    }
  }
  if (median([3, 1, 2]) !== 2 || median([4, 2, 1, 3]) !== 2.5) {
    throw new Error("median self-audit failed");
  }
  if (Math.abs(geometricMean([2, 8]) - 4) > 1e-12) {
    throw new Error("geometric mean self-audit failed");
  }
  if (JSON.stringify(expandCpuList("0-1,4,6-7")) !== JSON.stringify([0, 1, 4, 6, 7])) {
    throw new Error("CPU-list self-audit failed");
  }
  if (Math.abs(idlePercent({total: 10, idle: 4}, {total: 110, idle: 79}) - 75) > 1e-12) {
    throw new Error("CPU-idle self-audit failed");
  }
  const lower = bootstrapLowerBound([[1.1, 1.1, 1.1], [1.2, 1.2, 1.2]], 100, 7);
  if (Math.abs(lower - Math.sqrt(1.1 * 1.2)) > 1e-12) {
    throw new Error("bootstrap self-audit failed");
  }
  const fakeEntry = MATRICES.smoke[0];
  const fakeReceipt = {
    receipt: "fused-json-streaming-token-cost",
    version: 1,
    release_build: true,
    fused_json_commit: "a".repeat(40),
    profile: fakeEntry.profile,
    consumer: fakeEntry.consumer,
    transport: fakeEntry.transport,
    values: fakeEntry.values,
    requested_token_bytes: fakeEntry.token_bytes,
    leading_padding: fakeEntry.leading_padding,
    buffer_size: fakeEntry.buffer_size,
    chunk_pattern: [],
    cache_keys: false,
    limit_policy: "none",
    warmup_seconds: 0,
    calculation_seconds: 0.01,
    allocation_iterations: 1,
    latency_iterations: 1,
    pair_id: "self-audit",
    order_position: "measured",
    gc_nprocs: "1",
    gc_markers: "1",
    iterations_per_second: 1,
    relative_stddev_percent: 0,
    managed_bytes_per_operation: 0,
    one_value_microseconds: 1,
    source_sha256: "b".repeat(64),
    benchmark_source_sha256: "c".repeat(64),
    benchmark_support_sha256: "d".repeat(64),
    preflight_read_calls: 1,
    preflight_bytes_read: 10,
    source_bytes: 10,
  };
  const fakeOptions = {warmup: 0, time: 0.01, allocations: 1, latency_iterations: 1};
  if (receiptIssues(fakeReceipt, fakeEntry, fakeOptions, "a".repeat(40),
    "self-audit", "measured").length !== 0) {
    throw new Error("receipt validation self-audit rejected valid data");
  }
  fakeReceipt.source_sha256 = "bad";
  if (!receiptIssues(fakeReceipt, fakeEntry, fakeOptions, "a".repeat(40),
    "self-audit", "measured").includes("invalid source identity")) {
    throw new Error("receipt validation self-audit accepted invalid data");
  }
  process.stdout.write(`${JSON.stringify({
    self_audit: "fused-json-streaming-performance-campaign",
    version: VERSION,
    matrices: Object.fromEntries(Object.entries(MATRICES).map(([name, entries]) =>
      [name, entries.length])),
    status: "passed",
  })}\n`);
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.self_audit) selfAudit();
  else runCampaign(options);
}

try {
  main();
} catch (error) {
  if (error instanceof UsageError) {
    console.error(`${error.message}\n${usage()}`);
    process.exitCode = 2;
  } else {
    console.error(error.stack ?? error.message);
    process.exitCode = 1;
  }
}
