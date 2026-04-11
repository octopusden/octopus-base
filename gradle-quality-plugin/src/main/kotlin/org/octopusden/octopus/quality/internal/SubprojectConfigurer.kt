package org.octopusden.octopus.quality.internal

import org.gradle.api.Project
import org.octopusden.octopus.quality.OctopusQualityExtension
import java.io.File

/**
 * Configures quality tool plugins on individual subprojects (or root if single-module)
 * based on detected languages.
 */
internal object SubprojectConfigurer {

    fun configure(project: Project, rootProject: Project, extension: OctopusQualityExtension) {
        val configDir = ConfigExtractor.extractTo(rootProject)
        val languages = LanguageDetector.detect(project)

        if (languages.hasJava || languages.hasKotlin || languages.hasGroovy) {
            configureJavaTools(project, configDir, extension)
        }

        if (languages.hasKotlin) {
            configureKotlinTools(project, rootProject, configDir, extension)
        }

        if (languages.hasGroovy) {
            configureGroovyTools(project, configDir, extension)
        }
    }

    private fun configureJavaTools(project: Project, configDir: File, extension: OctopusQualityExtension) {
        // Checkstyle — built into Gradle
        project.pluginManager.apply("checkstyle")
        project.extensions.configure(org.gradle.api.plugins.quality.CheckstyleExtension::class.java) { ext ->
            ext.toolVersion = "10.17.0"
            ext.configFile = File(configDir, "checkstyle.xml")
            ext.isShowViolations = true
            // Default report-only; resolved lazily via convention
            ext.isIgnoreFailures = !extension.java.failOnViolation.get()
        }
        project.tasks.withType(org.gradle.api.plugins.quality.Checkstyle::class.java).configureEach { task ->
            task.reports.xml.required.set(true)
            task.reports.html.required.set(true)
        }

        // PMD — built into Gradle
        project.pluginManager.apply("pmd")
        project.extensions.configure(org.gradle.api.plugins.quality.PmdExtension::class.java) { ext ->
            ext.toolVersion = "6.55.0"
            ext.isConsoleOutput = true
            ext.incrementalAnalysis.set(true)
            ext.isIgnoreFailures = !extension.java.failOnViolation.get()
            ext.ruleSets = emptyList()
            ext.ruleSetFiles = project.files(File(configDir, "pmd-ruleset.xml"))
        }
        project.tasks.withType(org.gradle.api.plugins.quality.Pmd::class.java).configureEach { task ->
            task.reports.xml.required.set(true)
            task.reports.html.required.set(true)
        }

        // JaCoCo — built into Gradle (coverage for Java/mixed projects)
        project.pluginManager.apply("jacoco")
        project.tasks.matching { it.name == "test" }.configureEach { testTask ->
            testTask.finalizedBy(project.tasks.matching { it.name == "jacocoTestReport" })
        }
        project.tasks.withType(org.gradle.testing.jacoco.tasks.JacocoReport::class.java).matching { it.name == "jacocoTestReport" }.configureEach { task ->
            task.dependsOn(project.tasks.matching { it.name == "test" })
            task.reports.xml.required.set(true)
            task.reports.html.required.set(true)
        }
        project.tasks.withType(org.gradle.testing.jacoco.tasks.JacocoCoverageVerification::class.java).matching { it.name == "jacocoTestCoverageVerification" }.configureEach { task ->
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

    @Suppress("UNUSED_PARAMETER")
    private fun configureKotlinTools(project: Project, rootProject: Project, configDir: File, extension: OctopusQualityExtension) {
        // Detekt
        tryApplyPlugin(project, "io.gitlab.arturbosch.detekt") {
            project.extensions.configure(io.gitlab.arturbosch.detekt.extensions.DetektExtension::class.java) { ext ->
                ext.buildUponDefaultConfig = true
                ext.allRules = false
                ext.config.setFrom(File(configDir, "detekt.yml"))
                ext.baseline = File(project.projectDir, "detekt-baseline.xml")
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

        // KtLint
        tryApplyPlugin(project, "org.jlleitschuh.gradle.ktlint") {
            project.extensions.configure(org.jlleitschuh.gradle.ktlint.KtlintExtension::class.java) { ext ->
                ext.ignoreFailures.set(!extension.kotlin.failOnViolation.get())
                ext.outputToConsole.set(true)
                ext.reporters {
                    it.reporter(org.jlleitschuh.gradle.ktlint.reporter.ReporterType.PLAIN)
                    it.reporter(org.jlleitschuh.gradle.ktlint.reporter.ReporterType.CHECKSTYLE)
                }
                ext.baseline.set(File(project.projectDir, "ktlint-baseline.xml"))
                ext.filter {
                    it.exclude("**/generated/**")
                    it.exclude("**/build/**")
                    it.include("**/src/**/*.kt")
                }
            }
            // Disable Kotlin script checks
            project.tasks.matching { task ->
                task.name == "runKtlintCheckOverKotlinScripts" ||
                    task.name == "ktlintKotlinScriptCheck" ||
                    task.name == "runKtlintFormatOverKotlinScripts" ||
                    task.name == "ktlintKotlinScriptFormat"
            }.configureEach { it.enabled = false }
        }
    }

    private fun configureGroovyTools(project: Project, configDir: File, extension: OctopusQualityExtension) {
        project.pluginManager.apply("codenarc")
        project.extensions.configure(org.gradle.api.plugins.quality.CodeNarcExtension::class.java) { ext ->
            ext.configFile = File(configDir, "codenarc.groovy")
            ext.isIgnoreFailures = !extension.groovy.failOnViolation.get()
        }
        project.tasks.withType(org.gradle.api.plugins.quality.CodeNarc::class.java).configureEach { task ->
            task.reports.xml.required.set(true)
            task.reports.html.required.set(true)
        }
    }

    /**
     * Try to apply a plugin. If the plugin class is not on the classpath (consumer
     * didn't add it to buildscript dependencies), log a warning and skip.
     */
    private fun tryApplyPlugin(project: Project, pluginId: String, configure: () -> Unit) {
        try {
            project.pluginManager.apply(pluginId)
            configure()
        } catch (e: Exception) {
            project.logger.warn(
                "octopus-quality: could not apply plugin '$pluginId' to '${project.path}'. " +
                    "Add the plugin to your buildscript classpath. Error: ${e.message}"
            )
        }
    }
}
