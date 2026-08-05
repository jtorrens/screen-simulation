use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=shaders/native_camera.metal");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let output = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo supplies OUT_DIR"));
    let air = output.join("native_camera.air");
    let library = output.join("native_camera.metallib");
    let compile = Command::new("xcrun")
        .args(["-sdk", "macosx", "metal", "-c"])
        .arg("shaders/native_camera.metal")
        .arg("-o")
        .arg(&air)
        .status()
        .expect("xcrun must be available for the supported macOS build");
    assert!(compile.success(), "Metal shader compilation failed");
    let link = Command::new("xcrun")
        .args(["-sdk", "macosx", "metallib"])
        .arg(&air)
        .arg("-o")
        .arg(&library)
        .status()
        .expect("xcrun must be available for the supported macOS build");
    assert!(link.success(), "Metal shader library creation failed");
}
