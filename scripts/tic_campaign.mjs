#!/usr/bin/env node

// Milestone 6 campaign runner. This file is intentionally self-contained
// and uses only Node's standard library. Run it pinned to CPU 0:
//
//   node scripts/tic_campaign.mjs \
//     --preflight-output=/new/preflight.json --binary=/path/to/tic-bench \
//     --fixture-dir=/path/to/fixtures --commit=<40 hex>
//
//   taskset -c 0 node scripts/tic_campaign.mjs \
//     --campaign-id=1 --output=/new/receipt.json --preflight=/preflight.json \
//     --binary=/path/to/tic-bench --fixture-dir=/path/to/fixtures \
//     --commit=<40 hex>

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {spawn} from "node:child_process";
import {performance} from "node:perf_hooks";

const ARTIFACT = "fused-json-milestone-6-tic-campaign";
const VERSION = 2;
const RUNNER_CPU = "0";
const BENCHMARK_CPU = "3";
const BENCHMARK_SIBLING_CPU = "2";
const GNU_TIME = "/usr/bin/time";
const TASKSET = "/usr/bin/taskset";
const BUFFER_SIZE = 32 * 1024;
const MAX_NESTING = 512;
const SEED = "7";
const MIB = 1024 * 1024;
const GIB = 1024 * MIB;
const SIZES = Object.freeze({
  retained: 64 * MIB,
  throughput: 256 * MIB,
  rss256: 256 * MIB,
  rss1g: GIB,
  rssLarge: 4 * GIB + 64 * MIB,
});
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

class CampaignInvalidError extends Error {}

function usage(exitCode = 64) {
  const message = [
    "usage: scripts/tic_campaign.mjs --preflight-output=/new/file",
    "       --binary=PATH --fixture-dir=DIR --commit=<40 lowercase hex>",
    "       scripts/tic_campaign.mjs --campaign-id=1|2 --output=/new/file",
    "       --preflight=PATH --binary=PATH --fixture-dir=DIR --commit=<40 lowercase hex>",
    "       scripts/tic_campaign.mjs --self-audit",
  ].join("\n");
  console.error(message);
  process.exit(exitCode);
}

function parseArguments(argv) {
  if (argv.length === 1 && argv[0] === "--self-audit") return {selfAudit: true};
  const allowed = new Set([
    "campaign-id", "output", "preflight", "preflight-output", "binary", "fixture-dir", "commit",
  ]);
  const values = {};
  for (const argument of argv) {
    const match = argument.match(/^--([^=]+)=(.*)$/s);
    if (!match || !allowed.has(match[1]) || Object.hasOwn(values, match[1])) usage();
    values[match[1]] = match[2];
  }
  const commonValid = values.binary && values["fixture-dir"] && /^[0-9a-f]{40}$/.test(values.commit ?? "");
  const preflightMode = Boolean(values["preflight-output"]);
  if (preflightMode) {
    if (!commonValid || values["campaign-id"] !== undefined || values.output !== undefined ||
        values.preflight !== undefined) usage();
    return {
      selfAudit: false,
      mode: "preflight",
      output: path.resolve(values["preflight-output"]),
      binary: path.resolve(values.binary),
      fixtureDir: path.resolve(values["fixture-dir"]),
      commit: values.commit,
    };
  }
  if (!commonValid || !/^[12]$/.test(values["campaign-id"] ?? "") ||
      !values.output || !values.preflight || values["preflight-output"] !== undefined) usage();
  return {
    selfAudit: false,
    mode: "campaign",
    campaignId: Number(values["campaign-id"]),
    output: path.resolve(values.output),
    preflight: path.resolve(values.preflight),
    binary: path.resolve(values.binary),
    fixtureDir: path.resolve(values["fixture-dir"]),
    commit: values.commit,
  };
}

