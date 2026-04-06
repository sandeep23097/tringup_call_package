package com.webtrit.callkeep.common

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent

interface ActivityProvider {
    fun getActivity(): Activity?
    fun addActivityChangeListener(listener: (Activity?) -> Unit)
    fun removeActivityChangeListener(listener: (Activity?) -> Unit)
}

@SuppressLint("StaticFieldLeak")
object ActivityHolder : ActivityProvider {
    private var activity: Activity? = null

    private val activityChangeListeners = mutableListOf<(Activity?) -> Unit>()

    private const val TAG = "ActivityHolder"

    /**
     * Set to true immediately before calling [start] (or before any explicit user-initiated
     * Activity launch) so that [WebtritCallkeepPlugin] can distinguish a user-triggered
     * foreground request from an automatic launch caused by the notification's fullScreenIntent
     * firing on the lock screen.
     *
     * Consumed and reset to false in [WebtritCallkeepPlugin.onStateChanged] ON_START.
     */
    @Volatile
    var userInitiatedLaunch: Boolean = false

    override fun getActivity(): Activity? {
        return activity
    }

    fun setActivity(newActivity: Activity?) {
        if (activity != newActivity) {
            activity = newActivity
            notifyActivityChanged(newActivity)
        }
    }

    fun start(context: Context) {
        // Mark as user-initiated so the lock-screen guard in WebtritCallkeepPlugin
        // knows NOT to suppress this Activity launch.
        userInitiatedLaunch = true

        // Use the dedicated call-screen Activity if configured via
        // com.webtrit.callkeep.call_screen_activity meta-data; otherwise fall
        // back to the main launch Activity.
        val hostAppActivity = Platform.getCallScreenActivity(context)?.apply {
            // Ensures the activity is started in a new task if needed (required when launching from a service)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    // Prevents recreating the activity if it's already at the top of the task
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    // Brings the existing activity to the foreground instead of creating a new one
                    Intent.FLAG_ACTIVITY_BROUGHT_TO_FRONT
        }

        context.startActivity(hostAppActivity)
    }

    fun finish() {
        Log.i(TAG, "Finishing activity")

        // Using moveTaskToBack(true) instead of finish(), because finish()
        // may cause the error "Error broadcast intent callback: result=CANCELLED".
        // This happens when the activity is finished while handling
        // a notification or a BroadcastReceiver, which cancels relevant operations.
        // moveTaskToBack(true) simply moves the app to the background,
        // preserving all active processes.
        // Reference: https://stackoverflow.com/questions/39480931/error-broadcast-intent-callback-result-cancelled-forintent-act-com-google-and
        activity?.moveTaskToBack(true)
    }


    override fun addActivityChangeListener(listener: (Activity?) -> Unit) {
        activityChangeListeners.add(listener)
    }

    override fun removeActivityChangeListener(listener: (Activity?) -> Unit) {
        activityChangeListeners.remove(listener)
    }

    private fun notifyActivityChanged(newActivity: Activity?) {
        activityChangeListeners.forEach { it.invoke(newActivity) }
    }
}
