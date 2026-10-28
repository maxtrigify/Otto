package io.openotto.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * A paired device credential and Ed25519 private key, always encrypted at rest.
 * Do not serialize this object to logs, intents, analytics, crash reports or UI.
 */
class PairedHost(
    val environmentID: String,
    val environmentName: String,
    val baseURL: String,
    val fingerprint: String,
    val deviceID: String,
    val credential: String,
    val devicePrivateKeyPKCS8: ByteArray,
    val scopes: Set<String>,
    val pairedAtMillis: Long
) {
    override fun toString(): String = "PairedHost(environmentID=$environmentID, [protected])"
}

/**
 * Stores opaque AES-GCM ciphertext in private SharedPreferences. The 256-bit
 * encryption key is non-exportable in AndroidKeyStore. Each record has a fresh
 * random IV, and its environment ID is authenticated as additional data.
 *
 * Android backup may restore ciphertext but not the Keystore key; such records
 * are rejected, never silently decrypted with a replacement key.
 */
class PairingStore(context: Context) {
    private val preferences =
        context.applicationContext.getSharedPreferences("otto_android_pairings_v1", Context.MODE_PRIVATE)
    private val lock = Any()
    private val keyAlias = "io.openotto.android.pairings.aesgcm.v1"

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore")
        store.load(null)
        val existing = store.getKey(keyAlias, null)
        if (existing != null) {
            return existing as? SecretKey ?: throw ProtocolException("Secure storage key is invalid")
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val parameters = KeyGenParameterSpec.Builder(
            keyAlias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .build()
        generator.init(parameters)
        return generator.generateKey()
    }

    private fun recordKey(environmentID: String): String = "record." + OttoProtocol.uuid(environmentID)

    private fun serialize(record: PairedHost): ByteArray {
        require(record.credential.length >= 32) { "Invalid credential" }
        require(record.devicePrivateKeyPKCS8.isNotEmpty()) { "Missing private key" }
        val json = JSONObject()
            .put("schemaVersion", 1)
            .put("environmentID", OttoProtocol.uuid(record.environmentID))
            .put("environmentName", record.environmentName)
            .put("baseURL", OttoProtocol.safeBaseURL(record.baseURL))
            .put("fingerprint", record.fingerprint)
            .put("deviceID", OttoProtocol.uuid(record.deviceID))
            .put("credential", record.credential)
            .put("devicePrivateKeyPKCS8", Base64.encodeToString(record.devicePrivateKeyPKCS8, Base64.NO_WRAP))
            .put("scopes", OttoProtocol.toJSONArray(record.scopes))
            .put("pairedAtMillis", record.pairedAtMillis)
        return json.toString().toByteArray(StandardCharsets.UTF_8)
    }

    private fun deserialize(data: ByteArray, expectedID: String): PairedHost {
        val json = JSONObject(String(data, StandardCharsets.UTF_8))
        if (json.optInt("schemaVersion") != 1 ||
            OttoProtocol.uuid(json.getString("environmentID")) != expectedID) {
            throw ProtocolException("Stored pairing identity does not match")
        }
        val fingerprint = json.getString("fingerprint")
        if (!Regex("[0-9a-fA-F]{64}").matches(fingerprint)) {
            throw ProtocolException("Stored pairing fingerprint is invalid")
        }
        val credential = json.getString("credential")
        if (credential.length !in 32..8192 || credential.any { it.isISOControl() }) {
            throw ProtocolException("Stored pairing credential is invalid")
        }
        val privateKey = Base64.decode(json.getString("devicePrivateKeyPKCS8"), Base64.DEFAULT)
        if (privateKey.size !in 32..512) throw ProtocolException("Stored Ed25519 key is invalid")
        return PairedHost(
            expectedID,
            json.getString("environmentName"),
            OttoProtocol.safeBaseURL(json.getString("baseURL")),
            fingerprint,
            OttoProtocol.uuid(json.getString("deviceID")),
            credential,
            privateKey,
            OttoProtocol.scopes(json.getJSONArray("scopes")),
            json.getLong("pairedAtMillis")
        )
    }

    @Synchronized
    fun save(record: PairedHost) {
        synchronized(lock) {
            val key = recordKey(record.environmentID)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, secretKey(), SecureRandom())
            cipher.updateAAD(key.toByteArray(StandardCharsets.UTF_8))
            val iv = cipher.iv
            if (iv.size !in 12..16) throw ProtocolException("Invalid secure storage IV")
            val ciphertext = cipher.doFinal(serialize(record))
            val payload = byteArrayOf(1, iv.size.toByte()) + iv + ciphertext
            if (!preferences.edit().putString(key, Base64.encodeToString(payload, Base64.NO_WRAP)).commit()) {
                throw ProtocolException("Could not securely save pairing")
            }
        }
    }

    @Synchronized
    fun get(environmentID: String): PairedHost? {
        synchronized(lock) {
            val key = recordKey(environmentID)
            val text = preferences.getString(key, null) ?: return null
            try {
                val bytes = Base64.decode(text, Base64.DEFAULT)
                if (bytes.size < 35 || bytes[0].toInt() != 1) {
                    throw ProtocolException("Stored pairing has an invalid format")
                }
                val ivSize = bytes[1].toInt() and 0xff
                if (ivSize !in 12..16 || bytes.size < ivSize + 19) {
                    throw ProtocolException("Stored pairing has an invalid IV")
                }
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(
                    Cipher.DECRYPT_MODE, secretKey(),
                    GCMParameterSpec(128, bytes.copyOfRange(2, 2 + ivSize))
                )
                cipher.updateAAD(key.toByteArray(StandardCharsets.UTF_8))
                val cleartext = cipher.doFinal(bytes.copyOfRange(2 + ivSize, bytes.size))
                return deserialize(cleartext, OttoProtocol.uuid(environmentID))
            } catch (_: Exception) {
                // Never fall back to plaintext or return unauthenticated data.
                throw ProtocolException("Cannot unlock pairing; it may have been changed or restored")
            }
        }
    }

    @Synchronized
    fun list(): List<PairedHost> {
        synchronized(lock) {
            val ids = preferences.all.keys
                .filter { it.startsWith("record.") }
                .map { it.removePrefix("record.") }
            // A corrupted/undecryptable pairing must not be silently ignored.
            return ids.mapNotNull { get(it) }.sortedByDescending { it.pairedAtMillis }
        }
    }

    @Synchronized
    fun records(): List<PairedHost> = list()

    @Synchronized
    fun delete(environmentID: String) {
        synchronized(lock) {
            if (!preferences.edit().remove(recordKey(environmentID)).commit()) {
                throw ProtocolException("Could not remove pairing")
            }
        }
    }
}