function invariant(condition, message) {
  if (!condition) throw new Error(message);
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function nodeRuntimeIdentity() {
  return {
    executable: path.resolve(process.execPath),
    version: process.version,
    versions: Object.fromEntries(Object.entries(process.versions).sort(([left], [right]) =>
      left.localeCompare(right))),
  };
}

function serializeStat(file, {hash = false} = {}) {
  const requestedPath = path.resolve(file);
  const realpath = fs.realpathSync(requestedPath);
  const stat = fs.statSync(realpath, {bigint: true});
  if (!stat.isFile()) throw new Error(`${requestedPath} is not a regular file`);
  const result = {
    path: requestedPath,
    realpath,
    device: stat.dev.toString(),
    inode: stat.ino.toString(),
    bytes: stat.size.toString(),
    mtime_ns: stat.mtimeNs.toString(),
    ctime_ns: stat.ctimeNs.toString(),
  };
  if (hash) result.sha256 = sha256(realpath);
  return result;
}

function sameStat(left, right) {
  return ["realpath", "device", "inode", "bytes", "mtime_ns", "ctime_ns"]
    .every((field) => left[field] === right[field]);
}

function assertIdentityUnchanged(expected, {rehash = false} = {}) {
  const actual = serializeStat(expected.path, {hash: rehash || Object.hasOwn(expected, "sha256")});
  if (!sameStat(expected, actual)) throw new Error(`file identity changed: ${expected.path}`);
  if (Object.hasOwn(expected, "sha256") && expected.sha256 !== actual.sha256) {
    throw new Error(`file hash changed: ${expected.path}`);
  }
  return actual;
}

function fsyncDirectory(directory) {
  try {
    const descriptor = fs.openSync(directory, "r");
    try { fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
  } catch {
    // Some filesystems do not permit directory fsync. File fsync still applies.
  }
}

function writeDurableNew(file, text) {
  const descriptor = fs.openSync(file, "wx", 0o600);
  try {
    fs.writeFileSync(descriptor, text, "utf8");
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fsyncDirectory(path.dirname(file));
}

function writeDurableAtomicReplacement(file, text) {
  const temporary = `${file}.tmp-${process.pid}`;
  if (fs.existsSync(temporary)) throw new Error(`stale atomic-write file: ${temporary}`);
  writeDurableNew(temporary, text);
  fs.renameSync(temporary, file);
  fsyncDirectory(path.dirname(file));
}

function writeDurableAtomicNew(file, text) {
  const temporary = `${file}.tmp-${process.pid}`;
  if (fs.existsSync(file) || fs.existsSync(temporary)) throw new Error(`output already exists: ${file}`);
  writeDurableNew(temporary, text);
  try {
    fs.linkSync(temporary, file);
  } finally {
    fs.unlinkSync(temporary);
  }
  fsyncDirectory(path.dirname(file));
}

function writeAllSync(descriptor, bytes, writer = fs.writeSync) {
  if (!Buffer.isBuffer(bytes)) throw new Error("write-all input must be a Buffer");
  let offset = 0;
  while (offset < bytes.length) {
    const remaining = bytes.length - offset;
    const written = writer(descriptor, bytes, offset, remaining);
    if (!Number.isSafeInteger(written) || written <= 0 || written > remaining) {
      throw new Error(`invalid synchronous write count: ${written}`);
    }
    offset += written;
  }
  return offset;
}

function appendDurableJsonLine(file, value) {
  const descriptor = fs.openSync(file, "a");
  try {
    writeAllSync(descriptor, Buffer.from(`${JSON.stringify(value)}\n`, "utf8"));
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}

function parseJsonFile(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function isLowerSha256(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
}

function requireSafeInteger(value, label, minimum = 0) {
  if (!Number.isSafeInteger(value) || value < minimum) throw new Error(`invalid ${label}: ${value}`);
  return value;
}

function requireFiniteNumber(value, label, {positive = false} = {}) {
  if (typeof value !== "number" || !Number.isFinite(value) || (positive ? value <= 0 : value < 0)) {
    throw new Error(`invalid ${label}: ${value}`);
  }
  return value;
}

function validateManifest(manifest, expected) {
  invariant(manifest?.format === "fused-json-tic-fixture" && manifest.version === 1,
    `${expected.key}: wrong manifest schema`);
  invariant(manifest.profile === expected.profile, `${expected.key}: wrong profile`);
  invariant(manifest.seed === SEED, `${expected.key}: wrong seed`);
  invariant(manifest.requested_bytes === expected.bytes && manifest.decompressed_bytes === expected.bytes,
    `${expected.key}: wrong document size`);
  invariant(isLowerSha256(manifest.document_sha256), `${expected.key}: malformed document SHA-256`);
  invariant(Array.isArray(manifest.root_key_order), `${expected.key}: missing root key order`);
  const providerIndex = manifest.root_key_order.indexOf("provider_references");
  const rateIndex = manifest.root_key_order.indexOf("in_network");
  invariant(providerIndex >= 0 && rateIndex >= 0, `${expected.key}: missing root arrays`);
  if (expected.profile === "many-small") {
    invariant(providerIndex < rateIndex, `${expected.key}: expected providers-first order`);
  } else {
    invariant(rateIndex < providerIndex, `${expected.key}: expected rates-first order`);
  }
  invariant(manifest.boundary_bytes === null || manifest.boundary_bytes === undefined,
    `${expected.key}: unexpected boundary profile`);
  requireSafeInteger(manifest.maximum_nesting, `${expected.key} maximum_nesting`, 1);
  invariant(manifest.maximum_nesting <= MAX_NESTING, `${expected.key}: fixture nesting exceeds campaign limit`);
  for (const field of ["provider_references", "provider_groups", "in_network", "negotiated_rates", "negotiated_prices"]) {
    requireSafeInteger(manifest.counts?.[field], `${expected.key} counts.${field}`);
  }
  invariant(manifest.projection?.format === "fused-json-tic-prices-jsonl" &&
    manifest.projection.version === 1 && manifest.projection.algorithm === "sha256",
  `${expected.key}: wrong projection schema`);
  invariant(manifest.projection.lines === manifest.counts.negotiated_prices,
    `${expected.key}: projection line count mismatch`);
  invariant(isLowerSha256(manifest.projection.sha256), `${expected.key}: malformed projection SHA-256`);
  invariant(manifest.projection.checksum_algorithm === "fnv1a64-fields-v1" &&
    /^0x[0-9a-f]{16}$/.test(manifest.projection.checksum ?? ""),
  `${expected.key}: malformed projection checksum`);
  invariant(manifest.projection.raw_number_checksum_algorithm === "fnv1a64-fields-raw-number-v2" &&
    /^0x[0-9a-f]{16}$/.test(manifest.projection.raw_number_checksum ?? ""),
  `${expected.key}: missing raw-number checksum`);
  if (expected.gzip) {
    invariant(manifest.gzip && Number.isSafeInteger(manifest.gzip.bytes) && manifest.gzip.bytes > 0,
      `${expected.key}: missing gzip metadata`);
    invariant(isLowerSha256(manifest.gzip.sha256), `${expected.key}: malformed gzip SHA-256`);
    invariant(manifest.gzip.level === 6 && manifest.gzip.modification_time === 0 && manifest.gzip.os === 255,
      `${expected.key}: wrong gzip settings`);
  }
}

function loadFixtures(fixtureDir) {
  const definitions = [
    {key: "many-64m", stem: "many-small-64m", profile: "many-small", bytes: SIZES.retained},
    {key: "many-256m", stem: "many-small-256m", profile: "many-small", bytes: SIZES.throughput, gzip: true},
    {key: "many-1g", stem: "many-small-1g", profile: "many-small", bytes: SIZES.rss1g},
    {key: "many-4g-plus", stem: "many-small-4g-plus", profile: "many-small", bytes: SIZES.rssLarge},
    {key: "wide-256m", stem: "wide-item-256m", profile: "wide-item", bytes: SIZES.throughput},
  ];
  const fixtures = {};
  for (const definition of definitions) {
    const input = path.join(fixtureDir, `${definition.stem}.json`);
    const manifestPath = path.join(fixtureDir, `${definition.stem}.meta.json`);
    const gzipInput = definition.gzip ? path.join(fixtureDir, `${definition.stem}.json.gz`) : null;
    const manifest = parseJsonFile(manifestPath);
    validateManifest(manifest, definition);
    const inputIdentity = serializeStat(input);
    invariant(Number(inputIdentity.bytes) === definition.bytes, `${definition.key}: plain input size mismatch`);
    const manifestIdentity = serializeStat(manifestPath, {hash: true});
    let gzipIdentity = null;
    if (gzipInput) {
      gzipIdentity = serializeStat(gzipInput);
      invariant(Number(gzipIdentity.bytes) === manifest.gzip.bytes, `${definition.key}: gzip input size mismatch`);
    }
    fixtures[definition.key] = {
      ...definition,
      input: path.resolve(input),
      manifestPath: path.resolve(manifestPath),
      gzipInput: gzipInput ? path.resolve(gzipInput) : null,
      manifest,
      identities: {input: inputIdentity, manifest: manifestIdentity, gzip: gzipIdentity},
    };
  }
  return fixtures;
}

function fixtureIdentityMap(fixtures) {
  return Object.fromEntries(Object.entries(fixtures).map(([key, fixture]) => [key, {
    profile: fixture.profile,
    bytes: fixture.bytes,
    document_sha256: fixture.manifest.document_sha256,
    projection_sha256: fixture.manifest.projection.sha256,
    projection_checksum: fixture.manifest.projection.checksum,
    raw_number_checksum: fixture.manifest.projection.raw_number_checksum,
    identities: fixture.identities,
  }]));
}

function selfAffinity() {
  const match = fs.readFileSync("/proc/self/status", "utf8").match(/^Cpus_allowed_list:\s*(.+)$/m);
  if (!match) throw new Error("could not read runner CPU affinity");
  return match[1].trim();
}

function cpuSiblingList(cpu) {
  return fs.readFileSync(`/sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list`, "utf8").trim();
}

function cpuListIncludes(list, cpu) {
  for (const part of list.split(",")) {
    const [first, last = first] = part.split("-").map(Number);
    if (Number(cpu) >= first && Number(cpu) <= last) return true;
  }
  return false;
}

function cpuModel() {
  const match = fs.readFileSync("/proc/cpuinfo", "utf8").match(/^(?:model name|Hardware)\s*:\s*(.+)$/m);
  return match?.[1]?.trim() ?? "unknown";
}

function hostIdentity() {
  const benchmarkSiblings = cpuSiblingList(BENCHMARK_CPU);
  invariant(cpuListIncludes(benchmarkSiblings, BENCHMARK_SIBLING_CPU),
    `CPU ${BENCHMARK_SIBLING_CPU} is not a sibling of CPU ${BENCHMARK_CPU}`);
  invariant(!cpuListIncludes(benchmarkSiblings, RUNNER_CPU), "runner CPU overlaps benchmark core");
  return {
    platform: process.platform,
    architecture: process.arch,
    kernel: fs.readFileSync("/proc/version", "utf8").trim(),
    cpu_model: cpuModel(),
    logical_cpu_count: fs.readdirSync("/sys/devices/system/cpu").filter((name) => /^cpu\d+$/.test(name)).length,
    runner_cpu: RUNNER_CPU,
    runner_affinity: selfAffinity(),
    benchmark_cpu: BENCHMARK_CPU,
    benchmark_sibling_cpu: BENCHMARK_SIBLING_CPU,
    benchmark_thread_siblings_list: benchmarkSiblings,
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
  const schedule = [];
  for (let index = 0; index < count; index += 1) {
    schedule.push({
      id: `${prefix}-${String(index).padStart(2, "0")}`,
      index,
      fixture,
      order: index % 2 === 0 ? [modes[0], modes[1]] : [modes[1], modes[0]],
    });
  }
  return schedule;
}

function buildSchedule() {
  return {
    performance: buildPerformanceSchedule(),
    bounded_rss_baselines: Array.from({length: RSS.baselineRunsPerSize * 2}, (_, index) => ({
      id: `rss-baseline-${String(index).padStart(2, "0")}`,
      fixture: index % 2 === 0 ? "many-256m" : "many-1g",
      mode: "fused-typed",
    })),
    bounded_rss_large: Array.from({length: RSS.largeRuns}, (_, index) => ({
      id: `rss-large-${index}`,
      fixture: "many-4g-plus",
      mode: "fused-typed",
    })),
    diagnostics: {
      plain_drains: [
        {id: "diagnostic-plain-drain-many", fixture: "many-256m", mode: "plain-drain"},
        {id: "diagnostic-plain-drain-wide", fixture: "wide-256m", mode: "plain-drain"},
      ],
      gzip_drain_rss: Array.from({length: DIAGNOSTICS.gzipDrainRssRuns}, (_, index) => ({
        id: `diagnostic-gzip-drain-${index}`, fixture: "many-256m", mode: "gzip-drain",
      })),
      gzip_typed_pairs: balancedPairSchedule(
        "diagnostic-gzip-typed", DIAGNOSTICS.gzipTypedPairs, "many-256m",
        ["fused-gzip-typed", "crystal-gzip-typed"]
      ),
      two_pass_pairs: balancedPairSchedule(
        "diagnostic-two-pass", DIAGNOSTICS.twoPassPairs, "many-256m",
        ["fused-two-pass-typed", "crystal-two-pass-typed"]
      ),
      wide_item_rss: Array.from({length: DIAGNOSTICS.wideItemRssRuns}, (_, index) => ({
        id: `diagnostic-wide-rss-${index}`, fixture: "wide-256m", mode: "fused-typed",
      })),
      retained_pairs: balancedPairSchedule(
        "diagnostic-retained", DIAGNOSTICS.retainedPairs, "many-64m",
        ["fused-retained-typed", "crystal-retained-typed"]
      ),
    },
  };
}

function assertBalancedPairs(entries, leftMatcher) {
  invariant(entries.length % 2 === 0, "balanced schedule must contain an even pair count");
  invariant(entries.filter((entry) => leftMatcher(entry.order[0])).length === entries.length / 2,
    "schedule is not balanced by first side");
}

function validateSchedule(schedule) {
  invariant(!Object.hasOwn(schedule, "verifications"), "semantic verification belongs in the shared preflight");
  invariant(schedule.performance.length === PERFORMANCE.pairsPerProfile * 2, "wrong performance schedule length");
  invariant(new Set(schedule.performance.map((entry) => entry.id)).size === schedule.performance.length,
    "duplicate performance schedule ID");
  for (const profile of ["many-small", "wide-item"]) {
    const entries = schedule.performance.filter((entry) => entry.profile === profile);
    invariant(entries.length === PERFORMANCE.pairsPerProfile, `${profile}: wrong pair count`);
    assertBalancedPairs(entries, (value) => value === "fused");
    invariant(entries.filter((entry) => entry.slot === 0).length === entries.length / 2,
      `${profile}: profile is not slot-balanced`);
  }
  for (let round = 0; round < PERFORMANCE.pairsPerProfile; round += 1) {
    const profiles = schedule.performance.filter((entry) => entry.round === round).map((entry) => entry.profile);
    invariant(profiles.length === 2 && new Set(profiles).size === 2, `round ${round} is not profile-interleaved`);
  }
  invariant(schedule.bounded_rss_baselines.length === 10 &&
    schedule.bounded_rss_baselines.filter((entry) => entry.fixture === "many-256m").length === 5 &&
    schedule.bounded_rss_baselines.filter((entry) => entry.fixture === "many-1g").length === 5,
  "wrong bounded RSS baseline schedule");
  invariant(schedule.bounded_rss_large.length === 3, "wrong large RSS schedule");
  const diagnostics = schedule.diagnostics;
  invariant(diagnostics.plain_drains.length === 2, "wrong plain-drain diagnostic count");
  invariant(diagnostics.gzip_drain_rss.length === 3, "wrong gzip-drain RSS diagnostic count");
  invariant(diagnostics.gzip_typed_pairs.length === 6, "wrong gzip typed pair count");
  invariant(diagnostics.two_pass_pairs.length === 6, "wrong two-pass pair count");
  invariant(diagnostics.wide_item_rss.length === 3, "wrong wide RSS count");
  invariant(diagnostics.retained_pairs.length === 4, "wrong retained pair count");
  assertBalancedPairs(diagnostics.gzip_typed_pairs, (mode) => mode.startsWith("fused-"));
  assertBalancedPairs(diagnostics.two_pass_pairs, (mode) => mode.startsWith("fused-"));
  assertBalancedPairs(diagnostics.retained_pairs, (mode) => mode.startsWith("fused-"));
  return schedule;
}

function median(values) {
  invariant(values.length > 0 && values.every((value) => Number.isFinite(value)), "invalid median input");
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
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
  invariant(ratios.length >= PERFORMANCE.pairsPerProfile, "bootstrap requires all 20 process pairs");
  invariant(ratios.every((value) => Number.isFinite(value) && value > 0), "invalid bootstrap ratio");
  const random = mulberry32(PERFORMANCE.bootstrapSeed);
  const estimates = new Array(PERFORMANCE.bootstrapResamples);
  for (let sample = 0; sample < PERFORMANCE.bootstrapResamples; sample += 1) {
    let logSum = 0;
    for (let index = 0; index < ratios.length; index += 1) {
      logSum += Math.log(ratios[Math.floor(random() * ratios.length)]);
    }
    estimates[sample] = Math.exp(logSum / ratios.length);
  }
  estimates.sort((left, right) => left - right);
  return estimates[PERFORMANCE.bootstrapLowerIndex];
}

function rssCeiling(baselinePeakKibibytes) {
  invariant(baselinePeakKibibytes.length === RSS.baselineRunsPerSize * 2,
    "RSS ceiling requires all ten baseline runs");
  invariant(baselinePeakKibibytes.every((value) => Number.isSafeInteger(value) && value > 0),
    "invalid baseline RSS value");
  const maximumKibibytes = Math.max(...baselinePeakKibibytes);
  const headroomKibibytes = Math.max(
    RSS.minimumHeadroomKibibytes,
    Math.ceil(maximumKibibytes * 0.25)
  );
  const ceilingKibibytes = maximumKibibytes + headroomKibibytes;
  return {
    maximum_baseline_kibibytes: maximumKibibytes,
    headroom_kibibytes: headroomKibibytes,
    ceiling_kibibytes: ceilingKibibytes,
    maximum_baseline_bytes: maximumKibibytes * 1024,
    headroom_bytes: headroomKibibytes * 1024,
    ceiling_bytes: ceilingKibibytes * 1024,
  };
}

function parseCpuCounterLine(text, cpu) {
  const match = text.match(new RegExp(`^(cpu${cpu}\\s+(.+))$`, "m"));
  if (!match) throw new Error(`missing CPU ${cpu} counters`);
  const counters = match[2].trim().split(/\s+/).map((value) => BigInt(value));
  if (counters.length < 5) throw new Error(`short CPU ${cpu} counters`);
  // guest and guest_nice are already included in user and nice respectively.
  const total = counters.slice(0, 8).reduce((sum, value) => sum + value, 0n);
  const idle = counters[3] + (counters[4] ?? 0n);
  return {rawLine: match[1], counters, total, idle};
}

function parseCpuCounters(text, cpu) {
  const {total, idle} = parseCpuCounterLine(text, cpu);
  return {total, idle};
}

function cpuBusyPercent(previous, current) {
  if (!previous) return null;
  const total = current.total - previous.total;
  const idle = current.idle - previous.idle;
  if (total <= 0n || idle < 0n || idle > total) throw new Error("CPU counters moved backwards or did not advance");
  return Number(total - idle) / Number(total) * 100;
}

function parseTctlInput(text) {
  const rawMillidegrees = typeof text === "string" ? text.trim() : "";
  if (!/^(?:0|[1-9]\d*)$/.test(rawMillidegrees)) {
    throw new Error("Tctl input is not a nonempty unsigned decimal integer");
  }
  const millidegrees = Number(rawMillidegrees);
  if (!Number.isSafeInteger(millidegrees)) throw new Error("Tctl input exceeds the safe integer range");
  return {rawMillidegrees, celsius: millidegrees / 1000};
}

function readChildBoundary(tctlPath) {
  const observedAt = new Date().toISOString();
  const monotonicMs = performance.now();
  const cpu = parseCpuCounterLine(fs.readFileSync("/proc/stat", "utf8"), BENCHMARK_SIBLING_CPU);
  const tctl = parseTctlInput(fs.readFileSync(tctlPath, "utf8"));
  return {
    observed_at: observedAt,
    monotonic_ms: monotonicMs,
    proc_stat_cpu_line: cpu.rawLine,
    counters: cpu.counters.map((value) => value.toString()),
    total_ticks: cpu.total.toString(),
    idle_ticks: cpu.idle.toString(),
    tctl_raw_millicelsius: tctl.rawMillidegrees,
    tctl_c: tctl.celsius,
  };
}

function childEnvironmentWindow(before, after) {
  const beforeCounters = {total: BigInt(before.total_ticks), idle: BigInt(before.idle_ticks)};
  const afterCounters = {total: BigInt(after.total_ticks), idle: BigInt(after.idle_ticks)};
  const deltaTotal = afterCounters.total - beforeCounters.total;
  const deltaIdle = afterCounters.idle - beforeCounters.idle;
  if (deltaTotal <= 0n || deltaIdle < 0n || deltaIdle > deltaTotal) {
    throw new Error("child-window CPU counters moved backwards or did not advance");
  }
  const deltaBusy = deltaTotal - deltaIdle;
  const busyPercent = Number(deltaBusy) / Number(deltaTotal) * 100;
  return {
    cpu: BENCHMARK_SIBLING_CPU,
    maximum_busy_percent: ENVIRONMENT_POLICY.childWindowSiblingBusyMaximumPercent,
    before,
    after,
    delta_total_ticks: deltaTotal.toString(),
    delta_idle_ticks: deltaIdle.toString(),
    delta_busy_ticks: deltaBusy.toString(),
    cpu_busy_percent: busyPercent,
    within_busy_limit: busyPercent <= ENVIRONMENT_POLICY.childWindowSiblingBusyMaximumPercent,
  };
}

function resolveTctlPath() {
  const root = "/sys/class/hwmon";
  for (const hwmon of fs.readdirSync(root).sort()) {
    const directory = path.join(root, hwmon);
    for (const entry of fs.readdirSync(directory).sort()) {
      if (!/^temp\d+_label$/.test(entry)) continue;
      const labelPath = path.join(directory, entry);
      if (fs.readFileSync(labelPath, "utf8").trim() !== "Tctl") continue;
      const input = labelPath.replace(/_label$/, "_input");
      if (fs.existsSync(input)) return fs.realpathSync(input);
    }
  }
  throw new Error("could not resolve Tctl input");
}

function environmentInvalidation(policyState, sample) {
  if (sample.read_errors.length) return {kind: "environment_read_failure", detail: sample.read_errors.join("; ")};
  if (sample.gap_seconds !== null && sample.gap_seconds > ENVIRONMENT_POLICY.maximumMonitorGapSeconds) {
    return {kind: "monitor_gap", detail: `${sample.gap_seconds.toFixed(3)} seconds`};
  }
  if (sample.tctl_c >= ENVIRONMENT_POLICY.invalidTctlMinimumC) {
    return {kind: "temperature", detail: `Tctl ${sample.tctl_c} C`};
  }
  policyState.loadBreaches = sample.load1 > ENVIRONMENT_POLICY.invalidLoad1StrictlyGreaterThan
    ? policyState.loadBreaches + 1 : 0;
  policyState.siblingBreaches = sample.cpu2_busy_percent !== null &&
    sample.cpu2_busy_percent > ENVIRONMENT_POLICY.invalidSiblingBusyStrictlyGreaterThanPercent
    ? policyState.siblingBreaches + 1 : 0;
  if (policyState.loadBreaches >= ENVIRONMENT_POLICY.consecutiveBreachSamples) {
    return {kind: "load", detail: `load1 exceeded ${ENVIRONMENT_POLICY.invalidLoad1StrictlyGreaterThan} for ` +
      `${policyState.loadBreaches} consecutive samples`};
  }
  if (policyState.siblingBreaches >= ENVIRONMENT_POLICY.consecutiveBreachSamples) {
    return {kind: "sibling_cpu",
      detail: `CPU ${BENCHMARK_SIBLING_CPU} exceeded ` +
        `${ENVIRONMENT_POLICY.invalidSiblingBusyStrictlyGreaterThanPercent}% for ` +
        `${policyState.siblingBreaches} consecutive samples`};
  }
  return null;
}

function gateSampleAcceptable(sample) {
  return sample.cpu2_busy_percent !== null && sample.cpu3_busy_percent !== null &&
    sample.load1 <= ENVIRONMENT_POLICY.gateLoad1Maximum &&
    sample.load5 <= ENVIRONMENT_POLICY.gateLoad5Maximum &&
    sample.tctl_c <= ENVIRONMENT_POLICY.gateTctlMaximumC &&
    sample.cpu2_busy_percent <= ENVIRONMENT_POLICY.gateSiblingCpuBusyMaximumPercent &&
    sample.cpu3_busy_percent <= ENVIRONMENT_POLICY.gateBenchmarkCpuBusyMaximumPercent;
}

function advanceGateWindow(window, sample) {
  if (!gateSampleAcceptable(sample)) return null;
  if (window === null) {
    return {samples: [sample], minimumTctlC: sample.tctl_c, maximumTctlC: sample.tctl_c};
  }
  const minimumTctlC = Math.min(window.minimumTctlC, sample.tctl_c);
  const maximumTctlC = Math.max(window.maximumTctlC, sample.tctl_c);
  if (maximumTctlC - minimumTctlC > ENVIRONMENT_POLICY.gateTctlRangeMaximumC) {
    return {samples: [sample], minimumTctlC: sample.tctl_c, maximumTctlC: sample.tctl_c};
  }
  return {samples: [...window.samples, sample], minimumTctlC, maximumTctlC};
}

function admittedGate(window, requiredSeconds, label) {
  if (window === null) return null;
  const first = window.samples[0];
  const last = window.samples.at(-1);
  const durationSeconds = (last.monotonic_ms - first.monotonic_ms) / 1000;
  const minimumSampleCount = Math.ceil(requiredSeconds / (ENVIRONMENT_POLICY.sampleIntervalMs / 1000)) + 1;
  if (durationSeconds < requiredSeconds || window.samples.length < minimumSampleCount) return null;
  return {
    label,
    required_continuous_seconds: requiredSeconds,
    first_sample_sequence: first.sequence,
    admitted_sample_sequence: last.sequence,
    sample_sequences: window.samples.map((sample) => sample.sequence),
    sample_count: window.samples.length,
    duration_seconds: durationSeconds,
    tctl_min_c: window.minimumTctlC,
    tctl_max_c: window.maximumTctlC,
    tctl_range_c: window.maximumTctlC - window.minimumTctlC,
  };
}

function blockGateDeadlineExceeded(sample, evaluatedMonotonicMs, deadlineMonotonicMs) {
  return sample.monotonic_ms > evaluatedMonotonicMs ||
    sample.monotonic_ms > deadlineMonotonicMs || evaluatedMonotonicMs > deadlineMonotonicMs;
}

function admittedBlockGate(window, label, waitStartedMonotonicMs, deadlineMonotonicMs,
  admittedEvaluatedMonotonicMs) {
  const gate = admittedGate(window, ENVIRONMENT_POLICY.blockAdmissionSeconds, label);
  if (gate === null || blockGateDeadlineExceeded(
    window.samples.at(-1), admittedEvaluatedMonotonicMs, deadlineMonotonicMs
  )) return null;
  return {
    ...gate,
    wait_started_monotonic_ms: waitStartedMonotonicMs,
    deadline_monotonic_ms: deadlineMonotonicMs,
    admitted_evaluated_monotonic_ms: admittedEvaluatedMonotonicMs,
  };
}

class EnvironmentMonitor {
  constructor({environmentJournal, onInvalid, tctlPath}) {
    this.environmentJournal = environmentJournal;
    this.onInvalid = onInvalid;
    this.tctlPath = tctlPath;
    this.frequencyPath = `/sys/devices/system/cpu/cpu${BENCHMARK_CPU}/cpufreq/scaling_cur_freq`;
    this.samples = [];
    this.previousCpu = {};
    this.previousMonotonicMs = null;
    this.policyState = {loadBreaches: 0, siblingBreaches: 0};
    this.invalidReason = null;
    this.waiters = [];
    this.timer = null;
  }

  start() {
    this.takeSample("monitor-start");
    this.timer = setInterval(() => this.takeSample("monitor"), ENVIRONMENT_POLICY.sampleIntervalMs);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    for (const waiter of this.waiters.splice(0)) waiter.reject(new Error("environment monitor stopped"));
  }

  setInvalid(reason) {
    if (this.invalidReason) return;
    this.invalidReason = {...reason, observed_at: new Date().toISOString(), sample_sequence: this.samples.at(-1)?.sequence};
    this.onInvalid(this.invalidReason);
  }

  invalidateAndWake(reason) {
    this.setInvalid(reason);
    const error = new CampaignInvalidError(`${reason.kind}: ${reason.detail}`);
    for (const waiter of this.waiters.splice(0)) waiter.reject(error);
  }

  takeSample(label) {
    const now = performance.now();
    const sample = {
      sequence: this.samples.length,
      label,
      observed_at: new Date().toISOString(),
      monotonic_ms: now,
      gap_seconds: this.previousMonotonicMs === null ? null : (now - this.previousMonotonicMs) / 1000,
      load1: null,
      load5: null,
      tctl_c: null,
      cpu2_busy_percent: null,
      cpu3_busy_percent: null,
      cpu3_scaling_cur_freq_khz: null,
      cpu3_frequency_error: null,
      read_errors: [],
    };
    this.previousMonotonicMs = now;
    try {
      const fields = fs.readFileSync("/proc/loadavg", "utf8").trim().split(/\s+/);
      sample.load1 = Number(fields[0]);
      sample.load5 = Number(fields[1]);
      if (!Number.isFinite(sample.load1) || !Number.isFinite(sample.load5)) throw new Error("nonfinite load average");
    } catch (error) { sample.read_errors.push(`loadavg: ${error.message}`); }
    try {
      sample.tctl_c = parseTctlInput(fs.readFileSync(this.tctlPath, "utf8")).celsius;
    } catch (error) { sample.read_errors.push(`Tctl: ${error.message}`); }
    try {
      const procStat = fs.readFileSync("/proc/stat", "utf8");
      for (const cpu of [BENCHMARK_SIBLING_CPU, BENCHMARK_CPU]) {
        const current = parseCpuCounters(procStat, cpu);
        const busy = cpuBusyPercent(this.previousCpu[cpu], current);
        this.previousCpu[cpu] = current;
        sample[`cpu${cpu}_busy_percent`] = busy;
      }
    } catch (error) { sample.read_errors.push(`CPU counters: ${error.message}`); }
    try {
      const value = Number(fs.readFileSync(this.frequencyPath, "utf8").trim());
      if (!Number.isFinite(value) || value <= 0) throw new Error("invalid scaling_cur_freq");
      sample.cpu3_scaling_cur_freq_khz = value;
    } catch (error) {
      sample.cpu3_frequency_error = error.message;
    }
    this.samples.push(sample);
    appendDurableJsonLine(this.environmentJournal, sample);
    const invalid = environmentInvalidation(this.policyState, sample);
    if (invalid) this.setInvalid(invalid);
    for (const waiter of this.waiters.splice(0)) {
      if (sample.sequence > waiter.afterSequence) waiter.resolve(sample);
      else this.waiters.push(waiter);
    }
  }

  waitForSampleAfter(afterSequence) {
    const existing = this.samples.find((sample) => sample.sequence > afterSequence);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const waiter = {afterSequence, resolve, reject};
      this.waiters.push(waiter);
      const timeout = setTimeout(() => {
        const index = this.waiters.indexOf(waiter);
        if (index >= 0) this.waiters.splice(index, 1);
        const reason = {kind: "monitor_timeout",
          detail: `no environment sample arrived within ${ENVIRONMENT_POLICY.maximumMonitorGapSeconds} seconds`};
        this.setInvalid(reason);
        reject(new CampaignInvalidError(reason.detail));
      }, (ENVIRONMENT_POLICY.maximumMonitorGapSeconds * 1000) + 250);
      waiter.resolve = (sample) => { clearTimeout(timeout); resolve(sample); };
      waiter.reject = (error) => { clearTimeout(timeout); reject(error); };
    });
  }

  assertValid() {
    if (this.invalidReason) throw new CampaignInvalidError(`${this.invalidReason.kind}: ${this.invalidReason.detail}`);
  }

  async awaitAdmission() {
    this.assertValid();
    let sequence = this.samples.at(-1).sequence;
    let window = null;
    while (true) {
      const sample = await this.waitForSampleAfter(sequence);
      sequence = sample.sequence;
      this.assertValid();
      window = advanceGateWindow(window, sample);
      const admitted = admittedGate(window, ENVIRONMENT_POLICY.initialAdmissionSeconds,
        "campaign-initial-admission");
      if (admitted) return admitted;
    }
  }

  async awaitBlockStart(label) {
    const started = performance.now();
    const deadline = started + (ENVIRONMENT_POLICY.blockGateDeadlineSeconds * 1000);
    this.assertValid();
    let sequence = this.samples.at(-1).sequence;
    let window = null;
    while (true) {
      const sample = await this.waitForSampleAfter(sequence);
      sequence = sample.sequence;
      this.assertValid();
      const evaluated = performance.now();
      if (blockGateDeadlineExceeded(sample, evaluated, deadline)) {
        const reason = {kind: "block_gate_timeout",
          detail: `${label} did not sustain the ${ENVIRONMENT_POLICY.name} limits for ` +
            `${ENVIRONMENT_POLICY.blockAdmissionSeconds} seconds within ` +
            `${ENVIRONMENT_POLICY.blockGateDeadlineSeconds} seconds`,
          wait_started_monotonic_ms: started,
          deadline_monotonic_ms: deadline,
          sample_monotonic_ms: sample.monotonic_ms,
          evaluated_monotonic_ms: evaluated};
        this.setInvalid(reason);
        throw new CampaignInvalidError(reason.detail);
      }
      window = advanceGateWindow(window, sample);
      const admitted = admittedBlockGate(window, label, started, deadline, evaluated);
      if (admitted) return admitted;
    }
  }
}

function parseGnuTime(raw) {
  const fields = {};
  const patterns = {
    user_cpu_seconds: /^\s*User time \(seconds\):\s*(\S+)\s*$/m,
    system_cpu_seconds: /^\s*System time \(seconds\):\s*(\S+)\s*$/m,
    elapsed_wall: /^\s*Elapsed \(wall clock\) time \(h:mm:ss or m:ss\):\s*(\S+)\s*$/m,
    cpu_percent: /^\s*Percent of CPU this job got:\s*(\d+)%\s*$/m,
    maximum_resident_kibibytes: /^\s*Maximum resident set size \(kbytes\):\s*(\d+)\s*$/m,
    major_page_faults: /^\s*Major \(requiring I\/O\) page faults:\s*(\d+)\s*$/m,
    minor_page_faults: /^\s*Minor \(reclaiming a frame\) page faults:\s*(\d+)\s*$/m,
    voluntary_context_switches: /^\s*Voluntary context switches:\s*(\d+)\s*$/m,
    involuntary_context_switches: /^\s*Involuntary context switches:\s*(\d+)\s*$/m,
    filesystem_inputs: /^\s*File system inputs:\s*(\d+)\s*$/m,
    filesystem_outputs: /^\s*File system outputs:\s*(\d+)\s*$/m,
    exit_status: /^\s*Exit status:\s*(\d+)\s*$/m,
  };
  for (const [name, pattern] of Object.entries(patterns)) {
    const matches = [...raw.matchAll(new RegExp(pattern.source, pattern.flags.includes("g") ? pattern.flags : `${pattern.flags}g`))];
    if (matches.length !== 1) throw new Error(`GNU time field ${name} occurred ${matches.length} times`);
    fields[name] = matches[0][1];
  }
  const decimalFields = ["user_cpu_seconds", "system_cpu_seconds"];
  for (const name of decimalFields) fields[name] = requireFiniteNumber(Number(fields[name]), `GNU time ${name}`);
  for (const name of ["cpu_percent", "maximum_resident_kibibytes", "major_page_faults", "minor_page_faults",
    "voluntary_context_switches", "involuntary_context_switches", "filesystem_inputs", "filesystem_outputs", "exit_status"]) {
    fields[name] = requireSafeInteger(Number(fields[name]), `GNU time ${name}`);
  }
  invariant(fields.cpu_percent <= 100, "GNU time CPU percentage exceeds one pinned CPU");
  invariant(fields.maximum_resident_kibibytes > 0, "GNU time peak RSS is zero");
  fields.maximum_resident_bytes = fields.maximum_resident_kibibytes * 1024;
  return fields;
}

function parseSingleJson(raw, label) {
  const trimmed = raw.trim();
  if (!trimmed) throw new Error(`${label}: empty stdout`);
  try {
    const parsed = JSON.parse(trimmed);
    invariant(parsed && typeof parsed === "object" && !Array.isArray(parsed), `${label}: stdout is not one JSON object`);
    return parsed;
  } catch (error) {
    throw new Error(`${label}: malformed JSON stdout: ${error.message}`);
  }
}

function expectedArguments(command, fixture, mode, commit) {
  const arguments_ = [
    command,
    `--input=${fixture.input}`,
    `--manifest=${fixture.manifestPath}`,
  ];
  if ((command === "verify" && fixture.gzipInput) ||
      (mode && (mode === "gzip-drain" || mode.includes("gzip")))) {
    arguments_.push(`--gzip-input=${fixture.gzipInput}`);
  }
  if (mode) arguments_.push(`--mode=${mode}`);
  arguments_.push(`--buffer-size=${BUFFER_SIZE}`, `--max-nesting=${MAX_NESTING}`);
  if (command !== "verify") arguments_.push(`--commit=${commit}`);
  return arguments_;
}

function sameJson(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function validateCounts(actual, expected, label) {
  for (const field of ["provider_references", "provider_groups", "in_network", "negotiated_rates", "negotiated_prices"]) {
    invariant(actual?.[field] === expected[field], `${label}: count mismatch for ${field}`);
  }
}

function validateVerificationReceipt(receipt, fixture, expectedArgs) {
  const fail = (message) => { throw new Error(`verification ${fixture.key}: ${message}`); };
  if (receipt.receipt !== "fused-json-tic-verification" || receipt.version !== 1 ||
      receipt.command !== "verify" || receipt.status !== "verified") fail("wrong receipt schema/status");
  if (receipt.profile !== fixture.profile || receipt.seed !== SEED ||
      !sameJson(receipt.root_key_order, fixture.manifest.root_key_order) || receipt.boundary_bytes !== null) {
    fail("wrong fixture identity");
  }
  if (receipt.input !== fixture.input || receipt.manifest !== fixture.manifestPath) fail("wrong paths");
  if (receipt.manifest_sha256 !== fixture.identities.manifest.sha256) fail("wrong manifest hash");
  if (receipt.document_bytes !== fixture.bytes || receipt.document_sha256 !== fixture.manifest.document_sha256) fail("wrong document identity");
  if (receipt.projection_sha256 !== fixture.manifest.projection.sha256 ||
      receipt.projection_checksum !== fixture.manifest.projection.checksum) fail("wrong projection identity");
  if (receipt.typed_verified !== true || receipt.typed_provider_checksum_algorithm !== "fnv1a64-provider-fields-v1" ||
      !/^0x[0-9a-f]{16}$/.test(receipt.typed_provider_checksum ?? "")) fail("typed verification missing");
  if (receipt.typed_provider_records !== fixture.manifest.counts.provider_references ||
      receipt.typed_price_records !== fixture.manifest.counts.negotiated_prices ||
      receipt.typed_scalar_values !== fixture.manifest.counts.negotiated_rates) fail("wrong typed counts");
  if (receipt.raw_number_verified !== true ||
      receipt.raw_number_checksum_algorithm !== fixture.manifest.projection.raw_number_checksum_algorithm ||
      receipt.raw_number_checksum !== fixture.manifest.projection.raw_number_checksum) fail("raw-number verification missing");
  if (receipt.gzip_verified !== Boolean(fixture.gzipInput)) fail("wrong gzip verification status");
  if (receipt.buffer_size !== BUFFER_SIZE || receipt.max_nesting !== MAX_NESTING) fail("wrong parser settings");
  validateCounts(receipt.counts, fixture.manifest.counts, `verification ${fixture.key}`);
  // Verification v1 does not expose ARGV. The exact expected command remains in
  // the outer observation and is hash-bound to this receipt.
  invariant(expectedArgs[0] === "verify", "internal verification argument mismatch");
  return {
    projection_checksum: receipt.projection_checksum,
    provider_checksum: receipt.typed_provider_checksum,
    raw_number_checksum: receipt.raw_number_checksum,
  };
}

function validatePreflightReceipt(preflight, {commit, fixtures, identities}) {
  invariant(preflight?.artifact === "fused-json-m6-tic-preflight" && preflight.version === 1,
    "wrong semantic-preflight schema");
  invariant(preflight.status === "complete" && preflight.valid === true,
    "semantic preflight is not complete and valid");
  invariant(preflight.commit === commit, "semantic-preflight commit attestation mismatch");
  invariant(preflight.definition?.buffer_size === BUFFER_SIZE &&
    preflight.definition?.max_nesting === MAX_NESTING && preflight.definition?.seed === SEED,
  "semantic-preflight parser settings mismatch");
  invariant(sameJson(preflight.runner_runtime, nodeRuntimeIdentity()),
    "semantic-preflight Node runtime mismatch");
  for (const name of ["runner", "binary", "node"]) {
    invariant(preflight.identities?.[name]?.sha256 === identities[name].sha256,
      `semantic-preflight ${name} hash mismatch`);
  }
  const currentFixtureIdentities = fixtureIdentityMap(fixtures);
  invariant(sameJson(preflight.fixture_identities, currentFixtureIdentities),
    "semantic-preflight fixture identities do not match current files");
  const fixtureKeys = Object.keys(fixtures);
  invariant(Array.isArray(preflight.verifications) && preflight.verifications.length === fixtureKeys.length,
    "semantic-preflight verification set is incomplete");
  const seen = new Set();
  const semanticReferences = {};
  for (const observation of preflight.verifications) {
    invariant(typeof observation?.fixture === "string" && fixtures[observation.fixture],
      "semantic-preflight contains an unknown fixture");
    invariant(!seen.has(observation.fixture), `duplicate semantic-preflight fixture ${observation.fixture}`);
    seen.add(observation.fixture);
    const fixture = fixtures[observation.fixture];
    const expectedArgs = expectedArguments("verify", fixture, null, commit);
    invariant(observation.valid === true && observation.exit_code === 0 && observation.signal === null &&
      observation.spawn_error === null && observation.validation_error === null,
    `semantic-preflight ${observation.fixture} is invalid`);
    invariant(sameJson(observation.arguments, expectedArgs),
      `semantic-preflight ${observation.fixture} argument mismatch`);
    invariant(typeof observation.stdout === "string" && typeof observation.stderr === "string",
      `semantic-preflight ${observation.fixture} did not retain child output`);
    invariant(sameJson(parseSingleJson(observation.stdout, `preflight ${observation.fixture}`), observation.receipt),
      `semantic-preflight ${observation.fixture} stdout/receipt mismatch`);
    semanticReferences[observation.fixture] = validateVerificationReceipt(
      observation.receipt, fixture, expectedArgs
    );
    invariant(sameJson(observation.fixture_before, currentFixtureIdentities[observation.fixture].identities) &&
      sameJson(observation.fixture_after, currentFixtureIdentities[observation.fixture].identities),
    `semantic-preflight ${observation.fixture} file identity mismatch`);
  }
  invariant(fixtureKeys.every((key) => seen.has(key)), "semantic-preflight is missing a fixture");
  return semanticReferences;
}

function modeProperties(mode) {
  const gzip = mode === "gzip-drain" || mode.includes("gzip");
  const drain = mode.endsWith("-drain");
  const parser = mode.startsWith("fused-") ? "FusedJSON" :
    mode.startsWith("crystal-") ? "Crystal JSON::PullParser" : null;
  const twoPass = mode.includes("two-pass");
  const retained = mode.includes("retained");
  const typed = !drain && (mode.includes("typed") || retained);
  return {gzip, drain, parser, twoPass, retained, typed};
}

function validateMeasurementReceipt(receipt, context) {
  const {fixture, mode, command, expectedArgs, commit, semanticReference} = context;
  const fail = (message) => { throw new Error(`${mode}/${fixture.key}: ${message}`); };
  const properties = modeProperties(mode);
  if (receipt.receipt !== "fused-json-tic-measurement" || receipt.version !== 1 ||
      receipt.command !== command || receipt.mode !== mode) fail("wrong receipt schema/mode");
  if (!sameJson(receipt.arguments, expectedArgs)) fail("arguments do not match command");
  if (receipt.profile !== fixture.profile || receipt.seed !== SEED ||
      !sameJson(receipt.root_key_order, fixture.manifest.root_key_order)) fail("wrong fixture identity");
  const expectedInput = properties.gzip ? fixture.gzipInput : fixture.input;
  if (receipt.input !== expectedInput || receipt.manifest !== fixture.manifestPath ||
      receipt.manifest_sha256 !== fixture.identities.manifest.sha256) fail("wrong path or manifest identity");
  if (receipt.expected_document_sha256 !== fixture.manifest.document_sha256 ||
      receipt.expected_projection_sha256 !== fixture.manifest.projection.sha256 ||
      receipt.expected_projection_checksum !== fixture.manifest.projection.checksum) fail("wrong expected semantics");
  const inputPasses = properties.twoPass ? 2 : 1;
  if (receipt.logical_document_bytes !== fixture.bytes || receipt.input_passes !== inputPasses ||
      receipt.processed_bytes !== fixture.bytes * inputPasses) fail("wrong byte accounting");
  const expectedCompressed = properties.gzip ? fixture.manifest.gzip.bytes : null;
  if (receipt.compressed_ingress_bytes !== expectedCompressed) fail("wrong compressed byte accounting");
  const wall = requireFiniteNumber(receipt.timing?.wall_seconds, `${mode} wall time`, {positive: true});
  requireFiniteNumber(receipt.decompressed_mib_per_second, `${mode} throughput`, {positive: true});
  const recomputed = (receipt.processed_bytes / MIB) / wall;
  if (Math.abs(recomputed / receipt.decompressed_mib_per_second - 1) > 1e-10) fail("throughput does not match bytes/wall");
  if (properties.drain) {
    if (receipt.counts !== null || receipt.projection_checksum !== null ||
        receipt.projected_prices_per_second !== null || !/^0x[0-9a-f]{16}$/.test(receipt.drain_observer ?? "")) {
      fail("malformed drain semantics");
    }
  } else {
    validateCounts(receipt.counts, fixture.manifest.counts, `${mode}/${fixture.key}`);
    if (receipt.projection_sha256 !== null || receipt.projection_checksum !== semanticReference.projection_checksum) {
      fail("timed projection mismatch");
    }
    if (receipt.typed_provider_checksum !== semanticReference.provider_checksum ||
        receipt.typed_provider_records !== fixture.manifest.counts.provider_references ||
        receipt.typed_price_records !== fixture.manifest.counts.negotiated_prices ||
        receipt.typed_scalar_values !== fixture.manifest.counts.negotiated_rates) fail("typed semantic mismatch");
    requireFiniteNumber(receipt.projected_prices_per_second, `${mode} item rate`, {positive: true});
    requireFiniteNumber(receipt.first_projected_price_seconds, `${mode} first-price latency`);
  }
  if (properties.retained) {
    const retained = receipt.retained_output;
    if (receipt.configuration?.retained_output_policy !== RETENTION_POLICY ||
        retained?.policy !== RETENTION_POLICY ||
        retained.provider_records !== fixture.manifest.counts.provider_references ||
        retained.scalar_values !== fixture.manifest.counts.negotiated_rates ||
        retained.price_records !== fixture.manifest.counts.negotiated_prices ||
        retained.total_values !== retained.provider_records + retained.scalar_values + retained.price_records) {
      fail("retained-output policy/count mismatch");
    }
  } else if (receipt.configuration?.retained_output_policy !== "none" || receipt.retained_output !== null) {
    fail("unexpected retained-output metadata");
  }
  if (receipt.configuration?.buffer_size !== BUFFER_SIZE ||
      receipt.configuration?.max_nesting !== MAX_NESTING ||
      receipt.configuration?.parser !== properties.parser ||
      receipt.configuration?.transport !== (properties.gzip ? "gzip" : "plain") ||
      receipt.configuration?.workload !== (properties.drain ? "drain" : properties.retained ? "typed-retained" :
        properties.twoPass ? "typed-two-pass" : "typed") ||
      receipt.configuration?.fused_cache_keys !== false ||
      receipt.configuration?.fused_reject_duplicate_keys !== false) fail("wrong parser configuration");
  if (receipt.runtime?.fused_json_commit !== commit || receipt.runtime?.release_build !== true ||
      typeof receipt.runtime?.crystal_version !== "string" || typeof receipt.runtime?.llvm_version !== "string" ||
      typeof receipt.runtime?.target !== "string" || typeof receipt.runtime?.zlib_version !== "string") fail("wrong runtime identity");
  if (receipt.host?.cpu_affinity !== BENCHMARK_CPU) fail("wrong benchmark affinity");
  for (const [name, value] of Object.entries(CHILD_ENVIRONMENT)) {
    if (["GC_NPROCS", "GC_MARKERS", "CRYSTAL_WORKERS", "OMP_NUM_THREADS"].includes(name) &&
        receipt.environment?.[name] !== value) fail(`wrong environment ${name}`);
  }
  requireFiniteNumber(receipt.managed_memory?.allocated_bytes, `${mode} allocated bytes`);
  return receipt;
}

function receiptFingerprint(receipt) {
  return {
    runtime: receipt.runtime,
    host: {
      os: receipt.host.os,
      cpu_model: receipt.host.cpu_model,
      cpu_count: receipt.host.cpu_count,
      cpu_affinity: receipt.host.cpu_affinity,
    },
    environment: receipt.environment,
  };
}

function assertFixtureStable(fixture) {
  assertIdentityUnchanged(fixture.identities.input);
  assertIdentityUnchanged(fixture.identities.manifest, {rehash: true});
  if (fixture.identities.gzip) assertIdentityUnchanged(fixture.identities.gzip);
}

function spawnCaptured(command, arguments_, options) {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let spawnError = null;
    const child = spawn(command, arguments_, options);
    options.onSpawn?.(child);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => { spawnError = error; });
    child.on("close", (code, signal) => resolve({stdout, stderr, code, signal, spawnError}));
  });
}

function snapshotFixtureIdentities(fixture) {
  return {
    input: serializeStat(fixture.input),
    manifest: serializeStat(fixture.manifestPath, {hash: true}),
    gzip: fixture.gzipInput ? serializeStat(fixture.gzipInput) : null,
  };
}

class SemanticPreflight {
  constructor(options) {
    this.options = options;
    this.paths = {
      final: options.output,
      partial: `${options.output}.partial.json`,
      journal: `${options.output}.journal.jsonl`,
    };
    for (const file of Object.values(this.paths)) {
      if (fs.existsSync(file)) throw new Error(`preflight output already exists: ${file}`);
    }
    const parent = path.dirname(options.output);
    if (!fs.statSync(parent).isDirectory()) throw new Error(`output parent is not a directory: ${parent}`);
    this.fixtures = loadFixtures(options.fixtureDir);
    this.identities = {
      runner: serializeStat(process.argv[1], {hash: true}),
      binary: serializeStat(options.binary, {hash: true}),
      node: serializeStat(process.execPath, {hash: true}),
    };
    this.currentChild = null;
    this.interruption = null;
    this.finalized = false;
    this.state = {
      artifact: "fused-json-m6-tic-preflight",
      version: 1,
      status: "prepared",
      valid: null,
      started_at: new Date().toISOString(),
      completed_at: null,
      commit: options.commit,
      commit_binding: "caller attestation; the recorded benchmark binary SHA-256 is authoritative",
      definition: {
        purpose: "shared untimed semantic preflight outside controlled performance campaigns",
        buffer_size: BUFFER_SIZE,
        max_nesting: MAX_NESTING,
        seed: SEED,
        fixture_order: Object.keys(this.fixtures),
        environment_monitor: "not used; preflight is correctness evidence, not performance evidence",
        task_cpu_gate: "not applied",
      },
      paths: this.paths,
      identities: this.identities,
      runner_runtime: nodeRuntimeIdentity(),
      fixture_identities: fixtureIdentityMap(this.fixtures),
      child_environment: CHILD_ENVIRONMENT,
      verifications: [],
      errors: [],
      interruption: null,
      completion: null,
    };
    writeDurableNew(this.paths.journal, `${JSON.stringify({
      event: "preflight-predeclared", at: new Date().toISOString(),
      definition: this.state.definition, identities: this.identities,
      fixture_identities: this.state.fixture_identities,
    })}\n`);
    this.persist();
  }

  persist() {
    writeDurableAtomicReplacement(this.paths.partial, `${JSON.stringify(this.state, null, 2)}\n`);
  }

  event(event, details = {}) {
    appendDurableJsonLine(this.paths.journal, {event, at: new Date().toISOString(), ...details});
  }

  async runVerification(fixtureKey) {
    const fixture = this.fixtures[fixtureKey];
    const arguments_ = expectedArguments("verify", fixture, null, this.options.commit);
    const fixtureBefore = snapshotFixtureIdentities(fixture);
    const startedAt = new Date().toISOString();
    const result = await spawnCaptured(this.options.binary, arguments_, {
      env: {...CHILD_ENVIRONMENT},
      cwd: this.options.fixtureDir,
      stdio: ["ignore", "pipe", "pipe"],
      detached: true,
      onSpawn: (child) => { this.currentChild = child; },
    });
    this.currentChild = null;
    const completedAt = new Date().toISOString();
    let receipt = null;
    let semanticReference = null;
    let validationError = null;
    try {
      if (result.spawnError) throw result.spawnError;
      if (result.code !== 0 || result.signal) throw new Error(`child exit=${result.code} signal=${result.signal}`);
      receipt = parseSingleJson(result.stdout, `preflight ${fixtureKey}`);
      semanticReference = validateVerificationReceipt(receipt, fixture, arguments_);
      assertFixtureStable(fixture);
    } catch (error) {
      validationError = error.message;
    }
    let fixtureAfter = null;
    try {
      fixtureAfter = snapshotFixtureIdentities(fixture);
    } catch (error) {
      validationError ||= `could not snapshot fixture after verification: ${error.message}`;
    }
    const observation = {
      sequence: this.state.verifications.length,
      fixture: fixtureKey,
      arguments: arguments_,
      command: [this.options.binary, ...arguments_],
      child_environment: CHILD_ENVIRONMENT,
      started_at: startedAt,
      completed_at: completedAt,
      fixture_before: fixtureBefore,
      fixture_after: fixtureAfter,
      stdout: result.stdout,
      stderr: result.stderr,
      exit_code: result.code,
      signal: result.signal,
      spawn_error: result.spawnError?.message ?? null,
      receipt,
      semantic_reference: semanticReference,
      valid: validationError === null,
      validation_error: validationError,
    };
    this.state.verifications.push(observation);
    appendDurableJsonLine(this.paths.journal, {event: "preflight-verification", observation});
    this.persist();
    if (validationError) throw new Error(`${fixtureKey}: ${validationError}`);
  }

  async execute() {
    this.state.status = "running";
    this.persist();
    for (const fixtureKey of Object.keys(this.fixtures)) {
      if (this.interruption) throw new Error(`interrupted by ${this.interruption.signal}`);
      await this.runVerification(fixtureKey);
    }
    const expected = Object.keys(this.fixtures);
    const actual = this.state.verifications.map((entry) => entry.fixture);
    this.state.completion = {
      expected, actual,
      complete: sameJson(expected, actual) && this.state.verifications.every((entry) => entry.valid),
    };
    invariant(this.state.completion.complete, "semantic preflight did not complete every fixture");
    validatePreflightReceipt({...this.state, status: "complete", valid: true}, {
      commit: this.options.commit, fixtures: this.fixtures, identities: this.identities,
    });
    this.state.status = "complete";
    this.state.valid = true;
  }

  finalize() {
    if (this.finalized) return;
    this.finalized = true;
    try {
      for (const identity of Object.values(this.identities)) assertIdentityUnchanged(identity, {rehash: true});
      for (const fixture of Object.values(this.fixtures)) assertFixtureStable(fixture);
    } catch (error) {
      this.state.errors.push(`final identity validation: ${error.message}`);
      this.state.valid = false;
    }
    if (this.state.status !== "complete" || this.state.valid !== true || this.interruption) {
      this.state.status = this.interruption ? "interrupted" : "invalid";
      this.state.valid = false;
    }
    this.state.interruption = this.interruption;
    this.state.completed_at = new Date().toISOString();
    this.persist();
    this.event("preflight-finalized", {status: this.state.status, valid: this.state.valid});
    writeDurableAtomicNew(this.paths.final, `${JSON.stringify(this.state, null, 2)}\n`);
  }

  interrupt(signal) {
    if (this.interruption) return;
    this.interruption = {signal, at: new Date().toISOString()};
    this.state.errors.push(`interrupted by ${signal}`);
    this.event("preflight-interruption-requested", this.interruption);
    this.persist();
    if (this.currentChild?.pid) {
      try { process.kill(-this.currentChild.pid, signal); } catch { /* The child may have exited. */ }
    }
  }
}

class Campaign {
  constructor(options) {
    this.options = options;
    this.paths = {
      final: options.output,
      partial: `${options.output}.partial.json`,
      journal: `${options.output}.journal.jsonl`,
      environment: `${options.output}.environment.jsonl`,
    };
    for (const file of Object.values(this.paths)) {
      if (fs.existsSync(file)) throw new Error(`campaign output already exists: ${file}`);
    }
    const parent = path.dirname(options.output);
    if (!fs.statSync(parent).isDirectory()) throw new Error(`output parent is not a directory: ${parent}`);
    this.schedule = validateSchedule(buildSchedule());
    this.fixtures = loadFixtures(options.fixtureDir);
    this.identities = {
      runner: serializeStat(process.argv[1], {hash: true}),
      binary: serializeStat(options.binary, {hash: true}),
      node: serializeStat(process.execPath, {hash: true}),
      gnu_time: serializeStat(GNU_TIME, {hash: true}),
      taskset: serializeStat(TASKSET, {hash: true}),
    };
    const preflight = parseJsonFile(options.preflight);
    this.semanticReferences = validatePreflightReceipt(preflight, {
      commit: options.commit, fixtures: this.fixtures, identities: this.identities,
    });
    this.identities.preflight = serializeStat(options.preflight, {hash: true});
    this.preflightSummary = {
      path: this.identities.preflight.path,
      sha256: this.identities.preflight.sha256,
      artifact: preflight.artifact,
      version: preflight.version,
      status: preflight.status,
      valid: preflight.valid,
      completed_at: preflight.completed_at,
      verification_fixtures: preflight.verifications.map((entry) => entry.fixture),
    };
    this.host = hostIdentity();
    invariant(this.host.runner_affinity === RUNNER_CPU,
      `runner must be pinned only to CPU ${RUNNER_CPU}; got ${this.host.runner_affinity}`);
    this.tctlPath = resolveTctlPath();
    this.auditDirectory = fs.mkdtempSync("/tmp/fused-json-m6-time-");
    this.currentChild = null;
    this.runtimeFingerprint = null;
    this.invalidReason = null;
    this.interruption = null;
    this.finalized = false;
    this.state = {
      artifact: ARTIFACT,
      version: VERSION,
      campaign_id: options.campaignId,
      status: "prepared",
      valid: null,
      passed: null,
      started_at: new Date().toISOString(),
      completed_at: null,
      commit: options.commit,
      commit_binding: "caller attestation; the recorded benchmark binary SHA-256 is authoritative",
      paths: this.paths,
      definition: this.definition(),
      schedule: this.schedule,
      identities: this.identities,
      runner_runtime: nodeRuntimeIdentity(),
      fixture_identities: fixtureIdentityMap(this.fixtures),
      semantic_preflight: this.preflightSummary,
      host: this.host,
      admission: null,
      environment: {policy: ENVIRONMENT_POLICY, tctl_path: null, invalid_reason: null, samples: []},
      observations: [],
      events: [],
      rss_ceiling: null,
      analysis: null,
      errors: [],
      interruption: null,
    };
    writeDurableNew(this.paths.journal, `${JSON.stringify({event: "campaign-predeclared", at: new Date().toISOString(),
      campaign_id: options.campaignId, definition: this.state.definition, schedule: this.schedule})}\n`);
    writeDurableNew(this.paths.environment, `${JSON.stringify({event: "environment-log-start", at: new Date().toISOString(),
      policy: ENVIRONMENT_POLICY})}\n`);
    this.persist();
    this.monitor = new EnvironmentMonitor({
      environmentJournal: this.paths.environment,
      onInvalid: (reason) => this.invalidate(reason),
      tctlPath: this.tctlPath,
    });
    this.state.environment.tctl_path = this.monitor.tctlPath;
  }

  definition() {
    return {
      protocol: "fused-json-m6-tic-v2",
      buffer_size: BUFFER_SIZE,
      max_nesting: MAX_NESTING,
      seed: SEED,
      sizes_bytes: SIZES,
      child_environment: CHILD_ENVIRONMENT,
      performance: PERFORMANCE,
      rss: RSS,
      diagnostics: DIAGNOSTICS,
      environment_policy: ENVIRONMENT_POLICY,
      exclusions: "no observation-level exclusions; child, receipt, identity, monitor, or task-CPU failure invalidates the complete campaign",
      retries: "none; an invalid, failed, or interrupted observation is never selectively rerun",
      semantic_verification: "one complete hash-bound preflight is shared by campaigns 1 and 2 and is not performance evidence",
      input_cache: "one validated plain-drain child immediately before every throughput pair",
      rss_ceiling_scope: "maximum of this campaign's ten bounded 256 MiB/1 GiB FusedJSON baselines only",
      rss_ceiling_comparison: "every >4 GiB peak must be strictly less than the frozen ceiling",
      gzip_first_item_and_two_pass: "reported diagnostics; never release gates",
      cpu_frequency: ENVIRONMENT_POLICY.cpuFrequencyPolicy,
    };
  }

  persist() {
    if (this.monitor) this.state.environment.samples = this.monitor.samples;
    writeDurableAtomicReplacement(this.paths.partial, `${JSON.stringify(this.state, null, 2)}\n`);
  }

  event(event, details = {}) {
    const entry = {event, at: new Date().toISOString(), ...details};
    this.state.events.push(entry);
    appendDurableJsonLine(this.paths.journal, entry);
    this.persist();
  }

  invalidate(reason) {
    if (this.invalidReason) return;
    this.invalidReason = reason;
    this.state.environment.invalid_reason = reason;
    this.state.status = "invalid";
    const entry = {event: "campaign-invalidated", at: new Date().toISOString(), reason};
    this.state.events.push(entry);
    appendDurableJsonLine(this.paths.journal, entry);
    this.persist();
  }

  observationById(id) {
    return this.state.observations.find((observation) => observation.id === id);
  }

  assertRunnable() {
    if (this.interruption) {
      throw new CampaignInvalidError(`interrupted by ${this.interruption.signal}`);
    }
    if (this.invalidReason) throw new CampaignInvalidError(this.invalidReason.detail);
    this.monitor.assertValid();
  }

  async runObservation(spec) {
    this.assertRunnable();
    const fixture = this.fixtures[spec.fixture];
    invariant(fixture, `unknown fixture ${spec.fixture}`);
    assertFixtureStable(fixture);
    const expectedArgs = expectedArguments(spec.command, fixture, spec.mode, this.options.commit);
    const auditFile = path.join(this.auditDirectory, `${String(this.state.observations.length).padStart(4, "0")}.time`);
    const outerArguments = ["-v", "-o", auditFile, TASKSET, "-c", BENCHMARK_CPU, this.options.binary, ...expectedArgs];
    const startedAt = new Date().toISOString();
    const startSequence = this.monitor.samples.at(-1)?.sequence ?? null;
    const fixtureBefore = {
      input: serializeStat(fixture.input),
      manifest: serializeStat(fixture.manifestPath, {hash: true}),
      gzip: fixture.gzipInput ? serializeStat(fixture.gzipInput) : null,
    };
    let childBoundaryBefore;
    try {
      childBoundaryBefore = readChildBoundary(this.monitor.tctlPath);
    } catch (error) {
      const reason = {kind: "child_environment_read_failure", detail: `${spec.id} before: ${error.message}`};
      this.invalidate(reason);
      throw new CampaignInvalidError(reason.detail);
    }
    if (childBoundaryBefore.tctl_c >= ENVIRONMENT_POLICY.invalidTctlMinimumC) {
      const reason = {kind: "child_boundary_temperature",
        detail: `${spec.id} before: Tctl ${childBoundaryBefore.tctl_c} C`};
      this.invalidate(reason);
      throw new CampaignInvalidError(reason.detail);
    }
    const result = await spawnCaptured(GNU_TIME, outerArguments, {
      env: {...CHILD_ENVIRONMENT},
      cwd: this.options.fixtureDir,
      stdio: ["ignore", "pipe", "pipe"],
      detached: true,
      onSpawn: (child) => { this.currentChild = child; },
    });
    let childBoundaryAfter = null;
    let childWindow = null;
    let childWindowInvalidReason = null;
    try {
      childBoundaryAfter = readChildBoundary(this.monitor.tctlPath);
      childWindow = childEnvironmentWindow(childBoundaryBefore, childBoundaryAfter);
      if (childBoundaryAfter.tctl_c >= ENVIRONMENT_POLICY.invalidTctlMinimumC) {
        childWindowInvalidReason = {kind: "child_boundary_temperature",
          detail: `${spec.id} after: Tctl ${childBoundaryAfter.tctl_c} C`};
      } else if (!childWindow.within_busy_limit) {
        childWindowInvalidReason = {kind: "child_window_sibling_cpu",
          detail: `${spec.id}: CPU ${BENCHMARK_SIBLING_CPU} busy ` +
            `${childWindow.cpu_busy_percent}% exceeded ` +
            `${ENVIRONMENT_POLICY.childWindowSiblingBusyMaximumPercent}%`};
      }
    } catch (error) {
      childWindowInvalidReason = {kind: "child_environment_read_failure",
        detail: `${spec.id} after: ${error.message}`};
      childWindow = {
        cpu: BENCHMARK_SIBLING_CPU,
        maximum_busy_percent: ENVIRONMENT_POLICY.childWindowSiblingBusyMaximumPercent,
        before: childBoundaryBefore,
        after: childBoundaryAfter,
        read_error: error.message,
      };
    }
    this.currentChild = null;
    const completedAt = new Date().toISOString();
    const auditRaw = fs.existsSync(auditFile) ? fs.readFileSync(auditFile, "utf8") : "";
    let audit = null;
    let receipt = null;
    let validationError = null;
    try {
      if (childWindowInvalidReason) throw new Error(childWindowInvalidReason.detail);
      if (result.spawnError) throw result.spawnError;
      if (result.code !== 0 || result.signal) throw new Error(`child exit=${result.code} signal=${result.signal}`);
      audit = parseGnuTime(auditRaw);
      if (audit.exit_status !== result.code) throw new Error("GNU time exit status disagrees with wrapper exit");
      receipt = parseSingleJson(result.stdout, spec.id);
      if (spec.command === "verify") {
        this.semanticReferences[fixture.key] = validateVerificationReceipt(receipt, fixture, expectedArgs);
      } else {
        const semanticReference = this.semanticReferences[fixture.key];
        if (!semanticReference && !modeProperties(spec.mode).drain) throw new Error(`fixture ${fixture.key} was not semantically verified`);
        validateMeasurementReceipt(receipt, {
          fixture, mode: spec.mode, command: spec.command, expectedArgs,
          commit: this.options.commit, semanticReference,
        });
        const fingerprint = receiptFingerprint(receipt);
        if (!this.runtimeFingerprint) this.runtimeFingerprint = fingerprint;
        else if (!sameJson(this.runtimeFingerprint, fingerprint)) throw new Error("runtime/host/environment fingerprint changed");
      }
      assertFixtureStable(fixture);
      if (spec.parserChild && audit.cpu_percent < ENVIRONMENT_POLICY.minimumParserTaskCpuPercent) {
        throw new Error(`parser child task CPU ${audit.cpu_percent}% is below ` +
          `${ENVIRONMENT_POLICY.minimumParserTaskCpuPercent}%`);
      }
      this.monitor.assertValid();
    } catch (error) {
      validationError = error.message;
    }
    const fixtureAfter = {
      input: serializeStat(fixture.input),
      manifest: serializeStat(fixture.manifestPath, {hash: true}),
      gzip: fixture.gzipInput ? serializeStat(fixture.gzipInput) : null,
    };
    const observation = {
      sequence: this.state.observations.length,
      id: spec.id,
      phase: spec.phase,
      category: spec.category,
      block_id: spec.blockId ?? null,
      profile: fixture.profile,
      fixture: fixture.key,
      side: spec.side ?? null,
      mode: spec.mode ?? null,
      command: [GNU_TIME, ...outerArguments],
      benchmark_arguments: expectedArgs,
      child_environment: CHILD_ENVIRONMENT,
      started_at: startedAt,
      completed_at: completedAt,
      environment_start_sample_sequence: startSequence,
      environment_end_sample_sequence: this.monitor.samples.at(-1)?.sequence ?? null,
      child_environment_window: childWindow,
      fixture_before: fixtureBefore,
      fixture_after: fixtureAfter,
      stdout: result.stdout,
      stderr: result.stderr,
      gnu_time_output: auditRaw,
      wrapper_exit_code: result.code,
      wrapper_signal: result.signal,
      spawn_error: result.spawnError?.message ?? null,
      task_audit: audit,
      receipt,
      valid: validationError === null,
      validation_error: validationError,
    };
    this.state.observations.push(observation);
    appendDurableJsonLine(this.paths.journal, {event: "observation", observation});
    this.persist();
    if (validationError) {
      this.invalidate(childWindowInvalidReason ??
        {kind: "observation_invalid", detail: `${spec.id}: ${validationError}`});
      throw new CampaignInvalidError(validationError);
    }
    return observation;
  }

  async startBlock(blockId, gatePosition) {
    this.assertRunnable();
    const label = `${blockId}:${gatePosition}`;
    const gate = await this.monitor.awaitBlockStart(label);
    this.assertRunnable();
    const sample = this.monitor.samples.find((candidate) =>
      candidate.sequence === gate.admitted_sample_sequence);
    invariant(sample, `${label}: admitted sample disappeared`);
    this.event("block-admitted", {
      label,
      block_id: blockId,
      gate_position: gatePosition,
      sample_sequence: sample.sequence,
      tctl_c: sample.tctl_c,
      gate,
    });
    return gate;
  }

  async runPerformancePair(entry) {
    await this.startBlock(entry.id, "before-warm");
    await this.runObservation({
      id: `${entry.id}-warm`, phase: "performance", category: "page-cache-warm",
      fixture: entry.fixture, command: "run", mode: "plain-drain", parserChild: false,
      blockId: entry.id,
    });
    await this.startBlock(entry.id, "after-warm-before-side1");
    for (const side of entry.order) {
      const mode = `${side}-typed`;
      await this.runObservation({
        id: `${entry.id}-${side}`, phase: "performance", category: "typed-throughput",
        fixture: entry.fixture, command: "run", mode, parserChild: true,
        blockId: entry.id, side,
      });
    }
  }

  async runSingle(entry, details) {
    await this.startBlock(entry.id, "before-measurement");
    return this.runObservation({
      id: entry.id,
      fixture: entry.fixture,
      mode: entry.mode,
      blockId: entry.id,
      ...details,
    });
  }

  async runDiagnosticPair(entry, category) {
    await this.startBlock(entry.id, "before-measurement");
    for (const mode of entry.order) {
      await this.runObservation({
        id: `${entry.id}-${mode.startsWith("fused-") ? "fused" : "crystal"}`,
        phase: "diagnostics", category, fixture: entry.fixture,
        command: mode.includes("retained") ? "rss" : "run",
        mode, parserChild: true, blockId: entry.id,
        side: mode.startsWith("fused-") ? "fused" : "crystal",
      });
    }
  }

  freezeRssCeiling() {
    invariant(this.state.rss_ceiling === null, "RSS ceiling was already frozen");
    const observations = this.schedule.bounded_rss_baselines.map((entry) => this.observationById(entry.id));
    invariant(observations.every((observation) => observation?.valid), "cannot freeze RSS ceiling before all baselines complete");
    const values = observations.map((observation) => observation.task_audit.maximum_resident_kibibytes);
    this.state.rss_ceiling = {
      ...rssCeiling(values),
      frozen_at: new Date().toISOString(),
      observation_ids: observations.map((observation) => observation.id),
      formula: "max baseline KiB + max(16384 KiB, ceil(25% of max baseline KiB))",
    };
    this.event("rss-ceiling-frozen", {rss_ceiling: this.state.rss_ceiling});
  }

  analyzePerformance() {
    const profiles = {};
    for (const profile of ["many-small", "wide-item"]) {
      const entries = this.schedule.performance.filter((entry) => entry.profile === profile);
      const pairs = entries.map((entry) => {
        const fused = this.observationById(`${entry.id}-fused`);
        const crystal = this.observationById(`${entry.id}-crystal`);
        invariant(fused?.valid && crystal?.valid, `${entry.id}: incomplete performance pair`);
        const fusedThroughput = fused.receipt.decompressed_mib_per_second;
        const crystalThroughput = crystal.receipt.decompressed_mib_per_second;
        const ratio = fusedThroughput / crystalThroughput;
        invariant(Number.isFinite(ratio) && ratio > 0, `${entry.id}: invalid throughput ratio`);
        return {
          id: entry.id, round: entry.round, slot: entry.slot, order: entry.order,
          fused_observation: fused.id, crystal_observation: crystal.id,
          fused_mib_per_second: fusedThroughput,
          crystal_mib_per_second: crystalThroughput,
          ratio, log_ratio: Math.log(ratio),
        };
      });
      const ratios = pairs.map((pair) => pair.ratio);
      const geometric = geometricMean(ratios);
      const lower = bootstrapLower(ratios);
      profiles[profile] = {
        pairs,
        pair_count: pairs.length,
        median_ratio: median(ratios),
        geometric_mean_ratio: geometric,
        bootstrap_one_sided_95_lower: lower,
        gates: {
          geometric_mean: geometric >= PERFORMANCE.geometricMeanGate,
          bootstrap_lower: lower > PERFORMANCE.bootstrapLowerGate,
        },
      };
      profiles[profile].passed = Object.values(profiles[profile].gates).every(Boolean);
    }
    return profiles;
  }

  analyzeRss() {
    invariant(this.state.rss_ceiling, "RSS ceiling is not frozen");
    const baseline = this.schedule.bounded_rss_baselines.map((entry) => {
      const observation = this.observationById(entry.id);
      invariant(observation?.valid, `${entry.id}: missing RSS baseline`);
      return {
        id: entry.id,
        fixture: entry.fixture,
        peak_rss_kibibytes: observation.task_audit.maximum_resident_kibibytes,
        peak_rss_bytes: observation.task_audit.maximum_resident_bytes,
      };
    });
    const large = this.schedule.bounded_rss_large.map((entry) => {
      const observation = this.observationById(entry.id);
      invariant(observation?.valid, `${entry.id}: missing large RSS run`);
      invariant(this.fixtures[entry.fixture].bytes > 4 * GIB, `${entry.id}: input is not strictly larger than 4 GiB`);
      const peakKibibytes = observation.task_audit.maximum_resident_kibibytes;
      return {
        id: entry.id,
        peak_rss_kibibytes: peakKibibytes,
        peak_rss_bytes: observation.task_audit.maximum_resident_bytes,
        strictly_below_ceiling: peakKibibytes < this.state.rss_ceiling.ceiling_kibibytes,
      };
    });
    return {baseline, large, passed: large.every((entry) => entry.strictly_below_ceiling)};
  }

  analyzeDiagnostics() {
    const groups = {};
    for (const [name, entries] of Object.entries(this.schedule.diagnostics)) {
      const ids = [];
      if (name.endsWith("_pairs")) {
        for (const entry of entries) {
          ids.push(`${entry.id}-fused`, `${entry.id}-crystal`);
        }
      } else {
        ids.push(...entries.map((entry) => entry.id));
      }
      const observations = ids.map((id) => this.observationById(id));
      invariant(observations.every((observation) => observation?.valid), `${name}: incomplete diagnostic series`);
      groups[name] = {
        observation_ids: ids,
        peaks_rss_bytes: observations.map((observation) => observation.task_audit.maximum_resident_bytes),
        decompressed_mib_per_second: observations.map((observation) =>
          observation.receipt.decompressed_mib_per_second),
        first_projected_price_seconds: observations.map((observation) =>
          observation.receipt.first_projected_price_seconds),
      };
      if (name.endsWith("_pairs")) {
        groups[name].pairs = entries.map((entry) => {
          const fused = this.observationById(`${entry.id}-fused`);
          const crystal = this.observationById(`${entry.id}-crystal`);
          return {
            id: entry.id,
            order: entry.order,
            fused_observation: fused.id,
            crystal_observation: crystal.id,
            throughput_ratio: fused.receipt.decompressed_mib_per_second /
              crystal.receipt.decompressed_mib_per_second,
            peak_rss_ratio: fused.task_audit.maximum_resident_bytes /
              crystal.task_audit.maximum_resident_bytes,
            fused_first_projected_price_seconds: fused.receipt.first_projected_price_seconds,
            crystal_first_projected_price_seconds: crystal.receipt.first_projected_price_seconds,
          };
        });
        groups[name].geometric_mean_throughput_ratio = geometricMean(
          groups[name].pairs.map((pair) => pair.throughput_ratio)
        );
      }
    }
    return groups;
  }

  expectedObservationIds() {
    const ids = [];
    for (const entry of this.schedule.performance) ids.push(`${entry.id}-warm`, `${entry.id}-fused`, `${entry.id}-crystal`);
    ids.push(...this.schedule.bounded_rss_baselines.map((entry) => entry.id));
    ids.push(...this.schedule.bounded_rss_large.map((entry) => entry.id));
    ids.push(...this.schedule.diagnostics.plain_drains.map((entry) => entry.id));
    ids.push(...this.schedule.diagnostics.gzip_drain_rss.map((entry) => entry.id));
    for (const key of ["gzip_typed_pairs", "two_pass_pairs", "retained_pairs"]) {
      for (const entry of this.schedule.diagnostics[key]) ids.push(`${entry.id}-fused`, `${entry.id}-crystal`);
    }
    ids.push(...this.schedule.diagnostics.wide_item_rss.map((entry) => entry.id));
    return ids;
  }

  completionState() {
    const expected = this.expectedObservationIds();
    const actual = this.state.observations.map((observation) => observation.id);
    const missing = expected.filter((id) => !actual.includes(id));
    const unexpected = actual.filter((id) => !expected.includes(id));
    const duplicate = actual.filter((id, index) => actual.indexOf(id) !== index);
    const invalid = this.state.observations.filter((observation) => !observation.valid).map((observation) => observation.id);
    return {expected_count: expected.length, actual_count: actual.length, missing, unexpected, duplicate, invalid,
      complete: missing.length === 0 && unexpected.length === 0 && duplicate.length === 0 && invalid.length === 0};
  }

  async execute() {
    this.state.status = "admitting";
    this.persist();
    this.monitor.start();
    this.state.admission = await this.monitor.awaitAdmission();
    this.state.status = "running";
    this.event("campaign-admitted", {admission: this.state.admission});

    for (const entry of this.schedule.performance) await this.runPerformancePair(entry);
    for (const entry of this.schedule.bounded_rss_baselines) {
      await this.runSingle(entry, {phase: "rss", category: "bounded-baseline", command: "rss", parserChild: true});
    }
    this.freezeRssCeiling();
    for (const entry of this.schedule.bounded_rss_large) {
      await this.runSingle(entry, {phase: "rss", category: "bounded-large", command: "rss", parserChild: true});
    }

    for (const entry of this.schedule.diagnostics.plain_drains) {
      await this.runSingle(entry, {phase: "diagnostics", category: "plain-drain-rss", command: "rss", parserChild: false});
    }
    for (const entry of this.schedule.diagnostics.gzip_drain_rss) {
      await this.runSingle(entry, {phase: "diagnostics", category: "gzip-drain-rss", command: "rss", parserChild: false});
    }
    for (const entry of this.schedule.diagnostics.gzip_typed_pairs) await this.runDiagnosticPair(entry, "gzip-typed");
    for (const entry of this.schedule.diagnostics.two_pass_pairs) await this.runDiagnosticPair(entry, "two-pass-typed");
    for (const entry of this.schedule.diagnostics.wide_item_rss) {
      await this.runSingle(entry, {phase: "diagnostics", category: "wide-item-rss", command: "rss", parserChild: true});
    }
    for (const entry of this.schedule.diagnostics.retained_pairs) await this.runDiagnosticPair(entry, "retained-output-rss");

    const completion = this.completionState();
    invariant(completion.complete, `campaign schedule is incomplete: ${JSON.stringify(completion)}`);
    const performanceAnalysis = this.analyzePerformance();
    const rssAnalysis = this.analyzeRss();
    const diagnostics = this.analyzeDiagnostics();
    this.state.analysis = {
      completion,
      performance: performanceAnalysis,
      bounded_rss: rssAnalysis,
      diagnostics,
      passed: Object.values(performanceAnalysis).every((profile) => profile.passed) && rssAnalysis.passed,
    };
    this.state.valid = true;
    this.state.passed = this.state.analysis.passed;
    this.state.status = this.state.passed ? "complete-passed" : "complete-failed";
  }

  verifyFinalIdentities() {
    for (const identity of Object.values(this.identities)) assertIdentityUnchanged(identity, {rehash: true});
    for (const fixture of Object.values(this.fixtures)) assertFixtureStable(fixture);
  }

  finalize() {
    if (this.finalized) return;
    this.finalized = true;
    try {
      this.verifyFinalIdentities();
    } catch (error) {
      this.invalidate({kind: "final_identity", detail: error.message});
    }
    if (this.monitor) {
      this.state.environment.samples = this.monitor.samples;
      this.monitor.stop();
    }
    const completion = this.completionState();
    if (this.invalidReason || this.interruption || !completion.complete) {
      this.state.valid = false;
      this.state.passed = false;
      this.state.analysis = null;
      this.state.status = this.interruption ? "interrupted" : "invalid";
    }
    this.state.completed_at = new Date().toISOString();
    this.state.completion = completion;
    this.state.interruption = this.interruption;
    this.state.environment.invalid_reason = this.invalidReason;
    this.persist();
    appendDurableJsonLine(this.paths.journal, {event: "campaign-finalized", at: this.state.completed_at,
      status: this.state.status, valid: this.state.valid, passed: this.state.passed, completion});
    writeDurableAtomicNew(this.paths.final, `${JSON.stringify(this.state, null, 2)}\n`);
    try {
      fs.rmSync(this.auditDirectory, {recursive: true, force: true});
    } catch {
      // The final receipt already contains every audit record.
    }
  }

  interrupt(signal) {
    if (this.interruption) {
      process.exit(128 + (signal === "SIGINT" ? 2 : 15));
    }
    this.interruption = {signal, at: new Date().toISOString()};
    this.state.errors.push(`interrupted by ${signal}`);
    if (this.currentChild?.pid) {
      try { process.kill(-this.currentChild.pid, signal); } catch { /* The child may have exited. */ }
    }
    this.monitor?.invalidateAndWake({kind: "interruption", detail: `interrupted by ${signal}`});
    this.event("interruption-requested", this.interruption);
  }
}

function syntheticFixture() {
  const counts = {provider_references: 16, provider_groups: 16, in_network: 10,
    negotiated_rates: 10, negotiated_prices: 10};
  return {
    key: "synthetic", profile: "many-small", bytes: SIZES.throughput,
    input: "/fixtures/many-small-256m.json",
    manifestPath: "/fixtures/many-small-256m.meta.json",
    gzipInput: "/fixtures/many-small-256m.json.gz",
    identities: {manifest: {sha256: "a".repeat(64)}},
    manifest: {
      document_sha256: "b".repeat(64),
      root_key_order: ["provider_references", "in_network"],
      counts,
      projection: {
        sha256: "c".repeat(64), checksum: "0x1111111111111111",
        raw_number_checksum_algorithm: "fnv1a64-fields-raw-number-v2",
        raw_number_checksum: "0x3333333333333333",
      },
      gzip: {bytes: 12345},
    },
  };
}

function syntheticVerificationReceipt(fixture) {
  return {
    receipt: "fused-json-tic-verification", version: 1, command: "verify", status: "verified",
    profile: fixture.profile, seed: SEED, root_key_order: fixture.manifest.root_key_order,
    boundary_bytes: null, input: fixture.input, manifest: fixture.manifestPath,
    manifest_sha256: fixture.identities.manifest.sha256,
    document_bytes: fixture.bytes, document_sha256: fixture.manifest.document_sha256,
    projection_sha256: fixture.manifest.projection.sha256,
    projection_checksum: fixture.manifest.projection.checksum,
    typed_verified: true, typed_provider_checksum_algorithm: "fnv1a64-provider-fields-v1",
    typed_provider_checksum: "0x2222222222222222",
    typed_provider_records: fixture.manifest.counts.provider_references,
    typed_price_records: fixture.manifest.counts.negotiated_prices,
    typed_scalar_values: fixture.manifest.counts.negotiated_rates,
    raw_number_verified: true,
    raw_number_checksum_algorithm: fixture.manifest.projection.raw_number_checksum_algorithm,
    raw_number_checksum: fixture.manifest.projection.raw_number_checksum,
    gzip_verified: true, counts: fixture.manifest.counts,
    buffer_size: BUFFER_SIZE, max_nesting: MAX_NESTING,
  };
}

function syntheticMeasurementReceipt({mode = "fused-typed", command = "run", retained = false} = {}) {
  const fixture = syntheticFixture();
  const properties = modeProperties(mode);
  const inputPasses = properties.twoPass ? 2 : 1;
  const expectedArgs = expectedArguments(command, fixture, mode, "d".repeat(40));
  const wall = 2;
  const processed = fixture.bytes * inputPasses;
  const receipt = {
    receipt: "fused-json-tic-measurement", version: 1, command, mode,
    profile: fixture.profile, seed: SEED, arguments: expectedArgs,
    root_key_order: fixture.manifest.root_key_order,
    input: properties.gzip ? fixture.gzipInput : fixture.input,
    manifest: fixture.manifestPath, manifest_sha256: fixture.identities.manifest.sha256,
    expected_document_sha256: fixture.manifest.document_sha256,
    expected_projection_sha256: fixture.manifest.projection.sha256,
    expected_projection_checksum: fixture.manifest.projection.checksum,
    logical_document_bytes: fixture.bytes, input_passes: inputPasses, processed_bytes: processed,
    compressed_ingress_bytes: properties.gzip ? fixture.manifest.gzip.bytes : null,
    decompressed_mib_per_second: (processed / MIB) / wall,
    logical_document_mib_per_second: (fixture.bytes / MIB) / wall,
    projected_prices_per_second: fixture.manifest.counts.negotiated_prices / wall,
    typed_values_per_second: 18,
    first_projected_price_seconds: 0.1,
    projection_sha256: null, projection_checksum: fixture.manifest.projection.checksum,
    typed_provider_checksum_algorithm: "fnv1a64-provider-fields-v1",
    typed_provider_checksum: "0x2222222222222222",
    typed_provider_records: fixture.manifest.counts.provider_references,
    typed_price_records: fixture.manifest.counts.negotiated_prices,
    typed_scalar_values: fixture.manifest.counts.negotiated_rates,
    typed_records: 26, typed_values: 36, typed_pass_wall_seconds: [wall],
    drain_observer: null, counts: fixture.manifest.counts,
    timing: {wall_seconds: wall, user_cpu_seconds: 1.9, system_cpu_seconds: 0.1, total_cpu_seconds: 2},
    managed_memory: {allocated_bytes: 1000},
    configuration: {
      buffer_size: BUFFER_SIZE, max_nesting: MAX_NESTING, parser: properties.parser,
      transport: properties.gzip ? "gzip" : "plain", workload: retained ? "typed-retained" : "typed",
      fused_cache_keys: false, fused_reject_duplicate_keys: false,
      retained_output_policy: retained ? RETENTION_POLICY : "none",
    },
    runtime: {fused_json_commit: "d".repeat(40), release_build: true,
      crystal_version: "1.22", llvm_version: "21", target: "x86_64", zlib_version: "1.3"},
    host: {os: "Linux", cpu_model: "synthetic", cpu_count: 8, cpu_affinity: BENCHMARK_CPU},
    environment: {GC_NPROCS: "1", GC_MARKERS: "1", CRYSTAL_WORKERS: "1", OMP_NUM_THREADS: "1"},
    retained_output: null,
  };
  if (retained) {
    receipt.retained_output = {
      policy: RETENTION_POLICY,
      provider_records: fixture.manifest.counts.provider_references,
      scalar_values: fixture.manifest.counts.negotiated_rates,
      price_records: fixture.manifest.counts.negotiated_prices,
      total_values: fixture.manifest.counts.provider_references + fixture.manifest.counts.negotiated_rates +
        fixture.manifest.counts.negotiated_prices,
    };
  }
  return {receipt, fixture, expectedArgs, semanticReference: {
    projection_checksum: fixture.manifest.projection.checksum,
    provider_checksum: "0x2222222222222222",
  }};
}

function runSelfAudit() {
  const assertions = [];
  const check = (name, callback) => {
    callback();
    assertions.push(name);
  };
  const rejects = (callback, pattern) => {
    let error = null;
    try { callback(); } catch (exception) { error = exception; }
    invariant(error && pattern.test(error.message), `expected rejection ${pattern}, got ${error?.message}`);
  };

  check("durable-write-all", () => {
    const payload = Buffer.from("partial-\u2603-write\n", "utf8");
    const chunks = [];
    let calls = 0;
    const written = writeAllSync(17, payload, (descriptor, bytes, offset, remaining) => {
      invariant(descriptor === 17 && bytes === payload, "write-all changed its descriptor or buffer");
      const count = Math.min(1 + (calls % 3), remaining);
      chunks.push(Buffer.from(bytes.subarray(offset, offset + count)));
      calls += 1;
      return count;
    });
    invariant(written === payload.length && calls > 1 && Buffer.concat(chunks).equals(payload),
      "write-all lost bytes across partial writes");
    rejects(() => writeAllSync(17, Buffer.from("x"), () => 0), /invalid synchronous write count/);
    rejects(() => writeAllSync(17, Buffer.from("x"), (_descriptor, _bytes, _offset, remaining) => remaining + 1),
      /invalid synchronous write count/);
  });
  check("strict-tctl-input", () => {
    const parsed = parseTctlInput("94000\n");
    invariant(parsed.rawMillidegrees === "94000" && parsed.celsius === 94,
      "valid Tctl input was parsed incorrectly");
    for (const malformed of ["", " \n", "-1", "+1", "1.5", "01", "NaN", "Infinity"]) {
      rejects(() => parseTctlInput(malformed), /nonempty unsigned decimal integer/);
    }
    rejects(() => parseTctlInput("9007199254740992"), /safe integer range/);
  });
  check("schedule", () => validateSchedule(buildSchedule()));
  check("verification-arguments", () => {
    const fixture = syntheticFixture();
    const arguments_ = expectedArguments("verify", fixture, null, "d".repeat(40));
    invariant(arguments_.includes(`--gzip-input=${fixture.gzipInput}`),
      "gzip fixture verification omitted compressed input");
    invariant(!arguments_.some((argument) => argument.startsWith("--commit=")),
      "verification unexpectedly received a commit argument");
  });
  check("shared-semantic-preflight", () => {
    const fixture = syntheticFixture();
    const fixtures = {synthetic: fixture};
    const identities = {
      runner: {sha256: "e".repeat(64)},
      binary: {sha256: "f".repeat(64)},
      node: {sha256: "1".repeat(64)},
    };
    const receipt = syntheticVerificationReceipt(fixture);
    const arguments_ = expectedArguments("verify", fixture, null, "d".repeat(40));
    const preflight = {
      artifact: "fused-json-m6-tic-preflight", version: 1, status: "complete", valid: true,
      commit: "d".repeat(40),
      definition: {buffer_size: BUFFER_SIZE, max_nesting: MAX_NESTING, seed: SEED},
      identities, runner_runtime: nodeRuntimeIdentity(), fixture_identities: fixtureIdentityMap(fixtures),
      verifications: [{
        fixture: "synthetic", valid: true, exit_code: 0, signal: null, spawn_error: null,
        validation_error: null, arguments: arguments_, stdout: JSON.stringify(receipt), stderr: "",
        receipt, fixture_before: fixture.identities, fixture_after: fixture.identities,
      }],
    };
    const references = validatePreflightReceipt(preflight, {
      commit: "d".repeat(40), fixtures, identities,
    });
    invariant(references.synthetic.projection_checksum === fixture.manifest.projection.checksum,
      "semantic reference was not imported");
    const incomplete = structuredClone(preflight);
    incomplete.verifications = [];
    rejects(() => validatePreflightReceipt(incomplete, {
      commit: "d".repeat(40), fixtures, identities,
    }), /incomplete/);
    const wrongBinary = structuredClone(preflight);
    wrongBinary.identities.binary.sha256 = "0".repeat(64);
    rejects(() => validatePreflightReceipt(wrongBinary, {
      commit: "d".repeat(40), fixtures, identities,
    }), /binary hash/);
  });
  check("bootstrap-determinism-and-gates", () => {
    const passing = Array(20).fill(1.1);
    const first = bootstrapLower(passing);
    const second = bootstrapLower(passing);
    invariant(first === second && first > 1.0 && geometricMean(passing) >= 1.05, "passing vector failed");
    const lowerEquality = Array(20).fill(1.0);
    invariant(bootstrapLower(lowerEquality) === 1.0 && !(bootstrapLower(lowerEquality) > 1.0),
      "bootstrap lower equality must fail strict gate");
    rejects(() => bootstrapLower(Array(19).fill(1.1)), /all 20/);
    rejects(() => geometricMean([1, 0]), /positive/);
  });
  check("rss-ceiling", () => {
    const small = rssCeiling(Array(10).fill(40 * 1024));
    invariant(small.headroom_kibibytes === 16 * 1024 && small.ceiling_kibibytes === 56 * 1024,
      "16 MiB floor error");
    const large = rssCeiling(Array(10).fill(100 * 1024));
    invariant(large.headroom_kibibytes === 25 * 1024 && large.ceiling_kibibytes === 125 * 1024,
      "25% headroom error");
    const rounded = rssCeiling([...Array(9).fill(100_000), 100_001]);
    invariant(rounded.headroom_kibibytes === 25_001 && rounded.ceiling_kibibytes === 125_002,
      "KiB ceiling did not round upward before addition");
    invariant(!(large.ceiling_kibibytes < large.ceiling_kibibytes), "RSS equality must fail strict comparison");
    rejects(() => rssCeiling(Array(9).fill(1)), /ten/);
    invariant(SIZES.rssLarge > 4 * GIB, "large fixture must be strictly larger than 4 GiB");
  });
  check("gnu-time-parser", () => {
    const raw = `\n\tUser time (seconds): 1.00\n\tSystem time (seconds): 0.01\n\tPercent of CPU this job got: 99%\n` +
      `\tElapsed (wall clock) time (h:mm:ss or m:ss): 0:01.02\n\tMaximum resident set size (kbytes): 12345\n` +
      `\tMajor (requiring I/O) page faults: 0\n\tMinor (reclaiming a frame) page faults: 2\n` +
      `\tVoluntary context switches: 3\n\tInvoluntary context switches: 4\n\tFile system inputs: 0\n` +
      `\tFile system outputs: 8\n\tExit status: 0\n`;
    const parsed = parseGnuTime(raw);
    invariant(parsed.cpu_percent === 99 && parsed.maximum_resident_bytes === 12345 * 1024, "GNU time parse error");
    rejects(() => parseGnuTime(raw.replace("Maximum resident set size (kbytes): 12345", "")), /occurred 0/);
    rejects(() => parseGnuTime(raw.replace("12345", "0")), /peak RSS is zero/);
  });
  check("measurement-receipt", () => {
    const synthetic = syntheticMeasurementReceipt();
    validateMeasurementReceipt(synthetic.receipt, {
      fixture: synthetic.fixture, mode: "fused-typed", command: "run",
      expectedArgs: synthetic.expectedArgs, commit: "d".repeat(40),
      semanticReference: synthetic.semanticReference,
    });
    const wrongAffinity = structuredClone(synthetic.receipt);
    wrongAffinity.host.cpu_affinity = "2-3";
    rejects(() => validateMeasurementReceipt(wrongAffinity, {
      fixture: synthetic.fixture, mode: "fused-typed", command: "run",
      expectedArgs: synthetic.expectedArgs, commit: "d".repeat(40),
      semanticReference: synthetic.semanticReference,
    }), /affinity/);
    const wrongChecksum = structuredClone(synthetic.receipt);
    wrongChecksum.projection_checksum = "0xffffffffffffffff";
    rejects(() => validateMeasurementReceipt(wrongChecksum, {
      fixture: synthetic.fixture, mode: "fused-typed", command: "run",
      expectedArgs: synthetic.expectedArgs, commit: "d".repeat(40),
      semanticReference: synthetic.semanticReference,
    }), /projection mismatch/);
    const retained = syntheticMeasurementReceipt({mode: "fused-retained-typed", command: "rss", retained: true});
    validateMeasurementReceipt(retained.receipt, {
      fixture: retained.fixture, mode: "fused-retained-typed", command: "rss",
      expectedArgs: retained.expectedArgs, commit: "d".repeat(40), semanticReference: retained.semanticReference,
    });
    retained.receipt.retained_output.total_values -= 1;
    rejects(() => validateMeasurementReceipt(retained.receipt, {
      fixture: retained.fixture, mode: "fused-retained-typed", command: "rss",
      expectedArgs: retained.expectedArgs, commit: "d".repeat(40), semanticReference: retained.semanticReference,
    }), /retained-output/);
  });
  check("environment-invalidation", () => {
    const base = {read_errors: [], gap_seconds: 2, tctl_c: 94, load1: 5,
      cpu2_busy_percent: 1};
    let state = {loadBreaches: 0, siblingBreaches: 0};
    invariant(environmentInvalidation(state, {...base, load1: 7}) === null &&
      environmentInvalidation(state, {...base, load1: 7}) === null, "load equality must not invalidate");
    invariant(environmentInvalidation(state, {...base, load1: 7.001}) === null, "first load breach invalidated");
    invariant(environmentInvalidation(state, {...base, load1: 7.001})?.kind === "load", "second load breach did not invalidate");
    state = {loadBreaches: 0, siblingBreaches: 0};
    invariant(environmentInvalidation(state, {...base, cpu2_busy_percent: 35}) === null &&
      environmentInvalidation(state, {...base, cpu2_busy_percent: 35}) === null,
    "sibling equality must not invalidate");
    environmentInvalidation(state, {...base, cpu2_busy_percent: 35.001});
    environmentInvalidation(state, base);
    invariant(environmentInvalidation(state, {...base, cpu2_busy_percent: 35.001}) === null,
      "sibling breach did not reset");
    invariant(environmentInvalidation({loadBreaches: 0, siblingBreaches: 0}, {...base, tctl_c: 100})?.kind === "temperature",
      "thermal equality must invalidate");
    invariant(environmentInvalidation({loadBreaches: 0, siblingBreaches: 0}, {...base, tctl_c: 99.999}) === null,
      "temperature below the invalid boundary must pass");
    invariant(environmentInvalidation({loadBreaches: 0, siblingBreaches: 0}, {...base, gap_seconds: 5}) === null,
      "monitor-gap equality must pass");
    invariant(environmentInvalidation({loadBreaches: 0, siblingBreaches: 0}, {...base, gap_seconds: 5.001})?.kind === "monitor_gap",
      "monitor gap did not invalidate");
    invariant(environmentInvalidation({loadBreaches: 0, siblingBreaches: 0}, {...base, read_errors: ["x"]})?.kind === "environment_read_failure",
      "read error did not invalidate");
  });
  check("busy-pinned-v2-gates", () => {
    invariant(ENVIRONMENT_POLICY.name === "busy-pinned-v2" && ENVIRONMENT_POLICY.version === 2 &&
      ENVIRONMENT_POLICY.sampleIntervalMs === 2_000, "wrong environment policy identity");
    const sample = (sequence, monotonicMs, overrides = {}) => ({
      sequence, monotonic_ms: monotonicMs, load1: 5, load5: 5, tctl_c: sequence % 2 ? 89 : 94,
      cpu2_busy_percent: 25, cpu3_busy_percent: 10, ...overrides,
    });
    let window = null;
    for (let sequence = 0; sequence <= 30; sequence += 1) {
      window = advanceGateWindow(window, sample(sequence, sequence * 2_000));
    }
    const admission = admittedGate(window, 60, "campaign-initial-admission");
    invariant(admission?.duration_seconds === 60 && admission.tctl_range_c === 5 &&
      admission.sample_count === 31 && admission.first_sample_sequence === 0 &&
      admission.admitted_sample_sequence === 30 &&
      !Object.hasOwn(admission, "admitted_evaluated_monotonic_ms"),
    "initial admission equality failed");
    invariant(admittedGate(window, 60.001, "too-long") === null, "short admission window passed");
    let sparseWindow = advanceGateWindow(null, sample(0, 0, {tctl_c: 94}));
    sparseWindow = advanceGateWindow(sparseWindow, sample(1, 60_000, {tctl_c: 94}));
    invariant(admittedGate(sparseWindow, 60, "sparse") === null,
      "initial gate admitted fewer than 31 two-second samples");
    invariant(!gateSampleAcceptable(sample(0, 0, {load1: 5.001})) &&
      !gateSampleAcceptable(sample(0, 0, {load5: 5.001})) &&
      !gateSampleAcceptable(sample(0, 0, {tctl_c: 94.001})) &&
      !gateSampleAcceptable(sample(0, 0, {cpu2_busy_percent: 25.001})) &&
      !gateSampleAcceptable(sample(0, 0, {cpu3_busy_percent: 10.001})),
    "a gate accepted a strict limit breach");
    let rangeWindow = advanceGateWindow(null, sample(0, 0, {tctl_c: 88}));
    rangeWindow = advanceGateWindow(rangeWindow, sample(1, 2_000, {tctl_c: 94}));
    invariant(rangeWindow.samples.length === 1 && rangeWindow.minimumTctlC === 94,
      "Tctl range breach did not restart the window at the current sample");
    let blockWindow = null;
    for (let sequence = 0; sequence <= 3; sequence += 1) {
      blockWindow = advanceGateWindow(blockWindow, sample(sequence, sequence * 2_000, {tctl_c: 94}));
    }
    invariant(admittedGate(blockWindow, 6, "block:before-measurement")?.duration_seconds === 6,
      "six-second block equality failed");
    let sparseBlock = advanceGateWindow(null, sample(0, 0, {tctl_c: 94}));
    sparseBlock = advanceGateWindow(sparseBlock, sample(1, 6_000, {tctl_c: 94}));
    invariant(admittedGate(sparseBlock, 6, "sparse-block") === null,
      "block gate admitted fewer than four two-second samples");
    let deadlineWindow = null;
    for (let sequence = 0; sequence <= 3; sequence += 1) {
      deadlineWindow = advanceGateWindow(deadlineWindow,
        sample(sequence, 1_174_000 + (sequence * 2_000), {tctl_c: 94}));
    }
    const atDeadline = admittedBlockGate(
      deadlineWindow, "block:before-measurement", 1_000_000, 1_180_000, 1_180_000
    );
    invariant(atDeadline?.wait_started_monotonic_ms === 1_000_000 &&
      atDeadline.deadline_monotonic_ms === 1_180_000 &&
      atDeadline.admitted_evaluated_monotonic_ms === 1_180_000,
    "block gate at the deadline must pass and record its wait and evaluation bounds");
    const lateWindow = advanceGateWindow(null, sample(0, 1_174_001, {tctl_c: 94}));
    let completedLateWindow = lateWindow;
    for (let sequence = 1; sequence <= 3; sequence += 1) {
      completedLateWindow = advanceGateWindow(completedLateWindow,
        sample(sequence, 1_174_001 + (sequence * 2_000), {tctl_c: 94}));
    }
    invariant(admittedBlockGate(
      completedLateWindow, "late-sample", 1_000_000, 1_180_000, 1_180_001
    ) === null && admittedBlockGate(
      deadlineWindow, "late-evaluation", 1_000_000, 1_180_000, 1_180_000.001
    ) === null &&
      !blockGateDeadlineExceeded({monotonic_ms: 1_180_000}, 1_180_000, 1_180_000) &&
      blockGateDeadlineExceeded({monotonic_ms: 1_180_000}, 1_179_999.999, 1_180_000) &&
      blockGateDeadlineExceeded({monotonic_ms: 1_180_001}, 1_180_001, 1_180_000) &&
      blockGateDeadlineExceeded({monotonic_ms: 1_180_000}, 1_180_000.001, 1_180_000),
      "block deadline equality semantics changed");
  });
  check("child-window-boundaries", () => {
    const boundary = (total, idle, tctl = 99_999) => ({
      observed_at: "2026-08-24T00:00:00.000Z", monotonic_ms: Number(total),
      proc_stat_cpu_line: `cpu2 ${total} 0 0 ${idle} 0 0 0 0 0 0`,
      counters: [total, "0", "0", idle, "0", "0", "0", "0", "0", "0"].map(String),
      total_ticks: String(total), idle_ticks: String(idle),
      tctl_raw_millicelsius: String(tctl), tctl_c: tctl / 1000,
    });
    const equality = childEnvironmentWindow(boundary(1_000, 500), boundary(1_100, 575));
    invariant(equality.cpu_busy_percent === 25 && equality.within_busy_limit &&
      equality.delta_busy_ticks === "25", "child CPU equality must pass");
    const breach = childEnvironmentWindow(boundary(1_000, 500), boundary(1_100, 574));
    invariant(breach.cpu_busy_percent === 26 && !breach.within_busy_limit,
      "child CPU strict breach must fail");
    invariant(boundary(1_000, 500, 100_000).tctl_c >= ENVIRONMENT_POLICY.invalidTctlMinimumC &&
      boundary(1_000, 500, 99_999).tctl_c < ENVIRONMENT_POLICY.invalidTctlMinimumC,
    "child Tctl boundary semantics changed");
    rejects(() => childEnvironmentWindow(boundary(1_100, 575), boundary(1_000, 500)), /moved backwards/);
  });
  check("interruption-wakes-monitor", () => {
    let invalid = null;
    let rejected = null;
    const monitor = new EnvironmentMonitor({
      environmentJournal: "/dev/null",
      onInvalid: (reason) => { invalid = reason; },
      tctlPath: "/dev/null",
    });
    monitor.waiters.push({reject: (error) => { rejected = error; }});
    monitor.invalidateAndWake({kind: "interruption", detail: "interrupted by SIGTERM"});
    invariant(invalid?.kind === "interruption" && rejected instanceof CampaignInvalidError &&
      monitor.waiters.length === 0, "interruption did not invalidate and wake the monitor");
  });
  check("node-runtime-identity", () => {
    const runtime = nodeRuntimeIdentity();
    invariant(runtime.version === process.version && runtime.executable === path.resolve(process.execPath) &&
      typeof runtime.versions.node === "string", "Node runtime identity is incomplete");
  });
  check("incomplete-behavior-model", () => {
    const expected = ["a", "b"];
    const completion = (observed, invalidReason = null) => ({
      complete: expected.every((id) => observed.includes(id)) && observed.every((id) => expected.includes(id)) && !invalidReason,
      analysis: expected.every((id) => observed.includes(id)) && !invalidReason ? {} : null,
    });
    invariant(!completion(["a"]).complete && completion(["a"]).analysis === null, "partial campaign analyzed");
    invariant(!completion(["a", "b"], {kind: "load"}).complete &&
      completion(["a", "b"], {kind: "load"}).analysis === null, "invalid campaign analyzed");
    invariant(completion(["a", "b"]).complete, "complete campaign rejected");
  });

  const schedule = buildSchedule();
  const result = {
    artifact: "fused-json-m6-tic-campaign-self-audit",
    version: 2,
    status: "passed",
    assertions,
    performance_pairs: schedule.performance.length,
    expected_observations_per_campaign: (() => {
      // Semantic verification is a shared preflight. A formal campaign has
      // 120 performance children, 13 bounded-RSS children, and 40 diagnostics.
      const diagnostics = 2 + 3 + (6 * 2) + (6 * 2) + 3 + (4 * 2);
      return (schedule.performance.length * 3) + schedule.bounded_rss_baselines.length +
        schedule.bounded_rss_large.length + diagnostics;
    })(),
    semantic_preflight_verifications: 5,
    gates: PERFORMANCE,
    rss: RSS,
    diagnostics: DIAGNOSTICS,
  };
  console.log(JSON.stringify(result, null, 2));
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.selfAudit) {
    runSelfAudit();
    return;
  }
  if (options.mode === "preflight") {
    let preflight = null;
    try {
      preflight = new SemanticPreflight(options);
      process.on("SIGINT", () => preflight.interrupt("SIGINT"));
      process.on("SIGTERM", () => preflight.interrupt("SIGTERM"));
      await preflight.execute();
    } catch (error) {
      if (!preflight) throw error;
      preflight.state.errors.push(error.stack ?? error.message);
      preflight.state.status = "invalid";
      preflight.state.valid = false;
    } finally {
      preflight?.finalize();
    }
    if (!preflight.state.valid) process.exitCode = 1;
    return;
  }
  let campaign = null;
  try {
    campaign = new Campaign(options);
    process.on("SIGINT", () => campaign.interrupt("SIGINT"));
    process.on("SIGTERM", () => campaign.interrupt("SIGTERM"));
    await campaign.execute();
  } catch (error) {
    if (campaign) {
      campaign.state.errors.push(error.stack ?? error.message);
      if (!campaign.invalidReason) {
        campaign.invalidate({kind: error instanceof CampaignInvalidError ? "campaign_invalid" : "runner_error",
          detail: error.message});
      }
    } else {
      throw error;
    }
  } finally {
    campaign?.finalize();
  }
  if (!campaign.state.valid || !campaign.state.passed) process.exitCode = 1;
}

main().catch((error) => {
  console.error(error.stack ?? error.message);
  process.exitCode = 1;
});
