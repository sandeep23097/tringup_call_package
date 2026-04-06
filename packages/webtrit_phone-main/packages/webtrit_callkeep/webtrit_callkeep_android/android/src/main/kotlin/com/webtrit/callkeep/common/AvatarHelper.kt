package com.webtrit.callkeep.common

import android.graphics.Bitmap
import android.graphics.BitmapFactory

/**
 * Helper that stores per-call metadata (display name, avatar path) and resolves
 * avatar bitmaps for the lock-screen incoming-call UI.
 *
 * Populated by the signaling layer when call info arrives, consumed by
 * IncomingCallLockScreenActivity to show caller name and avatar.
 */
object AvatarHelper {

    private data class CallInfo(
        val callId: String,
        val displayName: String?,
        val number: String?,
        val avatarFilePath: String?
    )

    private val callInfoMap = mutableMapOf<String, CallInfo>()

    fun setCallInfo(
        callId: String,
        displayName: String? = null,
        number: String? = null,
        avatarFilePath: String? = null
    ) {
        callInfoMap[callId] = CallInfo(callId, displayName, number, avatarFilePath)
    }

    fun getNumber(callId: String): String? = callInfoMap[callId]?.number

    fun getAvatarFilePath(callId: String): String? = callInfoMap[callId]?.avatarFilePath

    fun getDisplayName(callId: String): String? = callInfoMap[callId]?.displayName

    fun removeCallInfo(callId: String) {
        callInfoMap.remove(callId)
    }

    /**
     * Returns a circular-cropped Bitmap loaded from [filePath], or null if the
     * file does not exist or cannot be decoded.
     */
    fun loadCircular(filePath: String): Bitmap? {
        return try {
            val bitmap = BitmapFactory.decodeFile(filePath) ?: return null
            toCircle(bitmap)
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Resolves the avatar for display:
     *  - If [avatarFilePath] is non-null and the file loads → circular photo
     *  - Otherwise → null (caller lets the default drawable show)
     */
    fun resolve(avatarFilePath: String?, displayName: String): Bitmap? {
        if (!avatarFilePath.isNullOrEmpty()) {
            val bm = loadCircular(avatarFilePath)
            if (bm != null) return bm
        }
        return null
    }

    private fun toCircle(bitmap: Bitmap): Bitmap {
        val size = minOf(bitmap.width, bitmap.height)
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(output)
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
        val rect = android.graphics.Rect(0, 0, size, size)
        canvas.drawOval(android.graphics.RectF(rect), paint)
        paint.xfermode = android.graphics.PorterDuffXfermode(android.graphics.PorterDuff.Mode.SRC_IN)
        val x = (bitmap.width - size) / 2
        val y = (bitmap.height - size) / 2
        canvas.drawBitmap(bitmap, android.graphics.Rect(x, y, x + size, y + size), rect, paint)
        return output
    }
}
