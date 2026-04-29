package org.octopusden.octopus.quality.internal

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.octopusden.octopus.quality.CoverageExtension

class CoverageToolResolverTest {
    private fun languages(
        hasKotlin: Boolean = false,
        hasJava: Boolean = false,
        hasGroovy: Boolean = false,
    ) = DetectedLanguages(hasKotlin = hasKotlin, hasJava = hasJava, hasGroovy = hasGroovy)

    // AUTO + Kotlin-only → KOVER
    @Test
    fun `AUTO on kotlin-only project resolves to KOVER`() {
        val result =
            resolveCoverageTool(
                CoverageExtension.Tool.AUTO,
                languages(hasKotlin = true),
            )
        assertEquals(CoverageExtension.Tool.KOVER, result)
    }

    // AUTO + Kotlin + Java (mixed) → JACOCO
    @Test
    fun `AUTO on mixed kotlin-java project resolves to JACOCO`() {
        val result =
            resolveCoverageTool(
                CoverageExtension.Tool.AUTO,
                languages(hasKotlin = true, hasJava = true),
            )
        assertEquals(CoverageExtension.Tool.JACOCO, result)
    }

    // AUTO + Java-only → JACOCO
    @Test
    fun `AUTO on java-only project resolves to JACOCO`() {
        val result =
            resolveCoverageTool(
                CoverageExtension.Tool.AUTO,
                languages(hasJava = true),
            )
        assertEquals(CoverageExtension.Tool.JACOCO, result)
    }

    // AUTO + Groovy → JACOCO (not kotlin-only)
    @Test
    fun `AUTO on groovy project resolves to JACOCO`() {
        val result =
            resolveCoverageTool(
                CoverageExtension.Tool.AUTO,
                languages(hasGroovy = true),
            )
        assertEquals(CoverageExtension.Tool.JACOCO, result)
    }

    // AUTO + Kotlin + Groovy (mixed) → JACOCO
    @Test
    fun `AUTO on kotlin-groovy project resolves to JACOCO`() {
        val result =
            resolveCoverageTool(
                CoverageExtension.Tool.AUTO,
                languages(hasKotlin = true, hasGroovy = true),
            )
        assertEquals(CoverageExtension.Tool.JACOCO, result)
    }

    // Explicit JACOCO overrides AUTO logic
    @Test
    fun `explicit JACOCO is returned unchanged regardless of languages`() {
        val result =
            resolveCoverageTool(
                CoverageExtension.Tool.JACOCO,
                languages(hasKotlin = true),
            )
        assertEquals(CoverageExtension.Tool.JACOCO, result)
    }

    // Explicit KOVER overrides AUTO logic
    @Test
    fun `explicit KOVER is returned unchanged regardless of languages`() {
        val result =
            resolveCoverageTool(
                CoverageExtension.Tool.KOVER,
                languages(hasJava = true),
            )
        assertEquals(CoverageExtension.Tool.KOVER, result)
    }
}
