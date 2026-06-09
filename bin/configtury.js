#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parse as parseToml } from "smol-toml";
import { loadRegistry } from "../src/registry.js";
import { compile } from "../src/compile.js";
import { emitFlake, emitHome, emitNixosFlake, emitConfiguration } from "../src/emit.js";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const REGISTRY = join(ROOT, "registry");

function loadSpec(path) {
  return parseToml(readFileSync(path, "utf8"));
}

function cmdBuild(args) {
  const specPath = args[0];
  if (!specPath) die("usage: configtury build <spec.toml> [--out <dir>]");
  const outIdx = args.indexOf("--out");
  const outDir = outIdx !== -1 ? args[outIdx + 1] : "out";

  const plan = compile(loadSpec(specPath), loadRegistry(REGISTRY));
  mkdirSync(outDir, { recursive: true });

  if (plan.target === "nixos") {
    writeFileSync(join(outDir, "flake.nix"), emitNixosFlake(plan));
    writeFileSync(join(outDir, "configuration.nix"), emitConfiguration(plan));
    console.log(`✓ compiled NixOS system "${plan.name}" -> ${outDir}/`);
    console.log(`  ${plan.nixpkgs.length} package(s), ${plan.services.length} service(s), ${plan.users.length} user(s)`);
    console.log(`\nApply it on a NixOS machine:`);
    console.log(`  sudo nixos-rebuild switch --flake ${outDir}#${plan.name}`);
  } else {
    writeFileSync(join(outDir, "flake.nix"), emitFlake(plan));
    writeFileSync(join(outDir, "home.nix"), emitHome(plan));
    console.log(`✓ compiled home environment "${plan.name}" -> ${outDir}/`);
    console.log(`  ${plan.nixpkgs.length} package(s), system ${plan.system}`);
    console.log(`\nApply it on a machine with Nix:`);
    console.log(`  cd ${outDir} && nix run home-manager/master -- switch --flake .#${plan.username}`);
  }
}

function cmdCheck(args) {
  const specPath = args[0];
  if (!specPath) die("usage: configtury check <spec.toml>");
  const plan = compile(loadSpec(specPath), loadRegistry(REGISTRY));
  console.log(`✓ "${plan.name}" is valid — ${plan.nixpkgs.length} package(s) resolved.`);
}

function cmdList() {
  const reg = loadRegistry(REGISTRY);
  console.log("packages:");
  for (const p of [...reg.packages.values()].sort((a, b) => a.name.localeCompare(b.name))) {
    console.log(`  ${p.name.padEnd(14)} ${p.description}`);
  }
  console.log("\nprofiles:");
  for (const pr of reg.profiles.values()) {
    console.log(`  ${pr.name.padEnd(14)} ${pr.description} [${pr.packages.join(", ")}]`);
  }
  console.log("\nservices (nixos target):");
  for (const s of [...reg.services.values()].sort((a, b) => a.name.localeCompare(b.name))) {
    console.log(`  ${s.name.padEnd(14)} ${s.description}`);
  }
}

function die(msg) {
  console.error(msg);
  process.exit(1);
}

const [cmd, ...rest] = process.argv.slice(2);
try {
  switch (cmd) {
    case "build": cmdBuild(rest); break;
    case "check": cmdCheck(rest); break;
    case "list": cmdList(); break;
    default:
      die("configtury <command>\n\n  build <spec.toml> [--out dir]   compile a spec to Nix\n  check <spec.toml>               validate a spec against the registry\n  list                            show available packages & profiles");
  }
} catch (err) {
  die(`error: ${err.message}`);
}
