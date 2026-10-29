// Build-script stdout belongs to Cargo, never the helper's Port.
#![allow(clippy::print_stdout)]

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=src/bridge.cpp");
    println!("cargo:rerun-if-changed=../vendor/signalsmith");
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .flag("-ffp-contract=off")
        .include("../vendor/signalsmith/stretch")
        .include("../vendor/signalsmith")
        .file("src/bridge.cpp")
        .warnings(true)
        .extra_warnings(true)
        .try_compile("randos_signalsmith")?;
    Ok(())
}
