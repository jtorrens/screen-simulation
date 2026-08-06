use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=shaders/native_camera.metal");
    println!("cargo:rerun-if-changed=shaders/spatial_optics.metal");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let output = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo supplies OUT_DIR"));
    let camera_air = output.join("native_camera.air");
    let spatial_air = output.join("spatial_optics.air");
    let library = output.join("native_camera.metallib");
    let compile = Command::new("xcrun")
        .args(["-sdk", "macosx", "metal", "-c"])
        .arg("shaders/native_camera.metal")
        .arg("-o")
        .arg(&camera_air)
        .status()
        .expect("xcrun must be available for the supported macOS build");
    assert!(compile.success(), "Metal shader compilation failed");
    let spatial_compile = Command::new("xcrun")
        .args(["-sdk", "macosx", "metal", "-c"])
        .args(["-fmetal-math-mode=safe", "-ffp-contract=off"])
        .arg("shaders/spatial_optics.metal")
        .arg("-o")
        .arg(&spatial_air)
        .status()
        .expect("xcrun must be available for the supported macOS build");
    assert!(
        spatial_compile.success(),
        "spatial Metal shader compilation failed"
    );
    let link = Command::new("xcrun")
        .args(["-sdk", "macosx", "metallib"])
        .arg(&camera_air)
        .arg(&spatial_air)
        .arg("-o")
        .arg(&library)
        .status()
        .expect("xcrun must be available for the supported macOS build");
    assert!(link.success(), "Metal shader library creation failed");
}
