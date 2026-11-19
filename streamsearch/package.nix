{ lib, rustPlatform, stdenv }:

rustPlatform.buildRustPackage {
  pname = "streamsearch";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.lock
      ./Cargo.toml
      ./src
      ./tests
    ];
  };

  cargoLock.lockFile = ./Cargo.lock;

  # The tests read /proc/<pid>/status for peak RSS.
  doCheck = stdenv.hostPlatform.isLinux;

  meta = {
    description = "Bounded-memory multi-threaded search for files larger than RAM";
    license = lib.licenses.mit;
    mainProgram = "streamsearch";
  };
}
