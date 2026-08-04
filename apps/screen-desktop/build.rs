fn main() {
    let configuration = slint_build::CompilerConfiguration::new().with_style("fluent-dark".into());
    slint_build::compile_with_config("ui/main.slint", configuration)
        .expect("the current Slint UI must compile");
}
