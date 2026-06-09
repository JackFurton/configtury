// Resolve a host spec against the registry into a plain, emit-ready plan.
// Two targets:
//   "home"  -> user environment (home-manager)
//   "nixos" -> whole machine (NixOS): services, users, boot, system packages

const DEFAULTS = {
  system: "aarch64-darwin",
  stateVersion: "24.05",
};

function homeDirFor(system, username) {
  return system.endsWith("darwin") ? `/Users/${username}` : `/home/${username}`;
}

// Expand profiles + explicit installs into a deduped, sorted list of nixpkgs
// attrs. Shared by both targets so package handling never diverges.
function resolvePackages(spec, registry) {
  const requested = [];
  const seen = new Set();
  const add = (name) => {
    if (!seen.has(name)) {
      seen.add(name);
      requested.push(name);
    }
  };

  const profileNames = spec.packages?.profiles ?? spec.profiles ?? [];
  for (const profName of profileNames) {
    const prof = registry.profiles.get(profName);
    if (!prof) {
      const known = [...registry.profiles.keys()].join(", ") || "(none)";
      throw new Error(`spec: unknown profile "${profName}". Known: ${known}`);
    }
    prof.packages.forEach(add);
  }
  for (const name of spec.packages?.install ?? []) add(name);

  const unknown = requested.filter((n) => !registry.packages.has(n));
  if (unknown.length) {
    const known = [...registry.packages.keys()].sort().join(", ") || "(none)";
    throw new Error(`spec: unknown package(s): ${unknown.join(", ")}.\n  Available: ${known}`);
  }

  return requested
    .map((n) => registry.packages.get(n).nixpkg)
    .sort((a, b) => a.localeCompare(b));
}

function resolveServices(spec, registry) {
  const requested = spec.services?.enable ?? [];
  const unknown = requested.filter((n) => !registry.services.has(n));
  if (unknown.length) {
    const known = [...registry.services.keys()].sort().join(", ") || "(none)";
    throw new Error(`spec: unknown service(s): ${unknown.join(", ")}.\n  Available: ${known}`);
  }
  return requested
    .map((n) => registry.services.get(n).enable)
    .sort((a, b) => a.localeCompare(b));
}

function resolveUsers(spec) {
  // [users.<name>] tables -> normal users with extra groups.
  return Object.entries(spec.users ?? {}).map(([name, cfg]) => ({
    name,
    groups: cfg?.groups ?? [],
  }));
}

function compileHome(spec, registry, host, system, stateVersion) {
  if (!host.username) throw new Error("spec: home target needs [host].username");
  return {
    target: "home",
    name: host.name,
    username: host.username,
    system,
    stateVersion,
    homeDirectory: host.homeDirectory ?? homeDirFor(system, host.username),
    nixpkgs: resolvePackages(spec, registry),
    shell: spec.shell?.program ?? null,
  };
}

function compileNixos(spec, registry, host, system, stateVersion) {
  if (!system.endsWith("linux")) {
    throw new Error(`spec: nixos target requires a linux system, got "${system}"`);
  }
  const boot = spec.boot ?? {};
  const loader = boot.loader ?? "systemd-boot";
  if (loader === "grub" && !boot.device) {
    throw new Error('spec: [boot] loader = "grub" requires a device, e.g. device = "/dev/sda"');
  }
  return {
    target: "nixos",
    name: host.name,
    system,
    stateVersion,
    nixpkgs: resolvePackages(spec, registry),
    services: resolveServices(spec, registry),
    users: resolveUsers(spec),
    boot: { loader, device: boot.device ?? null },
  };
}

export function compile(spec, registry) {
  const host = spec.host ?? {};
  if (!host.name) throw new Error("spec: [host] needs a name");

  const system = host.system ?? DEFAULTS.system;
  const stateVersion = host.stateVersion ?? DEFAULTS.stateVersion;
  const target = host.target ?? "home";

  switch (target) {
    case "home": return compileHome(spec, registry, host, system, stateVersion);
    case "nixos": return compileNixos(spec, registry, host, system, stateVersion);
    default: throw new Error(`spec: unknown target "${target}" (expected "home" or "nixos")`);
  }
}
