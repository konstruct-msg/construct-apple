use wasm_bindgen::prelude::*;
use std::collections::HashMap;
use std::sync::Mutex;
use once_cell::sync::Lazy;
use uuid::Uuid;

use crate::state::app::{AppState, ConnectionState};
use crate::crypto::suites::classic::ClassicSuiteProvider;
use crate::utils::error::{Result, ConstructError};


// Global state manager to hold AppState instances
static APP_STATES: Lazy<Mutex<HashMap<String, Mutex<AppState<ClassicSuiteProvider>>>>> = Lazy::new(|| {
    Mutex::new(HashMap::new())
});

// Internal helper to run a synchronous closure on an AppState
fn with_app_state<F, T>(state_id: &str, mut f: F) -> std::result::Result<T, ConstructError>
where
    F: FnMut(&mut AppState<ClassicSuiteProvider>) -> std::result::Result<T, ConstructError>,
{
    let states = APP_STATES.lock().unwrap();
    if let Some(state_mutex) = states.get(state_id) {
        let mut state = state_mutex.lock().unwrap();
        f(&mut state)
    } else {
        Err(ConstructError::NotFound(format!("AppState with ID {} not found", state_id)))
    }
}


#[wasm_bindgen]
pub async fn create_app_state(db_name: String) -> std::result::Result<String, JsValue> {
    let _ = db_name;
    console_error_panic_hook::set_once();
    let state = AppState::<ClassicSuiteProvider>::new().await.map_err(Into::<JsValue>::into)?;
    let state_id = Uuid::new_v4().to_string();
    let mut states = APP_STATES.lock().unwrap();
    states.insert(state_id.clone(), Mutex::new(state));
    Ok(state_id)
}

#[wasm_bindgen]
pub fn destroy_app_state(state_id: String) {
    let mut states = APP_STATES.lock().unwrap();
    states.remove(&state_id);
}

// NOTE: The async functions below are not ideal because they lock a std::sync::Mutex
// across an .await point, which can lead to deadlocks if the executor is multi-threaded.
// However, wasm-bindgen's executor on the main browser thread is single-threaded,
// so this should be safe in this specific context. A more robust solution would
// involve using an async-aware mutex if this code were to be used in a multi-threaded
// environment.

#[wasm_bindgen]
pub async fn app_state_initialize_user(state_id: String, username: String, password: String) -> std::result::Result<(), JsValue> {
    let states = APP_STATES.lock().unwrap();
    let state_mutex = states.get(&state_id).ok_or_else(|| JsValue::from_str(&ConstructError::NotFound(format!("State {} not found", state_id)).to_string()))?;
    let mut state = state_mutex.lock().unwrap();
    state.initialize_user(username, password).await.map_err(Into::<JsValue>::into)
}

#[wasm_bindgen]
pub async fn app_state_finalize_registration(state_id: String, server_user_id: String, session_token: String, password: String) -> std::result::Result<(), JsValue> {
    let states = APP_STATES.lock().unwrap();
    let state_mutex = states.get(&state_id).ok_or_else(|| JsValue::from_str(&ConstructError::NotFound(format!("State {} not found", state_id)).to_string()))?;
    let mut state = state_mutex.lock().unwrap();
    state.finalize_registration(server_user_id, session_token, password).await.map_err(Into::<JsValue>::into)
}

#[wasm_bindgen]
pub async fn app_state_load_user(state_id: String, user_id: String, password: String) -> std::result::Result<(), JsValue> {
    let states = APP_STATES.lock().unwrap();
    let state_mutex = states.get(&state_id).ok_or_else(|| JsValue::from_str(&ConstructError::NotFound(format!("State {} not found", state_id)).to_string()))?;
    let mut state = state_mutex.lock().unwrap();
    state.load_user(user_id, password).await.map_err(Into::<JsValue>::into)
}

#[wasm_bindgen]
pub fn app_state_get_user_id(state_id: String) -> Option<String> {
    with_app_state(&state_id, |state| Ok(state.get_user_id().map(|s| s.to_string()))).unwrap_or(None)
}

