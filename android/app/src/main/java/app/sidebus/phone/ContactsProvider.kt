package app.sidebus.phone

import android.Manifest
import android.content.ContentProvider
import android.content.ContentValues
import android.content.pm.PackageManager
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.provider.ContactsContract.CommonDataKinds.Phone

/**
 * Hands the phone's address book to the Mac, which reads it over adb with
 * `content query --uri content://app.sidebus.contacts/phones`, to complete names when
 * placing a call.
 *
 * Guarded by android.permission.DUMP in the manifest: the adb shell holds it, no
 * installed application can. Without the contacts permission the cursor is empty and
 * carries `permission` = 0 on its one row, so the Mac knows to open
 * [ContactsAccessActivity].
 */
class ContactsProvider : ContentProvider() {

    override fun onCreate() = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val context = context!!
        if (context.checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            return MatrixCursor(arrayOf("permission")).apply { addRow(arrayOf(0)) }
        }
        val result = MatrixCursor(arrayOf("name", "number", "starred", "times_contacted"))
        context.contentResolver.query(
            Phone.CONTENT_URI,
            arrayOf(Phone.DISPLAY_NAME, Phone.NUMBER, Phone.STARRED, Phone.TIMES_CONTACTED),
            null,
            null,
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                result.addRow(arrayOf(cursor.getString(0), cursor.getString(1), cursor.getInt(2), cursor.getInt(3)))
            }
        }
        return result
    }

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
}
