package com.jetsetslow.omniterm.ui

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.jetsetslow.omniterm.data.SftpFile

/**
 * An open file editor's unsaved text and edit mode.
 *
 * The ViewModel keeps it, not the screen: App Lock removes the whole app from the screen while it
 * is locked, and a rotation or a theme change rebuilds it, and the text typed so far must still be
 * there afterwards. Saving or closing the editor, or opening a file, starts a new draft.
 */
@Stable
class EditorDraft internal constructor(
    internal val file: SftpFile,
) {
    var text by mutableStateOf(file.content)
    var editMode by mutableStateOf(file.content.isEmpty())
}

/** One editor's draft. A draft belongs to the file object it was opened for. */
class EditorDraftSlot {
    private var current: EditorDraft? = null

    /** The draft for [file]: the one already open for it, or a new one with the file's content. */
    fun draftFor(file: SftpFile): EditorDraft {
        current?.takeIf { it.file === file }?.let { return it }
        return EditorDraft(file).also { current = it }
    }

    /** Drops the draft, when its editor closes. */
    fun clear() {
        current = null
    }
}
