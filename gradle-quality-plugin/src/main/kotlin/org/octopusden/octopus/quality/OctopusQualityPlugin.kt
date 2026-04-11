package org.octopusden.octopus.quality

import org.gradle.api.Plugin
import org.gradle.api.Project
import org.octopusden.octopus.quality.internal.SubprojectConfigurer
import org.octopusden.octopus.quality.internal.TaskRegistrar

/**
 * Convention plugin providing unified quality gates for octopusden JVM repositories.
 *
 * Apply to the **root project**:
 * ```kotlin
 * plugins {
 *     id("org.octopusden.octopus-quality") version "<version>"
 * }
 * ```
 *
 * The plugin auto-detects languages (Java, Kotlin, Groovy) in each subproject and
 * configures the appropriate static analysis, formatting, and coverage tools.
 *
 * Aggregate tasks registered at root level:
 * - `qualityStatic` — static analysis + formatting checks
 * - `qualityCoverage` — tests + coverage verification
 * - `qualityCheck` — both of the above
 */
class OctopusQualityPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val extension = project.extensions.create("octopusQuality", OctopusQualityExtension::class.java)

        // Configure subprojects after they are evaluated (plugins and source sets resolved).
        // Use subproject.afterEvaluate so that the consumer's build.gradle.kts has been processed.
        if (project.subprojects.isEmpty()) {
            project.afterEvaluate {
                SubprojectConfigurer.configure(project, project, extension)
            }
        } else {
            project.allprojects.filter { it != project }.forEach { sub ->
                sub.afterEvaluate {
                    SubprojectConfigurer.configure(sub, project, extension)
                }
            }
        }

        // Register aggregate quality tasks. Uses gradle.projectsEvaluated to ensure
        // all subproject afterEvaluate blocks have completed before wiring task dependencies.
        project.gradle.projectsEvaluated {
            TaskRegistrar.register(project, extension)
        }
    }
}