#[wasm_bindgen]
pub fn app_state_get_username(state_id: String) -> Option<String> {
    with_app_state(&state_id, |state| Ok(state.get_username().map(|s| s.to_string()))).unwrap_or(None)
}

#[wasm_bindgen]
pub async fn app_state_add_contact(state_id: String, contact_id: String, username: String) -> std::result::Result<(), JsValue> {
    let states = APP_STATES.lock().unwrap();
    let state_mutex = states.get(&state_id).ok_or_else(|| JsValue::from_str(&ConstructError::NotFound(format!("State {} not found", state_id)).to_string()))?;
    let mut state = state_mutex.lock().unwrap();
    state.add_contact(contact_id, username).await.map_err(Into::<JsValue>::into)
}

#[wasm_bindgen]
pub fn app_state_get_contacts(state_id: String) -> std::result::Result<JsValue, JsValue> {
    let contacts = with_app_state(&state_id, |state| {
        let contacts = state.get_contacts();
        // This serialization can't fail
        Ok(serde_json::to_value(contacts).unwrap())
    }).map_err(Into::<JsValue>::into)?;
    Ok(serde_wasm_bindgen::to_value(&contacts)?)
}

#[wasm_bindgen]
pub async fn app_state_send_message(state_id: String, to_contact_id: String, session_id: String, text: String) -> std::result::Result<String, JsValue> {
    let states = APP_STATES.lock().unwrap();
    let state_mutex = states.get(&state_id).ok_or_else(|| JsValue::from_str(&ConstructError::NotFound(format!("State {} not found", state_id)).to_string()))?;
    let mut state = state_mutex.lock().unwrap();
    state.send_message(&to_contact_id, &session_id, &text).await.map_err(Into::<JsValue>::into)
}

#[wasm_bindgen]
pub async fn app_state_load_conversation(state_id: String, contact_id: String) -> std::result::Result<JsValue, JsValue> {
    let states = APP_STATES.lock().unwrap();
    let state_mutex = states.get(&state_id).ok_or_else(|| JsValue::from_str(&ConstructError::NotFound(format!("State {} not found", state_id)).to_string()))?;
    let mut state = state_mutex.lock().unwrap();
    let conversation = state.load_conversation(&contact_id).await?;
    Ok(serde_wasm_bindgen::to_value(&conversation)?)
}

#[wasm_bindgen]
pub fn app_state_connect(state_id: String, server_url: String) -> std::result::Result<(), JsValue> {
    with_app_state(&state_id, |state| state.connect(&server_url)).map_err(Into::<JsValue>::into)
}

#[wasm_bindgen]
pub fn app_state_disconnect(state_id: String) -> std::result::Result<(), JsValue> {
    with_app_state(&state_id, |state| state.disconnect()).map_err(Into::<JsValue>::into)
}

#[wasm_bindgen]
pub fn app_state_connection_state(state_id: String) -> String {
    with_app_state(&state_id, |state| {
        let state_val = match state.connection_state() {
            ConnectionState::Disconnected => "disconnected",
            ConnectionState::Connecting => "connecting",
            ConnectionState::Connected => "connected",
            ConnectionState::Reconnecting => "reconnecting",
            ConnectionState::Error => "error",
        };
        Ok(state_val.to_string())
    }).unwrap_or_else(|_| "error".to_string())
}

#[wasm_bindgen]
pub fn app_state_set_auto_reconnect(state_id: String, enabled: bool) {
    let _ = with_app_state(&state_id, |state| {
        state.reconnect_state_mut().set_enabled(enabled);
        Ok(())
    });
}

#[wasm_bindgen]
pub fn app_state_reconnect_attempts(state_id: String) -> u32 {
    with_app_state(&state_id, |state| Ok(state.reconnect_state().attempts())).unwrap_or(0)
}

#[wasm_bindgen]
pub fn app_state_reset_reconnect(state_id: String) {
    let _ = with_app_state(&state_id, |state| {
        state.reconnect_state_mut().reset();
        Ok(())
    });
}

#[wasm_bindgen]
pub fn app_state_register_on_server(state_id: String, password: String) -> std::result::Result<(), JsValue> {
    with_app_state(&state_id, |state| state.register_on_server(password.clone())).map_err(Into::<JsValue>::into)
}