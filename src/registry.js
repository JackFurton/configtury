// The registry IS the database. Every file under registry/ is "all config".
// Packages map a friendly name -> a nixpkgs attribute (+ metadata).
// Profiles are named bundles of packages, so specs compose instead of repeat.
import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { parse as parseToml } from "smol-toml";

function loadTomlDir(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith(".toml"))
    .map((f) => {
      try {
        return { file: f, data: parseToml(readFileSync(join(dir, f), "utf8")) };
      } catch (err) {
        throw new Error(`registry: failed to parse ${join(dir, f)}: ${err.message}`);
      }
    });
}

export function loadRegistry(root) {
  const packages = new Map();
  for (const { file, data } of loadTomlDir(join(root, "packages"))) {
    const p = data.package;
    if (!p?.name || !p?.nixpkg) {
      throw new Error(`registry: ${file} needs [package] with name + nixpkg`);
    }
    packages.set(p.name, {
      name: p.name,
      nixpkg: p.nixpkg,
      description: p.description ?? "",
    });
  }

  const profiles = new Map();
  for (const { file, data } of loadTomlDir(join(root, "profiles"))) {
    const pr = data.profile;
    if (!pr?.name) throw new Error(`registry: ${file} needs [profile] with name`);
    profiles.set(pr.name, {
      name: pr.name,
      description: pr.description ?? "",
      packages: pr.packages ?? [],
    });
  }

  // Services map a friendly name -> the NixOS option path that turns them on,
  // e.g. "openssh" -> "services.openssh.enable". This is the OS-level registry.
  const services = new Map();
  for (const { file, data } of loadTomlDir(join(root, "services"))) {
    const s = data.service;
    if (!s?.name || !s?.enable) {
      throw new Error(`registry: ${file} needs [service] with name + enable (a NixOS option path)`);
    }
    services.set(s.name, {
      name: s.name,
      enable: s.enable,
      description: s.description ?? "",
    });
  }

  return { packages, profiles, services };
}
