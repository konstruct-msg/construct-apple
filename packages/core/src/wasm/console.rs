#[cfg(target_arch = "wasm32")]
pub fn init_logging() {
    // Базовая инициализация логирования для WASM
    // В будущем можно добавить tracing_subscriber
    log("Construct Messenger WASM initialized");
}

#[cfg(target_arch = "wasm32")]
pub fn log(message: &str) {
    web_sys::console::log_1(&message.into());
}

#[cfg(target_arch = "wasm32")]
pub fn error(message: &str) {
    web_sys::console::error_1(&message.into());
}
