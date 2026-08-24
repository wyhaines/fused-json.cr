#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {spawn} from "node:child_process";
import {performance} from "node:perf_hooks";

const ARTIFACT = "fused-json-milestone-6-dynamic-gate";
const VERSION = 2;
const RUNNER_CPU = "0";
const BENCHMARK_CPU = "3";
const BENCHMARK_SIBLING_CPU = "2";
const GNU_TIME = "/usr/bin/time";
const TASKSET = "/usr/bin/taskset";
const PARAMETERS = Object.freeze({
  warmup_seconds: 1,
  measurement_seconds: 2,
  allocation_operations: 20,
});
const THRESHOLDS = Object.freeze({
  corpus_median_ratio: 0.98,
  geometric_mean_ratio: 1.5,
  minimum_task_cpu_percent: 99,
});
const ENVIRONMENT_POLICY = Object.freeze({
  name: "busy-pinned-v2",
  version: 2,
  sample_interval_ms: 2_000,
  initial_admission_seconds: 60,
  block_admission_seconds: 6,
  gate_load1_maximum: 5,
  gate_load5_maximum: 5,
  gate_tctl_maximum_c: 94,
  gate_tctl_range_maximum_c: 5,
  gate_sibling_cpu_busy_maximum_percent: 25,
  gate_benchmark_cpu_busy_maximum_percent: 10,
  block_gate_deadline_seconds: 180,
  invalid_tctl_minimum_c: 100,
  invalid_load1_strictly_greater_than: 7,
  invalid_sibling_busy_strictly_greater_than_percent: 35,
  consecutive_breach_samples: 2,
  maximum_monitor_gap_seconds: 5,
  minimum_parser_task_cpu_percent: 99,
  child_window_sibling_busy_maximum_percent: 25,
  cpu_frequency_policy: "diagnostic-only; never gates, excludes, or normalizes",
});
const ORDER = Object.freeze(["normal", "reverse", "normal", "reverse", "normal"]);
const LABELS = Object.freeze([
  "Crystal JSON.parse",
  "FusedJSON.load",
  "FusedJSON cached",
]);
const LABEL_KEYS = Object.freeze({
  "Crystal JSON.parse": "crystal_json_parse",
  "FusedJSON.load": "fused_json_load",
  "FusedJSON cached": "fused_json_cached",
});
const CORPORA = Object.freeze([
  Object.freeze({
    name: "activitypub.json",
    bytes: 58_160,
    sha256: "4f4a68f2a0b0f5022e1eeff93ed6871845dc0e4e479dc4c32082225e1dbb3f7c",
  }),
  Object.freeze({
    name: "canada.json",
    bytes: 2_251_051,
    sha256: "f83b3b354030d5dd58740c68ac4fecef64cb730a0d12a90362a7f23077f50d78",
  }),
  Object.freeze({
    name: "citm_catalog.json",
    bytes: 1_727_204,
    sha256: "b3a1f8d7eda4d74551ee8c47639d2896fdcdb0d3ed8ffdb4d4d93ddbb07fdb90",
  }),
  Object.freeze({
    name: "ohai.json",
    bytes: 32_444,
    sha256: "4a56817d69aaedb1689944d9af6d8487dbd9742be415d9e22390236022be50f8",
  }),
  Object.freeze({
    name: "twitter.json",
    bytes: 631_514,
    sha256: "a08b769f32b95f426cbc3abafcec65c1a19d3eb544d4ddf320eae142c99efc5d",
  }),
]);

class UsageError extends Error {}
class IncompleteDataError extends Error {}
class CampaignInvalidError extends Error {}

function usage() {
  return "usage: scripts/dynamic_gate.mjs " +
    "--output=newfile --binary=PATH --corpus-dir=PATH --commit=40hex\n" +
    "       scripts/dynamic_gate.mjs --self-audit";
}

function parseArgs(args) {
  if (args.length === 1 && args[0] === "--self-audit") return {self_audit: true};

  const parsed = {};
  for (const arg of args) {
    const match = arg.match(/^--([a-z-]+)=(.+)$/);
    if (match === null) throw new UsageError(`invalid argument: ${arg}`);
    if (Object.hasOwn(parsed, match[1])) throw new UsageError(`duplicate --${match[1]}`);
    parsed[match[1]] = match[2];
  }
  const expected = ["binary", "commit", "corpus-dir", "output"];
  const actual = Object.keys(parsed).sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new UsageError(`expected exactly ${expected.map((key) => `--${key}`).join(", ")}`);
  }
  if (!/^[0-9a-f]{40}$/.test(parsed.commit)) {
    throw new UsageError("--commit must be a full lowercase 40-character SHA");
  }
  return {
    self_audit: false,
    output: path.resolve(parsed.output),
    partial: `${path.resolve(parsed.output)}.partial`,
    journal: `${path.resolve(parsed.output)}.journal.jsonl`,
    environment_journal: `${path.resolve(parsed.output)}.environment.jsonl`,
    binary: path.resolve(parsed.binary),
    corpus_dir: path.resolve(parsed["corpus-dir"]),
    commit: parsed.commit,
  };
}

function isoNow() {
  return new Date().toISOString();
}

function errorText(error) {
  return String(error?.message ?? error);
}

function sha256Bytes(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function sha256File(file) {
  return sha256Bytes(fs.readFileSync(file));
}

function fileIdentity(requestedPath, {executable = false} = {}) {
  const absolutePath = path.resolve(requestedPath);
  const realpath = fs.realpathSync(absolutePath);
  const stat = fs.statSync(realpath);
  if (!stat.isFile()) throw new Error(`${absolutePath} is not a regular file`);
  if (executable && (stat.mode & 0o111) === 0) throw new Error(`${absolutePath} is not executable`);
  return {
    requested_path: absolutePath,
    realpath,
    basename: path.basename(absolutePath),
    bytes: stat.size,
    sha256: sha256File(realpath),
    mode_octal: (stat.mode & 0o7777).toString(8).padStart(4, "0"),
    device: stat.dev,
    inode: stat.ino,
    mtime_iso: stat.mtime.toISOString(),
    executable,
  };
}

function directoryIdentity(requestedPath) {
  const absolutePath = path.resolve(requestedPath);
  const realpath = fs.realpathSync(absolutePath);
  const stat = fs.statSync(realpath);
  if (!stat.isDirectory()) throw new Error(`${absolutePath} is not a directory`);
  return {
    requested_path: absolutePath,
    realpath,
    device: stat.dev,
    inode: stat.ino,
  };
}

function verifyCanonicalCorpora(corpusDir) {
  const directory = directoryIdentity(corpusDir);
  const files = CORPORA.map((expected) => {
    const requestedPath = path.join(directory.realpath, expected.name);
    const identity = fileIdentity(requestedPath);
    if (identity.basename !== expected.name) {
      throw new Error(`wrong corpus filename: expected ${expected.name}, got ${identity.basename}`);
    }
    if (identity.bytes !== expected.bytes) {
      throw new Error(`${expected.name} size mismatch: expected ${expected.bytes}, got ${identity.bytes}`);
    }
    if (identity.sha256 !== expected.sha256) {
      throw new Error(`${expected.name} SHA-256 mismatch: expected ${expected.sha256}, got ${identity.sha256}`);
    }
    return {...identity, canonical_name: expected.name};
  });
  if (new Set(files.map((entry) => entry.realpath)).size !== files.length) {
    throw new Error("canonical corpus paths do not resolve to five distinct files");
  }
  return {
    directory,
    canonical_order: CORPORA.map((entry) => entry.name),
    files,
  };
}

function comparableIdentity(identity) {
  return {
    realpath: identity.realpath,
    basename: identity.basename,
    bytes: identity.bytes,
    sha256: identity.sha256,
    executable: identity.executable,
  };
}

function sameJson(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function identityMismatch(label, expected, actual) {
  const fields = ["realpath", "basename", "bytes", "sha256", "executable"];
  const changed = fields.filter((field) => expected[field] !== actual[field]);
  return changed.length === 0 ? null : `${label} changed fields: ${changed.join(", ")}`;
}

function takeIdentitySnapshot(frozen) {
  const mismatches = [];
  const observed = {tools: {}, corpora: []};
  const inspect = (label, expected) => {
    try {
      const actual = comparableIdentity(fileIdentity(expected.realpath, {executable: expected.executable}));
      const mismatch = identityMismatch(label, comparableIdentity(expected), actual);
      if (mismatch !== null) mismatches.push(mismatch);
      return actual;
    } catch (error) {
      mismatches.push(`${label}: ${errorText(error)}`);
      return null;
    }
  };

  observed.binary = inspect("benchmark binary", frozen.binary);
  observed.runner = inspect("runner", frozen.runner);
  observed.tools.gnu_time = inspect("GNU time", frozen.tools.gnu_time);
  observed.tools.taskset = inspect("taskset", frozen.tools.taskset);
  observed.tools.node = inspect("Node executable", frozen.tools.node);
  for (const expected of frozen.corpora.files) {
    observed.corpora.push({
      name: expected.canonical_name,
      identity: inspect(`corpus ${expected.canonical_name}`, expected),
    });
  }
  return {verified_at: isoNow(), matched: mismatches.length === 0, mismatches, observed};
}

function buildSchedule() {
  return ORDER.map((order, index) => ({
    index,
    process_id: `m6-dynamic-${String(index).padStart(2, "0")}-${order}`,
    order,
    reverse: order === "reverse",
    attempt: 1,
  }));
}

function assertSchedule(schedule) {
  if (!Array.isArray(schedule) || schedule.length !== 5) throw new Error("schedule must contain five processes");
  if (!sameJson(schedule.map((entry) => entry.order), [...ORDER])) {
    throw new Error("schedule order is not normal/reverse/normal/reverse/normal");
  }
  if (new Set(schedule.map((entry) => entry.process_id)).size !== schedule.length) {
    throw new Error("schedule process IDs are not unique");
  }
  for (let index = 0; index < schedule.length; index += 1) {
    const entry = schedule[index];
    if (entry.index !== index || entry.attempt !== 1 || entry.reverse !== (entry.order === "reverse")) {
      throw new Error(`invalid schedule entry ${index}`);
    }
  }
}

function childEnvironment(entry, commit) {
  return {
    PATH: "/usr/bin:/bin",
    LANG: "C",
    LC_ALL: "C",
    TZ: "UTC",
    GC_NPROCS: "1",
    GC_MARKERS: "1",
    FUSED_JSON_BENCH_WARMUP: String(PARAMETERS.warmup_seconds),
    FUSED_JSON_BENCH_TIME: String(PARAMETERS.measurement_seconds),
    FUSED_JSON_BENCH_ALLOCATIONS: String(PARAMETERS.allocation_operations),
    FUSED_JSON_BENCH_REVERSE: entry.reverse ? "1" : "0",
    FUSED_JSON_BENCH_COMMIT: commit,
  };
}

function benchmarkCommand(_entry, frozen) {
  return [
    TASKSET,
    "-c",
    BENCHMARK_CPU,
    frozen.binary.realpath,
    ...frozen.corpora.files.map((corpus) => corpus.realpath),
  ];
}

function timeCommand(entry, frozen, auditFile) {
  return [GNU_TIME, "-v", "-o", auditFile, ...benchmarkCommand(entry, frozen)];
}

function rawRecord(bytes) {
  const buffer = Buffer.from(bytes);
  return {
    bytes: buffer.length,
    sha256: sha256Bytes(buffer),
    encoding: "base64",
    base64: buffer.toString("base64"),
    utf8: buffer.toString("utf8"),
  };
}

function verifyRawRecord(record, label) {
  if (record?.encoding !== "base64" || typeof record.base64 !== "string" ||
      typeof record.utf8 !== "string" || !Number.isInteger(record.bytes) || record.bytes < 0 ||
      !/^[0-9a-f]{64}$/.test(record.sha256 ?? "")) {
    throw new Error(`${label} raw record has the wrong shape`);
  }
  const decoded = Buffer.from(record.base64, "base64");
  if (decoded.length !== record.bytes || sha256Bytes(decoded) !== record.sha256 ||
      decoded.toString("utf8") !== record.utf8) {
    throw new Error(`${label} raw record does not match its byte binding`);
  }
}

function expectedThroughputOrder(reverse) {
  return reverse ? [...LABELS].reverse() : [...LABELS];
}

function parseCustomOutput(raw, expectedCorpora = CORPORA, expectedReverse = null) {
  if (typeof raw !== "string") throw new Error("benchmark stdout must be UTF-8 text");
  const expectedByName = new Map(expectedCorpora.map((entry) => [entry.name, entry]));
  const records = [];
  const seenNames = new Set();
  let current = null;
  const throughputPattern = /^ {2}(Crystal JSON\.parse|FusedJSON\.load|FusedJSON cached)\s+([0-9]+(?:\.[0-9]+)?) MiB\/s\s+\(RSD\s+([0-9]+(?:\.[0-9]+)?)%\)\s*$/;
  const allocationPattern = /^ {2}(Crystal JSON\.parse|FusedJSON\.load|FusedJSON cached)\s+([0-9]+) B\/op\s*$/;

  for (const line of raw.split(/\r?\n/)) {
    const header = line.match(/^([^/\\:\r\n]+\.json): ([0-9]+) bytes$/);
    if (header !== null) {
      const name = header[1];
      const bytes = Number(header[2]);
      const expected = expectedByName.get(name);
      if (expected === undefined) throw new Error(`unexpected corpus header ${name}`);
      if (seenNames.has(name)) throw new Error(`duplicate corpus header ${name}`);
      if (bytes !== expected.bytes) {
        throw new Error(`${name} stdout size mismatch: expected ${expected.bytes}, got ${bytes}`);
      }
      seenNames.add(name);
      current = {name, bytes, throughput_order: [], allocation_order: [], implementations: {}};
      records.push(current);
      continue;
    }

    const throughput = line.match(throughputPattern);
    if (throughput !== null) {
      if (current === null) throw new Error("throughput line appears before a corpus header");
      const label = throughput[1];
      const key = LABEL_KEYS[label];
      current.implementations[key] ??= {label};
      if (Object.hasOwn(current.implementations[key], "mib_per_second")) {
        throw new Error(`duplicate ${label} throughput for ${current.name}`);
      }
      current.throughput_order.push(label);
      const mibPerSecond = Number(throughput[2]);
      const rsdPercent = Number(throughput[3]);
      if (!Number.isFinite(mibPerSecond) || mibPerSecond <= 0 ||
          !Number.isFinite(rsdPercent) || rsdPercent < 0) {
        throw new Error(`invalid ${label} throughput for ${current.name}`);
      }
      current.implementations[key].mib_per_second = mibPerSecond;
      current.implementations[key].relative_stddev_percent = rsdPercent;
      continue;
    }

    const allocation = line.match(allocationPattern);
    if (allocation !== null) {
      if (current === null) throw new Error("allocation line appears before a corpus header");
      const label = allocation[1];
      const key = LABEL_KEYS[label];
      current.implementations[key] ??= {label};
      if (Object.hasOwn(current.implementations[key], "managed_bytes_per_operation")) {
        throw new Error(`duplicate ${label} allocation for ${current.name}`);
      }
      current.allocation_order.push(label);
      const bytesPerOperation = Number(allocation[2]);
      if (!Number.isSafeInteger(bytesPerOperation) || bytesPerOperation < 0) {
        throw new Error(`invalid ${label} allocation for ${current.name}`);
      }
      current.implementations[key].managed_bytes_per_operation = bytesPerOperation;
      continue;
    }

    if (line.includes("MiB/s") || /\sB\/op\s*$/.test(line)) {
      throw new Error(`malformed custom benchmark line: ${line}`);
    }
  }

  if (!sameJson(records.map((record) => record.name), expectedCorpora.map((entry) => entry.name))) {
    throw new Error("stdout corpus names or order differ from the canonical order");
  }
  for (const record of records) {
    for (const label of LABELS) {
      const measurement = record.implementations[LABEL_KEYS[label]];
      if (measurement === undefined || !Number.isFinite(measurement.mib_per_second) ||
          !Number.isFinite(measurement.relative_stddev_percent) ||
          !Number.isSafeInteger(measurement.managed_bytes_per_operation)) {
        throw new Error(`${record.name} is missing complete custom metrics for ${label}`);
      }
    }
    if (!sameJson(record.allocation_order, [...LABELS])) {
      throw new Error(`${record.name} allocation lines differ from the benchmark contract`);
    }
    if (expectedReverse !== null &&
        !sameJson(record.throughput_order, expectedThroughputOrder(expectedReverse))) {
      throw new Error(`${record.name} throughput order does not match the requested benchmark order`);
    }
    const crystal = record.implementations.crystal_json_parse.mib_per_second;
    const fused = record.implementations.fused_json_load.mib_per_second;
    record.fused_load_to_crystal_ratio = fused / crystal;
  }
  return {schema: "fused-json-parse-custom-output-v1", corpora: records};
}

function oneMatch(raw, regex, label) {
  const matches = [...raw.matchAll(regex)];
  if (matches.length !== 1) throw new Error(`expected one GNU time ${label}, got ${matches.length}`);
  return matches[0][1];
}

function nonnegativeDecimal(value, label) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) throw new Error(`invalid ${label}: ${value}`);
  return number;
}

