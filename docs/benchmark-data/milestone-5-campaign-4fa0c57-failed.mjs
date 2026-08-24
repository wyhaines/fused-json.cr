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
const BASELINE_COMMIT = "eb7b377ee6b8588d4060405e68b13b9704ffffa5";
const CANDIDATE_COMMIT = "4fa0c57c3f027d95423ffe2980489921147ec3c0";
const BINARIES = {
  baseline: {
    path: "/tmp/fused-json-limits-v2-m4",
    sha256: "fe9a4583e14c0afbdaa452803b96d257f6428940a1c4af601ee639a0e7d9ea2b",
  },
  candidate: {
    path: "/tmp/fused-json-limits-v4-m5-default",
    sha256: "b7fcad5068ae9bed2020fcd8b263cde8dc846226fc6a7a263e0f6a6478940a9d",
  },
  limits_api: {
    path: "/tmp/fused-json-limits-v4-m5-api",
    sha256: "ad8bbb274b2997fed5f73c1305b03e369b1c610f05203efacb27cc84812a588f",
  },
};
const BENCHMARK_CPU = "3";
const BENCHMARK_SIBLING_CPU = "2";
const RUNNER_CPU = "0";
const TEMPERATURE_LIMITS = {admission_c: 70, observation_start_c: 70, invalid_c: 95};
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
const MAX_OBSERVATION_COOLDOWN_SECONDS = 60;
const FIXTURE = {
  records: 10_000,
  buffer_size: 32_768,
  warmup_seconds: 0.5,
  calculation_seconds: 1.5,
  allocation_iterations: 20,
};
const BOOTSTRAP = {seed: 20_260_822, resamples: 10_000, lower_index: 500};

function usage() {
  console.error("usage: fused-json-m5-campaign.mjs --campaign=m4|api --output=/new/path");
  process.exit(64);
}

