# configtury core, written in Nix itself.
#
# The whole "compiler" is gone: we read the friendly TOML with builtins.fromTOML
# and feed it straight into the NixOS / home-manager module systems. No string
# templating, no manual escaping — the module system does the merging, typing,
# and validation for us. Each enabled service is just a tiny module; Nix merges
# them. That's the payoff of going native.
{ nixpkgs, home-manager, disko, nixos-generators, nixos-anywhere }:
let
  lib = nixpkgs.lib;

  # ---- registry: TOML stays the contribution surface (4-line PRs) ----
  readTomlDir = dir:
    if !(builtins.pathExists dir)
    then [ ]
    else
      let
        entries = builtins.readDir dir;
        tomls = lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".toml" n) entries;
      in
      lib.mapAttrsToList
        (name: _: builtins.fromTOML (builtins.readFile (dir + "/${name}")))
        tomls;

  mkRegistry = root: {
    packages = lib.listToAttrs
      (map (d: lib.nameValuePair d.package.name d.package) (readTomlDir (root + "/registry/packages")));
    profiles = lib.listToAttrs
      (map (d: lib.nameValuePair d.profile.name d.profile) (readTomlDir (root + "/registry/profiles")));
    services = lib.listToAttrs
      (map (d: lib.nameValuePair d.service.name d.service) (readTomlDir (root + "/registry/services")));
  };

  # ---- resolution + validation (errors instead of bogus output) ----
  resolvePkgNames = registry: spec:
    let
      profileNames = spec.packages.profiles or [ ];
      fromProfiles = lib.concatMap
        (pn:
          let p = registry.profiles.${pn} or (throw "configtury: unknown profile '${pn}'");
          in p.packages or [ ])
        profileNames;
      explicit = spec.packages.install or [ ];
      all = lib.unique (fromProfiles ++ explicit);
      unknown = lib.filter (n: !(registry.packages ? ${n})) all;
    in
    if unknown != [ ]
    then throw "configtury: unknown package(s): ${lib.concatStringsSep ", " unknown}"
    else all;

  pkgAttr = registry: name: registry.packages.${name}.nixpkg;

  # Services support two forms, which compose:
  #   [services] enable = ["openssh", "docker"]       # simple on/off
  #   [services.openssh] ports = [2222]               # enable + set options
  #     settings = { PermitRootLogin = "no" }
  # A registry service declares a `prefix` (e.g. "services.openssh"); every key
  # under [services.<name>] maps to "<prefix>.<key>", so any NixOS option on
  # that service is reachable from TOML. setAttrByPath builds the nested attrs
  # and the module system merges everything.
  serviceModules = registry: spec:
    let
      svc = spec.services or { };
      simple = svc.enable or [ ];
      tables = removeAttrs svc [ "enable" ]; # [services.<name>] option tables
      names = lib.unique (simple ++ lib.attrNames tables);
      prefixOf = name:
        let s = registry.services.${name} or (throw "configtury: unknown service '${name}'");
        in lib.splitString "." s.prefix;
    in
    lib.concatMap
      (name:
        let
          prefix = prefixOf name;
          opts = tables.${name} or { };
          enableVal = if opts ? enable then opts.enable else true;
          optKeys = removeAttrs opts [ "enable" ];
        in
        [ (lib.setAttrByPath (prefix ++ [ "enable" ]) enableVal) ]
        ++ lib.mapAttrsToList (k: v: lib.setAttrByPath (prefix ++ [ k ]) v) optKeys)
      names;

  usersModule = spec: {
    users.users = lib.mapAttrs
      (_: cfg: {
        isNormalUser = true;
        extraGroups = cfg.groups or [ ];
      })
      (spec.users or { });
  };

  bootModule = spec:
    let
      boot = spec.boot or { };
      loader = boot.loader or "systemd-boot";
    in
    if loader == "grub"
    then {
      boot.loader.grub.enable = true;
      boot.loader.grub.device = boot.device or (throw "configtury: grub loader needs [boot].device");
    }
    else {
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
    };

  # ---- rung 2: declarative disk layout (disko) ----
  # A [disk] section turns an OS-minus-its-disk into a complete, bootable
  # machine: disko formats the device AND auto-generates fileSystems.* for us.
  # v0 = GPT with an ESP (/boot) + a root partition filling the rest.
  diskoModule = spec:
    let
      disk = spec.disk;
      device = disk.device or (throw "configtury: [disk] needs a device, e.g. device = \"/dev/vda\"");
      rootFs = disk.filesystem or "ext4";
    in
    {
      disko.devices.disk.main = {
        inherit device;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; };
            };
            root = {
              size = "100%";
              content = { type = "filesystem"; format = rootFs; mountpoint = "/"; };
            };
          };
        };
      };
    };

  homeDirFor = system: user:
    if lib.hasSuffix "darwin" system then "/Users/${user}" else "/home/${user}";

  # Everything that describes the machine itself: identity, who can log in,
  # what's installed, what runs. Shared by the real-machine build AND the
  # image build — boot loader and disk layout are layered on separately.
  coreNixosModules = registry: name: spec: [
    {
      networking.hostName = name;
      system.stateVersion = spec.host.stateVersion or "24.05";
    }
    (usersModule spec)
    ({ pkgs, ... }: {
      environment.systemPackages =
        map (n: pkgs.${pkgAttr registry n}) (resolvePkgNames registry spec);
    })
  ] ++ serviceModules registry spec;

  # ---- the targets ----
  mkNixos = registry: name: spec:
    if !(lib.hasSuffix "linux" (spec.host.system or "x86_64-linux"))
    then throw "configtury: nixos target '${name}' requires a linux system"
    else nixpkgs.lib.nixosSystem {
      system = spec.host.system or "x86_64-linux";
      modules = coreNixosModules registry name spec
        ++ [ (bootModule spec) ]
        ++ lib.optionals (spec ? disk) [ disko.nixosModules.disko (diskoModule spec) ];
    };

  # ---- rung 3: a flashable image (qcow / iso / sd-aarch64 / raw / ...) ----
  # The chosen format owns disk layout AND bootloader, so we feed it the core
  # machine modules WITHOUT our boot/disko modules (which would conflict).
  mkImage = registry: name: spec:
    nixos-generators.nixosGenerate {
      system = spec.host.system or "x86_64-linux";
      format = spec.image.format or "qcow";
      modules = coreNixosModules registry name spec;
    };

  # ---- rung 4: install a declared OS onto a remote machine over SSH ----
  # nixos-anywhere consumes nixosConfigurations.<name> (which already carries
  # the disko layout), kexecs into an installer on the target, wipes+partitions
  # the disk, and installs. We wrap it as `nix run .#deploy-<name> -- root@host`.
  # The [disk] section is what makes a host deployable, so we only emit a
  # deploy app for hosts that have one.
  mkDeployApp = system: name: spec:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      na = nixos-anywhere.packages.${system}.nixos-anywhere;
      target = spec.deploy.target or "";
      script = pkgs.writeShellScript "deploy-${name}" ''
        set -euo pipefail
        TARGET="${target}"
        if [ "$#" -gt 0 ]; then TARGET="$1"; shift; fi
        if [ -z "$TARGET" ]; then
          echo "usage: nix run .#deploy-${name} -- [user@]host"
          echo "installs nixosConfigurations.${name} onto the target (WIPES its disk)"
          exit 1
        fi
        echo ">> deploying '${name}' to $TARGET — this ERASES the target disk"
        exec ${na}/bin/nixos-anywhere --flake ".#${name}" "$@" "$TARGET"
      '';
    in
    {
      type = "app";
      program = "${script}";
    };

  mkHome = registry: name: spec:
    let
      system = spec.host.system or "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      user = spec.host.username or (throw "configtury: home target '${name}' needs [host].username");
    in
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        {
          home.username = user;
          home.homeDirectory = spec.host.homeDirectory or (homeDirFor system user);
          home.stateVersion = spec.host.stateVersion or "24.05";
          home.packages = map (n: pkgs.${pkgAttr registry n}) (resolvePkgNames registry spec);
        }
        (lib.optionalAttrs (spec ? shell) {
          programs.${spec.shell.program}.enable = true;
        })
      ];
    };

  # ---- scan hosts/*.toml -> flake outputs, partitioned by target ----
  loadSpecs = root:
    let
      dir = root + "/hosts";
      entries = if builtins.pathExists dir then builtins.readDir dir else { };
      tomls = lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".toml" n) entries;
    in
    lib.mapAttrsToList
      (fname: _: builtins.fromTOML (builtins.readFile (dir + "/${fname}")))
      tomls;

  isNixos = spec: (spec.host.target or "home") == "nixos";
