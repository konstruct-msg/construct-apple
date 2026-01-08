fn main() {
    // Allow unsafe attributes for UniFFI 0.28 on Rust 1.82+
    println!("cargo:rustc-env=RUSTFLAGS=-A unsafe-attr-outside-unsafe");

    // Generate UniFFI bindings
    uniffi::generate_scaffolding("src/construct_core.udl").unwrap();

    // Rerun if UDL file changes
    println!("cargo:rerun-if-changed=src/construct_core.udl");
}
