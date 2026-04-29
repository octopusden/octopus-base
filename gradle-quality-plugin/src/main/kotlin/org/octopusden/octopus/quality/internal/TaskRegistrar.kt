package org.octopusden.octopus.quality.internal

import org.gradle.api.Project
import org.gradle.api.Task
import org.octopusden.octopus.quality.CoverageExtension
import org.octopusden.octopus.quality.OctopusQualityExtension

/**
 * Registers root-level aggregate quality tasks: qualityStatic, qualityCoverage, qualityCheck.
 *
 * Called from `gradle.projectsEvaluated` so all subproject plugins and tasks are already resolved.
 */
internal object TaskRegistrar {
    // Kover does not expose stable public types for these report tasks, so type-based
    // matching is not viable. Names are extracted to constants so a Kover rename
    // surfaces in one place; `dependOnExpectedTask` logs a warning when the named
    // task is absent so silent breakage doesn't happen on a tool upgrade.
    private const val KOVER_XML_REPORT = "koverXmlReport"
    private const val KOVER_VERIFY = "koverVerify"
    private const val KOVER_MERGED_XML_REPORT = "koverMergedXmlReport"
    private const val KOVER_MERGED_VERIFY = "koverMergedVerify"

    fun register(
        rootProject: Project,
        extension: OctopusQualityExtension,
    ) {
        val allProjects = allTargetProjects(rootProject)
        val coverageProjects = coverageTargetProjects(rootProject, extension)
        val excludedTasks = extension.excludedTasks.get()

        registerQualityStatic(rootProject, allProjects, excludedTasks)
        registerQualityCoverage(rootProject, coverageProjects, extension, excludedTasks)
        registerQualityCheck(rootProject)
    }

    private fun registerQualityStatic(
        rootProject: Project,
        targets: List<Project>,
        excludedTasks: Set<String>,
    ) {
        rootProject.tasks.register("qualityStatic") { task ->
            task.group = "verification"
            task.description = "Runs static analysis checks for all modules"

            for (project in targets) {
                val languages = LanguageDetector.detect(project)

                // Java tools: checkstyle, pmd, spotbugs
                if (languages.hasJava || languages.hasKotlin || languages.hasGroovy) {
                    dependOnIfExists(task, project, "checkstyleMain", excludedTasks)
                    dependOnIfExists(task, project, "checkstyleTest", excludedTasks)
                    dependOnIfExists(task, project, "checkstyleIntegrationTest", excludedTasks)
                    dependOnIfExists(task, project, "pmdMain", excludedTasks)
                    dependOnIfExists(task, project, "pmdTest", excludedTasks)
                    dependOnIfExists(task, project, "pmdIntegrationTest", excludedTasks)
                    dependOnIfExists(task, project, "spotbugsMain", excludedTasks)
                    dependOnIfExists(task, project, "spotbugsTest", excludedTasks)
                    dependOnIfExists(task, project, "classes", excludedTasks)
                    dependOnIfExists(task, project, "testClasses", excludedTasks)
                }

                // Kotlin tools: detekt, ktlint
                if (languages.hasKotlin) {
                    dependOnIfExists(task, project, "detekt", excludedTasks)
                    dependOnIfExists(task, project, "ktlintCheck", excludedTasks)
                }

                // Groovy tools: codenarc
                if (languages.hasGroovy) {
                    dependOnIfExists(task, project, "codenarcMain", excludedTasks)
                    dependOnIfExists(task, project, "codenarcTest", excludedTasks)
                }
            }
        }
    }

