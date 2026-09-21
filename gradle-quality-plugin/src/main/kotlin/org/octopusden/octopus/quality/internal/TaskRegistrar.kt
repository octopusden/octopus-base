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
        HollowGateGuard.register(rootProject, allProjects)
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

                // checkstyle/pmd are Java-only source analysers — gated (plugin-apply and here) to
                // modules with Java source; see SubprojectConfigurer.configure.
                if (languages.hasJava) {
                    dependOnIfExists(task, project, "checkstyleMain", excludedTasks)
                    dependOnIfExists(task, project, "checkstyleTest", excludedTasks)
                    dependOnIfExists(task, project, "checkstyleIntegrationTest", excludedTasks)
                    dependOnIfExists(task, project, "pmdMain", excludedTasks)
                    dependOnIfExists(task, project, "pmdTest", excludedTasks)
                    dependOnIfExists(task, project, "pmdIntegrationTest", excludedTasks)
                }

                // Compilation is needed by every JVM module's analysis (detekt/codenarc modules
                // included), so `classes`/`testClasses` stay under the broad language condition —
                // NOT gated to hasJava, which would silently drop compilation for Kotlin/Groovy.
                if (languages.hasJava || languages.hasKotlin || languages.hasGroovy) {
                    dependOnIfExists(task, project, "classes", excludedTasks)
                    dependOnIfExists(task, project, "testClasses", excludedTasks)
                }

                // spotbugs is bytecode-based and gated to Java-without-Kotlin modules (it would
                // false-positive on co-located Kotlin classes) — see SubprojectConfigurer.configure.
                if (languages.hasJava && !languages.hasKotlin) {
                    dependOnIfExists(task, project, "spotbugsMain", excludedTasks)
                    dependOnIfExists(task, project, "spotbugsTest", excludedTasks)
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
        // Resolved eagerly: this runs from `gradle.projectsEvaluated`, and Gradle forbids mutating
        // the task container from inside another task's configuration action — registering the
        // aggregate tasks there made `qualityCoverage` unrealizable in multi-module builds (#231).
        val coverageEnabled = extension.coverage.enabled.get()
        val coverageTool =
            if (coverageEnabled) {
                val overallLanguages = LanguageDetector.detectAll(rootProject, extension.coverageExcludedProjects.get())
                resolveCoverageTool(extension.coverage.tool.get(), overallLanguages)
            } else {
                null
            }
        val aggregateJacoco = coverageTool == CoverageExtension.Tool.JACOCO && targets.size > 1

        if (aggregateJacoco) {
            registerJacocoOverallTasks(rootProject, targets, extension)
        }

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
            if (aggregateJacoco) {
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
        // Which SUITES run: a project without a `test` task (non-Java module) or whose `test` is
        // excluded contributes no execution data and must not be depended on.
        val executionTargets =
            targets.filter { project ->
                val testPath = "${project.path}:test"
                "test" in project.tasks.names &&
                    "test" !in excludedTasks &&
                    testPath !in excludedTasks
            }

        // Which CLASSES count: every coverage target, including those whose `test` is excluded.
        // Filtering the denominator too would let a repo raise its reported coverage merely by
        // excluding a suite its CI cannot run (#231). Opting a project out of coverage entirely is
        // `coverageExcludedProjects`, which `targets` already honours.
        val sourceDirs =
            rootProject.files(
                targets.mapNotNull { project -> project.mainSourceSet()?.allSource?.srcDirs },
            )
        val classDirs =
            rootProject.files(
                targets.mapNotNull { project -> project.mainSourceSet()?.output },
            )
        // Glob rather than `jacoco/test.exec`: a module whose coverage-bearing suite is any other
        // Test task (e.g. `unitTest`) writes `jacoco/<taskName>.exec`. JaCoCo merges execution data
        // per class id, OR-ing the probe arrays, so overlapping suites do not double-count.
        val executionData =
            rootProject.files(
                executionTargets.map { project ->
                    project.fileTree(project.layout.buildDirectory) { tree ->
                        tree.include("jacoco/*.exec")
                    }
                },
            )
        val testDependencies = executionTargets.map { "${it.path}:test" }

        rootProject.tasks.register("jacocoOverallCoverageReport", org.gradle.testing.jacoco.tasks.JacocoReport::class.java) { task ->
            task.group = "verification"
            task.description = "Generates an aggregated JaCoCo report across all coverage modules"

            task.dependsOn(testDependencies)
            task.executionData.from(executionData)
            task.sourceDirectories.from(sourceDirs)
            task.classDirectories.from(classDirs)

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

            task.dependsOn(testDependencies)
            task.executionData.from(executionData)
            task.sourceDirectories.from(sourceDirs)
            task.classDirectories.from(classDirs)

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
        return when {
            allSubs.isEmpty() -> listOf(rootProject)
            // Include the root when it carries its own sources, so root-module code is wired into
            // qualityStatic (otherwise it escapes the gate in multi-module repos with a source root).
            LanguageDetector.hasAnySource(rootProject) -> allSubs + rootProject
            else -> allSubs
        }
    }

    private fun coverageTargetProjects(
        rootProject: Project,
        extension: OctopusQualityExtension,
    ): List<Project> {
        val excluded = extension.coverageExcludedProjects.get()
        val allSubs = rootProject.allprojects.filter { it != rootProject }
        return when {
            allSubs.isEmpty() -> listOf(rootProject)
            else -> {
                val withRoot =
                    if (LanguageDetector.hasAnySource(rootProject)) allSubs + rootProject else allSubs
                withRoot.filter { it.name !in excluded }
            }
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

/**
 * The `main` source set of a JVM project, or null for a project that applies no Java-based plugin.
 * Top-level rather than a member of [TaskRegistrar] so it does not count against detekt's
 * `TooManyFunctions` ceiling for that object, mirroring `resolveCoverageTool`.
 */
private fun Project.mainSourceSet() =
    extensions
        .findByType(org.gradle.api.plugins.JavaPluginExtension::class.java)
        ?.sourceSets
        ?.findByName("main")
