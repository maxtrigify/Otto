package io.openotto.android

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.text.method.PasswordTransformationMethod
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.ArrayDeque
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/**
 * Lightweight Android companion for a paired Otto Mac. Native Android SDK UI
 * keeps the APK usable without Compose, WebView, or external UI libraries.
 *
 * Every host request goes through [HostClient] on a background executor.
 * Credentials stay inside HostClient; the UI never renders or logs them.
 */
class MainActivity : Activity() {
    private object Palette {
        val background = Color.rgb(14, 18, 25)
        val surface = Color.rgb(26, 31, 41)
        val surfaceRaised = Color.rgb(34, 40, 52)
        val border = Color.rgb(53, 61, 76)
        val ink = Color.rgb(244, 241, 235)
        val secondary = Color.rgb(170, 179, 189)
        val coral = Color.rgb(245, 147, 131)
        val green = Color.rgb(138, 207, 162)
        val yellow = Color.rgb(241, 193, 116)
        val warning = Color.rgb(244, 147, 137)
    }

    private enum class Screen { PAIR, HOME, THREAD }

    private data class ThreadItem(
        val id: String,
        val title: String,
        val status: String,
        val updated: String = ""
    )

    private data class BotItem(val id: String, val name: String, val subtitle: String = "")

    private data class MessageItem(val role: String, val body: String, val sender: String = "")

    private val background = Executors.newSingleThreadExecutor { task ->
        Thread(task, "OttoMobileHostClient").apply { isDaemon = true }
    }
    private val ui = Handler(Looper.getMainLooper())
    private val running = AtomicBoolean(false)
    private val queuedUserActions = ArrayDeque<() -> Unit>()
    private var foreground = false
    private var working = false
    private var screen = Screen.PAIR
    private var generation = 0
    private var selectedThread: ThreadItem? = null
    private var threads = listOf<ThreadItem>()
    private var bots = listOf<BotItem>()
    private var messages = listOf<MessageItem>()
    private var connected = false
    private var statusDetail = "Not paired"
    private var pairingDraft = ""
    private var secureMacAddress = ""
    private var unsentDraft = ""
    private var pendingSendID: String? = null
    private var pendingSendThread: String? = null
    private var pendingSendContent: String? = null
    private val client by lazy { HostClient(applicationContext) }

    private lateinit var root: LinearLayout
    private lateinit var statusLabel: TextView
    private lateinit var statusDot: TextView
    private lateinit var heading: TextView
    private lateinit var bodyContainer: FrameLayout
    private lateinit var actionButton: TextView
    private var composeInput: EditText? = null
    private var homeScroll: ScrollView? = null
    private var chatScroll: ScrollView? = null
    private var chatColumn: LinearLayout? = null

