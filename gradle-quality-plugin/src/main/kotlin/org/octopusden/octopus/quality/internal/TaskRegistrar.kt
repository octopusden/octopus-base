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

    fun register(rootProject: Project, extension: OctopusQualityExtension) {
        val targetProjects = targetProjects(rootProject, extension)
        val excludedTasks = extension.excludedTasks.get()

        registerQualityStatic(rootProject, targetProjects, excludedTasks)
        registerQualityCoverage(rootProject, targetProjects, extension, excludedTasks)
        registerQualityCheck(rootProject)
    }

    private fun registerQualityStatic(rootProject: Project, targets: List<Project>, excludedTasks: Set<String>) {
        rootProject.tasks.register("qualityStatic") { task ->
            task.group = "verification"
            task.description = "Runs static analysis checks for all modules"

            for (project in targets) {
                val languages = LanguageDetector.detect(project)

                // Java tools: checkstyle, pmd
                if (languages.hasJava || languages.hasKotlin || languages.hasGroovy) {
                    dependOnIfExists(task, project, "checkstyleMain", excludedTasks)
                    dependOnIfExists(task, project, "checkstyleTest", excludedTasks)
                    dependOnIfExists(task, project, "checkstyleIntegrationTest", excludedTasks)
                    dependOnIfExists(task, project, "pmdMain", excludedTasks)
                    dependOnIfExists(task, project, "pmdTest", excludedTasks)
                    dependOnIfExists(task, project, "pmdIntegrationTest", excludedTasks)
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
            task.description = if (coverageEnabled) {
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
                        dependOnIfExists(task, project, "koverXmlReport", excludedTasks)
                        dependOnIfExists(task, project, "koverVerify", excludedTasks)
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
                dependOnRootIfExists(task, rootProject, "koverMergedXmlReport")
                dependOnRootIfExists(task, rootProject, "koverXmlReport")
                dependOnRootIfExists(task, rootProject, "koverMergedVerify")
                dependOnRootIfExists(task, rootProject, "koverVerify")
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

        rootProject.tasks.register("jacocoOverallCoverageReport", org.gradle.testing.jacoco.tasks.JacocoReport::class.java) { task ->
            task.group = "verification"
            task.description = "Generates an aggregated JaCoCo report across all coverage modules"

            task.dependsOn(targets.map { "${it.path}:test" })

            task.executionData.from(rootProject.files(targets.map { project ->
                project.fileTree(project.layout.buildDirectory) { tree ->
                    tree.include("jacoco/test.exec")
                }
            }))
            task.sourceDirectories.from(rootProject.files(targets.mapNotNull { project ->
                project.extensions.findByType(org.gradle.api.plugins.JavaPluginExtension::class.java)
                    ?.sourceSets?.findByName("main")?.allSource?.srcDirs
            }))
            task.classDirectories.from(rootProject.files(targets.mapNotNull { project ->
                project.extensions.findByType(org.gradle.api.plugins.JavaPluginExtension::class.java)
                    ?.sourceSets?.findByName("main")?.output
            }))

            task.reports.xml.required.set(true)
            task.reports.html.required.set(true)
            task.reports.xml.outputLocation.set(
                rootProject.layout.buildDirectory.file("reports/jacoco/overallCoverage/jacocoOverallCoverageReport.xml")
            )
            task.reports.html.outputLocation.set(
                rootProject.layout.buildDirectory.dir("reports/jacoco/overallCoverage/html")
            )
        }

        rootProject.tasks.register("jacocoOverallCoverageVerification", org.gradle.testing.jacoco.tasks.JacocoCoverageVerification::class.java) { task ->
            task.group = "verification"
            task.description = "Verifies aggregated JaCoCo coverage across all coverage modules"

            task.dependsOn(targets.map { "${it.path}:test" })

            task.executionData.from(rootProject.files(targets.map { project ->
                project.fileTree(project.layout.buildDirectory) { tree ->
                    tree.include("jacoco/test.exec")
                }
            }))
            task.sourceDirectories.from(rootProject.files(targets.mapNotNull { project ->
                project.extensions.findByType(org.gradle.api.plugins.JavaPluginExtension::class.java)
                    ?.sourceSets?.findByName("main")?.allSource?.srcDirs
            }))
            task.classDirectories.from(rootProject.files(targets.mapNotNull { project ->
                project.extensions.findByType(org.gradle.api.plugins.JavaPluginExtension::class.java)
                    ?.sourceSets?.findByName("main")?.output
            }))

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

    private fun resolveCoverageTool(
        requested: CoverageExtension.Tool,
        languages: DetectedLanguages,
    ): CoverageExtension.Tool {
        if (requested != CoverageExtension.Tool.AUTO) return requested
        return if (languages.isKotlinOnly) CoverageExtension.Tool.KOVER else CoverageExtension.Tool.JACOCO
    }

    private fun targetProjects(rootProject: Project, extension: OctopusQualityExtension): List<Project> {
        val excluded = extension.coverageExcludedProjects.get()
        return if (rootProject.subprojects.isEmpty()) {
            listOf(rootProject)
        } else {
            rootProject.subprojects.filter { it.name !in excluded }
        }
    }

    private fun dependOnIfExists(task: Task, project: Project, taskName: String, excludedTasks: Set<String>) {
        val fullPath = "${project.path}:$taskName"
        if (taskName in excludedTasks || fullPath in excludedTasks) return
        if (taskName in project.tasks.names) {
            task.dependsOn(fullPath)
        }
    }

    private fun dependOnRootIfExists(task: Task, rootProject: Project, taskName: String) {
        if (taskName in rootProject.tasks.names) {
            task.dependsOn(taskName)
        }
    }
}
