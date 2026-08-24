#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const ARTIFACT = "fused-json-milestone-6-tic-campaign";
const AUDIT_ARTIFACT = "fused-json-m6-cross-campaign-audit";
const BUILD_ARTIFACT = "fused-json-m6-build-attestation";
const VERSION = 1;
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
  sampleIntervalMs: 2_000,
  admissionSeconds: 60,
  admissionLoad1Maximum: 2.5,
  admissionLoad5Maximum: 2.5,
  admissionTctlMaximumC: 70,
  admissionCpuBusyMaximumPercent: 10,
  startTctlMaximumC: 70,
  cooldownSeconds: 180,
  invalidTctlMinimumC: 95,
  invalidLoad1StrictlyGreaterThan: 4.0,
  invalidSiblingBusyStrictlyGreaterThanPercent: 20,
  consecutiveBreachSamples: 2,
  maximumMonitorGapSeconds: 5,
  minimumParserTaskCpuPercent: 99,
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
  invariant(definition?.protocol === "fused-json-m6-tic-v1" &&
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

function validateEnvironment(campaign, blockIds) {
  const label = `campaign ${campaign.campaign_id}`;
  invariant(campaign.environment?.invalid_reason === null, `${label}: environment was invalidated`);
  invariant(sameJson(campaign.environment?.policy, ENVIRONMENT_POLICY), `${label}: environment policy mismatch`);
  const samples = campaign.environment?.samples;
  invariant(Array.isArray(samples) && samples.length >= 31, `${label}: too few environment samples`);
  let loadBreaches = 0;
  let siblingBreaches = 0;
  for (let index = 0; index < samples.length; index += 1) {
    const sample = samples[index];
    invariant(sample.sequence === index, `${label}: noncontiguous environment sequence`);
    invariant(Array.isArray(sample.read_errors) && sample.read_errors.length === 0,
      `${label}: environment read failure at sample ${index}`);
    requireFinite(sample.monotonic_ms, `${label} sample ${index} monotonic`);
    requireFinite(sample.load1, `${label} sample ${index} load1`);
    requireFinite(sample.load5, `${label} sample ${index} load5`);
    requireFinite(sample.tctl_c, `${label} sample ${index} Tctl`);
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
    loadBreaches = sample.load1 > ENVIRONMENT_POLICY.invalidLoad1StrictlyGreaterThan
      ? loadBreaches + 1 : 0;
    siblingBreaches = sample.cpu2_busy_percent !== null &&
      sample.cpu2_busy_percent > ENVIRONMENT_POLICY.invalidSiblingBusyStrictlyGreaterThanPercent
      ? siblingBreaches + 1 : 0;
    invariant(loadBreaches < ENVIRONMENT_POLICY.consecutiveBreachSamples,
      `${label}: consecutive load invalidation was present`);
    invariant(siblingBreaches < ENVIRONMENT_POLICY.consecutiveBreachSamples,
      `${label}: consecutive sibling-CPU invalidation was present`);
  }
  const admission = campaign.admission;
  requireFinite(admission?.first_acceptable_monotonic_ms, `${label} admission start`);
  requireSafeInteger(admission?.admitted_sample_sequence, `${label} admission sequence`);
  const admitted = samples[admission.admitted_sample_sequence];
  invariant(admitted, `${label}: admitted environment sample is missing`);
  const admissionWindow = samples.filter((sample) =>
    sample.monotonic_ms >= admission.first_acceptable_monotonic_ms && sample.sequence <= admitted.sequence);
  invariant(admissionWindow.some((sample) => sample.monotonic_ms === admission.first_acceptable_monotonic_ms),
    `${label}: admission streak does not start on a sample`);
  invariant(admitted.monotonic_ms - admission.first_acceptable_monotonic_ms >=
    ENVIRONMENT_POLICY.admissionSeconds * 1000, `${label}: admission streak was shorter than 60 seconds`);
  invariant(admissionWindow.every((sample) =>
    sample.load1 <= ENVIRONMENT_POLICY.admissionLoad1Maximum &&
    sample.load5 <= ENVIRONMENT_POLICY.admissionLoad5Maximum &&
    sample.tctl_c <= ENVIRONMENT_POLICY.admissionTctlMaximumC &&
    sample.cpu2_busy_percent !== null && sample.cpu2_busy_percent <= ENVIRONMENT_POLICY.admissionCpuBusyMaximumPercent &&
    sample.cpu3_busy_percent !== null && sample.cpu3_busy_percent <= ENVIRONMENT_POLICY.admissionCpuBusyMaximumPercent),
  `${label}: admission streak contains an unacceptable sample`);

  const blockEvents = campaign.events?.filter((event) => event.event === "block-admitted") ?? [];
  invariant(sameJson(blockEvents.map((event) => event.label), blockIds), `${label}: block-admission order mismatch`);
  const blockSamples = new Map();
  for (const event of blockEvents) {
    const sample = samples[event.sample_sequence];
    invariant(sample && sample.tctl_c <= ENVIRONMENT_POLICY.startTctlMaximumC,
      `${label}: block ${event.label} did not start from a <=70 C sample`);
    invariant(event.tctl_c === sample.tctl_c, `${label}: block ${event.label} temperature receipt mismatch`);
    blockSamples.set(event.label, sample.sequence);
  }
  return blockSamples;
}

function runtimeFingerprint(receipt) {
  return {runtime: receipt.runtime, host: receipt.host, environment: receipt.environment};
}

function validateObservation(campaign, observation, spec, build, blockSamples) {
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
  const fixtureIdentity = campaign.fixture_identities?.[spec.fixture];
  invariant(fixtureIdentity && sameJson(observation.fixture_before, fixtureIdentity.identities) &&
    sameJson(observation.fixture_after, fixtureIdentity.identities), `${label}: fixture identity changed`);
  invariant(observation.profile === fixtureIdentity.profile, `${label}: fixture profile mismatch`);
  const startSequence = requireSafeInteger(observation.environment_start_sample_sequence, `${label} start sample`);
  const endSequence = requireSafeInteger(observation.environment_end_sample_sequence, `${label} end sample`);
  invariant(startSequence >= blockSamples.get(spec.blockId) && endSequence >= startSequence,
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
  const blockSamples = validateEnvironment(campaign, expectedBlockIds(expectedSchedule));
  const fingerprints = [];
  const observations = new Map();
  for (let index = 0; index < specs.length; index += 1) {
    const observation = campaign.observations[index];
    invariant(observation.sequence === index, `${label}: observation sequence mismatch at ${index}`);
    fingerprints.push(validateObservation(campaign, observation, specs[index], build, blockSamples));
    observations.set(observation.id, observation);
  }
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
  for (const name of ["runner", "binary", "node", "gnu_time", "taskset", "preflight"]) {
    invariant(left.identities[name].sha256 === right.identities[name].sha256,
      `campaigns differ in ${name} artifact SHA-256`);
  }
  invariant(sameJson(first.fingerprint, second.fingerprint),
    "campaign runtime/host/environment fingerprints differ");
}

function runSelfAudit() {
  const assertions = [];
  const check = (name, callback) => { callback(); assertions.push(name); };
  check("frozen-schedule", () => {
    const schedule = buildSchedule();
    const specs = expectedExecution(schedule);
    invariant(schedule.performance.length === 40 && specs.length === 173 && expectedBlockIds(schedule).length === 77,
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
  console.log(JSON.stringify({
    artifact: `${AUDIT_ARTIFACT}-self-audit`,
    version: VERSION,
    status: "passed",
    assertions,
    expected_observations_per_campaign: 173,
    expected_blocks_per_campaign: 77,
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
      task_cpu_gate_rechecked: true,
      performance_statistics_and_gates_recomputed: true,
      rss_ceiling_and_strict_large_gate_recomputed: true,
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
