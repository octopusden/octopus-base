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

    /** Full POM that passes Maven Central requirements — used by validator tests. */
    private val fullPom =
        """
        pom {
            name.set("test")
            description.set("test library")
            url.set("https://example.com")
            licenses {
                license {
                    name.set("The Apache License, Version 2.0")
                    url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                }
            }
            scm {
                url.set("https://github.com/octopusden/test")
                connection.set("scm:git://github.com/octopusden/test.git")
            }
            developers {
                developer {
                    id.set("test")
                    name.set("test")
                }
            }
        }
        """.trimIndent()

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

    // ---------------------------------------------------------------
    // 6. Publication validator: valid jar publication passes
    // ---------------------------------------------------------------
    @Test
    fun `validatePublications passes for complete jar publication`() {
        settingsFile(kotlinSettings("test-pub-valid"))
        buildFile(
            """
            plugins {
                kotlin("jvm") version "1.9.25"
                `maven-publish`
                id("org.octopusden.octopus-quality")
            }
            repositories { mavenCentral() }
            group = "org.example"
            version = "1.0.0"
            java { withSourcesJar(); withJavadocJar() }
            publishing {
                publications {
                    create<MavenPublication>("mavenJava") {
                        from(components["java"])
                        $fullPom
                    }
                }
            }
            octopusQuality { coverage { enabled.set(false) } }
            """.trimIndent(),
        )
        writeKotlinFile("src/main/kotlin/com/example/Hello.kt", "package com.example\nfun hello() = 1\n")

        val result = runner("validatePublications").build()
        assertEquals(TaskOutcome.SUCCESS, result.task(":validatePublications")?.outcome)
        assertTrue(result.output.contains("passed Maven Central checks"))
    }

    // ---------------------------------------------------------------
    // 7. Publication validator: missing sources JAR fails
    // ---------------------------------------------------------------
    @Test
    fun `validatePublications fails when sources JAR is missing`() {
        settingsFile(kotlinSettings("test-pub-no-sources"))
        buildFile(
            """
            plugins {
                kotlin("jvm") version "1.9.25"
                `maven-publish`
                id("org.octopusden.octopus-quality")
            }
            repositories { mavenCentral() }
            group = "org.example"
            version = "1.0.0"
            java { withJavadocJar() }
            publishing {
                publications {
                    create<MavenPublication>("mavenJava") {
                        from(components["java"])
                        $fullPom
                    }
                }
            }
            octopusQuality { coverage { enabled.set(false) } }
            """.trimIndent(),
        )
        writeKotlinFile("src/main/kotlin/com/example/Hello.kt", "package com.example\nfun hello() = 1\n")

        val result = runner("validatePublications").buildAndFail()
        assertTrue(result.output.contains("sources JAR missing"))
    }

    // ---------------------------------------------------------------
    // 8. Publication validator: missing javadoc JAR fails
    // ---------------------------------------------------------------
    @Test
    fun `validatePublications fails when javadoc JAR is missing`() {
        settingsFile(kotlinSettings("test-pub-no-javadoc"))
        buildFile(
            """
            plugins {
                kotlin("jvm") version "1.9.25"
                `maven-publish`
                id("org.octopusden.octopus-quality")
            }
            repositories { mavenCentral() }
            group = "org.example"
            version = "1.0.0"
            java { withSourcesJar() }
            publishing {
                publications {
                    create<MavenPublication>("mavenJava") {
                        from(components["java"])
                        $fullPom
                    }
                }
            }
            octopusQuality { coverage { enabled.set(false) } }
            """.trimIndent(),
        )
        writeKotlinFile("src/main/kotlin/com/example/Hello.kt", "package com.example\nfun hello() = 1\n")

        val result = runner("validatePublications").buildAndFail()
        assertTrue(result.output.contains("javadoc JAR missing"))
    }

    // ---------------------------------------------------------------
    // 9. Publication validator: missing POM fields fail
    // ---------------------------------------------------------------
    @Test
    fun `validatePublications fails when POM fields are missing`() {
        settingsFile(kotlinSettings("test-pub-no-pom"))
        buildFile(
            """
            plugins {
                kotlin("jvm") version "1.9.25"
                `maven-publish`
                id("org.octopusden.octopus-quality")
            }
            repositories { mavenCentral() }
            group = "org.example"
            version = "1.0.0"
            java { withSourcesJar(); withJavadocJar() }
            publishing {
                publications {
                    create<MavenPublication>("mavenJava") {
                        from(components["java"])
                        // no pom metadata at all
                    }
                }
            }
            octopusQuality { coverage { enabled.set(false) } }
            """.trimIndent(),
        )
        writeKotlinFile("src/main/kotlin/com/example/Hello.kt", "package com.example\nfun hello() = 1\n")

        val result = runner("validatePublications").buildAndFail()
        assertTrue(result.output.contains("POM <name> is missing"))
        assertTrue(result.output.contains("POM <description> is missing"))
        assertTrue(result.output.contains("POM <url> is missing"))
        assertTrue(result.output.contains("POM <licenses> section is missing"))
        assertTrue(result.output.contains("POM <developers> section is missing"))
        assertTrue(result.output.contains("POM <scm> section is missing"))
    }

    // ---------------------------------------------------------------
    // 10. Publication validator: pom-only publication passes without sources/javadoc
    // ---------------------------------------------------------------
    @Test
    fun `validatePublications passes for pom-only publication`() {
        settingsFile(kotlinSettings("test-pub-pom-only"))
        buildFile(
            """
            plugins {
                `java-platform`
                `maven-publish`
                id("org.octopusden.octopus-quality")
            }
            publishing {
                publications {
                    create<MavenPublication>("bom") {
                        from(components["javaPlatform"])
                        pom {
                            name.set("test-bom")
                            description.set("test BOM")
                            url.set("https://example.com")
                            licenses {
                                license {
                                    name.set("Apache-2.0")
                                    url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                                }
                            }
                            scm { url.set("https://github.com/octopusden/test") }
                            developers { developer { id.set("test"); name.set("test") } }
                        }
                    }
                }
            }
            octopusQuality { coverage { enabled.set(false) } }
            """.trimIndent(),
        )

        val result = runner("validatePublications").build()
        assertEquals(TaskOutcome.SUCCESS, result.task(":validatePublications")?.outcome)
        assertTrue(result.output.contains("passed Maven Central checks"))
    }

    // ---------------------------------------------------------------
    // 11. Nested <name> in licenses does not satisfy top-level <name>
    // ---------------------------------------------------------------
    @Test
    fun `validatePublications rejects POM with nested name but no top-level name`() {
        settingsFile(kotlinSettings("test-pub-nested-name"))
        buildFile(
            """
            plugins {
                kotlin("jvm") version "1.9.25"
                `maven-publish`
                id("org.octopusden.octopus-quality")
            }
            repositories { mavenCentral() }
            group = "org.example"
            version = "1.0.0"
            java { withSourcesJar(); withJavadocJar() }
            publishing {
                publications {
                    create<MavenPublication>("mavenJava") {
                        from(components["java"])
                        pom {
                            // NO top-level name/description set
                            url.set("https://example.com")
                            licenses {
                                license {
                                    // This <name> is nested inside <license>, not top-level
                                    name.set("Apache-2.0")
                                    url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                                }
                            }
                            scm { url.set("https://github.com/octopusden/test") }
                            developers { developer { id.set("test"); name.set("test") } }
                        }
                    }
                }
            }
            octopusQuality { coverage { enabled.set(false) } }
            """.trimIndent(),
        )
        writeKotlinFile("src/main/kotlin/com/example/Hello.kt", "package com.example\nfun hello() = 1\n")

        val result = runner("validatePublications").buildAndFail()
        // Must fail on BOTH top-level name and description
        assertTrue(result.output.contains("POM <name> is missing"))
        assertTrue(result.output.contains("POM <description> is missing"))
        // url is set, so should NOT be in errors
        assertTrue(!result.output.contains("POM <url> is missing"))
    }

    // ---------------------------------------------------------------
    // Regression: config extraction must survive `clean` task
    // ---------------------------------------------------------------
    @Test
    fun `detekt config survives clean build cycle`() {
        settingsFile(kotlinSettings("test-clean-cycle"))
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
            // Explicit ordering: detekt must run AFTER clean, so the test
            // deterministically exercises the "config wiped by clean" path.
            tasks.named("detekt") { mustRunAfter(tasks.named("clean")) }
            """.trimIndent(),
        )
        writeKotlinFile(
            "src/main/kotlin/com/example/Hello.kt",
            "package com.example\nfun hello() = \"Hello\"\n",
        )

        // Clean and detekt in a single build — reproduces CI `gradle clean build` scenario.
        // If config lived under build/, :clean would delete it before :detekt reads it.
        val result = runner("clean", "detekt").build()
        // :clean may be UP_TO_DATE on a fresh workspace (no build dir to remove);
        // the important invariant is that it executed and :detekt succeeded afterwards.
        assertTrue(result.task(":clean")?.outcome in setOf(TaskOutcome.SUCCESS, TaskOutcome.UP_TO_DATE))
        assertEquals(TaskOutcome.SUCCESS, result.task(":detekt")?.outcome)
    }

    // ---------------------------------------------------------------
    // Regression A: ktlint baseline must take effect on the first build cycle.
    // Locks in the timing fix — pre-fix, `ext.baseline.set(...)` ran inside
    // subproject.afterEvaluate, too late for ktlint-gradle 14.0.1 to wire the
    // baseline into its check tasks, so a baselined violation still failed the build.
    // ---------------------------------------------------------------
    @Test
    fun `ktlint baselined violation passes after clean - locks in timing fix`() {
        settingsFile(kotlinSettings("test-ktlint-baseline"))
        buildFile(
            """
            plugins {
                kotlin("jvm") version "1.9.25"
                id("org.jlleitschuh.gradle.ktlint") version "14.0.1"
                id("org.octopusden.octopus-quality")
            }
            repositories { mavenCentral() }
            octopusQuality {
                kotlin { failOnViolation.set(true) }
                coverage { enabled.set(false) }
            }
            tasks.named("ktlintCheck") { mustRunAfter(tasks.named("clean")) }
            """.trimIndent(),
        )
        // Missing final newline → ktlint flags `standard:final-newline`.
        writeKotlinFile(
            "src/main/kotlin/com/example/Bad.kt",
            "package com.example\nfun foo() = 1",
        )

        // Phase 1: capture the violation into a real baseline file via ktlint-gradle's
        // own task — avoids us hand-rolling the baseline XML schema. The convention
        // plugin sets ext.baseline to <projectDir>/ktlint-baseline.xml unconditionally,
        // so ktlintGenerateBaseline writes there directly (no copy needed).
        runner("ktlintGenerateBaseline").build()
        assertTrue(File(projectDir, "ktlint-baseline.xml").exists(), "baseline not written to convention path")

        // Phase 2: with the baseline file pre-existing on the next Gradle invocation,
        // the convention plugin must wire it BEFORE ktlint-gradle reads its task config.
        // Pre-fix: this would still fail with the baselined violation reported.
        val result = runner("clean", "ktlintCheck").build()
        assertEquals(TaskOutcome.SUCCESS, result.task(":ktlintCheck")?.outcome)
    }

    // ---------------------------------------------------------------
    // Regression B: an unbaselined violation must fail the build when the consumer
    // sets `failOnViolation = true`. Locks in lazy `Provider` wiring — pre-fix, an
    // eager `.get()` inside the early withId callback would freeze the convention
    // default (`false`), translating the consumer's `true` override into
    // `ignoreFailures = true` and silently passing.
    // ---------------------------------------------------------------
    @Test
    fun `ktlint unbaselined violation fails when failOnViolation is true - locks in lazy provider wiring`() {
        settingsFile(kotlinSettings("test-ktlint-fail-on-violation"))
        buildFile(
            """
            plugins {
                kotlin("jvm") version "1.9.25"
                id("org.jlleitschuh.gradle.ktlint") version "14.0.1"
                id("org.octopusden.octopus-quality")
            }
            repositories { mavenCentral() }
            octopusQuality {
                kotlin { failOnViolation.set(true) }
                coverage { enabled.set(false) }
            }
            tasks.named("ktlintCheck") { mustRunAfter(tasks.named("clean")) }
            """.trimIndent(),
        )
        writeKotlinFile(
            "src/main/kotlin/com/example/Bad.kt",
            "package com.example\nfun foo() = 1",
        )

        val result = runner("clean", "ktlintCheck").buildAndFail()
        assertTrue(
            result.output.contains("Bad.kt"),
            "Expected ktlint failure output to mention Bad.kt; got: ${result.output}",
        )
    }

    // ---------------------------------------------------------------
    // Regression C: ktlint must inspect *.gradle.kts files. Locks in the filter
    // broadening (`include("**/*.kt", "**/*.kts")`) and the removal of the
    // hardcoded ktlint script-task disable. Pre-fix, build scripts were silently
    // skipped — a violation in `build.gradle.kts` would never be reported.
    // ---------------------------------------------------------------
    @Test
    fun `ktlintCheck inspects build_gradle_kts violations - locks in filter broadening`() {
        settingsFile(kotlinSettings("test-ktlint-kts-coverage"))
        // Build script with a wildcard import (violates `no-wildcard-imports`).
        // Wildcard imports are flagged on .kts as on .kt; the settings file has none.
        buildFile(
            """
            import java.util.*

            plugins {
                kotlin("jvm") version "1.9.25"
                id("org.jlleitschuh.gradle.ktlint") version "14.0.1"
                id("org.octopusden.octopus-quality")
            }
            repositories { mavenCentral() }
            octopusQuality {
                kotlin { failOnViolation.set(true) }
                coverage { enabled.set(false) }
            }
            // Reference UUID so the Kotlin compiler doesn't strip the import.
            val unused: UUID? = null
            tasks.named("ktlintCheck") { mustRunAfter(tasks.named("clean")) }
            """.trimIndent(),
        )

        val result = runner("clean", "ktlintCheck").buildAndFail()
        assertTrue(
            result.output.contains("build.gradle.kts"),
            "Expected ktlintCheck failure to mention build.gradle.kts; got: ${result.output}",
        )
        // Rule-message assertion guards against false positives where "build.gradle.kts"
        // appears in unrelated error output (deprecation warnings, stack traces).
        // ktlint's PLAIN reporter prints the human message, not the rule id.
        assertTrue(
            result.output.contains("Wildcard import"),
            "Expected ktlintCheck failure to fire the wildcard-import rule; got: ${result.output}",
        )
    }
}
