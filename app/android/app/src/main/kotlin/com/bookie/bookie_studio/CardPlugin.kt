package com.bookie.bookie_studio

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.util.Log
import androidx.annotation.NonNull
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileNotFoundException

/**
 * Write access to the microSD card in a USB-OTG reader.
 *
 * Android will not hand out a file path for removable storage, so everything
 * goes through the Storage Access Framework: the user points at the card's root
 * folder once, we take a persistable permission on the returned tree URI, and
 * from then on every path is resolved by walking children with
 * DocumentsContract.
 *
 * That walk is the expensive part — one cursor query per directory — so the
 * listing of each directory we touch is cached for the life of the plugin and
 * kept up to date as we create files. Without it, writing 60 clips would mean
 * a few hundred queries.
 */
class CardPlugin(private val context: Context) :
    MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {

    companion object {
        const val CHANNEL = "com.bookie.studio/card"
        private const val REQUEST_PICK_TREE = 0xB00C
        private const val TAG = "CardPlugin"
    }

    var activity: Activity? = null

    private var pendingPick: MethodChannel.Result? = null

    /** parent document id -> (child name -> child document id, isDirectory). */
    private val listingCache = HashMap<String, MutableMap<String, Child>>()

    private data class Child(val documentId: String, val isDirectory: Boolean)

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: MethodChannel.Result) {
        try {
            when (call.method) {
                "pick" -> pick(result)
                "resolve" -> result.success(describe(handleOf(call)))
                "list" -> result.success(list(handleOf(call), call.argument<String>("path")!!))
                "read" -> result.success(read(handleOf(call), call.argument<String>("path")!!))
                "writeBytes" -> result.success(
                    writeBytes(
                        handleOf(call),
                        call.argument<String>("path")!!,
                        call.argument<ByteArray>("bytes")!!
                    )
                )
                "copy" -> result.success(
                    copyIn(
                        handleOf(call),
                        call.argument<String>("path")!!,
                        call.argument<String>("src")!!
                    )
                )
                "copyOut" -> result.success(
                    copyOut(
                        handleOf(call),
                        call.argument<String>("path")!!,
                        call.argument<String>("dest")!!
                    )
                )
                "delete" -> result.success(delete(handleOf(call), call.argument<String>("path")!!))
                "release" -> {
                    listingCache.clear()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: CardGone) {
            result.error("unavailable", e.message, null)
        } catch (e: Exception) {
            Log.e(TAG, "${call.method} failed", e)
            result.error("failed", e.message ?: e.toString(), null)
        }
    }

    private class CardGone(message: String) : Exception(message)

    private fun handleOf(call: MethodCall): Uri =
        Uri.parse(call.argument<String>("handle") ?: throw CardGone("No card selected."))

    // ------------------------------------------------------------- picking

    private fun pick(result: MethodChannel.Result) {
        val activity = this.activity
            ?: return result.error("failed", "No activity to show the picker on.", null)
        if (pendingPick != null) {
            return result.error("failed", "A folder picker is already open.", null)
        }
        pendingPick = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
            // Nudge the picker towards removable volumes rather than Documents.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                primaryVolumeUri()?.let { putExtra(DocumentsContract.EXTRA_INITIAL_URI, it) }
            }
        }
        activity.startActivityForResult(intent, REQUEST_PICK_TREE)
    }

    private fun primaryVolumeUri(): Uri? = try {
        val storage = context.getSystemService(Context.STORAGE_SERVICE) as StorageManager
        storage.storageVolumes.firstOrNull { it.isRemovable }?.let { volume ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) volume.createOpenDocumentTreeIntent()
                .getParcelableExtra(DocumentsContract.EXTRA_INITIAL_URI) else null
        }
    } catch (e: Exception) {
        null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_TREE) return false
        val result = pendingPick ?: return true
        pendingPick = null

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        try {
            context.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (e: SecurityException) {
            Log.w(TAG, "could not persist permission for $uri", e)
        }
        listingCache.clear()
        result.success(describe(uri))
        return true
    }

    /** null when the grant is gone or the reader was unplugged. */
    private fun describe(tree: Uri): Map<String, Any?>? {
        val held = context.contentResolver.persistedUriPermissions.any {
            it.uri == tree && it.isWritePermission
        }
        if (!held) return null

        val rootId = DocumentsContract.getTreeDocumentId(tree)
        val rootUri = DocumentsContract.buildDocumentUriUsingTree(tree, rootId)
        var name = "Card"
        try {
            context.contentResolver.query(
                rootUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) name = cursor.getString(0) ?: name
            } ?: return null
        } catch (e: Exception) {
            return null // the volume went away between the check and the query
        }

        var free: Long? = null
        var total: Long? = null
        try {
            context.contentResolver.openFileDescriptor(rootUri, "r")?.use { fd ->
                val stat = android.system.Os.fstatvfs(fd.fileDescriptor)
                free = stat.f_bavail * stat.f_frsize
                total = stat.f_blocks * stat.f_frsize
            }
        } catch (e: Exception) {
            // Directories are not always openable; free space is a nicety.
        }

        return mapOf(
            "handle" to tree.toString(),
            "name" to name,
            "freeBytes" to free,
            "totalBytes" to total
        ) + whereItPointsAt(tree)
    }

    /**
     * Which volume, and how deep into it, the user actually pointed the picker.
     *
     * Two mistakes write happily and leave the toy with an empty card: choosing
     * the phone's own storage instead of the reader, and choosing a folder on
     * the card rather than the card itself. Neither fails, so the only way to
     * catch them is to look at the tree URI and say so. External storage
     * document ids read "primary:Download" or "1A2B-3C4D:" — volume, colon,
     * path within it. Any other provider (Drive, MTP, a file manager of its
     * own) is not a card either, and we cannot tell where it points, so both
     * answers come back null and the app stays quiet.
     */
    private fun whereItPointsAt(tree: Uri): Map<String, Any?> {
        if (tree.authority != "com.android.externalstorage.documents") {
            return mapOf("location" to null, "removable" to null, "atRoot" to null)
        }
        val id = DocumentsContract.getTreeDocumentId(tree)
        val volume = id.substringBefore(':')
        val within = id.substringAfter(':', "").trim('/')
        return mapOf(
            "location" to "$volume:/$within",
            "removable" to (volume != "primary" && volume != "home"),
            "atRoot" to within.isEmpty()
        )
    }

    // ------------------------------------------------------------- walking

    /** Children of [documentId], read once and remembered. */
    private fun childrenOf(tree: Uri, documentId: String): MutableMap<String, Child> {
        listingCache[documentId]?.let { return it }

        val children = LinkedHashMap<String, Child>()
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, documentId)
        try {
            context.contentResolver.query(
                uri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                ),
                null, null, null
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getString(0) ?: continue
                    val name = cursor.getString(1) ?: continue
                    val mime = cursor.getString(2)
                    children[name] = Child(id, mime == DocumentsContract.Document.MIME_TYPE_DIR)
                }
            }
        } catch (e: Exception) {
            throw CardGone("The card is no longer reachable.")
        }
        listingCache[documentId] = children
        return children
    }

    private fun segmentsOf(path: String) = path.split('/').filter { it.isNotEmpty() }

    /** Document id for [path], or null if any segment is missing. */
    private fun resolve(tree: Uri, path: String): Child? {
        var current = Child(DocumentsContract.getTreeDocumentId(tree), true)
        for (segment in segmentsOf(path)) {
            if (!current.isDirectory) return null
            current = childrenOf(tree, current.documentId)[segment] ?: return null
        }
        return current
    }

    /** Document id for the directory holding [path], creating it if needed. */
    private fun resolveParent(tree: Uri, path: String): String {
        var parentId = DocumentsContract.getTreeDocumentId(tree)
        val segments = segmentsOf(path)
        for (segment in segments.dropLast(1)) {
            val cache = childrenOf(tree, parentId)
            val existing = cache[segment]
            parentId = if (existing != null && existing.isDirectory) {
                existing.documentId
            } else {
                val created = DocumentsContract.createDocument(
                    context.contentResolver,
                    DocumentsContract.buildDocumentUriUsingTree(tree, parentId),
                    DocumentsContract.Document.MIME_TYPE_DIR,
                    segment
                ) ?: throw CardGone("Could not create /$segment on the card.")
                val id = DocumentsContract.getDocumentId(created)
                cache[segment] = Child(id, true)
                id
            }
        }
        return parentId
    }

    // ------------------------------------------------------------- files

    private fun list(tree: Uri, path: String): List<Map<String, Any?>> {
        val dir = resolve(tree, path) ?: return emptyList()
        if (!dir.isDirectory) return emptyList()

        val out = ArrayList<Map<String, Any?>>()
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, dir.documentId)
        val cache = LinkedHashMap<String, Child>()
        context.contentResolver.query(
            uri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE
            ),
            null, null, null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                val isDir = cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR
                cache[name] = Child(id, isDir)
                out.add(
                    mapOf(
                        "name" to name,
                        "isDirectory" to isDir,
                        "size" to if (cursor.isNull(3)) 0L else cursor.getLong(3)
                    )
                )
            }
        } ?: throw CardGone("The card is no longer reachable.")
        listingCache[dir.documentId] = cache
        return out
    }

    private fun read(tree: Uri, path: String): ByteArray? {
        val file = resolve(tree, path) ?: return null
        if (file.isDirectory) return null
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, file.documentId)
        return try {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (e: FileNotFoundException) {
            null
        }
    }

    /**
     * Open [path] for writing, creating it if it is not there. Truncation
     * matters: "w" leaves the tail of a longer previous file behind on some
     * providers, so "wt" is the mode to ask for, with a manual truncate as the
     * fallback for providers that do not honour it.
     */
    private fun openForWrite(tree: Uri, path: String): Uri {
        val existing = resolve(tree, path)
        if (existing != null && !existing.isDirectory) {
            return DocumentsContract.buildDocumentUriUsingTree(tree, existing.documentId)
        }
        val parentId = resolveParent(tree, path)
        val name = segmentsOf(path).last()
        val created = DocumentsContract.createDocument(
            context.contentResolver,
            DocumentsContract.buildDocumentUriUsingTree(tree, parentId),
            mimeFor(name),
            name
        ) ?: throw CardGone("Could not create $path on the card.")

        // Some providers append a suffix when the name is taken; trust what
        // came back rather than the name we asked for.
        val id = DocumentsContract.getDocumentId(created)
        listingCache[parentId]?.put(name, Child(id, false))
        return created
    }

    private fun mimeFor(name: String) = when (name.substringAfterLast('.', "").lowercase()) {
        "mp3" -> "audio/mpeg"
        "wav" -> "audio/wav"
        "csv" -> "text/csv"
        "json" -> "application/json"
        else -> "application/octet-stream"
    }

    private fun writeBytes(tree: Uri, path: String, bytes: ByteArray): Long {
        val uri = openForWrite(tree, path)
        context.contentResolver.openOutputStream(uri, "wt")?.use { out ->
            out.write(bytes)
            out.flush()
        } ?: throw CardGone("Could not open $path for writing.")
        return bytes.size.toLong()
    }

    private fun copyIn(tree: Uri, path: String, sourcePath: String): Long {
        val source = File(sourcePath)
        if (!source.exists()) throw FileNotFoundException("$sourcePath is gone")
        val uri = openForWrite(tree, path)
        var written = 0L
        context.contentResolver.openOutputStream(uri, "wt")?.use { out ->
            source.inputStream().use { input -> written = input.copyTo(out, 64 * 1024) }
            out.flush()
        } ?: throw CardGone("Could not open $path for writing.")
        return written
    }

    private fun copyOut(tree: Uri, path: String, destPath: String): Long {
        val file = resolve(tree, path) ?: throw FileNotFoundException("$path is not on the card")
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, file.documentId)
        val dest = File(destPath)
        dest.parentFile?.mkdirs()
        var read = 0L
        context.contentResolver.openInputStream(uri)?.use { input ->
            dest.outputStream().use { out -> read = input.copyTo(out, 64 * 1024) }
        } ?: throw CardGone("Could not read $path from the card.")
        return read
    }

    private fun delete(tree: Uri, path: String): Boolean {
        val file = resolve(tree, path) ?: return false
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, file.documentId)
        val gone = DocumentsContract.deleteDocument(context.contentResolver, uri)
        if (gone) {
            val segments = segmentsOf(path)
            val parent = resolve(tree, segments.dropLast(1).joinToString("/"))
            parent?.let { listingCache[it.documentId]?.remove(segments.last()) }
        }
        return gone
    }
}
