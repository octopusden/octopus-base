package org.octopusden.octopus.quality

import org.gradle.api.Plugin
import org.gradle.api.Project
import org.octopusden.octopus.quality.internal.PublicationValidator
import org.octopusden.octopus.quality.internal.SubprojectConfigurer
import org.octopusden.octopus.quality.internal.TaskRegistrar

/**
 * Convention plugin providing shared quality configuration for octopusden JVM repositories.
 *
 * **Consumer contract:** The consumer repo declares and applies quality tool plugins
 * (detekt, ktlint, kover) with their own versions. This plugin configures them
 * (shared rules, baselines, reports, task wiring) but does NOT pin tool versions.
 *
 * ```kotlin
 * // settings.gradle.kts — ALL versions here:
 * pluginManagement {
 *     plugins {
 *         kotlin("jvm") version(extra["kotlin.version"] as String)
 *         id("io.gitlab.arturbosch.detekt") version(extra["detekt.version"] as String)
 *         id("org.jlleitschuh.gradle.ktlint") version(extra["ktlint-gradle.version"] as String)
 *         id("org.octopusden.octopus-quality") version "<version>"
 *     }
 * }
 *
 * // build.gradle.kts — apply at root:
 * plugins {
 *     kotlin("jvm") apply false
 *     id("io.gitlab.arturbosch.detekt") apply false
 *     id("org.jlleitschuh.gradle.ktlint") apply false
 *     id("org.octopusden.octopus-quality")
 * }
 *
 * subprojects {
 *     apply(plugin = "org.jetbrains.kotlin.jvm")
 *     apply(plugin = "io.gitlab.arturbosch.detekt")
 *     apply(plugin = "org.jlleitschuh.gradle.ktlint")
 * }
 * ```
 *
 * The plugin auto-detects languages per subproject and configures:
 * - **Kotlin** (when detekt/ktlint applied): shared detekt.yml, baseline support, report formats
 * - **Java/Groovy** (always): checkstyle, pmd, spotbugs, codenarc — bundled by plugin
 * - **Coverage**: JaCoCo (Java/mixed, applied by plugin) or Kover (Kotlin-only, applied by consumer)
 *
 * Aggregate tasks registered at root level:
 * - `qualityStatic` — static analysis + formatting checks
 * - `qualityCoverage` — tests + coverage verification
 * - `qualityCheck` — both of the above
 *
 * See `docs/Octopus JVM Style Guidelines.md` for full consumer wiring guide.
 */
class OctopusQualityPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val extension = project.extensions.create("octopusQuality", OctopusQualityExtension::class.java)

        val targets =
            if (project.subprojects.isEmpty()) {
                listOf(project)
            } else {
                project.allprojects.filter { it != project }
            }

        // Phase 1 — synchronous, BEFORE subproject scripts evaluate. Registers
        // `plugins.withId(...)` callbacks for ktlint/detekt so that settings whose
        // upstream tools read them during their own configuration (notably ktlint's
        // baseline) actually land before task wiring. Lazy `Provider` mapping is used
        // for any consumer-driven property — never `.get()` here.
        targets.forEach { sub -> SubprojectConfigurer.registerEarly(sub, project, extension) }

        // Phase 2 — afterEvaluate for source-set-dependent wiring (LanguageDetector,
        // checkstyle/pmd/spotbugs/codenarc/jacoco/kover, and detekt's eager-Boolean
        // `ignoreFailures` which has no lazy hook in detekt-gradle 1.23.x).
        targets.forEach { sub ->
            sub.afterEvaluate {
                SubprojectConfigurer.configure(sub, project, extension)
            }
        }

        // Register aggregate quality tasks. Uses gradle.projectsEvaluated to ensure
        // all subproject afterEvaluate blocks have completed before wiring task dependencies.
        project.gradle.projectsEvaluated {
            TaskRegistrar.register(project, extension)
        }

        // Validate Maven Central publication readiness (sources, javadoc, POM fields)
        // for every project that applies maven-publish. Wired into `check`.
        project.allprojects.forEach { PublicationValidator.register(it) }
    }
}
