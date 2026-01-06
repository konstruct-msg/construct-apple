/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SERVER_URL?: string;
  readonly VITE_DEBUG?: string;
  readonly VITE_WS_RECONNECT_INTERVAL?: string;
  readonly VITE_WS_MAX_RECONNECT_ATTEMPTS?: string;
  readonly VITE_WS_HEARTBEAT_INTERVAL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
