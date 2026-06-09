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
profiles = ["dev-base", "ops"]   # system-wide packages

[services]
enable = ["tailscale", "docker", "jellyfin"]   # simple on/off

[services.openssh]               # ...or configure: keys map to services.openssh.*
ports = [22, 2222]
[services.openssh.settings]
PermitRootLogin = "no"

[users.jack]
groups = ["wheel", "docker"]
```

Services take two forms that compose: list them in `[services] enable = [...]`
for on/off, or give a `[services.<name>]` table whose keys map straight onto
that service's NixOS options (`[services.<name>] foo = ...` → `services.<name>.foo`).

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

### Install onto a remote machine

Any host with a `[disk]` gets a `deploy-<name>` app. It uses
[nixos-anywhere](https://github.com/nix-community/nixos-anywhere) to kexec into
the target, wipe + partition the disk (via the disko layout), and install:

```console
$ nix run .#deploy-homelab -- root@1.2.3.4     # ERASES the target's disk
```

Add a default target so you can drop the argument:

```toml
[deploy]
target = "root@192.168.1.50"
```

The partitioning is real and generated from your `[disk]` spec — it's
`nixosConfigurations.<name>.config.system.build.diskoScript` (`sgdisk` + `mkfs`
on your device), the exact automation nixos-anywhere runs on the target.

## Apps (self-hosted PaaS)

The layer on top of machines: describe an **app**, and configtury runs it on a
host as a container behind an nginx reverse proxy (with optional ACME TLS). Drop
a file in `apps/`:

```toml
# apps/blog.toml
[app]
name = "blog"
host = "homelab"                 # which machine runs it
image = "ghcr.io/me/blog:latest"
port = 8080                      # loopback port nginx proxies to
container_port = 8080            # what the container listens on (defaults to port)
domain = "blog.example.com"
tls = true                       # forceSSL + auto Let's Encrypt cert
email = "me@example.com"         # ACME contact

[app.env]
DATABASE_URL = "postgres://..."
```

The app is wired into that host's config — so it ships in the host's **image**
and **remote install** automatically. One spec, deployed everywhere the host is.

## Roadmap — climbing toward the metal (and up the stack)

- [x] v0: packages + profiles + shell → home-manager flake
- [x] **NixOS system target**: services + users + boot → `configuration.nix`
- [x] **disko disk layout**: `[disk]` → GPT partitioning + auto-generated `fileSystems`
- [x] **flashable images**: `[image]` → qcow / iso / sd-aarch64 / raw via nixos-generators
- [x] **remote install**: `[disk]` → `deploy-<name>` app (nixos-anywhere over SSH)
- [x] **service options**: `[services.<name>]` keys map onto `services.<name>.*`
- [x] **apps (PaaS)**: `apps/<name>.toml` → container + nginx reverse proxy (+TLS)
- [ ] App build-from-source (git repo → image), not just prebuilt images
- [ ] Multi-app routing, health checks, zero-downtime restarts
- [ ] Migrate image builds to the upstreamed `system.build.images` (nixpkgs ≥ 25.05)
- [ ] Hosted control plane: dashboard, deploy + rollback, fleet view

## How it's built (Nix-native core)

configtury is written in Nix itself. There is no string-templating "compiler":
`builtins.fromTOML` reads your spec and feeds it straight into the NixOS /
home-manager module systems, which do the merging, typing, and validation.

```
flake.nix           entry point; scans hosts/ -> nixos/home Configurations
lib/default.nix     reads registry + specs, builds modules per target
registry/           the database: packages/, profiles/, services/ — all TOML
hosts/              your machines, one TOML each
apps/               your apps (PaaS), one TOML each → containers + proxy
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
