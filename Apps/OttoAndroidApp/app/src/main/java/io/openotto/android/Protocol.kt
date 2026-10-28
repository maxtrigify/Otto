package io.openotto.android

import android.util.Base64
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.UUID

/**
 * Otto native mobile protocol version 1, matching OttoRPCContracts.swift.
 *
 * The fingerprint is the Mac's *declared environment public-key fingerprint*.
 * It is not a TLS certificate pin. HTTPS remains authenticated by Android's
 * normal system trust store and hostname verification; do not bypass either.
 */
object OttoProtocol {
    const val VERSION = 1
    const val DEVICE_HEADER = "X-Muse-Device-ID" // Host's current OttoLegacyWire.deviceIDHeader.
    const val ENV_READ = "environment:read"
    const val THREAD_READ = "thread:read"
    const val MESSAGE_WRITE = "message:write"
    const val RUN_CONTROL = "run:control"
    const val APPROVAL_RESPOND = "approval:respond"
    const val SECURE_LOGIN = "secure-login:control"

    val KNOWN_SCOPES: Set<String> = setOf(
        ENV_READ, THREAD_READ, MESSAGE_WRITE, RUN_CONTROL, APPROVAL_RESPOND, SECURE_LOGIN
    )

    private val uuidPattern = Regex(
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    )
    private val fingerprintPattern = Regex("[0-9a-fA-F]{64}")

    fun uuid(value: String): String {
        if (!uuidPattern.matches(value)) throw ProtocolException("Invalid UUID")
        return try { UUID.fromString(value).toString() }
        catch (_: IllegalArgumentException) { throw ProtocolException("Invalid UUID") }
    }

    fun safeBaseURL(raw: String): String {
        if (raw.length > 1024 || raw.isBlank() || raw.any { it.isWhitespace() || it.isISOControl() }) {
            throw ProtocolException("Invalid host URL")
        }
        val uri = try { URI(raw) } catch (_: Exception) { throw ProtocolException("Invalid host URL") }
        val scheme = uri.scheme?.lowercase(Locale.US) ?: throw ProtocolException("Missing host scheme")
        val host = uri.host?.lowercase(Locale.US) ?: throw ProtocolException("Missing host name")
        if (uri.isOpaque || uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null ||
            uri.port > 65535 || uri.port == 0 || scheme !in setOf("https", "http")) {
            throw ProtocolException("Unsafe host URL")
        }
        val loopback = host == "127.0.0.1" || host == "localhost" || host == "::1" ||
            host == "[::1]"
        if (scheme != "https" && !loopback) throw ProtocolException("HTTPS is required for remote pairing")
        val path = uri.rawPath ?: ""
        if (path.contains("%") || path.contains("//") ||
            path.split('/').any { it == "." || it == ".." } ||
            path.any { it.isISOControl() }) {
            throw ProtocolException("Unsafe host path")
        }
        // Keep an optional host prefix for reverse-proxy deployments.
        val prefix = path.trimEnd('/')
        return URI(scheme, null, host, uri.port, if (prefix.isEmpty()) "/" else "$prefix/", null, null)
            .toASCIIString()
    }

    fun endpoint(baseURL: String, suffix: String): String {
        val normalized = safeBaseURL(baseURL)
        require(suffix.startsWith("v1/") && !suffix.contains("..") && !suffix.contains("?"))
        return normalized + suffix
    }

    fun scopes(array: JSONArray): Set<String> {
        if (array.length() < 1 || array.length() > KNOWN_SCOPES.size) {
            throw ProtocolException("Invalid credential scopes")
        }
        val values = linkedSetOf<String>()
        for (i in 0 until array.length()) {
            val value = array.optString(i)
            if (value !in KNOWN_SCOPES || !values.add(value)) {
                throw ProtocolException("Unknown or duplicated credential scope")
            }
        }
        if (ENV_READ !in values) throw ProtocolException("Pairing must grant environment read access")
        return values
    }

    fun toJSONArray(values: Set<String>): JSONArray {
        val array = JSONArray()
        values.sorted().forEach { array.put(it) }
        return array
    }

    fun parsePairingUri(text: String, nowMillis: Long = System.currentTimeMillis()): PairingOffer {
        val raw = text.trim()
        if (raw.length !in 30..16000) throw ProtocolException("Invalid pairing link")
        val uri = try { URI(raw) } catch (_: Exception) { throw ProtocolException("Invalid pairing link") }
        if (uri.scheme?.lowercase(Locale.US) !in setOf("otto", "muse") ||
            uri.host != "pair" || !uri.rawPath.isNullOrEmpty() ||
            uri.rawUserInfo != null || uri.rawFragment != null) {
            throw ProtocolException("Expected an otto://pair link")
        }
        val pieces = (uri.rawQuery ?: "").split('&')
        if (pieces.size != 1 || !pieces[0].startsWith("payload=")) {
            throw ProtocolException("Pairing link must contain only a payload")
        }
        val encoded = try { URLDecoder.decode(pieces[0].substringAfter('='), "UTF-8") }
        catch (_: Exception) { throw ProtocolException("Malformed pairing payload") }
        if (encoded.length !in 32..12000 || !Regex("[A-Za-z0-9_-]+={0,2}").matches(encoded)) {
            throw ProtocolException("Malformed pairing payload")
        }
        val jsonBytes = try {
            Base64.decode(encoded, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        } catch (_: Exception) { throw ProtocolException("Invalid pairing encoding") }
        if (jsonBytes.size > 8192) throw ProtocolException("Pairing payload is too large")
        val json = try { JSONObject(String(jsonBytes, StandardCharsets.UTF_8)) }
        catch (_: JSONException) { throw ProtocolException("Invalid pairing JSON") }
        if (json.optInt("protocolVersion", -1) != VERSION) {
            throw ProtocolException("Unsupported Otto pairing protocol")
        }
        val offerID = uuid(json.getString("offerID"))
        val environmentID = uuid(json.getString("environmentID"))
        val name = json.getString("environmentName")
        if (name.isBlank() || name.length > 120 || name.any { it.isISOControl() }) {
            throw ProtocolException("Invalid environment name")
        }
        val fingerprint = json.getString("fingerprint").lowercase(Locale.US)
        if (!fingerprintPattern.matches(fingerprint)) throw ProtocolException("Invalid host fingerprint")
        val baseURL = safeBaseURL(json.getString("baseURL"))
        val code = json.getString("code")
        if (code.length !in 4..128 || code.any { it.isISOControl() }) {
            throw ProtocolException("Invalid pairing code")
        }
        // OttoRPCCodec uses JSONEncoder.dateEncodingStrategy = millisecondsSince1970.
        val expiry = json.opt("expiresAt") as? Number
            ?: throw ProtocolException("Invalid expiration time")
        val expiresAt = expiry.toDouble()
        if (!expiresAt.isFinite() || expiresAt < nowMillis || expiresAt > nowMillis + 3_600_000) {
            throw ProtocolException("Pairing code expired or has an invalid expiration")
        }
        return PairingOffer(
            offerID, environmentID, name, fingerprint, baseURL, code,
            expiresAt.toLong(), scopes(json.getJSONArray("scopes"))
        )
    }
}

data class PairingOffer(
    val offerID: String,
    val environmentID: String,
    val environmentName: String,
    val fingerprint: String,
    val baseURL: String,
    val code: String,
    val expiresAtMillis: Long,
    val scopes: Set<String>
)

class ProtocolException(message: String) : Exception(message)
