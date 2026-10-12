{
  description = "HarborReply: pinned local tools, synthetic checks, and Apple Silicon Xcode workflows";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/a7868a727837f3c09cee2ce0ca671c76b1589fed";

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;
      python = pkgs.python313;
      # Keep the check/package source public and small. Runtime state, mail archives,
      # credentials, generated apps, and caches are never derivation inputs.
      coreSource = lib.cleanSourceWith {
        src = ./.;
        filter =
          path: type:
          let
            relative = lib.removePrefix (toString ./. + "/") (toString path);
            inTree = tree: relative == tree || lib.hasPrefix (tree + "/") relative;
          in
          type == "directory"
          && (
            builtins.elem relative [
              "Sources"
              "Sources/HarborReply"
              "Sources/HarborReply/Resources"
            ]
            || inTree "Sources/HarborReply/Resources/worker"
            || inTree "Tests"
            || inTree "fixtures"
            || inTree "scripts"
          )
          ||
            type == "regular"
            && (
              relative == "scripts/Info.plist"
              || relative == "Sources/HarborReply/Resources/MailBridge.applescript"
              || inTree "Sources/HarborReply/Resources/worker" && (lib.hasSuffix ".py" relative || lib.hasSuffix ".json" relative)
              || inTree "Tests" && lib.hasSuffix ".py" relative
              || inTree "scripts" && lib.hasSuffix ".py" relative
              ||
                inTree "fixtures"
                && builtins.any (suffix: lib.hasSuffix suffix relative) [
                  ".eml"
                  ".mbox"
                  ".json"
                ]
            );
      };
      workflow =
        name:
        pkgs.writeShellApplication {
          name = "harborreply-${name}";
          runtimeInputs = [ pkgs.gh pkgs.git ];
          text = ''
            if [[ ! -f scripts/nix.sh || ! -f Package.swift ]]; then
              echo "Run this command from the HarborReply checkout." >&2
              exit 2
            fi
            export HARBOR_PYTHON=${python}/bin/python3
            exec ${pkgs.bash}/bin/bash scripts/nix.sh ${lib.escapeShellArg name} "$@"
          '';
        };
      workflows = lib.genAttrs [ "test" "build" "package" "deploy" "performance" "diagnose" ] workflow;
      worker = pkgs.stdenvNoCC.mkDerivation {
        pname = "harborreply-worker";
        version = "0.1";
        src = coreSource;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        dontBuild = true;
        installPhase = ''
          runHook preInstall
          mkdir -p "$out/lib/harborreply" "$out/bin"
          cp Sources/HarborReply/Resources/worker/*.py "$out/lib/harborreply/"
          cp Sources/HarborReply/Resources/worker/failure_codes.json "$out/lib/harborreply/"
          makeWrapper ${python}/bin/python3 "$out/bin/harborreply-worker" \
            --add-flags "-s -B $out/lib/harborreply/main.py"
          runHook postInstall
        '';
      };
      pythonTests = pkgs.runCommand "harborreply-python-tests" { nativeBuildInputs = [ python ]; } ''
        cp -R ${coreSource} source
        chmod -R u+w source
        cd source
        export PYTHONDONTWRITEBYTECODE=1
        mkdir -p "$out"
        if ! python3 -m unittest discover -s Tests -v > "$out/results.txt" 2>&1; then
          cat "$out/results.txt"
          exit 1
        fi
        tail -n 4 "$out/results.txt"
      '';
      performance = pkgs.runCommand "harborreply-performance" { nativeBuildInputs = [ python ]; } ''
        cp -R ${coreSource} source
        chmod -R u+w source
        cd source
        export PYTHONDONTWRITEBYTECODE=1
        mkdir -p "$out"
        python3 scripts/performance.py --quick --output "$out/performance.json"
      '';
      nativeIndexPerformance = pkgs.runCommand "harborreply-native-index-performance" { nativeBuildInputs = [ python ]; } ''
        cp -R ${coreSource} source
        chmod -R u+w source
        cd source
        export PYTHONDONTWRITEBYTECODE=1
        mkdir -p "$out"
        python3 scripts/index-performance.py --quick --output "$out/performance.json"
      '';
    in
    {
      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = [
          python
          pkgs.bash
          pkgs.git
          pkgs.ripgrep
          pkgs.nixfmt
        ];
        HARBOR_PYTHON = "${python}/bin/python3";
        HARBOR_SWIFT = "/usr/bin/swift";
        shellHook = ''
          echo "HarborReply tools ready. Native test/build/package require locally installed Xcode."
          echo "nix run .#test | .#build | .#package | .#deploy | .#performance"
        '';
      };
      apps.${system} =
        lib.mapAttrs (_: value: {
          type = "app";
          program = "${value}/bin/${value.name}";
          meta.description = "HarborReply repository workflow using pinned Python and host Xcode";
        }) workflows
        // {
          default = {
            type = "app";
            program = "${workflows.test}/bin/${workflows.test.name}";
            meta.description = "Run HarborReply Python and native Swift tests";
          };
        };
      # The independently reproducible local worker is a Nix package. The native
      # .app uses nix run .#build because Apple SDK/Xcode are host prerequisites.
      packages.${system} = {
        inherit worker;
        default = worker;
      };
      checks.${system} = {
        python-tests = pythonTests;
        inherit performance;
        native-index-performance = nativeIndexPerformance;
      };
      formatter.${system} = pkgs.nixfmt;
    };
}
