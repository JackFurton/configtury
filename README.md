# configtury

**Describe a machine in friendly TOML. `configtury` compiles it to Nix. Nix provisions it — reproducibly.**

Nix is the most powerful provisioning engine in existence and one of the hardest
to approach. `configtury` is a thin, config-first layer on top: you write plain
TOML describing *what you want*, and it generates a correct, standalone
[home-manager](https://github.com/nix-community/home-manager) flake. You never
have to learn the Nix language to get a reproducible environment.

```toml
# laptop.toml
[host]
name = "laptop"
username = "furjacka"
system = "aarch64-darwin"

[packages]
profiles = ["dev-base"]      # reusable bundles from the registry
install = []                 # anything extra on top

[shell]
program = "zsh"
```

Drop that file in `hosts/` and it becomes a flake output automatically:

```console
$ nix run home-manager/master -- switch --flake .#laptop
```

No CLI to install, no codegen step — `flake.nix` reads the TOML and feeds it
straight into the home-manager / NixOS module systems.

## Why this can scale

The product is **almost entirely config files**, and that's the point:

- **The registry is the database.** Every package and profile is a tiny `.toml`
  under `registry/`. Adding support for a new tool is a 4-line file + a PR — the
  contribution surface is trivially small, which is how awesome-lists and
  `schemastore` grew to thousands of entries.
- **Profiles make specs compose** instead of repeat. `dev-base` today; `rust`,
  `data-science`, `web` tomorrow — each just a list of package names.
- **There is no compiler to maintain** because all the real complexity lives in
  Nix. We feed config into the module system; Nix does the provisioning.

## Usage

Add a `<name>.toml` to `hosts/`, then build the matching flake output:

```console
# inspect what a host resolves to
nix eval .#nixosConfigurations.homelab.config.networking.hostName

# build a whole machine's system closure
nix build .#nixosConfigurations.homelab.config.system.build.toplevel

# apply
sudo nixos-rebuild switch --flake .#homelab          # NixOS
nix run home-manager/master -- switch --flake .#laptop   # home-manager
```

Validate everything evaluates with `nix flake check`.

## Two targets

`[host].target` decides what configtury emits:

| Target | Emits | Scope |
|---|---|---|
| `home` (default) | `flake.nix` + `home.nix` | your user environment (home-manager) |
| `nixos` | `flake.nix` + `configuration.nix` | the **whole machine** (services, users, boot) |

A `nixos` spec describes a server, not an account:

```toml
[host]
name = "homelab"
system = "x86_64-linux"
target = "nixos"

[boot]
loader = "systemd-boot"      # or "grub" with device = "/dev/sda"

[disk]
device = "/dev/vda"          # disko partitions + formats it; fileSystems auto-generated
filesystem = "ext4"

[packages]
profiles = ["dev-base"]      # system-wide packages

[services]
enable = ["openssh", "tailscale", "docker", "jellyfin"]

[users.jack]
groups = ["wheel", "docker"]
```

```console
$ sudo nixos-rebuild switch --flake .#homelab
```

A `[disk]` section makes it a *complete, bootable* machine: disko partitions
and formats the device and auto-generates `fileSystems`, so there's no
hand-written `hardware-configuration.nix` to babysit.

### Flashable images

Add an `[image]` section and the host also builds into a flashable artifact:

```toml
[image]
format = "sd-aarch64"   # also: iso, qcow, raw, vm, ...
```

```console
# e.g. an SD image to flash to a Raspberry Pi, or an ISO, or a qcow2 for a VPS
$ nix build .#packages.aarch64-linux.vmlab
```

The chosen format owns disk layout + bootloader, so the same TOML targets a
running NixOS host *or* an image, from one spec.

> Format note: `sd-aarch64` and `iso` are assembled with plain filesystem tools,
> so they build anywhere. `qcow`/`raw` install via a throwaway VM and therefore
> need a **KVM-capable builder** (`requiredSystemFeatures = ["kvm"]`).

## Roadmap — climbing toward the metal

- [x] v0: packages + profiles + shell → home-manager flake
- [x] **NixOS system target**: services + users + boot → `configuration.nix`
- [x] **disko disk layout**: `[disk]` → GPT partitioning + auto-generated `fileSystems`
- [x] **flashable images**: `[image]` → qcow / iso / sd-aarch64 / raw via nixos-generators
- [ ] nixos-anywhere (install a declared OS onto remote bare metal over SSH)
- [ ] Service options (ports, config), not just `enable`
- [ ] Migrate image builds to the upstreamed `system.build.images` (nixpkgs ≥ 25.05)
- [ ] Hosted registry browser (static site generated *from* the registry)

## How it's built (Nix-native core)

configtury is written in Nix itself. There is no string-templating "compiler":
`builtins.fromTOML` reads your spec and feeds it straight into the NixOS /
home-manager module systems, which do the merging, typing, and validation.

```
flake.nix           entry point; scans hosts/ -> nixos/home Configurations
lib/default.nix     reads registry + specs, builds modules per target
registry/           the database: packages/, profiles/, services/ — all TOML
hosts/              your machines, one TOML each
```

Drop a TOML in `hosts/`, and the matching config appears as a flake output:

```console
# whole-machine (NixOS)
sudo nixos-rebuild switch --flake .#homelab

# user environment (home-manager)
nix run home-manager/master -- switch --flake .#laptop
```

### Why Nix-native

- **No escaping bugs.** We set option *values*, not generate source text.
- **Free validation.** Unknown options, type errors, conflicts → caught by the
  module system, not by us.
- **Composable services.** Each enabled service is a one-line module; Nix merges
  them. Adding one is still a 4-line TOML PR to `registry/services/`.

MIT.
