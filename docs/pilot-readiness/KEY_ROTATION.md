# Provider-Credential Key Rotation

## Keyring contract

- `PROVIDER_CREDENTIAL_ENCRYPTION_KEY_V1` is required and Base64-encodes exactly 32 random bytes.
- When `PROVIDER_CREDENTIAL_ENCRYPTION_KEY_V2` is absent, V1 encrypts and decrypts.
- When V2 is present, V2 is the default encrypting cipher and V1 remains a retired decryption cipher.
- V1 and V2 must contain different key material.
- Never log, commit, paste, or reuse either key.

## Rotation procedure

1. Generate 32 random bytes for V2 and store only the Base64 value in the deployment secret store.
2. Deploy with both V1 and V2. Confirm the application starts and existing credentials validate.
3. Preview ciphertext inventory:

   ```shell
   mix silent_regression.credentials.rotate_key
   ```

4. Execute with exact active-tag confirmation:

   ```shell
   mix silent_regression.credentials.rotate_key \
     --execute \
     --confirm-active-tag AES.GCM.V2
   ```

5. Require `Decryptable == Rows`, `Unreadable headers == 0`, and only `AES.GCM.V2` in the final
   inventory. Repeat the preview after a restart.
6. Keep V1 configured until every backup that may contain V1 ciphertext has expired (maximum 30
   days) and the backup/restore drill succeeds with the planned key set.
7. Only then remove V1 in a reviewed follow-up that promotes a newer versioned key contract.

The rotation command never outputs plaintext and refuses execution unless the supplied tag exactly
matches the configured active tag.
