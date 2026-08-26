import fs from "node:fs";
import path from "node:path";

const root = process.argv[2] || path.join(import.meta.dirname, "rejected-directional");
const profiles = new Map();
const pattern = /^pair-(\d+)-(baseline|candidate)-(.+)-(io-memory|chunked-memory)-cache-([01])\.txt$/;

for (const file of fs.readdirSync(root)) {
  const match = file.match(pattern);
  if (!match) continue;

  const [, pair, side, shape, mode, cache] = match;
  const receipt = JSON.parse(fs.readFileSync(path.join(root, file), "utf8"));
  if (
    receipt.shape !== shape ||
    receipt.mode !== mode ||
    receipt.cache_keys !== (cache === "1")
  ) {
    throw new Error(`receipt identity mismatch: ${file}`);
  }

  const key = `${shape}|${mode}|${cache}`;
  if (!profiles.has(key)) profiles.set(key, {});
  const pairs = profiles.get(key);
  pairs[pair] ||= {};
  pairs[pair][side] = receipt;
}

function geometricMean(values) {
  return Math.exp(values.reduce((sum, value) => sum + Math.log(value), 0) / values.length);
}

function median(values) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.floor(sorted.length / 2)];
}

const results = [];
const matrixRatios = [];
for (const [key, pairs] of [...profiles].sort()) {
  const [shape, mode, cache] = key.split("|");
  const ratios = [];
  const allocationDeltas = [];

  for (let pair = 1; pair <= 5; pair += 1) {
    const measurement = pairs[pair];
    if (!measurement?.baseline || !measurement?.candidate) {
      throw new Error(`missing ${key} pair ${pair}`);
    }
    if (
      measurement.baseline.source_sha256 !== measurement.candidate.source_sha256 ||
      measurement.baseline.result_sha256 !== measurement.candidate.result_sha256
    ) {
      throw new Error(`semantic digest mismatch: ${key} pair ${pair}`);
    }

    ratios.push(
      measurement.candidate.mib_per_second / measurement.baseline.mib_per_second
    );
    allocationDeltas.push(
      Number(measurement.candidate.managed_bytes_per_operation) -
        Number(measurement.baseline.managed_bytes_per_operation)
    );
  }

  matrixRatios.push(...ratios);
  results.push({
    shape,
    mode,
    cache_keys: cache === "1",
    geometric_mean_ratio: geometricMean(ratios),
    median_ratio: median(ratios),
    minimum_ratio: Math.min(...ratios),
    maximum_ratio: Math.max(...ratios),
    maximum_managed_allocation_delta: Math.max(...allocationDeltas),
    ratios,
  });
}

if (results.length !== 12 || matrixRatios.length !== 60) {
  throw new Error(`expected 12 profiles and 60 ratios, got ${results.length} and ${matrixRatios.length}`);
}

const matrixGeometricMean = geometricMean(matrixRatios);
const output = {
  schema: "fused-json-direct-tree-prototype-analysis-v1",
  root,
  profile_count: results.length,
  paired_ratio_count: matrixRatios.length,
  matrix_geometric_mean_ratio: matrixGeometricMean,
  gates: {
    matrix_at_least_1_10: matrixGeometricMean >= 1.1,
    every_profile_median_at_least_0_98: results.every(
      (result) => result.median_ratio >= 0.98
    ),
    every_managed_allocation_delta_within_4096_bytes: results.every(
      (result) => result.maximum_managed_allocation_delta <= 4096
    ),
  },
  profiles: results,
};

process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
