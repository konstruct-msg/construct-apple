// TypeScript wrapper for WASM crypto module
import init, {
  create_crypto_client,
  get_registration_bundle,
  init_session,
  init_receiving_session,
  encrypt_message,
  decrypt_message,
  destroy_client,
  version
} from '../wasm/construct_core.js';

let wasmInitialized = false;

export interface KeyBundle {
  identity_public: number[];
  signed_prekey_public: number[];
  signature: number[];
  verifying_key: number[];
}

export interface EncryptedMessage {
  session_id: string;
  ciphertext: number[];
  dh_public_key: number[];
  nonce: number[];
  message_number: number;
  previous_chain_length: number;
}

export class CryptoClient {
  private clientId: string | null = null;

  async initialize(): Promise<void> {
    if (!wasmInitialized) {
      await init();
      wasmInitialized = true;
      console.log('🔐 Construct Crypto WASM initialized, version:', version());
    }

    this.clientId = create_crypto_client();
    console.log('👤 Created crypto client:', this.clientId);
  }

  getKeyBundle(): KeyBundle {
    if (!this.clientId) throw new Error('Client not initialized');
    const json = get_registration_bundle(this.clientId);
    return JSON.parse(json);
  }

  getKeyBundleJSON(): string {
    if (!this.clientId) throw new Error('Client not initialized');
    return get_registration_bundle(this.clientId);
  }

  initSession(contactId: string, remoteBundleJSON: string): string {
    if (!this.clientId) throw new Error('Client not initialized');
    return init_session(this.clientId, contactId, remoteBundleJSON);
  }

  initReceivingSession(contactId: string, remoteBundleJSON: string, firstMessageJSON: string): string {
    if (!this.clientId) throw new Error('Client not initialized');
    return init_receiving_session(this.clientId, contactId, remoteBundleJSON, firstMessageJSON);
  }

  encryptMessage(sessionId: string, plaintext: string): EncryptedMessage {
    if (!this.clientId) throw new Error('Client not initialized');
    const json = encrypt_message(this.clientId, sessionId, plaintext);
    return JSON.parse(json);
  }

  encryptMessageJSON(sessionId: string, plaintext: string): string {
    if (!this.clientId) throw new Error('Client not initialized');
    return encrypt_message(this.clientId, sessionId, plaintext);
  }

  decryptMessage(sessionId: string, encryptedJSON: string): string {
    if (!this.clientId) throw new Error('Client not initialized');
    return decrypt_message(this.clientId, sessionId, encryptedJSON);
  }

  destroy(): void {
    if (this.clientId) {
      destroy_client(this.clientId);
      this.clientId = null;
    }
  }

  getId(): string | null {
    return this.clientId;
  }
}

// Singleton instance for the app
let appCryptoClient: CryptoClient | null = null;

export async function getAppCryptoClient(): Promise<CryptoClient> {
  if (!appCryptoClient) {
    appCryptoClient = new CryptoClient();
    await appCryptoClient.initialize();
  }
  return appCryptoClient;
}

export function getCryptoVersion(): string {
  return version();
}
