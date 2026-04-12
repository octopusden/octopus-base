package org.octopusden.octopus.quality.internal

import org.gradle.api.Project
import org.octopusden.octopus.quality.CoverageExtension
import org.octopusden.octopus.quality.OctopusQualityExtension
import java.io.File

/**
 * Configures quality tool plugins on individual subprojects (or root if single-module)
 * based on detected languages.
 */
internal object SubprojectConfigurer {
    private const val CHECKSTYLE_VERSION = "10.17.0"
    private const val PMD_VERSION = "6.55.0"

    fun configure(
        project: Project,
        rootProject: Project,
        extension: OctopusQualityExtension,
    ) {
        val configDir =
            rootProject.extensions.extraProperties.let { extra ->
                val key = "octopusQuality.configDir"
                if (extra.has(key)) {
                    extra.get(key) as File
                } else {
                    ConfigExtractor.extractTo(rootProject).also { extra.set(key, it) }
                }
            }
        val languages = LanguageDetector.detect(project)

        // Java/Groovy built-in tools: always safe to apply (Gradle core, no external classloader)
        if (languages.hasJava || languages.hasKotlin || languages.hasGroovy) {
            configureCheckstyle(project, configDir, extension)
            configurePmd(project, configDir, extension)
            configureSpotBugs(project, extension)
        }

        if (languages.hasGroovy) {
            configureCodeNarc(project, configDir, extension)
        }

        // Kotlin tools (detekt, ktlint): compileOnly deps — consumer provides versions
        // via pluginManagement. We only configure when the consumer has applied them.
        if (languages.hasKotlin) {
            project.plugins.withId("io.gitlab.arturbosch.detekt") {
                configureDetekt(project, configDir, extension)
            }
            project.plugins.withId("org.jlleitschuh.gradle.ktlint") {
                configureKtlint(project, extension)
            }
        }

        // Coverage: skip for excluded projects
        val excludedFromCoverage = extension.coverageExcludedProjects.get()
        if (project.name !in excludedFromCoverage) {
            val overallLanguages = LanguageDetector.detectAll(rootProject, excludedFromCoverage)
            val coverageTool = resolveCoverageTool(extension.coverage.tool.get(), overallLanguages)
            when (coverageTool) {
                CoverageExtension.Tool.JACOCO -> configureJaCoCo(project, extension)
                CoverageExtension.Tool.KOVER -> configureKover(project, rootProject, extension)
                else -> {}
            }
        }
    }

    private fun configureCheckstyle(
        project: Project,
        configDir: File,
        extension: OctopusQualityExtension,
    ) {
        project.pluginManager.apply("checkstyle")
        project.extensions.configure(org.gradle.api.plugins.quality.CheckstyleExtension::class.java) { ext ->
            ext.toolVersion = CHECKSTYLE_VERSION
            ext.configFile = File(configDir, "checkstyle.xml")
            ext.isShowViolations = true
            ext.isIgnoreFailures = !extension.java.failOnViolation.get()
        }
        project.tasks.withType(org.gradle.api.plugins.quality.Checkstyle::class.java).configureEach { task ->
            task.reports.xml.required
                .set(true)
            task.reports.html.required
                .set(true)
        }
    }

    private fun configurePmd(
        project: Project,
        configDir: File,
        extension: OctopusQualityExtension,
    ) {
        project.pluginManager.apply("pmd")
        project.extensions.configure(org.gradle.api.plugins.quality.PmdExtension::class.java) { ext ->
            ext.toolVersion = PMD_VERSION
            ext.isConsoleOutput = true
            ext.incrementalAnalysis.set(true)
            ext.isIgnoreFailures = !extension.java.failOnViolation.get()
            ext.ruleSets = emptyList()
            ext.ruleSetFiles = project.files(File(configDir, "pmd-ruleset.xml"))
        }
        project.tasks.withType(org.gradle.api.plugins.quality.Pmd::class.java).configureEach { task ->
            task.reports.xml.required
                .set(true)
            task.reports.html.required
                .set(true)
        }
    }

    private fun configureSpotBugs(
        project: Project,
        extension: OctopusQualityExtension,
    ) {
        project.pluginManager.apply("com.github.spotbugs")
        project.extensions.configure(com.github.spotbugs.snom.SpotBugsExtension::class.java) { ext ->
            ext.ignoreFailures.set(!extension.java.failOnViolation.get())
            ext.showProgress.set(false)
        }
        project.tasks.withType(com.github.spotbugs.snom.SpotBugsTask::class.java).configureEach { task ->
            task.reports.register("xml") { it.required.set(true) }
            task.reports.register("html") { it.required.set(true) }
        }
    }

