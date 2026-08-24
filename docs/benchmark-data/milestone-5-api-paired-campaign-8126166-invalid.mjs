#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {spawn} from "node:child_process";
import {performance} from "node:perf_hooks";

const WORKLOADS = [
  "string-dynamic",
  "io-dynamic",
  "string-pull",
  "string-skip",
  "io-pull",
  "io-skip",
  "string-typed",
  "io-typed",
];
const CANDIDATE_COMMIT = "812616652cbf05470f963e4238260e9ca5d9d38a";
const BINARIES = {
  limits_api: {
    path: "/tmp/fused-json-limits-v8-m5-api-paired",
    sha256: "36b36fdd7c5627626127c8f75b8bde4df33f87562a9eb2c52ee3971876c1d2e6",
  },
};
const BENCHMARK_CPU = "3";
const BENCHMARK_SIBLING_CPU = "2";
const RUNNER_CPU = "0";
const GNU_TIME = "/usr/bin/time";
const TASK_AUDIT_FORMAT = "fused-json-task-audit-v1\t%U\t%S\t%e\t%P\t%c\t%w\t%F\t%R\t%M\t%x";
const TASK_EXECUTION_LIMITS = {
  // A reported 99% CPU share bounds scheduler/preemption loss to less than
  // one percent, half of the default campaign's two-percent median/geo
  // tolerance. GNU time reports this field as an integer percentage.
  minimum_reported_cpu_percent: 99,
};
const TEMPERATURE_LIMITS = {admission_c: 60, observation_start_c: 60, invalid_c: 95};
const LOAD_LIMITS = {
  admission_load1: 2.5,
  admission_load5: 2.5,
  invalid_load1: 4.0,
};
const CORE_LIMITS = {
  admission_busy_percent: 10,
  invalid_sibling_busy_percent: 20,
};
const SAMPLE_INTERVAL_MS = 2_000;
const ADMISSION_SECONDS = 60;
const MAX_SAMPLE_GAP_SECONDS = 5;
const MAX_OBSERVATION_COOLDOWN_SECONDS = 180;
const PAIRS_PER_WORKLOAD = 20;
const FIXTURE = {
  records: 10_000,
  buffer_size: 32_768,
  warmup_seconds: 0.5,
  calculation_seconds: 1.5,
  allocation_iterations: 20,
};
const BOOTSTRAP = {seed: 20_260_822, resamples: 10_000, lower_index: 500};
const DESIGN_CAVEATS = [
  "The paired benchmark source is frozen at candidate commit 812616652cbf05470f963e4238260e9ca5d9d38a and the runner verifies its release binary hash before and after the campaign.",
  "ABBA batch cycles reduce between-process state noise but can introduce cache, allocator, and GC carryover; balanced initial order mitigates rather than eliminates it.",
  "Only the 20 fresh-process ratios per workload are independent statistical units; interleaved batches within a child are not independent samples.",
  "The GNU task CPU-share audit covers the whole paired child and cannot identify an interruption confined to one configuration.",
  "A full-parameter smoke rose from 59.125C to 93.625C, so the formal policy is frozen at 60C admission/start, 180s cooldown, and the unchanged 95C runtime invalidation threshold.",
  "scaling_cur_freq is a coarse instantaneous sysfs diagnostic, not an APERF/MPERF effective-clock measurement, and never affects validity or acceptance.",
  "The Tctl hwmon index can change across boots; the runner resolves the path by its Tctl label at campaign start.",
];

function usage() {
  console.error("usage: fused-json-m5-api-paired-8126166.mjs --output=/new/path\n" +
    "       fused-json-m5-api-paired-8126166.mjs --self-audit");
  process.exit(64);
}

function parseArgs() {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-audit") return {selfAudit: true};
  const parsed = {};
  for (const arg of args) {
    const match = arg.match(/^--([^=]+)=(.*)$/);
    if (!match) usage();
    parsed[match[1]] = match[2];
  }
  if (Object.keys(parsed).length !== 1 || !parsed.output) usage();
  return {selfAudit: false, output: path.resolve(parsed.output)};
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function jsonWrite(file, value) {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, {encoding: "utf8", flag: "wx"});
}

function appendJsonLine(file, value) {
  fs.appendFileSync(file, `${JSON.stringify(value)}\n`, "utf8");
}

function isoNow() {
  return new Date().toISOString();
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
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
      if (fs.existsSync(inputPath)) return inputPath;
    }
  }
  throw new Error("could not resolve a Tctl sysfs input");
}

function scalingFrequencyPath() {
  const candidate = `/sys/devices/system/cpu/cpu${BENCHMARK_CPU}/cpufreq/scaling_cur_freq`;
  return fs.existsSync(candidate) ? candidate : null;
}

function readOptionalSysfs(file) {
  if (file === null || !fs.existsSync(file)) return null;
  try {
    return fs.readFileSync(file, "utf8").trim();
  } catch {
    return null;
  }
}

function frequencyMetadata(currentPath) {
  const root = `/sys/devices/system/cpu/cpu${BENCHMARK_CPU}/cpufreq`;
  return {
    scaling_cur_freq_path: currentPath,
    scaling_driver: readOptionalSysfs(path.join(root, "scaling_driver")),
    scaling_governor: readOptionalSysfs(path.join(root, "scaling_governor")),
    energy_performance_preference: readOptionalSysfs(path.join(root, "energy_performance_preference")),
    scaling_min_freq_khz: Number(readOptionalSysfs(path.join(root, "scaling_min_freq"))) || null,
    scaling_max_freq_khz: Number(readOptionalSysfs(path.join(root, "scaling_max_freq"))) || null,
    sample_interval_seconds: SAMPLE_INTERVAL_MS / 1_000,
    policy: "diagnostic-only: scaling_cur_freq is sampled but never gates, excludes, or normalizes an observation",
  };
}

