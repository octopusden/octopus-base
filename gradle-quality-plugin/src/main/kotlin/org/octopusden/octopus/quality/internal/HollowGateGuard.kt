package org.octopusden.octopus.quality.internal

import org.gradle.api.GradleException
import org.gradle.api.Project

/**
 * Guards against a "hollow" static-analysis gate.
 *
 * The convention plugin *self-applies* the Java/Groovy analysers (checkstyle/pmd/spotbugs/codenarc)
 * but only *reactively configures* detekt/ktlint via `plugins.withId(...)` — the consumer must apply
 * those plugins per Kotlin subproject (see `OctopusQualityPlugin` KDoc). If a module has Kotlin
 * sources but never applied them, no `detekt`/`ktlintCheck` tasks are created, `qualityStatic`'s
 * `dependOnIfExists` finds nothing, and the gate passes green while analysing zero Kotlin — a false
 * assurance (observed in octopus-components-registry-service).
 *
 * This registers `verifyStaticAnalysisApplied`, wired as a dependency of `qualityStatic`, which fails
 * the build with a per-module message when a Kotlin module is missing its analysis tasks.
 *
 * Self-apply of detekt/ktlint is deliberately NOT done: they are declared `compileOnly` (consumer
 * provides the version via `pluginManagement`) because both are Kotlin-version-coupled — bundling
 * them would force a Kotlin version onto every consumer. The assertion works over the
 * consumer-provided plugins instead.
 */
internal object HollowGateGuard {
    private val REQUIRED_KOTLIN_TASKS = listOf("detekt", "ktlintCheck")

    fun register(
        rootProject: Project,
        targets: List<Project>,
    ) {
        // Computed here (from `gradle.projectsEvaluated`, so tasks are resolved) and captured into the
        // task action as plain strings — no Project/task references leak into execution, keeping the
        // guard configuration-cache friendly.
        val problems =
            targets.mapNotNull { project ->
                if (!LanguageDetector.detect(project).hasKotlin) return@mapNotNull null
                val missing = REQUIRED_KOTLIN_TASKS.filter { project.tasks.findByName(it) == null }
                if (missing.isEmpty()) {
                    null
                } else {
                    "${project.path}: Kotlin sources present but ${missing.joinToString(", ")} " +
                        "task(s) missing — apply the plugin(s) in this module's build script."
                }
            }

        val guard =
            rootProject.tasks.register("verifyStaticAnalysisApplied") { task ->
                task.group = "verification"
                task.description =
                    "Fails if a module has Kotlin sources but its static-analysis tasks were never " +
                    "created (a hollow quality gate)."
                task.doLast {
                    if (problems.isNotEmpty()) {
                        throw GradleException(
                            "Hollow quality gate — static analysis would pass without scanning Kotlin:\n" +
                                problems.joinToString("\n") { "  - $it" } +
                                "\nSee OctopusQualityPlugin KDoc: consumers must apply detekt & ktlint " +
                                "per Kotlin subproject.",
                        )
                    }
                }
            }

        rootProject.tasks.named("qualityStatic").configure { it.dependsOn(guard) }
    }
}
