package org.octopusden.octopus.quality.internal

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class DetectedLanguagesTest {
    @Test
    fun `isKotlinOnly is true when only kotlin is detected`() {
        val langs = DetectedLanguages(hasKotlin = true, hasJava = false, hasGroovy = false)
        assertTrue(langs.isKotlinOnly)
    }

    @Test
    fun `isKotlinOnly is false when kotlin and java are both present`() {
        val langs = DetectedLanguages(hasKotlin = true, hasJava = true, hasGroovy = false)
        assertFalse(langs.isKotlinOnly)
    }

    @Test
    fun `isKotlinOnly is false when kotlin and groovy are both present`() {
        val langs = DetectedLanguages(hasKotlin = true, hasJava = false, hasGroovy = true)
        assertFalse(langs.isKotlinOnly)
    }

    @Test
    fun `isKotlinOnly is false when only java is detected`() {
        val langs = DetectedLanguages(hasKotlin = false, hasJava = true, hasGroovy = false)
        assertFalse(langs.isKotlinOnly)
    }

    @Test
    fun `isKotlinOnly is false when only groovy is detected`() {
        val langs = DetectedLanguages(hasKotlin = false, hasJava = false, hasGroovy = true)
        assertFalse(langs.isKotlinOnly)
    }

    @Test
    fun `isKotlinOnly is false when no languages are detected`() {
        val langs = DetectedLanguages(hasKotlin = false, hasJava = false, hasGroovy = false)
        assertFalse(langs.isKotlinOnly)
    }

    @Test
    fun `data class equality holds for identical values`() {
        val a = DetectedLanguages(hasKotlin = true, hasJava = false, hasGroovy = false)
        val b = DetectedLanguages(hasKotlin = true, hasJava = false, hasGroovy = false)
        assertEquals(a, b)
    }

    @Test
    fun `data class equality distinguishes differing values`() {
        val a = DetectedLanguages(hasKotlin = true, hasJava = false, hasGroovy = false)
        val b = DetectedLanguages(hasKotlin = false, hasJava = true, hasGroovy = false)
        assertNotEquals(a, b)
    }
}