    private fun registerQualityCoverage(
        rootProject: Project,
        targets: List<Project>,
        extension: OctopusQualityExtension,
        excludedTasks: Set<String>,
    ) {
        val coverageEnabled = extension.coverage.enabled.get()

        rootProject.tasks.register("qualityCoverage") { task ->
            task.group = "verification"
            task.description =
                if (coverageEnabled) {
                    "Runs tests and coverage verification for all modules"
                } else {
                    "Runs tests for all modules (coverage verification disabled)"
                }

            for (project in targets) {
                dependOnIfExists(task, project, "test", excludedTasks)
            }

            if (!coverageEnabled) return@register

            val overallLanguages = LanguageDetector.detectAll(rootProject, extension.coverageExcludedProjects.get())
            val coverageTool = resolveCoverageTool(extension.coverage.tool.get(), overallLanguages)

            for (project in targets) {
                when (coverageTool) {
                    CoverageExtension.Tool.JACOCO -> {
                        dependOnIfExists(task, project, "jacocoTestReport", excludedTasks)
                        dependOnIfExists(task, project, "jacocoTestCoverageVerification", excludedTasks)
                    }
                    CoverageExtension.Tool.KOVER -> {
                        dependOnExpectedTask(task, project, KOVER_XML_REPORT, excludedTasks)
                        dependOnExpectedTask(task, project, KOVER_VERIFY, excludedTasks)
                    }
                    else -> {}
                }
            }

            // Overall aggregation
            if (coverageTool == CoverageExtension.Tool.JACOCO && targets.size > 1) {
                registerJacocoOverallTasks(rootProject, targets, extension)
                task.dependsOn("jacocoOverallCoverageReport")
                task.dependsOn("jacocoOverallCoverageVerification")
            }
            if (coverageTool == CoverageExtension.Tool.KOVER) {
                // Either merged-* (multi-module) or single-module — exactly one set is
                // expected to exist. Use the silent helper here so the absent half
                // doesn't fire a spurious warning. If BOTH are missing, the per-project
                // `dependOnExpectedTask` calls above will already have warned.
                dependOnRootIfExists(task, rootProject, KOVER_MERGED_XML_REPORT)
                dependOnRootIfExists(task, rootProject, KOVER_XML_REPORT)
                dependOnRootIfExists(task, rootProject, KOVER_MERGED_VERIFY)
                dependOnRootIfExists(task, rootProject, KOVER_VERIFY)
            }
        }
    }

    private fun registerQualityCheck(rootProject: Project) {
        rootProject.tasks.register("qualityCheck") { task ->
            task.group = "verification"
            task.description = "Runs all quality gates (static + coverage)"
            task.dependsOn("qualityStatic", "qualityCoverage")
        }
    }

