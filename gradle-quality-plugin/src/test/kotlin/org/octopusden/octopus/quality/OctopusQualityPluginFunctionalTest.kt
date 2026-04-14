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
}