    private fun configureDetekt(
        project: Project,
        configDir: File,
        extension: OctopusQualityExtension,
    ) {
        // Plugin already applied by consumer — we only configure it
        project.extensions.configure(io.gitlab.arturbosch.detekt.extensions.DetektExtension::class.java) { ext ->
            ext.buildUponDefaultConfig = true
            ext.allRules = false
            ext.config.setFrom(File(configDir, "detekt.yml"))
            val baselineFile = File(project.projectDir, "detekt-baseline.xml")
            if (baselineFile.exists()) {
                ext.baseline = baselineFile
            }
            ext.ignoreFailures = !extension.kotlin.failOnViolation.get()
        }
        project.tasks.withType(io.gitlab.arturbosch.detekt.Detekt::class.java).configureEach { task ->
            task.reports {
                it.xml.required.set(true)
                it.html.required.set(true)
                it.sarif.required.set(true)
                it.txt.required.set(false)
            }
        }
    }

    private fun configureKtlint(
        project: Project,
        extension: OctopusQualityExtension,
    ) {
        // Plugin already applied by consumer — we only configure it
        project.extensions.configure(org.jlleitschuh.gradle.ktlint.KtlintExtension::class.java) { ext ->
            ext.ignoreFailures.set(!extension.kotlin.failOnViolation.get())
            ext.outputToConsole.set(true)
            ext.reporters {
                it.reporter(org.jlleitschuh.gradle.ktlint.reporter.ReporterType.PLAIN)
                it.reporter(org.jlleitschuh.gradle.ktlint.reporter.ReporterType.CHECKSTYLE)
            }
            val baselineFile = File(project.projectDir, "ktlint-baseline.xml")
            if (baselineFile.exists()) {
                ext.baseline.set(baselineFile)
            }
            ext.filter {
                it.exclude("**/generated/**")
                it.exclude("**/build/**")
                it.include("**/src/**/*.kt")
            }
        }
        // Disable Kotlin script checks
        project.tasks
            .matching { task ->
                task.name == "runKtlintCheckOverKotlinScripts" ||
                    task.name == "ktlintKotlinScriptCheck" ||
                    task.name == "runKtlintFormatOverKotlinScripts" ||
                    task.name == "ktlintKotlinScriptFormat"
            }.configureEach { it.enabled = false }
    }

    private fun configureCodeNarc(
        project: Project,
        configDir: File,
        extension: OctopusQualityExtension,
    ) {
        project.pluginManager.apply("codenarc")
        project.extensions.configure(org.gradle.api.plugins.quality.CodeNarcExtension::class.java) { ext ->
            ext.configFile = File(configDir, "codenarc.groovy")
            ext.isIgnoreFailures = !extension.groovy.failOnViolation.get()
        }
        project.tasks.withType(org.gradle.api.plugins.quality.CodeNarc::class.java).configureEach { task ->
            task.reports.xml.required
                .set(true)
            task.reports.html.required
                .set(true)
        }
    }

    private fun configureJaCoCo(
        project: Project,
        extension: OctopusQualityExtension,
    ) {
        project.pluginManager.apply("jacoco")
        project.tasks.matching { it.name == "test" }.configureEach { testTask ->
            testTask.finalizedBy(project.tasks.matching { it.name == "jacocoTestReport" })
        }
        project.tasks
            .withType(org.gradle.testing.jacoco.tasks.JacocoReport::class.java)
            .matching { it.name == "jacocoTestReport" }
            .configureEach { task ->
                task.dependsOn(project.tasks.matching { it.name == "test" })
                task.reports.xml.required
                    .set(true)
                task.reports.html.required
                    .set(true)
            }
        project.tasks
            .withType(org.gradle.testing.jacoco.tasks.JacocoCoverageVerification::class.java)
            .matching { it.name == "jacocoTestCoverageVerification" }
            .configureEach { task ->
                task.dependsOn(project.tasks.matching { it.name == "test" })
                task.violationRules.rule { rule ->
                    rule.element = "BUNDLE"
                    rule.limit { limit ->
                        limit.counter = "LINE"
                        limit.value = "COVEREDRATIO"
                        limit.minimum = extension.coverage.minimumLineCoverage.get()
                    }
                }
            }
    }

    @Suppress("UnusedParameter")
    private fun configureKover(
        project: Project,
        rootProject: Project,
        extension: OctopusQualityExtension,
    ) {
        // Kover is applied by consumer (with their version via pluginManagement).
        // Convention plugin only wires qualityCoverage tasks to kover tasks if they exist.
    }
}