function nonnegativeInteger(value, label) {
  if (!/^\d+$/.test(value)) throw new Error(`invalid ${label}: ${value}`);
  const number = Number(value);
  if (!Number.isSafeInteger(number)) throw new Error(`unsafe ${label}: ${value}`);
  return number;
}

function elapsedSeconds(value) {
  const fields = value.split(":");
  if (fields.length !== 2 && fields.length !== 3) throw new Error(`invalid GNU time elapsed value: ${value}`);
  const numbers = fields.map(Number);
  if (!numbers.every((number) => Number.isFinite(number) && number >= 0)) {
    throw new Error(`invalid GNU time elapsed value: ${value}`);
  }
  if (fields.length === 2) {
    if (numbers[1] >= 60) throw new Error(`invalid GNU time elapsed seconds: ${value}`);
    return numbers[0] * 60 + numbers[1];
  }
  if (numbers[1] >= 60 || numbers[2] >= 60) throw new Error(`invalid GNU time elapsed fields: ${value}`);
  return numbers[0] * 3600 + numbers[1] * 60 + numbers[2];
}

function parseGnuTimeVerbose(raw) {
  if (typeof raw !== "string" || raw.length === 0) throw new Error("GNU time audit is empty");
  const user = nonnegativeDecimal(oneMatch(raw, /^\s*User time \(seconds\):\s*([0-9]+(?:\.[0-9]+)?)\s*$/gm, "user time"), "user time");
  const system = nonnegativeDecimal(oneMatch(raw, /^\s*System time \(seconds\):\s*([0-9]+(?:\.[0-9]+)?)\s*$/gm, "system time"), "system time");
  const cpu = nonnegativeInteger(oneMatch(raw, /^\s*Percent of CPU this job got:\s*(\d+)%\s*$/gm, "CPU percent"), "CPU percent");
  if (cpu > 100) throw new Error(`single-CPU GNU time audit reported ${cpu}% CPU`);
  const elapsedText = oneMatch(raw, /^\s*Elapsed \(wall clock\) time \(h:mm:ss or m:ss\):\s*([0-9:.]+)\s*$/gm, "elapsed time");
  const audit = {
    schema: "gnu-time-v1-verbose-v1",
    user_cpu_seconds: user,
    system_cpu_seconds: system,
    task_cpu_seconds: user + system,
    reported_cpu_percent: cpu,
    reported_cpu_share: cpu / 100,
    elapsed_wall: elapsedText,
    elapsed_wall_seconds: elapsedSeconds(elapsedText),
    maximum_resident_kibibytes: nonnegativeInteger(oneMatch(raw, /^\s*Maximum resident set size \(kbytes\):\s*(\d+)\s*$/gm, "maximum RSS"), "maximum RSS"),
    major_page_faults: nonnegativeInteger(oneMatch(raw, /^\s*Major \(requiring I\/O\) page faults:\s*(\d+)\s*$/gm, "major page faults"), "major page faults"),
    minor_page_faults: nonnegativeInteger(oneMatch(raw, /^\s*Minor \(reclaiming a frame\) page faults:\s*(\d+)\s*$/gm, "minor page faults"), "minor page faults"),
    voluntary_context_switches: nonnegativeInteger(oneMatch(raw, /^\s*Voluntary context switches:\s*(\d+)\s*$/gm, "voluntary context switches"), "voluntary context switches"),
    involuntary_context_switches: nonnegativeInteger(oneMatch(raw, /^\s*Involuntary context switches:\s*(\d+)\s*$/gm, "involuntary context switches"), "involuntary context switches"),
    exit_status: nonnegativeInteger(oneMatch(raw, /^\s*Exit status:\s*(\d+)\s*$/gm, "exit status"), "exit status"),
  };
  if (audit.elapsed_wall_seconds <= 0) throw new Error("GNU time elapsed wall time is zero");
  audit.cpu_time_over_wall_from_rounded_seconds = audit.task_cpu_seconds / audit.elapsed_wall_seconds;
  audit.total_context_switches = audit.voluntary_context_switches + audit.involuntary_context_switches;
  return audit;
}

function median(values) {
  if (!Array.isArray(values) || values.length === 0 ||
      values.some((value) => !Number.isFinite(value))) {
    throw new IncompleteDataError("median requires non-empty finite data");
  }
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle];
}

function geometricMean(values) {
  if (!Array.isArray(values) || values.length === 0 ||
      values.some((value) => !Number.isFinite(value) || value <= 0)) {
    throw new IncompleteDataError("geometric mean requires non-empty finite positive data");
  }
  return Math.exp(values.reduce((sum, value) => sum + Math.log(value), 0) / values.length);
}

function analyzeObservations(observations, expectedSchedule = buildSchedule(), expectedCorpora = CORPORA) {
  if (!Array.isArray(observations) || observations.length !== expectedSchedule.length) {
    throw new IncompleteDataError(`expected ${expectedSchedule.length} child receipts, got ${observations?.length ?? "non-array"}`);
  }
  const ordered = [...observations].sort((left, right) => left.schedule_index - right.schedule_index);
  for (let index = 0; index < expectedSchedule.length; index += 1) {
    const observation = ordered[index];
    const scheduled = expectedSchedule[index];
    if (observation?.schedule_index !== scheduled.index || observation?.process_id !== scheduled.process_id ||
        observation?.order !== scheduled.order || observation?.valid !== true || observation?.parsed_output === null) {
      throw new IncompleteDataError(`child receipt ${index} is missing, invalid, or inconsistent with the schedule`);
    }
  }

  const corpora = expectedCorpora.map((corpus) => {
    const samples = ordered.map((observation) => {
      const matches = observation.parsed_output.corpora.filter((entry) => entry.name === corpus.name);
      if (matches.length !== 1) {
        throw new IncompleteDataError(`${observation.process_id} does not contain exactly one ${corpus.name} result`);
      }
      const entry = matches[0];
      const crystal = entry.implementations?.crystal_json_parse;
      const fused = entry.implementations?.fused_json_load;
      if (entry.bytes !== corpus.bytes || !Number.isFinite(crystal?.mib_per_second) || crystal.mib_per_second <= 0 ||
          !Number.isFinite(fused?.mib_per_second) || fused.mib_per_second <= 0 ||
          !Number.isSafeInteger(crystal?.managed_bytes_per_operation) ||
          !Number.isSafeInteger(fused?.managed_bytes_per_operation)) {
        throw new IncompleteDataError(`${observation.process_id} has incomplete ${corpus.name} metrics`);
      }
      return {
        schedule_index: observation.schedule_index,
        process_id: observation.process_id,
        order: observation.order,
        crystal_mib_per_second: crystal.mib_per_second,
        fused_load_mib_per_second: fused.mib_per_second,
        fused_load_to_crystal_ratio: fused.mib_per_second / crystal.mib_per_second,
        crystal_managed_bytes_per_operation: crystal.managed_bytes_per_operation,
        fused_load_managed_bytes_per_operation: fused.managed_bytes_per_operation,
      };
    });
    const ratios = samples.map((sample) => sample.fused_load_to_crystal_ratio);
    return {
      name: corpus.name,
      bytes: corpus.bytes,
      samples,
      median_fused_load_to_crystal_ratio: median(ratios),
      minimum_ratio: Math.min(...ratios),
      maximum_ratio: Math.max(...ratios),
      median_crystal_managed_bytes_per_operation: median(samples.map((sample) => sample.crystal_managed_bytes_per_operation)),
      median_fused_load_managed_bytes_per_operation: median(samples.map((sample) => sample.fused_load_managed_bytes_per_operation)),
    };
  });
  const corpusMedians = corpora.map((corpus) => corpus.median_fused_load_to_crystal_ratio);
  return {
    estimator: "geometric-mean-of-five-per-corpus-medians-v1",
    independent_processes: ordered.length,
    samples_per_corpus: ordered.length,
    corpora,
    geometric_mean_of_corpus_median_ratios: geometricMean(corpusMedians),
  };
}

function evaluateGates(analysis) {
  if (analysis === null) {
    return {
      evaluable: false,
      thresholds: THRESHOLDS,
      per_corpus: [],
      every_corpus_median: false,
      geometric_mean: false,
      passed: false,
    };
  }
  const perCorpus = analysis.corpora.map((corpus) => ({
    name: corpus.name,
    value: corpus.median_fused_load_to_crystal_ratio,
    threshold: THRESHOLDS.corpus_median_ratio,
    comparison: ">=",
    passed: corpus.median_fused_load_to_crystal_ratio >= THRESHOLDS.corpus_median_ratio,
  }));
  const everyCorpus = perCorpus.every((gate) => gate.passed);
  const geometric = analysis.geometric_mean_of_corpus_median_ratios >= THRESHOLDS.geometric_mean_ratio;
  return {
    evaluable: true,
    thresholds: THRESHOLDS,
    per_corpus: perCorpus,
    every_corpus_median: everyCorpus,
    geometric_mean: geometric,
    geometric_mean_value: analysis.geometric_mean_of_corpus_median_ratios,
    passed: everyCorpus && geometric,
  };
}

function finalStatus(valid, passed, interruption) {
  if (interruption !== null) return "interrupted";
  if (!valid) return "invalid";
  return passed ? "passed" : "failed";
}

function expectedCorpusBinding(frozen) {
  return frozen.corpora.files.map((corpus) => ({
    name: corpus.canonical_name,
    realpath: corpus.realpath,
    bytes: corpus.bytes,
    sha256: corpus.sha256,
  }));
}

function startSampleBindingMatches(receipt) {
  return receipt?.environment_start_sample_sequence ===
    receipt?.environment_start_gate?.admitted_sample_sequence;
}

function childEnvironmentSampleBindingIssues(receipt, environmentSamples) {
  const issues = [];
  const issue = (condition, message) => { if (!condition) issues.push(message); };
  if (!Array.isArray(environmentSamples)) {
    return ["child environment sample binding has no retained monitor samples"];
  }
  const startSequence = receipt?.environment_start_sample_sequence;
  const endSequence = receipt?.environment_end_sample_sequence;
  issue(Number.isSafeInteger(startSequence) && startSequence >= 0,
    "child environment start sample sequence is invalid");
  issue(Number.isSafeInteger(endSequence) && endSequence >= 0,
    "child environment end sample sequence is invalid");
  if (!(Number.isSafeInteger(startSequence) && startSequence >= 0 &&
        Number.isSafeInteger(endSequence) && endSequence >= 0)) {
    return issues;
  }
  issue(startSequence <= endSequence,
    "child environment sample range is reversed");
  const samplesBySequence = new Map(
    environmentSamples.map((sample) => [sample?.sequence, sample]),
  );
  const startSample = samplesBySequence.get(startSequence);
  const endSample = samplesBySequence.get(endSequence);
  issue(startSample !== undefined && endSample !== undefined,
    "child environment sample range does not resolve to retained samples");
  if (startSample === undefined || endSample === undefined) return issues;

  const beforeMonotonicMs = receipt?.child_environment_window?.before?.monotonic_ms;
  const afterMonotonicMs = receipt?.child_environment_window?.after?.monotonic_ms;
  issue(Number.isFinite(beforeMonotonicMs) &&
    startSample.monotonic_ms <= beforeMonotonicMs,
  "child environment start sample is after the before boundary");
  issue(Number.isFinite(afterMonotonicMs) &&
    endSample.monotonic_ms <= afterMonotonicMs,
  "child environment end sample is after the after boundary");
  const nextStartSample = samplesBySequence.get(startSequence + 1);
  const nextEndSample = samplesBySequence.get(endSequence + 1);
  issue(nextStartSample === undefined ||
    nextStartSample.monotonic_ms > beforeMonotonicMs,
  "child environment start sample is not the latest sample at the before boundary");
  issue(nextEndSample === undefined ||
    nextEndSample.monotonic_ms > afterMonotonicMs,
  "child environment end sample is not the latest sample at the after boundary");
  return issues;
}

function childReceiptIssues(receipt, entry, options, frozen, environmentSamples = null) {
  const issues = [];
  const issue = (condition, message) => { if (!condition) issues.push(message); };
  issue(receipt.receipt === "fused-json-m6-dynamic-child" && receipt.version === VERSION,
    "wrong child receipt schema");
  issue(receipt.schedule_index === entry.index && receipt.process_id === entry.process_id &&
    receipt.order === entry.order && receipt.attempt === 1, "child receipt differs from frozen schedule");
  issue(receipt.commit_argument === options.commit && receipt.fused_json_commit === options.commit &&
    receipt.environment?.FUSED_JSON_BENCH_COMMIT === options.commit, "commit argument, environment, and child receipt differ");
  issue(receipt.environment?.GC_NPROCS === "1" && receipt.environment?.GC_MARKERS === "1", "wrong GC environment");
  issue(receipt.environment?.FUSED_JSON_BENCH_WARMUP === "1" &&
    receipt.environment?.FUSED_JSON_BENCH_TIME === "2" &&
    receipt.environment?.FUSED_JSON_BENCH_ALLOCATIONS === "20", "wrong measurement environment");
  issue(receipt.environment?.FUSED_JSON_BENCH_REVERSE === (entry.reverse ? "1" : "0"), "wrong benchmark order environment");
  issue(sameJson(receipt.benchmark_command, benchmarkCommand(entry, frozen)), "benchmark command differs from frozen command");
  issue(receipt.cpu_affinity === BENCHMARK_CPU, "wrong child CPU affinity request");
  issue(receipt.binary_sha256 === frozen.binary.sha256 && receipt.runner_sha256 === frozen.runner.sha256 &&
    receipt.gnu_time_sha256 === frozen.tools.gnu_time.sha256 && receipt.taskset_sha256 === frozen.tools.taskset.sha256 &&
    receipt.node_executable_sha256 === frozen.tools.node.sha256,
  "child receipt artifact hashes differ from the manifest");
  issue(sameJson(receipt.corpora, expectedCorpusBinding(frozen)), "child receipt corpus identities differ from the manifest");
  issue(receipt.identity_verification_before?.matched === true &&
    receipt.identity_verification_after?.matched === true, "artifact identity verification failed around the child");
  issue(receipt.exit?.spawn_error === null && receipt.exit?.code === 0 && receipt.exit?.signal === null,
    "child did not exit successfully");
  issues.push(...gateEvidenceIssues(
    receipt.environment_start_gate,
    entry.process_id,
    ENVIRONMENT_POLICY.block_admission_seconds,
    {environmentSamples, deadline: true},
  ));
  issue(startSampleBindingMatches(receipt),
  "redundant environment start sample sequence differs from gate evidence");
  issues.push(...childEnvironmentWindowIssues(receipt.child_environment_window));
  issues.push(...childBoundaryTimingIssues(receipt));
  issues.push(...childEnvironmentSampleBindingIssues(receipt, environmentSamples));

  for (const [label, raw] of Object.entries(receipt.raw ?? {})) {
    try {
      verifyRawRecord(raw, label);
    } catch (error) {
      issues.push(errorText(error));
    }
  }
  issue(receipt.raw !== undefined && Object.keys(receipt.raw).sort().join(",") === "stderr,stdout,task_audit",
    "raw stdout, stderr, or task audit is missing");
  issue(receipt.parsed_stdout_sha256 === receipt.raw?.stdout?.sha256, "parsed output is not bound to raw stdout");
  issue(receipt.parsed_task_audit_sha256 === receipt.raw?.task_audit?.sha256, "parsed task audit is not bound to raw audit");

  if (receipt.task_audit === null) {
    issues.push(`task audit did not parse: ${receipt.task_audit_error ?? "unknown error"}`);
  } else {
    issue(receipt.task_audit.exit_status === receipt.exit?.code, "GNU time and wrapper exit statuses differ");
    issue(receipt.task_audit.reported_cpu_percent >=
      ENVIRONMENT_POLICY.minimum_parser_task_cpu_percent,
    `child CPU ${receipt.task_audit.reported_cpu_percent}% is below ${ENVIRONMENT_POLICY.minimum_parser_task_cpu_percent}%`);
  }

  if (receipt.parsed_output === null) {
    issues.push(`stdout did not parse: ${receipt.output_parse_error ?? "unknown error"}`);
  } else {
    try {
      const reparsed = parseCustomOutput(receipt.raw.stdout.utf8, CORPORA, entry.reverse);
      issue(sameJson(reparsed, receipt.parsed_output), "parsed output differs when raw stdout is reparsed");
    } catch (error) {
      issues.push(`raw stdout reparse failed: ${errorText(error)}`);
    }
  }
  return issues;
}

