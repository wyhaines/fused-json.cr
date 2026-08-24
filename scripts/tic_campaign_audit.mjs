#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const ARTIFACT = "fused-json-milestone-6-tic-campaign";
const AUDIT_ARTIFACT = "fused-json-m6-cross-campaign-audit";
const BUILD_ARTIFACT = "fused-json-m6-build-attestation";
const VERSION = 2;
const BUFFER_SIZE = 32 * 1024;
const MAX_NESTING = 512;
const SEED = "7";
const MIB = 1024 * 1024;
const PERFORMANCE = Object.freeze({
  pairsPerProfile: 20,
  geometricMeanGate: 1.05,
  bootstrapLowerGate: 1.0,
  bootstrapSeed: 20_260_824,
  bootstrapResamples: 10_000,
  bootstrapLowerIndex: 500,
});
const RSS = Object.freeze({
  baselineRunsPerSize: 5,
  largeRuns: 3,
  minimumHeadroomKibibytes: 16 * 1024,
});
const DIAGNOSTICS = Object.freeze({
  plainDrainRunsPerProfile: 1,
  gzipDrainRssRuns: 3,
  gzipTypedPairs: 6,
  twoPassPairs: 6,
  wideItemRssRuns: 3,
  retainedPairs: 4,
});
const ENVIRONMENT_POLICY = Object.freeze({
  name: "busy-pinned-v2",
  version: 2,
  sampleIntervalMs: 2_000,
  initialAdmissionSeconds: 60,
  blockAdmissionSeconds: 6,
  gateLoad1Maximum: 5,
  gateLoad5Maximum: 5,
  gateTctlMaximumC: 94,
  gateTctlRangeMaximumC: 5,
  gateSiblingCpuBusyMaximumPercent: 25,
  gateBenchmarkCpuBusyMaximumPercent: 10,
  blockGateDeadlineSeconds: 180,
  invalidTctlMinimumC: 100,
  invalidLoad1StrictlyGreaterThan: 7,
  invalidSiblingBusyStrictlyGreaterThanPercent: 35,
  consecutiveBreachSamples: 2,
  maximumMonitorGapSeconds: 5,
  minimumParserTaskCpuPercent: 99,
  childWindowSiblingBusyMaximumPercent: 25,
  cpuFrequencyPolicy: "diagnostic-only; never gates, excludes, or normalizes",
});
const CHILD_ENVIRONMENT = Object.freeze({
  PATH: "/usr/bin:/bin",
  LANG: "C",
  LC_ALL: "C",
  TZ: "UTC",
  GC_NPROCS: "1",
  GC_MARKERS: "1",
  CRYSTAL_WORKERS: "1",
  OMP_NUM_THREADS: "1",
});
const RETENTION_POLICY = "all-selected-typed-values-v1";
const EXPECTED_FIXTURES = Object.freeze([
  "many-64m", "many-256m", "many-1g", "many-4g-plus", "wide-256m",
]);

function usage(exitCode = 64) {
  console.error([
    "usage: scripts/tic_campaign_audit.mjs",
    "       --campaign-1=PATH --campaign-2=PATH",
    "       --build-attestation=PATH --output=/new/file.json",
    "       scripts/tic_campaign_audit.mjs --self-audit",
  ].join("\n"));
  process.exit(exitCode);
}

function parseArguments(argv) {
  if (argv.length === 1 && argv[0] === "--self-audit") return {selfAudit: true};
  const allowed = new Set(["campaign-1", "campaign-2", "build-attestation", "output"]);
  const values = {};
  for (const argument of argv) {
    const match = argument.match(/^--([^=]+)=(.*)$/s);
    if (!match || !allowed.has(match[1]) || Object.hasOwn(values, match[1]) || !match[2]) usage();
    values[match[1]] = path.resolve(match[2]);
  }
  if ([...allowed].some((name) => !values[name])) usage();
  return {
    selfAudit: false,
    campaign1: values["campaign-1"],
    campaign2: values["campaign-2"],
    buildAttestation: values["build-attestation"],
    output: values.output,
  };
}

function invariant(condition, message) {
  if (!condition) throw new Error(message);
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  }
  return value;
}

