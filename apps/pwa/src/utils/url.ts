/**
 * URL validation and normalization utilities
 * Supports domain names, IPv4, and IPv6 addresses
 */

/**
 * Validates if a string is a valid IPv4 address
 */
function isIPv4(str: string): boolean {
  const ipv4Regex = /^(\d{1,3}\.){3}\d{1,3}$/;
  if (!ipv4Regex.test(str)) return false;

  const parts = str.split('.');
  return parts.every(part => {
    const num = parseInt(part, 10);
    return num >= 0 && num <= 255;
  });
}

/**
 * Validates if a string is a valid IPv6 address
 */
function isIPv6(str: string): boolean {
  // Remove brackets if present
  const cleaned = str.replace(/^\[|\]$/g, '');

  // IPv6 validation regex (simplified)
  const ipv6Regex = /^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$/;
  return ipv6Regex.test(cleaned);
}

/**
 * Normalizes a WebSocket URL:
 * - Adds wss:// prefix if missing
 * - Wraps IPv6 addresses in brackets
 * - Validates format
 *
 * @param url - Server URL (can be domain, IPv4, or IPv6)
 * @returns Normalized WebSocket URL
 * @throws Error if URL is invalid
 *
 * @example
 * normalizeWebSocketUrl('66.241.124.8:443') -> 'wss://66.241.124.8:443'
 * normalizeWebSocketUrl('2a09:8280:1::b9:e736:0') -> 'wss://[2a09:8280:1::b9:e736:0]'
 * normalizeWebSocketUrl('wss://example.com') -> 'wss://example.com'
 */
export function normalizeWebSocketUrl(url: string): string {
  if (!url || url.trim() === '') {
    throw new Error('URL cannot be empty');
  }

  let normalized = url.trim();

  // Check if protocol is present
  const hasProtocol = /^wss?:\/\//i.test(normalized);

  if (!hasProtocol) {
    // Extract host and port
    const parts = normalized.split(':');

    // Check if it's an IPv6 address (contains multiple colons)
    if (parts.length > 2) {
      // IPv6 address
      const lastPart = parts[parts.length - 1];
      const maybePort = parseInt(lastPart, 10);

      if (!isNaN(maybePort) && maybePort > 0 && maybePort <= 65535) {
        // Has port
        const ipv6 = parts.slice(0, -1).join(':');
        if (isIPv6(ipv6)) {
          normalized = `wss://[${ipv6}]:${maybePort}`;
        } else {
          throw new Error(`Invalid IPv6 address: ${ipv6}`);
        }
      } else {
        // No port, entire string is IPv6
        if (isIPv6(normalized)) {
          normalized = `wss://[${normalized}]`;
        } else {
          throw new Error(`Invalid IPv6 address: ${normalized}`);
        }
      }
    } else {
      // IPv4 or domain name
      const host = parts[0];
      const port = parts[1];

      if (isIPv4(host)) {
        normalized = port ? `wss://${host}:${port}` : `wss://${host}`;
      } else {
        // Assume domain name
        normalized = port ? `wss://${host}:${port}` : `wss://${host}`;
      }
    }
  } else {
    // Protocol is present, validate IPv6 format
    const urlObj = new URL(normalized);
    const hostname = urlObj.hostname;

    // If hostname contains colons but not wrapped in brackets, it's IPv6
    if (hostname.includes(':') && !hostname.startsWith('[')) {
      if (isIPv6(hostname)) {
        urlObj.hostname = `[${hostname}]`;
        normalized = urlObj.toString();
      }
    }
  }

  // Validate final URL
  try {
    const urlObj = new URL(normalized);
    if (!['ws:', 'wss:'].includes(urlObj.protocol)) {
      throw new Error(`Invalid WebSocket protocol: ${urlObj.protocol}. Use ws:// or wss://`);
    }
  } catch (err) {
    if (err instanceof TypeError) {
      throw new Error(`Invalid URL format: ${normalized}`);
    }
    throw err;
  }

  return normalized;
}

/**
 * Validates and normalizes a server URL from user input
 * Provides helpful error messages
 */
export function validateServerUrl(url: string): { valid: boolean; normalized?: string; error?: string } {
  try {
    const normalized = normalizeWebSocketUrl(url);

    // Additional security check: warn about ws:// in production
    if (normalized.startsWith('ws://') && !normalized.includes('localhost') && !normalized.includes('127.0.0.1')) {
      return {
        valid: false,
        error: 'Insecure WebSocket (ws://) is not allowed for remote servers. Use wss:// instead.',
      };
    }

    return { valid: true, normalized };
  } catch (err) {
    return {
      valid: false,
      error: err instanceof Error ? err.message : 'Invalid URL format',
    };
  }
}
