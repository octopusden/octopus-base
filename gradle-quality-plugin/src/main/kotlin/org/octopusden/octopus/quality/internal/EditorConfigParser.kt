package org.octopusden.octopus.quality.internal

import java.io.File

/**
 * Reads the bundled `.editorconfig` and returns flat key/value pairs from the
 * Kotlin sections, suitable for ktlint-gradle's `additionalEditorconfig`
 * `MapProperty`.
 *
 * Filters to keys ktlint's EditorConfigPropertyRegistry recognizes — feeding
 * an unknown key (e.g. `charset`) through `additionalEditorconfig` causes
 * `EditorConfigPropertyNotFoundException` at task wiring. Allow-list is preferred
 * over deny-list so an accidental edit to the bundled file (e.g. someone adds
 * `tab_width`) doesn't silently break ktlint.
 *
 * Top-level `root = true` and comment/blank lines are skipped.
 */
internal object EditorConfigParser {
    private val KOTLIN_SECTIONS = setOf("*.{kt,kts}", "*.kt", "*.kts")

    // ktlint 1.5.0 EditorConfigPropertyRegistry core keys (verified against
    // ktlint-gradle 14.0.1 / 14.2.0). Keep in sync if/when the bundled file
    // adds new core editorconfig knobs.
    private val ALLOWED_CORE_KEYS =
        setOf(
            "end_of_line",
            "indent_style",
            "indent_size",
            "insert_final_newline",
            "max_line_length",
        )

    fun parseKotlinSection(file: File): Map<String, String> {
        val result = LinkedHashMap<String, String>()
        var inKotlinSection = false
        for (raw in file.readLines()) {
            val line = raw.trim()
            when {
                line.isEmpty() || line.startsWith("#") || line.startsWith(";") -> Unit
                line.startsWith("[") && line.endsWith("]") -> {
                    inKotlinSection = line.substring(1, line.length - 1).trim() in KOTLIN_SECTIONS
                }
                inKotlinSection -> appendAssignment(line, result)
            }
        }
        return result
    }

    private fun appendAssignment(
        line: String,
        result: MutableMap<String, String>,
    ) {
        val eq = line.indexOf('=')
        if (eq <= 0) return
        val key = line.substring(0, eq).trim()
        val value = line.substring(eq + 1).trim()
        if (isKtlintKey(key)) result[key] = value
    }

    private fun isKtlintKey(key: String): Boolean =
        key.startsWith("ktlint_") ||
            key.startsWith("ij_kotlin_") ||
            key in ALLOWED_CORE_KEYS
}
