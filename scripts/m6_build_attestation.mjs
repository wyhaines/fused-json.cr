#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {spawnSync} from "node:child_process";

const ARTIFACT = "fused-json-m6-build-attestation";
const VERSION = 1;
const GIT = "/usr/bin/git";
const ARTIFACT_SPECS = Object.freeze({
  tic_fixture: {source: "bench/tic_fixture.cr", commandOption: "tic-fixture-command"},
  tic_bench: {source: "bench/tic.cr", commandOption: "tic-bench-command"},
  parse_bench: {source: "bench/parse.cr", commandOption: "parse-bench-command"},
});

function usage(exitCode = 64) {
  console.error([
    "usage: scripts/m6_build_attestation.mjs",
    "       --repo=PATH --crystal=PATH",
    "       --tic-fixture=PATH --tic-bench=PATH --parse-bench=PATH",
    "       --tic-fixture-command='COMMAND'",
    "       --tic-bench-command='COMMAND'",
    "       --parse-bench-command='COMMAND'",
    "       --output=/new/attestation.json",
    "       scripts/m6_build_attestation.mjs --self-audit",
  ].join("\n"));
  process.exit(exitCode);
}

function parseArguments(argv) {
  if (argv.length === 1 && argv[0] === "--self-audit") return {selfAudit: true};
  const allowed = new Set([
    "repo", "crystal", "tic-fixture", "tic-bench", "parse-bench",
    "tic-fixture-command", "tic-bench-command", "parse-bench-command", "output",
  ]);
  const values = {};
  for (const argument of argv) {
    const match = argument.match(/^--([^=]+)=(.*)$/s);
    if (!match || !allowed.has(match[1]) || Object.hasOwn(values, match[1]) || !match[2]) usage();
    values[match[1]] = match[2];
  }
  if ([...allowed].some((name) => !values[name])) usage();
  return {
    selfAudit: false,
    repo: path.resolve(values.repo),
    crystal: path.resolve(values.crystal),
    artifactPaths: {
      tic_fixture: path.resolve(values["tic-fixture"]),
      tic_bench: path.resolve(values["tic-bench"]),
      parse_bench: path.resolve(values["parse-bench"]),
    },
    commands: {
      tic_fixture: values["tic-fixture-command"],
      tic_bench: values["tic-bench-command"],
      parse_bench: values["parse-bench-command"],
    },
    output: path.resolve(values.output),
  };
}

function invariant(condition, message) {
  if (!condition) throw new Error(message);
}

function isCommit(value) {
  return typeof value === "string" && /^[0-9a-f]{40}$/.test(value);
}

function isSha256(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
}

