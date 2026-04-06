package com.webtrit.callkeep

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import android.widget.Button
import android.widget.ImageView
import android.widget.TextView
import com.webtrit.callkeep.common.ActivityHolder
import com.webtrit.callkeep.common.AvatarHelper
import com.webtrit.callkeep.models.CallMetadata
import com.webtrit.callkeep.models.NotificationAction
import com.webtrit.callkeep.services.services.connection.PhoneConnectionService
import com.webtrit.callkeep.services.services.incoming_call.IncomingCallService

/**
 * Lightweight native Activity displayed over the lock screen when an incoming call arrives.
 * No Flutter engine — pure Android, so it appears instantly without warm-up delay.
 *
 * Behaviour:
 *  - Shows caller name, call type, and avatar (if available).
 *  - Accept button → sends Answer intent to IncomingCallService, then launches the
 *    configured call-screen Activity via ActivityHolder.start() so the user goes
 *    straight to the call UI (WhatsApp-style).
 *  - Decline button → sends Decline intent to IncomingCallService.
 *  - Auto-dismissed (via callMonitorRunnable) when the connection disappears.
 *
 * The host app declares this Activity in its AndroidManifest.xml (or the library
 * manifest merge provides it) and sets:
 *   android:showWhenLocked="true"
 *   android:turnScreenOn="true"
 */
class IncomingCallLockScreenActivity : Activity() {

    private val callMonitorHandler = Handler(Looper.getMainLooper())
    private val callMonitorRunnable = object : Runnable {
        override fun run() {
            if (!hasActiveConnections()) {
                finish()
            } else {
                callMonitorHandler.postDelayed(this, MONITOR_INTERVAL_MS)
            }
        }
    }

    companion object {
        /**
         * Set to true by [launchMainApp] immediately before launching the host Activity
         * so that MainActivity (if it receives this launch) knows it originated from an
         * incoming-call accept and can apply showWhenLocked / getInitialRoute overrides.
         *
         * Consumed and reset in MainActivity.onCreate().
         */
        @Volatile
        var pendingShowOverLockScreen: Boolean = false

        private const val MONITOR_INTERVAL_MS = 500L
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Apply lock-screen flags before super so the window is above the keyguard
        // from the very first frame.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )
        }

        super.onCreate(savedInstanceState)

        // If no active telecom connections exist yet, there's nothing to show.
        if (!hasActiveConnections()) {
            finish()
            return
        }

        setContentView(R.layout.activity_incoming_call_lock_screen)

        // Parse call metadata from the intent extras (provided by IncomingCallNotificationBuilder).
        val metadata: CallMetadata? = intent?.extras?.let { CallMetadata.fromBundleOrNull(it) }
        val callId: String? = metadata?.callId

        // Resolve display name: prefer AvatarHelper cache (set by signaling layer), fall back to metadata.
        val displayName: String = callId?.let { AvatarHelper.getDisplayName(it) }
            ?: metadata?.name
            ?: "Unknown Caller"

        val callTypeText = if (metadata?.hasVideo == true) "Incoming video call" else "Incoming call"

        // Bind views
        findViewById<TextView>(R.id.tv_caller_name).text = displayName
        findViewById<TextView>(R.id.tv_call_type).text = callTypeText

        // Avatar
        if (callId != null) {
            val avatarPath = metadata?.avatarFilePath ?: AvatarHelper.getAvatarFilePath(callId)
            val bitmap: Bitmap? = AvatarHelper.resolve(avatarPath, displayName)
            if (bitmap != null) {
                findViewById<ImageView>(R.id.iv_caller_avatar).setImageBitmap(bitmap)
            }
        }

        // Decline button
        findViewById<Button>(R.id.btn_decline).setOnClickListener {
            metadata?.let { sendDeclineIntent(it) }
            finish()
        }

        // Accept button
        findViewById<Button>(R.id.btn_answer).setOnClickListener {
            metadata?.let { sendAnswerIntent(it) }
            launchMainApp()
        }

        // Start polling to auto-dismiss when call ends
        callMonitorHandler.postDelayed(callMonitorRunnable, MONITOR_INTERVAL_MS)
    }

    override fun onDestroy() {
        callMonitorHandler.removeCallbacks(callMonitorRunnable)
        super.onDestroy()
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    /**
     * Set [pendingShowOverLockScreen] and launch the configured call-screen Activity
     * (TringupCallActivity if meta-data is set, else MainActivity).
     * ActivityHolder.start() reads Platform.getCallScreenActivity() which respects
     * the "com.webtrit.callkeep.call_screen_activity" manifest meta-data.
     */
    private fun launchMainApp() {
        pendingShowOverLockScreen = true
        ActivityHolder.start(applicationContext)
        finish()
    }

    /**
     * Sends the Answer notification action to IncomingCallService so the
     * TelecomManager / PhoneConnection can be answered.
     */
    private fun sendAnswerIntent(metadata: CallMetadata) {
        val intent = Intent(applicationContext, IncomingCallService::class.java).apply {
            action = NotificationAction.Answer.action
            putExtras(metadata.toBundle())
        }
        applicationContext.startService(intent)
    }

    /**
     * Sends the Decline notification action to IncomingCallService.
     */
    private fun sendDeclineIntent(metadata: CallMetadata) {
        val intent = Intent(applicationContext, IncomingCallService::class.java).apply {
            action = NotificationAction.Decline.action
            putExtras(metadata.toBundle())
        }
        applicationContext.startService(intent)
    }

    /**
     * Returns true when there is at least one active PhoneConnection.
     * Used to auto-dismiss this Activity when the call ends before the user interacts.
     */
    private fun hasActiveConnections(): Boolean {
        return try {
            PhoneConnectionService.connectionManager.getConnections().isNotEmpty()
        } catch (e: Exception) {
            false
        }
    }
}