function spawnCaptured(command, environment, stdoutFile, stderrFile,
                       {detached = false, onSpawn = null} = {}) {
  return new Promise((resolve) => {
    let stdoutFd;
    let stderrFd;
    let child;
    try {
      stdoutFd = fs.openSync(stdoutFile, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
      stderrFd = fs.openSync(stderrFile, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
      child = spawn(command[0], command.slice(1), {
        env: environment,
        stdio: ["ignore", stdoutFd, stderrFd],
        detached,
      });
      onSpawn?.(child);
    } catch (error) {
      if (stdoutFd !== undefined) fs.closeSync(stdoutFd);
      if (stderrFd !== undefined) fs.closeSync(stderrFd);
      resolve({pid: null, code: null, signal: null, spawn_error: errorText(error), stdout: Buffer.alloc(0), stderr: Buffer.alloc(0)});
      return;
    }
    fs.closeSync(stdoutFd);
    fs.closeSync(stderrFd);
    let spawnError = null;
    child.once("error", (error) => { spawnError = errorText(error); });
    child.once("close", (code, signal) => {
      let stdout = Buffer.alloc(0);
      let stderr = Buffer.alloc(0);
      try { stdout = fs.readFileSync(stdoutFile); } catch { /* Preserve the child audit below. */ }
      try { stderr = fs.readFileSync(stderrFile); } catch { /* Preserve the child audit below. */ }
      try { if (fs.existsSync(stdoutFile)) fs.unlinkSync(stdoutFile); } catch { /* Best-effort cleanup. */ }
      try { if (fs.existsSync(stderrFile)) fs.unlinkSync(stderrFile); } catch { /* Best-effort cleanup. */ }
      resolve({
        pid: child.pid ?? null,
        code,
        signal,
        spawn_error: spawnError,
        stdout,
        stderr,
      });
    });
  });
}

async function runChild(entry, options, frozen, scratchDirectory, control, startGate) {
  const before = takeIdentitySnapshot(frozen);
  const environment = childEnvironment(entry, options.commit);
  const auditFile = path.join(scratchDirectory, `process-${String(entry.index).padStart(2, "0")}.time-v.txt`);
  const stdoutFile = path.join(scratchDirectory, `process-${String(entry.index).padStart(2, "0")}.stdout.bin`);
  const stderrFile = path.join(scratchDirectory, `process-${String(entry.index).padStart(2, "0")}.stderr.bin`);
  if ([auditFile, stdoutFile, stderrFile].some((file) => fs.existsSync(file))) {
    throw new Error(`process ${entry.index} scratch file already exists`);
  }
  const command = timeCommand(entry, frozen, auditFile);
  let environmentBoundaryBefore;
  try {
    environmentBoundaryBefore = captureChildEnvironmentBoundary(control.tctl_path);
  } catch (error) {
    const reason = {
      kind: "child_environment_read_failure",
      detail: `${entry.process_id} before: ${errorText(error)}`,
    };
    control.monitor.setInvalid(reason);
    throw new CampaignInvalidError(reason.detail);
  }
  if (environmentBoundaryBefore.tctl_c >= ENVIRONMENT_POLICY.invalid_tctl_minimum_c) {
    const reason = {
      kind: "child_boundary_temperature",
      detail: `${entry.process_id} before: Tctl ${environmentBoundaryBefore.tctl_c} C`,
    };
    control.monitor.setInvalid(reason);
    throw new CampaignInvalidError(reason.detail);
  }
  const startedAt = isoNow();
  const startedMonotonicMs = performance.now();
  const result = await spawnCaptured(command, environment, stdoutFile, stderrFile, {
    detached: true,
    onSpawn: (child) => { control.current_child = child; },
  });
  control.current_child = null;
  const finishedAt = isoNow();
  const finishedMonotonicMs = performance.now();
  let environmentBoundaryAfter = null;
  let environmentWindow;
  let environmentEndSampleSequence = null;
  try {
    environmentBoundaryAfter = captureChildEnvironmentBoundary(control.tctl_path);
    environmentEndSampleSequence = control.monitor.samples.at(-1)?.sequence ?? null;
    environmentWindow = childEnvironmentWindow(
      environmentBoundaryBefore,
      environmentBoundaryAfter,
    );
    if (environmentBoundaryAfter.tctl_c >= ENVIRONMENT_POLICY.invalid_tctl_minimum_c) {
      control.monitor.setInvalid({
        kind: "child_boundary_temperature",
        detail: `${entry.process_id} after: Tctl ${environmentBoundaryAfter.tctl_c} C`,
      });
    } else if (!environmentWindow.within_busy_limit) {
      control.monitor.setInvalid({
        kind: "child_window_sibling_cpu",
        detail: `${entry.process_id}: CPU ${BENCHMARK_SIBLING_CPU} busy ${environmentWindow.cpu_busy_percent}% exceeded ${ENVIRONMENT_POLICY.child_window_sibling_busy_maximum_percent}%`,
      });
    }
  } catch (error) {
    const reason = {
      kind: "child_environment_read_failure",
      detail: `${entry.process_id} after: ${errorText(error)}`,
    };
    control.monitor.setInvalid(reason);
    environmentWindow = {
      cpu: BENCHMARK_SIBLING_CPU,
      maximum_busy_percent: ENVIRONMENT_POLICY.child_window_sibling_busy_maximum_percent,
      before: environmentBoundaryBefore,
      after: environmentBoundaryAfter,
      read_error: errorText(error),
    };
  }
  let auditBytes = Buffer.alloc(0);
  let auditReadError = null;
  try {
    auditBytes = fs.readFileSync(auditFile);
  } catch (error) {
    auditReadError = errorText(error);
  }
  try {
    if (fs.existsSync(auditFile)) fs.unlinkSync(auditFile);
  } catch (error) {
    auditReadError = auditReadError ?? `cleanup failed: ${errorText(error)}`;
  }
  const after = takeIdentitySnapshot(frozen);
  const raw = {
    stdout: rawRecord(result.stdout),
    stderr: rawRecord(result.stderr),
    task_audit: rawRecord(auditBytes),
  };
  let parsedOutput = null;
  let outputParseError = null;
  try {
    parsedOutput = parseCustomOutput(raw.stdout.utf8, CORPORA, entry.reverse);
  } catch (error) {
    outputParseError = errorText(error);
  }
  let taskAudit = null;
  let taskAuditError = auditReadError;
  if (taskAuditError === null) {
    try {
      taskAudit = parseGnuTimeVerbose(raw.task_audit.utf8);
    } catch (error) {
      taskAuditError = errorText(error);
    }
  }
  const receipt = {
    receipt: "fused-json-m6-dynamic-child",
    version: VERSION,
    schedule_index: entry.index,
    process_id: entry.process_id,
    order: entry.order,
    attempt: entry.attempt,
    retry_policy: "none",
    commit_argument: options.commit,
    fused_json_commit: options.commit,
    cpu_affinity: BENCHMARK_CPU,
    environment,
    environment_policy: "sanitized; parent environment is not inherited",
    time_command: command,
    benchmark_command: benchmarkCommand(entry, frozen),
    wrapper_pid: result.pid,
    binary_sha256: frozen.binary.sha256,
    runner_sha256: frozen.runner.sha256,
    gnu_time_sha256: frozen.tools.gnu_time.sha256,
    taskset_sha256: frozen.tools.taskset.sha256,
    node_executable_sha256: frozen.tools.node.sha256,
    corpora: expectedCorpusBinding(frozen),
    identity_verification_before: before,
    identity_verification_after: after,
    started_at: startedAt,
    finished_at: finishedAt,
    started_monotonic_ms: startedMonotonicMs,
    finished_monotonic_ms: finishedMonotonicMs,
    elapsed_monotonic_seconds: (finishedMonotonicMs - startedMonotonicMs) / 1_000,
    environment_start_gate: startGate,
    environment_start_sample_sequence: startGate.admitted_sample_sequence,
    environment_end_sample_sequence: environmentEndSampleSequence,
    child_environment_window: environmentWindow,
    exit: {code: result.code, signal: result.signal, spawn_error: result.spawn_error},
    raw,
    parsed_stdout_sha256: parsedOutput === null ? null : raw.stdout.sha256,
    parsed_output: parsedOutput,
    output_parse_error: outputParseError,
    parsed_task_audit_sha256: taskAudit === null ? null : raw.task_audit.sha256,
    task_audit: taskAudit,
    task_audit_error: taskAuditError,
    validity_issues: [],
    valid: false,
  };
  receipt.validity_issues = childReceiptIssues(
    receipt,
    entry,
    options,
    frozen,
    control.monitor.samples,
  );
  receipt.valid = receipt.validity_issues.length === 0;
  return receipt;
}

let atomicCounter = 0;

function serialized(value) {
  return Buffer.from(`${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function fsyncDirectory(directory) {
  const fd = fs.openSync(directory, fs.constants.O_RDONLY);
  try {
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

function writeDurableTextNew(target, textValue) {
  const fd = fs.openSync(target, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
  try {
    fs.writeFileSync(fd, textValue, "utf8");
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fsyncDirectory(path.dirname(target));
}

function writeAllSync(fd, bytes, writer = fs.writeSync) {
  const buffer = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes);
  let offset = 0;
  while (offset < buffer.length) {
    const remaining = buffer.length - offset;
    const written = writer(fd, buffer, offset, remaining, null);
    if (!Number.isSafeInteger(written) || written <= 0 || written > remaining) {
      throw new Error(`invalid synchronous write length ${written}`);
    }
    offset += written;
  }
}

function appendDurableJsonLine(target, value) {
  const fd = fs.openSync(target, fs.constants.O_WRONLY | fs.constants.O_APPEND);
  try {
    writeAllSync(fd, Buffer.from(`${JSON.stringify(value)}\n`, "utf8"));
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

function writeSyncedTemporary(target, value) {
  atomicCounter += 1;
  const temporary = path.join(
    path.dirname(target),
    `.${path.basename(target)}.tmp-${process.pid}-${atomicCounter}`,
  );
  const fd = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
  try {
    fs.writeFileSync(fd, serialized(value));
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  return temporary;
}

function atomicCreate(target, value) {
  const temporary = writeSyncedTemporary(target, value);
  try {
    fs.linkSync(temporary, target);
    fsyncDirectory(path.dirname(target));
  } finally {
    fs.unlinkSync(temporary);
  }
}

function atomicReplace(target, value) {
  const temporary = writeSyncedTemporary(target, value);
  try {
    fs.renameSync(temporary, target);
    fsyncDirectory(path.dirname(target));
  } catch (error) {
    if (fs.existsSync(temporary)) fs.unlinkSync(temporary);
    throw error;
  }
}

function runnerAffinity() {
  try {
    const match = fs.readFileSync("/proc/self/status", "utf8").match(/^Cpus_allowed_list:\s*(.+)$/m);
    return match?.[1]?.trim() ?? null;
  } catch {
    return null;
  }
}

function requireRunnerAffinity(observed) {
  if (observed !== RUNNER_CPU) {
    throw new Error(`runner must be pinned only to CPU ${RUNNER_CPU}; got ${observed ?? "unavailable"}`);
  }
}

function resolveTctlPath() {
  const root = "/sys/class/hwmon";
  for (const hwmon of fs.readdirSync(root).sort()) {
    const directory = path.join(root, hwmon);
    for (const entry of fs.readdirSync(directory).sort()) {
      if (!/^temp\d+_label$/.test(entry)) continue;
      const labelPath = path.join(directory, entry);
      if (fs.readFileSync(labelPath, "utf8").trim() !== "Tctl") continue;
      const inputPath = labelPath.replace(/_label$/, "_input");
      if (fs.existsSync(inputPath)) return fs.realpathSync(inputPath);
    }
  }
  throw new Error("could not resolve Tctl input");
}

function parseTctlInput(text) {
  const rawMillicelsius = typeof text === "string" ? text.trim() : "";
  if (!/^(?:0|[1-9]\d*)$/.test(rawMillicelsius)) {
    throw new Error(`invalid Tctl input: ${JSON.stringify(rawMillicelsius)}`);
  }
  const millicelsius = Number(rawMillicelsius);
  if (!Number.isSafeInteger(millicelsius)) throw new Error("unsafe Tctl integer");
  return {
    raw_millicelsius: rawMillicelsius,
    celsius: millicelsius / 1_000,
  };
}

function parseCpuCounters(text, cpu) {
  const match = text.match(new RegExp(`^(cpu${cpu}\\s+(.+))$`, "m"));
  if (match === null) throw new Error(`missing CPU ${cpu} counters`);
  const rawCounters = match[2].trim().split(/\s+/);
  if (rawCounters.length < 5) throw new Error(`short CPU ${cpu} counters`);
  if (!rawCounters.every((value) => /^\d+$/.test(value))) {
    throw new Error(`malformed CPU ${cpu} counters`);
  }
  const counters = rawCounters.map((value) => BigInt(value));
  // guest and guest_nice are already included in user and nice respectively.
  const total = counters.slice(0, 8).reduce((sum, value) => sum + value, 0n);
  const idle = counters[3] + counters[4];
  return {proc_stat_cpu_line: match[1], counters, total, idle};
}

function cpuBusyPercent(previous, current) {
  if (previous === undefined) return null;
  const total = current.total - previous.total;
  const idle = current.idle - previous.idle;
  if (total <= 0n || idle < 0n || idle > total) {
    throw new Error("CPU counters moved backwards or did not advance");
  }
  return Number(total - idle) / Number(total) * 100;
}

function gateSampleAcceptable(sample) {
  return sample.read_errors.length === 0 &&
    Number.isFinite(sample.load1) && Number.isFinite(sample.load5) &&
    Number.isFinite(sample.tctl_c) && Number.isFinite(sample.cpu2_busy_percent) &&
    Number.isFinite(sample.cpu3_busy_percent) &&
    sample.load1 >= 0 &&
    sample.load5 >= 0 &&
    sample.tctl_c >= 0 &&
    sample.cpu2_busy_percent >= 0 &&
    sample.cpu3_busy_percent >= 0 &&
    sample.load1 <= ENVIRONMENT_POLICY.gate_load1_maximum &&
    sample.load5 <= ENVIRONMENT_POLICY.gate_load5_maximum &&
    sample.tctl_c <= ENVIRONMENT_POLICY.gate_tctl_maximum_c &&
    sample.cpu2_busy_percent <= ENVIRONMENT_POLICY.gate_sibling_cpu_busy_maximum_percent &&
    sample.cpu3_busy_percent <= ENVIRONMENT_POLICY.gate_benchmark_cpu_busy_maximum_percent;
}

function gateTctlRange(samples) {
  if (samples.length === 0) return null;
  const temperaturesMillicelsius = samples.map((sample) => Math.round(sample.tctl_c * 1_000));
  return (Math.max(...temperaturesMillicelsius) -
    Math.min(...temperaturesMillicelsius)) / 1_000;
}

function resetUnstableGateWindow(samples) {
  if (samples.length > 1 &&
      gateTctlRange(samples) > ENVIRONMENT_POLICY.gate_tctl_range_maximum_c) {
    const latest = samples.at(-1);
    samples.length = 0;
    samples.push(latest);
  }
}

function gateEvidence(label, samples, requiredSeconds, {
  waitStartedMonotonicMs,
  absoluteDeadlineMonotonicMs = null,
  admittedEvaluatedMonotonicMs,
} = {}) {
  if (samples.length === 0) throw new Error("gate evidence requires at least one sample");
  const first = samples[0];
  const admitted = samples.at(-1);
  const temperatures = samples.map((sample) => sample.tctl_c);
  return {
    policy_name: ENVIRONMENT_POLICY.name,
    policy_version: ENVIRONMENT_POLICY.version,
    label,
    required_continuous_seconds: requiredSeconds,
    wait_started_monotonic_ms: waitStartedMonotonicMs,
    block_gate_deadline_seconds: absoluteDeadlineMonotonicMs === null ? null :
      ENVIRONMENT_POLICY.block_gate_deadline_seconds,
    absolute_deadline_monotonic_ms: absoluteDeadlineMonotonicMs,
    admitted_evaluated_monotonic_ms: admittedEvaluatedMonotonicMs,
    first_acceptable_sample_sequence: first.sequence,
    first_acceptable_monotonic_ms: first.monotonic_ms,
    admitted_sample_sequence: admitted.sequence,
    admitted_monotonic_ms: admitted.monotonic_ms,
    continuous_seconds: (admitted.monotonic_ms - first.monotonic_ms) / 1_000,
    sample_sequences: samples.map((sample) => sample.sequence),
    sample_count: samples.length,
    tctl_minimum_c: Math.min(...temperatures),
    tctl_maximum_c: Math.max(...temperatures),
    tctl_range_c: gateTctlRange(samples),
  };
}

function minimumGateSampleCount(requiredSeconds) {
  return Math.ceil(
    (requiredSeconds * 1_000) / ENVIRONMENT_POLICY.sample_interval_ms,
  ) + 1;
}

function gateEvidenceIssues(evidence, label, requiredSeconds, {
  environmentSamples = null,
  deadline = false,
} = {}) {
  const issues = [];
  const issue = (condition, message) => { if (!condition) issues.push(message); };
  issue(evidence?.policy_name === ENVIRONMENT_POLICY.name &&
    evidence?.policy_version === ENVIRONMENT_POLICY.version,
  `${label} gate has the wrong policy identity`);
  issue(evidence?.label === label && evidence?.required_continuous_seconds === requiredSeconds,
    `${label} gate has the wrong label or duration`);
  issue(Array.isArray(evidence?.sample_sequences) && evidence.sample_sequences.length >= 2,
    `${label} gate has no sample sequence evidence`);
  const minimumSampleCount = minimumGateSampleCount(requiredSeconds);
  issue(evidence?.sample_count === evidence?.sample_sequences?.length &&
    evidence?.sample_count >= minimumSampleCount,
  `${label} gate has fewer than ${minimumSampleCount} required samples`);
  if (Array.isArray(evidence?.sample_sequences) && evidence.sample_sequences.length > 0) {
    issue(evidence.sample_sequences.every((sequence, index, values) =>
      Number.isSafeInteger(sequence) && (index === 0 || sequence === values[index - 1] + 1)),
    `${label} gate sample sequences are not contiguous increasing integers`);
    issue(evidence.first_acceptable_sample_sequence === evidence.sample_sequences[0] &&
      evidence.admitted_sample_sequence === evidence.sample_sequences.at(-1),
    `${label} gate endpoints differ from its sample sequences`);
  }
  issue(Number.isFinite(evidence?.first_acceptable_monotonic_ms) &&
    Number.isFinite(evidence?.admitted_monotonic_ms) &&
    evidence?.continuous_seconds ===
      (evidence?.admitted_monotonic_ms - evidence?.first_acceptable_monotonic_ms) / 1_000 &&
    evidence?.continuous_seconds >= requiredSeconds,
  `${label} gate has inconsistent or insufficient continuous time`);
  issue(Number.isFinite(evidence?.wait_started_monotonic_ms) &&
    evidence?.wait_started_monotonic_ms <= evidence?.first_acceptable_monotonic_ms &&
    Number.isFinite(evidence?.admitted_evaluated_monotonic_ms) &&
    evidence?.admitted_evaluated_monotonic_ms >= evidence?.admitted_monotonic_ms,
  `${label} gate has inconsistent wait or evaluation timing`);
  issue(Number.isFinite(evidence?.tctl_minimum_c) && Number.isFinite(evidence?.tctl_maximum_c) &&
    evidence?.tctl_range_c === gateTctlRange([
      {tctl_c: evidence?.tctl_minimum_c},
      {tctl_c: evidence?.tctl_maximum_c},
    ]) &&
    evidence?.tctl_maximum_c <= ENVIRONMENT_POLICY.gate_tctl_maximum_c &&
    evidence?.tctl_range_c <= ENVIRONMENT_POLICY.gate_tctl_range_maximum_c,
  `${label} gate has inconsistent or out-of-range Tctl evidence`);

  if (deadline) {
    issue(evidence?.block_gate_deadline_seconds ===
      ENVIRONMENT_POLICY.block_gate_deadline_seconds &&
      evidence?.absolute_deadline_monotonic_ms === evidence?.wait_started_monotonic_ms +
        (ENVIRONMENT_POLICY.block_gate_deadline_seconds * 1_000) &&
      blockGateSampleTimely(
        evidence?.wait_started_monotonic_ms,
        evidence?.admitted_monotonic_ms,
        evidence?.admitted_evaluated_monotonic_ms,
      ),
    `${label} gate missed or misreported its absolute deadline`);
  } else {
    issue(evidence?.block_gate_deadline_seconds === null &&
      evidence?.absolute_deadline_monotonic_ms === null,
    `${label} initial gate unexpectedly records a block deadline`);
  }

  if (Array.isArray(environmentSamples) && Array.isArray(evidence?.sample_sequences)) {
    const samplesBySequence = new Map();
    for (const sample of environmentSamples) {
      if (samplesBySequence.has(sample.sequence)) {
        issues.push(`${label} environment samples contain duplicate sequence ${sample.sequence}`);
      }
      samplesBySequence.set(sample.sequence, sample);
    }
    const cited = evidence.sample_sequences.map((sequence) => samplesBySequence.get(sequence));
    issue(cited.every((sample) => sample !== undefined),
      `${label} gate cites a missing environment sample`);
    if (cited.every((sample) => sample !== undefined)) {
      issue(cited.every((sample) => gateSampleAcceptable(sample)),
        `${label} gate cites a sample outside the load, CPU, or Tctl limits`);
      const recomputed = gateEvidence(label, cited, requiredSeconds, {
        waitStartedMonotonicMs: evidence.wait_started_monotonic_ms,
        absoluteDeadlineMonotonicMs: evidence.absolute_deadline_monotonic_ms,
        admittedEvaluatedMonotonicMs: evidence.admitted_evaluated_monotonic_ms,
      });
      issue(sameJson(recomputed, evidence),
        `${label} gate differs when recomputed from environment samples`);
    }
  }
  return issues;
}

function blockGateSampleTimely(startedMonotonicMs, sampleMonotonicMs, evaluatedMonotonicMs) {
  const deadline = startedMonotonicMs + (ENVIRONMENT_POLICY.block_gate_deadline_seconds * 1_000);
  return sampleMonotonicMs <= deadline && evaluatedMonotonicMs <= deadline;
}

function captureChildEnvironmentBoundary(tctlPath) {
  const observedAt = isoNow();
  const monotonicMs = performance.now();
  const counters = parseCpuCounters(
    fs.readFileSync("/proc/stat", "utf8"),
    BENCHMARK_SIBLING_CPU,
  );
  const tctl = parseTctlInput(fs.readFileSync(tctlPath, "utf8"));
  return {
    observed_at: observedAt,
    monotonic_ms: monotonicMs,
    proc_stat_cpu_line: counters.proc_stat_cpu_line,
    counters: counters.counters.map((value) => value.toString()),
    total_ticks: counters.total.toString(),
    idle_ticks: counters.idle.toString(),
    tctl_raw_millicelsius: tctl.raw_millicelsius,
    tctl_c: tctl.celsius,
  };
}

function childEnvironmentWindow(before, after) {
  const beforeTotal = BigInt(before.total_ticks);
  const beforeIdle = BigInt(before.idle_ticks);
  const afterTotal = BigInt(after.total_ticks);
  const afterIdle = BigInt(after.idle_ticks);
  const deltaTotal = afterTotal - beforeTotal;
  const deltaIdle = afterIdle - beforeIdle;
  const deltaBusy = deltaTotal - deltaIdle;
  if (deltaTotal <= 0n || deltaIdle < 0n || deltaIdle > deltaTotal) {
    throw new Error("child-window CPU counters moved backwards or did not advance");
  }
  const busyPercent = Number(deltaBusy) / Number(deltaTotal) * 100;
  return {
    cpu: BENCHMARK_SIBLING_CPU,
    maximum_busy_percent: ENVIRONMENT_POLICY.child_window_sibling_busy_maximum_percent,
    before,
    after,
    delta_total_ticks: deltaTotal.toString(),
    delta_idle_ticks: deltaIdle.toString(),
    delta_busy_ticks: deltaBusy.toString(),
    cpu_busy_percent: busyPercent,
    within_busy_limit:
      busyPercent <= ENVIRONMENT_POLICY.child_window_sibling_busy_maximum_percent,
  };
}

function childEnvironmentWindowIssues(window) {
  const issues = [];
  const issue = (condition, message) => { if (!condition) issues.push(message); };
  issue(sameJson(Object.keys(window ?? {}).sort(), [
    "after", "before", "cpu", "cpu_busy_percent", "delta_busy_ticks",
    "delta_idle_ticks", "delta_total_ticks", "maximum_busy_percent", "within_busy_limit",
  ]), "child environment window has missing or unexpected fields");
  issue(window?.cpu === BENCHMARK_SIBLING_CPU, "child environment window has the wrong CPU");
  issue(window?.maximum_busy_percent ===
    ENVIRONMENT_POLICY.child_window_sibling_busy_maximum_percent,
  "child environment window has the wrong busy limit");
  issue(window?.read_error === undefined, `child environment read failed: ${window?.read_error}`);

  for (const position of ["before", "after"]) {
    const boundary = window?.[position];
    issue(sameJson(Object.keys(boundary ?? {}).sort(), [
      "counters", "idle_ticks", "monotonic_ms", "observed_at", "proc_stat_cpu_line",
      "tctl_c", "tctl_raw_millicelsius", "total_ticks",
    ]), `${position} child boundary has missing or unexpected fields`);
    issue(typeof boundary?.observed_at === "string" &&
      Number.isFinite(Date.parse(boundary.observed_at)),
    `${position} child boundary has no valid wall time`);
    issue(Number.isFinite(boundary?.monotonic_ms), `${position} child boundary has no monotonic time`);
    try {
      const parsed = parseCpuCounters(`${boundary.proc_stat_cpu_line}\n`, BENCHMARK_SIBLING_CPU);
      issue(Array.isArray(boundary.counters) && boundary.counters.length >= 5 &&
        boundary.counters.every((value) => /^\d+$/.test(value)),
      `${position} child boundary counters are not raw decimal strings`);
      issue(sameJson(boundary.counters, parsed.counters.map((value) => value.toString())),
        `${position} child boundary counters differ from the raw CPU line`);
      issue(boundary.total_ticks === parsed.total.toString() &&
        boundary.idle_ticks === parsed.idle.toString(),
      `${position} child boundary totals differ from the raw CPU line`);
    } catch (error) {
      issues.push(`${position} child boundary CPU counters: ${errorText(error)}`);
    }
    try {
      issue(typeof boundary.tctl_raw_millicelsius === "string" &&
        /^(?:0|[1-9]\d*)$/.test(boundary.tctl_raw_millicelsius),
        `${position} child boundary has malformed raw Tctl`);
      const rawTctl = Number(boundary.tctl_raw_millicelsius);
      issue(Number.isSafeInteger(rawTctl) && boundary.tctl_c === rawTctl / 1_000,
        `${position} child boundary Tctl differs from its raw value`);
      issue(boundary.tctl_c < ENVIRONMENT_POLICY.invalid_tctl_minimum_c,
        `${position} child boundary Tctl reached the invalidation threshold`);
    } catch (error) {
      issues.push(`${position} child boundary Tctl: ${errorText(error)}`);
    }
  }

  try {
    const recomputed = childEnvironmentWindow(window.before, window.after);
    issue(sameJson(window, recomputed), "child environment window differs when recomputed");
  } catch (error) {
    issues.push(`child environment window recompute failed: ${errorText(error)}`);
  }
  issue(Number.isFinite(window?.cpu_busy_percent), "child environment window busy percent is unavailable");
  issue(window?.cpu_busy_percent <=
    ENVIRONMENT_POLICY.child_window_sibling_busy_maximum_percent,
  `child-window CPU ${BENCHMARK_SIBLING_CPU} exceeded ${ENVIRONMENT_POLICY.child_window_sibling_busy_maximum_percent}%`);
  issue(window?.within_busy_limit === true, "child environment window is outside its busy limit");
  return issues;
}

function childBoundaryTimingIssues(receipt) {
  const issues = [];
  const before = receipt.child_environment_window?.before;
  const after = receipt.child_environment_window?.after;
  if (!(Number.isFinite(receipt.started_monotonic_ms) &&
        Number.isFinite(receipt.finished_monotonic_ms) &&
        before?.monotonic_ms <= receipt.started_monotonic_ms &&
        receipt.started_monotonic_ms <= receipt.finished_monotonic_ms &&
        receipt.finished_monotonic_ms <= after?.monotonic_ms)) {
    issues.push("child environment monotonic boundaries do not enclose the measured process");
  }
  if (receipt.elapsed_monotonic_seconds !==
      (receipt.finished_monotonic_ms - receipt.started_monotonic_ms) / 1_000) {
    issues.push("child elapsed monotonic time differs from its boundaries");
  }
  const startedWallMs = Date.parse(receipt.started_at);
  const finishedWallMs = Date.parse(receipt.finished_at);
  if (!(Number.isFinite(startedWallMs) && Number.isFinite(finishedWallMs) &&
        Date.parse(before?.observed_at) <= startedWallMs &&
        startedWallMs <= finishedWallMs &&
        finishedWallMs <= Date.parse(after?.observed_at))) {
    issues.push("child environment wall-clock boundaries do not enclose the measured process");
  }
  return issues;
}

function environmentInvalidation(policyState, sample) {
  if (sample.read_errors.length > 0) {
    return {kind: "environment_read_failure", detail: sample.read_errors.join("; ")};
  }
  if (sample.gap_seconds !== null &&
      sample.gap_seconds > ENVIRONMENT_POLICY.maximum_monitor_gap_seconds) {
    return {kind: "monitor_gap", detail: `${sample.gap_seconds.toFixed(3)} seconds`};
  }
  if (sample.tctl_c >= ENVIRONMENT_POLICY.invalid_tctl_minimum_c) {
    return {kind: "temperature", detail: `Tctl ${sample.tctl_c} C`};
  }
  policyState.load_breaches = sample.load1 > ENVIRONMENT_POLICY.invalid_load1_strictly_greater_than
    ? policyState.load_breaches + 1 : 0;
  policyState.sibling_breaches = sample.cpu2_busy_percent !== null &&
    sample.cpu2_busy_percent > ENVIRONMENT_POLICY.invalid_sibling_busy_strictly_greater_than_percent
    ? policyState.sibling_breaches + 1 : 0;
  if (policyState.load_breaches >= ENVIRONMENT_POLICY.consecutive_breach_samples) {
    return {
      kind: "load",
      detail: `load1 exceeded ${ENVIRONMENT_POLICY.invalid_load1_strictly_greater_than} for ${policyState.load_breaches} consecutive samples`,
    };
  }
  if (policyState.sibling_breaches >= ENVIRONMENT_POLICY.consecutive_breach_samples) {
    return {
      kind: "sibling_cpu",
      detail: `CPU ${BENCHMARK_SIBLING_CPU} exceeded ${ENVIRONMENT_POLICY.invalid_sibling_busy_strictly_greater_than_percent}% for ${policyState.sibling_breaches} consecutive samples`,
    };
  }
  return null;
}

function replayEnvironmentSamples(samples) {
  const issues = [];
  const invalidations = [];
  const policyState = {load_breaches: 0, sibling_breaches: 0};
  if (!Array.isArray(samples) || samples.length === 0) {
    return {
      policy_name: ENVIRONMENT_POLICY.name,
      policy_version: ENVIRONMENT_POLICY.version,
      sample_count: Array.isArray(samples) ? samples.length : null,
      invalidations,
      issues: ["environment replay requires retained samples"],
      passed: false,
    };
  }
  let previousMonotonicMs = null;
  for (let index = 0; index < samples.length; index += 1) {
    const sample = samples[index];
    const issue = (condition, message) => { if (!condition) issues.push(message); };
    if (sample?.sequence !== index || !Number.isSafeInteger(sample?.sequence)) {
      issues.push(`environment sample ${index} has sequence ${sample?.sequence}`);
    }
    issue(typeof sample?.label === "string" && sample.label.length > 0,
      `environment sample ${index} has an invalid label`);
    issue(typeof sample?.observed_at === "string" &&
      Number.isFinite(Date.parse(sample.observed_at)),
    `environment sample ${index} has an invalid wall time`);
    issue(Number.isFinite(sample?.monotonic_ms) && sample.monotonic_ms >= 0,
      `environment sample ${index} has invalid monotonic time`);
    if (previousMonotonicMs !== null) {
      issue(sample?.monotonic_ms > previousMonotonicMs,
        `environment sample ${index} monotonic time did not advance`);
    }
    issue(Array.isArray(sample?.read_errors) &&
      sample.read_errors.every((entry) => typeof entry === "string" && entry.length > 0),
    `environment sample ${index} has malformed read_errors`);
    for (const [field, maximum] of [
      ["load1", Number.POSITIVE_INFINITY],
      ["load5", Number.POSITIVE_INFINITY],
      ["tctl_c", Number.POSITIVE_INFINITY],
    ]) {
      issue(Number.isFinite(sample?.[field]) && sample[field] >= 0 &&
        sample[field] <= maximum,
      `environment sample ${index} has invalid ${field}`);
    }
    for (const field of ["cpu2_busy_percent", "cpu3_busy_percent"]) {
      const valid = index === 0 ? sample?.[field] === null :
        Number.isFinite(sample?.[field]) && sample[field] >= 0 && sample[field] <= 100;
      issue(valid, `environment sample ${index} has invalid ${field}`);
    }
    const frequencyValid =
      (Number.isFinite(sample?.cpu3_scaling_cur_freq_khz) &&
        sample.cpu3_scaling_cur_freq_khz > 0 && sample?.cpu3_frequency_error === null) ||
      (sample?.cpu3_scaling_cur_freq_khz === null &&
        typeof sample?.cpu3_frequency_error === "string" &&
        sample.cpu3_frequency_error.length > 0);
    issue(frequencyValid,
      `environment sample ${index} has malformed diagnostic frequency evidence`);
    const expectedGap = previousMonotonicMs === null ? null :
      (sample.monotonic_ms - previousMonotonicMs) / 1_000;
    if (sample?.gap_seconds !== expectedGap) {
      issues.push(`environment sample ${index} gap differs from retained monotonic times`);
    }
    previousMonotonicMs = sample?.monotonic_ms;
    try {
      const reason = environmentInvalidation(policyState, sample);
      if (reason !== null) {
        invalidations.push({sample_sequence: sample.sequence, ...reason});
      }
    } catch (error) {
      issues.push(`environment sample ${index} replay failed: ${errorText(error)}`);
    }
  }
  return {
    policy_name: ENVIRONMENT_POLICY.name,
    policy_version: ENVIRONMENT_POLICY.version,
    sample_count: samples.length,
    invalidations,
    issues,
    passed: issues.length === 0 && invalidations.length === 0,
  };
}

function chronologyAudit(admission, observations, schedule) {
  const issues = [];
  const timeline = [];
  if (admission === null || !Number.isFinite(admission?.admitted_evaluated_monotonic_ms) ||
      !Number.isSafeInteger(admission?.admitted_sample_sequence)) {
    issues.push("chronology has no valid initial-admission endpoint");
  }
  let previousEndpoint = admission?.admitted_evaluated_monotonic_ms ?? null;
  let previousEndSequence = admission?.admitted_sample_sequence ?? null;
  for (let index = 0; index < observations.length; index += 1) {
    const observation = observations[index];
    const expected = schedule[index];
    const gate = observation?.environment_start_gate;
    const before = observation?.child_environment_window?.before;
    const after = observation?.child_environment_window?.after;
    if (expected === undefined || observation?.schedule_index !== expected.index ||
        observation?.process_id !== expected.process_id || observation?.order !== expected.order) {
      issues.push(`observation ${index} differs from the frozen schedule`);
    }
    if (!(Number.isFinite(gate?.wait_started_monotonic_ms) &&
          Number.isFinite(gate?.first_acceptable_monotonic_ms) &&
          Number.isFinite(gate?.admitted_monotonic_ms) &&
          Number.isFinite(gate?.admitted_evaluated_monotonic_ms) &&
          Number.isFinite(before?.monotonic_ms) && Number.isFinite(after?.monotonic_ms))) {
      issues.push(`observation ${index} has incomplete chronology fields`);
    } else {
      if (!(previousEndpoint < gate.wait_started_monotonic_ms &&
            gate.wait_started_monotonic_ms < gate.first_acceptable_monotonic_ms)) {
        issues.push(`observation ${index} gate starts before the preceding endpoint`);
      }
      if (!(gate.admitted_monotonic_ms <= gate.admitted_evaluated_monotonic_ms &&
            gate.admitted_evaluated_monotonic_ms < before.monotonic_ms)) {
        issues.push(`observation ${index} gate admission does not precede its child boundary`);
      }
      if (before.monotonic_ms >= after.monotonic_ms) {
        issues.push(`observation ${index} child boundaries overlap backwards`);
      }
      previousEndpoint = after.monotonic_ms;
    }
    if (!(Number.isSafeInteger(gate?.first_acceptable_sample_sequence) &&
          Number.isSafeInteger(observation?.environment_start_sample_sequence) &&
          Number.isSafeInteger(observation?.environment_end_sample_sequence) &&
          previousEndSequence < gate.first_acceptable_sample_sequence &&
          gate.admitted_sample_sequence === observation.environment_start_sample_sequence &&
          observation.environment_start_sample_sequence <=
            observation.environment_end_sample_sequence)) {
      issues.push(`observation ${index} does not use fresh post-predecessor samples`);
    }
    previousEndSequence = observation?.environment_end_sample_sequence ?? null;
    timeline.push({
      schedule_index: observation?.schedule_index ?? null,
      process_id: observation?.process_id ?? null,
      gate_wait_started_monotonic_ms: gate?.wait_started_monotonic_ms ?? null,
      gate_admitted_evaluated_monotonic_ms:
        gate?.admitted_evaluated_monotonic_ms ?? null,
      gate_first_acceptable_sample_sequence:
        gate?.first_acceptable_sample_sequence ?? null,
      environment_start_sample_sequence:
        observation?.environment_start_sample_sequence ?? null,
      environment_end_sample_sequence:
        observation?.environment_end_sample_sequence ?? null,
      child_before_monotonic_ms: before?.monotonic_ms ?? null,
      child_after_monotonic_ms: after?.monotonic_ms ?? null,
    });
  }
  if (observations.length !== schedule.length) {
    issues.push(`chronology retained ${observations.length}/${schedule.length} scheduled observations`);
  }
  return {issues, timeline, passed: issues.length === 0};
}

class EnvironmentMonitor {
  constructor({environmentJournal, tctlPath, onInvalid}) {
    this.environment_journal = environmentJournal;
    this.tctl_path = tctlPath;
    this.on_invalid = onInvalid;
    this.frequency_path = `/sys/devices/system/cpu/cpu${BENCHMARK_CPU}/cpufreq/scaling_cur_freq`;
    this.samples = [];
    this.previous_cpu = {};
    this.previous_monotonic_ms = null;
    this.policy_state = {load_breaches: 0, sibling_breaches: 0};
    this.invalid_reason = null;
    this.waiters = [];
    this.timer = null;
  }

  start() {
    this.takeSample("monitor-start");
    this.timer = setInterval(
      () => this.takeSample("monitor"),
      ENVIRONMENT_POLICY.sample_interval_ms,
    );
  }

  stop(reason = new Error("environment monitor stopped")) {
    if (this.timer !== null) clearInterval(this.timer);
    this.timer = null;
    for (const waiter of this.waiters.splice(0)) waiter.reject(reason);
  }

  setInvalid(reason) {
    if (this.invalid_reason !== null) return;
    this.invalid_reason = {
      ...reason,
      observed_at: isoNow(),
      sample_sequence: this.samples.at(-1)?.sequence ?? null,
    };
    this.on_invalid(this.invalid_reason);
  }

  takeSample(label) {
    const now = performance.now();
    const sample = {
      sequence: this.samples.length,
      label,
      observed_at: isoNow(),
      monotonic_ms: now,
      gap_seconds: this.previous_monotonic_ms === null ? null :
        (now - this.previous_monotonic_ms) / 1_000,
      load1: null,
      load5: null,
      tctl_c: null,
      cpu2_busy_percent: null,
      cpu3_busy_percent: null,
      cpu3_scaling_cur_freq_khz: null,
      cpu3_frequency_error: null,
      read_errors: [],
    };
    this.previous_monotonic_ms = now;
    try {
      const fields = fs.readFileSync("/proc/loadavg", "utf8").trim().split(/\s+/);
      sample.load1 = Number(fields[0]);
      sample.load5 = Number(fields[1]);
      if (!Number.isFinite(sample.load1) || !Number.isFinite(sample.load5)) {
        throw new Error("nonfinite load average");
      }
    } catch (error) {
      sample.read_errors.push(`loadavg: ${errorText(error)}`);
    }
    try {
      sample.tctl_c = parseTctlInput(
        fs.readFileSync(this.tctl_path, "utf8"),
      ).celsius;
    } catch (error) {
      sample.read_errors.push(`Tctl: ${errorText(error)}`);
    }
    try {
      const procStat = fs.readFileSync("/proc/stat", "utf8");
      for (const cpu of [BENCHMARK_SIBLING_CPU, BENCHMARK_CPU]) {
        const current = parseCpuCounters(procStat, cpu);
        sample[`cpu${cpu}_busy_percent`] = cpuBusyPercent(this.previous_cpu[cpu], current);
        this.previous_cpu[cpu] = current;
      }
    } catch (error) {
      sample.read_errors.push(`CPU counters: ${errorText(error)}`);
    }
    try {
      const frequency = Number(fs.readFileSync(this.frequency_path, "utf8").trim());
      if (!Number.isFinite(frequency) || frequency <= 0) throw new Error("invalid scaling_cur_freq");
      sample.cpu3_scaling_cur_freq_khz = frequency;
    } catch (error) {
      sample.cpu3_frequency_error = errorText(error);
    }
    this.samples.push(sample);
    try {
      appendDurableJsonLine(this.environment_journal, sample);
    } catch (error) {
      this.setInvalid({kind: "environment_journal_write_failure", detail: errorText(error)});
      return;
    }
    const invalid = environmentInvalidation(this.policy_state, sample);
    if (invalid !== null) this.setInvalid(invalid);
    for (const waiter of this.waiters.splice(0)) {
      if (sample.sequence > waiter.after_sequence) waiter.resolve(sample);
      else this.waiters.push(waiter);
    }
  }

  waitForSampleAfter(afterSequence) {
    const existing = this.samples.find((sample) => sample.sequence > afterSequence);
    if (existing !== undefined) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const waiter = {after_sequence: afterSequence, resolve, reject};
      this.waiters.push(waiter);
      const timeout = setTimeout(() => {
        const index = this.waiters.indexOf(waiter);
        if (index >= 0) this.waiters.splice(index, 1);
        const reason = {kind: "monitor_timeout", detail: "no environment sample arrived within 5 seconds"};
        this.setInvalid(reason);
        reject(new CampaignInvalidError(reason.detail));
      }, (ENVIRONMENT_POLICY.maximum_monitor_gap_seconds * 1_000) + 250);
      waiter.resolve = (sample) => { clearTimeout(timeout); resolve(sample); };
      waiter.reject = (error) => { clearTimeout(timeout); reject(error); };
    });
  }

  assertValid() {
    if (this.invalid_reason !== null) {
      throw new CampaignInvalidError(`${this.invalid_reason.kind}: ${this.invalid_reason.detail}`);
    }
  }

  async awaitGate(label, requiredSeconds, {deadline = false} = {}) {
    this.assertValid();
    const started = performance.now();
    const absoluteDeadline = started +
      (ENVIRONMENT_POLICY.block_gate_deadline_seconds * 1_000);
    let sequence = this.samples.at(-1).sequence;
    const acceptableSamples = [];
    while (true) {
      const sample = await this.waitForSampleAfter(sequence);
      sequence = sample.sequence;
      this.assertValid();
      const evaluated = performance.now();
      if (deadline && !blockGateSampleTimely(started, sample.monotonic_ms, evaluated)) {
        const reason = {
          kind: "block_gate_timeout",
          detail: `${label} did not sustain the ${requiredSeconds}-second ${ENVIRONMENT_POLICY.name} gate by the absolute ${ENVIRONMENT_POLICY.block_gate_deadline_seconds}-second deadline`,
          started_monotonic_ms: started,
          deadline_monotonic_ms: absoluteDeadline,
          sample_monotonic_ms: sample.monotonic_ms,
          evaluated_monotonic_ms: evaluated,
        };
        this.setInvalid(reason);
        throw new CampaignInvalidError(reason.detail);
      }
      if (!gateSampleAcceptable(sample)) {
        acceptableSamples.length = 0;
        continue;
      }
      acceptableSamples.push(sample);
      resetUnstableGateWindow(acceptableSamples);
      const evidence = gateEvidence(label, acceptableSamples, requiredSeconds, {
        waitStartedMonotonicMs: started,
        absoluteDeadlineMonotonicMs: deadline ? absoluteDeadline : null,
        admittedEvaluatedMonotonicMs: evaluated,
      });
      if (evidence.continuous_seconds >= requiredSeconds &&
          evidence.sample_count >= minimumGateSampleCount(requiredSeconds)) {
        return evidence;
      }
    }
  }

  awaitAdmission() {
    return this.awaitGate("initial-admission", ENVIRONMENT_POLICY.initial_admission_seconds);
  }

  awaitObservationStart(label) {
    return this.awaitGate(label, ENVIRONMENT_POLICY.block_admission_seconds, {deadline: true});
  }
}

function baseReceipt(options, frozen, schedule) {
  const affinity = runnerAffinity();
  requireRunnerAffinity(affinity);
  return {
    artifact: ARTIFACT,
    version: VERSION,
    campaign: "milestone-6-dynamic-regression-gate-adjunct",
    created_at: isoNow(),
    requested: {
      output: options.output,
      partial_journal: options.partial,
      append_only_journal: options.journal,
      environment_journal: options.environment_journal,
      binary: options.binary,
      corpus_dir: options.corpus_dir,
      commit: options.commit,
    },
    candidate_commit: options.commit,
    commit_binding: "caller attestation; the recorded benchmark binary SHA-256 is authoritative",
    protocol: {
      independent_unit: "one fresh bench/parse process covering all five canonical corpora",
      process_count: 5,
      retry_policy: "none",
      order: [...ORDER],
      benchmark_cpu: BENCHMARK_CPU,
      benchmark_sibling_cpu: BENCHMARK_SIBLING_CPU,
      runner_cpu: RUNNER_CPU,
      wrapper: "GNU time -v around taskset -c 3",
      parameters: PARAMETERS,
      task_cpu_validity: {
        comparison: ">=",
        percent: ENVIRONMENT_POLICY.minimum_parser_task_cpu_percent,
      },
      environment_policy: ENVIRONMENT_POLICY,
      thermal_monitor: "owned by this dynamic-gate run; samples are durable in the environment journal",
      exclusions: "none; any child, identity, monitor, task-CPU, or receipt failure invalidates the complete run",
    },
    schedule,
    identities: frozen,
    host: {
      hostname: os.hostname(),
      platform: `${os.type()} ${os.release()} ${os.arch()}`,
      cpu_model: os.cpus()[Number(BENCHMARK_CPU)]?.model ?? null,
      runner_affinity: affinity,
      node: process.version,
      node_versions: {...process.versions},
      node_release: {...process.release},
      node_executable: frozen.tools.node,
      argv: [...process.argv],
    },
  };
}

function partialJournal(base, observations, runtime = {}) {
  let analysis = null;
  let analysisError = null;
  if (runtime.interruption === null && runtime.invalid_reason === null &&
      observations.length === base.schedule.length && observations.every((observation) => observation.valid)) {
    try {
      analysis = analyzeObservations(observations, base.schedule);
    } catch (error) {
      analysisError = errorText(error);
    }
  }
  const gates = evaluateGates(analysis);
  const invalid = runtime.invalid_reason !== null || observations.some((observation) => !observation.valid);
  return {
    artifact: `${ARTIFACT}-partial-journal`,
    version: VERSION,
    journal_generation: observations.length,
    updated_at: isoNow(),
    state: runtime.interruption !== null ? "interrupted" : invalid ? "invalid-stop" :
      observations.length === base.schedule.length ? "observations-complete" :
        runtime.admission === null ? "awaiting-admission" : "running",
    base,
    completed_processes: observations.length,
    observations,
    admission: runtime.admission ?? null,
    interruption: runtime.interruption ?? null,
    invalid_reason: runtime.invalid_reason ?? null,
    environment: {
      policy: ENVIRONMENT_POLICY,
      tctl_path: runtime.tctl_path ?? null,
      journal: base.requested.environment_journal,
      sample_count: runtime.monitor?.samples.length ?? 0,
      latest_sample_sequence: runtime.monitor?.samples.at(-1)?.sequence ?? null,
    },
    analysis,
    analysis_error: analysisError,
    gates,
  };
}

function cleanupScratch(directory) {
  try {
    for (const entry of fs.readdirSync(directory)) {
      if (/^process-\d{2}\.(?:time-v\.txt|stdout\.bin|stderr\.bin)$/.test(entry)) {
        fs.unlinkSync(path.join(directory, entry));
      }
    }
    fs.rmdirSync(directory);
  } catch {
    // Scratch cleanup is best-effort. All completed-child bytes are already in
    // the atomic journal or final receipt.
  }
}

function prepare(options) {
  const parent = path.dirname(options.output);
  const parentStat = fs.statSync(parent);
  if (!parentStat.isDirectory()) throw new Error(`output parent is not a directory: ${parent}`);
  for (const [label, file] of Object.entries({
    output: options.output,
    partial: options.partial,
    journal: options.journal,
    environment_journal: options.environment_journal,
  })) {
    if (fs.existsSync(file)) throw new Error(`${label} output already exists: ${file}`);
  }
  requireRunnerAffinity(runnerAffinity());
  const tctlPath = resolveTctlPath();

  const schedule = buildSchedule();
  assertSchedule(schedule);
  const runnerPath = fs.realpathSync(process.argv[1]);
  const frozen = {
    frozen_at: isoNow(),
    binary: fileIdentity(options.binary, {executable: true}),
    binary_build_contract: {
      supplied_as: "release bench/parse binary",
      verification: "caller-supplied build status; executable bytes are frozen and verified by SHA-256",
    },
    runner: fileIdentity(runnerPath, {executable: false}),
    tools: {
      gnu_time: fileIdentity(GNU_TIME, {executable: true}),
      taskset: fileIdentity(TASKSET, {executable: true}),
      node: fileIdentity(process.execPath, {executable: true}),
    },
    corpora: verifyCanonicalCorpora(options.corpus_dir),
  };
  const initial = takeIdentitySnapshot(frozen);
  if (!initial.matched) throw new Error(`initial identity verification failed: ${initial.mismatches.join("; ")}`);
  frozen.initial_verification = initial;
  return {schedule, frozen, tctlPath};
}

async function runCampaign(options) {
  const {schedule, frozen, tctlPath} = prepare(options);
  const base = baseReceipt(options, frozen, schedule);
  const observations = [];
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "fused-json-m6-dynamic-"));
  const runtime = {
    admission: null,
    interruption: null,
    invalid_reason: null,
    monitor: null,
    tctl_path: tctlPath,
    current_child: null,
    runner_error: null,
  };
  const persist = () => atomicReplace(options.partial, partialJournal(base, observations, runtime));
  const event = (name, details = {}) => {
    appendDurableJsonLine(options.journal, {event: name, at: isoNow(), ...details});
    persist();
  };
  const invalidate = (reason) => {
    if (runtime.invalid_reason !== null) return;
    runtime.invalid_reason = {...reason, observed_at: reason.observed_at ?? isoNow()};
    event("dynamic-gate-invalidated", {reason: runtime.invalid_reason});
  };
  const signalExitCode = (signal) => signal === "SIGHUP" ? 129 : signal === "SIGINT" ? 130 : 143;
  const requestInterruption = (signal) => {
    if (runtime.interruption !== null) process.exit(signalExitCode(signal));
    runtime.interruption = {signal, at: isoNow()};
    try {
      event("interruption-requested", runtime.interruption);
    } catch (error) {
      runtime.runner_error = `could not persist interruption request: ${errorText(error)}`;
      runtime.invalid_reason ??= {
        kind: "interruption_persistence_failure",
        detail: runtime.runner_error,
        observed_at: isoNow(),
      };
    }
    runtime.monitor?.stop(new CampaignInvalidError(`interrupted by ${signal}`));
    if (runtime.current_child?.pid) {
      try { process.kill(-runtime.current_child.pid, signal); } catch { /* The child may have exited. */ }
    }
  };
  const signalHandlers = {
    SIGHUP: () => requestInterruption("SIGHUP"),
    SIGINT: () => requestInterruption("SIGINT"),
    SIGTERM: () => requestInterruption("SIGTERM"),
  };

  writeDurableTextNew(options.journal, `${JSON.stringify({
    event: "dynamic-gate-predeclared",
    at: isoNow(),
    artifact: ARTIFACT,
    version: VERSION,
    schedule,
    candidate_commit: options.commit,
    identities: frozen,
  })}\n`);
  writeDurableTextNew(options.environment_journal, `${JSON.stringify({
    event: "environment-log-start",
    at: isoNow(),
    policy: ENVIRONMENT_POLICY,
    tctl_path: tctlPath,
  })}\n`);
  atomicCreate(options.partial, partialJournal(base, observations, runtime));
  runtime.monitor = new EnvironmentMonitor({
    environmentJournal: options.environment_journal,
    tctlPath,
    onInvalid: invalidate,
  });
  for (const [signal, handler] of Object.entries(signalHandlers)) process.on(signal, handler);

  try {
    runtime.monitor.start();
    runtime.admission = await runtime.monitor.awaitAdmission();
    const admissionIssues = gateEvidenceIssues(
      runtime.admission,
      "initial-admission",
      ENVIRONMENT_POLICY.initial_admission_seconds,
      {environmentSamples: runtime.monitor.samples},
    );
    if (admissionIssues.length > 0) {
      throw new CampaignInvalidError(`initial admission audit failed: ${admissionIssues.join("; ")}`);
    }
    event("environment-admitted", runtime.admission);
    for (const entry of schedule) {
      if (runtime.interruption !== null) {
        throw new CampaignInvalidError(`interrupted by ${runtime.interruption.signal}`);
      }
      runtime.monitor.assertValid();
      const startGate = await runtime.monitor.awaitObservationStart(entry.process_id);
      event("process-start-admitted", {
        process_id: entry.process_id,
        gate: startGate,
      });
      const observation = await runChild(entry, options, frozen, scratch, runtime, startGate);
      if (runtime.invalid_reason !== null) {
        observation.validity_issues.push(
          `environment invalidated: ${runtime.invalid_reason.kind}: ${runtime.invalid_reason.detail}`,
        );
      }
      if (runtime.interruption !== null) {
        observation.validity_issues.push(`interrupted by ${runtime.interruption.signal}`);
      }
      observation.valid = observation.validity_issues.length === 0;
      observations.push(observation);
      appendDurableJsonLine(options.journal, {event: "process-complete", at: isoNow(), observation});
      persist();
      console.error(`dynamic gate process ${observations.length}/${schedule.length}: ${entry.order} ${observation.valid ? "valid" : "invalid"}`);
      if (!observation.valid) break;
    }
  } catch (error) {
    runtime.runner_error = errorText(error);
    if (runtime.interruption === null && runtime.invalid_reason === null) {
      invalidate({
        kind: error instanceof CampaignInvalidError ? "campaign_invalid" : "runner_error",
        detail: runtime.runner_error,
      });
    }
  } finally {
    runtime.monitor.stop();
    cleanupScratch(scratch);
    for (const [signal, handler] of Object.entries(signalHandlers)) process.off(signal, handler);
  }

  const invalidReasons = [];
  if (runtime.interruption !== null) {
    invalidReasons.push(`interrupted by ${runtime.interruption.signal} at ${runtime.interruption.at}`);
  }
  if (runtime.invalid_reason !== null) {
    invalidReasons.push(`environment/runner invalidation: ${runtime.invalid_reason.kind}: ${runtime.invalid_reason.detail}`);
  }
  if (observations.length !== schedule.length) {
    invalidReasons.push(`incomplete campaign: retained ${observations.length}/${schedule.length} scheduled processes`);
  }
  for (const observation of observations) {
    for (const issue of observation.validity_issues) {
      invalidReasons.push(`${observation.process_id}: ${issue}`);
    }
  }
  const finalIdentityVerification = takeIdentitySnapshot(frozen);
  if (!finalIdentityVerification.matched) {
    invalidReasons.push(...finalIdentityVerification.mismatches.map((mismatch) => `final identity: ${mismatch}`));
  }
  const gateAudit = {
    policy_name: ENVIRONMENT_POLICY.name,
    policy_version: ENVIRONMENT_POLICY.version,
    initial_admission: null,
    process_starts: [],
    passed: true,
  };
  if (runtime.admission !== null) {
    const issues = gateEvidenceIssues(
      runtime.admission,
      "initial-admission",
      ENVIRONMENT_POLICY.initial_admission_seconds,
      {environmentSamples: runtime.monitor.samples},
    );
    gateAudit.initial_admission = {issues, passed: issues.length === 0};
    for (const issue of issues) invalidReasons.push(`initial admission audit: ${issue}`);
  } else {
    gateAudit.passed = false;
  }
  for (const observation of observations) {
    const issues = gateEvidenceIssues(
      observation.environment_start_gate,
      observation.process_id,
      ENVIRONMENT_POLICY.block_admission_seconds,
      {environmentSamples: runtime.monitor.samples, deadline: true},
    );
    gateAudit.process_starts.push({process_id: observation.process_id, issues, passed: issues.length === 0});
    for (const issue of issues) invalidReasons.push(`${observation.process_id} gate audit: ${issue}`);
  }
  gateAudit.passed = gateAudit.passed &&
    gateAudit.initial_admission?.passed === true &&
    gateAudit.process_starts.length === schedule.length &&
    gateAudit.process_starts.every((entry) => entry.passed);

  const environmentReplay = replayEnvironmentSamples(runtime.monitor.samples);
  for (const issue of environmentReplay.issues) {
    invalidReasons.push(`environment replay: ${issue}`);
  }
  for (const invalidation of environmentReplay.invalidations) {
    invalidReasons.push(
      `environment replay sample ${invalidation.sample_sequence}: ${invalidation.kind}: ${invalidation.detail}`,
    );
  }

  const childReceiptAudit = {
    expected_observations: schedule.length,
    audited_observations: observations.length,
    entries: [],
    passed: observations.length === schedule.length,
  };
  for (let index = 0; index < observations.length; index += 1) {
    const observation = observations[index];
    const entry = schedule[index];
    let issues;
    try {
      issues = entry === undefined ? ["no corresponding frozen schedule entry"] :
        childReceiptIssues(
          observation,
          entry,
          options,
          frozen,
          runtime.monitor.samples,
        );
    } catch (error) {
      issues = [`child receipt replay failed: ${errorText(error)}`];
    }
    childReceiptAudit.entries.push({
      schedule_index: observation?.schedule_index ?? null,
      process_id: observation?.process_id ?? null,
      issues,
      passed: issues.length === 0,
    });
    for (const issue of issues) {
      invalidReasons.push(`${observation?.process_id ?? `observation-${index}`} child replay: ${issue}`);
    }
  }
  if (observations.length !== schedule.length) {
    invalidReasons.push(
      `child receipt replay incomplete: audited ${observations.length}/${schedule.length}`,
    );
  }
  childReceiptAudit.passed = childReceiptAudit.passed &&
    childReceiptAudit.entries.every((entry) => entry.passed);

  const chronology = chronologyAudit(runtime.admission, observations, schedule);
  for (const issue of chronology.issues) invalidReasons.push(`chronology replay: ${issue}`);

  let analysis = null;
  let analysisError = null;
  if (invalidReasons.length === 0) {
    try {
      analysis = analyzeObservations(observations, schedule);
    } catch (error) {
      analysisError = errorText(error);
      invalidReasons.push(`analysis: ${analysisError}`);
    }
  }
  const gates = evaluateGates(analysis);
  const valid = invalidReasons.length === 0 && gates.evaluable;
  const passed = valid && gates.passed;
  const finalReceipt = {
    ...base,
    receipt: "fused-json-m6-dynamic-final",
    completed_at: isoNow(),
    status: finalStatus(valid, passed, runtime.interruption),
    valid,
    passed,
    invalid_reasons: invalidReasons,
    interruption: runtime.interruption,
    runner_error: runtime.runner_error,
    admission: runtime.admission,
    environment: {
      policy: ENVIRONMENT_POLICY,
      tctl_path: tctlPath,
      invalid_reason: runtime.invalid_reason,
      sample_count: runtime.monitor.samples.length,
      samples: runtime.monitor.samples,
      journal: options.environment_journal,
      gate_audit: gateAudit,
    },
    completed_processes: observations.length,
    observations,
    final_identity_verification: finalIdentityVerification,
    independent_audits: {
      environment_replay: environmentReplay,
      child_receipts: childReceiptAudit,
      chronology,
    },
    analysis,
    analysis_error: analysisError,
    gates,
  };
  if (finalReceipt.candidate_commit !== finalReceipt.requested.commit ||
      finalReceipt.observations.some((observation) => observation.fused_json_commit !== finalReceipt.candidate_commit)) {
    throw new Error("internal final receipt commit inconsistency");
  }
  atomicReplace(options.partial, partialJournal(base, observations, runtime));
  appendDurableJsonLine(options.journal, {
    event: "dynamic-gate-finalizing",
    at: isoNow(),
    status: finalReceipt.status,
    valid,
    passed,
  });
  finalReceipt.auxiliary_file_identities = {
    append_only_journal: fileIdentity(options.journal),
    environment_journal: fileIdentity(options.environment_journal),
  };
  atomicCreate(options.output, finalReceipt);
  console.log(JSON.stringify({
    output: options.output,
    partial_journal: options.partial,
    append_only_journal: options.journal,
    environment_journal: options.environment_journal,
    status: finalReceipt.status,
    valid,
    passed,
    completed_processes: observations.length,
    geometric_mean_ratio: analysis?.geometric_mean_of_corpus_median_ratios ?? null,
  }));
  process.exitCode = passed ? 0 : 1;
}

function expectThrow(label, operation) {
  let threw = false;
  try {
    operation();
  } catch {
    threw = true;
  }
  if (!threw) throw new Error(`self-audit expected rejection: ${label}`);
}

function syntheticStdout({
  omitLastAllocation = false,
  wrongFirstSize = false,
  malformed = false,
  reverse = false,
} = {}) {
  const blocks = CORPORA.map((corpus, corpusIndex) => {
    const throughput = {
      "Crystal JSON.parse": "100.00",
      "FusedJSON.load": malformed && corpusIndex === 0 ? "NaN" : "160.00",
      "FusedJSON cached": "170.00",
    };
    const lines = [
      "",
      `${corpus.name}: ${wrongFirstSize && corpusIndex === 0 ? corpus.bytes + 1 : corpus.bytes} bytes`,
      "Crystal JSON.parse  1.00M (1.00us) (plus/minus 1.00%)  10.0kB/op  2.00x slower",
      ...expectedThroughputOrder(reverse).map((label, index) =>
        `  ${label.padEnd(18)} ${throughput[label]} MiB/s  (RSD  ${(index + 1).toFixed(2)}%)`),
      "  Managed allocations",
      "  Crystal JSON.parse       100000 B/op",
      "  FusedJSON.load           110000 B/op",
      "  FusedJSON cached         105000 B/op",
    ];
    if (omitLastAllocation && corpusIndex === CORPORA.length - 1) lines.pop();
    return lines.join("\n");
  });
  return `${blocks.join("\n")}\n`;
}

function syntheticObservation(entry, corpusMedians, sampleMultiplier) {
  return {
    schedule_index: entry.index,
    process_id: entry.process_id,
    order: entry.order,
    valid: true,
    parsed_output: {
      schema: "fused-json-parse-custom-output-v1",
      corpora: CORPORA.map((corpus, index) => ({
        name: corpus.name,
        bytes: corpus.bytes,
        implementations: {
          crystal_json_parse: {label: "Crystal JSON.parse", mib_per_second: 100, relative_stddev_percent: 1, managed_bytes_per_operation: 1000 + index},
          fused_json_load: {label: "FusedJSON.load", mib_per_second: 100 * corpusMedians[index] * sampleMultiplier, relative_stddev_percent: 1, managed_bytes_per_operation: 1100 + index},
          fused_json_cached: {label: "FusedJSON cached", mib_per_second: 200, relative_stddev_percent: 1, managed_bytes_per_operation: 1050 + index},
        },
      })),
    },
  };
}

function runSelfAudit() {
  const checks = {};
  if (VERSION !== 2 || ENVIRONMENT_POLICY.version !== 2) {
    throw new Error("dynamic receipt or environment policy schema is not v2");
  }
  checks.schema = "dynamic receipts and busy-pinned environment policy are explicitly version 2";
  const schedule = buildSchedule();
  assertSchedule(schedule);
  if (schedule.filter((entry) => entry.order === "normal").length !== 3 ||
      schedule.filter((entry) => entry.order === "reverse").length !== 2) {
    throw new Error("schedule self-audit found the wrong order counts");
  }
  checks.schedule = "five unique fresh-process entries in normal/reverse/normal/reverse/normal order";

  const parsed = parseCustomOutput(syntheticStdout(), CORPORA, false);
  if (parsed.corpora.length !== CORPORA.length ||
      parsed.corpora.some((corpus) => Math.abs(corpus.fused_load_to_crystal_ratio - 1.6) > 1e-12)) {
    throw new Error("custom-output parser self-audit produced the wrong ratios");
  }
  expectThrow("missing allocation line", () => parseCustomOutput(syntheticStdout({omitLastAllocation: true})));
  expectThrow("wrong corpus size", () => parseCustomOutput(syntheticStdout({wrongFirstSize: true})));
  expectThrow("malformed throughput", () => parseCustomOutput(syntheticStdout({malformed: true})));
  parseCustomOutput(syntheticStdout({reverse: true}), CORPORA, true);
  expectThrow("normal output for reverse process", () =>
    parseCustomOutput(syntheticStdout(), CORPORA, true));
  expectThrow("reverse output for normal process", () =>
    parseCustomOutput(syntheticStdout({reverse: true}), CORPORA, false));
  checks.parser = "accepted complete MiB/s and B/op blocks in requested order; rejected missing, wrong-size, malformed, and wrong-order data";

  if (median([9, 1, 5, 3, 7]) !== 5 || median([4, 2, 1, 3]) !== 2.5 ||
      Math.abs(geometricMean([1, 4]) - 2) > 1e-12) {
    throw new Error("median or geometric-mean primitive failed self-audit");
  }
  const corpusMedians = [1.4, 1.5, 1.6, 1.7, 1.8];
  const multipliers = [1, 0.5, 1.5, 0.9, 1.1];
  const observations = schedule.map((entry, index) => syntheticObservation(entry, corpusMedians, multipliers[index]));
  const analysis = analyzeObservations(observations, schedule);
  for (let index = 0; index < CORPORA.length; index += 1) {
    if (Math.abs(analysis.corpora[index].median_fused_load_to_crystal_ratio - corpusMedians[index]) > 1e-12) {
      throw new Error(`per-corpus median self-audit failed for ${CORPORA[index].name}`);
    }
  }
  const expectedGeo = Math.pow(corpusMedians.reduce((product, value) => product * value, 1), 1 / corpusMedians.length);
  if (Math.abs(analysis.geometric_mean_of_corpus_median_ratios - expectedGeo) > 1e-12) {
    throw new Error("cross-corpus geometric mean self-audit failed");
  }
  checks.statistics = "odd/even medians, per-corpus ratio medians, and cross-corpus geometric mean verified";

  const boundaryAnalysis = {
    geometric_mean_of_corpus_median_ratios: 1.5,
    corpora: CORPORA.map((corpus) => ({name: corpus.name, median_fused_load_to_crystal_ratio: 0.98})),
  };
  if (!evaluateGates(boundaryAnalysis).passed) throw new Error("inclusive gate boundaries were rejected");
  const lowGeo = structuredClone(boundaryAnalysis);
  lowGeo.geometric_mean_of_corpus_median_ratios = 1.5 - Number.EPSILON;
  if (evaluateGates(lowGeo).passed) throw new Error("sub-threshold geometric mean passed");
  const lowCorpus = structuredClone(boundaryAnalysis);
  lowCorpus.corpora[2].median_fused_load_to_crystal_ratio = 0.98 - Number.EPSILON;
  if (evaluateGates(lowCorpus).passed) throw new Error("sub-threshold corpus median passed");
  if (evaluateGates(null).passed || evaluateGates(null).evaluable) throw new Error("missing analysis was gateable");
  checks.gates = "inclusive geo>=1.5 and every-median>=0.98 boundaries plus both rejection paths verified";

  expectThrow("four of five processes", () => analyzeObservations(observations.slice(0, 4), schedule));
  const invalid = structuredClone(observations);
  invalid[1].valid = false;
  expectThrow("invalid child", () => analyzeObservations(invalid, schedule));
  const missingCorpus = structuredClone(observations);
  missingCorpus[3].parsed_output.corpora.pop();
  expectThrow("missing corpus result", () => analyzeObservations(missingCorpus, schedule));
  checks.incomplete_data = "rejected missing process, invalid child, missing corpus, and unevaluable analysis";

  const parsedTctl = parseTctlInput("94000\n");
  if (parsedTctl.raw_millicelsius !== "94000" || parsedTctl.celsius !== 94) {
    throw new Error("strict Tctl parser produced the wrong value");
  }
  for (const malformedTctl of [
    "", " \n", "-1", "094000", "94.0", "+94000", "NaN", "1e5",
    "9007199254740992",
  ]) {
    expectThrow(`malformed Tctl ${JSON.stringify(malformedTctl)}`, () =>
      parseTctlInput(malformedTctl));
  }
  checks.sensor_input = "strict integer Tctl parsing rejects empty, malformed, and unsafe sensor reads";

  const environmentBase = {
    sequence: 0,
    label: "monitor",
    observed_at: "2026-08-24T00:00:00.000Z",
    monotonic_ms: 1_000,
    read_errors: [],
    gap_seconds: 2,
    tctl_c: 94,
    load1: 5,
    load5: 5,
    cpu2_busy_percent: 25,
    cpu3_busy_percent: 10,
    cpu3_scaling_cur_freq_khz: 4_000_000,
    cpu3_frequency_error: null,
  };
  if (!sameJson(ENVIRONMENT_POLICY, {
    name: "busy-pinned-v2",
    version: 2,
    sample_interval_ms: 2_000,
    initial_admission_seconds: 60,
    block_admission_seconds: 6,
    gate_load1_maximum: 5,
    gate_load5_maximum: 5,
    gate_tctl_maximum_c: 94,
    gate_tctl_range_maximum_c: 5,
    gate_sibling_cpu_busy_maximum_percent: 25,
    gate_benchmark_cpu_busy_maximum_percent: 10,
    block_gate_deadline_seconds: 180,
    invalid_tctl_minimum_c: 100,
    invalid_load1_strictly_greater_than: 7,
    invalid_sibling_busy_strictly_greater_than_percent: 35,
    consecutive_breach_samples: 2,
    maximum_monitor_gap_seconds: 5,
    minimum_parser_task_cpu_percent: 99,
    child_window_sibling_busy_maximum_percent: 25,
    cpu_frequency_policy: "diagnostic-only; never gates, excludes, or normalizes",
  })) {
    throw new Error("busy-pinned-v2 policy identity or thresholds changed");
  }
  if (!gateSampleAcceptable(environmentBase) ||
      gateSampleAcceptable({...environmentBase, load1: 5.001}) ||
      gateSampleAcceptable({...environmentBase, load5: 5.001}) ||
      gateSampleAcceptable({...environmentBase, tctl_c: 94.001}) ||
      gateSampleAcceptable({...environmentBase, cpu2_busy_percent: 25.001}) ||
      gateSampleAcceptable({...environmentBase, cpu3_busy_percent: 10.001}) ||
      gateSampleAcceptable({...environmentBase, load1: -0.001}) ||
      gateSampleAcceptable({...environmentBase, tctl_c: -0.001}) ||
      gateSampleAcceptable({...environmentBase, cpu2_busy_percent: -0.001})) {
    throw new Error("environment gate boundary self-audit failed");
  }
  const stableGateSamples = Array.from({length: 31}, (_, index) => ({
    ...environmentBase,
    sequence: index + 1,
    monotonic_ms: 1_000 + (index * 2_000),
    tctl_c: index % 2 === 0 ? 89 : 94,
  }));
  if (gateTctlRange(stableGateSamples) !== 5) {
    throw new Error("inclusive Tctl range boundary self-audit failed");
  }
  const admissionEvidence = gateEvidence(
    "initial-admission",
    stableGateSamples,
    ENVIRONMENT_POLICY.initial_admission_seconds,
    {
      waitStartedMonotonicMs: 999,
      admittedEvaluatedMonotonicMs: 61_001,
    },
  );
  if (admissionEvidence.continuous_seconds !== 60 ||
      admissionEvidence.sample_sequences.length !== 31 ||
      admissionEvidence.sample_count !== 31 ||
      admissionEvidence.tctl_range_c !== 5 ||
      admissionEvidence.policy_name !== "busy-pinned-v2" ||
      admissionEvidence.policy_version !== 2 ||
      gateEvidenceIssues(admissionEvidence, "initial-admission", 60, {
        environmentSamples: stableGateSamples,
      }).length !== 0) {
    throw new Error("gate evidence self-audit failed");
  }
  const sparseAdmissionSamples = Array.from({length: 30}, (_, index) => ({
    ...environmentBase,
    sequence: index + 1,
    monotonic_ms: 1_000 + Math.round(index * (60_000 / 29)),
    tctl_c: 90,
  }));
  const sparseAdmissionEvidence = gateEvidence(
    "initial-admission",
    sparseAdmissionSamples,
    ENVIRONMENT_POLICY.initial_admission_seconds,
    {
      waitStartedMonotonicMs: 999,
      admittedEvaluatedMonotonicMs: 61_001,
    },
  );
  if (sparseAdmissionEvidence.continuous_seconds !== 60 ||
      gateEvidenceIssues(sparseAdmissionEvidence, "initial-admission", 60, {
        environmentSamples: sparseAdmissionSamples,
      }).length === 0) {
    throw new Error("sparse 60-second gate window was accepted");
  }
  const blockEvidence = gateEvidence(
    "synthetic-block",
    stableGateSamples.slice(0, 4),
    ENVIRONMENT_POLICY.block_admission_seconds,
    {
      waitStartedMonotonicMs: 999,
      absoluteDeadlineMonotonicMs: 180_999,
      admittedEvaluatedMonotonicMs: 7_001,
    },
  );
  if (blockEvidence.continuous_seconds !== 6 ||
      gateEvidenceIssues(blockEvidence, "synthetic-block", 6, {
        environmentSamples: stableGateSamples,
        deadline: true,
      }).length !== 0) {
    throw new Error("six-second block gate self-audit failed");
  }
  const alteredEvidence = structuredClone(blockEvidence);
  alteredEvidence.tctl_range_c = 5.001;
  if (gateEvidenceIssues(alteredEvidence, "synthetic-block", 6, {
    environmentSamples: stableGateSamples,
    deadline: true,
  }).length === 0) {
    throw new Error("out-of-range block gate evidence was accepted");
  }
  const contaminatedGateSamples = structuredClone(stableGateSamples);
  contaminatedGateSamples[2].load1 = 5.001;
  if (gateEvidenceIssues(blockEvidence, "synthetic-block", 6, {
    environmentSamples: contaminatedGateSamples,
    deadline: true,
  }).length === 0) {
    throw new Error("gate evidence accepted an out-of-limit cited environment sample");
  }
  const gappedEvidence = structuredClone(blockEvidence);
  gappedEvidence.sample_sequences[2] += 1;
  if (gateEvidenceIssues(gappedEvidence, "synthetic-block", 6, {
    environmentSamples: stableGateSamples,
    deadline: true,
  }).length === 0) {
    throw new Error("gate evidence accepted noncontiguous sample sequences");
  }
  const deadlineEqualityEvidence = structuredClone(blockEvidence);
  deadlineEqualityEvidence.admitted_evaluated_monotonic_ms = 180_999;
  if (gateEvidenceIssues(deadlineEqualityEvidence, "synthetic-block", 6, {
    environmentSamples: stableGateSamples,
    deadline: true,
  }).length !== 0) {
    throw new Error("inclusive absolute block deadline was rejected");
  }
  const lateEvidence = structuredClone(deadlineEqualityEvidence);
  lateEvidence.admitted_evaluated_monotonic_ms += 0.001;
  if (gateEvidenceIssues(lateEvidence, "synthetic-block", 6, {
    environmentSamples: stableGateSamples,
    deadline: true,
  }).length === 0) {
    throw new Error("late absolute block deadline was accepted");
  }
  const unstableGateSamples = [
    {...environmentBase, sequence: 1, tctl_c: 88},
    {...environmentBase, sequence: 2, monotonic_ms: 3_000, tctl_c: 94},
  ];
  resetUnstableGateWindow(unstableGateSamples);
  if (unstableGateSamples.length !== 1 || unstableGateSamples[0].sequence !== 2) {
    throw new Error("Tctl range suffix reset self-audit failed");
  }
  let environmentState = {load_breaches: 0, sibling_breaches: 0};
  if (environmentInvalidation(environmentState, {...environmentBase, load1: 7}) !== null ||
      environmentInvalidation(environmentState, {...environmentBase, load1: 7}) !== null ||
      environmentInvalidation(environmentState, {...environmentBase, load1: 7.001}) !== null ||
      environmentInvalidation(environmentState, {...environmentBase, load1: 7.001})?.kind !== "load") {
    throw new Error("two-sample load invalidation self-audit failed");
  }
  environmentState = {load_breaches: 0, sibling_breaches: 0};
  if (environmentInvalidation(environmentState, {...environmentBase, cpu2_busy_percent: 35}) !== null) {
    throw new Error("inclusive sibling invalidation boundary self-audit failed");
  }
  environmentInvalidation(environmentState, {...environmentBase, cpu2_busy_percent: 35.001});
  environmentInvalidation(environmentState, environmentBase);
  if (environmentInvalidation(environmentState, {...environmentBase, cpu2_busy_percent: 35.001}) !== null ||
      environmentInvalidation(environmentState, {...environmentBase, cpu2_busy_percent: 35.001})?.kind !== "sibling_cpu") {
    throw new Error("sibling-CPU breach reset self-audit failed");
  }
  if (environmentInvalidation(
    {load_breaches: 0, sibling_breaches: 0}, {...environmentBase, tctl_c: 100},
  )?.kind !== "temperature" || environmentInvalidation(
    {load_breaches: 0, sibling_breaches: 0}, {...environmentBase, gap_seconds: 5.001},
  )?.kind !== "monitor_gap" || environmentInvalidation(
    {load_breaches: 0, sibling_breaches: 0}, {...environmentBase, read_errors: ["x"]},
  )?.kind !== "environment_read_failure") {
    throw new Error("environment hard-invalidation self-audit failed");
  }

  const replaySamples = [
    {...environmentBase, sequence: 0, label: "monitor-start", monotonic_ms: 1_000,
      gap_seconds: null, load1: 7, tctl_c: 99.999,
      cpu2_busy_percent: null, cpu3_busy_percent: null},
    {...environmentBase, sequence: 1, label: "monitor", monotonic_ms: 3_000, gap_seconds: 2,
      load1: 7, tctl_c: 99.999, cpu2_busy_percent: 35},
  ];
  if (!replayEnvironmentSamples(replaySamples).passed) {
    throw new Error("valid retained environment samples failed replay");
  }
  const loadReplaySamples = structuredClone(replaySamples);
  loadReplaySamples[0].load1 = 7.001;
  loadReplaySamples[1].load1 = 7.001;
  const loadReplay = replayEnvironmentSamples(loadReplaySamples);
  if (loadReplay.invalidations.length !== 1 ||
      loadReplay.invalidations[0].kind !== "load" ||
      loadReplay.invalidations[0].sample_sequence !== 1) {
    throw new Error("environment replay did not reproduce the two-sample load breach");
  }
  const sensorReplaySamples = [
    {...replaySamples[0], tctl_c: null, read_errors: ["Tctl: invalid Tctl input"]},
  ];
  if (replayEnvironmentSamples(sensorReplaySamples).invalidations[0]?.kind !==
      "environment_read_failure") {
    throw new Error("environment replay did not retain malformed-sensor invalidation");
  }
  const wrongGapSamples = structuredClone(replaySamples);
  wrongGapSamples[1].gap_seconds = 1;
  if (replayEnvironmentSamples(wrongGapSamples).issues.length === 0) {
    throw new Error("environment replay accepted a gap inconsistent with monotonic times");
  }
  const coerciveReplaySamples = structuredClone(replaySamples);
  coerciveReplaySamples[1].load1 = "5";
  if (replayEnvironmentSamples(coerciveReplaySamples).issues.length === 0) {
    throw new Error("environment replay accepted a coercive numeric value");
  }
  const reversedTimeSamples = structuredClone(replaySamples);
  reversedTimeSamples[1].monotonic_ms = 999;
  reversedTimeSamples[1].gap_seconds = -0.001;
  if (replayEnvironmentSamples(reversedTimeSamples).issues.length === 0) {
    throw new Error("environment replay accepted non-increasing monotonic time");
  }

  const chronologyAdmission = {
    admitted_sample_sequence: 0,
    admitted_evaluated_monotonic_ms: 500,
  };
  const chronologicalObservations = schedule.map((entry, index) => {
    const blockBase = 1_000 + (index * 10_000);
    const sampleBase = 1 + (index * 10);
    return {
      schedule_index: entry.index,
      process_id: entry.process_id,
      order: entry.order,
      environment_start_gate: {
        wait_started_monotonic_ms: blockBase,
        first_acceptable_monotonic_ms: blockBase + 1_000,
        admitted_monotonic_ms: blockBase + 7_000,
        admitted_evaluated_monotonic_ms: blockBase + 7_001,
        first_acceptable_sample_sequence: sampleBase,
        admitted_sample_sequence: sampleBase + 3,
      },
      environment_start_sample_sequence: sampleBase + 3,
      environment_end_sample_sequence: sampleBase + 4,
      child_environment_window: {
        before: {monotonic_ms: blockBase + 8_000},
        after: {monotonic_ms: blockBase + 9_000},
      },
    };
  });
  if (!chronologyAudit(chronologyAdmission, chronologicalObservations, schedule).passed) {
    throw new Error("valid cross-process chronology failed replay");
  }
  const recycledGateObservations = structuredClone(chronologicalObservations);
  recycledGateObservations[1].environment_start_gate.wait_started_monotonic_ms = 1_000;
  recycledGateObservations[1].environment_start_gate.first_acceptable_monotonic_ms = 2_000;
  if (chronologyAudit(chronologyAdmission, recycledGateObservations, schedule).passed) {
    throw new Error("chronology replay accepted a recycled gate window");
  }
  const recycledSequenceObservations = structuredClone(chronologicalObservations);
  recycledSequenceObservations[1].environment_start_gate.first_acceptable_sample_sequence =
    recycledSequenceObservations[0].environment_end_sample_sequence;
  if (chronologyAudit(chronologyAdmission, recycledSequenceObservations, schedule).passed) {
    throw new Error("chronology replay accepted a recycled gate sample sequence");
  }
  const lateGateObservations = structuredClone(chronologicalObservations);
  lateGateObservations[2].environment_start_gate.admitted_evaluated_monotonic_ms = 29_000.001;
  if (chronologyAudit(chronologyAdmission, lateGateObservations, schedule).passed) {
    throw new Error("chronology replay accepted gate admission after the child boundary");
  }
  if (!startSampleBindingMatches({
    environment_start_sample_sequence: 4,
    environment_start_gate: {admitted_sample_sequence: 4},
  }) || startSampleBindingMatches({
    environment_start_sample_sequence: 3,
    environment_start_gate: {admitted_sample_sequence: 4},
  })) {
    throw new Error("redundant environment start sample binding self-audit failed");
  }
  requireRunnerAffinity("0");
  expectThrow("runner not pinned only to CPU 0", () => requireRunnerAffinity("0-3"));
  if (!blockGateSampleTimely(1_000, 181_000, 181_000) ||
      blockGateSampleTimely(1_000, 181_000.001, 181_000.001) ||
      blockGateSampleTimely(1_000, 180_000, 181_000.001)) {
    throw new Error("absolute block-gate deadline self-audit failed");
  }

  const syntheticBoundary = (monotonicMs, line, tctlRaw) => {
    const parsedCounters = parseCpuCounters(`${line}\n`, BENCHMARK_SIBLING_CPU);
    return {
      observed_at: "2026-08-24T00:00:00.000Z",
      monotonic_ms: monotonicMs,
      proc_stat_cpu_line: line,
      counters: parsedCounters.counters.map((value) => value.toString()),
      total_ticks: parsedCounters.total.toString(),
      idle_ticks: parsedCounters.idle.toString(),
      tctl_raw_millicelsius: tctlRaw,
      tctl_c: Number(tctlRaw) / 1_000,
    };
  };
  const childBefore = syntheticBoundary(
    1_000, "cpu2 100 0 50 400 50", "94000",
  );
  const childAfterAtLimit = syntheticBoundary(
    2_000, "cpu2 120 0 80 530 70", "94000",
  );
  const exactChildWindow = childEnvironmentWindow(childBefore, childAfterAtLimit);
  if (exactChildWindow.cpu_busy_percent !== 25 || !exactChildWindow.within_busy_limit ||
      childEnvironmentWindowIssues(exactChildWindow).length !== 0) {
    throw new Error("inclusive child-window CPU boundary self-audit failed");
  }
  const childBindingSamples = [
    {...replaySamples[0], monotonic_ms: 900},
    {...replaySamples[1], monotonic_ms: 1_900, gap_seconds: 1},
    {...replaySamples[1], sequence: 2, monotonic_ms: 2_100, gap_seconds: 0.2},
  ];
  const childBindingReceipt = {
    environment_start_gate: {admitted_sample_sequence: 0},
    environment_start_sample_sequence: 0,
    environment_end_sample_sequence: 1,
    child_environment_window: exactChildWindow,
  };
  if (childEnvironmentSampleBindingIssues(
    childBindingReceipt,
    childBindingSamples,
  ).length !== 0) {
    throw new Error("valid child environment sample binding failed replay");
  }
  const staleChildBinding = structuredClone(childBindingReceipt);
  staleChildBinding.environment_end_sample_sequence = 0;
  if (childEnvironmentSampleBindingIssues(
    staleChildBinding,
    childBindingSamples,
  ).length === 0) {
    throw new Error("stale child environment end sample was accepted");
  }
  const missingBoundaryField = structuredClone(exactChildWindow);
  delete missingBoundaryField.before.tctl_c;
  if (childEnvironmentWindowIssues(missingBoundaryField).length === 0) {
    throw new Error("missing child boundary field was accepted");
  }
  const timingReceipt = {
    child_environment_window: exactChildWindow,
    started_at: "2026-08-24T00:00:00.000Z",
    finished_at: "2026-08-24T00:00:00.000Z",
    started_monotonic_ms: 1_100,
    finished_monotonic_ms: 1_900,
    elapsed_monotonic_seconds: 0.8,
  };
  if (childBoundaryTimingIssues(timingReceipt).length !== 0) {
    throw new Error("enclosing child boundary timing was rejected");
  }
  const escapedTimingReceipt = structuredClone(timingReceipt);
  escapedTimingReceipt.finished_monotonic_ms = 2_001;
  escapedTimingReceipt.elapsed_monotonic_seconds = 0.901;
  if (childBoundaryTimingIssues(escapedTimingReceipt).length === 0) {
    throw new Error("non-enclosing child boundary timing was accepted");
  }
  const childAfterOverLimit = syntheticBoundary(
    2_000, "cpu2 121 0 80 529 70", "94000",
  );
  const overLimitWindow = childEnvironmentWindow(childBefore, childAfterOverLimit);
  if (overLimitWindow.cpu_busy_percent !== 25.5 || overLimitWindow.within_busy_limit ||
      childEnvironmentWindowIssues(overLimitWindow).length === 0) {
    throw new Error("over-limit child-window CPU self-audit failed");
  }
  const hotBoundary = syntheticBoundary(
    2_000, "cpu2 120 0 80 530 70", "100000",
  );
  if (childEnvironmentWindowIssues(childEnvironmentWindow(childBefore, hotBoundary)).length === 0) {
    throw new Error("child boundary temperature invalidation self-audit failed");
  }
  checks.environment = "busy-pinned-v2 gates, global replay, cross-process chronology, strict invalidations, child-window counters, and runner affinity verified";

  const interrupted = {signal: "SIGINT", at: "2026-08-24T00:00:00.000Z"};
  const interruptionJournal = partialJournal(
    {schedule, requested: {environment_journal: "/tmp/synthetic.environment.jsonl"}},
    [],
    {admission: null, interruption: interrupted, invalid_reason: null, monitor: null, tctl_path: "/sys/Tctl"},
  );
  if (interruptionJournal.state !== "interrupted" || interruptionJournal.analysis !== null ||
      interruptionJournal.gates.evaluable || finalStatus(false, false, interrupted) !== "interrupted") {
    throw new Error("interruption state self-audit failed");
  }
  checks.interruption = "interrupted partial data remains unevaluable and final status is explicitly interrupted";

  const durabilityDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "fused-json-dynamic-self-audit-"));
  try {
    const shortWriteFragments = [];
    writeAllSync(123, Buffer.from("short-write-audit", "utf8"),
      (_fd, buffer, offset, length) => {
        const written = Math.min(3, length);
        shortWriteFragments.push(Buffer.from(buffer.subarray(offset, offset + written)));
        return written;
      });
    if (Buffer.concat(shortWriteFragments).toString("utf8") !== "short-write-audit") {
      throw new Error("write-all loop lost bytes across short writes");
    }
    expectThrow("zero-length synchronous write", () =>
      writeAllSync(123, Buffer.from("x"), () => 0));
    const atomicFile = path.join(durabilityDirectory, "atomic.json");
    const eventFile = path.join(durabilityDirectory, "events.jsonl");
    atomicCreate(atomicFile, {generation: 0});
    atomicReplace(atomicFile, {generation: 1});
    if (JSON.parse(fs.readFileSync(atomicFile, "utf8")).generation !== 1) {
      throw new Error("atomic replacement did not retain generation 1");
    }
    writeDurableTextNew(eventFile, `${JSON.stringify({event: "predeclared"})}\n`);
    appendDurableJsonLine(eventFile, {event: "complete"});
    if (fs.readFileSync(eventFile, "utf8").trim().split("\n").length !== 2) {
      throw new Error("append-only event journal has the wrong line count");
    }
  } finally {
    fs.rmSync(durabilityDirectory, {recursive: true, force: true});
  }
  checks.durability = "short-write completion, generation-0 create, atomic replacement, and append-only journal writes verified";

  const timeSample = [
    "\tUser time (seconds): 10.00",
    "\tSystem time (seconds): 0.10",
    "\tPercent of CPU this job got: 99%",
    "\tElapsed (wall clock) time (h:mm:ss or m:ss): 0:10.20",
    "\tMaximum resident set size (kbytes): 12345",
    "\tMajor (requiring I/O) page faults: 0",
    "\tMinor (reclaiming a frame) page faults: 100",
    "\tVoluntary context switches: 3",
    "\tInvoluntary context switches: 4",
    "\tExit status: 0",
  ].join("\n") + "\n";
  const audit = parseGnuTimeVerbose(timeSample);
  if (audit.reported_cpu_percent !== 99 || audit.elapsed_wall_seconds !== 10.2 ||
      audit.total_context_switches !== 7 || audit.exit_status !== 0) {
    throw new Error("GNU time parser self-audit failed");
  }
  checks.task_audit = "GNU time -v CPU, elapsed, RSS, faults, switches, and exit status parsed";

  const runner = fileIdentity(fs.realpathSync(process.argv[1]));
  const nodeExecutable = fileIdentity(process.execPath, {executable: true});
  if (!/^[0-9a-f]{64}$/.test(nodeExecutable.sha256) ||
      process.version !== `v${process.versions.node}` || Object.keys(process.versions).length < 2) {
    throw new Error("Node interpreter identity self-audit failed");
  }
  checks.interpreter_identity = "Node executable SHA-256, process.version, and full process.versions are available";
  console.log(JSON.stringify({
    self_audit: `${ARTIFACT}-self-audit`,
    version: VERSION,
    passed: true,
    runner_sha256: runner.sha256,
    checks,
  }, null, 2));
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.self_audit) {
    runSelfAudit();
    return;
  }
  await runCampaign(options);
}

main().catch((error) => {
  if (error instanceof UsageError) {
    console.error(`${error.message}\n${usage()}`);
    process.exitCode = 64;
    return;
  }
  console.error(`${ARTIFACT}: ${errorText(error)}`);
  process.exitCode = 1;
});