    private fun registerJacocoOverallTasks(
        rootProject: Project,
        targets: List<Project>,
        extension: OctopusQualityExtension,
    ) {
        rootProject.pluginManager.apply("jacoco")
        val excludedTasks = extension.excludedTasks.get()
        val filteredTargets =
            targets.filter { project ->
                val testPath = "${project.path}:test"
                // Skip projects without a test task (non-Java modules) or where test is excluded
                "test" in project.tasks.names &&
                    "test" !in excludedTasks &&
                    testPath !in excludedTasks
            }

        rootProject.tasks.register("jacocoOverallCoverageReport", org.gradle.testing.jacoco.tasks.JacocoReport::class.java) { task ->
            task.group = "verification"
            task.description = "Generates an aggregated JaCoCo report across all coverage modules"

            task.dependsOn(filteredTargets.map { "${it.path}:test" })

            task.executionData.from(
                rootProject.files(
                    filteredTargets.map { project ->
                        project.fileTree(project.layout.buildDirectory) { tree ->
                            tree.include("jacoco/test.exec")
                        }
                    },
                ),
            )
            task.sourceDirectories.from(
                rootProject.files(
                    filteredTargets.mapNotNull { project ->
                        project.extensions
                            .findByType(org.gradle.api.plugins.JavaPluginExtension::class.java)
                            ?.sourceSets
                            ?.findByName("main")
                            ?.allSource
                            ?.srcDirs
                    },
                ),
            )
            task.classDirectories.from(
                rootProject.files(
                    filteredTargets.mapNotNull { project ->
                        project.extensions
                            .findByType(org.gradle.api.plugins.JavaPluginExtension::class.java)
                            ?.sourceSets
                            ?.findByName("main")
                            ?.output
                    },
                ),
            )

            task.reports.xml.required
                .set(true)
            task.reports.html.required
                .set(true)
            task.reports.xml.outputLocation.set(
                rootProject.layout.buildDirectory.file("reports/jacoco/overallCoverage/jacocoOverallCoverageReport.xml"),
            )
            task.reports.html.outputLocation.set(
                rootProject.layout.buildDirectory.dir("reports/jacoco/overallCoverage/html"),
            )
        }

        val verificationType = org.gradle.testing.jacoco.tasks.JacocoCoverageVerification::class.java
        rootProject.tasks.register("jacocoOverallCoverageVerification", verificationType) { task ->
            task.group = "verification"
            task.description = "Verifies aggregated JaCoCo coverage across all coverage modules"

            task.dependsOn(filteredTargets.map { "${it.path}:test" })

            task.executionData.from(
                rootProject.files(
                    filteredTargets.map { project ->
                        project.fileTree(project.layout.buildDirectory) { tree ->
                            tree.include("jacoco/test.exec")
                        }
                    },
                ),
            )
            task.sourceDirectories.from(
                rootProject.files(
                    filteredTargets.mapNotNull { project ->
                        project.extensions
                            .findByType(org.gradle.api.plugins.JavaPluginExtension::class.java)
                            ?.sourceSets
                            ?.findByName("main")
                            ?.allSource
                            ?.srcDirs
                    },
                ),
            )
            task.classDirectories.from(
                rootProject.files(
                    filteredTargets.mapNotNull { project ->
                        project.extensions
                            .findByType(org.gradle.api.plugins.JavaPluginExtension::class.java)
                            ?.sourceSets
                            ?.findByName("main")
                            ?.output
                    },
                ),
            )

            task.violationRules.rule { rule ->
                rule.element = "BUNDLE"
                rule.limit { limit ->
                    limit.counter = "LINE"
                    limit.value = "COVEREDRATIO"
                    limit.minimum = extension.coverage.overallMinimum.get()
                }
            }
        }
    }

    private fun allTargetProjects(rootProject: Project): List<Project> {
        val allSubs = rootProject.allprojects.filter { it != rootProject }
        return if (allSubs.isEmpty()) {
            listOf(rootProject)
        } else {
            allSubs
        }
    }

    private fun coverageTargetProjects(
        rootProject: Project,
        extension: OctopusQualityExtension,
    ): List<Project> {
        val excluded = extension.coverageExcludedProjects.get()
        val allSubs = rootProject.allprojects.filter { it != rootProject }
        return if (allSubs.isEmpty()) {
            listOf(rootProject)
        } else {
            allSubs.filter { it.name !in excluded }
        }
    }

    private fun dependOnIfExists(
        task: Task,
        project: Project,
        taskName: String,
        excludedTasks: Set<String>,
    ) {
        val fullPath = if (project.path == ":") ":$taskName" else "${project.path}:$taskName"
        if (taskName in excludedTasks || fullPath in excludedTasks) return
        if (taskName in project.tasks.names) {
            task.dependsOn(fullPath)
        }
    }

    /**
     * Like `dependOnIfExists` but logs a warning when the named task is absent and
     * was not explicitly excluded. Use for tasks that the convention plugin requires
     * by name (e.g. Kover's report tasks) so that an upstream rename surfaces loudly
     * instead of becoming a silent no-op.
     */
    private fun dependOnExpectedTask(
        task: Task,
        project: Project,
        taskName: String,
        excludedTasks: Set<String>,
    ) {
        val fullPath = if (project.path == ":") ":$taskName" else "${project.path}:$taskName"
        if (taskName in excludedTasks || fullPath in excludedTasks) return
        if (taskName in project.tasks.names) {
            task.dependsOn(fullPath)
        } else {
            project.logger.warn(
                "octopusQuality: expected task '$taskName' not found on project '${project.path}'. " +
                    "If the upstream tool renamed it, update the convention plugin.",
            )
        }
    }

    private fun dependOnRootIfExists(
        task: Task,
        rootProject: Project,
        taskName: String,
    ) {
        if (taskName in rootProject.tasks.names) {
            task.dependsOn(":$taskName")
        }
    }
}