    private val poller = object : Runnable {
        override fun run() {
            if (!foreground) return
            // Poll gently and only while visible. Background polling previously
            // rebuilt Home every 7.5 seconds, resetting the user's scroll.
            if (!working && screen != Screen.PAIR) refresh(silent = true)
            ui.postDelayed(this, if (screen == Screen.THREAD) 8000L else 20000L)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = Palette.background
        window.navigationBarColor = Palette.background
        // Android 15+ enforces edge-to-edge for targetSdk 35. Account for both
        // system bars and the keyboard so cards and the chat composer cannot
        // disappear behind the bottom navigation/gesture area.
        window.setDecorFitsSystemWindows(false)
        // Conversation text and one-time pairing links must not appear in
        // Android's recents thumbnails or third-party screen captures.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        // Do not reset legacy systemUiVisibility here: it would undo the
        // edge-to-edge layout flags set by setDecorFitsSystemWindows(false).
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        root = column().apply {
            setBackgroundColor(Palette.background)
            orientation = LinearLayout.VERTICAL
            setOnApplyWindowInsetsListener { _, insets ->
                val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                val keyboard = insets.getInsets(WindowInsets.Type.ime())
                val bottom = maxOf(bars.bottom, keyboard.bottom)
                if (paddingTop != bars.top || paddingBottom != bottom) {
                    setPadding(0, bars.top, 0, bottom)
                }
                insets
            }
        }
        setContentView(root)
        root.requestApplyInsets()
        buildFrame()
        if (savedInstanceState != null) secureMacAddress = savedInstanceState.getString("secureAddress", "")
        handleIncomingPairUri(intent)
        refresh(silent = true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingPairUri(intent)
    }

    override fun onResume() {
        super.onResume()
        foreground = true
        ui.removeCallbacks(poller)
        ui.postDelayed(poller, 1200L)
    }

    override fun onPause() {
        foreground = false
        ui.removeCallbacks(poller)
        super.onPause()
    }

    override fun onDestroy() {
        foreground = false
        ui.removeCallbacks(poller)
        queuedUserActions.clear()
        generation++
        background.shutdownNow()
        super.onDestroy()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        // No message or pairing payload enters the saved-state Bundle.
        outState.putString("secureAddress", secureMacAddress)
        super.onSaveInstanceState(outState)
    }

    @Deprecated("Handled with Android's standard back navigation")
    override fun onBackPressed() {
        if (screen == Screen.THREAD) {
            selectedThread = null
            messages = emptyList()
            screen = Screen.HOME
            generation++
            render()
        } else if (screen == Screen.HOME && !connected) {
            screen = Screen.PAIR
            render()
        } else super.onBackPressed()
    }

    private fun buildFrame() {
        root.removeAllViews()
        val header = column().apply {
            setPadding(dp(22), dp(19), dp(22), dp(12))
        }
        val topLine = row(Gravity.CENTER_VERTICAL)
        val logo = text("OTTO  /›", 14f, Palette.ink, Typeface.BOLD).apply {
            letterSpacing = 0.19f
            contentDescription = "Otto Android companion"
        }
        topLine.addView(logo, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        statusDot = text("●", 13f, Palette.warning)
        topLine.addView(statusDot)
        statusLabel = text(" NOT PAIRED", 11f, Palette.secondary, Typeface.BOLD).apply {
            letterSpacing = 0.08f
        }
        topLine.addView(statusLabel)
        header.addView(topLine)
        val titleRow = row(Gravity.CENTER_VERTICAL).apply {
            setPadding(0, dp(21), 0, dp(2))
        }
        heading = text("Your workspace.\nWithin reach.", 29f, Palette.ink, Typeface.NORMAL).apply {
            typeface = Typeface.create("serif", Typeface.NORMAL)
        }
        titleRow.addView(heading, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        actionButton = action("Refresh", false) { refresh(silent = false) }
        titleRow.addView(actionButton, LinearLayout.LayoutParams(dp(88), dp(46)))
        header.addView(titleRow)
        root.addView(header)
        bodyContainer = FrameLayout(this)
        root.addView(bodyContainer, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        render()
    }

    private fun render() {
        if (!::bodyContainer.isInitialized) return
        statusDot.setTextColor(if (connected) Palette.green else Palette.warning)
        statusLabel.text = if (connected) " CONNECTED" else " NOT CONNECTED"
        when (screen) {
            Screen.PAIR -> {
                heading.text = "Your Mac.\nIn your pocket."
                actionButton.text = "Help"
                actionButton.setOnClickListener { showPairHelp() }
                renderPair()
            }
            Screen.HOME -> {
                heading.text = "Your workspace.\nWithin reach."
                actionButton.text = "Refresh"
                actionButton.setOnClickListener { refresh(silent = false) }
                renderHome()
            }
            Screen.THREAD -> {
                heading.text = selectedThread?.title ?: "Conversation"
                actionButton.text = "Back"
                actionButton.setOnClickListener { onBackPressed() }
                renderThread()
            }
        }
    }

    private fun renderPair() {
        homeScroll = null
        bodyContainer.removeAllViews()
        val scroller = scroll()
        val body = column().apply { setPadding(dp(22), dp(12), dp(22), dp(24)) }
        val intro = card().apply { setPadding(dp(20), dp(22), dp(20), dp(22)) }
        intro.addView(eyebrow("PAIR WITH YOUR MAC"))
        intro.addView(text("Open Otto on your Mac and generate a fresh mobile pairing QR.", 17f, Palette.ink).apply {
            setPadding(0, dp(12), 0, dp(10))
        })
        intro.addView(text("Paste the QR link and the private HTTPS address of your Mac. Turn on Tailscale on your phone first.", 14f, Palette.secondary))
        body.addView(intro)

        val entry = card().apply {
            setPadding(dp(18), dp(18), dp(18), dp(18))
        }
        entry.addView(eyebrow("ONE-TIME PAIRING LINK"))
        val input = EditText(this).apply {
            hint = "otto://pair?payload=…"
            setText(pairingDraft)
            setTextColor(Palette.ink)
            setHintTextColor(Palette.secondary)
            textSize = 15f
            minHeight = dp(52)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            transformationMethod = PasswordTransformationMethod.getInstance()
            background = rounded(Palette.surfaceRaised, 12f, Palette.border)
            setPadding(dp(14), dp(11), dp(14), dp(11))
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            contentDescription = "Private one-time Otto pairing link"
            setSingleLine(true)
        }
        entry.addView(input, margins(top = 12, bottom = 12))
        val secureLabel = eyebrow("SECURE MAC ADDRESS (TAILSCALE HTTPS)").apply {
            setPadding(0, dp(22), 0, dp(12))
        }
        entry.addView(secureLabel)
        val hostInput = EditText(this).apply {
            hint = "https://your-mac.your-tailnet.ts.net:7339/"
            setText(secureMacAddress)
            setTextColor(Palette.ink)
            setHintTextColor(Palette.secondary)
            textSize = 14f
            minHeight = dp(52)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            background = rounded(Palette.surfaceRaised, 12f, Palette.border)
            setPadding(dp(14), dp(11), dp(14), dp(11))
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            contentDescription = "HTTPS Tailscale address of your Mac"
            setSingleLine(true)
        }
        entry.addView(hostInput)
        val buttons = row(Gravity.CENTER_VERTICAL)
        buttons.addView(action("Paste QR", false) {
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = clipboard.primaryClip
            if (clip != null && clip.itemCount > 0) {
                val value = clip.getItemAt(0).coerceToText(this).toString().trim()
                if (value.startsWith("otto://pair?", ignoreCase = true) ||
                    value.startsWith("muse://pair?", ignoreCase = true)) input.setText(value)
                else toast("Clipboard has no Otto pairing link")
            }
        }, LinearLayout.LayoutParams(0, dp(50), 1f))
        buttons.addView(action("Connect Mac", true) {
            pairingDraft = input.text.toString().trim()
            secureMacAddress = hostInput.text.toString().trim()
            if (!pairingDraft.startsWith("otto://pair?", ignoreCase = true) &&
                !pairingDraft.startsWith("muse://pair?", ignoreCase = true)) {
                toast("Paste the pairing link generated on your Mac")
                return@action
            }
            if (!secureMacAddress.startsWith("https://", ignoreCase = true)) {
                toast("Enter your Mac's private HTTPS address")
                return@action
            }
            val uri = pairingDraft
            pair(uri)
            input.text.clear()
            pairingDraft = ""
        }, LinearLayout.LayoutParams(0, dp(50), 1.7f).apply { leftMargin = dp(10) })
        entry.addView(buttons, margins(top = 14))
        body.addView(entry, margins(top = 14))
        body.addView(text("Tailscale must be running on both devices. The QR may contain a localhost address; the private HTTPS address tells Android how to reach your Mac. Your credential remains private on this phone.", 12f, Palette.secondary).apply {
            setPadding(dp(5), dp(20), dp(5), 0)
        })
        scroller.addView(body)
        bodyContainer.addView(scroller)
    }

    private fun renderHome() {
        val previousScrollY = if (homeScroll?.parent != null) homeScroll?.scrollY ?: 0 else 0
        bodyContainer.removeAllViews()
        val scroll = scroll()
        homeScroll = scroll
        val body = column().apply { setPadding(dp(22), dp(4), dp(22), dp(28)) }
        body.addView(text(if (connected) "Your paired Mac is available" else "Checking the connection to your Mac…", 14f, Palette.secondary))
        val quick = row(Gravity.CENTER_VERTICAL)
        quick.addView(action("Refresh", false) { refresh(silent = false) }, LinearLayout.LayoutParams(0, dp(48), 1f))
        quick.addView(action("Pair Mac", false) { screen = Screen.PAIR; render() }, LinearLayout.LayoutParams(0, dp(48), 1f).apply {
            leftMargin = dp(10)
        })
        body.addView(quick, margins(top = 19, bottom = 25))
        body.addView(eyebrow("SESSIONS"))
        if (threads.isEmpty()) {
            val empty = card()
            empty.addView(text("No sessions yet", 21f, Palette.ink).apply { typeface = Typeface.create("serif", Typeface.BOLD) })
            empty.addView(text("Start a bot below to continue working with Otto on your Mac.", 14f, Palette.secondary), margins(top = 6))
            body.addView(empty, margins(top = 12))
        } else {
            for (thread in threads) {
                body.addView(threadCard(thread), margins(top = 12))
            }
        }
        body.addView(eyebrow("BOTS  •  START A CONVERSATION"), margins(top = 30, bottom = 10))
        if (bots.isEmpty()) {
            body.addView(text("Create a bot in Otto on your Mac to begin a new conversation.", 14f, Palette.secondary), margins(top = 7))
        } else {
            val roster = card().apply { setPadding(dp(10), dp(6), dp(10), dp(6)) }
            bots.forEachIndexed { index, bot ->
                val row = row(Gravity.CENTER_VERTICAL).apply {
                    setPadding(dp(11), dp(13), dp(11), dp(13))
                    isClickable = true
                    isFocusable = true
                    contentDescription = "Start conversation with ${bot.name}"
                    background = ripple(Palette.surface)
                    setOnClickListener { startBot(bot) }
                }
                row.addView(text("%02d".format(index + 1), 13f, Palette.coral, Typeface.BOLD))
                val info = column().apply { setPadding(dp(13), 0, 0, 0) }
                info.addView(text(bot.name, 17f, Palette.ink).apply { typeface = Typeface.create("serif", Typeface.BOLD) })
                if (bot.subtitle.isNotBlank()) info.addView(text(bot.subtitle, 12f, Palette.secondary))
                row.addView(info, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                row.addView(text("START  ›", 12f, Palette.coral, Typeface.BOLD))
                roster.addView(row)
                if (index < bots.lastIndex) roster.addView(divider())
            }
            body.addView(roster)
        }
        scroll.addView(body)
        bodyContainer.addView(scroll)
        scroll.post {
            if (!isFinishing && !isDestroyed && homeScroll === scroll && screen == Screen.HOME) {
                scroll.scrollTo(0, previousScrollY)
            }
        }
    }

    private fun threadCard(thread: ThreadItem): View {
        val wrap = card().apply {
            isClickable = true
            isFocusable = true
            contentDescription = "Open ${thread.title}, ${thread.status} on your Mac"
            background = ripple(Palette.surface)
            setOnClickListener { openThread(thread) }
        }
        val line = row(Gravity.CENTER_VERTICAL)
        val icon = text(thread.title.trim().firstOrNull()?.uppercase() ?: "O", 23f, Palette.coral, Typeface.BOLD).apply {
            typeface = Typeface.create("serif", Typeface.BOLD)
            gravity = Gravity.CENTER
            background = rounded(Color.rgb(56, 42, 48), 18f)
        }
        line.addView(icon, LinearLayout.LayoutParams(dp(50), dp(50)))
        val info = column().apply { setPadding(dp(14), 0, dp(5), 0) }
        info.addView(text(thread.title, 17f, Palette.ink).apply { typeface = Typeface.create("serif", Typeface.BOLD) })
        info.addView(text("● ${thread.status.uppercase()}  •  THIS MAC", 11f,
            if (thread.status.contains("work", true) || thread.status.contains("run", true)) Palette.green else Palette.secondary), margins(top = 7))
        line.addView(info, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        line.addView(text("›", 25f, Palette.coral))
        wrap.addView(line)
        return wrap
    }

    private fun renderThread() {
        homeScroll = null
        bodyContainer.removeAllViews()
        val layout = column()
        val context = row(Gravity.CENTER_VERTICAL).apply { setPadding(dp(22), 0, dp(22), dp(12)) }
        context.addView(text("MAC SESSION", 11f, Palette.secondary, Typeface.BOLD), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        context.addView(action("Sync", false) { refresh(silent = false) }, LinearLayout.LayoutParams(dp(74), dp(42)))
        layout.addView(context)
        chatScroll = scroll().apply { isFillViewport = true }
        chatColumn = column().apply { setPadding(dp(16), dp(10), dp(16), dp(12)) }
        chatScroll?.addView(chatColumn)
        layout.addView(chatScroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        val composer = column().apply {
            background = rounded(Palette.surface, 18f, Palette.border)
            setPadding(dp(12), dp(10), dp(12), dp(12))
        }
        composeInput = EditText(this).apply {
            hint = "Reply to ${selectedThread?.title ?: "Otto"}…"
            setHintTextColor(Palette.secondary)
            setTextColor(Palette.ink)
            background = null
            textSize = 16f
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            minLines = 1
            maxLines = 5
            setText(unsentDraft)
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            contentDescription = "Message to ${selectedThread?.title ?: "Otto"}"
        }
        composer.addView(composeInput)
        val buttons = row(Gravity.CENTER_VERTICAL)
        buttons.addView(text("Runs on your paired Mac", 11f, Palette.secondary), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        buttons.addView(action("Send  ↗", true) { sendMessage() }, LinearLayout.LayoutParams(dp(96), dp(48)))
        composer.addView(buttons)
        layout.addView(composer, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            leftMargin = dp(14); rightMargin = dp(14); bottomMargin = dp(12)
        })
        // Weighted chat history needs the full available height so the composer
        // stays above the keyboard on narrow Galaxy displays.
        bodyContainer.addView(layout, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT
        ))
        renderMessages()
    }

    private fun renderMessages(forceScrollToBottom: Boolean = false) {
        val column = chatColumn ?: return
        val scroll = chatScroll
        val previousY = scroll?.scrollY ?: 0
        val previousContentHeight = scroll?.getChildAt(0)?.height ?: 0
        val wasNearBottom = previousContentHeight <= 0 ||
            previousY + (scroll?.height ?: 0) >= previousContentHeight - dp(96)
        column.removeAllViews()
        if (messages.isEmpty()) {
            val welcome = card().apply { setPadding(dp(20), dp(24), dp(20), dp(24)) }
            welcome.addView(eyebrow("CONTINUE THE CONVERSATION"))
            welcome.addView(text("What should ${selectedThread?.title ?: "Otto"} pick up?", 22f, Palette.ink).apply {
                typeface = Typeface.create("serif", Typeface.BOLD)
                setPadding(0, dp(12), 0, dp(12))
            })
            welcome.addView(text("Messages and work remain on your Mac.", 13f, Palette.secondary))
            column.addView(welcome)
        }
        for (message in messages.takeLast(200)) {
            val mine = message.role.lowercase() in setOf("user", "human")
            val row = row(Gravity.TOP).apply {
                gravity = if (mine) Gravity.RIGHT else Gravity.LEFT
                setPadding(if (mine) dp(35) else 0, dp(7), if (mine) 0 else dp(27), dp(7))
            }
            val surface = column().apply {
                setPadding(dp(15), dp(12), dp(15), dp(12))
                background = rounded(if (mine) Color.rgb(67, 51, 56) else Palette.surface, 17f, Palette.border)
            }
            surface.addView(text(if (mine) "YOU" else message.sender.ifBlank { "OTTO" }.uppercase(), 10f,
                if (mine) Palette.coral else Palette.green, Typeface.BOLD))
            // Render host content as plain text: no WebView, HTML interpretation,
            // JavaScript bridge, inline active links or dangerous rich spans.
            surface.addView(text(message.body.take(24000), 15f, Palette.ink).apply {
                setTextIsSelectable(true)
                setPadding(0, dp(8), 0, 0)
                setLineSpacing(dp(3).toFloat(), 1f)
            })
            row.addView(surface, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            column.addView(row)
        }
        scroll?.post {
            if (chatScroll !== scroll || screen != Screen.THREAD) return@post
            val contentHeight = scroll.getChildAt(0)?.height ?: 0
            if (forceScrollToBottom || wasNearBottom) {
                scroll.scrollTo(0, contentHeight)
            } else {
                // New messages should not yank a reader away from older text.
                scroll.scrollTo(0, previousY)
            }
        }
    }

    private fun showPairHelp() {
        AlertDialog.Builder(this)
            .setTitle("Connect to Otto")
            .setMessage("1. Open Otto on your Mac.\n2. Open Mobile pairing and create a fresh QR.\n3. Scan the QR using the Android camera and open the Otto link.\n4. If needed, copy and paste the link here.\n\nBoth devices must be able to reach the Mac's configured host endpoint.")
            .setPositiveButton("OK", null)
            .show()
    }

    private fun handleIncomingPairUri(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val link = intent.dataString ?: return
        if (!link.startsWith("otto://pair?", ignoreCase = true) &&
            !link.startsWith("muse://pair?", ignoreCase = true)) return
        // A QR can advertise localhost, so the user reviews a separate HTTPS
        // address before exchange. Do not show its one-time code in a toast.
        pairingDraft = link
        screen = Screen.PAIR
        render()
        intent.data = null
    }

    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_SHORT).show()

    private fun request(name: String, silent: Boolean = false, work: () -> Unit) {
        if (!running.compareAndSet(false, true)) {
            // Periodic refresh must never silently consume a user's Send,
            // Start, or Pair tap. Queue interactive work on the UI thread.
            if (!silent) {
                if (queuedUserActions.size < 3) {
                    queuedUserActions.addLast { request(name, work = work) }
                    statusLabel.text = " QUEUED…"
                } else toast("Otto is handling another request")
            }
            return
        }
        working = true
        if (!silent) ui.post { statusLabel.text = " $name…" }
        background.execute {
            try { work() }
            catch (error: Exception) {
                // Avoid including untrusted URLs, credential values, or raw
                // backend error strings in the UI, notifications, or logs.
                ui.post {
                    if (isFinishing || isDestroyed) return@post
                    if (name == "Refresh") connected = false
                    statusLabel.text = if (connected) " CONNECTED" else " NOT CONNECTED"
                    if (!silent) toast("$name failed. Check the Mac connection and try again.")
                }
            } finally {
                ui.post {
                    working = false
                    running.set(false)
                    if (!isFinishing && !isDestroyed && queuedUserActions.isNotEmpty()) {
                        queuedUserActions.removeFirst().invoke()
                    }
                }
            }
        }
    }

    private fun refresh(silent: Boolean) {
        refreshFromHost(silent)
    }

    private fun pair(rawUri: String) = pairWithHost(rawUri)
    private fun openThread(thread: ThreadItem) = openFromHost(thread)
    private fun startBot(bot: BotItem) = startOnHost(bot)
    private fun sendMessage() = sendToHost()

    private fun jsonItems(array: JSONArray?): List<JSONObject> {
        if (array == null) return emptyList()
        return (0 until minOf(array.length(), 250)).mapNotNull { array.optJSONObject(it) }
    }

    private fun threadFromJSON(value: JSONObject): ThreadItem? {
        val id = value.optString("id")
        if (id.isBlank()) return null
        return ThreadItem(
            id = id,
            title = value.optString("title").ifBlank { "Conversation" },
            status = value.optString("state", "idle").replace('_', ' '),
            updated = value.optString("updatedAt")
        )
    }

    private fun botFromJSON(value: JSONObject): BotItem? {
        val id = value.optString("id")
        if (id.isBlank()) return null
        return BotItem(
            id = id,
            name = value.optString("name").ifBlank { "Unnamed bot" },
            subtitle = value.optString("jobTitle", value.optString("role", ""))
        )
    }

    private fun messageFromJSON(value: JSONObject): MessageItem {
        val author = value.optJSONObject("author")
        return MessageItem(
            role = value.optString("role", "assistant"),
            body = value.optString("text", value.optString("body", "")),
            sender = author?.optString("displayName", "") ?: ""
        )
    }

    private fun readMessages(value: JSONObject): List<MessageItem> =
        jsonItems(value.optJSONArray("messages")).map(::messageFromJSON)

    private fun updateThreadSnapshot(
        threadID: String,
        value: JSONObject,
        version: Int,
        followNewMessages: Boolean = false
    ) {
        if (version != generation || selectedThread?.id != threadID || screen != Screen.THREAD) return
        value.optJSONObject("thread")?.let { threadFromJSON(it) }?.let { selectedThread = it }
        val refreshed = readMessages(value)
        if (refreshed != messages) {
            messages = refreshed
            renderMessages(forceScrollToBottom = followNewMessages)
        }
    }

    private fun refreshFromHost(silent: Boolean) {
        val currentThread = selectedThread?.id
        val version = generation
        request("Refresh", silent = silent) {
            if (!client.isPaired()) {
                ui.post {
                    if (isFinishing || isDestroyed || version != generation) return@post
                    connected = false
                    if (screen != Screen.PAIR) screen = Screen.PAIR
                    render()
                }
                return@request
            }
            // A quiet thread check only needs its snapshot; roster and session
            // refreshes remain available through the explicit Refresh action.
            if (silent && currentThread != null && screen == Screen.THREAD) {
                val snapshot = client.snapshot(currentThread)
                ui.post {
                    if (isFinishing || isDestroyed || version != generation) return@post
                    connected = true
                    statusDot.setTextColor(Palette.green)
                    statusLabel.text = " CONNECTED"
                    updateThreadSnapshot(currentThread, snapshot, version)
                }
                return@request
            }
            val loadedThreads = jsonItems(client.listThreads().optJSONArray("threads")).mapNotNull(::threadFromJSON)
            val loadedBots = jsonItems(client.listBots().optJSONArray("bots")).mapNotNull(::botFromJSON)
            val snapshot = if (currentThread != null) client.snapshot(currentThread) else null
            ui.post {
                if (isFinishing || isDestroyed || version != generation) return@post
                val homeChanged = loadedThreads != threads || loadedBots != bots
                val wasConnected = connected
                threads = loadedThreads
                bots = loadedBots
                connected = true
                statusDetail = "Mac connected"
                if (screen == Screen.PAIR) screen = Screen.HOME
                if (screen == Screen.THREAD && currentThread != null && snapshot != null) {
                    updateThreadSnapshot(currentThread, snapshot, version)
                    statusLabel.text = " CONNECTED"
                    statusDot.setTextColor(Palette.green)
                } else if (homeChanged || !wasConnected || !silent) {
                    render()
                } else {
                    // No content change: leave views, touch state and scroll alone.
                    statusLabel.text = " CONNECTED"
                    statusDot.setTextColor(Palette.green)
                }
            }
        }
    }

    private fun pairWithHost(rawUri: String) {
        val base = secureMacAddress.trim()
        try {
            OttoProtocol.parsePairingUri(rawUri)
            OttoProtocol.safeBaseURL(base)
        } catch (_: Exception) {
            toast("The pairing link or HTTPS address is invalid or expired")
            return
        }
        request("Connecting") {
            client.pair(rawUri, base, android.os.Build.MODEL.take(80).ifBlank { "Android Otto" })
            ui.post {
                if (isFinishing || isDestroyed) return@post
                connected = true
                pairingDraft = ""
                screen = Screen.HOME
                generation++
                render()
                toast("Mac paired securely")
                ui.postDelayed({ refresh(silent = true) }, 250L)
            }
        }
    }

    private fun openFromHost(thread: ThreadItem) {
        unsentDraft = ""
        pendingSendID = null
        pendingSendThread = null
        pendingSendContent = null
        selectedThread = thread
        screen = Screen.THREAD
        messages = emptyList()
        generation++
        render()
        val version = generation
        request("Loading") {
            val snapshot = client.snapshot(thread.id)
            ui.post {
                if (isFinishing || isDestroyed) return@post
                updateThreadSnapshot(thread.id, snapshot, version)
                statusLabel.text = " CONNECTED"
            }
        }
    }

    private fun startOnHost(bot: BotItem) {
        request("Opening bot") {
            val result = client.startThread(bot.id)
            val next = result.optJSONObject("thread")?.let(::threadFromJSON)
                ?: throw ProtocolException("Mac did not return a thread")
            val snapshot = client.snapshot(next.id)
            ui.post {
                if (isFinishing || isDestroyed) return@post
                selectedThread = next
                messages = readMessages(snapshot)
                unsentDraft = ""
                pendingSendID = null
                pendingSendThread = null
                pendingSendContent = null
                screen = Screen.THREAD
                generation++
                render()
            }
        }
    }

    private fun sendToHost() {
        val threadID = selectedThread?.id ?: return
        val input = composeInput ?: return
        val body = input.text.toString().trim()
        if (body.isEmpty()) return
        if (body.length > 24_000) {
            toast("Message is too long")
            return
        }
        val existingID = if (pendingSendThread == threadID && pendingSendContent == body) pendingSendID else null
        val clientMessageID = existingID ?: UUID.randomUUID().toString()
        pendingSendID = clientMessageID
        pendingSendThread = threadID
        pendingSendContent = body
        unsentDraft = body
        val version = generation
        request("Sending") {
            val accepted = client.send(threadID, body, clientMessageID)
            if (!accepted.optBoolean("accepted", false)) throw ProtocolException("Mac did not accept the message")
            val snapshot = client.snapshot(threadID)
            ui.post {
                if (isFinishing || isDestroyed || version != generation || selectedThread?.id != threadID) return@post
                if (input.text.toString().trim() == body) input.text.clear()
                unsentDraft = ""
                pendingSendID = null
                pendingSendThread = null
                pendingSendContent = null
                updateThreadSnapshot(threadID, snapshot, version, followNewMessages = true)
                statusLabel.text = " CONNECTED"
            }
        }
    }

    private fun dp(value: Int) = (resources.displayMetrics.density * value + 0.5f).toInt()

    private fun margins(top: Int = 0, bottom: Int = 0): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(top); bottomMargin = dp(bottom)
        }

    private fun column() = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    private fun row(alignment: Int) = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = alignment }
    private fun scroll() = ScrollView(this).apply {
        isFillViewport = false
        isVerticalScrollBarEnabled = false
        clipToPadding = false
    }

    private fun text(label: String, sp: Float, color: Int, style: Int = Typeface.NORMAL): TextView =
        TextView(this).apply {
            text = label
            textSize = sp
            setTextColor(color)
            typeface = Typeface.create("sans-serif", style)
            includeFontPadding = true
        }

    private fun eyebrow(label: String): TextView = text(label, 11f, Palette.secondary, Typeface.BOLD).apply {
        letterSpacing = 0.13f
    }

    private fun rounded(color: Int, radius: Float, outline: Int? = null): GradientDrawable =
        GradientDrawable().apply {
            setColor(color)
            cornerRadius = dp(radius.toInt()).toFloat()
            if (outline != null) setStroke(dp(1), outline)
        }

    private fun ripple(color: Int) = android.graphics.drawable.RippleDrawable(
        ColorStateList.valueOf(Palette.border), rounded(color, 18f, Palette.border), null
    )

    private fun card(): LinearLayout = column().apply {
        background = rounded(Palette.surface, 20f, Palette.border)
        setPadding(dp(17), dp(17), dp(17), dp(17))
        clipToOutline = true
    }

    private fun divider() = View(this).apply {
        setBackgroundColor(Palette.border)
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(1))
    }

    private fun action(label: String, prominent: Boolean, action: () -> Unit): TextView =
        text(label, 13f, if (prominent) Palette.background else Palette.coral, Typeface.BOLD).apply {
            gravity = Gravity.CENTER
            background = rounded(if (prominent) Palette.coral else Palette.surfaceRaised, 14f,
                if (prominent) null else Palette.border)
            setPadding(dp(13), dp(10), dp(13), dp(10))
            isClickable = true
            isFocusable = true
            minHeight = dp(48)
            contentDescription = label
            setOnClickListener { action() }
        }
}
