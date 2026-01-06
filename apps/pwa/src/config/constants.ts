// Application configuration constants
import { normalizeWebSocketUrl } from '../utils/url';

// Server configuration
// Default fallback if no env variable is set
const DEFAULT_SERVER_URL = 'wss://66.241.124.8:443';

// Get server URL from environment or use default
const rawServerUrl = import.meta.env.VITE_SERVER_URL || DEFAULT_SERVER_URL;

// Normalize and validate the URL (supports IPv4, IPv6, domain names)
export const SERVER_URL = normalizeWebSocketUrl(rawServerUrl);

// Debug mode
export const DEBUG = import.meta.env.VITE_DEBUG === 'true';

// API endpoints
export const API_ENDPOINTS = {
  register: '/api/register',
  message: '/api/message',
  getMessages: '/api/messages',
  getContacts: '/api/contacts',
} as const;

// WebSocket configuration
export const WS_CONFIG = {
  reconnectInterval: parseInt(import.meta.env.VITE_WS_RECONNECT_INTERVAL || '3000', 10),
  maxReconnectAttempts: parseInt(import.meta.env.VITE_WS_MAX_RECONNECT_ATTEMPTS || '5', 10),
  heartbeatInterval: parseInt(import.meta.env.VITE_WS_HEARTBEAT_INTERVAL || '30000', 10),
} as const;

// Application metadata
export const APP_VERSION = '0.1.0';
export const APP_NAME = 'Construct Messenger';
