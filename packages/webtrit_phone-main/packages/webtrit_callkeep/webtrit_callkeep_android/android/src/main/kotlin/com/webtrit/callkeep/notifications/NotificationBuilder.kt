package com.webtrit.callkeep.notifications

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import com.webtrit.callkeep.R
import com.webtrit.callkeep.common.Platform

abstract class NotificationBuilder() {
    /**
     * Builds a PendingIntent targeting the main launch Activity (MainActivity).
     * Used for active call, missed call, and foreground service notifications.
     */
    protected fun buildOpenAppIntent(context: Context, uri: Uri = Uri.EMPTY): PendingIntent {
        val hostAppActivity = Platform.getLaunchActivity(context)?.apply {
            if (uri != Uri.EMPTY) data = uri
        }

        return PendingIntent.getActivity(
            context,
            R.integer.notification_incoming_call_id,
            hostAppActivity,
            PendingIntent.FLAG_IMMUTABLE
        )
    }

    /**
     * Builds a PendingIntent targeting the configured call-screen Activity
     * (com.webtrit.callkeep.call_screen_activity meta-data), or the main launch Activity.
     * Used for active-call notification content tap and fullScreenIntent.
     * Android-only; iOS has no active-call notification.
     */
    protected fun buildCallScreenIntent(context: Context): PendingIntent {
        val targetActivity = Platform.getCallScreenActivity(context)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(
            context,
            R.integer.notification_incoming_call_id,
            targetActivity,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    /**
     * Builds a PendingIntent for the incoming call fullScreenIntent.
     * Targets the configured lock screen Activity (via manifest meta-data
     * "com.webtrit.callkeep.lock_screen_activity") if available, otherwise the main launch Activity.
     *
     * @param extras Optional Bundle of extras to pass to the target Activity (e.g. call metadata).
     */
    protected fun buildIncomingCallFullScreenIntent(
        context: Context,
        extras: Bundle? = null
    ): PendingIntent {
        val targetActivity = Platform.getFullScreenIntentActivity(context)?.apply {
            extras?.let { putExtras(it) }
        }

        return PendingIntent.getActivity(
            context,
            R.integer.notification_incoming_call_id,
            targetActivity,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    abstract fun build(): Notification
}
