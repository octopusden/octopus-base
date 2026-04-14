package org.octopusden.octopus.quality

import org.gradle.testkit.runner.GradleRunner
import org.gradle.testkit.runner.TaskOutcome
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class OctopusQualityPluginFunctionalTest {
    @TempDir
    lateinit var projectDir: File

    private fun settingsFile(content: String) {
        File(projectDir, "settings.gradle.kts").writeText(content)
    }

    private fun buildFile(content: String) {
        File(projectDir, "build.gradle.kts").writeText(content)
    }

    private fun subDir(path: String): File = File(projectDir, path).also { it.mkdirs() }

    private fun writeKotlinFile(
        path: String,
        content: String,
    ) {
        val file = File(projectDir, path)
        file.parentFile.mkdirs()
        file.writeText(content)
    }

    private fun runner(vararg args: String) =
        GradleRunner
            .create()
            .withProjectDir(projectDir)
            .withPluginClasspath()
            .withGradleVersion("8.9")
            .withArguments(*args, "--stacktrace")
            .forwardOutput()

    /**
     * Settings preamble that makes Kotlin/detekt/ktlint resolvable from Gradle Plugin Portal.
     * Our plugin is injected by withPluginClasspath(), so no version needed for it.
     */
    private fun kotlinSettings(
        projectName: String,
        extraIncludes: String = "",
    ) = """
        pluginManagement {
            repositories {
                gradlePluginPortal()
                mavenCentral()
            }
        }
        rootProject.name = "$projectName"
        $extraIncludes
        """.trimIndent()

    // ---------------------------------------------------------------
    // 1. Single-module Kotlin: qualityStatic registers and runs
    // ---------------------------------------------------------------
    @Test
    fun `single-module Kotlin repo - qualityStatic succeeds`() {
        settingsFile(kotlinSettings("test-single-kotlin"))
        buildFile(
            """
            plugins {
                kotlin("jvm") version "1.9.25"
                id("io.gitlab.arturbosch.detekt") version "1.23.5"
                id("org.jlleitschuh.gradle.ktlint") version "14.0.1"
                id("org.octopusden.octopus-quality")
            }
            repositories { mavenCentral() }
            octopusQuality {
                kotlin { failOnViolation.set(false) }
                java { failOnViolation.set(false) }
                coverage { enabled.set(false) }
            }
            """.trimIndent(),
        )
        writeKotlinFile(
            "src/main/kotlin/com/example/Hello.kt",
            "package com.example\nfun hello() = \"Hello\"\n",
        )

        val result = runner("qualityStatic").build()
        assertEquals(TaskOutcome.SUCCESS, result.task(":qualityStatic")?.outcome)
    }

    // ---------------------------------------------------------------
    // 2. Multi-module Kotlin: tasks wired across subprojects
    // ---------------------------------------------------------------
    @Test
    fun `multi-module Kotlin repo - qualityStatic wires subprojects`() {
        settingsFile(kotlinSettings("test-multi-kotlin", """include("lib")"""))
        buildFile(
            """
            plugins {
                kotlin("jvm") version "1.9.25" apply false
                id("io.gitlab.arturbosch.detekt") version "1.23.5" apply false
                id("org.jlleitschuh.gradle.ktlint") version "14.0.1" apply false
                id("org.octopusden.octopus-quality")
            }
            subprojects {
                apply(plugin = "org.jetbrains.kotlin.jvm")
                apply(plugin = "io.gitlab.arturbosch.detekt")
                apply(plugin = "org.jlleitschuh.gradle.ktlint")
                repositories { mavenCentral() }
            }
            octopusQuality {
                kotlin { failOnViolation.set(false) }
                java { failOnViolation.set(false) }
                coverage { enabled.set(false) }
            }
            """.trimIndent(),
        )
        writeKotlinFile(
            "lib/src/main/kotlin/com/example/Lib.kt",
            "package com.example\nfun lib() = 42\n",
        )

        val result = runner("qualityStatic").build()
        assertEquals(TaskOutcome.SUCCESS, result.task(":qualityStatic")?.outcome)
        assertTrue(result.output.contains(":lib:detekt"))
    }

    // ---------------------------------------------------------------
    // 3. Groovy-only: codenarc + checkstyle + pmd applied
    // ---------------------------------------------------------------
    @Test
    fun `groovy-only repo - qualityStatic applies codenarc`() {
        settingsFile(kotlinSettings("test-groovy"))
        buildFile(
            """
            plugins {
                groovy
                id("org.octopusden.octopus-quality")
            }
            repositories { mavenCentral() }
            dependencies { implementation(localGroovy()) }
            octopusQuality {
                groovy { failOnViolation.set(false) }
                java { failOnViolation.set(false) }
                coverage { enabled.set(false) }
            }
            """.trimIndent(),
        )
        subDir("src/main/groovy/com/example")
        File(projectDir, "src/main/groovy/com/example/Hello.groovy")
            .writeText("package com.example\nclass Hello { String greet() { 'hi' } }\n")

        val result = runner("qualityStatic").build()
        assertEquals(TaskOutcome.SUCCESS, result.task(":qualityStatic")?.outcome)
        assertTrue(result.output.contains("codenarcMain"))
    }

    // ---------------------------------------------------------------
    // 4. coverage.enabled = false: no verification tasks in graph
    // ---------------------------------------------------------------
    @Test
    fun `coverage disabled - qualityCoverage skips verification`() {
        settingsFile(kotlinSettings("test-no-coverage"))
        buildFile(
            """
            plugins {
                kotlin("jvm") version "1.9.25"
                id("org.octopusden.octopus-quality")
            }
            repositories { mavenCentral() }
            octopusQuality {
                coverage { enabled.set(false) }
            }
            """.trimIndent(),
        )
        writeKotlinFile(
            "src/main/kotlin/com/example/Hello.kt",
            "package com.example\nfun hello() = \"Hello\"\n",
        )

        val result = runner("qualityCoverage", "--dry-run").build()
        assertTrue(!result.output.contains("jacocoTestCoverageVerification"))
    }

    // ---------------------------------------------------------------
    // 5. coverageExcludedProjects does NOT leak into qualityStatic
    // ---------------------------------------------------------------
    @Test
    fun `coverageExcludedProjects does not affect qualityStatic`() {
        settingsFile(
            kotlinSettings(
                "test-exclude",
                """
                include("app")
                include("test-utils")
                """.trimIndent(),
            ),
        )
        buildFile(
            """
            plugins {
                kotlin("jvm") version "1.9.25" apply false
                id("io.gitlab.arturbosch.detekt") version "1.23.5" apply false
                id("org.jlleitschuh.gradle.ktlint") version "14.0.1" apply false
                id("org.octopusden.octopus-quality")
            }
            subprojects {
                apply(plugin = "org.jetbrains.kotlin.jvm")
                apply(plugin = "io.gitlab.arturbosch.detekt")
                apply(plugin = "org.jlleitschuh.gradle.ktlint")
                repositories { mavenCentral() }
            }
            octopusQuality {
                kotlin { failOnViolation.set(false) }
                java { failOnViolation.set(false) }
                coverage { enabled.set(false) }
                excludeProjects("test-utils")
            }
            """.trimIndent(),
        )
        writeKotlinFile(
            "app/src/main/kotlin/com/example/App.kt",
            "package com.example\nfun app() = 1\n",
        )
        writeKotlinFile(
            "test-utils/src/main/kotlin/com/example/Utils.kt",
            "package com.example\nfun util() = 2\n",
        )

        val result = runner("qualityStatic", "--dry-run").build()
        // test-utils must still be in qualityStatic (not excluded)
        assertTrue(result.output.contains(":test-utils:detekt"))
        assertTrue(result.output.contains(":app:detekt"))
    }
}
