package com.webtrit.callkeep.common

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager

object Platform {
    /**
     * Meta-data key in the host app's AndroidManifest.xml that specifies a lightweight
     * Activity to use as the fullScreenIntent target for incoming call notifications.
     * When set, the specified Activity is shown over the lock screen instead of the
     * main app Activity, enabling WhatsApp-like lock screen call handling.
     *
     * Example usage in AndroidManifest.xml:
     * <meta-data
     *     android:name="com.webtrit.callkeep.lock_screen_activity"
     *     android:value="com.example.app.IncomingCallLockScreenActivity"/>
     */
    private const val LOCK_SCREEN_ACTIVITY_META_KEY = "com.webtrit.callkeep.lock_screen_activity"

    fun getLaunchActivity(context: Context): Intent? {
        val pm: PackageManager = context.packageManager
        return pm.getLaunchIntentForPackage(context.packageName)
    }

    /**
     * Meta-data key in the host app's AndroidManifest.xml that specifies a dedicated
     * call-screen Activity (e.g. TringupCallActivity) to launch when an ongoing call
     * needs UI — on video-call accept or active-call notification tap.
     * Falls back to the main launch Activity when not configured.
     *
     * Example:
     * <meta-data
     *     android:name="com.webtrit.callkeep.call_screen_activity"
     *     android:value="com.example.app.TringupCallActivity"/>
     */
    private const val CALL_SCREEN_ACTIVITY_META_KEY = "com.webtrit.callkeep.call_screen_activity"

    /**
     * Returns an Intent for the configured call-screen Activity, or the main launch
     * Activity when [CALL_SCREEN_ACTIVITY_META_KEY] is not set.
     * Used by ActivityHolder.start(), PhoneConnection.establish(), and
     * ActiveCallNotificationBuilder for content/fullScreen intents.
     */
    fun getCallScreenActivity(context: Context): Intent? {
        return try {
            val pm = context.packageManager
            val appInfo = pm.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
            val className = appInfo.metaData?.getString(CALL_SCREEN_ACTIVITY_META_KEY)
            if (className != null) {
                Intent().apply {
                    setClassName(context, className)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                }
            } else {
                getLaunchActivity(context)
            }
        } catch (e: Exception) {
            getLaunchActivity(context)
        }
    }

    /**
     * Returns an Intent targeting the configured lock screen activity (via manifest meta-data),
     * or falls back to the default launch activity if not configured.
     */
    fun getFullScreenIntentActivity(context: Context): Intent? {
        return try {
            val pm = context.packageManager
            val appInfo = pm.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
            val className = appInfo.metaData?.getString(LOCK_SCREEN_ACTIVITY_META_KEY)
            if (className != null) {
                Intent().apply {
                    setClassName(context, className)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                }
            } else {
                getLaunchActivity(context)
            }
        } catch (e: Exception) {
            getLaunchActivity(context)
        }
    }

    fun isLockScreen(context: Context): Boolean {
        val keyguardManager =
            context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager ?: return false

        // isKeyguardLocked() returns true if the lock screen
        // (keyguard) is currently active.
        // This works for both "swipe" and PIN.
        return keyguardManager.isKeyguardLocked
    }
}