function requireSafeInteger(value, label, minimum = 0) {
  invariant(Number.isSafeInteger(value) && value >= minimum,
    `${label}: expected a safe integer >= ${minimum}`);
  return value;
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function statSnapshot(file) {
  const stat = fs.statSync(file, {bigint: true});
  invariant(stat.isFile(), `${file} is not a regular file`);
  invariant(stat.size <= BigInt(Number.MAX_SAFE_INTEGER), `${file} is too large for a JSON byte count`);
  return {
    device: stat.dev.toString(),
    inode: stat.ino.toString(),
    bytes: Number(stat.size),
    mtime_ns: stat.mtimeNs.toString(),
    ctime_ns: stat.ctimeNs.toString(),
    mode_octal: (Number(stat.mode) & 0o7777).toString(8).padStart(4, "0"),
  };
}

function sameStat(left, right) {
  return ["device", "inode", "bytes", "mtime_ns", "ctime_ns", "mode_octal"]
    .every((field) => left[field] === right[field]);
}

function fileIdentity(file, {requireExecutable = false} = {}) {
  const requestedPath = path.resolve(file);
  const realpath = fs.realpathSync(requestedPath);
  const before = statSnapshot(realpath);
  if (requireExecutable) {
    invariant((Number.parseInt(before.mode_octal, 8) & 0o111) !== 0,
      `${requestedPath} is not executable`);
  }
  const digest = sha256(realpath);
  const after = statSnapshot(realpath);
  invariant(sameStat(before, after), `file changed while hashing: ${requestedPath}`);
  return {path: requestedPath, realpath, ...before, sha256: digest, executable: requireExecutable ? true : undefined};
}

function assertIdentityUnchanged(identity) {
  const current = fileIdentity(identity.path, {requireExecutable: identity.executable === true});
  invariant(sameStat(identity, current) && identity.sha256 === current.sha256,
    `file identity changed: ${identity.path}`);
}

function run(command, arguments_, {cwd, label}) {
  const result = spawnSync(command, arguments_, {
    cwd,
    encoding: "utf8",
    env: {...process.env, LANG: "C", LC_ALL: "C", TZ: "UTC"},
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error && !(result.status === 0 && result.signal === null)) {
    throw new Error(`${label}: ${result.error.message}`);
  }
  invariant(result.signal === null && result.status === 0,
    `${label} failed: exit=${result.status} signal=${result.signal}; ${result.stderr.trim()}`);
  return {stdout: result.stdout, stderr: result.stderr};
}

function git(repo, arguments_, label) {
  return run(GIT, arguments_, {cwd: repo, label}).stdout.trim();
}

function gitSnapshot(repo) {
  const root = fs.realpathSync(git(repo, ["rev-parse", "--show-toplevel"], "resolve Git root"));
  invariant(root === fs.realpathSync(repo), `--repo must be the Git root: ${root}`);
  const head = git(repo, ["rev-parse", "HEAD"], "read Git HEAD");
  const tree = git(repo, ["rev-parse", "HEAD^{tree}"], "read Git tree");
  const status = git(repo, ["status", "--porcelain=v1", "--untracked-files=all"], "read Git status");
  const branch = git(repo, ["rev-parse", "--abbrev-ref", "HEAD"], "read Git branch");
  invariant(isCommit(head), `malformed Git HEAD: ${head}`);
  invariant(/^[0-9a-f]{40}$/.test(tree), `malformed Git tree: ${tree}`);
  return {root, head, tree, branch, clean: status === "", status_porcelain: status};
}

function sameGitSnapshot(left, right) {
  return left.root === right.root && left.head === right.head && left.tree === right.tree &&
    left.branch === right.branch && left.clean === right.clean &&
    left.status_porcelain === right.status_porcelain;
}

function parseCrystalVersion(raw) {
  const crystal = raw.match(/^Crystal\s+(\S+)(?:\s+\[([0-9a-f]+)\])?/m);
  const llvm = raw.match(/^LLVM:\s*(\S(?:.*\S)?)\s*$/m);
  const target = raw.match(/^Default target:\s*(\S+)\s*$/m);
  invariant(crystal && llvm && target, `could not parse Crystal version output:\n${raw}`);
  return {
    crystal_version: crystal[1],
    crystal_build_commit: crystal[2] ?? null,
    llvm_version: llvm[1],
    target: target[1],
    version_output: raw.trim(),
  };
}

function commandForValidation(command) {
  invariant(typeof command === "string" && command.length > 0 && !/[\0\r\n]/.test(command),
    "build commands must be nonempty single-line strings");
  return command;
}

function validateBuildCommand(name, command, artifactPath) {
  const spec = ARTIFACT_SPECS[name];
  const value = commandForValidation(command);
  invariant(value.includes(spec.source), `${name} build command does not name ${spec.source}`);
  invariant(value.includes("--release") && value.includes("--no-debug"),
    `${name} build command must include --release and --no-debug`);
  invariant(value.includes("-o") && value.includes(artifactPath),
    `${name} build command does not bind output ${artifactPath}`);
  invariant(!/(?:^|\s)--target(?:=|\s)/.test(value),
    `${name} build command uses --target but the attestation records the compiler default target`);
  return value;
}

function isInside(parent, candidate) {
  const relative = path.relative(parent, candidate);
  return relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== "..");
}

function fsyncDirectory(directory) {
  try {
    const descriptor = fs.openSync(directory, "r");
    try { fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
  } catch {
    // File fsync remains authoritative when directory fsync is unavailable.
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
  } finally {
    fs.unlinkSync(temporary);
  }
  fsyncDirectory(parent);
}

function validateAttestation(attestation) {
  invariant(attestation?.artifact === ARTIFACT && attestation.version === VERSION,
    "wrong build-attestation schema");
  invariant(isCommit(attestation.commit), "malformed attested commit");
  invariant(attestation.git?.clean === true && attestation.git.head === attestation.commit &&
    attestation.git.status_porcelain === "" && /^[0-9a-f]{40}$/.test(attestation.git.tree),
  "attestation does not bind a clean matching Git HEAD/tree");
  invariant(Array.isArray(attestation.commands) && attestation.commands.length === 3,
    "attestation must contain exactly three build command strings");
  for (const [index, name] of Object.keys(ARTIFACT_SPECS).entries()) {
    const binary = attestation.artifacts?.[name];
    invariant(binary && isSha256(binary.sha256) && typeof binary.path === "string",
      `attestation is missing ${name} identity`);
    requireSafeInteger(binary.bytes, `${name} bytes`, 1);
    validateBuildCommand(name, attestation.commands[index], binary.path);
    const source = attestation.source?.entrypoints?.[name];
    invariant(source?.path === ARTIFACT_SPECS[name].source && isSha256(source.sha256),
      `attestation is missing ${name} source identity`);
  }
  for (const field of ["crystal_version", "llvm_version", "target"]) {
    invariant(typeof attestation.toolchain?.[field] === "string" && attestation.toolchain[field],
      `attestation is missing toolchain.${field}`);
  }
  invariant(isSha256(attestation.tools?.generator?.sha256) && isSha256(attestation.tools?.crystal?.sha256) &&
    isSha256(attestation.tools?.node?.sha256), "attestation is missing tool identities");
  return attestation;
}

function generate(options) {
  invariant(!fs.existsSync(options.output), `output already exists: ${options.output}`);
  const outputParent = path.dirname(options.output);
  invariant(fs.statSync(outputParent).isDirectory(), `output parent is not a directory: ${outputParent}`);
  const repo = fs.realpathSync(options.repo);
  const effectiveOutput = path.join(fs.realpathSync(outputParent), path.basename(options.output));
  invariant(!isInside(repo, effectiveOutput), "attestation output must be outside the repository");
  const uniqueArtifacts = new Set(Object.values(options.artifactPaths).map((file) => fs.realpathSync(file)));
  invariant(uniqueArtifacts.size === Object.keys(ARTIFACT_SPECS).length,
    "formal binary paths must identify three distinct files");

  const gitBefore = gitSnapshot(repo);
  invariant(gitBefore.clean, `repository is not clean:\n${gitBefore.status_porcelain}`);
  const commands = Object.keys(ARTIFACT_SPECS).map((name) =>
    validateBuildCommand(name, options.commands[name], options.artifactPaths[name]));
  const artifacts = Object.fromEntries(Object.keys(ARTIFACT_SPECS).map((name) => [
    name, fileIdentity(options.artifactPaths[name], {requireExecutable: true}),
  ]));
  const sourceEntrypoints = Object.fromEntries(Object.entries(ARTIFACT_SPECS).map(([name, spec]) => {
    const identity = fileIdentity(path.join(repo, spec.source));
    return [name, {path: spec.source, bytes: identity.bytes, sha256: identity.sha256}];
  }));
  const crystalIdentity = fileIdentity(options.crystal, {requireExecutable: true});
  const toolchain = parseCrystalVersion(
    run(crystalIdentity.path, ["--version"], {cwd: repo, label: "read Crystal toolchain"}).stdout
  );
  assertIdentityUnchanged(crystalIdentity);
  const generatorIdentity = fileIdentity(process.argv[1]);
  const nodeIdentity = fileIdentity(process.execPath, {requireExecutable: true});
  const gitIdentity = fileIdentity(GIT, {requireExecutable: true});
  const gitAfter = gitSnapshot(repo);
  invariant(gitAfter.clean && sameGitSnapshot(gitBefore, gitAfter),
    "Git HEAD, tree, branch, or cleanliness changed while creating the attestation");
  for (const identity of Object.values(artifacts)) assertIdentityUnchanged(identity);

  return validateAttestation({
    artifact: ARTIFACT,
    version: VERSION,
    created_at: new Date().toISOString(),
    commit: gitBefore.head,
    git: gitBefore,
    commands,
    command_artifacts: Object.fromEntries(Object.keys(ARTIFACT_SPECS).map((name, index) => [name, index])),
    toolchain,
    source: {
      git_tree: gitBefore.tree,
      entrypoints: sourceEntrypoints,
    },
    artifacts,
    tools: {
      generator: generatorIdentity,
      node: nodeIdentity,
      crystal: crystalIdentity,
      git: gitIdentity,
      node_version: process.version,
    },
  });
}

function runSelfAudit() {
  const assertions = [];
  const check = (name, callback) => { callback(); assertions.push(name); };
  const rejects = (callback, pattern) => {
    let error = null;
    try { callback(); } catch (exception) { error = exception; }
    invariant(error && pattern.test(error.message), `expected rejection ${pattern}, got ${error?.message}`);
  };
  check("crystal-version-parser", () => {
    const parsed = parseCrystalVersion(
      "Crystal 1.22.0-dev [6c6a5e988] (2026-08-22)\n\nLLVM: 21.1.8\nDefault target: x86_64-pc-linux-gnu\n"
    );
    invariant(parsed.crystal_version === "1.22.0-dev" && parsed.crystal_build_commit === "6c6a5e988" &&
      parsed.llvm_version === "21.1.8" && parsed.target === "x86_64-pc-linux-gnu",
    "Crystal version fields were parsed incorrectly");
  });
  check("build-command-validation", () => {
    validateBuildCommand("tic_bench",
      "crystal build --release --no-debug bench/tic.cr -o /tmp/tic-bench", "/tmp/tic-bench");
    rejects(() => validateBuildCommand("tic_bench",
      "crystal build bench/tic.cr -o /tmp/tic-bench", "/tmp/tic-bench"), /--release/);
    rejects(() => validateBuildCommand("tic_bench",
      "crystal build --release --no-debug --target=x bench/tic.cr -o /tmp/tic-bench", "/tmp/tic-bench"),
    /--target/);
  });
  check("accepted-schema", () => {
    const identity = (name, source) => ({
      path: `/tmp/${name}`, bytes: 123, sha256: "a".repeat(64),
      source: {path: source, sha256: "b".repeat(64)},
    });
    const fixture = identity("tic-fixture", ARTIFACT_SPECS.tic_fixture.source);
    const tic = identity("tic-bench", ARTIFACT_SPECS.tic_bench.source);
    const parse = identity("parse-bench", ARTIFACT_SPECS.parse_bench.source);
    validateAttestation({
      artifact: ARTIFACT,
      version: VERSION,
      commit: "c".repeat(40),
      git: {clean: true, head: "c".repeat(40), tree: "d".repeat(40), status_porcelain: ""},
      commands: [
        `crystal build --release --no-debug ${fixture.source.path} -o ${fixture.path}`,
        `crystal build --release --no-debug ${tic.source.path} -o ${tic.path}`,
        `crystal build --release --no-debug ${parse.source.path} -o ${parse.path}`,
      ],
      toolchain: {crystal_version: "1.22", llvm_version: "21", target: "x86_64"},
      source: {entrypoints: {
        tic_fixture: fixture.source, tic_bench: tic.source, parse_bench: parse.source,
      }},
      artifacts: {tic_fixture: fixture, tic_bench: tic, parse_bench: parse},
      tools: {
        generator: {sha256: "e".repeat(64)},
        crystal: {sha256: "f".repeat(64)},
        node: {sha256: "1".repeat(64)},
      },
    });
  });
  check("file-identity", () => {
    const identity = fileIdentity(process.execPath, {requireExecutable: true});
    invariant(identity.bytes > 0 && isSha256(identity.sha256) && identity.executable === true,
      "executable identity is incomplete");
    assertIdentityUnchanged(identity);
  });
  console.log(JSON.stringify({
    artifact: `${ARTIFACT}-generator-self-audit`,
    version: VERSION,
    status: "passed",
    assertions,
    required_artifacts: Object.keys(ARTIFACT_SPECS),
    accepted_schema: {
      artifact: ARTIFACT,
      version: VERSION,
      required_toolchain_fields: ["crystal_version", "llvm_version", "target"],
    },
  }, null, 2));
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.selfAudit) return runSelfAudit();
  const attestation = generate(options);
  writeDurableAtomicNew(options.output, `${JSON.stringify(attestation, null, 2)}\n`);
  console.log(JSON.stringify({
    artifact: `${ARTIFACT}-generator-result`,
    version: VERSION,
    status: "written",
    output: options.output,
    output_sha256: sha256(options.output),
    commit: attestation.commit,
    artifact_sha256: Object.fromEntries(Object.entries(attestation.artifacts)
      .map(([name, identity]) => [name, identity.sha256])),
  }, null, 2));
}

try {
  main();
} catch (error) {
  console.error(error.stack ?? error.message);
  process.exitCode = 1;
}