function parseArgs() {
  const parsed = {};
  for (const arg of process.argv.slice(2)) {
    const match = arg.match(/^--([^=]+)=(.*)$/);
    if (!match) usage();
    parsed[match[1]] = match[2];
  }
  if (!(["m4", "api"].includes(parsed.campaign)) || !parsed.output) usage();
  return {campaign: parsed.campaign, output: path.resolve(parsed.output)};
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

function buildSchedule(campaign) {
  const rounds = campaign === "m4" ? 20 : 10;
  const first = campaign === "m4" ? "baseline" : "default";
  const second = campaign === "m4" ? "candidate" : "explicit-empty";
  const schedule = [];
  for (let round = 0; round < rounds; round += 1) {
    for (let slot = 0; slot < WORKLOADS.length; slot += 1) {
      const workloadIndex = (slot + round) % WORKLOADS.length;
      // Invert the slot-parity order every two rounds and again after each
      // complete workload rotation. Repeated workload/slot cells alternate
      // order, and the 20-round campaign is balanced by workload and by slot.
      const orderPhase = (Math.floor(round / 2) + Math.floor(round / WORKLOADS.length)) % 2;
      const firstSideFirst = ((slot + orderPhase) % 2) === 0;
      schedule.push({
        index: schedule.length,
        round,
        slot,
        workload: WORKLOADS[workloadIndex],
        order: firstSideFirst ? [first, second] : [second, first],
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
    if (campaign === "m4" && firstCount !== rounds / 2) {
      throw new Error(`slot ${slot} is not order-balanced`);
    }
  }
  return schedule;
}

function campaignDefinition(campaign) {
  if (campaign === "m4") {
    return {
      id: "m4-default-vs-m5-default",
      rounds: 20,
      numerator: "candidate",
      denominator: "baseline",
      sides: {
        baseline: {binary: "baseline", configuration: "default", commit: BASELINE_COMMIT, limits_api: false},
        candidate: {binary: "candidate", configuration: "default", commit: CANDIDATE_COMMIT, limits_api: false},
      },
      gates: {median: 0.98, geometric_mean: 0.98, bootstrap_lower: 0.97},
    };
  }
  return {
    id: "m5-default-vs-explicit-empty",
    rounds: 10,
    numerator: "explicit-empty",
    denominator: "default",
    sides: {
      default: {binary: "limits_api", configuration: "default", commit: CANDIDATE_COMMIT, limits_api: true},
      "explicit-empty": {binary: "limits_api", configuration: "explicit-empty", commit: CANDIDATE_COMMIT, limits_api: true},
    },
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

function assertReceipt(receipt, entry, sideName, side) {
  const fail = (message) => { throw new Error(`receipt ${entry.index}/${sideName}: ${message}`); };
  if (receipt.receipt !== "fused-json-limits-overhead" || receipt.version !== 2) fail("wrong schema");
  if (receipt.workload !== entry.workload || receipt.configuration !== side.configuration) fail("wrong workload/configuration");
  if (receipt.semantic_verification?.status !== "verified") fail("semantics were not verified");
  if (!receipt.pairing_key?.startsWith(`v2:${entry.workload}:`)) fail("wrong pairing key");
  if (receipt.fixture?.records !== FIXTURE.records) fail("wrong fixture size");
  if (receipt.measurement?.estimator !== "total-iterations-over-total-elapsed-v1") fail("wrong estimator");
  if (receipt.measurement?.warmup_seconds !== FIXTURE.warmup_seconds ||
      receipt.measurement?.calculation_seconds !== FIXTURE.calculation_seconds ||
      receipt.measurement?.allocation_iterations !== FIXTURE.allocation_iterations) fail("wrong measurement parameters");
  if (receipt.build?.fused_json_commit !== side.commit || receipt.build?.release !== true ||
      receipt.build?.limits_api !== side.limits_api) fail("wrong build identity");
  if (receipt.host?.cpu_affinity !== BENCHMARK_CPU) fail("wrong CPU affinity");
  if (side.limits_api ? receipt.disabled_limits === null : receipt.disabled_limits !== null) fail("wrong disabled-limits shape");
  if (entry.workload.startsWith("io-") && receipt.parser_options?.buffer_size !== FIXTURE.buffer_size) fail("wrong IO buffer");
  if (!entry.workload.startsWith("io-") && receipt.parser_options?.buffer_size !== null) fail("unexpected String buffer");
  const env = receipt.environment;
  if (env?.GC_NPROCS !== "1" || env?.GC_MARKERS !== "1" || env?.CRYSTAL_WORKERS !== "1" ||
      env?.OMP_NUM_THREADS !== "1" || env?.FUSED_JSON_BENCH_CPU !== BENCHMARK_CPU ||
      env?.FUSED_JSON_BENCH_COMMIT !== null) fail("wrong benchmark environment");
}

function assertPair(pair, definition) {
  const left = pair.observations[definition.denominator].receipt;
  const right = pair.observations[definition.numerator].receipt;
  if (left.pairing_key !== right.pairing_key || !sameJson(left.fixture, right.fixture)) {
    throw new Error(`pair ${pair.index} fixture mismatch`);
  }
  for (const field of ["crystal_version", "crystal_build_commit", "llvm_version", "target", "release"]) {
    if (left.build[field] !== right.build[field]) throw new Error(`pair ${pair.index} build ${field} mismatch`);
  }
  if (!sameJson(left.host, right.host) || !sameJson(left.environment, right.environment) ||
      !sameJson(left.parser_options, right.parser_options) ||
      !sameJson(left.semantic_verification, right.semantic_verification)) {
    throw new Error(`pair ${pair.index} receipt metadata mismatch`);
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
  for (const workload of WORKLOADS) {
    const workloadPairs = pairs.filter((pair) => pair.workload === workload).sort((a, b) => a.round - b.round);
    const ratios = workloadPairs.map((pair) => {
      const numerator = pair.observations[definition.numerator].receipt.measurement.iterations_per_second;
      const denominator = pair.observations[definition.denominator].receipt.measurement.iterations_per_second;
      return numerator / denominator;
    });
    const denominatorAllocations = workloadPairs.map((pair) =>
      pair.observations[definition.denominator].receipt.measurement.managed_bytes_per_operation);
    const numeratorAllocations = workloadPairs.map((pair) =>
      pair.observations[definition.numerator].receipt.measurement.managed_bytes_per_operation);
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

async function main() {
  const options = parseArgs();
  const definition = campaignDefinition(options.campaign);
  const runnerAffinity = selfAffinity();
  if (runnerAffinity !== RUNNER_CPU) {
    throw new Error(`runner must be pinned to CPU ${RUNNER_CPU}; affinity is ${runnerAffinity}`);
  }
  fs.mkdirSync(options.output, {recursive: false});
  fs.mkdirSync(path.join(options.output, "observations"));
  const environmentFile = path.join(options.output, "environment.jsonl");
  const eventFile = path.join(options.output, "events.jsonl");
  const tctlPath = resolveTctlPath();
  const usedBinaryNames = [...new Set(Object.values(definition.sides).map((side) => side.binary))];
  const binaryMetadata = Object.fromEntries(usedBinaryNames.map((name) => [name, assertBinary(name)]));
  const schedule = buildSchedule(options.campaign);
  const manifest = {
    artifact: "fused-json-milestone-5-campaign",
    version: 1,
    campaign: options.campaign,
    id: definition.id,
    created_at: isoNow(),
    baseline_commit: BASELINE_COMMIT,
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
    fixture: FIXTURE,
    bootstrap: BOOTSTRAP,
    admission: {seconds: ADMISSION_SECONDS, sample_interval_seconds: 2, ...TEMPERATURE_LIMITS, ...LOAD_LIMITS, ...CORE_LIMITS, max_sample_gap_seconds: MAX_SAMPLE_GAP_SECONDS, max_observation_cooldown_seconds: MAX_OBSERVATION_COOLDOWN_SECONDS},
    comparison: {numerator: definition.numerator, denominator: definition.denominator, gates: definition.gates},
    schedule_design: {
      version: 2,
      workload_rotation: "workload_index=(slot+round)%workload_count",
      order_counterbalance: "phase=(floor(round/2)+floor(round/workload_count))%2; first_side_first=(slot+phase)%2==0",
      repeated_workload_slot_order: "alternating",
    },
    child_environment: childEnvironment(),
    runner: {node: process.version, argv: process.argv, sha256: sha256(fs.realpathSync(process.argv[1]))},
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

  async function runObservation(entry, sideName) {
    await waitForObservationTemperature();
    if (invalidReason !== null) throw new Error("campaign invalidated before observation start");
    const side = definition.sides[sideName];
    const binary = BINARIES[side.binary].path;
    const args = [
      "-c", BENCHMARK_CPU,
      binary,
      `--workload=${entry.workload}`,
      `--configuration=${side.configuration}`,
      `--records=${FIXTURE.records}`,
      `--buffer-size=${FIXTURE.buffer_size}`,
      `--warmup=${FIXTURE.warmup_seconds}`,
      `--time=${FIXTURE.calculation_seconds}`,
      `--allocations=${FIXTURE.allocation_iterations}`,
      `--commit=${side.commit}`,
    ];
    const startEnvironmentSample = lastEnvironmentSample;
    const startedMonotonic = performance.now() / 1_000;
    if (firstObservationMonotonic === null) firstObservationMonotonic = startedMonotonic;
    const startedAt = isoNow();
    const result = await new Promise((resolve) => {
      const child = spawn("/usr/bin/taskset", args, {env: childEnvironment(), stdio: ["ignore", "pipe", "pipe"]});
      const stdout = [];
      const stderr = [];
      child.stdout.on("data", (chunk) => stdout.push(chunk));
      child.stderr.on("data", (chunk) => stderr.push(chunk));
      child.on("error", (error) => resolve({code: null, signal: null, spawn_error: String(error.message), stdout: Buffer.concat(stdout).toString(), stderr: Buffer.concat(stderr).toString()}));
      child.on("close", (code, signal) => resolve({code, signal, spawn_error: null, stdout: Buffer.concat(stdout).toString(), stderr: Buffer.concat(stderr).toString()}));
    });
    previousObservationFinishedMonotonic = performance.now() / 1_000;
    const prefix = `${String(observationNumber).padStart(3, "0")}-${String(entry.round).padStart(2, "0")}-${entry.workload}-${sideName}`;
    observationNumber += 1;
    fs.writeFileSync(path.join(options.output, "observations", `${prefix}.stdout.json`), result.stdout, {encoding: "utf8", flag: "wx"});
    fs.writeFileSync(path.join(options.output, "observations", `${prefix}.stderr.txt`), result.stderr, {encoding: "utf8", flag: "wx"});
    const metadata = {
      entry: {index: entry.index, round: entry.round, slot: entry.slot, workload: entry.workload},
      side: sideName,
      order_index: entry.order.indexOf(sideName),
      command: ["/usr/bin/taskset", ...args],
      binary_sha256: BINARIES[side.binary].sha256,
      started_at: startedAt,
      start_environment_sample: startEnvironmentSample,
      finished_at: isoNow(),
      elapsed_seconds: performance.now() / 1_000 - startedMonotonic,
      exit_code: result.code,
      signal: result.signal,
      spawn_error: result.spawn_error,
    };
    jsonWrite(path.join(options.output, "observations", `${prefix}.meta.json`), metadata);
    if (result.spawn_error !== null || result.code !== 0 || result.signal !== null) {
      throw new Error(`observation ${prefix} failed: ${result.spawn_error ?? `exit=${result.code} signal=${result.signal}`} stderr=${result.stderr}`);
    }
    if (result.stderr !== "") throw new Error(`observation ${prefix} wrote stderr: ${result.stderr}`);
    let receipt;
    try {
      receipt = JSON.parse(result.stdout);
    } catch (error) {
      throw new Error(`observation ${prefix} emitted invalid JSON: ${error.message}`);
    }
    assertReceipt(receipt, entry, sideName, side);
    return {side: sideName, metadata, receipt};
  }

  const monitorPromise = runtimeMonitor();
  const pairs = [];
  for (const entry of schedule) {
    if (invalidReason !== null) break;
    const pair = {index: entry.index, round: entry.round, slot: entry.slot, workload: entry.workload, order: entry.order, observations: {}};
    try {
      for (const sideName of entry.order) {
        const observation = await runObservation(entry, sideName);
        pair.observations[sideName] = observation;
        if (invalidReason !== null) break;
      }
      if (Object.keys(pair.observations).length === 2) assertPair(pair, definition);
      else invalidate({kind: "partial_pair", detail: `pair ${entry.index} was interrupted`});
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
  if (pairs.length !== schedule.length || pairs.some((pair) => Object.keys(pair.observations).length !== 2)) {
    invalidate({kind: "incomplete", detail: `${pairs.length}/${schedule.length} pairs retained`});
  }

  let analysis = null;
  let passed = false;
  if (invalidReason === null) {
    analysis = analyze(pairs, definition);
    passed = analysis.every((result) => result.passed);
  }
  const environmentLog = fs.readFileSync(environmentFile, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
  const final = {
    artifact: "fused-json-milestone-5-campaign",
    version: 1,
    campaign: options.campaign,
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
