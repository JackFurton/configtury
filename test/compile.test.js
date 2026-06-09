import { test } from "node:test";
import assert from "node:assert/strict";
import { compile } from "../src/compile.js";
import { emitFlake, emitHome, emitNixosFlake, emitConfiguration } from "../src/emit.js";

const registry = {
  packages: new Map([
    ["git", { name: "git", nixpkg: "git" }],
    ["ripgrep", { name: "ripgrep", nixpkg: "ripgrep" }],
    ["bat", { name: "bat", nixpkg: "bat" }],
  ]),
  profiles: new Map([
    ["base", { name: "base", packages: ["git", "ripgrep"] }],
  ]),
  services: new Map([
    ["openssh", { name: "openssh", enable: "services.openssh.enable" }],
    ["docker", { name: "docker", enable: "virtualisation.docker.enable" }],
  ]),
};

test("expands profiles and dedupes against explicit packages", () => {
  const plan = compile(
    {
      host: { name: "h", username: "u", system: "x86_64-linux" },
      profiles: ["base"],
      packages: { install: ["bat", "git"] }, // git already in profile
    },
    registry,
  );
  assert.deepEqual(plan.nixpkgs, ["bat", "git", "ripgrep"]); // sorted + deduped
  assert.equal(plan.homeDirectory, "/home/u"); // linux home
});

test("reads profiles nested under [packages] (TOML-scoping safe)", () => {
  const plan = compile(
    {
      host: { name: "h", username: "u" },
      packages: { profiles: ["base"], install: ["bat"] },
    },
    registry,
  );
  assert.deepEqual(plan.nixpkgs, ["bat", "git", "ripgrep"]);
});

test("infers darwin home directory", () => {
  const plan = compile(
    { host: { name: "h", username: "u", system: "aarch64-darwin" }, packages: { install: ["git"] } },
    registry,
  );
  assert.equal(plan.homeDirectory, "/Users/u");
});

test("rejects unknown packages with a helpful message", () => {
  assert.throws(
    () => compile({ host: { name: "h", username: "u" }, packages: { install: ["nope"] } }, registry),
    /unknown package\(s\): nope/,
  );
});

test("requires host name and username", () => {
  assert.throws(() => compile({ packages: { install: [] } }, registry), /needs a name/);
});

test("emitted nix contains username, packages, and shell", () => {
  const plan = compile(
    { host: { name: "h", username: "u" }, packages: { install: ["git"] }, shell: { program: "zsh" } },
    registry,
  );
  const home = emitHome(plan);
  assert.match(home, /home\.username = "u"/);
  assert.match(home, /git/);
  assert.match(home, /programs\.zsh\.enable = true/);
  assert.match(emitFlake(plan), /homeConfigurations\."u"/);
});

test("nixos target compiles services, users, boot and system packages", () => {
  const plan = compile(
    {
      host: { name: "box", username: "ignored", system: "x86_64-linux", target: "nixos" },
      boot: { loader: "systemd-boot" },
      packages: { install: ["git"] },
      services: { enable: ["docker", "openssh"] },
      users: { jack: { groups: ["wheel", "docker"] } },
    },
    registry,
  );
  assert.equal(plan.target, "nixos");
  assert.deepEqual(plan.services, ["services.openssh.enable", "virtualisation.docker.enable"]);
  assert.deepEqual(plan.users, [{ name: "jack", groups: ["wheel", "docker"] }]);

  const conf = emitConfiguration(plan);
  assert.match(conf, /networking\.hostName = "box"/);
  assert.match(conf, /boot\.loader\.systemd-boot\.enable = true/);
  assert.match(conf, /services\.openssh\.enable = true/);
  assert.match(conf, /virtualisation\.docker\.enable = true/);
  assert.match(conf, /users\.users\.jack/);
  assert.match(conf, /extraGroups = \[ "wheel" "docker" \]/);
  assert.match(emitNixosFlake(plan), /nixosConfigurations\."box"/);
});

test("nixos target rejects a darwin system", () => {
  assert.throws(
    () => compile({ host: { name: "b", system: "aarch64-darwin", target: "nixos" } }, registry),
    /requires a linux system/,
  );
});

test("grub loader requires a device", () => {
  assert.throws(
    () => compile({ host: { name: "b", system: "x86_64-linux", target: "nixos" }, boot: { loader: "grub" } }, registry),
    /requires a device/,
  );
});

test("unknown service is rejected", () => {
  assert.throws(
    () => compile({ host: { name: "b", system: "x86_64-linux", target: "nixos" }, services: { enable: ["nope"] } }, registry),
    /unknown service\(s\): nope/,
  );
});