function buildSchedule() {
  const rounds = PAIRS_PER_WORKLOAD;
  const first = "default";
  const second = "explicit-empty";
  const schedule = [];
  for (let round = 0; round < rounds; round += 1) {
    for (let slot = 0; slot < WORKLOADS.length; slot += 1) {
      const workloadIndex = (slot + round) % WORKLOADS.length;
      // Invert the slot-parity order every two rounds and again after each
      // complete workload rotation. Repeated workload/slot cells alternate
      // order, and the 20-round campaign is balanced by workload and by slot.
      const orderPhase = (Math.floor(round / 2) + Math.floor(round / WORKLOADS.length)) % 2;
      const firstSideFirst = ((slot + orderPhase) % 2) === 0;
      const order = firstSideFirst ? [first, second] : [second, first];
      const index = schedule.length;
      schedule.push({
        index,
        pair_id: `m5-api-paired-v1-${String(index).padStart(3, "0")}-${String(round).padStart(2, "0")}-${slot}-${WORKLOADS[workloadIndex]}-${order[0]}-first`,
        round,
        slot,
        workload: WORKLOADS[workloadIndex],
        order,
      });
    }
  }

  if (schedule.length !== rounds * WORKLOADS.length) throw new Error("bad schedule length");
  for (let round = 0; round < rounds; round += 1) {
    const entries = schedule.filter((entry) => entry.round === round);
    if (new Set(entries.map((entry) => entry.workload)).size !== WORKLOADS.length) {
      throw new Error(`round ${round} does not contain every workload once`);
    }
    if (entries.filter((entry) => entry.order[0] === first).length !== 4) {
      throw new Error(`round ${round} is not order-balanced`);
    }
  }
  for (const workload of WORKLOADS) {
    const entries = schedule.filter((entry) => entry.workload === workload);
    if (entries.length !== rounds || entries.filter((entry) => entry.order[0] === first).length !== rounds / 2) {
      throw new Error(`${workload} is not balanced`);
    }
    for (let slot = 0; slot < WORKLOADS.length; slot += 1) {
      const cell = entries.filter((entry) => entry.slot === slot).sort((left, right) => left.round - right.round);
      if (cell.slice(1).some((entry, index) => entry.order[0] === cell[index].order[0])) {
        throw new Error(`${workload} slot ${slot} does not alternate repeated orders`);
      }
    }
  }
  for (let slot = 0; slot < WORKLOADS.length; slot += 1) {
    const entries = schedule.filter((entry) => entry.slot === slot);
    const firstCount = entries.filter((entry) => entry.order[0] === first).length;
    if (entries.length !== rounds || firstCount === 0 || firstCount === rounds) {
      throw new Error(`slot ${slot} does not contain both orders`);
    }
    if (firstCount !== rounds / 2) {
      throw new Error(`slot ${slot} is not order-balanced`);
    }
  }
  return schedule;
}

function campaignDefinition() {
  return {
    id: "m5-default-vs-explicit-empty-paired-process-v1",
    rounds: PAIRS_PER_WORKLOAD,
    workloads: WORKLOADS,
    numerator: "explicit-empty",
    denominator: "default",
    binary: "limits_api",
    gates: {median: 0.99, geometric_mean: 0.99, bootstrap_lower: 0.98},
  };
}

function assertBinary(binaryName) {
  const expected = BINARIES[binaryName];
  const stat = fs.statSync(expected.path);
  if (!stat.isFile()) throw new Error(`${expected.path} is not a regular file`);
  const actualHash = sha256(expected.path);
  if (actualHash !== expected.sha256) {
    throw new Error(`${binaryName} hash mismatch: expected ${expected.sha256}, got ${actualHash}`);
  }
  return {path: expected.path, sha256: actualHash, bytes: stat.size};
}

function assertTaskAuditBinary() {
  const stat = fs.statSync(GNU_TIME);
  if (!stat.isFile()) throw new Error(`${GNU_TIME} is not a regular file`);
  return {
    path: GNU_TIME,
    realpath: fs.realpathSync(GNU_TIME),
    sha256: sha256(GNU_TIME),
    bytes: stat.size,
  };
}

function assertRunnerFile() {
  const realpath = fs.realpathSync(process.argv[1]);
  const stat = fs.statSync(realpath);
  if (!stat.isFile()) throw new Error(`${realpath} is not a regular file`);
  return {
    path: process.argv[1],
    realpath,
    sha256: sha256(realpath),
    bytes: stat.size,
  };
}

function parseTaskAudit(raw) {
  const lines = raw.trim().split("\n").filter(Boolean);
  if (lines.length !== 1) throw new Error(`expected one task-audit record, got ${lines.length}`);
  const fields = lines[0].split("\t");
  if (fields.length !== 11 || fields[0] !== "fused-json-task-audit-v1") {
    throw new Error("wrong task-audit schema");
  }
  const decimal = (index, label) => {
    const value = Number(fields[index]);
    if (!Number.isFinite(value) || value < 0) throw new Error(`invalid task-audit ${label}: ${fields[index]}`);
    return value;
  };
  const integer = (index, label) => {
    if (!/^\d+$/.test(fields[index])) throw new Error(`invalid task-audit ${label}: ${fields[index]}`);
    return Number(fields[index]);
  };
  const percentMatch = fields[4].match(/^(\d+)%$/);
  if (!percentMatch) throw new Error(`invalid task-audit CPU percentage: ${fields[4]}`);
  const reportedCpuPercent = Number(percentMatch[1]);
  if (reportedCpuPercent > 100) throw new Error(`impossible single-CPU task share: ${fields[4]}`);
  const userCpuSeconds = decimal(1, "user CPU seconds");
  const systemCpuSeconds = decimal(2, "system CPU seconds");
  const elapsedWallSeconds = decimal(3, "elapsed wall seconds");
  if (elapsedWallSeconds === 0) throw new Error("task-audit elapsed wall seconds is zero");
  const involuntaryContextSwitches = integer(5, "involuntary context switches");
  const voluntaryContextSwitches = integer(6, "voluntary context switches");
  return {
    schema: fields[0],
    user_cpu_seconds: userCpuSeconds,
    system_cpu_seconds: systemCpuSeconds,
    task_cpu_seconds: userCpuSeconds + systemCpuSeconds,
    elapsed_wall_seconds: elapsedWallSeconds,
    cpu_time_over_wall_from_rounded_seconds: (userCpuSeconds + systemCpuSeconds) / elapsedWallSeconds,
    reported_cpu_percent: reportedCpuPercent,
    reported_cpu_share: reportedCpuPercent / 100,
    involuntary_context_switches: involuntaryContextSwitches,
    voluntary_context_switches: voluntaryContextSwitches,
    total_context_switches: involuntaryContextSwitches + voluntaryContextSwitches,
    major_page_faults: integer(7, "major page faults"),
    minor_page_faults: integer(8, "minor page faults"),
    maximum_resident_kibibytes: integer(9, "maximum resident set"),
    exit_status: integer(10, "exit status"),
  };
}

function taskAuditValidityIssue(audit) {
  if (audit.reported_cpu_percent < TASK_EXECUTION_LIMITS.minimum_reported_cpu_percent) {
    return `reported task CPU share ${audit.reported_cpu_percent}% is below ` +
      `${TASK_EXECUTION_LIMITS.minimum_reported_cpu_percent}% ` +
      `(involuntary=${audit.involuntary_context_switches}, voluntary=${audit.voluntary_context_switches})`;
  }
  return null;
}

function selfAffinity() {
  const match = fs.readFileSync("/proc/self/status", "utf8").match(/^Cpus_allowed_list:\s*(.+)$/m);
  if (!match) throw new Error("could not read runner CPU affinity");
  return match[1].trim();
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle];
}

function geometricMean(values) {
  return Math.exp(values.reduce((sum, value) => sum + Math.log(value), 0) / values.length);
}

function mulberry32(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4_294_967_296;
  };
}

