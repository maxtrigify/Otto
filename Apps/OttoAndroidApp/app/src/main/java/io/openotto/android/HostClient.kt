package io.openotto.android

import android.content.Context
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URI
import java.net.URL
import java.nio.charset.StandardCharsets
import java.security.KeyPairGenerator
import java.security.PublicKey
import java.util.Locale
import java.util.UUID

/**
 * Android SDK-only Otto Host network bridge. All methods perform blocking IO
 * and MUST be called from a worker thread/coroutine Dispatchers.IO, never UI.
 *
 * No global credentials, no relaxed TLS hostname verification, no redirects,
 * no HTTP proxies, no WebView, and no third-party networking libraries.
 */
class HostClient(context: Context) {
    private val store = PairingStore(context.applicationContext)
    private val preferences =
        context.applicationContext.getSharedPreferences("otto_android_active_host_v1", Context.MODE_PRIVATE)
    private val activeKey = "active_environment"
    private val maxBody = 4 * 1024 * 1024

    fun isPaired(): Boolean = store.list().isNotEmpty()

    /** Remove all saved host credentials and local selection (does not remotely revoke). */
    fun forget() {
        store.list().forEach { store.delete(it.environmentID) }
        if (!preferences.edit().remove(activeKey).commit()) {
            throw ProtocolException("Could not clear active host")
        }
    }

    fun forget(environmentID: String) {
        val id = OttoProtocol.uuid(environmentID)
        store.delete(id)
        if (preferences.getString(activeKey, null) == id) {
            preferences.edit().remove(activeKey).commit()
        }
    }

    /** Non-secret pairing metadata only, safe for the UI to display. */
    fun pairedHosts(): JSONArray {
        val results = JSONArray()
        for (record in store.list()) results.put(publicHost(record))
        return results
    }

    fun selectHost(environmentID: String) {
        val id = OttoProtocol.uuid(environmentID)
        if (store.get(id) == null) throw ProtocolException("Host not paired")
        if (!preferences.edit().putString(activeKey, id).commit()) {
            throw ProtocolException("Could not select host")
        }
    }

    private fun selected(): PairedHost {
        val active = preferences.getString(activeKey, null)
        if (active != null) store.get(active)?.let { return it }
        return store.list().firstOrNull() ?: throw ProtocolException("Pair your Mac first")
    }

    /**
     * Scan or paste a QR URI, with an explicit trusted HTTPS override.
     *
     * Mac Otto currently advertises http://127.0.0.1:7338 in its QR even
     * when a reverse-proxied Tailscale HTTPS endpoint is reachable remotely.
     * The HTTPS override is selected by the user and used for BOTH pairing and
     * subsequent RPCs. Returned baseURL must still equal the original Mac QR
     * identity URL; this does not weaken environment/fingerprint checks.
     *
     * A QR does NOT prove that an arbitrary override domain is the Mac: show
     * the HTTPS host to the user for review prior to calling this method.
     */
    fun pair(qr: String, secureBaseUrl: String, deviceName: String): JSONObject {
        val offer = OttoProtocol.parsePairingUri(qr)
        val name = deviceName.trim()
        if (name.isEmpty() || name.length > 120 || name.any { it.isISOControl() }) {
            throw ProtocolException("Enter a valid device name")
        }
        val effectiveURL = OttoProtocol.safeBaseURL(secureBaseUrl)
        val qrHost = URI(offer.baseURL).host.lowercase(Locale.US)
        val loopbackOffer = qrHost in setOf("localhost", "127.0.0.1", "::1")
        if (effectiveURL != offer.baseURL && !loopbackOffer) {
            throw ProtocolException("Cannot override an existing remote Mac identity")
        }
        if (URI(effectiveURL).scheme != "https") {
            throw ProtocolException("Pairing from Android requires a reviewed HTTPS host URL")
        }
        if (System.currentTimeMillis() >= offer.expiresAtMillis) {
            throw ProtocolException("Pairing offer expired")
        }

        val keys = try { KeyPairGenerator.getInstance("Ed25519").generateKeyPair() }
        catch (_: Exception) { throw ProtocolException("Ed25519 is unavailable on this device") }
        val rawPublicKey = rawEd25519PublicKey(keys.public)
        val exchangeInput = JSONObject()
            .put("offerID", offer.offerID)
            .put("code", offer.code)
            .put("deviceName", name)
            .put("devicePublicKey", Base64.encodeToString(rawPublicKey, Base64.NO_WRAP))
        val output = post(effectiveURL, "v1/pairing/exchange", exchangeInput)

        // Compare identity fields to the trusted QR offer (not merely to the
        // TLS host response). The endpoint override intentionally does NOT
        // replace the QR URL for this comparison.
        if (OttoProtocol.uuid(output.getString("environmentID")) != offer.environmentID ||
            output.getString("environmentName") != offer.environmentName ||
            output.getString("fingerprint").lowercase(Locale.US) != offer.fingerprint ||
            OttoProtocol.safeBaseURL(output.getString("baseURL")) != offer.baseURL) {
            throw ProtocolException("Paired host details differ from the QR code")
        }
        val granted = OttoProtocol.scopes(output.getJSONArray("scopes"))
        if (!offer.scopes.containsAll(granted)) {
            throw ProtocolException("Mac granted unrequested scopes")
        }
        val deviceID = OttoProtocol.uuid(output.getString("deviceID"))
        val credential = output.getString("credential")
        if (credential.toByteArray(StandardCharsets.UTF_8).size !in 32..8192 ||
            credential.any { it.isISOControl() }) {
            throw ProtocolException("Invalid paired-device credential")
        }
        val record = PairedHost(
            offer.environmentID,
            offer.environmentName,
            effectiveURL,
            offer.fingerprint,
            deviceID,
            credential,
            keys.private.encoded ?: throw ProtocolException("Ed25519 key cannot be stored securely"),
            granted,
            System.currentTimeMillis()
        )
        // Prove the credential actually reaches the same claimed environment
        // before saving it. An arbitrary endpoint response is insufficient.
        val capability = rpc(record, "environment.getCapabilities", JSONObject())
        val environment = capability.optJSONObject("environment")
            ?: throw ProtocolException("Mac returned no environment identity")
        val versions = capability.optJSONArray("supportedProtocolVersions")
            ?: throw ProtocolException("Mac returned no protocol versions")
        var supportsV1 = false
        for (i in 0 until versions.length()) if (versions.optInt(i) == OttoProtocol.VERSION) supportsV1 = true
        if (OttoProtocol.uuid(environment.getString("id")) != offer.environmentID || !supportsV1) {
            throw ProtocolException("Mac identity or protocol verification failed")
        }
        store.save(record)
        selectHost(record.environmentID)
        return publicHost(record)
    }

