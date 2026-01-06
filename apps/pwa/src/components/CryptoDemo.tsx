import { useState, useEffect } from 'react';
import { CryptoClient, KeyBundle } from '../lib/crypto';
import './CryptoDemo.css';

export default function CryptoDemo() {
  const [alice, setAlice] = useState<CryptoClient | null>(null);
  const [bob, setBob] = useState<CryptoClient | null>(null);
  const [aliceKeys, setAliceKeys] = useState<KeyBundle | null>(null);
  const [bobKeys, setBobKeys] = useState<KeyBundle | null>(null);
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [message, setMessage] = useState('Hello from Alice!');
  const [encrypted, setEncrypted] = useState<string | null>(null);
  const [status, setStatus] = useState<string>('Initializing...');
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    initClients();
  }, []);

  async function initClients() {
    try {
      setStatus('Creating Alice...');
      const aliceClient = new CryptoClient();
      await aliceClient.initialize();
      setAlice(aliceClient);
      const aliceBundle = aliceClient.getKeyBundle();
      setAliceKeys(aliceBundle);

      setStatus('Creating Bob...');
      const bobClient = new CryptoClient();
      await bobClient.initialize();
      setBob(bobClient);
      const bobBundle = bobClient.getKeyBundle();
      setBobKeys(bobBundle);

      setStatus('Ready! Click "Initialize Session" to start');
    } catch (err) {
      setError(`Initialization failed: ${err}`);
      setStatus('Error');
    }
  }

  function handleInitSession() {
    if (!alice || !bobKeys) {
      setError('Clients not ready');
      return;
    }

    try {
      setStatus('Initializing session...');
      const bobKeysJSON = JSON.stringify(bobKeys);
      const sid = alice.initSession('bob', bobKeysJSON);
      setSessionId(sid);
      setStatus('Session created! Ready to encrypt');
      setError(null);
    } catch (err) {
      setError(`Session init failed: ${err}`);
      setStatus('Error');
    }
  }

  function handleEncrypt() {
    if (!alice || !sessionId) {
      setError('Session not initialized');
      return;
    }

    try {
      setStatus('Encrypting message...');
      const encryptedMsg = alice.encryptMessageJSON(sessionId, message);
      setEncrypted(encryptedMsg);
      setStatus('Message encrypted!');
      setError(null);
    } catch (err) {
      setError(`Encryption failed: ${err}`);
      setStatus('Error');
    }
  }

  function formatKey(key: number[]): string {
    return key.slice(0, 8).map(b => b.toString(16).padStart(2, '0')).join('') + '...';
  }

  return (
    <div className="crypto-demo">
      <h2>🔐 Construct Crypto Demo</h2>

      <div className="status-bar">
        <strong>Status:</strong> {status}
        {error && <div className="error">{error}</div>}
      </div>

      <div className="clients-grid">
        <div className="client-card">
          <h3>👤 Alice</h3>
          {aliceKeys ? (
            <div className="key-info">
              <div>
                <strong>Identity:</strong><br/>
                <code>{formatKey(aliceKeys.identity_public)}</code>
              </div>
              <div>
                <strong>Prekey:</strong><br/>
                <code>{formatKey(aliceKeys.signed_prekey_public)}</code>
              </div>
            </div>
          ) : (
            <div>Initializing...</div>
          )}
        </div>

        <div className="client-card">
          <h3>👤 Bob</h3>
          {bobKeys ? (
            <div className="key-info">
              <div>
                <strong>Identity:</strong><br/>
                <code>{formatKey(bobKeys.identity_public)}</code>
              </div>
              <div>
                <strong>Prekey:</strong><br/>
                <code>{formatKey(bobKeys.signed_prekey_public)}</code>
              </div>
            </div>
          ) : (
            <div>Initializing...</div>
          )}
        </div>
      </div>

      {alice && bob && !sessionId && (
        <div className="action-section">
          <button onClick={handleInitSession} className="primary-btn">
            🤝 Initialize Session
          </button>
        </div>
      )}

      {sessionId && (
        <>
          <div className="session-info">
            <strong>Session ID:</strong> <code>{sessionId.substring(0, 16)}...</code>
          </div>

          <div className="message-section">
            <label>
              <strong>Message to encrypt:</strong>
              <input
                type="text"
                value={message}
                onChange={(e) => setMessage(e.target.value)}
                placeholder="Enter message..."
              />
            </label>
            <button onClick={handleEncrypt} className="primary-btn">
              🔒 Encrypt Message
            </button>
          </div>
        </>
      )}

      {encrypted && (
        <div className="encrypted-output">
          <h3>📦 Encrypted Output</h3>
          <textarea
            value={encrypted}
            readOnly
            rows={6}
          />
          <div className="encrypted-size">
            Size: {encrypted.length} bytes
          </div>
        </div>
      )}

      <div className="info-box">
        <h4>ℹ️ About</h4>
        <p>
          This demo shows Rust/WASM cryptography working in the browser:
        </p>
        <ul>
          <li>X25519 key exchange</li>
          <li>Ed25519 signatures</li>
          <li>Double Ratchet encryption</li>
          <li>ChaCha20-Poly1305 AEAD</li>
        </ul>
      </div>
    </div>
  );
}