function sameJson(left, right) {
  return JSON.stringify(canonical(left)) === JSON.stringify(canonical(right));
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function fileIdentity(file) {
  const requestedPath = path.resolve(file);
  const realpath = fs.realpathSync(requestedPath);
  const stat = fs.statSync(realpath, {bigint: true});
  invariant(stat.isFile(), `${requestedPath} is not a regular file`);
  return {
    path: requestedPath,
    realpath,
    bytes: stat.size.toString(),
    sha256: sha256(realpath),
  };
}

function parseJsonFile(file) {
  const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
  invariant(parsed && typeof parsed === "object" && !Array.isArray(parsed), `${file}: expected one JSON object`);
  return parsed;
}

function parseJsonText(text, label) {
  const parsed = JSON.parse(text.trim());
  invariant(parsed && typeof parsed === "object" && !Array.isArray(parsed), `${label}: expected one JSON object`);
  return parsed;
}

function writeDurableNew(file, text) {
  const descriptor = fs.openSync(file, "wx", 0o600);
  try {
    fs.writeFileSync(descriptor, text, "utf8");
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}

function writeDurableAtomicNew(file, text) {
  invariant(!fs.existsSync(file), `output already exists: ${file}`);
  const parent = path.dirname(file);
  invariant(fs.statSync(parent).isDirectory(), `output parent is not a directory: ${parent}`);
  const temporary = `${file}.tmp-${process.pid}`;
  invariant(!fs.existsSync(temporary), `stale temporary output exists: ${temporary}`);
  writeDurableNew(temporary, text);
  try {
    fs.linkSync(temporary, file);
    try {
      const descriptor = fs.openSync(parent, "r");
      try { fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
    } catch {
      // File fsync remains authoritative when directory fsync is unavailable.
    }
  } finally {
    fs.unlinkSync(temporary);
  }
}

function isSha256(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
}

function isCommit(value) {
  return typeof value === "string" && /^[0-9a-f]{40}$/.test(value);
}

function requireSafeInteger(value, label, minimum = 0) {
  invariant(Number.isSafeInteger(value) && value >= minimum, `${label}: expected safe integer >= ${minimum}`);
  return value;
}

function requireByteCount(value, label) {
  if (typeof value === "string" && /^(?:0|[1-9]\d*)$/.test(value)) {
    const parsed = Number(value);
    requireSafeInteger(parsed, label, 1);
    return parsed;
  }
  return requireSafeInteger(value, label, 1);
}

function requireFinite(value, label, {positive = false} = {}) {
  invariant(typeof value === "number" && Number.isFinite(value) && (positive ? value > 0 : value >= 0),
    `${label}: expected ${positive ? "positive " : "nonnegative "}finite number`);
  return value;
}

function nearlyEqual(left, right, tolerance = 1e-12) {
  return Number.isFinite(left) && Number.isFinite(right) &&
    Math.abs(left - right) <= tolerance * Math.max(1, Math.abs(left), Math.abs(right));
}

function geometricMean(values) {
  invariant(values.length > 0 && values.every((value) => Number.isFinite(value) && value > 0),
    "geometric mean requires positive finite values");
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
  invariant(ratios.length === PERFORMANCE.pairsPerProfile, "bootstrap requires exactly 20 ratios");
  const random = mulberry32(PERFORMANCE.bootstrapSeed);
  const estimates = new Array(PERFORMANCE.bootstrapResamples);
  for (let sample = 0; sample < estimates.length; sample += 1) {
    let logSum = 0;
    for (let index = 0; index < ratios.length; index += 1) {
      logSum += Math.log(ratios[Math.floor(random() * ratios.length)]);
    }
    estimates[sample] = Math.exp(logSum / ratios.length);
  }
  estimates.sort((left, right) => left - right);
  return estimates[PERFORMANCE.bootstrapLowerIndex];
}

function rssCeiling(peakKibibytes) {
  invariant(peakKibibytes.length === 10, "RSS gate requires ten baselines");
  peakKibibytes.forEach((value, index) => requireSafeInteger(value, `RSS baseline ${index}`, 1));
  const maximum = Math.max(...peakKibibytes);
  const headroom = Math.max(RSS.minimumHeadroomKibibytes, Math.ceil(maximum * 0.25));
  return {
    maximum_baseline_kibibytes: maximum,
    headroom_kibibytes: headroom,
    ceiling_kibibytes: maximum + headroom,
    maximum_baseline_bytes: maximum * 1024,
    headroom_bytes: headroom * 1024,
    ceiling_bytes: (maximum + headroom) * 1024,
  };
}

function buildPerformanceSchedule() {
  const schedule = [];
  const cycle = [
    [["many-small", ["fused", "crystal"]], ["wide-item", ["crystal", "fused"]]],
    [["wide-item", ["fused", "crystal"]], ["many-small", ["crystal", "fused"]]],
    [["many-small", ["crystal", "fused"]], ["wide-item", ["fused", "crystal"]]],
    [["wide-item", ["crystal", "fused"]], ["many-small", ["fused", "crystal"]]],
  ];
  for (let round = 0; round < PERFORMANCE.pairsPerProfile; round += 1) {
    cycle[round % cycle.length].forEach(([profile, order], slot) => {
      schedule.push({
        id: `performance-${String(schedule.length).padStart(2, "0")}`,
        round,
        slot,
        profile,
        fixture: profile === "many-small" ? "many-256m" : "wide-256m",
        order,
      });
    });
  }
  return schedule;
}

function balancedPairSchedule(prefix, count, fixture, modes) {
  return Array.from({length: count}, (_, index) => ({
    id: `${prefix}-${String(index).padStart(2, "0")}`,
    index,
    fixture,
    order: index % 2 === 0 ? [modes[0], modes[1]] : [modes[1], modes[0]],
  }));
}

function buildSchedule() {
  return {
    performance: buildPerformanceSchedule(),
    bounded_rss_baselines: Array.from({length: 10}, (_, index) => ({
      id: `rss-baseline-${String(index).padStart(2, "0")}`,
      fixture: index % 2 === 0 ? "many-256m" : "many-1g",
      mode: "fused-typed",
    })),
    bounded_rss_large: Array.from({length: 3}, (_, index) => ({
      id: `rss-large-${index}`, fixture: "many-4g-plus", mode: "fused-typed",
    })),
    diagnostics: {
      plain_drains: [
        {id: "diagnostic-plain-drain-many", fixture: "many-256m", mode: "plain-drain"},
        {id: "diagnostic-plain-drain-wide", fixture: "wide-256m", mode: "plain-drain"},
      ],
      gzip_drain_rss: Array.from({length: 3}, (_, index) => ({
        id: `diagnostic-gzip-drain-${index}`, fixture: "many-256m", mode: "gzip-drain",
      })),
      gzip_typed_pairs: balancedPairSchedule(
        "diagnostic-gzip-typed", 6, "many-256m", ["fused-gzip-typed", "crystal-gzip-typed"]
      ),
      two_pass_pairs: balancedPairSchedule(
        "diagnostic-two-pass", 6, "many-256m", ["fused-two-pass-typed", "crystal-two-pass-typed"]
      ),
      wide_item_rss: Array.from({length: 3}, (_, index) => ({
        id: `diagnostic-wide-rss-${index}`, fixture: "wide-256m", mode: "fused-typed",
      })),
      retained_pairs: balancedPairSchedule(
        "diagnostic-retained", 4, "many-64m", ["fused-retained-typed", "crystal-retained-typed"]
      ),
    },
  };
}

function expectedExecution(schedule) {
  const specs = [];
  const add = (entry, details) => specs.push({
    id: entry.id,
    blockId: details.blockId ?? entry.id,
    fixture: entry.fixture,
    phase: details.phase,
    category: details.category,
    mode: details.mode ?? entry.mode,
    command: details.command,
    parserChild: details.parserChild,
    side: details.side ?? null,
  });
  for (const entry of schedule.performance) {
    add({...entry, id: `${entry.id}-warm`}, {
      blockId: entry.id, phase: "performance", category: "page-cache-warm",
      mode: "plain-drain", command: "run", parserChild: false,
    });
    for (const side of entry.order) {
      add({...entry, id: `${entry.id}-${side}`}, {
        blockId: entry.id, phase: "performance", category: "typed-throughput",
        mode: `${side}-typed`, command: "run", parserChild: true, side,
      });
    }
  }
  for (const entry of schedule.bounded_rss_baselines) {
    add(entry, {phase: "rss", category: "bounded-baseline", command: "rss", parserChild: true});
  }
  for (const entry of schedule.bounded_rss_large) {
    add(entry, {phase: "rss", category: "bounded-large", command: "rss", parserChild: true});
  }
  for (const entry of schedule.diagnostics.plain_drains) {
    add(entry, {phase: "diagnostics", category: "plain-drain-rss", command: "rss", parserChild: false});
  }
  for (const entry of schedule.diagnostics.gzip_drain_rss) {
    add(entry, {phase: "diagnostics", category: "gzip-drain-rss", command: "rss", parserChild: false});
  }
  const addPairs = (entries, category) => {
    for (const entry of entries) {
      for (const mode of entry.order) {
        const side = mode.startsWith("fused-") ? "fused" : "crystal";
        add({...entry, id: `${entry.id}-${side}`}, {
          blockId: entry.id, phase: "diagnostics", category,
          mode, command: mode.includes("retained") ? "rss" : "run", parserChild: true, side,
        });
      }
    }
  };
  addPairs(schedule.diagnostics.gzip_typed_pairs, "gzip-typed");
  addPairs(schedule.diagnostics.two_pass_pairs, "two-pass-typed");
  for (const entry of schedule.diagnostics.wide_item_rss) {
    add(entry, {phase: "diagnostics", category: "wide-item-rss", command: "rss", parserChild: true});
  }
  addPairs(schedule.diagnostics.retained_pairs, "retained-output-rss");
  return specs;
}

function expectedBlockIds(schedule) {
  return [
    ...schedule.performance.map((entry) => entry.id),
    ...schedule.bounded_rss_baselines.map((entry) => entry.id),
    ...schedule.bounded_rss_large.map((entry) => entry.id),
    ...schedule.diagnostics.plain_drains.map((entry) => entry.id),
    ...schedule.diagnostics.gzip_drain_rss.map((entry) => entry.id),
    ...schedule.diagnostics.gzip_typed_pairs.map((entry) => entry.id),
    ...schedule.diagnostics.two_pass_pairs.map((entry) => entry.id),
    ...schedule.diagnostics.wide_item_rss.map((entry) => entry.id),
    ...schedule.diagnostics.retained_pairs.map((entry) => entry.id),
  ];
}

function validateBuildAttestation(build) {
  invariant(build?.artifact === BUILD_ARTIFACT && build.version === 1, "wrong build-attestation schema");
  invariant(isCommit(build.commit), "build attestation has malformed commit");
  invariant(build.git?.clean === true && build.git?.head === build.commit,
    "build attestation does not describe a clean matching HEAD");
  invariant(Array.isArray(build.commands) && build.commands.length > 0, "build attestation has no commands");
  const commands = JSON.stringify(build.commands);
  invariant(commands.includes("bench/tic.cr") && commands.includes("--release") && commands.includes("--no-debug"),
    "build attestation does not include the release tic-bench build command");
  for (const field of ["crystal_version", "llvm_version", "target"]) {
    invariant(typeof build.toolchain?.[field] === "string" && build.toolchain[field],
      `build attestation is missing toolchain.${field}`);
  }
  const binary = build.artifacts?.tic_bench;
  invariant(isSha256(binary?.sha256), "build attestation has malformed tic_bench SHA-256");
  requireByteCount(binary?.bytes, "build attestation tic_bench bytes");
  invariant(typeof binary.path === "string" && binary.path, "build attestation is missing tic_bench path");
  return build;
}

function validateDefinition(campaign) {
  const definition = campaign.definition;
  invariant(definition?.protocol === "fused-json-m6-tic-v2" &&
    definition.buffer_size === BUFFER_SIZE && definition.max_nesting === MAX_NESTING && definition.seed === SEED,
  `campaign ${campaign.campaign_id}: wrong protocol definition`);
  invariant(sameJson(definition.performance, PERFORMANCE), `campaign ${campaign.campaign_id}: wrong performance gate`);
  invariant(sameJson(definition.rss, RSS), `campaign ${campaign.campaign_id}: wrong RSS gate`);
  invariant(sameJson(definition.diagnostics, DIAGNOSTICS), `campaign ${campaign.campaign_id}: wrong diagnostics`);
  invariant(sameJson(definition.environment_policy, ENVIRONMENT_POLICY),
    `campaign ${campaign.campaign_id}: wrong environment policy`);
  invariant(sameJson(definition.child_environment, CHILD_ENVIRONMENT),
    `campaign ${campaign.campaign_id}: wrong child environment`);
}

function requireDecimalInteger(value, label) {
  invariant(typeof value === "string" && /^(?:0|[1-9]\d*)$/.test(value),
    `${label}: expected an unsigned decimal integer string`);
  return BigInt(value);
}

function gateSampleAcceptable(sample) {
  return sample.load1 <= ENVIRONMENT_POLICY.gateLoad1Maximum &&
    sample.load5 <= ENVIRONMENT_POLICY.gateLoad5Maximum &&
    sample.tctl_c <= ENVIRONMENT_POLICY.gateTctlMaximumC &&
    sample.cpu2_busy_percent !== null &&
    sample.cpu2_busy_percent <= ENVIRONMENT_POLICY.gateSiblingCpuBusyMaximumPercent &&
    sample.cpu3_busy_percent !== null &&
    sample.cpu3_busy_percent <= ENVIRONMENT_POLICY.gateBenchmarkCpuBusyMaximumPercent;
}

function environmentInvalidation(policyState, sample) {
  if (sample.read_errors.length > 0) return "environment read failure";
  if (sample.gap_seconds !== null && sample.gap_seconds > ENVIRONMENT_POLICY.maximumMonitorGapSeconds) {
    return "monitor gap";
  }
  if (sample.tctl_c >= ENVIRONMENT_POLICY.invalidTctlMinimumC) return "Tctl";
  policyState.loadBreaches = sample.load1 > ENVIRONMENT_POLICY.invalidLoad1StrictlyGreaterThan
    ? policyState.loadBreaches + 1 : 0;
  policyState.siblingBreaches = sample.cpu2_busy_percent !== null &&
    sample.cpu2_busy_percent > ENVIRONMENT_POLICY.invalidSiblingBusyStrictlyGreaterThanPercent
    ? policyState.siblingBreaches + 1 : 0;
  if (policyState.loadBreaches >= ENVIRONMENT_POLICY.consecutiveBreachSamples) return "load1";
  if (policyState.siblingBreaches >= ENVIRONMENT_POLICY.consecutiveBreachSamples) return "CPU 2";
  return null;
}

function validateMonitorCpuBusy(sample, index, label) {
  if (index === 0) {
    invariant(sample.cpu2_busy_percent === null && sample.cpu3_busy_percent === null,
      `${label}: initial CPU busy percentages must be null`);
    return;
  }
  const cpu2Busy = requireFinite(sample.cpu2_busy_percent, `${label} CPU 2 busy`);
  const cpu3Busy = requireFinite(sample.cpu3_busy_percent, `${label} CPU 3 busy`);
  invariant(cpu2Busy <= 100 && cpu3Busy <= 100,
    `${label}: CPU busy percentage exceeds 100`);
}

function validateGate(gate, samples, {label, requiredSeconds, blockDeadline = false}) {
  invariant(gate?.label === label, `${label}: gate label mismatch`);
  invariant(gate.required_continuous_seconds === requiredSeconds,
    `${label}: wrong required continuous duration`);
  const firstSequence = requireSafeInteger(gate.first_sample_sequence, `${label} first sample sequence`);
  const admittedSequence = requireSafeInteger(gate.admitted_sample_sequence, `${label} admitted sample sequence`);
  invariant(firstSequence <= admittedSequence, `${label}: reversed sample range`);
  invariant(Array.isArray(gate.sample_sequences), `${label}: sample sequence list is missing`);
  const expectedSequences = Array.from(
    {length: admittedSequence - firstSequence + 1}, (_, index) => firstSequence + index
  );
  invariant(sameJson(gate.sample_sequences, expectedSequences),
    `${label}: gate sample sequence list is not contiguous and exact`);
  invariant(gate.sample_count === expectedSequences.length,
    `${label}: gate sample count differs from its sequence list`);
  const gateSamples = expectedSequences.map((sequence) => {
    const sample = samples[sequence];
    invariant(sample?.sequence === sequence, `${label}: environment sample ${sequence} is missing`);
    return sample;
  });
  const first = gateSamples[0];
  const admitted = gateSamples.at(-1);
  const duration = (admitted.monotonic_ms - first.monotonic_ms) / 1000;
  invariant(duration >= requiredSeconds, `${label}: continuous window was shorter than ${requiredSeconds} seconds`);
  const minimumSamples = Math.ceil(requiredSeconds * 1000 / ENVIRONMENT_POLICY.sampleIntervalMs) + 1;
  invariant(gateSamples.length >= minimumSamples,
    `${label}: ${requiredSeconds}-second window has fewer than ${minimumSamples} two-second samples`);
  invariant(nearlyEqual(gate.duration_seconds, duration, 1e-9), `${label}: stored duration differs from samples`);
  invariant(gateSamples.every(gateSampleAcceptable), `${label}: gate window contains an unacceptable sample`);
  const temperatures = gateSamples.map((sample) => sample.tctl_c);
  const minimum = Math.min(...temperatures);
  const maximum = Math.max(...temperatures);
  const range = maximum - minimum;
  invariant(nearlyEqual(gate.tctl_min_c, minimum) && nearlyEqual(gate.tctl_max_c, maximum) &&
    nearlyEqual(gate.tctl_range_c, range), `${label}: stored Tctl range differs from samples`);
  invariant(range <= ENVIRONMENT_POLICY.gateTctlRangeMaximumC,
    `${label}: Tctl range exceeds ${ENVIRONMENT_POLICY.gateTctlRangeMaximumC} C`);
  let admittedEvaluated = null;
  let waitStarted = null;
  let deadline = null;
  if (blockDeadline) {
    admittedEvaluated = requireFinite(gate.admitted_evaluated_monotonic_ms,
      `${label} admitted evaluation time`);
    invariant(admittedEvaluated >= admitted.monotonic_ms,
      `${label}: gate evaluation precedes its admitted sample`);
    waitStarted = requireFinite(gate.wait_started_monotonic_ms, `${label} wait start`);
    deadline = requireFinite(gate.deadline_monotonic_ms, `${label} deadline`);
    const expectedDeadline = waitStarted + (ENVIRONMENT_POLICY.blockGateDeadlineSeconds * 1000);
    invariant(deadline === expectedDeadline,
      `${label}: block deadline is not exactly ${ENVIRONMENT_POLICY.blockGateDeadlineSeconds} seconds after wait start`);
    invariant(first.monotonic_ms > waitStarted, `${label}: block window did not begin after its recorded wait`);
    invariant(admitted.monotonic_ms <= deadline && admittedEvaluated <= deadline &&
      admitted.monotonic_ms - waitStarted <= ENVIRONMENT_POLICY.blockGateDeadlineSeconds * 1000 &&
      admittedEvaluated - waitStarted <= ENVIRONMENT_POLICY.blockGateDeadlineSeconds * 1000,
    `${label}: block gate sample or evaluation occurred after its exact deadline`);
  } else {
    invariant(!Object.hasOwn(gate, "wait_started_monotonic_ms") &&
      !Object.hasOwn(gate, "deadline_monotonic_ms") &&
      !Object.hasOwn(gate, "admitted_evaluated_monotonic_ms"),
    `${label}: initial admission unexpectedly contains block timing evidence`);
  }
  return {firstSequence, admittedSequence, first, admitted,
    admittedEvaluatedMonotonicMs: admittedEvaluated,
    waitStartedMonotonicMs: waitStarted, deadlineMonotonicMs: deadline};
}

function expectedGateEvents(schedule) {
  const gates = [];
  for (const entry of schedule.performance) {
    gates.push({blockId: entry.id, position: "before-warm"});
    gates.push({blockId: entry.id, position: "after-warm-before-side1"});
  }
  for (const blockId of expectedBlockIds(schedule).slice(schedule.performance.length)) {
    gates.push({blockId, position: "before-measurement"});
  }
  return gates;
}

function validateEnvironment(campaign, schedule) {
  const label = `campaign ${campaign.campaign_id}`;
  invariant(campaign.environment?.invalid_reason === null, `${label}: environment was invalidated`);
  invariant(sameJson(campaign.environment?.policy, ENVIRONMENT_POLICY), `${label}: environment policy mismatch`);
  const samples = campaign.environment?.samples;
  invariant(Array.isArray(samples) && samples.length >= 31, `${label}: too few environment samples`);
  const policyState = {loadBreaches: 0, siblingBreaches: 0};
  for (let index = 0; index < samples.length; index += 1) {
    const sample = samples[index];
    invariant(sample.sequence === index, `${label}: noncontiguous environment sequence`);
    invariant(typeof sample.observed_at === "string" && Number.isFinite(Date.parse(sample.observed_at)),
      `${label}: malformed environment timestamp at sample ${index}`);
    invariant(Array.isArray(sample.read_errors) && sample.read_errors.length === 0,
      `${label}: environment read failure at sample ${index}`);
    requireFinite(sample.monotonic_ms, `${label} sample ${index} monotonic`);
    requireFinite(sample.load1, `${label} sample ${index} load1`);
    requireFinite(sample.load5, `${label} sample ${index} load5`);
    requireFinite(sample.tctl_c, `${label} sample ${index} Tctl`);
    validateMonitorCpuBusy(sample, index, `${label} sample ${index}`);
    invariant(sample.tctl_c < ENVIRONMENT_POLICY.invalidTctlMinimumC,
      `${label}: Tctl invalidation threshold reached`);
    if (index === 0) {
      invariant(sample.gap_seconds === null, `${label}: first monitor gap must be null`);
    } else {
      const gap = requireFinite(sample.gap_seconds, `${label} sample ${index} gap`, {positive: true});
      invariant(gap <= ENVIRONMENT_POLICY.maximumMonitorGapSeconds, `${label}: monitor gap exceeded five seconds`);
      invariant(nearlyEqual(gap, (sample.monotonic_ms - samples[index - 1].monotonic_ms) / 1000, 1e-9),
        `${label}: monitor gap does not match monotonic timestamps`);
    }
    const invalid = environmentInvalidation(policyState, sample);
    invariant(invalid === null, `${label}: ${invalid} invalidation was present at sample ${index}`);
  }
  const initialAdmission = validateGate(campaign.admission, samples, {
    label: "campaign-initial-admission",
    requiredSeconds: ENVIRONMENT_POLICY.initialAdmissionSeconds,
  });
  const campaignAdmissions = campaign.events?.filter((event) => event.event === "campaign-admitted") ?? [];
  invariant(campaignAdmissions.length === 1 && sameJson(campaignAdmissions[0].admission, campaign.admission),
    `${label}: campaign-admitted event does not bind the initial gate`);
  invariant(Number.isFinite(Date.parse(campaignAdmissions[0].at)) &&
    Date.parse(campaignAdmissions[0].at) >= Date.parse(initialAdmission.admitted.observed_at),
  `${label}: campaign-admitted event precedes its admitted sample`);

  const expectedGates = expectedGateEvents(schedule);
  const blockEvents = campaign.events?.filter((event) => event.event === "block-admitted") ?? [];
  invariant(blockEvents.length === expectedGates.length, `${label}: block-admission count mismatch`);
  const blockGates = new Map();
  for (let index = 0; index < expectedGates.length; index += 1) {
    const expected = expectedGates[index];
    const event = blockEvents[index];
    invariant(Number.isFinite(Date.parse(event.at)), `${label}: block-admission timestamp is malformed`);
    invariant(event.block_id === expected.blockId && event.gate_position === expected.position,
      `${label}: block-admission order mismatch at ${index}`);
    const expectedLabel = `${expected.blockId}:${expected.position}`;
    invariant(event.label === expectedLabel && event.gate?.label === expectedLabel,
      `${label}: block ${expected.blockId} gate label mismatch`);
    const validated = validateGate(event.gate, samples, {
      label: expectedLabel,
      requiredSeconds: ENVIRONMENT_POLICY.blockAdmissionSeconds,
      blockDeadline: true,
    });
    invariant(event.sample_sequence === validated.admittedSequence &&
      event.tctl_c === validated.admitted.tctl_c,
    `${label}: block ${expected.blockId} endpoint evidence differs from its gate`);
    blockGates.set(`${expected.blockId}/${expected.position}`, {...validated, event});
  }
  return {blockGates, initialAdmission, campaignAdmissionEvent: campaignAdmissions[0]};
}

function runtimeFingerprint(receipt) {
  return {runtime: receipt.runtime, host: receipt.host, environment: receipt.environment};
}

function validateChildBoundary(boundary, label) {
  const observedMs = Date.parse(boundary?.observed_at);
  invariant(typeof boundary?.observed_at === "string" && Number.isFinite(observedMs),
    `${label}: invalid observation timestamp`);
  requireFinite(boundary.monotonic_ms, `${label} monotonic timestamp`);
  invariant(typeof boundary.proc_stat_cpu_line === "string" && /^cpu2\s+\d+(?:\s+\d+){4,}\s*$/.test(boundary.proc_stat_cpu_line),
    `${label}: malformed raw /proc/stat CPU 2 line`);
  invariant(Array.isArray(boundary.counters) && boundary.counters.length >= 5,
    `${label}: raw CPU 2 counters are missing`);
  const counters = boundary.counters.map((value, index) => requireDecimalInteger(value, `${label} counter ${index}`));
  const lineCounters = boundary.proc_stat_cpu_line.trim().split(/\s+/).slice(1);
  invariant(sameJson(lineCounters, boundary.counters), `${label}: parsed counters differ from raw /proc/stat line`);
  // Linux reports guest and guest_nice inside user and nice, so they must not be
  // added to the total a second time.
  const total = counters.slice(0, 8).reduce((sum, value) => sum + value, 0n);
  const idle = counters[3] + counters[4];
  invariant(requireDecimalInteger(boundary.total_ticks, `${label} total ticks`) === total,
    `${label}: total ticks differ from raw counters`);
  invariant(requireDecimalInteger(boundary.idle_ticks, `${label} idle ticks`) === idle,
    `${label}: idle ticks differ from raw counters`);
  const rawTctl = requireDecimalInteger(boundary.tctl_raw_millicelsius, `${label} raw Tctl`);
  const tctl = requireFinite(boundary.tctl_c, `${label} Tctl`);
  invariant(nearlyEqual(tctl, Number(rawTctl) / 1000), `${label}: Tctl conversion differs from raw evidence`);
  invariant(tctl < ENVIRONMENT_POLICY.invalidTctlMinimumC,
    `${label}: boundary Tctl reached the invalidation threshold`);
  return {total, idle, monotonicMs: boundary.monotonic_ms, observedMs};
}

function validateChildEnvironmentWindow(window, observation, label) {
  invariant(window?.cpu === "2" &&
    window.maximum_busy_percent === ENVIRONMENT_POLICY.childWindowSiblingBusyMaximumPercent,
  `${label}: wrong child-window CPU or limit`);
  const before = validateChildBoundary(window.before, `${label} before boundary`);
  const after = validateChildBoundary(window.after, `${label} after boundary`);
  invariant(after.monotonicMs >= before.monotonicMs, `${label}: child-window boundaries are reversed`);
  invariant(Date.parse(observation.started_at) <= before.observedMs &&
    before.observedMs <= after.observedMs && after.observedMs <= Date.parse(observation.completed_at),
  `${label}: boundary timestamps do not enclose the child execution`);
  const total = after.total - before.total;
  const idle = after.idle - before.idle;
  invariant(total > 0n && idle >= 0n && idle <= total, `${label}: invalid raw CPU 2 counter deltas`);
  const busy = total - idle;
  invariant(requireDecimalInteger(window.delta_total_ticks, `${label} total delta`) === total &&
    requireDecimalInteger(window.delta_idle_ticks, `${label} idle delta`) === idle &&
    requireDecimalInteger(window.delta_busy_ticks, `${label} busy delta`) === busy,
  `${label}: stored CPU 2 deltas differ from raw counters`);
  const busyPercent = Number(busy) / Number(total) * 100;
  invariant(nearlyEqual(window.cpu_busy_percent, busyPercent, 1e-10),
    `${label}: stored CPU 2 busy percentage differs from raw counters`);
  const withinLimit = busyPercent <= ENVIRONMENT_POLICY.childWindowSiblingBusyMaximumPercent;
  invariant(window.within_busy_limit === withinLimit && withinLimit,
    `${label}: child-window CPU 2 busy limit was exceeded`);
  return {before, after};
}

function observationGate(spec, blockGates) {
  const position = spec.phase !== "performance" ? "before-measurement" :
    spec.category === "page-cache-warm" ? "before-warm" : "after-warm-before-side1";
  return blockGates.get(`${spec.blockId}/${position}`);
}

function validateObservation(campaign, observation, spec, build, blockGates) {
  const label = `campaign ${campaign.campaign_id}/${spec.id}`;
  invariant(observation.sequence >= 0 && observation.id === spec.id && observation.block_id === spec.blockId,
    `${label}: wrong observation identity`);
  for (const field of ["fixture", "phase", "category", "mode", "side"]) {
    invariant(observation[field] === spec[field], `${label}: wrong ${field}`);
  }
  invariant(observation.valid === true && observation.validation_error === null &&
    observation.wrapper_exit_code === 0 && observation.wrapper_signal === null && observation.spawn_error === null,
  `${label}: observation is not valid`);
  invariant(typeof observation.stdout === "string" && sameJson(parseJsonText(observation.stdout, label), observation.receipt),
    `${label}: stdout and parsed receipt differ`);
  invariant(typeof observation.gnu_time_output === "string" && observation.gnu_time_output.length > 0,
    `${label}: GNU-time output is missing`);
  const audit = observation.task_audit;
  invariant(audit?.exit_status === 0, `${label}: task audit exit status is not zero`);
  requireSafeInteger(audit.maximum_resident_kibibytes, `${label} RSS`, 1);
  invariant(audit.maximum_resident_bytes === audit.maximum_resident_kibibytes * 1024,
    `${label}: RSS byte conversion mismatch`);
  requireSafeInteger(audit.cpu_percent, `${label} task CPU`);
  if (spec.parserChild) {
    invariant(audit.cpu_percent >= ENVIRONMENT_POLICY.minimumParserTaskCpuPercent,
      `${label}: parser task CPU is below 99%`);
  }
  invariant(sameJson(observation.child_environment, CHILD_ENVIRONMENT), `${label}: child environment mismatch`);
  const childWindow = validateChildEnvironmentWindow(observation.child_environment_window, observation,
    `${label} child environment window`);
  const fixtureIdentity = campaign.fixture_identities?.[spec.fixture];
  invariant(fixtureIdentity && sameJson(observation.fixture_before, fixtureIdentity.identities) &&
    sameJson(observation.fixture_after, fixtureIdentity.identities), `${label}: fixture identity changed`);
  invariant(observation.profile === fixtureIdentity.profile, `${label}: fixture profile mismatch`);
  const startSequence = requireSafeInteger(observation.environment_start_sample_sequence, `${label} start sample`);
  const endSequence = requireSafeInteger(observation.environment_end_sample_sequence, `${label} end sample`);
  const startSample = campaign.environment.samples[startSequence];
  const endSample = campaign.environment.samples[endSequence];
  invariant(startSample?.sequence === startSequence && endSample?.sequence === endSequence,
    `${label}: observation environment sample index does not resolve`);
  invariant(startSample.monotonic_ms <= childWindow.before.monotonicMs &&
    endSample.monotonic_ms <= childWindow.after.monotonicMs,
  `${label}: observation sample range is not bound to the child boundaries`);
  const afterStartSample = campaign.environment.samples[startSequence + 1];
  const afterEndSample = campaign.environment.samples[endSequence + 1];
  invariant((!afterStartSample || afterStartSample.monotonic_ms > childWindow.before.monotonicMs) &&
    (!afterEndSample || afterEndSample.monotonic_ms > childWindow.after.monotonicMs),
  `${label}: observation sample indices are not the latest samples at the child boundaries`);
  const gate = observationGate(spec, blockGates);
  invariant(gate && startSequence >= gate.admittedSequence && endSequence >= startSequence,
    `${label}: environment sample range is inconsistent with block admission`);

  const receipt = observation.receipt;
  invariant(receipt?.receipt === "fused-json-tic-measurement" && receipt.version === 1 &&
    receipt.command === spec.command && receipt.mode === spec.mode, `${label}: wrong measurement schema`);
  invariant(sameJson(receipt.arguments, observation.benchmark_arguments), `${label}: benchmark arguments differ`);
  invariant(receipt.runtime?.fused_json_commit === campaign.commit && receipt.runtime.release_build === true,
    `${label}: runtime commit/build mismatch`);
  invariant(receipt.runtime.crystal_version === build.toolchain.crystal_version &&
    receipt.runtime.llvm_version === build.toolchain.llvm_version && receipt.runtime.target === build.toolchain.target,
  `${label}: runtime toolchain differs from build attestation`);
  invariant(receipt.host?.cpu_affinity === "3", `${label}: parser was not pinned to CPU 3`);
  invariant(receipt.configuration?.buffer_size === BUFFER_SIZE &&
    receipt.configuration?.max_nesting === MAX_NESTING &&
    receipt.configuration?.fused_cache_keys === false &&
    receipt.configuration?.fused_reject_duplicate_keys === false,
  `${label}: parser configuration mismatch`);
  const retained = spec.mode.includes("retained");
  if (retained) {
    invariant(receipt.configuration.retained_output_policy === RETENTION_POLICY &&
      receipt.retained_output?.policy === RETENTION_POLICY &&
      receipt.retained_output.total_values === receipt.typed_values &&
      receipt.retained_output.provider_records === receipt.typed_provider_records &&
      receipt.retained_output.scalar_values === receipt.typed_scalar_values &&
      receipt.retained_output.price_records === receipt.typed_price_records &&
      receipt.retained_output.total_values === receipt.retained_output.provider_records +
        receipt.retained_output.scalar_values + receipt.retained_output.price_records,
    `${label}: retained-output policy mismatch`);
  } else {
    invariant(receipt.configuration.retained_output_policy === "none" && receipt.retained_output === null,
      `${label}: unexpected retained output`);
  }
  const wall = requireFinite(receipt.timing?.wall_seconds, `${label} wall time`, {positive: true});
  const throughput = requireFinite(receipt.decompressed_mib_per_second, `${label} throughput`, {positive: true});
  invariant(receipt.logical_document_bytes === fixtureIdentity.bytes,
    `${label}: logical byte count differs from fixture identity`);
  const inputPasses = spec.mode.includes("two-pass") ? 2 : 1;
  const processedBytes = fixtureIdentity.bytes * inputPasses;
  invariant(receipt.input_passes === inputPasses && receipt.processed_bytes === processedBytes &&
    nearlyEqual(throughput, (processedBytes / MIB) / wall, 1e-10),
  `${label}: processed-byte or throughput accounting mismatch`);
  return runtimeFingerprint(receipt);
}

function recomputePerformance(campaign, observations) {
  const result = {};
  for (const profile of ["many-small", "wide-item"]) {
    const entries = campaign.schedule.performance.filter((entry) => entry.profile === profile);
    const pairs = entries.map((entry) => {
      const fused = observations.get(`${entry.id}-fused`);
      const crystal = observations.get(`${entry.id}-crystal`);
      const fusedRate = requireFinite(fused.receipt.decompressed_mib_per_second,
        `${campaign.campaign_id}/${entry.id} Fused throughput`, {positive: true});
      const crystalRate = requireFinite(crystal.receipt.decompressed_mib_per_second,
        `${campaign.campaign_id}/${entry.id} Crystal throughput`, {positive: true});
      const ratio = fusedRate / crystalRate;
      return {id: entry.id, ratio, log_ratio: Math.log(ratio)};
    });
    const ratios = pairs.map((pair) => pair.ratio);
    const geometric = geometricMean(ratios);
    const lower = bootstrapLower(ratios);
    const orders = new Map(entries.map((entry) => [entry.id, entry.order]));
    const abRatios = pairs.filter((pair) => orders.get(pair.id)[0] === "fused").map((pair) => pair.ratio);
    const baRatios = pairs.filter((pair) => orders.get(pair.id)[0] === "crystal").map((pair) => pair.ratio);
    invariant(abRatios.length === 10 && baRatios.length === 10,
      `campaign ${campaign.campaign_id}/${profile}: performance order groups are not balanced`);
    const abGeometric = geometricMean(abRatios);
    const baGeometric = geometricMean(baRatios);
    const orderDiagnostics = {
      ab_order: "FusedJSON then Crystal",
      ab_pair_count: abRatios.length,
      ab_geometric_mean_ratio: abGeometric,
      ba_order: "Crystal then FusedJSON",
      ba_pair_count: baRatios.length,
      ba_geometric_mean_ratio: baGeometric,
      order_contrast_ratio: abGeometric / baGeometric,
      order_contrast_formula: "AB geometric mean / BA geometric mean",
      interpretation: "diagnostic-only; never gates or excludes a campaign",
    };
    const passed = geometric >= PERFORMANCE.geometricMeanGate && lower > PERFORMANCE.bootstrapLowerGate;
    const stored = campaign.analysis?.performance?.[profile];
    invariant(stored?.pair_count === 20 && nearlyEqual(stored.geometric_mean_ratio, geometric) &&
      nearlyEqual(stored.bootstrap_one_sided_95_lower, lower) && stored.passed === passed,
    `campaign ${campaign.campaign_id}/${profile}: stored performance analysis differs from raw observations`);
    invariant(passed, `campaign ${campaign.campaign_id}/${profile}: performance gate failed`);
    result[profile] = {
      pair_count: pairs.length,
      geometric_mean_ratio: geometric,
      bootstrap_one_sided_95_lower: lower,
      passed,
      order_diagnostics: orderDiagnostics,
      pairs,
    };
  }
  return result;
}

function recomputeRss(campaign, observations) {
  const baseline = campaign.schedule.bounded_rss_baselines.map((entry) =>
    observations.get(entry.id).task_audit.maximum_resident_kibibytes);
  const ceiling = rssCeiling(baseline);
  for (const field of Object.keys(ceiling)) {
    invariant(campaign.rss_ceiling?.[field] === ceiling[field],
      `campaign ${campaign.campaign_id}: stored RSS ${field} differs from raw observations`);
  }
  const large = campaign.schedule.bounded_rss_large.map((entry) => {
    const peak = observations.get(entry.id).task_audit.maximum_resident_kibibytes;
    return {id: entry.id, peak_rss_kibibytes: peak, strictly_below_ceiling: peak < ceiling.ceiling_kibibytes};
  });
  const passed = large.every((entry) => entry.strictly_below_ceiling);
  invariant(campaign.analysis?.bounded_rss?.passed === passed && passed,
    `campaign ${campaign.campaign_id}: bounded RSS gate failed or stored analysis differs`);
  return {baseline_peak_rss_kibibytes: baseline, ...ceiling, large, passed};
}

function logicalBlocks(schedule) {
  const blocks = [];
  for (const spec of expectedExecution(schedule)) {
    let block = blocks.at(-1);
    if (!block || block.id !== spec.blockId) {
      block = {id: spec.blockId, phase: spec.phase, specs: []};
      blocks.push(block);
    }
    block.specs.push(spec);
  }
  return blocks;
}

function gateBeforeChild(gate, child, label) {
  invariant(gate.admittedSequence <= child.environment_start_sample_sequence &&
    gate.admitted.monotonic_ms <= gate.admittedEvaluatedMonotonicMs &&
    gate.admittedEvaluatedMonotonicMs <= child.child_environment_window.before.monotonic_ms,
  `${label}: gate endpoint is not before its first child`);
  invariant(Date.parse(gate.event.at) >= Date.parse(gate.admitted.observed_at) &&
    Date.parse(gate.event.at) <= Date.parse(child.started_at),
  `${label}: gate event is not between admission and its first child`);
}

function gateAfterObservation(gate, observation, label) {
  invariant(gate.firstSequence > observation.environment_end_sample_sequence,
    `${label}: gate reused an environment sample from before its predecessor completed`);
  invariant(gate.waitStartedMonotonicMs > observation.child_environment_window.after.monotonic_ms &&
    gate.first.monotonic_ms > gate.waitStartedMonotonicMs,
  `${label}: gate wait did not begin after its predecessor child boundary`);
  invariant(Date.parse(gate.first.observed_at) >= Date.parse(observation.completed_at) &&
    Date.parse(gate.event.at) >= Date.parse(observation.completed_at),
  `${label}: gate chronology precedes its predecessor completion`);
}

function gatesBetweenChildren(previous, next, blockGates) {
  return [...blockGates.values()].filter((gate) => {
    const bySamples = gate.firstSequence > previous.environment_end_sample_sequence &&
      gate.admittedSequence <= next.environment_start_sample_sequence;
    const eventAt = Date.parse(gate.event.at);
    const byTime = eventAt > Date.parse(previous.completed_at) && eventAt < Date.parse(next.started_at);
    return bySamples || byTime;
  });
}

function validateChildTransition(previous, next, blockGates, expectedGates, label) {
  invariant(previous.environment_end_sample_sequence <= next.environment_start_sample_sequence &&
    previous.child_environment_window.after.monotonic_ms <=
      next.child_environment_window.before.monotonic_ms &&
    Date.parse(previous.completed_at) <= Date.parse(next.started_at),
  `${label}: children did not execute in declared order`);
  const intervening = gatesBetweenChildren(previous, next, blockGates);
  invariant(intervening.length === expectedGates.length &&
    expectedGates.every((gate) => intervening.includes(gate)),
  `${label}: intervening block-gate sequence differs from the declared execution`);
}

function validateGatePositioning(campaign, schedule, observations, environmentEvidence) {
  const label = `campaign ${campaign.campaign_id}`;
  const {blockGates, initialAdmission, campaignAdmissionEvent} = environmentEvidence;
  const blocks = logicalBlocks(schedule);
  invariant(blocks.length === 77, `${label}: logical block count mismatch`);
  let previousFinalChild = null;
  for (const [index, block] of blocks.entries()) {
    const firstPosition = block.phase === "performance" ? "before-warm" : "before-measurement";
    const firstGate = blockGates.get(`${block.id}/${firstPosition}`);
    const children = block.specs.map((spec) => observations.get(spec.id));
    invariant(firstGate && children.every(Boolean), `${label}/${block.id}: block evidence is incomplete`);
    if (index === 0) {
      invariant(firstGate.firstSequence > initialAdmission.admittedSequence &&
        firstGate.waitStartedMonotonicMs > initialAdmission.admitted.monotonic_ms,
      `${label}/${block.id}: first block gate did not begin after initial admission`);
      invariant(Date.parse(firstGate.first.observed_at) >= Date.parse(campaignAdmissionEvent.at) &&
        Date.parse(firstGate.event.at) >= Date.parse(campaignAdmissionEvent.at),
      `${label}/${block.id}: first block gate precedes the campaign-admitted event`);
    } else {
      gateAfterObservation(firstGate, previousFinalChild,
        `${label}/${block.id} first gate`);
    }
    gateBeforeChild(firstGate, children[0], `${label}/${block.id} first gate`);

    let afterWarm = null;
    if (block.phase === "performance") {
      afterWarm = blockGates.get(`${block.id}/after-warm-before-side1`);
      invariant(afterWarm, `${label}/${block.id}: post-warm gate is missing`);
      gateAfterObservation(afterWarm, children[0], `${label}/${block.id} post-warm gate`);
      gateBeforeChild(afterWarm, children[1], `${label}/${block.id} post-warm gate`);
    }
    for (let childIndex = 1; childIndex < children.length; childIndex += 1) {
      const expectedGates = block.phase === "performance" && childIndex === 1 ? [afterWarm] : [];
      validateChildTransition(children[childIndex - 1], children[childIndex], blockGates, expectedGates,
        `${label}/${block.id} child ${childIndex - 1}->${childIndex}`);
    }
    previousFinalChild = children.at(-1);
  }
}

function validateCampaign(campaign, build) {
  const label = `campaign ${campaign?.campaign_id ?? "?"}`;
  invariant(campaign?.artifact === ARTIFACT && campaign.version === VERSION, `${label}: wrong campaign schema`);
  invariant([1, 2].includes(campaign.campaign_id), `${label}: campaign ID must be 1 or 2`);
  invariant(campaign.status === "complete-passed" && campaign.valid === true && campaign.passed === true,
    `${label}: campaign is not complete, valid, and passed`);
  invariant(isCommit(campaign.commit) && campaign.commit === build.commit, `${label}: commit differs from build`);
  invariant(Array.isArray(campaign.errors) && campaign.errors.length === 0 && campaign.interruption === null,
    `${label}: campaign contains errors or interruption`);
  validateDefinition(campaign);
  const expectedSchedule = buildSchedule();
  invariant(sameJson(campaign.schedule, expectedSchedule), `${label}: schedule differs from frozen schedule`);
  invariant(sameJson(Object.keys(campaign.fixture_identities ?? {}).sort(), [...EXPECTED_FIXTURES].sort()),
    `${label}: fixture set is incomplete`);
  invariant(campaign.semantic_preflight?.artifact === "fused-json-m6-tic-preflight" &&
    campaign.semantic_preflight.version === 1 && campaign.semantic_preflight.status === "complete" &&
    campaign.semantic_preflight.valid === true && isSha256(campaign.semantic_preflight.sha256),
  `${label}: semantic preflight is not bound and valid`);
  invariant(isSha256(campaign.identities?.binary?.sha256) &&
    campaign.identities.binary.sha256 === build.artifacts.tic_bench.sha256 &&
    campaign.identities.binary.bytes === String(build.artifacts.tic_bench.bytes),
  `${label}: benchmark binary differs from build attestation`);
  for (const name of ["runner", "node", "gnu_time", "taskset", "preflight"]) {
    invariant(isSha256(campaign.identities?.[name]?.sha256), `${label}: missing ${name} identity`);
  }
  invariant(campaign.semantic_preflight.sha256 === campaign.identities.preflight.sha256,
    `${label}: semantic-preflight summary/hash identity mismatch`);
  invariant(typeof campaign.runner_runtime?.version === "string" &&
    typeof campaign.runner_runtime?.executable === "string" &&
    path.resolve(campaign.runner_runtime.executable) === path.resolve(campaign.identities.node.path),
  `${label}: missing or inconsistent Node runtime identity`);

  const specs = expectedExecution(expectedSchedule);
  invariant(specs.length === 173, "internal expected observation count is not 173");
  const completion = campaign.completion;
  invariant(completion?.complete === true && completion.expected_count === 173 && completion.actual_count === 173 &&
    [completion.missing, completion.unexpected, completion.duplicate, completion.invalid]
      .every((values) => Array.isArray(values) && values.length === 0),
  `${label}: completion receipt is not exact`);
  invariant(Array.isArray(campaign.observations) && campaign.observations.length === specs.length,
    `${label}: observation count mismatch`);
  invariant(sameJson(campaign.observations.map((entry) => entry.id), specs.map((entry) => entry.id)),
    `${label}: observation execution order differs from schedule`);
  const environmentEvidence = validateEnvironment(campaign, expectedSchedule);
  const {blockGates} = environmentEvidence;
  const fingerprints = [];
  const observations = new Map();
  for (let index = 0; index < specs.length; index += 1) {
    const observation = campaign.observations[index];
    invariant(observation.sequence === index, `${label}: observation sequence mismatch at ${index}`);
    fingerprints.push(validateObservation(campaign, observation, specs[index], build, blockGates));
    observations.set(observation.id, observation);
  }
  validateGatePositioning(campaign, expectedSchedule, observations, environmentEvidence);
  invariant(fingerprints.every((fingerprint) => sameJson(fingerprint, fingerprints[0])),
    `${label}: runtime/host/environment fingerprint changed within campaign`);
  const performance = recomputePerformance(campaign, observations);
  const rss = recomputeRss(campaign, observations);
  invariant(campaign.analysis?.passed === true, `${label}: composite analysis did not pass`);
  return {campaign, fingerprint: fingerprints[0], performance, rss};
}

function validateShared(first, second) {
  invariant(first.campaign.campaign_id !== second.campaign.campaign_id &&
    new Set([first.campaign.campaign_id, second.campaign.campaign_id]).size === 2,
  "campaign IDs are not the required distinct pair");
  const left = first.campaign;
  const right = second.campaign;
  for (const field of ["commit", "definition", "schedule", "fixture_identities", "host", "runner_runtime"] ) {
    invariant(sameJson(left[field], right[field]), `campaigns differ in shared ${field}`);
  }
  invariant(sameJson(left.semantic_preflight, right.semantic_preflight),
    "campaigns do not use the same semantic preflight");
  invariant(left.environment.tctl_path === right.environment.tctl_path,
    "campaigns used different Tctl sensors");
  invariant(sameJson(left.environment.policy, right.environment.policy) &&
    sameJson(left.environment.policy, ENVIRONMENT_POLICY),
  "campaigns did not use the identical frozen busy-pinned-v2 policy");
  for (const name of ["runner", "binary", "node", "gnu_time", "taskset", "preflight"]) {
    invariant(left.identities[name].sha256 === right.identities[name].sha256,
      `campaigns differ in ${name} artifact SHA-256`);
  }
  invariant(sameJson(first.fingerprint, second.fingerprint),
    "campaign runtime/host/environment fingerprints differ");
}

function crossCampaignOrderDiagnostics(campaigns) {
  const diagnostics = {};
  for (const profile of ["many-small", "wide-item"]) {
    const ab = [];
    const ba = [];
    for (const entry of campaigns) {
      const orders = new Map(entry.campaign.schedule.performance.map((pair) => [pair.id, pair.order]));
      for (const pair of entry.performance[profile].pairs) {
        (orders.get(pair.id)[0] === "fused" ? ab : ba).push(pair.ratio);
      }
    }
    invariant(ab.length === 20 && ba.length === 20,
      `${profile}: cross-campaign performance order groups are not balanced`);
    const abGeometric = geometricMean(ab);
    const baGeometric = geometricMean(ba);
    diagnostics[profile] = {
      ab_order: "FusedJSON then Crystal",
      ab_pair_count: ab.length,
      ab_geometric_mean_ratio: abGeometric,
      ba_order: "Crystal then FusedJSON",
      ba_pair_count: ba.length,
      ba_geometric_mean_ratio: baGeometric,
      order_contrast_ratio: abGeometric / baGeometric,
      order_contrast_formula: "AB geometric mean / BA geometric mean",
      interpretation: "diagnostic-only; never gates or excludes a campaign",
    };
  }
  return diagnostics;
}

function runSelfAudit() {
  const assertions = [];
  const check = (name, callback) => { callback(); assertions.push(name); };
  const rejects = (callback, pattern) => {
    try {
      callback();
    } catch (error) {
      invariant(pattern.test(error.message), `unexpected rejection: ${error.message}`);
      return;
    }
    throw new Error("expected callback to reject");
  };
  check("frozen-schedule", () => {
    const schedule = buildSchedule();
    const specs = expectedExecution(schedule);
    const gates = expectedGateEvents(schedule);
    invariant(schedule.performance.length === 40 && specs.length === 173 && expectedBlockIds(schedule).length === 77 &&
      logicalBlocks(schedule).length === 77 && gates.length === 117 &&
      gates.filter((gate) => gate.position === "after-warm-before-side1").length === 40,
      "frozen schedule cardinality mismatch");
    const plainDrain = specs.find((entry) => entry.id === "diagnostic-plain-drain-many");
    const retained = specs.find((entry) => entry.id === "diagnostic-retained-00-fused");
    invariant(plainDrain?.phase === "diagnostics" && plainDrain.category === "plain-drain-rss" &&
      plainDrain.mode === "plain-drain" && plainDrain.command === "rss" && plainDrain.parserChild === false,
    "plain-drain diagnostic execution spec mismatch");
    invariant(retained?.category === "retained-output-rss" && retained.mode === "fused-retained-typed" &&
      retained.command === "rss" && retained.parserChild === true,
    "retained diagnostic execution spec mismatch");
    const reversePair = specs.filter((entry) => entry.blockId === "performance-01");
    invariant(sameJson(reversePair.map((entry) => entry.id),
      ["performance-01-warm", "performance-01-crystal", "performance-01-fused"]),
    "performance BA execution order mismatch");
    for (const profile of ["many-small", "wide-item"]) {
      const entries = schedule.performance.filter((entry) => entry.profile === profile);
      invariant(entries.length === 20 && entries.filter((entry) => entry.order[0] === "fused").length === 10 &&
        entries.filter((entry) => entry.slot === 0).length === 10, `${profile} schedule is not balanced`);
    }
  });
  check("bootstrap", () => {
    const values = Array(20).fill(1.1);
    invariant(nearlyEqual(geometricMean(values), 1.1) && bootstrapLower(values) > 1.0,
      "passing bootstrap vector failed");
    invariant(bootstrapLower(Array(20).fill(1.0)) === 1.0, "strict bootstrap equality was not preserved");
  });
  check("rss-kibibyte-ceiling", () => {
    const ceiling = rssCeiling([...Array(9).fill(100_000), 100_001]);
    invariant(ceiling.maximum_baseline_kibibytes === 100_001 && ceiling.headroom_kibibytes === 25_001 &&
      ceiling.ceiling_kibibytes === 125_002, "RSS KiB rounding mismatch");
    invariant(!(ceiling.ceiling_kibibytes < ceiling.ceiling_kibibytes), "RSS equality must fail strict gate");
  });
  check("build-attestation", () => {
    validateBuildAttestation({
      artifact: BUILD_ARTIFACT,
      version: 1,
      commit: "d".repeat(40),
      git: {clean: true, head: "d".repeat(40)},
      commands: ["crystal build --release --no-debug bench/tic.cr -o /tmp/tic-bench"],
      toolchain: {crystal_version: "1.22", llvm_version: "21", target: "x86_64"},
      artifacts: {tic_bench: {sha256: "e".repeat(64), bytes: 123, path: "/tmp/tic-bench"}},
    });
  });
  check("canonical-comparison", () => {
    invariant(sameJson({b: 2, a: {d: 4, c: 3}}, {a: {c: 3, d: 4}, b: 2}),
      "canonical object comparison is order-sensitive");
  });
  check("busy-pinned-v2-gates", () => {
    invariant(ENVIRONMENT_POLICY.name === "busy-pinned-v2" && ENVIRONMENT_POLICY.version === 2 &&
      ENVIRONMENT_POLICY.initialAdmissionSeconds === 60 && ENVIRONMENT_POLICY.blockAdmissionSeconds === 6 &&
      ENVIRONMENT_POLICY.gateLoad1Maximum === 5 && ENVIRONMENT_POLICY.gateLoad5Maximum === 5 &&
      ENVIRONMENT_POLICY.gateTctlMaximumC === 94 && ENVIRONMENT_POLICY.gateTctlRangeMaximumC === 5 &&
      ENVIRONMENT_POLICY.gateSiblingCpuBusyMaximumPercent === 25 &&
      ENVIRONMENT_POLICY.gateBenchmarkCpuBusyMaximumPercent === 10,
    "busy-pinned-v2 gate constants changed");
    const samples = Array.from({length: 31}, (_, sequence) => ({
      sequence,
      monotonic_ms: sequence * 2_000,
      load1: 5,
      load5: 5,
      tctl_c: sequence % 2 === 0 ? 89 : 94,
      cpu2_busy_percent: 25,
      cpu3_busy_percent: 10,
    }));
    const gate = {
      label: "campaign-initial-admission",
      required_continuous_seconds: 60,
      first_sample_sequence: 0,
      admitted_sample_sequence: 30,
      sample_sequences: samples.map((sample) => sample.sequence),
      sample_count: 31,
      duration_seconds: 60,
      tctl_min_c: 89,
      tctl_max_c: 94,
      tctl_range_c: 5,
    };
    validateGate(gate, samples, {label: gate.label, requiredSeconds: 60});
    rejects(() => validateGate({...gate, admitted_evaluated_monotonic_ms: 60_000}, samples,
      {label: gate.label, requiredSeconds: 60}), /unexpectedly contains block timing evidence/);
    const excessiveRange = structuredClone(samples);
    excessiveRange[0].tctl_c = 88;
    rejects(() => validateGate({...gate, tctl_min_c: 88, tctl_range_c: 6}, excessiveRange,
      {label: gate.label, requiredSeconds: 60}), /range exceeds/);
    const highLoad = structuredClone(samples);
    highLoad[15].load1 = 5.01;
    rejects(() => validateGate(gate, highLoad, {label: gate.label, requiredSeconds: 60}), /unacceptable/);
    const blockSamples = samples.slice(0, 4).map((sample, sequence) => ({
      ...sample, sequence, monotonic_ms: 174_000 + (sequence * 2_000), tctl_c: 90,
    }));
    const blockGate = {
      ...gate,
      label: "performance-00:before-warm",
      required_continuous_seconds: 6,
      first_sample_sequence: 0,
      admitted_sample_sequence: 3,
      sample_sequences: [0, 1, 2, 3],
      sample_count: 4,
      duration_seconds: 6,
      tctl_min_c: 90,
      tctl_max_c: 90,
      tctl_range_c: 0,
      wait_started_monotonic_ms: 0,
      deadline_monotonic_ms: 180_000,
      admitted_evaluated_monotonic_ms: 180_000,
    };
    validateGate(blockGate, blockSamples,
      {label: blockGate.label, requiredSeconds: 6, blockDeadline: true});
    const lateSamples = structuredClone(blockSamples);
    lateSamples.forEach((sample) => { sample.monotonic_ms += 1; });
    rejects(() => validateGate({...blockGate, admitted_evaluated_monotonic_ms: 180_001}, lateSamples,
      {label: blockGate.label, requiredSeconds: 6, blockDeadline: true}), /after its exact deadline/);
    rejects(() => validateGate({...blockGate, admitted_evaluated_monotonic_ms: 180_000.001}, blockSamples,
      {label: blockGate.label, requiredSeconds: 6, blockDeadline: true}), /after its exact deadline/);
    rejects(() => validateGate({...blockGate, admitted_evaluated_monotonic_ms: 179_999.999}, blockSamples,
      {label: blockGate.label, requiredSeconds: 6, blockDeadline: true}), /precedes its admitted sample/);
  });
  check("busy-pinned-v2-invalidation", () => {
    const base = {read_errors: [], gap_seconds: 2, tctl_c: 94, load1: 5, cpu2_busy_percent: 25};
    let state = {loadBreaches: 0, siblingBreaches: 0};
    invariant(environmentInvalidation(state, {...base, load1: 7}) === null,
      "load invalidation was not strict");
    invariant(environmentInvalidation(state, {...base, load1: 7.01}) === null &&
      environmentInvalidation(state, {...base, load1: 7.01}) === "load1",
    "two consecutive load breaches did not invalidate");
    state = {loadBreaches: 0, siblingBreaches: 0};
    invariant(environmentInvalidation(state, {...base, cpu2_busy_percent: 35}) === null,
      "CPU 2 invalidation was not strict");
    invariant(environmentInvalidation(state, {...base, cpu2_busy_percent: 35.01}) === null &&
      environmentInvalidation(state, {...base, cpu2_busy_percent: 35.01}) === "CPU 2",
    "two consecutive CPU 2 breaches did not invalidate");
    invariant(environmentInvalidation({loadBreaches: 0, siblingBreaches: 0}, {...base, tctl_c: 100}) === "Tctl",
      "Tctl equality did not invalidate immediately");
  });
  check("monitor-cpu-types", () => {
    validateMonitorCpuBusy({cpu2_busy_percent: null, cpu3_busy_percent: null}, 0, "sample 0");
    validateMonitorCpuBusy({cpu2_busy_percent: 0, cpu3_busy_percent: 100}, 1, "sample 1");
    rejects(() => validateMonitorCpuBusy({cpu2_busy_percent: "0", cpu3_busy_percent: 1}, 1, "sample 1"),
      /finite number/);
    rejects(() => validateMonitorCpuBusy({cpu2_busy_percent: 100.01, cpu3_busy_percent: 1}, 1, "sample 1"),
      /exceeds 100/);
  });
  check("child-cpu2-window", () => {
    const boundary = (observedAt, monotonicMs, counters, tctlRaw) => {
      const values = counters.map(String);
      const parsed = values.map(BigInt);
      return {
        observed_at: observedAt,
        monotonic_ms: monotonicMs,
        proc_stat_cpu_line: `cpu2 ${values.join(" ")}`,
        counters: values,
        total_ticks: parsed.slice(0, 8).reduce((sum, value) => sum + value, 0n).toString(),
        idle_ticks: (parsed[3] + parsed[4]).toString(),
        tctl_raw_millicelsius: String(tctlRaw),
        tctl_c: tctlRaw / 1000,
      };
    };
    const before = boundary("2026-08-24T00:00:01.000Z", 1_000,
      [100, 10, 20, 100, 5, 3, 2, 1, 0, 0], 93_000);
    const after = boundary("2026-08-24T00:00:02.000Z", 2_000,
      [105, 10, 20, 120, 5, 3, 2, 1, 0, 0], 94_000);
    const window = {
      cpu: "2",
      maximum_busy_percent: 25,
      before,
      after,
      delta_total_ticks: "25",
      delta_idle_ticks: "20",
      delta_busy_ticks: "5",
      cpu_busy_percent: 20,
      within_busy_limit: true,
    };
    const observation = {
      started_at: "2026-08-24T00:00:00.000Z",
      completed_at: "2026-08-24T00:00:03.000Z",
    };
    validateChildEnvironmentWindow(window, observation, "synthetic child");
    rejects(() => validateChildEnvironmentWindow({...window, delta_busy_ticks: "6"}, observation,
      "synthetic child"), /deltas differ/);
    const hotAfter = structuredClone(after);
    hotAfter.tctl_raw_millicelsius = "100000";
    hotAfter.tctl_c = 100;
    rejects(() => validateChildEnvironmentWindow({...window, after: hotAfter}, observation,
      "synthetic child"), /invalidation threshold/);
    const coerciveTctl = structuredClone(after);
    coerciveTctl.tctl_raw_millicelsius = 94_000;
    rejects(() => validateChildEnvironmentWindow({...window, after: coerciveTctl}, observation,
      "synthetic child"), /unsigned decimal integer string/);
  });
  check("fresh-block-chronology", () => {
    const previous = {
      environment_end_sample_sequence: 5,
      completed_at: "2026-08-24T00:00:02.000Z",
      child_environment_window: {after: {monotonic_ms: 200}},
    };
    const gate = {
      firstSequence: 6,
      admittedSequence: 9,
      admittedEvaluatedMonotonicMs: 208.5,
      waitStartedMonotonicMs: 201,
      first: {monotonic_ms: 202, observed_at: "2026-08-24T00:00:03.000Z"},
      admitted: {monotonic_ms: 208, observed_at: "2026-08-24T00:00:08.000Z"},
      event: {at: "2026-08-24T00:00:09.000Z"},
    };
    const firstChild = {
      environment_start_sample_sequence: 9,
      environment_end_sample_sequence: 10,
      started_at: "2026-08-24T00:00:10.000Z",
      completed_at: "2026-08-24T00:00:11.000Z",
      child_environment_window: {before: {monotonic_ms: 209}, after: {monotonic_ms: 300}},
    };
    const secondChild = {
      environment_start_sample_sequence: 10,
      environment_end_sample_sequence: 11,
      started_at: "2026-08-24T00:00:12.000Z",
      completed_at: "2026-08-24T00:00:13.000Z",
      child_environment_window: {before: {monotonic_ms: 301}, after: {monotonic_ms: 400}},
    };
    gateAfterObservation(gate, previous, "fresh gate");
    gateBeforeChild(gate, firstChild, "fresh gate");
    const gates = new Map([["block/before-measurement", gate]]);
    validateChildTransition(previous, firstChild, gates, [gate], "gated transition");
    validateChildTransition(firstChild, secondChild, gates, [], "ungated transition");
    rejects(() => gateAfterObservation({...gate, firstSequence: 5}, previous, "stale gate"), /reused/);
  });
  console.log(JSON.stringify({
    artifact: `${AUDIT_ARTIFACT}-self-audit`,
    version: VERSION,
    status: "passed",
    assertions,
    expected_observations_per_campaign: 173,
    expected_blocks_per_campaign: 77,
    expected_gate_events_per_campaign: 117,
    bootstrap: PERFORMANCE,
    rss: RSS,
  }, null, 2));
}

function audit(options) {
  invariant(options.campaign1 !== options.campaign2, "campaign input paths must be distinct");
  const identities = {
    campaign_1: fileIdentity(options.campaign1),
    campaign_2: fileIdentity(options.campaign2),
    build_attestation: fileIdentity(options.buildAttestation),
    auditor: fileIdentity(process.argv[1]),
    node: fileIdentity(process.execPath),
  };
  const build = validateBuildAttestation(parseJsonFile(options.buildAttestation));
  const first = validateCampaign(parseJsonFile(options.campaign1), build);
  const second = validateCampaign(parseJsonFile(options.campaign2), build);
  validateShared(first, second);
  const ordered = [first, second].sort((left, right) =>
    left.campaign.campaign_id - right.campaign.campaign_id);
  return {
    artifact: AUDIT_ARTIFACT,
    version: VERSION,
    status: "passed",
    valid: true,
    audited_at: new Date().toISOString(),
    identities,
    binding: {
      commit: build.commit,
      build_attestation_sha256: identities.build_attestation.sha256,
      campaign_sha256: Object.fromEntries(ordered.map((entry) => [
        String(entry.campaign.campaign_id),
        entry.campaign.campaign_id === first.campaign.campaign_id
          ? identities.campaign_1.sha256 : identities.campaign_2.sha256,
      ])),
      tic_bench_sha256: build.artifacts.tic_bench.sha256,
      runner_sha256: ordered[0].campaign.identities.runner.sha256,
      node_sha256: ordered[0].campaign.identities.node.sha256,
      preflight_sha256: ordered[0].campaign.identities.preflight.sha256,
      gnu_time_sha256: ordered[0].campaign.identities.gnu_time.sha256,
      taskset_sha256: ordered[0].campaign.identities.taskset.sha256,
      toolchain: build.toolchain,
      host: ordered[0].campaign.host,
    },
    checks: {
      campaign_ids_exactly_1_and_2: true,
      both_complete_valid_and_passed: true,
      exact_frozen_schedules: true,
      no_missing_duplicate_invalid_or_retried_observations: true,
      shared_artifacts_fixtures_host_and_runtime: true,
      build_attestation_matches_every_measurement: true,
      environment_rules_and_block_admissions_rechecked: true,
      exact_block_gate_deadlines_rechecked: true,
      admitted_gate_evaluation_deadlines_rechecked: true,
      fresh_block_and_child_chronology_rechecked: true,
      observation_environment_indices_and_boundaries_rechecked: true,
      monitor_cpu_sample_types_and_ranges_rechecked: true,
      identical_busy_pinned_v2_policy: true,
      child_cpu2_raw_counters_deltas_and_boundary_tctl_rechecked: true,
      performance_order_contrast_is_diagnostic_only: true,
      task_cpu_gate_rechecked: true,
      performance_statistics_and_gates_recomputed: true,
      rss_ceiling_and_strict_large_gate_recomputed: true,
    },
    diagnostics: {
      performance_order: crossCampaignOrderDiagnostics(ordered),
    },
    campaigns: Object.fromEntries(ordered.map((entry) => [String(entry.campaign.campaign_id), {
      started_at: entry.campaign.started_at,
      completed_at: entry.campaign.completed_at,
      observation_count: entry.campaign.observations.length,
      performance: entry.performance,
      bounded_rss: entry.rss,
    }])),
  };
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.selfAudit) return runSelfAudit();
  invariant(!fs.existsSync(options.output), `output already exists: ${options.output}`);
  let result;
  try {
    result = audit(options);
  } catch (error) {
    result = {
      artifact: AUDIT_ARTIFACT,
      version: VERSION,
      status: "failed",
      valid: false,
      audited_at: new Date().toISOString(),
      inputs: {
        campaign_1: options.campaign1,
        campaign_2: options.campaign2,
        build_attestation: options.buildAttestation,
      },
      error: error.stack ?? error.message,
    };
    process.exitCode = 1;
  }
  writeDurableAtomicNew(options.output, `${JSON.stringify(result, null, 2)}\n`);
}

try {
  main();
} catch (error) {
  console.error(error.stack ?? error.message);
  process.exitCode = 1;
}