function bootstrapLower(ratios) {
  const random = mulberry32(BOOTSTRAP.seed);
  const estimates = new Array(BOOTSTRAP.resamples);
  for (let sample = 0; sample < BOOTSTRAP.resamples; sample += 1) {
    let logSum = 0;
    for (let index = 0; index < ratios.length; index += 1) {
      logSum += Math.log(ratios[Math.floor(random() * ratios.length)]);
    }
    estimates[sample] = Math.exp(logSum / ratios.length);
  }
  estimates.sort((a, b) => a - b);
  return estimates[BOOTSTRAP.lower_index];
}

function sameJson(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function assertPairedReceipt(receipt, entry) {
  const fail = (message) => { throw new Error(`paired receipt ${entry.index}: ${message}`); };
  if (receipt.receipt !== "fused-json-limits-overhead-paired" || receipt.version !== 1) fail("wrong schema");
  if (receipt.workload !== entry.workload) fail("wrong workload");
  if (receipt.pair_id !== entry.pair_id) fail("wrong pair ID");
  if (!Number.isInteger(receipt.process_pid) || receipt.process_pid <= 0) fail("invalid process PID");
  const fixture = receipt.fixture;
  if (fixture?.format !== "fused-json-limits-overhead" || fixture?.version !== 1 ||
      fixture?.records !== FIXTURE.records || !Number.isInteger(fixture?.bytes) || fixture.bytes <= 0 ||
      !/^[0-9a-f]{64}$/.test(fixture?.sha256 ?? "") ||
      !/^[0-9a-f]{64}$/.test(fixture?.semantic_sha256 ?? "")) fail("wrong fixture identity");
  if (receipt.pairing_key !== `v3:${entry.workload}:${fixture.sha256}`) fail("wrong pairing key");
  if (receipt.semantic_verification?.status !== "verified") fail("semantics were not verified");
  if (receipt.paired_protocol?.version !== 1 || receipt.paired_protocol?.common_process !== true ||
      receipt.paired_protocol?.interleaved_batches !== true ||
      receipt.paired_protocol?.batch_pattern !== "ABBA" ||
      receipt.paired_protocol?.allocation_samples_per_configuration !== 2 ||
      !sameJson(receipt.paired_protocol?.requested_initial_order, entry.order) ||
      !sameJson(receipt.paired_protocol?.observed_initial_order, entry.order) ||
      !sameJson(receipt.paired_protocol?.allocation_order,
        [entry.order[0], entry.order[1], entry.order[1], entry.order[0]]) ||
      !Array.isArray(receipt.paired_protocol?.measurement_order) ||
      receipt.paired_protocol.measurement_order.length < 2) fail("wrong paired protocol or order");
  const measurementOrder = receipt.paired_protocol.measurement_order;
  const expectedCycle = [entry.order[0], entry.order[1], entry.order[1], entry.order[0]];
  if (measurementOrder.length % expectedCycle.length !== 0 ||
      measurementOrder.some((configuration, index) => configuration !== expectedCycle[index % expectedCycle.length])) {
    fail("measurement batches did not repeat the requested ABBA cycle");
  }
  if (receipt.build?.fused_json_commit !== CANDIDATE_COMMIT || receipt.build?.release !== true ||
      receipt.build?.limits_api !== true) fail("wrong build identity");
  if (receipt.host?.cpu_affinity !== BENCHMARK_CPU) fail("wrong CPU affinity");
  if (receipt.disabled_limits === null || typeof receipt.disabled_limits !== "object") fail("wrong disabled-limits shape");
  if (entry.workload.startsWith("io-") && receipt.parser_options?.buffer_size !== FIXTURE.buffer_size) fail("wrong IO buffer");
  if (!entry.workload.startsWith("io-") && receipt.parser_options?.buffer_size !== null) fail("unexpected String buffer");
  const env = receipt.environment;
  if (env?.GC_NPROCS !== "1" || env?.GC_MARKERS !== "1" || env?.CRYSTAL_WORKERS !== "1" ||
      env?.OMP_NUM_THREADS !== "1" || env?.FUSED_JSON_BENCH_CPU !== BENCHMARK_CPU ||
      env?.FUSED_JSON_BENCH_COMMIT !== null) fail("wrong benchmark environment");

  const expectedConfigurations = ["default", "explicit-empty"];
  if (!sameJson(Object.keys(receipt.measurements ?? {}).sort(), expectedConfigurations)) {
    fail("wrong measurement configurations");
  }
  const batchCounts = {};
  for (const configuration of expectedConfigurations) {
    const side = receipt.measurements[configuration];
    const expectedCallStyle = configuration === "default" ?
      "limits keyword omitted" : "limits: FusedJSON::Limits.new";
    if (side?.configuration !== configuration || side?.call_style !== expectedCallStyle) {
      fail(`wrong ${configuration} identity`);
    }
    const measurement = side.measurement;
    if (measurement?.estimator !== "total-iterations-over-total-elapsed-v1") {
      fail(`wrong ${configuration} estimator`);
    }
    if (measurement?.warmup_seconds !== FIXTURE.warmup_seconds ||
        measurement?.calculation_seconds !== FIXTURE.calculation_seconds ||
        measurement?.allocation_iterations !== FIXTURE.allocation_iterations) {
      fail(`wrong ${configuration} measurement parameters`);
    }
    if (!Number.isFinite(measurement.iterations_per_second) || measurement.iterations_per_second <= 0 ||
        !Number.isFinite(measurement.managed_bytes_per_operation) || measurement.managed_bytes_per_operation < 0 ||
        !Number.isInteger(measurement.iterations) || measurement.iterations <= 0 ||
        !Number.isInteger(measurement.batches) || measurement.batches <= 0 ||
        measurement.iterations % measurement.batches !== 0 ||
        !Number.isFinite(measurement.elapsed_seconds) || measurement.elapsed_seconds < FIXTURE.calculation_seconds ||
        !Number.isFinite(measurement.relative_stddev_percent) || measurement.relative_stddev_percent < 0) {
      fail(`invalid ${configuration} measurement`);
    }
    batchCounts[configuration] = measurement.batches;
  }
  if (measurementOrder.length !== batchCounts.default + batchCounts["explicit-empty"] ||
      batchCounts.default !== batchCounts["explicit-empty"] ||
      measurementOrder.filter((configuration) => configuration === "default").length !== batchCounts.default ||
      measurementOrder.filter((configuration) => configuration === "explicit-empty").length !== batchCounts["explicit-empty"]) {
    fail("measurement order and batch counts differ");
  }
}

function childEnvironment() {
  return {
    PATH: "/usr/bin:/bin",
    LANG: "C",
    LC_ALL: "C",
    TZ: "UTC",
    GC_NPROCS: "1",
    GC_MARKERS: "1",
    CRYSTAL_WORKERS: "1",
    OMP_NUM_THREADS: "1",
    FUSED_JSON_BENCH_CPU: BENCHMARK_CPU,
  };
}

function analyze(pairs, definition) {
  const results = [];
  for (const workload of definition.workloads) {
    const workloadPairs = pairs.filter((pair) => pair.workload === workload).sort((a, b) => a.round - b.round);
    const ratios = workloadPairs.map((pair) => {
      const measurements = pair.observation.receipt.measurements;
      const numerator = measurements[definition.numerator].measurement.iterations_per_second;
      const denominator = measurements[definition.denominator].measurement.iterations_per_second;
      return numerator / denominator;
    });
    const denominatorAllocations = workloadPairs.map((pair) =>
      pair.observation.receipt.measurements[definition.denominator].measurement.managed_bytes_per_operation);
    const numeratorAllocations = workloadPairs.map((pair) =>
      pair.observation.receipt.measurements[definition.numerator].measurement.managed_bytes_per_operation);
    const denominatorMedian = median(denominatorAllocations);
    const numeratorMedian = median(numeratorAllocations);
    const allocationTolerance = Math.max(4_096, denominatorMedian * 0.001);
    const metrics = {
      workload,
      pairs: workloadPairs.length,
      ratios,
      throughput: {
        median_ratio: median(ratios),
        geometric_mean_ratio: geometricMean(ratios),
        bootstrap_one_sided_95_lower: bootstrapLower(ratios),
      },
      allocation: {
        denominator_median_bytes_per_operation: denominatorMedian,
        numerator_median_bytes_per_operation: numeratorMedian,
        tolerance_bytes: allocationTolerance,
        maximum_numerator_bytes_per_operation: denominatorMedian + allocationTolerance,
      },
    };
    metrics.gates = {
      median: metrics.throughput.median_ratio >= definition.gates.median,
      geometric_mean: metrics.throughput.geometric_mean_ratio >= definition.gates.geometric_mean,
      bootstrap_lower: metrics.throughput.bootstrap_one_sided_95_lower >= definition.gates.bootstrap_lower,
      allocation: numeratorMedian <= denominatorMedian + allocationTolerance,
    };
    metrics.passed = Object.values(metrics.gates).every(Boolean);
    results.push(metrics);
  }
  return results;
}

function summarizeRatioSubset(pairs, definition) {
  const ratios = pairs.map((pair) => {
    const measurements = pair.observation.receipt.measurements;
    const numerator = measurements[definition.numerator].measurement.iterations_per_second;
    const denominator = measurements[definition.denominator].measurement.iterations_per_second;
    return numerator / denominator;
  });
  return {
    pairs: ratios.length,
    rounds: pairs.map((pair) => pair.round),
    median_ratio: median(ratios),
    geometric_mean_ratio: geometricMean(ratios),
    minimum_ratio: Math.min(...ratios),
    maximum_ratio: Math.max(...ratios),
  };
}

function pairedDiagnostics(pairs, definition) {
  return definition.workloads.map((workload) => {
    const ordered = pairs.filter((pair) => pair.workload === workload).sort((left, right) => left.round - right.round);
    const midpoint = definition.rounds / 2;
    const earlySummary = summarizeRatioSubset(ordered.filter((pair) => pair.round < midpoint), definition);
    const lateSummary = summarizeRatioSubset(ordered.filter((pair) => pair.round >= midpoint), definition);
    return {
      workload,
      purpose: "diagnostic strata only; acceptance uses all 20 independent process-pairs and unchanged gates",
      chronology: {
        early: earlySummary,
        late: lateSummary,
        late_to_early_geometric_mean: lateSummary.geometric_mean_ratio / earlySummary.geometric_mean_ratio,
      },
      initial_batch_order: {
        default_first: summarizeRatioSubset(ordered.filter((pair) => pair.order[0] === "default"), definition),
        explicit_empty_first: summarizeRatioSubset(ordered.filter((pair) => pair.order[0] === "explicit-empty"), definition),
      },
    };
  });
}

function scheduleDesign() {
  return {
    version: 1,
    independent_unit: "one fresh child process containing one paired default/explicit-empty observation",
    pairs_per_workload: PAIRS_PER_WORKLOAD,
    total_processes: PAIRS_PER_WORKLOAD * WORKLOADS.length,
    within_process_measurement: "approximately 100 ms batches in repeating ABBA cycles derived from the requested initial order",
    workload_rotation: "workload_index=(slot+round)%workload_count",
    initial_order_counterbalance: "phase=(floor(round/2)+floor(round/workload_count))%2; first_side_first=(slot+phase)%2==0; 10 AB and 10 BA processes per workload",
    repeated_workload_slot_order: "alternating",
    frequency_policy: "diagnostic samples only; no observation is excluded, gated, or normalized by frequency",
  };
}

function runSelfAudit() {
  const runnerSource = fs.readFileSync(fs.realpathSync(process.argv[1]), "utf8");
  const metadataWrites = runnerSource.match(
    /^    jsonWrite\(path\.join\(options\.output, "observations", `\$\{prefix\}\.meta\.json`\), metadata\);$/gm
  ) ?? [];
  if (metadataWrites.length !== 1) {
    throw new Error("runner must contain exactly one observation metadata write");
  }
  const definition = campaignDefinition();
  const schedule = buildSchedule();
  if (!sameJson(TEMPERATURE_LIMITS, {admission_c: 60, observation_start_c: 60, invalid_c: 95}) ||
      MAX_OBSERVATION_COOLDOWN_SECONDS !== 180) {
    throw new Error("paired campaign thermal policy changed");
  }
  const expectedPairs = definition.rounds * definition.workloads.length;
  if (schedule.length !== expectedPairs) throw new Error("paired campaign schedule length mismatch");
  if (new Set(schedule.map((entry) => entry.pair_id)).size !== schedule.length) {
    throw new Error("paired campaign pair IDs are not unique");
  }
  if (schedule.some((entry) => !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(entry.pair_id))) {
    throw new Error("paired campaign generated an unsafe pair ID");
  }
  if (!sameJson(definition.gates, {median: 0.99, geometric_mean: 0.99, bootstrap_lower: 0.98})) {
    throw new Error("paired campaign gates changed");
  }
  for (const workload of definition.workloads) {
    const entries = schedule.filter((entry) => entry.workload === workload);
    if (entries.length !== PAIRS_PER_WORKLOAD ||
        entries.filter((entry) => entry.order[0] === "default").length !== PAIRS_PER_WORKLOAD / 2 ||
        entries.filter((entry) => entry.order[0] === "explicit-empty").length !== PAIRS_PER_WORKLOAD / 2) {
      throw new Error(`${workload} does not have 20 balanced process-pairs`);
    }
  }
  const sample = parseTaskAudit("fused-json-task-audit-v1\t2.31\t0.02\t2.35\t99%\t4\t8\t0\t1234\t50000\t0\n");
  if (taskAuditValidityIssue(sample) !== null || sample.total_context_switches !== 12 || sample.exit_status !== 0) {
    throw new Error("valid task-audit sample was rejected or misparsed");
  }
  if (taskAuditValidityIssue({...sample, reported_cpu_percent: 98}) === null) {
    throw new Error("low-CPU task-audit sample was accepted");
  }
  const syntheticReceipt = (entry, explicitIps) => ({
    receipt: "fused-json-limits-overhead-paired",
    version: 1,
    workload: entry.workload,
    pair_id: entry.pair_id,
    process_pid: 12_345,
    pairing_key: `v3:${entry.workload}:${"0".repeat(64)}`,
    fixture: {
      format: "fused-json-limits-overhead",
      version: 1,
      records: FIXTURE.records,
      bytes: 1_000_000,
      sha256: "0".repeat(64),
      semantic_sha256: "1".repeat(64),
    },
    semantic_verification: {status: "verified"},
    paired_protocol: {
      version: 1,
      common_process: true,
      interleaved_batches: true,
      batch_pattern: "ABBA",
      requested_initial_order: entry.order,
      observed_initial_order: entry.order,
      allocation_order: [entry.order[0], entry.order[1], entry.order[1], entry.order[0]],
      allocation_samples_per_configuration: 2,
      measurement_order: [entry.order[0], entry.order[1], entry.order[1], entry.order[0]],
    },
    build: {fused_json_commit: CANDIDATE_COMMIT, release: true, limits_api: true},
    host: {cpu_affinity: BENCHMARK_CPU},
    disabled_limits: {},
    parser_options: {buffer_size: entry.workload.startsWith("io-") ? FIXTURE.buffer_size : null},
    environment: {GC_NPROCS: "1", GC_MARKERS: "1", CRYSTAL_WORKERS: "1", OMP_NUM_THREADS: "1", FUSED_JSON_BENCH_CPU: BENCHMARK_CPU, FUSED_JSON_BENCH_COMMIT: null},
    measurements: Object.fromEntries(["default", "explicit-empty"].map((configuration) => [configuration, {
      configuration,
      call_style: configuration === "default" ? "limits keyword omitted" : "limits: FusedJSON::Limits.new",
      measurement: {
        estimator: "total-iterations-over-total-elapsed-v1",
        warmup_seconds: FIXTURE.warmup_seconds,
        calculation_seconds: FIXTURE.calculation_seconds,
        allocation_iterations: FIXTURE.allocation_iterations,
        iterations_per_second: configuration === "default" ? 100 : explicitIps,
        iterations: 200,
        batches: 2,
        elapsed_seconds: 2,
        relative_stddev_percent: 0,
        managed_bytes_per_operation: 1_000,
      },
    }])),
  });
  const syntheticPairs = schedule.map((entry) => {
    const receipt = syntheticReceipt(entry, 100);
    assertPairedReceipt(receipt, entry);
    return {...entry, observation: {receipt}};
  });
  const rejectionEntry = schedule[0];
  const expectReceiptRejection = (label, mutate) => {
    const receipt = syntheticReceipt(rejectionEntry, 100);
    mutate(receipt);
    try {
      assertPairedReceipt(receipt, rejectionEntry);
    } catch {
      return;
    }
    throw new Error(`paired receipt self-audit accepted ${label}`);
  };
  expectReceiptRejection("a wrong pair ID", (receipt) => { receipt.pair_id = "wrong"; });
  expectReceiptRejection("a non-positive PID", (receipt) => { receipt.process_pid = 0; });
  expectReceiptRejection("an alternating non-ABBA order", (receipt) => {
    const order = rejectionEntry.order;
    receipt.paired_protocol.measurement_order = [order[0], order[1], order[0], order[1]];
  });
  expectReceiptRejection("non-divisible iterations", (receipt) => {
    receipt.measurements.default.measurement.iterations += 1;
  });
  if (!analyze(syntheticPairs, definition).every((result) => result.passed)) {
    throw new Error("neutral synthetic paired campaign failed");
  }
  const regressedPairs = schedule.map((entry) => ({...entry, observation: {receipt: syntheticReceipt(entry, 97)}}));
  if (analyze(regressedPairs, definition).some((result) => result.passed)) {
    throw new Error("regressed synthetic paired campaign passed");
  }
  const wrapper = assertTaskAuditBinary();
  const pairedBinary = assertBinary("limits_api");
  const tctlPath = resolveTctlPath();
  const frequencyPath = scalingFrequencyPath();
  console.log(JSON.stringify({
    status: "passed",
    campaign: {pairs: schedule.length, pairs_per_workload: PAIRS_PER_WORKLOAD, workloads: definition.workloads, gates: definition.gates},
    thermal_policy: {...TEMPERATURE_LIMITS, max_observation_cooldown_seconds: MAX_OBSERVATION_COOLDOWN_SECONDS},
    paths: {tctl: tctlPath, scaling_cur_freq: frequencyPath},
    frequency: frequencyMetadata(frequencyPath),
    frequency_is_acceptance_gate: false,
    design_caveats: DESIGN_CAVEATS,
    task_execution_limit: TASK_EXECUTION_LIMITS,
    paired_binary: pairedBinary,
    wrapper,
  }, null, 2));
}

async function main() {
  const options = parseArgs();
  if (options.selfAudit) {
    runSelfAudit();
    return;
  }
  const definition = campaignDefinition();
  const runnerAffinity = selfAffinity();
  if (runnerAffinity !== RUNNER_CPU) {
    throw new Error(`runner must be pinned to CPU ${RUNNER_CPU}; affinity is ${runnerAffinity}`);
  }
  fs.mkdirSync(options.output, {recursive: false});
  fs.mkdirSync(path.join(options.output, "observations"));
  const environmentFile = path.join(options.output, "environment.jsonl");
  const eventFile = path.join(options.output, "events.jsonl");
  const tctlPath = resolveTctlPath();
  const frequencyPath = scalingFrequencyPath();
  const usedBinaryNames = [definition.binary];
  const binaryMetadata = Object.fromEntries(usedBinaryNames.map((name) => [name, assertBinary(name)]));
  const taskAuditBinaryMetadata = assertTaskAuditBinary();
  const runnerFileMetadata = assertRunnerFile();
  const schedule = buildSchedule();
  const manifest = {
    artifact: "fused-json-milestone-5-api-paired-campaign",
    version: 1,
    campaign: "api-paired",
    id: definition.id,
    created_at: isoNow(),
    candidate_commit: CANDIDATE_COMMIT,
    binaries: binaryMetadata,
    host: {hostname: os.hostname(), platform: `${os.type()} ${os.release()} ${os.arch()}`, cpu_model: os.cpus()[Number(BENCHMARK_CPU)]?.model},
    cpus: {
      runner: RUNNER_CPU,
      runner_affinity: runnerAffinity,
      runner_siblings: fs.readFileSync(`/sys/devices/system/cpu/cpu${RUNNER_CPU}/topology/thread_siblings_list`, "utf8").trim(),
      benchmark: BENCHMARK_CPU,
      benchmark_sibling: BENCHMARK_SIBLING_CPU,
      benchmark_siblings: fs.readFileSync(`/sys/devices/system/cpu/cpu${BENCHMARK_CPU}/topology/thread_siblings_list`, "utf8").trim(),
    },
    tctl_path: tctlPath,
    cpu_frequency: frequencyMetadata(frequencyPath),
    fixture: FIXTURE,
    bootstrap: BOOTSTRAP,
    admission: {seconds: ADMISSION_SECONDS, sample_interval_seconds: 2, ...TEMPERATURE_LIMITS, ...LOAD_LIMITS, ...CORE_LIMITS, max_sample_gap_seconds: MAX_SAMPLE_GAP_SECONDS, max_observation_cooldown_seconds: MAX_OBSERVATION_COOLDOWN_SECONDS},
    thermal_rationale: "predeclared before formal observations after a full-parameter paired smoke rose from 59.125C to 93.625C; runtime invalidation remains 95C",
    comparison: {numerator: definition.numerator, denominator: definition.denominator, gates: definition.gates},
    schedule_design: scheduleDesign(),
    benchmark_contract: {
      status: "canonical paired binary validated against the version-1 receipt contract and frozen by commit and SHA-256",
      arguments: ["--configuration=paired", "--paired-order=default,explicit-empty|explicit-empty,default", "--pair-id=SCHEDULE_ENTRY_ID"],
      receipt: "fused-json-limits-overhead-paired version 1",
      measurement_unit: "one child emits one common-process paired receipt",
    },
    design_caveats: DESIGN_CAVEATS,
    task_execution_audit: {
      schema: "fused-json-task-audit-v1",
      wrapper: taskAuditBinaryMetadata,
      format: TASK_AUDIT_FORMAT,
      scope: "whole taskset child, including common setup, both interleaved measurements, allocation samples, and paired receipt emission",
      validity: {
        metric: "GNU time %P (task user+system CPU time divided by task wall time)",
        ...TASK_EXECUTION_LIMITS,
        maximum_reported_non_cpu_percent: 100 - TASK_EXECUTION_LIMITS.minimum_reported_cpu_percent,
        rationale: "with all child threads pinned to one logical CPU, a 99% reported task CPU share bounds visible scheduler/preemption loss to about one percent; both sides share the same audited child process",
        context_switch_policy: "voluntary and involuntary counts are recorded for diagnosis but are not gated because switch counts do not measure descheduled duration",
      },
    },
    child_environment: childEnvironment(),
    runner: {node: process.version, argv: process.argv, file: runnerFileMetadata},
  };
  jsonWrite(path.join(options.output, "manifest.json"), manifest);
  jsonWrite(path.join(options.output, "schedule.json"), schedule);
  appendJsonLine(eventFile, {at: isoNow(), event: "prepared", pairs: schedule.length});

  let lastSampleMonotonic = null;
  let invalidReason = null;
  let stopMonitor = false;
  let consecutiveLoadBreaches = 0;
  let consecutiveSiblingBreaches = 0;
  let lastCpuCounters = null;
  let lastEnvironmentSample = null;
  let previousObservationFinishedMonotonic = null;

  function readCpuCounters() {
    const wanted = new Set([BENCHMARK_CPU, BENCHMARK_SIBLING_CPU].map((cpu) => `cpu${cpu}`));
    const counters = {};
    for (const line of fs.readFileSync("/proc/stat", "utf8").split("\n")) {
      const fields = line.trim().split(/\s+/);
      if (!wanted.has(fields[0])) continue;
      const values = fields.slice(1, 9).map(Number);
      if (values.length !== 8 || !values.every(Number.isFinite)) throw new Error(`bad ${fields[0]} counters`);
      counters[fields[0].slice(3)] = {
        total: values.reduce((sum, value) => sum + value, 0),
        idle: values[3] + values[4],
      };
    }
    if (Object.keys(counters).length !== wanted.size) throw new Error("missing benchmark CPU counters");
    return counters;
  }

  function takeSample(phase) {
    const monotonic = performance.now() / 1_000;
    let load1 = null;
    let load5 = null;
    let runnable = null;
    let tasks = null;
    let tctlC = null;
    let cpuBusyPercent = null;
    let readError = null;
    let scalingCurFreqKHz = null;
    let scalingCurFreqReadError = null;
    try {
      const fields = fs.readFileSync("/proc/loadavg", "utf8").trim().split(/\s+/);
      load1 = Number(fields[0]);
      load5 = Number(fields[1]);
      [runnable, tasks] = fields[3].split("/").map(Number);
      const rawTemperature = fs.readFileSync(tctlPath, "utf8").trim();
      tctlC = Number(rawTemperature) / 1_000;
      if (![load1, load5, runnable, tasks, tctlC].every(Number.isFinite)) throw new Error("non-finite environmental value");
      const cpuCounters = readCpuCounters();
      if (lastCpuCounters !== null) {
        cpuBusyPercent = {};
        for (const cpu of [BENCHMARK_CPU, BENCHMARK_SIBLING_CPU]) {
          const total = cpuCounters[cpu].total - lastCpuCounters[cpu].total;
          const idle = cpuCounters[cpu].idle - lastCpuCounters[cpu].idle;
          if (total < 0 || idle < 0 || idle > total) throw new Error(`bad cpu${cpu} counter delta`);
          cpuBusyPercent[cpu] = total === 0 ? null : 100 * (total - idle) / total;
        }
      }
      lastCpuCounters = cpuCounters;
    } catch (error) {
      readError = String(error?.message ?? error);
    }
    if (frequencyPath === null) {
      scalingCurFreqReadError = "scaling_cur_freq is unavailable";
    } else {
      try {
        scalingCurFreqKHz = Number(fs.readFileSync(frequencyPath, "utf8").trim());
        if (!Number.isFinite(scalingCurFreqKHz) || scalingCurFreqKHz <= 0) {
          throw new Error("non-positive or non-finite scaling_cur_freq");
        }
      } catch (error) {
        scalingCurFreqKHz = null;
        scalingCurFreqReadError = String(error?.message ?? error);
      }
    }
    const sample = {
      at: isoNow(),
      monotonic_seconds: monotonic,
      phase,
      gap_seconds: lastSampleMonotonic === null ? null : monotonic - lastSampleMonotonic,
      load1,
      load5,
      runnable,
      tasks,
      tctl_c: tctlC,
      cpu_busy_percent: cpuBusyPercent,
      benchmark_cpu_scaling_cur_freq_khz: scalingCurFreqKHz,
      scaling_cur_freq_read_error: scalingCurFreqReadError,
      scaling_cur_freq_acceptance_gate: false,
      read_error: readError,
    };
    lastSampleMonotonic = monotonic;
    lastEnvironmentSample = sample;
    appendJsonLine(environmentFile, sample);
    return sample;
  }

  console.log(`waiting for ${ADMISSION_SECONDS}s admission: output=${options.output}`);
  let goodSince = null;
  let admissionSampleCount = 0;
  let admissionEnd = null;
  while (admissionEnd === null) {
    const sample = takeSample("admission");
    admissionSampleCount += 1;
    const good = sample.read_error === null &&
      (sample.gap_seconds === null || sample.gap_seconds <= MAX_SAMPLE_GAP_SECONDS) &&
      sample.load1 <= LOAD_LIMITS.admission_load1 &&
      sample.load5 <= LOAD_LIMITS.admission_load5 &&
      sample.tctl_c <= TEMPERATURE_LIMITS.admission_c &&
      sample.cpu_busy_percent !== null &&
      Number.isFinite(sample.cpu_busy_percent[BENCHMARK_CPU]) &&
      Number.isFinite(sample.cpu_busy_percent[BENCHMARK_SIBLING_CPU]) &&
      sample.cpu_busy_percent[BENCHMARK_CPU] <= CORE_LIMITS.admission_busy_percent &&
      sample.cpu_busy_percent[BENCHMARK_SIBLING_CPU] <= CORE_LIMITS.admission_busy_percent;
    if (good) {
      if (goodSince === null) goodSince = sample.monotonic_seconds;
      if (sample.monotonic_seconds - goodSince >= ADMISSION_SECONDS) admissionEnd = sample;
    } else {
      goodSince = null;
    }
    if (admissionSampleCount === 1 || admissionSampleCount % 5 === 0 || admissionEnd !== null) {
      const held = goodSince === null ? 0 : sample.monotonic_seconds - goodSince;
      const coreValue = (cpu) => Number.isFinite(sample.cpu_busy_percent?.[cpu]) ? sample.cpu_busy_percent[cpu].toFixed(1) : "n/a";
      const core = `${coreValue(BENCHMARK_SIBLING_CPU)}/${coreValue(BENCHMARK_CPU)}%`;
      console.log(`admission load=${sample.load1}/${sample.load5} run=${sample.runnable} temp=${sample.tctl_c}C cpu${BENCHMARK_SIBLING_CPU}/${BENCHMARK_CPU}=${core} good=${held.toFixed(1)}s`);
    }
    if (admissionEnd === null) await delay(SAMPLE_INTERVAL_MS);
  }
  appendJsonLine(eventFile, {at: isoNow(), event: "admitted", sample: admissionEnd});

  function invalidate(reason) {
    if (invalidReason !== null) return;
    invalidReason = {at: isoNow(), ...reason};
    appendJsonLine(eventFile, {event: "invalidated", ...invalidReason});
    console.error(`campaign invalidated: ${reason.kind}: ${reason.detail}`);
  }

  async function runtimeMonitor() {
    while (!stopMonitor) {
      await delay(SAMPLE_INTERVAL_MS);
      const sample = takeSample("campaign");
      if (sample.read_error !== null) invalidate({kind: "environment_read", detail: sample.read_error});
      if (sample.gap_seconds > MAX_SAMPLE_GAP_SECONDS) {
        invalidate({kind: "monitor_gap", detail: `${sample.gap_seconds}s`});
      }
      if (sample.tctl_c >= TEMPERATURE_LIMITS.invalid_c) {
        invalidate({kind: "temperature", detail: `${sample.tctl_c}C`});
      }
      consecutiveLoadBreaches = sample.load1 > LOAD_LIMITS.invalid_load1 ? consecutiveLoadBreaches + 1 : 0;
      const siblingBusy = sample.cpu_busy_percent?.[BENCHMARK_SIBLING_CPU];
      if (!Number.isFinite(siblingBusy)) invalidate({kind: "cpu_counter", detail: `cpu${BENCHMARK_SIBLING_CPU} utilization unavailable`});
      consecutiveSiblingBreaches = siblingBusy > CORE_LIMITS.invalid_sibling_busy_percent ? consecutiveSiblingBreaches + 1 : 0;
      if (consecutiveLoadBreaches >= 2) invalidate({kind: "load1", detail: `${sample.load1} twice consecutively`});
      if (consecutiveSiblingBreaches >= 2) invalidate({kind: "sibling_cpu", detail: `cpu${BENCHMARK_SIBLING_CPU} busy ${sample.cpu_busy_percent[BENCHMARK_SIBLING_CPU]}% twice consecutively`});
    }
  }

  let observationNumber = 0;
  let firstObservationMonotonic = null;
  async function waitForObservationTemperature() {
    if (previousObservationFinishedMonotonic === null) return;
    const waitStarted = performance.now() / 1_000;
    while (invalidReason === null) {
      const sample = lastEnvironmentSample;
      if (sample !== null && sample.monotonic_seconds >= previousObservationFinishedMonotonic &&
          sample.read_error === null && sample.tctl_c <= TEMPERATURE_LIMITS.observation_start_c) return;
      const elapsed = performance.now() / 1_000 - waitStarted;
      if (elapsed > MAX_OBSERVATION_COOLDOWN_SECONDS) {
        invalidate({kind: "cooldown_timeout", detail: `Tctl did not return to ${TEMPERATURE_LIMITS.observation_start_c}C within ${MAX_OBSERVATION_COOLDOWN_SECONDS}s`});
        return;
      }
      await delay(100);
    }
  }

  async function runObservation(entry) {
    await waitForObservationTemperature();
    if (invalidReason !== null) throw new Error("campaign invalidated before observation start");
    const binary = BINARIES[definition.binary].path;
    const tasksetArgs = [
      "-c", BENCHMARK_CPU,
      binary,
      `--workload=${entry.workload}`,
      "--configuration=paired",
      `--paired-order=${entry.order.join(",")}`,
      `--pair-id=${entry.pair_id}`,
      `--records=${FIXTURE.records}`,
      `--buffer-size=${FIXTURE.buffer_size}`,
      `--warmup=${FIXTURE.warmup_seconds}`,
      `--time=${FIXTURE.calculation_seconds}`,
      `--allocations=${FIXTURE.allocation_iterations}`,
      `--commit=${CANDIDATE_COMMIT}`,
    ];
    const prefix = `${String(observationNumber).padStart(3, "0")}-${String(entry.round).padStart(2, "0")}-${entry.workload}-${entry.order[0]}-first`;
    observationNumber += 1;
    const taskAuditFile = path.join(options.output, "observations", `${prefix}.task-audit.tsv`);
    const timeArgs = [
      "--quiet",
      "--output", taskAuditFile,
      "--format", TASK_AUDIT_FORMAT,
      "/usr/bin/taskset", ...tasksetArgs,
    ];
    const startEnvironmentSample = lastEnvironmentSample;
    const startedMonotonic = performance.now() / 1_000;
    if (firstObservationMonotonic === null) firstObservationMonotonic = startedMonotonic;
    const startedAt = isoNow();
    const result = await new Promise((resolve) => {
      const child = spawn(GNU_TIME, timeArgs, {env: childEnvironment(), stdio: ["ignore", "pipe", "pipe"]});
      const stdout = [];
      const stderr = [];
      child.stdout.on("data", (chunk) => stdout.push(chunk));
      child.stderr.on("data", (chunk) => stderr.push(chunk));
      child.on("error", (error) => resolve({code: null, signal: null, spawn_error: String(error.message), stdout: Buffer.concat(stdout).toString(), stderr: Buffer.concat(stderr).toString()}));
      child.on("close", (code, signal) => resolve({code, signal, spawn_error: null, stdout: Buffer.concat(stdout).toString(), stderr: Buffer.concat(stderr).toString()}));
    });
    const finishedMonotonic = performance.now() / 1_000;
    previousObservationFinishedMonotonic = finishedMonotonic;
    let taskExecutionAudit = null;
    let taskExecutionAuditError = null;
    try {
      taskExecutionAudit = parseTaskAudit(fs.readFileSync(taskAuditFile, "utf8"));
    } catch (error) {
      taskExecutionAuditError = String(error?.message ?? error);
    }
    fs.writeFileSync(path.join(options.output, "observations", `${prefix}.stdout.json`), result.stdout, {encoding: "utf8", flag: "wx"});
    fs.writeFileSync(path.join(options.output, "observations", `${prefix}.stderr.txt`), result.stderr, {encoding: "utf8", flag: "wx"});
    const metadata = {
      entry: {index: entry.index, pair_id: entry.pair_id, round: entry.round, slot: entry.slot, workload: entry.workload},
      requested_initial_order: entry.order,
      command: [GNU_TIME, ...timeArgs],
      benchmark_command: ["/usr/bin/taskset", ...tasksetArgs],
      binary_sha256: BINARIES[definition.binary].sha256,
      started_at: startedAt,
      started_monotonic_seconds: startedMonotonic,
      start_environment_sample: startEnvironmentSample,
      finished_at: isoNow(),
      finished_monotonic_seconds: finishedMonotonic,
      finish_environment_sample: lastEnvironmentSample,
      elapsed_seconds: finishedMonotonic - startedMonotonic,
      exit_code: result.code,
      signal: result.signal,
      spawn_error: result.spawn_error,
      task_execution_audit_file: path.basename(taskAuditFile),
      task_execution_audit: taskExecutionAudit,
      task_execution_audit_error: taskExecutionAuditError,
    };
    jsonWrite(path.join(options.output, "observations", `${prefix}.meta.json`), metadata);
    if (result.spawn_error !== null || result.code !== 0 || result.signal !== null) {
      throw new Error(`observation ${prefix} failed: ${result.spawn_error ?? `exit=${result.code} signal=${result.signal}`} stderr=${result.stderr}`);
    }
    if (result.stderr !== "") throw new Error(`observation ${prefix} wrote stderr: ${result.stderr}`);
    if (taskExecutionAuditError !== null) {
      throw new Error(`observation ${prefix} task audit failed: ${taskExecutionAuditError}`);
    }
    if (taskExecutionAudit.exit_status !== result.code) {
      throw new Error(`observation ${prefix} task-audit exit ${taskExecutionAudit.exit_status} != wrapper exit ${result.code}`);
    }
    let receipt;
    try {
      receipt = JSON.parse(result.stdout);
    } catch (error) {
      throw new Error(`observation ${prefix} emitted invalid JSON: ${error.message}`);
    }
    assertPairedReceipt(receipt, entry);
    const auditIssue = taskAuditValidityIssue(taskExecutionAudit);
    if (auditIssue !== null) {
      invalidate({kind: "benchmark_task_cpu_share", detail: `observation ${prefix}: ${auditIssue}`});
      throw new Error(`observation ${prefix} failed task-execution validity: ${auditIssue}`);
    }
    return {metadata, receipt};
  }

  const monitorPromise = runtimeMonitor();
  const pairs = [];
  for (const entry of schedule) {
    if (invalidReason !== null) break;
    const pair = {index: entry.index, pair_id: entry.pair_id, round: entry.round, slot: entry.slot, workload: entry.workload, order: entry.order, observation: null};
    try {
      pair.observation = await runObservation(entry);
      if (invalidReason !== null) invalidate({kind: "partial_pair", detail: `pair ${entry.index} was interrupted`});
    } catch (error) {
      invalidate({kind: "observation", detail: String(error?.message ?? error)});
    }
    pairs.push(pair);
    if ((entry.index + 1) % 8 === 0 || invalidReason !== null) {
      console.log(`progress pairs=${pairs.length}/${schedule.length} observations=${observationNumber}`);
    }
  }
  stopMonitor = true;
  await monitorPromise;
  const campaignEndSample = takeSample("campaign-end");
  if (firstObservationMonotonic === null || firstObservationMonotonic - admissionEnd.monotonic_seconds > 10) {
    invalidate({kind: "late_start", detail: `${firstObservationMonotonic - admissionEnd.monotonic_seconds}s after admission`});
  }
  for (const binaryName of usedBinaryNames) {
    try {
      assertBinary(binaryName);
    } catch (error) {
      invalidate({kind: "binary_changed", detail: String(error.message)});
    }
  }
  try {
    const finalTaskAuditBinaryMetadata = assertTaskAuditBinary();
    if (!sameJson(finalTaskAuditBinaryMetadata, taskAuditBinaryMetadata)) {
      invalidate({kind: "task_audit_binary_changed", detail: `${GNU_TIME} identity changed during the campaign`});
    }
  } catch (error) {
    invalidate({kind: "task_audit_binary_changed", detail: String(error.message)});
  }
  try {
    const finalRunnerFileMetadata = assertRunnerFile();
    if (!sameJson(finalRunnerFileMetadata, runnerFileMetadata)) {
      invalidate({kind: "runner_changed", detail: `${runnerFileMetadata.realpath} identity changed during the campaign`});
    }
  } catch (error) {
    invalidate({kind: "runner_changed", detail: String(error.message)});
  }
  if (pairs.length !== schedule.length || pairs.some((pair) => pair.observation === null)) {
    invalidate({kind: "incomplete", detail: `${pairs.length}/${schedule.length} pairs retained`});
  }

  let analysis = null;
  let diagnostics = null;
  let passed = false;
  if (invalidReason === null) {
    analysis = analyze(pairs, definition);
    diagnostics = pairedDiagnostics(pairs, definition);
    passed = analysis.every((result) => result.passed);
  }
  const environmentLog = fs.readFileSync(environmentFile, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
  const final = {
    artifact: "fused-json-milestone-5-api-paired-campaign",
    version: 1,
    campaign: "api-paired",
    id: definition.id,
    valid: invalidReason === null,
    passed,
    invalid_reason: invalidReason,
    completed_at: isoNow(),
    admission_end: admissionEnd,
    first_observation_delay_seconds: firstObservationMonotonic - admissionEnd.monotonic_seconds,
    final_environment_sample: campaignEndSample,
    manifest,
    schedule,
    pairs,
    environment_log: environmentLog,
    analysis,
    diagnostics,
  };
  jsonWrite(path.join(options.output, "final.json"), final);
  appendJsonLine(eventFile, {at: isoNow(), event: "completed", valid: final.valid, passed: final.passed});
  console.log(`completed valid=${final.valid} passed=${final.passed} output=${options.output}`);
  if (!final.valid) process.exitCode = 42;
  else if (!final.passed) process.exitCode = 2;
}

main().catch((error) => {
  console.error(error.stack ?? error);
  process.exitCode = 1;
});