in
{
  inherit mkRegistry mkNixos mkHome resolvePkgNames;

  mkOutputs = { root }:
    let
      registry = mkRegistry root;
      specs = loadSpecs root;
      nixosSpecs = lib.filter isNixos specs;
      homeSpecs = lib.filter (s: !(isNixos s)) specs;

      # Hosts that ask for an [image], grouped by their target system so they
      # land under the flat-by-system `packages` output flakes expect.
      imageSpecs = lib.filter (s: isNixos s && s ? image) specs;
      imageSystems = lib.unique (map (s: s.host.system or "x86_64-linux") imageSpecs);

      # Hosts with a [disk] are installable; each gets a deploy-<name> app.
      deploySpecs = lib.filter (s: isNixos s && s ? disk) specs;
      deploySystems = lib.unique (map (s: s.host.system or "x86_64-linux") deploySpecs);
    in
    {
      nixosConfigurations = lib.listToAttrs
        (map (s: lib.nameValuePair s.host.name (mkNixos registry s.host.name s)) nixosSpecs);
      homeConfigurations = lib.listToAttrs
        (map (s: lib.nameValuePair s.host.name (mkHome registry s.host.name s)) homeSpecs);
      packages = lib.listToAttrs (map
        (sys: lib.nameValuePair sys (lib.listToAttrs (map
          (s: lib.nameValuePair s.host.name (mkImage registry s.host.name s))
          (lib.filter (s: (s.host.system or "x86_64-linux") == sys) imageSpecs))))
        imageSystems);
      apps = lib.listToAttrs (map
        (sys: lib.nameValuePair sys (lib.listToAttrs (map
          (s: lib.nameValuePair "deploy-${s.host.name}" (mkDeployApp sys s.host.name s))
          (lib.filter (s: (s.host.system or "x86_64-linux") == sys) deploySpecs))))
        deploySystems);
    };
}