    /** Pair with URL already embedded in a remote HTTPS QR code. */
    fun pair(qr: String, deviceName: String): JSONObject {
        val offer = OttoProtocol.parsePairingUri(qr)
        return pair(qr, offer.baseURL, deviceName)
    }

    private fun publicHost(record: PairedHost) = JSONObject()
        .put("environmentID", record.environmentID)
        .put("environmentName", record.environmentName)
        .put("baseURL", record.baseURL)
        .put("fingerprint", record.fingerprint)
        .put("deviceID", record.deviceID)
        .put("scopes", OttoProtocol.toJSONArray(record.scopes))
        .put("pairedAtMillis", record.pairedAtMillis)

    private fun rawEd25519PublicKey(public: PublicKey): ByteArray {
        // X.509 SubjectPublicKeyInfo for Ed25519 is fixed 12-byte DER prefix
        // 302a300506032b6570032100 followed by the 32-byte RFC8032 public key.
        val encoded = public.encoded ?: throw ProtocolException("Ed25519 key cannot be exported")
        val prefix = byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00)
        if (encoded.size != prefix.size + 32 ||
            !encoded.copyOfRange(0, prefix.size).contentEquals(prefix)) {
            throw ProtocolException("Unexpected Ed25519 public-key format")
        }
        return encoded.copyOfRange(prefix.size, encoded.size)
    }

    private fun requireScope(record: PairedHost, method: String) {
        val required = when (method) {
            "environment.getCapabilities", "device.registerPush", "diagnostics.get" -> OttoProtocol.ENV_READ
            "bot.list", "thread.list", "thread.getSnapshot", "thread.events",
            "thread.subscribe", "attachment.list", "attachment.downloadChunk" -> OttoProtocol.THREAD_READ
            "thread.start", "message.send", "attachment.prepareUpload", "attachment.uploadChunk" ->
                OttoProtocol.MESSAGE_WRITE
            "run.interrupt", "run.stop" -> OttoProtocol.RUN_CONTROL
            "approval.get", "approval.respond" -> OttoProtocol.APPROVAL_RESPOND
            else -> throw ProtocolException("Unsupported RPC method")
        }
        if (required !in record.scopes) throw ProtocolException("Paired device lacks permission for $method")
    }

    private fun rpc(record: PairedHost, method: String, parameters: JSONObject): JSONObject {
        requireScope(record, method)
        val requestID = UUID.randomUUID().toString()
        val request = JSONObject()
            .put("id", requestID)
            .put("protocolVersion", OttoProtocol.VERSION)
            .put("method", method)
            .put("parameters", parameters)
        val response = post(record.baseURL, "v1/rpc", request, record)
        if (OttoProtocol.uuid(response.getString("id")) != requestID ||
            response.optInt("protocolVersion", -1) != OttoProtocol.VERSION) {
            throw ProtocolException("Otto RPC response was mismatched")
        }
        val error = response.optJSONObject("error")
        if (error != null) {
            val code = error.optString("code", "unknown").take(64)
            throw ProtocolException("Otto RPC failed ($code)")
        }
        return response.optJSONObject("result")
            ?: throw ProtocolException("Otto RPC returned no result")
    }

    /** Generic v1 RPC for future UI methods: scope-gated to known operations. */
    fun call(method: String, parameters: JSONObject = JSONObject()): JSONObject =
        rpc(selected(), method, parameters)

    fun capabilities(): JSONObject = call("environment.getCapabilities")
    fun listBots(): JSONObject = call("bot.list")
    fun listThreads(): JSONObject = call("thread.list")

    fun snapshot(threadID: String): JSONObject =
        call("thread.getSnapshot", JSONObject().put("threadID", OttoProtocol.uuid(threadID)))

    fun startThread(botID: String): JSONObject = startThread(botID, null)

    fun startThread(botID: String, initialMessage: String?): JSONObject {
        val parameters = JSONObject().put("botProfileID", OttoProtocol.uuid(botID))
        if (initialMessage != null) {
            if (initialMessage.length > 24_000) throw ProtocolException("Initial message is too long")
            parameters.put("initialMessage", initialMessage)
        }
        return call("thread.start", parameters)
    }

    fun send(threadID: String, body: String): JSONObject =
        send(threadID, body, UUID.randomUUID().toString())

    /** Pass a stable clientMessageID to safely retry after uncertain network delivery. */
    fun send(threadID: String, body: String, clientMessageID: String): JSONObject {
        if (body.isBlank() || body.length > 24_000) throw ProtocolException("Invalid message length")
        return call(
            "message.send",
            JSONObject().put("threadID", OttoProtocol.uuid(threadID))
                .put("clientMessageID", OttoProtocol.uuid(clientMessageID))
                .put("body", body)
        )
    }

    fun events(threadID: String, after: Long): JSONObject {
        if (after < 0) throw ProtocolException("Event cursor must be nonnegative")
        return call(
            "thread.events",
            JSONObject().put("threadID", OttoProtocol.uuid(threadID))
                .put("afterSequence", after)
                .put("limit", 200)
        )
    }

    fun stop(threadID: String, runID: String): JSONObject =
        call("run.stop", JSONObject()
            .put("threadID", OttoProtocol.uuid(threadID))
            .put("runID", OttoProtocol.uuid(runID)))

    fun interrupt(threadID: String, runID: String): JSONObject =
        call("run.interrupt", JSONObject()
            .put("threadID", OttoProtocol.uuid(threadID))
            .put("runID", OttoProtocol.uuid(runID)))

    fun pendingApproval(threadID: String): JSONObject =
        call("approval.get", JSONObject().put("threadID", OttoProtocol.uuid(threadID)))

    fun respondToApproval(threadID: String, requestID: String, nonce: String, approveOnce: Boolean): JSONObject {
        if (nonce.isEmpty() || nonce.length > 1024) throw ProtocolException("Invalid approval nonce")
        return call(
            "approval.respond",
            JSONObject().put("threadID", OttoProtocol.uuid(threadID))
                .put("requestID", OttoProtocol.uuid(requestID))
                .put("nonce", nonce)
                .put("decision", if (approveOnce) "approve_once" else "deny")
        )
    }

    private fun post(
        baseURL: String, path: String, payload: JSONObject, record: PairedHost? = null
    ): JSONObject {
        val uri = URI(OttoProtocol.endpoint(baseURL, path))
        val bytes = payload.toString().toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > 256 * 1024) throw ProtocolException("Otto request is too large")
        // Proxy.NO_PROXY prevents a system proxy from collecting credentials.
        val connection = URL(uri.toASCIIString()).openConnection(Proxy.NO_PROXY) as HttpURLConnection
        connection.instanceFollowRedirects = false
        connection.connectTimeout = 10_000
        connection.readTimeout = 30_000
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.useCaches = false
        connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
        connection.setRequestProperty("Accept", "application/json")
        connection.setRequestProperty("Cache-Control", "no-store")
        if (record != null) {
            connection.setRequestProperty("Authorization", "Bearer " + record.credential)
            connection.setRequestProperty(OttoProtocol.DEVICE_HEADER, record.deviceID)
            // The current native host consumes X-Muse-Device-ID (legacy wire
            // spelling). Include the Otto spelling for forward compatibility.
            connection.setRequestProperty("X-Otto-Device-ID", record.deviceID)
        }
        try {
            connection.outputStream.use { it.write(bytes) }
            val status = connection.responseCode
            if (status !in 200..299) {
                // Never echo response bodies: they may contain tokens or prompts.
                throw ProtocolException("Otto Host returned HTTP $status")
            }
            val contentLength = connection.contentLengthLong
            if (contentLength > maxBody) throw ProtocolException("Otto Host response is too large")
            val output = ByteArrayOutputStream()
            connection.inputStream.use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count == -1) break
                    if (output.size() + count > maxBody) throw ProtocolException("Otto Host response is too large")
                    output.write(buffer, 0, count)
                }
            }
            return try { JSONObject(output.toString("UTF-8")) }
            catch (_: Exception) { throw ProtocolException("Otto Host returned invalid JSON") }
        } finally {
            connection.disconnect()
        }
    }
}
