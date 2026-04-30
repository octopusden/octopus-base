package org.octopusden.octopus.quality.internal

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.nio.file.Path

class EditorConfigParserTest {
    @TempDir
    lateinit var tempDir: Path

    private fun writeEditorConfig(content: String): File {
        val file = tempDir.resolve(".editorconfig").toFile()
        file.writeText(content)
        return file
    }

    @Test
    fun `parses Kotlin section, drops root and other-language sections and comments`() {
        val file =
            writeEditorConfig(
                """
                # leading comment
                root = true

                [*.{kt,kts}]
                indent_style = space
                ; semicolon comment
                max_line_length = 140

                [*.java]
                indent_size = 2
                """.trimIndent(),
            )
        val parsed = EditorConfigParser.parseKotlinSection(file)

        assertEquals(mapOf("indent_style" to "space", "max_line_length" to "140"), parsed)
        assertFalse(parsed.containsKey("root"), "root meta-key must be skipped")
        assertFalse(parsed.containsKey("indent_size"), "java-section keys must be skipped")
    }

    @Test
    fun `drops charset because ktlint registry does not recognize it`() {
        val file =
            writeEditorConfig(
                """
                [*.{kt,kts}]
                charset = utf-8
                max_line_length = 140
                """.trimIndent(),
            )
        val parsed = EditorConfigParser.parseKotlinSection(file)

        assertFalse(parsed.containsKey("charset"), "charset is not a ktlint-recognized key")
        assertEquals("140", parsed["max_line_length"])
    }

    @Test
    fun `keeps ktlint-, ij_kotlin- and core editorconfig keys`() {
        val file =
            writeEditorConfig(
                """
                [*.{kt,kts}]
                ktlint_standard_foo = disabled
                ij_kotlin_allow_trailing_comma = true
                max_line_length = 140
                """.trimIndent(),
            )
        val parsed = EditorConfigParser.parseKotlinSection(file)

        assertTrue(parsed.containsKey("ktlint_standard_foo"))
        assertTrue(parsed.containsKey("ij_kotlin_allow_trailing_comma"))
        assertTrue(parsed.containsKey("max_line_length"))
        assertEquals(3, parsed.size)
    }

    @Test
    fun `drops keys that are neither prefixed nor in the core allow-list`() {
        val file =
            writeEditorConfig(
                """
                [*.{kt,kts}]
                tab_width = 4
                max_line_length = 140
                """.trimIndent(),
            )
        val parsed = EditorConfigParser.parseKotlinSection(file)

        assertFalse(parsed.containsKey("tab_width"), "tab_width is not in the allow-list")
        assertEquals("140", parsed["max_line_length"])
    }

    @Test
    fun `aggregates entries from multiple Kotlin-matching selectors`() {
        val file =
            writeEditorConfig(
                """
                [*.kt]
                max_line_length = 140

                [*.kts]
                indent_style = space

                [*.{kt,kts}]
                ij_kotlin_allow_trailing_comma = true
                """.trimIndent(),
            )
        val parsed = EditorConfigParser.parseKotlinSection(file)

        assertEquals(
            mapOf(
                "max_line_length" to "140",
                "indent_style" to "space",
                "ij_kotlin_allow_trailing_comma" to "true",
            ),
            parsed,
        )
    }

    @Test
    fun `real bundled editorconfig parses to expected canonical map`() {
        val resourcePath = "org/octopusden/octopus/quality/config/.editorconfig"
        val resourceStream =
            javaClass.classLoader.getResourceAsStream(resourcePath)
                ?: error("Bundled .editorconfig resource missing on classpath: $resourcePath")
        val target = tempDir.resolve(".editorconfig").toFile()
        resourceStream.use { input -> target.outputStream().use { output -> input.copyTo(output) } }

        val expected =
            mapOf(
                "end_of_line" to "lf",
                "indent_style" to "space",
                "indent_size" to "4",
                "insert_final_newline" to "true",
                "max_line_length" to "140",
                "ij_kotlin_allow_trailing_comma" to "true",
                "ij_kotlin_allow_trailing_comma_on_call_site" to "true",
                "ktlint_standard_multiline-expression-wrapping" to "disabled",
            )
        assertEquals(expected, EditorConfigParser.parseKotlinSection(target))
    }
}
