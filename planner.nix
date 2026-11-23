pkgs: pkgs.rustPlatform.buildRustPackage {
  pname = "drvcpp-plan";
  version = "0.1.0";
  src = ./planner;
  cargoLock.lockFile = ./planner/Cargo.lock;
}
