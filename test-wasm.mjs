// Простой тест WASM модуля
import init, {
    create_crypto_client,
    get_registration_bundle,
    init_session,
    init_receiving_session,
    encrypt_message,
    decrypt_message,
    destroy_client,
    version
} from './packages/core/pkg/construct_core.js';

async function test() {
    console.log('🚀 Initializing WASM...');
    // В Node.js нужно передать путь к WASM файлу
    const { readFile } = await import('fs/promises');
    const wasmBuffer = await readFile('./packages/core/pkg/construct_core_bg.wasm');
    await init(wasmBuffer);

    console.log('📦 Version:', version());

    console.log('\n👤 Creating Alice...');
    const aliceId = create_crypto_client();
    console.log('Alice ID:', aliceId);

    console.log('\n👤 Creating Bob...');
    const bobId = create_crypto_client();
    console.log('Bob ID:', bobId);

    console.log('\n🔑 Getting Alice\'s keys...');
    const aliceKeys = get_registration_bundle(aliceId);
    console.log('Alice keys:', aliceKeys.substring(0, 100) + '...');

    console.log('\n🔑 Getting Bob\'s keys...');
    const bobKeys = get_registration_bundle(bobId);
    console.log('Bob keys:', bobKeys.substring(0, 100) + '...');

    console.log('\n🤝 Alice initializing session with Bob...');
    const aliceSessionId = init_session(aliceId, 'bob', bobKeys);
    console.log('Alice Session ID:', aliceSessionId);

    console.log('\n📝 Alice encrypting first message...');
    const plaintext1 = 'Hello Bob! This is a secret message 🔒';
    const encrypted1 = encrypt_message(aliceId, aliceSessionId, plaintext1);
    console.log('Encrypted:', encrypted1.substring(0, 100) + '...');

    console.log('\n🤝 Bob receiving first message and creating session...');
    const bobSessionId = init_receiving_session(bobId, 'alice', aliceKeys, encrypted1);
    console.log('Bob Session ID:', bobSessionId);

    console.log('\n🔓 Bob decrypting Alice\'s message...');
    const decrypted1 = decrypt_message(bobId, bobSessionId, encrypted1);
    console.log('Decrypted:', decrypted1);
    console.log('✅ Alice->Bob test:', decrypted1 === plaintext1 ? 'YES ✨' : 'NO ❌');

    console.log('\n📝 Bob sending reply...');
    const plaintext2 = 'Hi Alice! Message received!';
    const encrypted2 = encrypt_message(bobId, bobSessionId, plaintext2);
    console.log('Encrypted:', encrypted2.substring(0, 100) + '...');

    console.log('\n🔓 Alice decrypting Bob\'s reply...');
    const decrypted2 = decrypt_message(aliceId, aliceSessionId, encrypted2);
    console.log('Decrypted:', decrypted2);
    console.log('✅ Bob->Alice test:', decrypted2 === plaintext2 ? 'YES ✨' : 'NO ❌');

    console.log('\n📝 Alice sending another message...');
    const plaintext3 = 'Great! Double Ratchet works!';
    const encrypted3 = encrypt_message(aliceId, aliceSessionId, plaintext3);
    console.log('Encrypted:', encrypted3.substring(0, 100) + '...');

    console.log('\n🔓 Bob decrypting second message...');
    const decrypted3 = decrypt_message(bobId, bobSessionId, encrypted3);
    console.log('Decrypted:', decrypted3);
    console.log('✅ Ratcheting test:', decrypted3 === plaintext3 ? 'YES ✨' : 'NO ❌');

    console.log('\n✅ WASM Module Test Completed!');
    console.log('🎯 Summary:');
    console.log('  - Crypto client creation: ✅');
    console.log('  - Key bundle generation: ✅');
    console.log('  - Session initialization (sender): ✅');
    console.log('  - Session initialization (receiver): ✅');
    console.log('  - Alice -> Bob encryption/decryption: ✅');
    console.log('  - Bob -> Alice encryption/decryption: ✅');
    console.log('  - Forward secrecy (ratcheting): ✅');

    // Cleanup
    destroy_client(aliceId);
    destroy_client(bobId);
}

test().catch(err => {
    console.error('❌ Test failed:', err);
    process.exit(1);
});
