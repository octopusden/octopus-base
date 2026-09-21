package org.octopusden.octopus.quality.internal

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class TaskSelectionTest {
    // A bare name excludes the task in every module.
    @Test
    fun `bare task name excludes the task in a subproject`() {
        assertTrue(isTaskExcluded(":client", "test", setOf("test")))
    }

    // The qualified form excludes it in exactly one module.
    @Test
    fun `qualified path excludes the task only in the named project`() {
        val excluded = setOf(":client:test")
        assertTrue(isTaskExcluded(":client", "test", excluded))
        assertFalse(isTaskExcluded(":server", "test", excluded))
    }

    @Test
    fun `an unlisted task is not excluded`() {
        assertFalse(isTaskExcluded(":client", "test", setOf("integrationTest")))
    }

    @Test
    fun `an empty exclusion set excludes nothing`() {
        assertFalse(isTaskExcluded(":client", "test", emptySet()))
    }

    // The root project's path is already ":", so naive interpolation would build "::test" and
    // silently fail to match. Single-module builds run every gate on the root, so this is the
    // case that would break them.
    @Test
    fun `root project qualifies to a single colon, not a double one`() {
        assertEquals(":test", qualifiedTaskPath(":", "test"))
        assertTrue(isTaskExcluded(":", "test", setOf(":test")))
        assertFalse(isTaskExcluded(":", "test", setOf("::test")))
    }

    @Test
    fun `subproject path is qualified by prefixing its path`() {
        assertEquals(":client:test", qualifiedTaskPath(":client", "test"))
        assertEquals(":a:b:test", qualifiedTaskPath(":a:b", "test"))
    }

    // --- coverage-suite selection ---

    @Test
    fun `the standard test task is always a coverage suite`() {
        assertTrue(isCoverageSuite(":client", "test", emptySet(), emptySet()))
    }

    // The default must not move: an extra Test task nobody declared is not a coverage suite.
    @Test
    fun `an undeclared extra Test task is not a coverage suite`() {
        assertFalse(isCoverageSuite(":client", "unitTest", emptySet(), emptySet()))
    }

    @Test
    fun `a declared extra Test task is a coverage suite`() {
        assertTrue(isCoverageSuite(":client", "unitTest", emptySet(), setOf("unitTest")))
    }

    // Declaration is unqualified, so one entry covers the task in every module that defines it.
    @Test
    fun `declaration by bare name applies in every module`() {
        val declared = setOf("unitTest")
        assertTrue(isCoverageSuite(":client", "unitTest", emptySet(), declared))
        assertTrue(isCoverageSuite(":server", "unitTest", emptySet(), declared))
    }

    @Test
    fun `exclusion wins over declaration`() {
        assertFalse(isCoverageSuite(":client", "unitTest", setOf(":client:unitTest"), setOf("unitTest")))
        assertFalse(isCoverageSuite(":client", "unitTest", setOf("unitTest"), setOf("unitTest")))
    }

    // The case that motivated the property: a docker-bound `test` is excluded while the
    // docker-free `unitTest` still counts, in the same module.
    @Test
    fun `excluding the default suite leaves a declared extra suite selected`() {
        val excluded = setOf(":client:test")
        val declared = setOf("unitTest")
        assertFalse(isCoverageSuite(":client", "test", excluded, declared))
        assertTrue(isCoverageSuite(":client", "unitTest", excluded, declared))
    }

    @Test
    fun `a root-project suite exclusion is honoured`() {
        assertFalse(isCoverageSuite(":", "test", setOf(":test"), emptySet()))
        assertTrue(isCoverageSuite(":", "test", setOf(":other"), emptySet()))
    }
}
